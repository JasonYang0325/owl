// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/owl/host/owl_browser_impl.h"

#include "base/files/file_path.h"
#include "base/task/sequenced_task_runner.h"
#include "third_party/owl/host/owl_browser_context.h"
#include "third_party/owl/host/owl_browser_main_parts.h"
#include "third_party/owl/host/owl_content_browser_client.h"
#include "third_party/owl/host/owl_content_browser_context.h"
#include "third_party/owl/mojom/owl_types.mojom.h"

namespace owl {

namespace {

// Validates partition_name: only [a-zA-Z0-9_-], max 64 chars.
bool IsPartitionNameValid(const std::string& name) {
  if (name.empty()) {
    return true;  // Null/empty partition is allowed (default).
  }
  if (name.size() > 64) {
    return false;
  }
  for (char c : name) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '_' || c == '-')) {
      return false;
    }
  }
  return true;
}

}  // namespace

OWLBrowserImpl::OWLBrowserImpl(const std::string& version,
                               const std::string& user_data_dir,
                               uint16_t devtools_port,
                               OWLContentBrowserContext* content_browser_context)
    : version_(version),
      user_data_dir_(user_data_dir),
      devtools_port_(devtools_port),
      content_browser_context_(content_browser_context) {}

OWLBrowserImpl::OWLBrowserImpl(const std::string& version,
                               const std::string& user_data_dir,
                               uint16_t devtools_port)
    : OWLBrowserImpl(version, user_data_dir, devtools_port, nullptr) {}

OWLBrowserImpl::~OWLBrowserImpl() = default;

void OWLBrowserImpl::Bind(
    mojo::PendingReceiver<owl::mojom::SessionHost> receiver) {
  receiver_.Bind(std::move(receiver));
  receiver_.set_disconnect_handler(base::BindOnce(
      &OWLBrowserImpl::OnDisconnect, base::Unretained(this)));
}

void OWLBrowserImpl::OnDisconnect() {
  // Client dropped the SessionHost remote — treat as shutdown.
  if (!is_shutting_down_) {
    is_shutting_down_ = true;
    if (observer_) {
      observer_->OnShutdown();
      observer_.reset();
    }
    // Move to local to prevent reentrant modification via
    // destroyed_callback_ -> OnBrowserContextDestroyed during iteration.
    auto local_contexts = std::move(browser_contexts_);
    for (auto& ctx : local_contexts) {
      ctx->DestroyInternal();
    }
    local_contexts.clear();
  }
}

void OWLBrowserImpl::GetHostInfo(GetHostInfoCallback callback) {
  std::move(callback).Run(version_, user_data_dir_, devtools_port_);
}

void OWLBrowserImpl::CreateBrowserContext(
    owl::mojom::ProfileConfigPtr config,
    CreateBrowserContextCallback callback) {
  if (is_shutting_down_) {
    std::move(callback).Run(mojo::NullRemote());
    return;
  }

  // Validate partition name.
  std::string partition_name =
      config->partition_name.value_or(std::string());
  if (!IsPartitionNameValid(partition_name)) {
    std::move(callback).Run(mojo::NullRemote());
    return;
  }

  OWLPermissionManager* pm = content_browser_context_
      ? content_browser_context_->GetPermissionManager() : nullptr;
  OWLDownloadService* ds = content_browser_context_
      ? content_browser_context_->download_service() : nullptr;

  auto context = std::make_unique<OWLBrowserContext>(
      partition_name, config->off_the_record,
      base::FilePath(user_data_dir_),
      pm, ds,
      base::BindOnce(&OWLBrowserImpl::OnBrowserContextDestroyed,
                     weak_factory_.GetWeakPtr()));

  mojo::PendingRemote<owl::mojom::BrowserContextHost> remote;
  context->Bind(remote.InitWithNewPipeAndPassReceiver());

  browser_contexts_.push_back(std::move(context));
  LOG(INFO) << "[OWL] BrowserContext created, partition=" << partition_name;
  std::move(callback).Run(std::move(remote));
}

void OWLBrowserImpl::SetObserver(
    mojo::PendingRemote<owl::mojom::SessionObserver> observer) {
  observer_.reset();
  if (observer.is_valid()) {
    observer_.Bind(std::move(observer));
  }
}

void OWLBrowserImpl::Shutdown(ShutdownCallback callback) {
  is_shutting_down_ = true;

  // Notify observer before clearing (so observer can still query state).
  if (observer_) {
    observer_->OnShutdown();
    observer_.reset();
  }

  // Move to local to prevent reentrant modification via
  // destroyed_callback_ -> OnBrowserContextDestroyed during iteration.
  // DestroyInternal is idempotent so ~OWLBrowserContext won't double-cleanup.
  auto local_contexts = std::move(browser_contexts_);
  for (auto& ctx : local_contexts) {
    ctx->DestroyInternal();
  }
  local_contexts.clear();

  std::move(callback).Run();
}

void OWLBrowserImpl::OnBrowserContextDestroyed(OWLBrowserContext* context) {
  std::erase_if(browser_contexts_, [context](const auto& ptr) {
    return ptr.get() == context;
  });
}

}  // namespace owl
