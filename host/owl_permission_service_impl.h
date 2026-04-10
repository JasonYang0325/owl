// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_HOST_OWL_PERMISSION_SERVICE_IMPL_H_
#define THIRD_PARTY_OWL_HOST_OWL_PERMISSION_SERVICE_IMPL_H_

#include <string>
#include <vector>

#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "third_party/owl/mojom/permissions.mojom.h"

namespace owl {

class OWLPermissionManager;

// Implements owl.mojom.PermissionService by delegating to OWLPermissionManager.
// Handles Mojom <-> blink/content type conversion.
//
// Supports multiple Mojo pipe endpoints via ReceiverSet. All methods run on the UI thread.
// If the underlying OWLPermissionManager is file-backed, changes are
// automatically persisted.
class OWLPermissionServiceImpl : public owl::mojom::PermissionService {
 public:
  // |manager| must outlive this object. Not owned.
  explicit OWLPermissionServiceImpl(OWLPermissionManager* manager);
  ~OWLPermissionServiceImpl() override;

  OWLPermissionServiceImpl(const OWLPermissionServiceImpl&) = delete;
  OWLPermissionServiceImpl& operator=(const OWLPermissionServiceImpl&) = delete;

  // Bind a single receiver (convenience, delegates to AddReceiver).
  void Bind(mojo::PendingReceiver<owl::mojom::PermissionService> receiver);

  // Add a new pipe endpoint (multiple clients supported via ReceiverSet).
  void AddReceiver(mojo::PendingReceiver<owl::mojom::PermissionService> receiver);

  // owl::mojom::PermissionService:
  void GetPermission(const std::string& origin,
                     owl::mojom::PermissionType type,
                     GetPermissionCallback callback) override;
  void SetPermission(const std::string& origin,
                     owl::mojom::PermissionType type,
                     owl::mojom::PermissionStatus status) override;
  void GetAllPermissions(GetAllPermissionsCallback callback) override;
  void ResetPermission(const std::string& origin,
                       owl::mojom::PermissionType type) override;
  void ResetAll() override;

 private:
  // Not owned. Must outlive this object.
  OWLPermissionManager* const manager_;

  mojo::ReceiverSet<owl::mojom::PermissionService> receivers_;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_PERMISSION_SERVICE_IMPL_H_
