// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_HOST_OWL_LOGIN_DELEGATE_H_
#define THIRD_PARTY_OWL_HOST_OWL_LOGIN_DELEGATE_H_

#include <string>

#include "base/memory/weak_ptr.h"
#include "content/public/browser/login_delegate.h"
#include "net/base/auth.h"

namespace owl {

// LoginDelegate implementation for HTTP Auth (401/407).
// Chromium owns the unique_ptr — when navigation ends or WebContents is
// destroyed, Chromium destroys this delegate. If the callback hasn't been
// consumed at that point, the destructor cancels the auth request.
class OWLLoginDelegate : public content::LoginDelegate {
 public:
  OWLLoginDelegate(
      content::LoginDelegate::LoginAuthRequiredCallback callback,
      uint64_t auth_id);
  ~OWLLoginDelegate() override;

  OWLLoginDelegate(const OWLLoginDelegate&) = delete;
  OWLLoginDelegate& operator=(const OWLLoginDelegate&) = delete;

  // Respond with credentials. Consumes the callback.
  void Respond(const std::u16string& username, const std::u16string& password);

  // Cancel the auth request. Consumes the callback.
  void Cancel();

  uint64_t auth_id() const { return auth_id_; }

  base::WeakPtr<OWLLoginDelegate> GetWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

 private:
  content::LoginDelegate::LoginAuthRequiredCallback callback_;
  uint64_t auth_id_;
  base::WeakPtrFactory<OWLLoginDelegate> weak_factory_{this};
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_LOGIN_DELEGATE_H_
