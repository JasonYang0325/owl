// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/owl/host/owl_web_contents.h"

#include <cmath>

#include "base/auto_reset.h"
#include "base/command_line.h"
#include "base/logging.h"
#include "base/json/json_reader.h"
#include "base/task/sequenced_task_runner.h"
#include "third_party/owl/host/owl_browser_context.h"
#include "third_party/owl/mojom/owl_input_types.mojom.h"
#include "third_party/owl/mojom/owl_types.mojom.h"

namespace owl {

namespace {

constexpr int kMaxDimension = 16384;
constexpr float kMinScaleFactor = 0.5f;
constexpr float kMaxScaleFactor = 4.0f;
constexpr size_t kMaxDataUrlSize = 2 * 1024 * 1024;  // 2MB

constexpr const char* kAllowedSchemes[] = {"https", "http", "data"};
// Defense-in-depth: explicitly block dangerous schemes even though the
// allowlist already rejects them. This prevents regressions if someone
// accidentally adds a dangerous scheme to kAllowedSchemes.
constexpr const char* kBlockedSchemes[] = {"file", "chrome", "devtools",
                                           "javascript", "blob"};

}  // namespace

OWLWebContents::OWLWebContents(uint64_t webview_id,
                               OWLBrowserContext* browser_context,
                               ClosedCallback closed_callback)
    : webview_id_(webview_id),
      browser_context_(browser_context),
      closed_callback_(std::move(closed_callback)) {}

OWLWebContents::OWLWebContents(uint64_t webview_id,
                               ClosedCallback closed_callback)
    : OWLWebContents(webview_id, nullptr, std::move(closed_callback)) {}

OWLWebContents::~OWLWebContents() {
  if (!detached_) {
    detached_ = true;
    base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
    if (g_real_detach_observer_func) {
      g_real_detach_observer_func();
    }
  }
}

void OWLWebContents::Bind(
    mojo::PendingReceiver<owl::mojom::WebViewHost> receiver) {
  receiver_.Bind(std::move(receiver));
  receiver_.set_disconnect_handler(base::BindOnce(
      &OWLWebContents::OnDisconnect, base::Unretained(this)));
}

void OWLWebContents::OnDisconnect() {
  if (!detached_) {
    detached_ = true;
    base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
    // Detach observer from RealWebContents to prevent UAF.
    if (g_real_detach_observer_func) {
      g_real_detach_observer_func();
    }
  }
  // Client dropped the remote — notify parent for cleanup.
  observer_.reset();
  if (closed_callback_) {
    std::move(closed_callback_).Run(this);
  }
}

void OWLWebContents::SetInitialObserver(
    mojo::PendingRemote<owl::mojom::WebViewObserver> observer) {
  observer_.Bind(std::move(observer));
}

// static
bool OWLWebContents::IsUrlAllowed(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }

  // Check blocked schemes first.
  for (const char* blocked : kBlockedSchemes) {
    if (url.SchemeIs(blocked)) {
      return false;
    }
  }

  // Check allowed schemes.
  for (const char* allowed : kAllowedSchemes) {
    if (url.SchemeIs(allowed)) {
      // Special case: data URLs have a size limit.
      if (url.SchemeIs("data") && url.spec().size() > kMaxDataUrlSize) {
        return false;
      }
      return true;
    }
  }

  return false;
}

// static
bool OWLWebContents::IsGeometryValid(const gfx::Size& size,
                                     float scale_factor) {
  if (!std::isfinite(scale_factor)) {
    return false;
  }
  if (size.width() < 1 || size.height() < 1) {
    return false;
  }
  if (size.width() > kMaxDimension || size.height() > kMaxDimension) {
    return false;
  }
  if (scale_factor < kMinScaleFactor || scale_factor > kMaxScaleFactor) {
    return false;
  }
  return true;
}

void OWLWebContents::Navigate(const GURL& url, NavigateCallback callback) {
  if (!IsUrlAllowed(url)) {
    auto result = owl::mojom::NavigationResult::New();
    result->success = false;
    result->http_status_code = 0;
    result->error_description = "URL scheme not allowed";
    std::move(callback).Run(std::move(result));
    return;
  }

  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  current_url_ = url;
  is_loading_ = true;

  // If real navigation is available (injected by host_content), delegate to it.
  // History recording uses the global g_owl_history_service (set by
  // OWLBrowserContext::GetHistoryServiceRaw) instead of a parameter.
  if (g_real_navigate_func && observer_) {
    g_real_navigate_func(url, &observer_);
    // Real implementation will push accurate PageInfo via DidFinishNavigation
    // -> NotifyPageInfo() -> observer. Don't send stub PageInfo here --
    // it would incorrectly set can_go_back=false even when history exists.
  } else if (observer_) {
    // Stub mode: send synthetic PageInfo (no real NavigationController).
    auto info = owl::mojom::PageInfo::New();
    info->url = current_url_.spec();
    info->title = title_;
    info->is_loading = is_loading_;
    info->can_go_back = false;
    info->can_go_forward = false;
    observer_->OnPageInfoChanged(std::move(info));
  }

  auto result = owl::mojom::NavigationResult::New();
  result->success = true;
  result->http_status_code = 200;
  std::move(callback).Run(std::move(result));
}

void OWLWebContents::GoBack(GoBackCallback callback) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_go_back_func) {
    g_real_go_back_func();
  }
  std::move(callback).Run();
}

void OWLWebContents::GoForward(GoForwardCallback callback) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_go_forward_func) {
    g_real_go_forward_func();
  }
  std::move(callback).Run();
}

void OWLWebContents::Reload(ReloadCallback callback) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_reload_func) {
    g_real_reload_func();
  }
  std::move(callback).Run();
}

void OWLWebContents::Stop(StopCallback callback) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_stop_func) {
    g_real_stop_func();
    // Real mode: is_loading state updated by RealWebContents::Stop() ->
    // NotifyPageInfo(). Don't set is_loading_ here -- it would conflict.
  } else {
    is_loading_ = false;  // Stub mode only.
  }
  std::move(callback).Run();
}

void OWLWebContents::GetPageContent(GetPageContentCallback callback) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  // Reuse existing g_real_eval_js_func -- no need for a dedicated function pointer.
  if (g_real_eval_js_func) {
    g_real_eval_js_func(
        "document.body ? document.body.innerText : ''",
        base::BindOnce(
            [](GetPageContentCallback cb,
               const std::string& result, int32_t result_type) {
              std::string text;
              if (result_type == 0 && !result.empty()) {
                // RealEvaluateJS returns base::Value serialized via WriteJson.
                // For a string value, this is a JSON-quoted string.
                // Use JSONReader to properly unescape.
                auto parsed = base::JSONReader::Read(result,
                    base::JSON_PARSE_RFC);
                if (parsed && parsed->is_string()) {
                  text = parsed->GetString();
                } else {
                  text = result;  // Fallback: return raw if not JSON string.
                }
              }
              std::move(cb).Run(text);
            },
            std::move(callback)));
    return;
  }
  std::move(callback).Run(std::string());
}

void OWLWebContents::GetPageInfo(GetPageInfoCallback callback) {
  auto info = owl::mojom::PageInfo::New();
  info->url = current_url_.spec();
  info->title = title_;
  info->is_loading = is_loading_;
  info->can_go_back = false;
  info->can_go_forward = false;
  std::move(callback).Run(std::move(info));
}

void OWLWebContents::UpdateViewGeometry(
    const gfx::Size& size_in_dips,
    float device_scale_factor,
    UpdateViewGeometryCallback callback) {
  if (!IsGeometryValid(size_in_dips, device_scale_factor)) {
    std::move(callback).Run();
    return;
  }

  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  view_size_ = size_in_dips;
  device_scale_factor_ = device_scale_factor;

  // Delegate to real WebContents for actual resize.
  if (g_real_resize_func) {
    g_real_resize_func(size_in_dips, device_scale_factor);
  }

  std::move(callback).Run();
}

void OWLWebContents::SendMouseEvent(owl::mojom::MouseEventPtr event) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_mouse_event_func) {
    g_real_mouse_event_func(std::move(event));
  }
}

void OWLWebContents::SendKeyEvent(owl::mojom::KeyEventPtr event) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_key_event_func) {
    g_real_key_event_func(std::move(event));
  }
}

void OWLWebContents::SendWheelEvent(owl::mojom::WheelEventPtr event) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_wheel_event_func) {
    g_real_wheel_event_func(std::move(event));
  }
}

void OWLWebContents::SendImeSetComposition(
    const std::string& text,
    int32_t selection_start, int32_t selection_end,
    int32_t replacement_start, int32_t replacement_end) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_ime_set_composition_func) {
    g_real_ime_set_composition_func(text, selection_start, selection_end,
                                    replacement_start, replacement_end);
  }
}

void OWLWebContents::SendImeCommitText(
    const std::string& text,
    int32_t replacement_start, int32_t replacement_end) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_ime_commit_text_func) {
    g_real_ime_commit_text_func(text, replacement_start, replacement_end);
  }
}

void OWLWebContents::SendImeFinishComposing() {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_ime_finish_composing_func) {
    g_real_ime_finish_composing_func();
  }
}

void OWLWebContents::Find(const std::string& query,
                           bool forward,
                           bool match_case,
                           FindCallback callback) {
  // Empty string guard -- Chromium Find does not accept empty queries.
  if (query.empty()) {
    std::move(callback).Run(0);
    return;
  }
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_find_func) {
    // Function pointer returns request_id synchronously.
    int32_t request_id = g_real_find_func(std::string(query), forward, match_case);
    std::move(callback).Run(request_id);
    return;
  }
  // Stub: return request_id = 0, no real find.
  std::move(callback).Run(0);
}

void OWLWebContents::StopFinding(owl::mojom::StopFindAction action) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (!g_real_stop_finding_func) return;
  // Explicit switch-case per project convention (no static_cast for enums).
  int32_t act;
  switch (action) {
    case owl::mojom::StopFindAction::kClearSelection:     act = 0; break;
    case owl::mojom::StopFindAction::kKeepSelection:      act = 1; break;
    case owl::mojom::StopFindAction::kActivateSelection:  act = 2; break;
  }
  g_real_stop_finding_func(act);
}

void OWLWebContents::SetVisible(bool visible, SetVisibleCallback callback) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  is_visible_ = visible;
  std::move(callback).Run();
}

void OWLWebContents::EvaluateJavaScript(
    const std::string& expression,
    EvaluateJavaScriptCallback callback) {
  // BH-021: Gate on --enable-owl-test-js command line switch only.
  // Environment variable check removed for security (env vars are inherited
  // by child processes and harder to audit).
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch(
          "enable-owl-test-js")) {
    std::move(callback).Run(
        "EvaluateJavaScript requires --enable-owl-test-js",
        /*result_type=*/1);
    return;
  }
  if (expression.size() > 1024 * 1024) {
    std::move(callback).Run("Expression too large (>1MB)",
                            /*result_type=*/1);
    return;
  }
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_eval_js_func) {
    g_real_eval_js_func(expression, std::move(callback));
  } else {
    std::move(callback).Run("Not supported (no real WebContents)",
                            /*result_type=*/1);
  }
}

void OWLWebContents::SetZoomLevel(double level,
                                   SetZoomLevelCallback callback) {
  if (!std::isfinite(level)) {
    std::move(callback).Run();
    return;
  }
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_set_zoom_func) {
    g_real_set_zoom_func(level);
  }
  std::move(callback).Run();
}

void OWLWebContents::GetZoomLevel(GetZoomLevelCallback callback) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  double level = 0.0;
  if (g_real_get_zoom_func) {
    level = g_real_get_zoom_func();
  }
  std::move(callback).Run(level);
}

void OWLWebContents::RespondToPermissionRequest(
    uint64_t request_id,
    owl::mojom::PermissionStatus status) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_respond_to_permission_func) {
    bool granted = (status == owl::mojom::PermissionStatus::kGranted);
    g_real_respond_to_permission_func(request_id, granted);
  } else {
    LOG(WARNING) << "OWLWebContents::RespondToPermissionRequest: "
                 << "request_id=" << request_id
                 << " status=" << static_cast<int>(status)
                 << " (no permission handler registered)";
  }
}

void OWLWebContents::RespondToSSLError(uint64_t error_id, bool proceed) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_respond_to_ssl_error_func) {
    g_real_respond_to_ssl_error_func(error_id, proceed);
  } else {
    LOG(WARNING) << "OWLWebContents::RespondToSSLError: "
                 << "error_id=" << error_id
                 << " proceed=" << proceed
                 << " (no SSL error handler registered)";
  }
}

void OWLWebContents::RespondToAuthChallenge(
    uint64_t auth_id,
    const std::optional<std::string>& username,
    const std::optional<std::string>& password) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_respond_to_auth_func) {
    if (username.has_value()) {
      const std::string empty_password;
      const std::string* pw_ptr =
          password.has_value() ? &password.value() : &empty_password;
      g_real_respond_to_auth_func(auth_id, &username.value(), pw_ptr);
    } else {
      // Cancel: pass nullptr for both.
      g_real_respond_to_auth_func(auth_id, nullptr, nullptr);
    }
  } else {
    LOG(WARNING) << "OWLWebContents::RespondToAuthChallenge: "
                 << "auth_id=" << auth_id
                 << " (no auth handler registered)";
  }
}

void OWLWebContents::ExecuteContextMenuAction(
    owl::mojom::ContextMenuAction action,
    uint32_t menu_id,
    const std::optional<std::string>& payload) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_execute_context_menu_action_func) {
    g_real_execute_context_menu_action_func(static_cast<int32_t>(action),
                                            menu_id,
                                            payload.value_or(std::string()));
  } else {
    LOG(INFO) << "OWLWebContents::ExecuteContextMenuAction: action="
              << static_cast<int>(action)
              << " menu_id=" << menu_id
              << " (no real impl, no-op)";
  }
}

void OWLWebContents::SetObserver(
    mojo::PendingRemote<owl::mojom::WebViewObserver> observer) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  observer_.reset();
  if (observer.is_valid()) {
    observer_.Bind(std::move(observer));
  }
  // Sync to RealWebContents so it uses the new (or null) observer.
  if (g_real_update_observer_func) {
    g_real_update_observer_func(&observer_);
  }
}

void OWLWebContents::SetActive(bool active) {
  // Phase 1: Log the active state change. Full input routing will be
  // implemented when per-instance RealWebContents is wired up.
  DVLOG(1) << "[OWL] WebViewHost::SetActive(" << active << ")";
  // TODO(Phase 2): Route input focus to this WebView's RealWebContents.
}

void OWLWebContents::Close(CloseCallback callback) {
  if (!detached_) {
    detached_ = true;
    base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
    // Detach observer from RealWebContents to prevent UAF.
    // RealWebContents may outlive this OWLWebContents (e.g. timer callbacks,
    // DidFinishNavigation, cursor swizzle) and would otherwise dereference
    // a dangling observer_ pointer.
    if (g_real_detach_observer_func) {
      g_real_detach_observer_func();
    }
  }

  observer_.reset();

  // Send callback before resetting receiver (pipe must still be connected).
  std::move(callback).Run();

  // Clear disconnect handler before reset to avoid double-triggering.
  receiver_.set_disconnect_handler(base::OnceClosure());
  receiver_.reset();

  // Notify parent (BrowserContext) that we're closed.
  if (closed_callback_) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(std::move(closed_callback_), this));
  }
}

}  // namespace owl
