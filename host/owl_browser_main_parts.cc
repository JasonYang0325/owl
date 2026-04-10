// Copyright 2026 AntlerAI. All rights reserved.

#include "third_party/owl/host/owl_browser_main_parts.h"

#include "base/command_line.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_socket_factory.h"
#include "net/base/net_errors.h"
#include "net/log/net_log_source.h"
#include "net/socket/tcp_server_socket.h"
#include "third_party/owl/host/owl_content_browser_context.h"
#include "ui/display/display.h"
#include "ui/display/screen.h"
#include "ui/display/screen_base.h"

// Defined in owl_real_web_contents.mm.
extern "C" void OWLRealWebContents_Init(content::BrowserContext* context);

namespace owl {

namespace {

class OWLDevToolsSocketFactory : public content::DevToolsSocketFactory {
 public:
  explicit OWLDevToolsSocketFactory(uint16_t port) : port_(port) {}
 private:
  std::unique_ptr<net::ServerSocket> CreateForHttpServer() override {
    auto socket = std::make_unique<net::TCPServerSocket>(nullptr, net::NetLogSource());
    if (socket->ListenWithAddressAndPort("127.0.0.1", port_, 10) != net::OK)
      return nullptr;
    return socket;
  }
  std::unique_ptr<net::ServerSocket> CreateForTethering(std::string*) override {
    return nullptr;
  }
  uint16_t port_;
};

}  // namespace

OWLBrowserMainParts::OWLBrowserMainParts() = default;
OWLBrowserMainParts::~OWLBrowserMainParts() = default;

int OWLBrowserMainParts::PreMainMessageLoopRun() {
  // Screen must exist before WebContents creation
  // (RenderWidgetHostViewMac requires display::Screen::Get()).
  if (!display::Screen::HasScreen()) {
    screen_ = std::make_unique<display::ScreenBase>();
    // Display must match actual screen's device_scale_factor. A mismatch
    // (e.g. 1.0 here vs 2.0 on the offscreen window) causes the compositor
    // to allocate surfaces at the wrong size, leading to SEGV in the GPU
    // process when committing CA layers with inconsistent dimensions.
    // Default to 2.0 (all Macs since 2018 are Retina).
    display::Display display(1, gfx::Rect(0, 0, 2560, 1600));
    display.set_device_scale_factor(2.0);
    screen_->display_list().AddDisplay(
        display, display::DisplayList::Type::PRIMARY);
    display::Screen::SetScreenInstance(screen_.get());
  }

  browser_context_ =
      std::make_unique<OWLContentBrowserContext>(/*off_the_record=*/false);

  OWLRealWebContents_Init(browser_context_.get());

  // Start DevTools remote debugging if --remote-debugging-port is set.
  const auto& cmd = *base::CommandLine::ForCurrentProcess();
  if (cmd.HasSwitch("remote-debugging-port")) {
    uint16_t port = 0;
    unsigned tmp = 0;
    base::StringToUint(cmd.GetSwitchValueASCII("remote-debugging-port"),
                        &tmp);
    port = static_cast<uint16_t>(tmp);
    if (port > 0) {
      content::DevToolsAgentHost::StartRemoteDebuggingServer(
          std::make_unique<OWLDevToolsSocketFactory>(port),
          browser_context_->GetPath(), base::FilePath());
      LOG(INFO) << "[OWL] DevTools listening on http://127.0.0.1:" << port;
    }
  }

  LOG(INFO) << "[OWL] BrowserMainParts ready (real rendering enabled)";
  return 0;
}

void OWLBrowserMainParts::PostMainMessageLoopRun() {
  LOG(INFO) << "[OWL] BrowserMainParts shutting down";
  browser_context_.reset();
  if (screen_) {
    display::Screen::SetScreenInstance(nullptr);
    screen_.reset();
  }
}

}  // namespace owl
