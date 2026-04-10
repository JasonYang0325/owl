// Copyright 2026 AntlerAI. All rights reserved.

#ifndef THIRD_PARTY_OWL_HOST_OWL_CONTENT_BROWSER_CLIENT_H_
#define THIRD_PARTY_OWL_HOST_OWL_CONTENT_BROWSER_CLIENT_H_

#include <memory>
#include <string>
#include <vector>

#include "content/public/browser/content_browser_client.h"
#include "content/public/browser/login_delegate.h"
#include "services/cert_verifier/public/mojom/cert_verifier_service_factory.mojom-forward.h"
#include "services/network/public/mojom/network_context.mojom-forward.h"

namespace net {
class AuthChallengeInfo;
class HttpResponseHeaders;
}  // namespace net

namespace owl {

class OWLBrowserImpl;
class OWLBrowserMainParts;

class OWLContentBrowserClient : public content::ContentBrowserClient {
 public:
  OWLContentBrowserClient();
  ~OWLContentBrowserClient() override;

  // content::ContentBrowserClient:
  std::unique_ptr<content::BrowserMainParts> CreateBrowserMainParts(
      bool is_integration_test) override;
  std::unique_ptr<content::DevToolsManagerDelegate>
      CreateDevToolsManagerDelegate() override;
  void ConfigureNetworkContextParams(
      content::BrowserContext* context,
      bool in_memory,
      const base::FilePath& relative_partition_path,
      network::mojom::NetworkContextParams* network_context_params,
      cert_verifier::mojom::CertVerifierCreationParams*
          cert_verifier_creation_params) override;
  std::vector<base::FilePath> GetNetworkContextsParentDirectory() override;

  // HTTP Auth: intercept 401/407 challenges and forward to OWL client.
  std::unique_ptr<content::LoginDelegate> CreateLoginDelegate(
      const net::AuthChallengeInfo& auth_info,
      content::WebContents* web_contents,
      content::BrowserContext* browser_context,
      const content::GlobalRequestID& request_id,
      bool is_request_for_primary_main_frame_navigation,
      bool is_request_for_navigation,
      const GURL& url,
      scoped_refptr<net::HttpResponseHeaders> response_headers,
      bool first_auth_attempt,
      content::GuestPageHolder* guest_page_holder,
      content::LoginDelegate::LoginAuthRequiredCallback
          auth_required_callback) override;

  // Called by ContentMainRunnerImpl after MaybeAcceptMojoInvitation().
  // This is THE entry point for receiving the Mojo pipe from parent.
  void BindBrowserControlInterface(
      mojo::ScopedMessagePipeHandle pipe) override;

  OWLBrowserMainParts* browser_main_parts() { return browser_main_parts_; }

 private:
  raw_ptr<OWLBrowserMainParts> browser_main_parts_ = nullptr;
  std::unique_ptr<OWLBrowserImpl> browser_impl_;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_CONTENT_BROWSER_CLIENT_H_
