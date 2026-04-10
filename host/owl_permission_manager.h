// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_HOST_OWL_PERMISSION_MANAGER_H_
#define THIRD_PARTY_OWL_HOST_OWL_PERMISSION_MANAGER_H_

#include <map>
#include <string>
#include <tuple>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/weak_ptr.h"
#include "base/sequence_checker.h"
#include "base/task/sequenced_task_runner.h"
#include "content/public/browser/permission_controller_delegate.h"
#include "content/public/browser/permission_result.h"
#include "third_party/blink/public/common/permissions/permission_utils.h"
#include "url/origin.h"

namespace owl {

// Implements content::PermissionControllerDelegate with JSON file persistence.
// All methods run on the UI thread (single-threaded, no locks needed).
//
// Phase 1 behavior:
// - RequestPermissions returns stored status or DENIED (no prompt).
// - Permissions are persisted to |permissions_path| as JSON.
// - If |permissions_path| is empty, operates in memory-only mode
//   (off-the-record / tests).
class OWLPermissionManager : public content::PermissionControllerDelegate {
 public:
  // |permissions_path|: path to permissions.json.
  // Empty path = memory-only mode (no file I/O).
  explicit OWLPermissionManager(const base::FilePath& permissions_path);
  ~OWLPermissionManager() override;

  OWLPermissionManager(const OWLPermissionManager&) = delete;
  OWLPermissionManager& operator=(const OWLPermissionManager&) = delete;

  // Query permission status for |origin| and |type|.
  // Returns ASK if not found in the store.
  content::PermissionStatus GetPermission(const url::Origin& origin,
                                          blink::PermissionType type) const;

  // Set permission status for |origin| and |type|.
  // Setting ASK removes the entry (ASK is the default, not stored).
  void SetPermission(const url::Origin& origin,
                     blink::PermissionType type,
                     content::PermissionStatus status);

  // Returns all stored permissions as (origin_string, type, status) tuples.
  std::vector<
      std::tuple<std::string, blink::PermissionType, content::PermissionStatus>>
  GetAllPermissions() const;

  // Reset all permissions for |origin|.
  void ResetOrigin(const url::Origin& origin);

  // content::PermissionControllerDelegate:
  void RequestPermissions(
      content::RenderFrameHost* render_frame_host,
      const content::PermissionRequestDescription& request_description,
      base::OnceCallback<void(const std::vector<content::PermissionResult>&)>
          callback) override;

  void RequestPermissionsFromCurrentDocument(
      content::RenderFrameHost* render_frame_host,
      const content::PermissionRequestDescription& request_description,
      base::OnceCallback<void(const std::vector<content::PermissionResult>&)>
          callback) override;

  content::PermissionStatus GetPermissionStatus(
      const blink::mojom::PermissionDescriptorPtr& permission,
      const GURL& requesting_origin,
      const GURL& embedding_origin) override;

  content::PermissionResult GetPermissionResultForOriginWithoutContext(
      const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
      const url::Origin& requesting_origin,
      const url::Origin& embedding_origin) override;

  content::PermissionResult GetPermissionResultForCurrentDocument(
      const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
      content::RenderFrameHost* render_frame_host,
      bool should_include_device_status) override;

  content::PermissionResult GetPermissionResultForWorker(
      const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
      content::RenderProcessHost* render_process_host,
      const GURL& worker_origin) override;

  content::PermissionResult GetPermissionResultForEmbeddedRequester(
      const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
      content::RenderFrameHost* render_frame_host,
      const url::Origin& requesting_origin) override;

  void ResetPermission(blink::PermissionType permission,
                       const GURL& requesting_origin,
                       const GURL& embedding_origin) override;

  // Resolve a pending permission request (from RespondToPermissionRequest).
  // Extracts request from the pending map and invokes its callback.
  // No-op if request_id is not found (already resolved or timed out).
  void ResolvePendingRequest(uint64_t request_id,
                             content::PermissionStatus status);

  // For testing.
  size_t permission_count_for_testing() const;
  size_t pending_request_count_for_testing() const;

  // Persistence (public for testing, matching BookmarkService pattern).
  void LoadFromFile();
  void PersistNow();

 private:
  // Look up a permission in the in-memory map.
  // Returns ASK if not found.
  content::PermissionStatus LookupPermission(
      const std::string& origin_str,
      blink::PermissionType type) const;

  // Convert between PermissionStatus and JSON string representation.
  static content::PermissionStatus StatusFromString(const std::string& s);
  static std::string StatusToString(content::PermissionStatus s);

  // Convert between PermissionType and JSON key string.
  // Returns nullopt for unsupported types.
  static std::optional<std::string> TypeToString(blink::PermissionType type);
  static std::optional<blink::PermissionType> TypeFromString(
      const std::string& s);

  // Called by timeout delayed task via weak pointer. Delegates to
  // ResolvePendingRequest. If the manager has been destroyed, the weak
  // pointer invalidates and the call is skipped.
  void ResolvePendingRequestIfAlive(uint64_t request_id,
                                    content::PermissionStatus status);

  const base::FilePath permissions_path_;

  // Background task runner for async file I/O (BH-017).
  scoped_refptr<base::SequencedTaskRunner> file_task_runner_;

  // In-memory cache: origin string -> (permission_type -> status).
  // Only stores non-ASK entries (ASK is the default, not persisted).
  std::map<std::string,
           std::map<blink::PermissionType, content::PermissionStatus>>
      permissions_map_;

  // Pending permission requests awaiting client response.
  // request_id -> (callback, num_permissions).
  struct PendingRequest {
    base::OnceCallback<void(const std::vector<content::PermissionResult>&)>
        callback;
    size_t num_permissions;
  };
  std::map<uint64_t, PendingRequest> pending_requests_;
  uint64_t next_request_id_ = 1;

  SEQUENCE_CHECKER(sequence_checker_);

  // Must be last member (weak pointers are invalidated before other members
  // are destroyed, preventing dangling pointers in delayed tasks).
  base::WeakPtrFactory<OWLPermissionManager> weak_factory_{this};
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_PERMISSION_MANAGER_H_
