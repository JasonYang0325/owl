// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/owl/host/owl_login_delegate.h"

#include "base/logging.h"

namespace owl {

OWLLoginDelegate::OWLLoginDelegate(
    content::LoginDelegate::LoginAuthRequiredCallback callback,
    uint64_t auth_id)
    : callback_(std::move(callback)), auth_id_(auth_id) {}

OWLLoginDelegate::~OWLLoginDelegate() {
  // If callback hasn't been consumed, cancel the auth request.
  if (callback_) {
    LOG(INFO) << "[OWL] LoginDelegate destroyed without response, "
              << "cancelling auth_id=" << auth_id_;
    std::move(callback_).Run(std::nullopt);
  }
}

void OWLLoginDelegate::Respond(const std::u16string& username,
                                const std::u16string& password) {
  if (!callback_) {
    LOG(WARNING) << "[OWL] LoginDelegate::Respond called but callback "
                 << "already consumed, auth_id=" << auth_id_;
    return;
  }
  net::AuthCredentials credentials(username, password);
  std::move(callback_).Run(credentials);
}

void OWLLoginDelegate::Cancel() {
  if (!callback_) {
    LOG(WARNING) << "[OWL] LoginDelegate::Cancel called but callback "
                 << "already consumed, auth_id=" << auth_id_;
    return;
  }
  std::move(callback_).Run(std::nullopt);
}

}  // namespace owl
