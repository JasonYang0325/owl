// Copyright 2026 AntlerAI. All rights reserved.
#include "third_party/owl/host/owl_permission_manager.h"

#include <optional>

#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/task/thread_pool/thread_pool_instance.h"
#include "base/values.h"
#include "content/public/browser/permission_request_description.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "third_party/owl/host/owl_web_contents.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace owl {

namespace {

using content::PermissionResult;
using content::PermissionStatus;
using content::PermissionStatusSource;

// Single OWLPermissionManager instance (owned by OWLContentBrowserContext).
// Used by RealRespondToPermission to route permission responses.
OWLPermissionManager* g_permission_manager_instance = nullptr;

void RealRespondToPermission(uint64_t request_id, bool granted) {
  if (g_permission_manager_instance) {
    g_permission_manager_instance->ResolvePendingRequest(
        request_id,
        granted ? PermissionStatus::GRANTED
                : PermissionStatus::DENIED);
  }
}

}  // namespace

OWLPermissionManager::OWLPermissionManager(
    const base::FilePath& permissions_path)
    : permissions_path_(permissions_path) {
  DETACH_FROM_SEQUENCE(sequence_checker_);
  // Some unit-test environments don't initialize ThreadPool. In that case we
  // fall back to synchronous writes in PersistNow().
  if (base::ThreadPoolInstance::Get()) {
    file_task_runner_ = base::ThreadPool::CreateSequencedTaskRunner(
        {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
         base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  }
  LoadFromFile();

  // Register the global function pointer so OWLWebContents can forward
  // RespondToPermissionRequest calls back to us.
  g_permission_manager_instance = this;
  g_real_respond_to_permission_func = &RealRespondToPermission;
}

OWLPermissionManager::~OWLPermissionManager() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  // Clear the global function pointer and instance reference.
  if (g_permission_manager_instance == this) {
    g_permission_manager_instance = nullptr;
    g_real_respond_to_permission_func = nullptr;
  }

  // Auto-DENY any remaining pending requests to avoid leaked callbacks.
  for (auto& [request_id, pending] : pending_requests_) {
    std::vector<content::PermissionResult> results;
    for (size_t i = 0; i < pending.num_permissions; ++i) {
      results.emplace_back(content::PermissionStatus::DENIED,
                           PermissionStatusSource::UNSPECIFIED);
    }
    std::move(pending.callback).Run(std::move(results));
  }
  pending_requests_.clear();
}

// --- Public API ---

PermissionStatus OWLPermissionManager::GetPermission(
    const url::Origin& origin,
    blink::PermissionType type) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return LookupPermission(origin.Serialize(), type);
}

void OWLPermissionManager::SetPermission(const url::Origin& origin,
                                         blink::PermissionType type,
                                         PermissionStatus status) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::string origin_str = origin.Serialize();

  if (status == PermissionStatus::ASK) {
    // ASK is the default — remove the entry.
    auto it = permissions_map_.find(origin_str);
    if (it != permissions_map_.end()) {
      it->second.erase(type);
      if (it->second.empty()) {
        permissions_map_.erase(it);
      }
    }
  } else {
    permissions_map_[origin_str][type] = status;
  }

  PersistNow();
}

std::vector<
    std::tuple<std::string, blink::PermissionType, PermissionStatus>>
OWLPermissionManager::GetAllPermissions() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::vector<
      std::tuple<std::string, blink::PermissionType, PermissionStatus>>
      result;
  for (const auto& [origin_str, inner_map] : permissions_map_) {
    for (const auto& [type, status] : inner_map) {
      result.emplace_back(origin_str, type, status);
    }
  }
  return result;
}

void OWLPermissionManager::ResetOrigin(const url::Origin& origin) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::string origin_str = origin.Serialize();
  permissions_map_.erase(origin_str);
  PersistNow();
}

size_t OWLPermissionManager::permission_count_for_testing() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  size_t count = 0;
  for (const auto& [_, inner_map] : permissions_map_) {
    count += inner_map.size();
  }
  return count;
}

size_t OWLPermissionManager::pending_request_count_for_testing() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return pending_requests_.size();
}

void OWLPermissionManager::ResolvePendingRequest(
    uint64_t request_id,
    PermissionStatus status) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  auto node = pending_requests_.extract(request_id);
  if (node.empty()) {
    // Already resolved (client responded) or timed out.
    LOG(WARNING) << "OWLPermissionManager::ResolvePendingRequest: "
                 << "request_id=" << request_id << " not found (already resolved)";
    return;
  }

  auto& pending = node.mapped();
  const size_t n = pending.num_permissions;

  // Phase 2: first permission gets the client's decision, rest DENIED.
  std::vector<content::PermissionResult> results;
  results.reserve(n);
  results.emplace_back(status, PermissionStatusSource::UNSPECIFIED);
  for (size_t i = 1; i < n; ++i) {
    results.emplace_back(PermissionStatus::DENIED,
                         PermissionStatusSource::UNSPECIFIED);
  }
  std::move(pending.callback).Run(std::move(results));
}

void OWLPermissionManager::ResolvePendingRequestIfAlive(
    uint64_t request_id,
    PermissionStatus status) {
  ResolvePendingRequest(request_id, status);
}

// --- PermissionControllerDelegate overrides ---

void OWLPermissionManager::RequestPermissions(
    content::RenderFrameHost* render_frame_host,
    const content::PermissionRequestDescription& request_description,
    base::OnceCallback<void(const std::vector<PermissionResult>&)> callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  std::vector<PermissionResult> results;

  // Extract origin from the main frame.
  std::string origin_str;
  if (render_frame_host) {
    url::Origin origin =
        render_frame_host->GetMainFrame()->GetLastCommittedOrigin();
    if (origin.opaque()) {
      // Opaque origins (file://, data:, etc.) — deny all.
      for (size_t i = 0; i < request_description.permissions.size(); ++i) {
        results.emplace_back(PermissionStatus::DENIED,
                             PermissionStatusSource::UNSPECIFIED);
      }
      std::move(callback).Run(std::move(results));
      return;
    }
    origin_str = origin.Serialize();
  }

  // Check if any permission needs prompting (status == ASK).
  // Phase 2: only the first ASK permission triggers async flow; rest DENIED.
  bool needs_prompt = false;

  for (const auto& descriptor : request_description.permissions) {
    auto maybe_type =
        blink::MaybePermissionDescriptorToPermissionType(descriptor);
    if (!maybe_type.has_value()) {
      continue;
    }
    PermissionStatus status = LookupPermission(origin_str, *maybe_type);
    if (status == PermissionStatus::ASK) {
      needs_prompt = true;
      break;  // Phase 2: only prompt for first ASK permission.
    }
  }

  if (!needs_prompt) {
    // All permissions are already decided (GRANTED or DENIED).
    for (const auto& descriptor : request_description.permissions) {
      auto maybe_type =
          blink::MaybePermissionDescriptorToPermissionType(descriptor);
      if (!maybe_type.has_value()) {
        results.emplace_back(PermissionStatus::DENIED,
                             PermissionStatusSource::UNSPECIFIED);
        continue;
      }
      PermissionStatus status = LookupPermission(origin_str, *maybe_type);
      results.emplace_back(status, PermissionStatusSource::UNSPECIFIED);
    }
    std::move(callback).Run(std::move(results));
    return;
  }

  // At least one permission needs prompting. Store callback as pending.
  uint64_t request_id = next_request_id_++;
  pending_requests_[request_id] = {
      std::move(callback),
      request_description.permissions.size()
  };

  // Notify observer via global function pointer (injected by RealWebContents).
  if (g_real_notify_permission_func) {
    for (const auto& descriptor : request_description.permissions) {
      auto maybe_type =
          blink::MaybePermissionDescriptorToPermissionType(descriptor);
      if (!maybe_type.has_value()) continue;
      PermissionStatus status = LookupPermission(origin_str, *maybe_type);
      if (status == PermissionStatus::ASK) {
        g_real_notify_permission_func(
            origin_str, static_cast<int>(*maybe_type), request_id);
        break;  // Phase 2: only first ASK
      }
    }
  }

  LOG(INFO) << "OWLPermissionManager: permission request pending, "
            << "request_id=" << request_id
            << " origin=" << origin_str;

  // Timeout: auto-DENY after 30 seconds if client doesn't respond.
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&OWLPermissionManager::ResolvePendingRequestIfAlive,
                     weak_factory_.GetWeakPtr(), request_id,
                     PermissionStatus::DENIED),
      base::Seconds(30));
}

void OWLPermissionManager::RequestPermissionsFromCurrentDocument(
    content::RenderFrameHost* render_frame_host,
    const content::PermissionRequestDescription& request_description,
    base::OnceCallback<void(const std::vector<PermissionResult>&)> callback) {
  // Delegates to RequestPermissions — same behavior in Phase 1.
  RequestPermissions(render_frame_host, request_description,
                     std::move(callback));
}

PermissionStatus OWLPermissionManager::GetPermissionStatus(
    const blink::mojom::PermissionDescriptorPtr& permission,
    const GURL& requesting_origin,
    const GURL& embedding_origin) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  auto maybe_type =
      blink::MaybePermissionDescriptorToPermissionType(permission);
  if (!maybe_type.has_value()) {
    return PermissionStatus::DENIED;
  }

  url::Origin origin = url::Origin::Create(requesting_origin);
  if (origin.opaque()) {
    return PermissionStatus::ASK;
  }

  return LookupPermission(origin.Serialize(), *maybe_type);
}

PermissionResult OWLPermissionManager::GetPermissionResultForOriginWithoutContext(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    const url::Origin& requesting_origin,
    const url::Origin& embedding_origin) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  auto maybe_type =
      blink::MaybePermissionDescriptorToPermissionType(permission_descriptor);
  if (!maybe_type.has_value()) {
    return PermissionResult(PermissionStatus::DENIED,
                            PermissionStatusSource::UNSPECIFIED);
  }

  if (requesting_origin.opaque()) {
    return PermissionResult(PermissionStatus::ASK,
                            PermissionStatusSource::UNSPECIFIED);
  }

  PermissionStatus status =
      LookupPermission(requesting_origin.Serialize(), *maybe_type);
  return PermissionResult(status, PermissionStatusSource::UNSPECIFIED);
}

PermissionResult OWLPermissionManager::GetPermissionResultForCurrentDocument(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderFrameHost* render_frame_host,
    bool should_include_device_status) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  auto maybe_type =
      blink::MaybePermissionDescriptorToPermissionType(permission_descriptor);
  if (!maybe_type.has_value()) {
    return PermissionResult(PermissionStatus::DENIED,
                            PermissionStatusSource::UNSPECIFIED);
  }

  url::Origin origin =
      render_frame_host->GetMainFrame()->GetLastCommittedOrigin();
  if (origin.opaque()) {
    return PermissionResult(PermissionStatus::ASK,
                            PermissionStatusSource::UNSPECIFIED);
  }

  PermissionStatus status = LookupPermission(origin.Serialize(), *maybe_type);
  return PermissionResult(status, PermissionStatusSource::UNSPECIFIED);
}

PermissionResult OWLPermissionManager::GetPermissionResultForWorker(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderProcessHost* render_process_host,
    const GURL& worker_origin) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  auto maybe_type =
      blink::MaybePermissionDescriptorToPermissionType(permission_descriptor);
  if (!maybe_type.has_value()) {
    return PermissionResult(PermissionStatus::DENIED,
                            PermissionStatusSource::UNSPECIFIED);
  }

  url::Origin origin = url::Origin::Create(worker_origin);
  if (origin.opaque()) {
    return PermissionResult(PermissionStatus::ASK,
                            PermissionStatusSource::UNSPECIFIED);
  }

  PermissionStatus status = LookupPermission(origin.Serialize(), *maybe_type);
  return PermissionResult(status, PermissionStatusSource::UNSPECIFIED);
}

PermissionResult OWLPermissionManager::GetPermissionResultForEmbeddedRequester(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderFrameHost* render_frame_host,
    const url::Origin& requesting_origin) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  auto maybe_type =
      blink::MaybePermissionDescriptorToPermissionType(permission_descriptor);
  if (!maybe_type.has_value()) {
    return PermissionResult(PermissionStatus::DENIED,
                            PermissionStatusSource::UNSPECIFIED);
  }

  if (requesting_origin.opaque()) {
    return PermissionResult(PermissionStatus::ASK,
                            PermissionStatusSource::UNSPECIFIED);
  }

  PermissionStatus status =
      LookupPermission(requesting_origin.Serialize(), *maybe_type);
  return PermissionResult(status, PermissionStatusSource::UNSPECIFIED);
}

void OWLPermissionManager::ResetPermission(blink::PermissionType permission,
                                           const GURL& requesting_origin,
                                           const GURL& embedding_origin) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  url::Origin origin = url::Origin::Create(requesting_origin);
  std::string origin_str = origin.Serialize();

  auto it = permissions_map_.find(origin_str);
  if (it != permissions_map_.end()) {
    it->second.erase(permission);
    if (it->second.empty()) {
      permissions_map_.erase(it);
    }
    PersistNow();
  }
}

// --- Persistence ---

void OWLPermissionManager::LoadFromFile() {
  if (permissions_path_.empty()) {
    return;  // Memory-only mode.
  }

  std::string contents;
  if (!base::ReadFileToString(permissions_path_, &contents)) {
    // File doesn't exist yet — normal for first run.
    return;
  }

  auto parsed = base::JSONReader::ReadDict(contents, base::JSON_PARSE_RFC);
  if (!parsed.has_value()) {
    LOG(ERROR) << "[OWL] Failed to parse permissions.json";
    // AC-P1-4: corrupt JSON — fall back to empty map.
    permissions_map_.clear();
    return;
  }

  const auto& root = *parsed;
  for (const auto [origin_str, inner_value] : root) {
    if (!inner_value.is_dict()) {
      LOG(WARNING) << "[OWL] Skipping non-dict origin entry: " << origin_str;
      continue;
    }

    const auto& inner_dict = inner_value.GetDict();
    for (const auto [type_str, status_value] : inner_dict) {
      auto maybe_type = TypeFromString(type_str);
      if (!maybe_type.has_value()) {
        LOG(WARNING) << "[OWL] Skipping unknown permission type: " << type_str
                     << " for origin: " << origin_str;
        continue;
      }

      if (!status_value.is_string()) {
        LOG(WARNING) << "[OWL] Skipping non-string status for " << type_str
                     << " at " << origin_str;
        continue;
      }

      PermissionStatus status = StatusFromString(status_value.GetString());
      if (status == PermissionStatus::ASK) {
        // Don't store ASK — it's the default.
        continue;
      }

      permissions_map_[origin_str][*maybe_type] = status;
    }
  }

  size_t count = 0;
  for (const auto& [_, inner] : permissions_map_) {
    count += inner.size();
  }
  LOG(INFO) << "[OWL] Loaded " << count << " permission entries from "
            << permissions_path_.value();
}

void OWLPermissionManager::PersistNow() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (permissions_path_.empty()) {
    return;  // Memory-only mode.
  }

  // BH-017: Snapshot the permissions data as JSON on the UI thread,
  // then post file I/O to the background task runner.
  base::DictValue root;
  for (const auto& [origin_str, inner_map] : permissions_map_) {
    base::DictValue inner;
    for (const auto& [type, status] : inner_map) {
      auto type_str = TypeToString(type);
      if (!type_str.has_value()) {
        continue;  // Skip unsupported types (shouldn't happen).
      }
      inner.Set(*type_str, StatusToString(status));
    }
    if (!inner.empty()) {
      root.Set(origin_str, std::move(inner));
    }
  }

  std::string json;
  if (!base::JSONWriter::WriteWithOptions(
          root, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json)) {
    LOG(ERROR) << "[OWL] Failed to serialize permissions to JSON";
    return;
  }

  base::FilePath target_path = permissions_path_;
  auto write_atomically = [](base::FilePath target_path, std::string json) {
    // Ensure parent directory exists.
    base::FilePath dir = target_path.DirName();
    if (!base::CreateDirectory(dir)) {
      LOG(ERROR) << "[OWL] Failed to create directory: " << dir.value();
      return;
    }

    // Write to temp file first.
    base::FilePath temp_path = target_path.AddExtensionASCII("tmp");
    if (!base::WriteFile(temp_path, json)) {
      LOG(ERROR) << "[OWL] Failed to write temp permissions file: "
                 << temp_path.value();
      return;
    }

    // Atomic rename: temp -> target.
    if (!base::Move(temp_path, target_path)) {
      LOG(ERROR) << "[OWL] Failed to rename temp permissions file to "
                 << target_path.value();
      // Clean up temp file on failure.
      base::DeleteFile(temp_path);
    }
  };

  if (file_task_runner_) {
    // Post async write to file_task_runner_: temp file + atomic rename.
    file_task_runner_->PostTask(
        FROM_HERE, base::BindOnce(write_atomically, target_path, std::move(json)));
    return;
  }

  // Unit-test fallback when ThreadPool is unavailable.
  write_atomically(target_path, std::move(json));
}

// --- Private helpers ---

PermissionStatus OWLPermissionManager::LookupPermission(
    const std::string& origin_str,
    blink::PermissionType type) const {
  auto origin_it = permissions_map_.find(origin_str);
  if (origin_it == permissions_map_.end()) {
    return PermissionStatus::ASK;
  }
  auto type_it = origin_it->second.find(type);
  if (type_it == origin_it->second.end()) {
    return PermissionStatus::ASK;
  }
  return type_it->second;
}

// static
PermissionStatus OWLPermissionManager::StatusFromString(
    const std::string& s) {
  if (s == "granted") {
    return PermissionStatus::GRANTED;
  }
  if (s == "denied") {
    return PermissionStatus::DENIED;
  }
  return PermissionStatus::ASK;
}

// static
std::string OWLPermissionManager::StatusToString(PermissionStatus s) {
  switch (s) {
    case PermissionStatus::GRANTED:
      return "granted";
    case PermissionStatus::DENIED:
      return "denied";
    case PermissionStatus::ASK:
      return "ask";
  }
}

// static
std::optional<std::string> OWLPermissionManager::TypeToString(
    blink::PermissionType type) {
  switch (type) {
    case blink::PermissionType::VIDEO_CAPTURE:
      return "camera";
    case blink::PermissionType::AUDIO_CAPTURE:
      return "microphone";
    case blink::PermissionType::GEOLOCATION:
      return "geolocation";
    case blink::PermissionType::NOTIFICATIONS:
      return "notifications";
    default:
      return std::nullopt;
  }
}

// static
std::optional<blink::PermissionType> OWLPermissionManager::TypeFromString(
    const std::string& s) {
  if (s == "camera") {
    return blink::PermissionType::VIDEO_CAPTURE;
  }
  if (s == "microphone") {
    return blink::PermissionType::AUDIO_CAPTURE;
  }
  if (s == "geolocation") {
    return blink::PermissionType::GEOLOCATION;
  }
  if (s == "notifications") {
    return blink::PermissionType::NOTIFICATIONS;
  }
  return std::nullopt;
}

}  // namespace owl
