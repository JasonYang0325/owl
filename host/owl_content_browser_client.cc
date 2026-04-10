// Copyright 2026 AntlerAI. All rights reserved.

#include "third_party/owl/host/owl_content_browser_client.h"

#include "base/command_line.h"
#include "base/logging.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/devtools_manager_delegate.h"
#include "content/public/browser/global_request_id.h"
#include "net/base/auth.h"
#include "net/http/http_response_headers.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "third_party/owl/host/owl_browser_impl.h"
#include "third_party/owl/host/owl_browser_main_parts.h"
#include "third_party/owl/host/owl_content_browser_context.h"
#include "third_party/owl/host/owl_login_delegate.h"
#include "third_party/owl/host/owl_web_contents.h"
#include "third_party/owl/mojom/session.mojom.h"

namespace owl {

OWLContentBrowserClient::OWLContentBrowserClient() = default;
OWLContentBrowserClient::~OWLContentBrowserClient() = default;

std::unique_ptr<content::BrowserMainParts>
OWLContentBrowserClient::CreateBrowserMainParts(bool is_integration_test) {
  auto parts = std::make_unique<OWLBrowserMainParts>();
  browser_main_parts_ = parts.get();
  return parts;
}

void OWLContentBrowserClient::BindBrowserControlInterface(
    mojo::ScopedMessagePipeHandle pipe) {
  if (!pipe.is_valid()) {
    LOG(INFO) << "No Mojo pipe from parent — running standalone";
    return;
  }

  const auto* cmd = base::CommandLine::ForCurrentProcess();
  std::string user_data_dir = cmd->GetSwitchValueASCII("user-data-dir");
  uint16_t devtools_port = 0;
  std::string port_str = cmd->GetSwitchValueASCII("devtools-port");
  if (!port_str.empty()) {
    devtools_port = static_cast<uint16_t>(std::atoi(port_str.c_str()));
  }

  OWLContentBrowserContext* content_ctx =
      browser_main_parts_ ? browser_main_parts_->browser_context() : nullptr;
  browser_impl_ = std::make_unique<OWLBrowserImpl>(
      "1.0.0", user_data_dir, devtools_port, content_ctx);
  browser_impl_->Bind(
      mojo::PendingReceiver<owl::mojom::SessionHost>(std::move(pipe)));

  LOG(INFO) << "[OWL] Host bound to parent process Mojo pipe";
}

std::unique_ptr<content::DevToolsManagerDelegate>
OWLContentBrowserClient::CreateDevToolsManagerDelegate() {
  return std::make_unique<content::DevToolsManagerDelegate>();
}

void OWLContentBrowserClient::ConfigureNetworkContextParams(
    content::BrowserContext* context,
    bool in_memory,
    const base::FilePath& relative_partition_path,
    network::mojom::NetworkContextParams* network_context_params,
    cert_verifier::mojom::CertVerifierCreationParams*
        cert_verifier_creation_params) {
  // Minimal configuration — required for network service to function.
  // Without this, the network service process crashes on first request.
  network_context_params->user_agent = "OWL/1.0";
  network_context_params->accept_language = "en-US,en";
}

std::vector<base::FilePath>
OWLContentBrowserClient::GetNetworkContextsParentDirectory() {
  // Return the browser context path so Chromium can manage network cache.
  if (browser_main_parts_ && browser_main_parts_->browser_context()) {
    return {browser_main_parts_->browser_context()->GetPath()};
  }
  return {};
}

std::unique_ptr<content::LoginDelegate>
OWLContentBrowserClient::CreateLoginDelegate(
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
        auth_required_callback) {
  // Only handle main frame navigation auth challenges.
  if (!is_request_for_primary_main_frame_navigation) {
    return nullptr;
  }

  // Generate a unique auth_id for this challenge.
  static uint64_t next_auth_id = 1;
  uint64_t auth_id = next_auth_id++;

  LOG(INFO) << "[OWL] CreateLoginDelegate auth_id=" << auth_id
            << " realm=\"" << auth_info.realm << "\""
            << " scheme=" << auth_info.scheme
            << " is_proxy=" << auth_info.is_proxy
            << " host=" << url.host();

  auto delegate = std::make_unique<OWLLoginDelegate>(
      std::move(auth_required_callback), auth_id);

  // Notify observer via the function pointer mechanism.
  // RealWebContents registers the auth challenge and notifies the Mojo observer.
  if (g_real_notify_auth_func) {
    g_real_notify_auth_func(
        url.spec(), auth_info.realm, auth_info.scheme,
        auth_id, auth_info.is_proxy, delegate->GetWeakPtr());
  }

  return delegate;
}

}  // namespace owl
