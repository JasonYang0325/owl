// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_HOST_OWL_WEB_CONTENTS_H_
#define THIRD_PARTY_OWL_HOST_OWL_WEB_CONTENTS_H_

#include <cstdint>
#include <optional>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "third_party/owl/mojom/web_view.mojom.h"
#include "url/gurl.h"

namespace owl {

class OWLBrowserContext;
class OWLHistoryService;

// Global pointer to the active history service (set by OWLBrowserContext
// when GetHistoryServiceRaw() is called, cleared on context destruction).
// Used by RealWebContents for visit recording in DidFinishNavigation.
inline OWLHistoryService* g_owl_history_service = nullptr;

// Function pointer for real navigation (injected by host_content).
// When set, Navigate() delegates to this instead of the stub.
// Parameters: url, observer remote (for PageInfo/RenderSurface callbacks).
// History recording uses g_owl_history_service global instead of a parameter.
using RealNavigateFunc = void (*)(
    const GURL& url,
    mojo::Remote<owl::mojom::WebViewObserver>* observer);
inline RealNavigateFunc g_real_navigate_func = nullptr;

// Function pointer for real viewport resize (injected by host_content).
using RealResizeFunc = void (*)(const gfx::Size& dip_size,
                                 float device_scale_factor);
inline RealResizeFunc g_real_resize_func = nullptr;

// Function pointers for real input event injection (injected by host_content).
// Fire-and-forget: no return value, no callback.
using RealMouseEventFunc = void (*)(owl::mojom::MouseEventPtr event);
using RealKeyEventFunc = void (*)(owl::mojom::KeyEventPtr event);
using RealWheelEventFunc = void (*)(owl::mojom::WheelEventPtr event);
inline RealMouseEventFunc g_real_mouse_event_func = nullptr;
inline RealKeyEventFunc g_real_key_event_func = nullptr;
inline RealWheelEventFunc g_real_wheel_event_func = nullptr;

// Function pointer for real JS evaluation (injected by host_content).
using RealEvalJSFunc = void (*)(
    const std::string& expression,
    base::OnceCallback<void(const std::string& result, int32_t result_type)> callback);
inline RealEvalJSFunc g_real_eval_js_func = nullptr;

// Function pointers for real IME operations (injected by host_content).
using RealImeSetCompositionFunc = void (*)(const std::string& text,
                                            int sel_start, int sel_end,
                                            int repl_start, int repl_end);
using RealImeCommitTextFunc = void (*)(const std::string& text,
                                        int repl_start, int repl_end);
using RealImeFinishComposingFunc = void (*)();
inline RealImeSetCompositionFunc g_real_ime_set_composition_func = nullptr;
inline RealImeCommitTextFunc g_real_ime_commit_text_func = nullptr;
inline RealImeFinishComposingFunc g_real_ime_finish_composing_func = nullptr;

// Function pointers for navigation history (injected by host_content).
// Fire-and-forget: void return. Caller relies on OnPageInfoChanged for state updates.
using RealGoBackFunc = void (*)();
using RealGoForwardFunc = void (*)();
using RealReloadFunc = void (*)();
using RealStopFunc = void (*)();
inline RealGoBackFunc g_real_go_back_func = nullptr;
inline RealGoForwardFunc g_real_go_forward_func = nullptr;
inline RealReloadFunc g_real_reload_func = nullptr;
inline RealStopFunc g_real_stop_func = nullptr;

// Detach observer from RealWebContents to prevent UAF on Close/disconnect.
using RealDetachObserverFunc = void (*)();
inline RealDetachObserverFunc g_real_detach_observer_func = nullptr;

// Phase 33: Find-in-Page function pointers.
// RealFindFunc returns request_id synchronously; OWLWebContents wraps Mojo callback.
using RealFindFunc = int32_t (*)(std::string query,
                                  bool forward,
                                  bool match_case);
inline RealFindFunc g_real_find_func = nullptr;

// StopFinding: uses Mojom enum value as int32_t (mapping done in dispatch layer).
using RealStopFindingFunc = void (*)(int32_t action);
inline RealStopFindingFunc g_real_stop_finding_func = nullptr;

// Sync observer reference to RealWebContents (e.g. after SetObserver).
using RealUpdateObserverFunc = void (*)(
    mojo::Remote<owl::mojom::WebViewObserver>* observer);
inline RealUpdateObserverFunc g_real_update_observer_func = nullptr;

// Phase 34: Zoom control function pointers.
// Set zoom: fire-and-forget (Chromium applies synchronously, callback is Mojo ack).
using RealSetZoomFunc = void (*)(double level);
inline RealSetZoomFunc g_real_set_zoom_func = nullptr;

// Get zoom: synchronous return of current level.
using RealGetZoomFunc = double (*)();
inline RealGetZoomFunc g_real_get_zoom_func = nullptr;

// Currently active webview_id for Real* function dispatch.
// Set via base::AutoReset in each OWLWebContents method before calling g_real_*.
// UI thread only — no atomic needed.
inline uint64_t g_active_webview_id = 0;

// Function pointer for notifying the observer of a pending permission request.
// Injected by host_content (RealWebContents). Called by OWLPermissionManager
// when a permission with status ASK is encountered in RequestPermissions().
using RealNotifyPermissionFunc = void (*)(const std::string& origin,
                                          int permission_type,
                                          uint64_t request_id);
inline RealNotifyPermissionFunc g_real_notify_permission_func = nullptr;

// Function pointer for resolving a pending permission request.
// Injected by host_content (OWLPermissionManager setup).
// Parameters: request_id (from OnPermissionRequest), granted (true=GRANTED,
// false=DENIED).
// Called by OWLWebContents::RespondToPermissionRequest.
using RealRespondToPermissionFunc = void (*)(uint64_t request_id, bool granted);
inline RealRespondToPermissionFunc g_real_respond_to_permission_func = nullptr;

// Phase 4: Function pointer for resolving a pending SSL error.
// Injected by host_content (RealWebContents).
// Parameters: error_id (from OnSSLError), proceed (true=allow+reload,
// false=stay on error page).
using RealRespondToSSLErrorFunc = void (*)(uint64_t error_id, bool proceed);
inline RealRespondToSSLErrorFunc g_real_respond_to_ssl_error_func = nullptr;

// Phase 3 HTTP Auth: Function pointer for notifying observer of an auth challenge.
// Injected by host_content (RealWebContents).
// Called by OWLContentBrowserClient::CreateLoginDelegate.
class OWLLoginDelegate;
using RealNotifyAuthFunc = void (*)(const std::string& url,
                                     const std::string& realm,
                                     const std::string& scheme,
                                     uint64_t auth_id,
                                     bool is_proxy,
                                     base::WeakPtr<OWLLoginDelegate> delegate);
inline RealNotifyAuthFunc g_real_notify_auth_func = nullptr;

// Phase 3 HTTP Auth: Function pointer for resolving a pending auth challenge.
// Injected by host_content (RealWebContents).
// Parameters: auth_id (from OnAuthRequired), username (nullptr = cancel),
// password (nullptr = cancel).
using RealRespondToAuthFunc = void (*)(uint64_t auth_id,
                                       const std::string* username,
                                       const std::string* password);
inline RealRespondToAuthFunc g_real_respond_to_auth_func = nullptr;

// Context menu: Execute a context menu action.
// payload: optional string for kOpenLinkInNewTab (link URL) and kSearch
// (selection text). Empty string for actions that don't need payload.
using RealExecuteContextMenuActionFunc = void (*)(int32_t action,
                                                   uint32_t menu_id,
                                                   const std::string& payload);
inline RealExecuteContextMenuActionFunc g_real_execute_context_menu_action_func =
    nullptr;

// Implements owl.mojom.WebViewHost.
// All methods run on the UI thread.
class OWLWebContents : public owl::mojom::WebViewHost {
 public:
  using ClosedCallback = base::OnceCallback<void(OWLWebContents*)>;

  OWLWebContents(uint64_t webview_id,
                 OWLBrowserContext* browser_context,
                 ClosedCallback closed_callback);

  // Convenience overload for tests (no browser_context).
  OWLWebContents(uint64_t webview_id,
                 ClosedCallback closed_callback);

  ~OWLWebContents() override;

  OWLWebContents(const OWLWebContents&) = delete;
  OWLWebContents& operator=(const OWLWebContents&) = delete;

  // Binds this implementation to a Mojo receiver.
  void Bind(mojo::PendingReceiver<owl::mojom::WebViewHost> receiver);

  // Sets the observer (from CreateWebView).
  void SetInitialObserver(
      mojo::PendingRemote<owl::mojom::WebViewObserver> observer);

  // owl::mojom::WebViewHost:
  void Navigate(const GURL& url, NavigateCallback callback) override;
  void GoBack(GoBackCallback callback) override;
  void GoForward(GoForwardCallback callback) override;
  void Reload(ReloadCallback callback) override;
  void Stop(StopCallback callback) override;
  void GetPageContent(GetPageContentCallback callback) override;
  void GetPageInfo(GetPageInfoCallback callback) override;
  void UpdateViewGeometry(const gfx::Size& size_in_dips,
                          float device_scale_factor,
                          UpdateViewGeometryCallback callback) override;
  void SetVisible(bool visible, SetVisibleCallback callback) override;
  void SendMouseEvent(owl::mojom::MouseEventPtr event) override;
  void SendKeyEvent(owl::mojom::KeyEventPtr event) override;
  void SendWheelEvent(owl::mojom::WheelEventPtr event) override;
  void EvaluateJavaScript(const std::string& expression,
                          EvaluateJavaScriptCallback callback) override;
  void SendImeSetComposition(const std::string& text,
                             int32_t selection_start, int32_t selection_end,
                             int32_t replacement_start,
                             int32_t replacement_end) override;
  void SendImeCommitText(const std::string& text,
                         int32_t replacement_start,
                         int32_t replacement_end) override;
  void SendImeFinishComposing() override;
  void Find(const std::string& query,
            bool forward,
            bool match_case,
            FindCallback callback) override;
  void StopFinding(owl::mojom::StopFindAction action) override;
  void SetZoomLevel(double level, SetZoomLevelCallback callback) override;
  void GetZoomLevel(GetZoomLevelCallback callback) override;
  void RespondToPermissionRequest(
      uint64_t request_id,
      owl::mojom::PermissionStatus status) override;
  void RespondToSSLError(uint64_t error_id, bool proceed) override;
  void RespondToAuthChallenge(
      uint64_t auth_id,
      const std::optional<std::string>& username,
      const std::optional<std::string>& password) override;
  void ExecuteContextMenuAction(
      owl::mojom::ContextMenuAction action,
      uint32_t menu_id,
      const std::optional<std::string>& payload) override;
  void SetObserver(
      mojo::PendingRemote<owl::mojom::WebViewObserver> observer) override;
  void SetActive(bool active) override;
  void Close(CloseCallback callback) override;

  // Validates a URL for navigation. Returns true if allowed.
  static bool IsUrlAllowed(const GURL& url);

  // Validates view geometry parameters. Returns true if valid.
  // Rejects NaN, Inf, and out-of-range values.
  static bool IsGeometryValid(const gfx::Size& size, float scale_factor);

  uint64_t webview_id() const { return webview_id_; }

 private:
  void OnDisconnect();

  const uint64_t webview_id_;
  raw_ptr<OWLBrowserContext> browser_context_;
  ClosedCallback closed_callback_;
  mojo::Receiver<owl::mojom::WebViewHost> receiver_{this};
  mojo::Remote<owl::mojom::WebViewObserver> observer_;

  // Guard against double detach (OnDisconnect/Close/~OWLWebContents).
  bool detached_ = false;

  // Current state.
  GURL current_url_;
  std::string title_;
  bool is_loading_ = false;
  bool is_visible_ = true;
  gfx::Size view_size_;
  float device_scale_factor_ = 1.0f;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_WEB_CONTENTS_H_
