// Copyright 2026 AntlerAI. All rights reserved.
#include "third_party/owl/host/owl_permission_service_impl.h"

#include "third_party/owl/host/owl_permission_manager.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace owl {

namespace {

// Convert owl::mojom::PermissionType to blink::PermissionType.
std::optional<blink::PermissionType> FromMojomType(
    owl::mojom::PermissionType type) {
  switch (type) {
    case owl::mojom::PermissionType::kCamera:
      return blink::PermissionType::VIDEO_CAPTURE;
    case owl::mojom::PermissionType::kMicrophone:
      return blink::PermissionType::AUDIO_CAPTURE;
    case owl::mojom::PermissionType::kGeolocation:
      return blink::PermissionType::GEOLOCATION;
    case owl::mojom::PermissionType::kNotifications:
      return blink::PermissionType::NOTIFICATIONS;
  }
  return std::nullopt;
}

// Convert content::PermissionStatus to owl::mojom::PermissionStatus.
owl::mojom::PermissionStatus ToMojomStatus(
    content::PermissionStatus status) {
  switch (status) {
    case content::PermissionStatus::GRANTED:
      return owl::mojom::PermissionStatus::kGranted;
    case content::PermissionStatus::DENIED:
      return owl::mojom::PermissionStatus::kDenied;
    case content::PermissionStatus::ASK:
      return owl::mojom::PermissionStatus::kAsk;
  }
  return owl::mojom::PermissionStatus::kAsk;
}

// Convert owl::mojom::PermissionStatus to content::PermissionStatus.
content::PermissionStatus FromMojomStatus(
    owl::mojom::PermissionStatus status) {
  switch (status) {
    case owl::mojom::PermissionStatus::kGranted:
      return content::PermissionStatus::GRANTED;
    case owl::mojom::PermissionStatus::kDenied:
      return content::PermissionStatus::DENIED;
    case owl::mojom::PermissionStatus::kAsk:
      return content::PermissionStatus::ASK;
  }
  return content::PermissionStatus::ASK;
}

// Convert blink::PermissionType to owl::mojom::PermissionType.
owl::mojom::PermissionType ToMojomType(blink::PermissionType type) {
  switch (type) {
    case blink::PermissionType::VIDEO_CAPTURE:
      return owl::mojom::PermissionType::kCamera;
    case blink::PermissionType::AUDIO_CAPTURE:
      return owl::mojom::PermissionType::kMicrophone;
    case blink::PermissionType::GEOLOCATION:
      return owl::mojom::PermissionType::kGeolocation;
    case blink::PermissionType::NOTIFICATIONS:
      return owl::mojom::PermissionType::kNotifications;
    default:
      // Should not reach here for supported types.
      return owl::mojom::PermissionType::kCamera;
  }
}

}  // namespace

OWLPermissionServiceImpl::OWLPermissionServiceImpl(
    OWLPermissionManager* manager)
    : manager_(manager) {}

OWLPermissionServiceImpl::~OWLPermissionServiceImpl() = default;

void OWLPermissionServiceImpl::Bind(
    mojo::PendingReceiver<owl::mojom::PermissionService> receiver) {
  receivers_.Add(this, std::move(receiver));
}

void OWLPermissionServiceImpl::AddReceiver(
    mojo::PendingReceiver<owl::mojom::PermissionService> receiver) {
  receivers_.Add(this, std::move(receiver));
}

void OWLPermissionServiceImpl::GetPermission(
    const std::string& origin,
    owl::mojom::PermissionType type,
    GetPermissionCallback callback) {
  auto blink_type = FromMojomType(type);
  if (!blink_type) {
    std::move(callback).Run(owl::mojom::PermissionStatus::kAsk);
    return;
  }
  auto status = manager_->GetPermission(
      url::Origin::Create(GURL(origin)), *blink_type);
  std::move(callback).Run(ToMojomStatus(status));
}

void OWLPermissionServiceImpl::SetPermission(
    const std::string& origin,
    owl::mojom::PermissionType type,
    owl::mojom::PermissionStatus status) {
  auto blink_type = FromMojomType(type);
  if (!blink_type) return;
  manager_->SetPermission(
      url::Origin::Create(GURL(origin)),
      *blink_type,
      FromMojomStatus(status));
}

void OWLPermissionServiceImpl::GetAllPermissions(
    GetAllPermissionsCallback callback) {
  auto all = manager_->GetAllPermissions();
  std::vector<owl::mojom::SitePermissionPtr> result;
  result.reserve(all.size());
  for (const auto& [origin_str, perm_type, perm_status] : all) {
    auto sp = owl::mojom::SitePermission::New();
    sp->origin = origin_str;
    sp->type = ToMojomType(perm_type);
    sp->status = ToMojomStatus(perm_status);
    result.push_back(std::move(sp));
  }
  std::move(callback).Run(std::move(result));
}

void OWLPermissionServiceImpl::ResetPermission(
    const std::string& origin,
    owl::mojom::PermissionType type) {
  auto blink_type = FromMojomType(type);
  if (!blink_type) return;
  // ASK is equivalent to deleting the entry (reset).
  manager_->SetPermission(
      url::Origin::Create(GURL(origin)),
      *blink_type,
      content::PermissionStatus::ASK);
}

void OWLPermissionServiceImpl::ResetAll() {
  // Get all permissions and reset each one.
  auto all = manager_->GetAllPermissions();
  for (const auto& [origin_str, perm_type, perm_status] : all) {
    manager_->SetPermission(
        url::Origin::Create(GURL(origin_str)),
        perm_type,
        content::PermissionStatus::ASK);
  }
}

}  // namespace owl
