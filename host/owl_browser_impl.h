// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_HOST_OWL_BROWSER_IMPL_H_
#define THIRD_PARTY_OWL_HOST_OWL_BROWSER_IMPL_H_

#include <memory>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "third_party/owl/mojom/session.mojom.h"

namespace owl {

class OWLBrowserContext;
class OWLContentBrowserContext;

// Implements owl.mojom.SessionHost.
// All methods run on the UI thread.
class OWLBrowserImpl : public owl::mojom::SessionHost {
 public:
  OWLBrowserImpl(const std::string& version,
                 const std::string& user_data_dir,
                 uint16_t devtools_port,
                 OWLContentBrowserContext* content_browser_context);

  // Convenience overload for tests (no content_browser_context).
  OWLBrowserImpl(const std::string& version,
                 const std::string& user_data_dir,
                 uint16_t devtools_port);
  ~OWLBrowserImpl() override;

  OWLBrowserImpl(const OWLBrowserImpl&) = delete;
  OWLBrowserImpl& operator=(const OWLBrowserImpl&) = delete;

  // Binds this implementation to a Mojo receiver.
  void Bind(mojo::PendingReceiver<owl::mojom::SessionHost> receiver);

  // owl::mojom::SessionHost:
  void GetHostInfo(GetHostInfoCallback callback) override;
  void CreateBrowserContext(
      owl::mojom::ProfileConfigPtr config,
      CreateBrowserContextCallback callback) override;
  void SetObserver(
      mojo::PendingRemote<owl::mojom::SessionObserver> observer) override;
  void Shutdown(ShutdownCallback callback) override;

  // For testing.
  size_t browser_context_count() const { return browser_contexts_.size(); }
  bool is_shutting_down() const { return is_shutting_down_; }

 private:
  void OnBrowserContextDestroyed(OWLBrowserContext* context);
  void OnDisconnect();

  const std::string version_;
  const std::string user_data_dir_;
  const uint16_t devtools_port_;
  raw_ptr<OWLContentBrowserContext> content_browser_context_;

  mojo::Receiver<owl::mojom::SessionHost> receiver_{this};
  mojo::Remote<owl::mojom::SessionObserver> observer_;
  std::vector<std::unique_ptr<OWLBrowserContext>> browser_contexts_;
  bool is_shutting_down_ = false;

  // Must be last member.
  base::WeakPtrFactory<OWLBrowserImpl> weak_factory_{this};
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_BROWSER_IMPL_H_
