// Copyright 2026 AntlerAI. All rights reserved.
// Real WebContents creation for OWL Host.
// This file is part of :host_content (has content/ deps).

#include <map>

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include "base/containers/id_map.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/time/time.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/escape.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "components/input/native_web_keyboard_event.h"
#include "content/browser/renderer_host/render_frame_host_impl.h"
#include "content/public/browser/browser_thread.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/platform/platform_handle.h"
#include "third_party/owl/host/owl_context_menu_utils.h"
#include "third_party/owl/host/owl_content_browser_context.h"
#include "third_party/owl/host/owl_history_service.h"
#include "third_party/owl/host/owl_login_delegate.h"
#include "third_party/owl/host/owl_web_contents.h"
#include "third_party/owl/mojom/owl_input_types.mojom.h"
#include "third_party/owl/mojom/owl_types.mojom.h"
#include "third_party/owl/mojom/web_view.mojom.h"
#include "content/public/browser/host_zoom_map.h"
#include "third_party/blink/public/mojom/devtools/console_message.mojom.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "third_party/blink/public/mojom/frame/find_in_page.mojom.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "third_party/blink/public/common/input/web_mouse_wheel_event.h"
#include "ui/events/keycodes/dom/dom_code.h"
#include "ui/events/keycodes/dom/keycode_converter.h"
#include "ui/events/keycodes/keyboard_code_conversion.h"
#include "ui/events/keycodes/keyboard_code_conversion_mac.h"
#include "content/public/browser/download_manager.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/ssl_status.h"
#include "net/base/net_errors.h"
#include "net/cert/cert_status_flags.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "skia/ext/skia_utils_mac.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/clipboard/clipboard.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/base/ime/ime_text_span.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

// Private CALayerHost API for contextId.
@interface CALayerHost : CALayer
@property uint32_t contextId;
@end

namespace owl {

namespace {

content::BrowserContext* g_browser_context = nullptr;

// Forward declare for cursor swizzle.
class RealWebContents;

// IME focus sync: tracks whether we've force-sent SetFocus(true) to the
// renderer for the current webview. Reset on navigation and tab switch.
static bool g_ime_focus_synced = false;
static uint64_t g_ime_focus_webview_id = 0;

// Phase 1 multi-WebView: Map of all live RealWebContents, keyed by webview_id.
// g_active_webview_id (set via AutoReset in OWLWebContents methods) selects
// which instance Real* functions operate on.
base::NoDestructor<base::IDMap<RealWebContents*, uint64_t>>
    g_real_web_contents_map;

// Helper: look up a RealWebContents by the currently active webview_id.
// Returns nullptr if g_active_webview_id is 0 or not found.
RealWebContents* GetActiveRealWebContents() {
  if (g_active_webview_id == 0) return nullptr;
  return g_real_web_contents_map->Lookup(g_active_webview_id);
}

// === Cursor swizzle (one-time install, accesses active RealWebContents via IDMap) ===

static IMP g_original_updateCursor = nullptr;
static bool g_cursor_swizzle_installed = false;

static owl::mojom::CursorType OWLCursorTypeFromNSCursor(NSCursor* cursor) {
  if (cursor == [NSCursor arrowCursor])               return owl::mojom::CursorType::kPointer;
  if (cursor == [NSCursor pointingHandCursor])        return owl::mojom::CursorType::kHand;
  if (cursor == [NSCursor IBeamCursor])               return owl::mojom::CursorType::kIBeam;
  if (cursor == [NSCursor crosshairCursor])           return owl::mojom::CursorType::kCrosshair;
  if (cursor == [NSCursor operationNotAllowedCursor]) return owl::mojom::CursorType::kNotAllowed;
  if (cursor == [NSCursor openHandCursor])            return owl::mojom::CursorType::kGrab;
  if (cursor == [NSCursor closedHandCursor])          return owl::mojom::CursorType::kGrabbing;
  if (cursor == [NSCursor resizeLeftRightCursor])     return owl::mojom::CursorType::kEWResize;
  if (cursor == [NSCursor resizeUpDownCursor])        return owl::mojom::CursorType::kNSResize;
  return owl::mojom::CursorType::kPointer;
}

// Called by swizzled updateCursor: on RenderWidgetHostViewCocoa.
// Declared here, defined after RealWebContents class.
static void OWL_swizzled_updateCursor(id self, SEL _cmd, NSCursor* cursor);

static void InstallCursorSwizzleOnce(NSView* rwhv_cocoa_view) {
  if (g_cursor_swizzle_installed) return;

  Class cls = [rwhv_cocoa_view class];
  SEL sel = @selector(updateCursor:);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    LOG(WARNING) << "[OWL] updateCursor: not found on " << class_getName(cls);
    return;
  }

  g_original_updateCursor = method_getImplementation(method);
  method_setImplementation(method, (IMP)OWL_swizzled_updateCursor);
  g_cursor_swizzle_installed = true;
  LOG(INFO) << "[OWL] Cursor swizzle installed on " << class_getName(cls);
}

// Truncate URL string to fit within 2KB (2048 bytes).
// If truncation is needed, appends "...[truncated]" marker within the limit.
std::string TruncateUrl(const std::string& url) {
  constexpr size_t kMaxUrlLength = 2048;
  constexpr const char kTruncationMarker[] = "...[truncated]";
  if (url.size() <= kMaxUrlLength) return url;
  constexpr size_t kMarkerLen = sizeof(kTruncationMarker) - 1;  // exclude NUL
  return url.substr(0, kMaxUrlLength - kMarkerLen) + kTruncationMarker;
}

// Build a NavigationEvent mojom struct from a NavigationHandle.
owl::mojom::NavigationEventPtr BuildNavigationEvent(
    content::NavigationHandle* handle,
    bool is_redirect,
    int32_t http_status_code) {
  auto event = owl::mojom::NavigationEvent::New();
  event->navigation_id = handle->GetNavigationId();
  event->url = TruncateUrl(handle->GetURL().spec());
  event->is_user_initiated = handle->HasUserGesture();
  event->is_redirect = is_redirect;
  event->http_status_code = http_status_code;
  return event;
}

// Wraps a real content::WebContents with observer for page info and render surface.
class RealWebContents : public content::WebContentsDelegate,
                        public content::WebContentsObserver {
 public:
  RealWebContents(uint64_t wid,
                  const GURL& url,
                  mojo::Remote<owl::mojom::WebViewObserver>* observer,
                  OWLHistoryService* history_service)
      : wid_(wid), observer_(observer), history_service_(history_service) {
    CHECK(g_browser_context) << "Call OWLRealWebContents_Init first";

    content::WebContents::CreateParams params(g_browser_context);
    web_contents_ = content::WebContents::Create(params);
    web_contents_->SetDelegate(this);
    Observe(web_contents_.get());

    web_contents_->Resize(gfx::Rect(0, 0, 1200, 800));

    // Attach native view to an offscreen window so CALayer is activated.
    // Without this, the NSView has no layer (wantsLayer=0) and compositor
    // output won't produce CALayerHost.
    SetupOffscreenWindow();

    content::NavigationController::LoadURLParams load_params(url);
    load_params.transition_type = ui::PAGE_TRANSITION_TYPED;
    web_contents_->GetController().LoadURLWithParams(load_params);

    StartRenderSurfacePolling();

    // Phase 34: Register zoom level change callback.
    zoom_subscription_ = content::HostZoomMap::GetDefaultForBrowserContext(
        g_browser_context)->AddZoomLevelChangedCallback(
        base::BindRepeating(&RealWebContents::OnZoomChanged,
                            base::Unretained(this)));

    // Mark as visible so InputRouter doesn't drop events,
    // and focus so the renderer processes keyboard input.
    EnsureRendererReady();

    LOG(INFO) << "[OWL] Real WebContents created, navigating to " << url.GetWithEmptyPath();
  }

  ~RealWebContents() override {
    render_surface_timer_.Stop();
  }

  uint64_t webview_id() const { return wid_; }

  // Navigate within existing WebContents (preserves history).
  void NavigateTo(const GURL& url) {
    content::NavigationController::LoadURLParams load_params(url);
    load_params.transition_type = ui::PAGE_TRANSITION_TYPED;
    web_contents_->GetController().LoadURLWithParams(load_params);

    // Same-site navigations don't trigger RenderFrameHostChanged, so we
    // need to ensure the renderer is ready here as a fallback.
    EnsureRendererReady();
  }

  // Update observer reference (in case SetObserver was called).
  void UpdateObserver(mojo::Remote<owl::mojom::WebViewObserver>* observer) {
    observer_ = observer;
  }

  // Detach observer to prevent UAF after OWLWebContents destruction.
  void DetachObserver() {
    observer_ = nullptr;
  }

  // Phase 3 HTTP Auth: Register an auth challenge and notify observer.
  void NotifyAuth(const std::string& url, const std::string& realm,
                  const std::string& scheme, uint64_t auth_id,
                  bool is_proxy,
                  base::WeakPtr<OWLLoginDelegate> delegate) {
    // Build failure count key: origin|realm
    GURL gurl(url);
    std::string origin = gurl.DeprecatedGetOriginAsURL().spec();
    std::string count_key = origin + "|" + realm;

    // Check failure count — auto-cancel after kMaxAuthFailures.
    int& count = auth_failure_counts_[count_key];
    if (count >= kMaxAuthFailures) {
      LOG(WARNING) << "[OWL] Auth max failures reached for " << count_key
                   << ", auto-cancelling auth_id=" << auth_id;
      if (delegate) {
        delegate->Cancel();
      }
      return;
    }

    pending_auth_map_[auth_id] = delegate;

    if (observer_ && observer_->is_connected()) {
      (*observer_)->OnAuthRequired(url, realm, scheme, auth_id, is_proxy);
    }
  }

  // Phase 3 HTTP Auth: Respond to a pending auth challenge.
  void RespondToAuth(uint64_t auth_id,
                     const std::string* username,
                     const std::string* password) {
    auto it = pending_auth_map_.find(auth_id);
    if (it == pending_auth_map_.end()) {
      LOG(WARNING) << "[OWL] RespondToAuth unknown auth_id=" << auth_id;
      return;
    }

    auto delegate = it->second;
    pending_auth_map_.erase(it);

    if (!delegate) {
      LOG(WARNING) << "[OWL] RespondToAuth delegate expired, auth_id="
                   << auth_id;
      return;
    }

    if (username) {
      // Submit credentials.
      delegate->Respond(base::UTF8ToUTF16(*username),
                        base::UTF8ToUTF16(password ? *password : ""));
    } else {
      // Cancel.
      delegate->Cancel();
    }
  }

  void GoBack() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_->GetController().CanGoBack()) return;
    web_contents_->GetController().GoBack();
  }

  void GoForward() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_->GetController().CanGoForward()) return;
    web_contents_->GetController().GoForward();
  }

  void Reload() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    web_contents_->GetController().Reload(content::ReloadType::NORMAL, false);
  }

  void Stop() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    web_contents_->Stop();
    NotifyPageInfo();  // Update is_loading state immediately via observer.
  }

  // WebContentsObserver:
  void TitleWasSet(content::NavigationEntry* entry) override {
    NotifyPageInfo();
  }

  void DidFinishNavigation(content::NavigationHandle* handle) override {
    NotifyPageInfo();
    if (handle->IsInPrimaryMainFrame() && handle->HasCommitted()) {
      // Navigation may create a new renderer widget — reset IME focus sync
      // so next IME call will force SetFocus(true) to the new renderer.
      g_ime_focus_synced = false;

      // Restart render surface polling — new navigation may create new CAContext.
      render_surface_timer_.Stop();
      last_context_id_ = 0;
      poll_count_ = 0;
      stable_count_ = 0;
      StartRenderSurfacePolling();

      // Navigation committed: notify observer (skip same-document and error pages).
      // Error pages have HasCommitted()=true but should trigger OnNavigationFailed.
      if (!handle->IsSameDocument() && !handle->IsErrorPage() &&
          observer_ && observer_->is_connected()) {
        int32_t status_code = 0;
        if (handle->GetResponseHeaders()) {
          status_code = handle->GetResponseHeaders()->response_code();
        }
        (*observer_)->OnNavigationCommitted(
            BuildNavigationEvent(handle, /*is_redirect=*/false, status_code));
      }

      // Record visit in history (main frame, committed, non-error only).
      if (!handle->IsErrorPage() && history_service_) {
        const GURL& url = handle->GetURL();
        if (OWLHistoryService::IsUrlAllowed(url)) {
          std::string title;
          if (web_contents_) {
            title = base::UTF16ToUTF8(web_contents_->GetTitle());
          }
          history_service_->AddVisit(
              url.spec(), title,
              base::BindOnce([](bool success) {
                if (!success) {
                  LOG(WARNING) << "[OWL] HistoryService AddVisit failed";
                }
              }));
        }
      }
    }

    // Navigation failed: notify observer (main frame, non-certificate errors).
    // Covers two cases: (1) !HasCommitted (network error), (2) IsErrorPage (committed error page).
    if (handle->IsInPrimaryMainFrame() &&
        (!handle->HasCommitted() || handle->IsErrorPage()) &&
        handle->GetNetErrorCode() != net::OK) {
      // Skip certificate errors — already handled by OnSSLError path.
      if (!net::IsCertificateError(handle->GetNetErrorCode()) &&
          observer_ && observer_->is_connected()) {
        (*observer_)->OnNavigationFailed(
            handle->GetNavigationId(),
            TruncateUrl(handle->GetURL().spec()),
            handle->GetNetErrorCode(),
            net::ErrorToString(handle->GetNetErrorCode()));
      }
    }
  }

  // Phase 28: Fires earlier than DidFinishNavigation when RFH swaps.
  void RenderFrameHostChanged(content::RenderFrameHost* old_host,
                               content::RenderFrameHost* new_host) override {
    if (!new_host || !new_host->IsInPrimaryMainFrame()) return;

    auto* rwhi = content::RenderWidgetHostImpl::From(
        new_host->GetRenderWidgetHost());
    if (!rwhi) return;

    // Re-force input unblocking on the new RWHI.
    web_contents_->WasShown();
    if (rwhi->GetView()) rwhi->GetView()->Focus();
    rwhi->ForceFirstFrameAfterNavigationTimeout();

    // Cancel any previous delayed task, then re-post.
    weak_factory_.InvalidateWeakPtrs();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&RealWebContents::DelayedReForce,
                       weak_factory_.GetWeakPtr()),
        base::Milliseconds(200));

    // Install cursor swizzle on RWHV's cocoa view (one-time).
    if (!g_cursor_swizzle_installed) {
      auto* rwhv = web_contents_->GetRenderWidgetHostView();
      if (rwhv) {
        NSView* cocoa_view = rwhv->GetNativeView().GetNativeNSView();
        if (cocoa_view) {
          InstallCursorSwizzleOnce(cocoa_view);
        }
      }
    }
  }

  void DidFinishLoad(content::RenderFrameHost* rfh,
                     const GURL& validated_url) override {
    if (!rfh->IsInPrimaryMainFrame()) return;
    if (observer_ && observer_->is_connected()) {
      (*observer_)->OnLoadFinished(true);
    }
    NotifyPageInfo();
  }

  void DidFailLoad(content::RenderFrameHost* rfh,
                   const GURL& validated_url,
                   int error_code) override {
    if (!rfh->IsInPrimaryMainFrame()) return;
    if (observer_ && observer_->is_connected()) {
      (*observer_)->OnLoadFinished(false);
    }
  }

  void DidStopLoading() override {
    NotifyPageInfo();  // web_contents_->IsLoading() is now false
  }

  void DidChangeVisibleSecurityState() override {
    if (!observer_ || !observer_->is_connected()) return;

    auto* web_contents = web_contents_.get();
    content::NavigationEntry* entry =
        web_contents->GetController().GetVisibleEntry();
    if (!entry) return;

    // Compute security level: 0=SECURE, 1=NONE/INFO, 3=DANGEROUS
    int32_t level = 1;  // default: NONE/INFO
    const GURL& url = entry->GetURL();
    if (url.SchemeIsCryptographic()) {
      net::CertStatus cert_status = entry->GetSSL().cert_status;
      if (net::IsCertStatusError(cert_status)) {
        level = 3;  // DANGEROUS
      } else {
        level = 0;  // SECURE
      }
    }

    std::string cert_subject;
    std::string error_desc;
    if (entry->GetSSL().certificate) {
      cert_subject =
          entry->GetSSL().certificate->subject().GetDisplayName();
    }

    (*observer_)->OnSecurityStateChanged(level, cert_subject, error_desc);
  }

  // WebContentsObserver: Console message from renderer (main frame only).
  void OnDidAddMessageToConsole(
      content::RenderFrameHost* source_frame,
      blink::mojom::ConsoleMessageLevel log_level,
      const std::u16string& message,
      int32_t line_no,
      const std::u16string& source_id,
      const std::optional<std::u16string>& untrusted_stack_trace) override {
    // 1. Main frame filter.
    if (!source_frame || !source_frame->IsInPrimaryMainFrame()) return;
    if (!observer_ || !observer_->is_connected()) return;

    // 2. Level mapping: blink::mojom::ConsoleMessageLevel → owl::mojom::ConsoleLevel.
    owl::mojom::ConsoleLevel level;
    switch (log_level) {
      case blink::mojom::ConsoleMessageLevel::kVerbose:
        level = owl::mojom::ConsoleLevel::kVerbose;
        break;
      case blink::mojom::ConsoleMessageLevel::kInfo:
        level = owl::mojom::ConsoleLevel::kInfo;
        break;
      case blink::mojom::ConsoleMessageLevel::kWarning:
        level = owl::mojom::ConsoleLevel::kWarning;
        break;
      case blink::mojom::ConsoleMessageLevel::kError:
        level = owl::mojom::ConsoleLevel::kError;
        break;
      default:
        level = owl::mojom::ConsoleLevel::kInfo;
        break;
    }

    // 3. Merge message + stack_trace, truncate to 10KB (UTF-8 safe).
    constexpr size_t kMaxConsoleMessageBytes = 10 * 1024;
    constexpr size_t kMaxSourceBytes = 2 * 1024;
    std::string msg_utf8 = base::UTF16ToUTF8(message);
    if (untrusted_stack_trace.has_value() &&
        !untrusted_stack_trace->empty()) {
      msg_utf8 += "\n";
      msg_utf8 += base::UTF16ToUTF8(*untrusted_stack_trace);
    }
    if (msg_utf8.size() > kMaxConsoleMessageBytes) {
      base::TruncateUTF8ToByteSize(msg_utf8, kMaxConsoleMessageBytes,
                                    &msg_utf8);
    }

    // 4. Build ConsoleMessage.
    auto console_msg = owl::mojom::ConsoleMessage::New();
    console_msg->level = level;
    console_msg->message = std::move(msg_utf8);
    std::string source_utf8 = base::UTF16ToUTF8(source_id);
    if (source_utf8.size() > kMaxSourceBytes) {
      base::TruncateUTF8ToByteSize(source_utf8, kMaxSourceBytes,
                                    &source_utf8);
    }
    console_msg->source = std::move(source_utf8);
    console_msg->line_number = line_no;
    console_msg->timestamp = base::Time::Now().InSecondsFSinceUnixEpoch();

    // 5. Send to observer.
    (*observer_)->OnConsoleMessage(std::move(console_msg));
  }

  content::WebContents* GetWebContents() const { return web_contents_.get(); }

  // WebContentsDelegate: Handle target="_blank" and Cmd+Click links.
  // Phase 3 Multi-tab: NEW_FOREGROUND_TAB / NEW_BACKGROUND_TAB → notify observer
  // to create a new tab. Other dispositions navigate in the current tab.
  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)> callback) override {
    const GURL& url = params.url;

    // Phase 3: New tab dispositions — notify observer instead of navigating.
    if (params.disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB ||
        params.disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB) {
      // URL scheme filter: only allow http/https/data.
      if (!url.is_empty() && (url.SchemeIsHTTPOrHTTPS() ||
                               url.SchemeIs("data"))) {
        bool foreground =
            params.disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB;
        if (observer_ && observer_->is_connected()) {
          (*observer_)->OnNewTabRequested(url.spec(), foreground);
          LOG(INFO) << "[OWL] OpenURLFromTab -> OnNewTabRequested url="
                    << url.scheme() << "://" << url.host()
                    << " foreground=" << foreground;
        }
      } else {
        // Rejected scheme — return nullptr so Chromium knows we did NOT handle
        // this navigation. Returning source would silently swallow the request.
        LOG(WARNING) << "[OWL] OpenURLFromTab rejected URL scheme: "
                     << url.scheme();
        return nullptr;
      }
      // Note: the |callback| parameter is intentionally ignored for new-tab
      // dispositions. We notify the observer to create a fresh tab; we do not
      // produce a NavigationHandle in the current WebContents.
      return nullptr;
    }

    // Default: navigate in current tab (preserves existing behavior).
    // Use LoadURLParams(OpenURLParams) constructor to preserve all fields
    // (initiator, referrer, post_data, extra_headers, redirect_chain, etc.)
    content::NavigationController::LoadURLParams load_params(params);
    auto nav_handle = source->GetController().LoadURLWithParams(load_params);
    if (callback && nav_handle.get()) {
      std::move(callback).Run(*nav_handle);
    }
    return source;
  }

  // Phase 3 Multi-tab: window.open() handling.
  // User gesture + HTTP(S)/data URL → notify observer to create new tab.
  // No gesture → block (popup blocking).
  content::WebContents* AddNewContents(
      content::WebContents* source,
      std::unique_ptr<content::WebContents> new_contents,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      bool user_gesture,
      bool* was_blocked) override {
    // Only allow user-gesture popups with a real HTTP(S)/data target URL.
    if (user_gesture && !target_url.is_empty() &&
        (target_url.SchemeIsHTTPOrHTTPS() || target_url.SchemeIs("data"))) {
      bool foreground =
          (disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB);
      if (observer_ && observer_->is_connected()) {
        (*observer_)->OnNewTabRequested(target_url.spec(), foreground);
        LOG(INFO) << "[OWL] AddNewContents -> OnNewTabRequested url="
                  << target_url.scheme() << "://" << target_url.host()
                  << " foreground=" << foreground;
      }
      // new_contents unique_ptr destroyed at scope end (Chromium handles
      // renderer cleanup). Don't set was_blocked — not a "blocked" popup.
    } else {
      // Truly block: no-gesture, blank URL, or non-HTTP scheme.
      if (was_blocked) *was_blocked = true;
      LOG(INFO) << "[OWL] AddNewContents blocked: user_gesture=" << user_gesture
                << " url=" << target_url.scheme() << "://" << target_url.host();
    }
    return nullptr;
  }

  // Phase 3 Multi-tab: window.close() → notify observer to close this tab.
  void CloseContents(content::WebContents* source) override {
    if (observer_ && observer_->is_connected()) {
      (*observer_)->OnWebViewCloseRequested();
      LOG(INFO) << "[OWL] CloseContents -> OnWebViewCloseRequested";
    }
  }

  // Phase 28: Context menu — extract params and forward to client via observer.
  bool HandleContextMenu(content::RenderFrameHost& render_frame_host,
                         const content::ContextMenuParams& params) override {
    ++current_menu_id_;

    if (!observer_ || !observer_->is_connected()) return true;

    // Convert selection_text from UTF-16 to UTF-8 once for both helpers.
    std::string sel_text_utf8 = base::UTF16ToUTF8(params.selection_text);

    // Determine ContextMenuType via pure helper (priority: kEditable > kLink > kImage > kSelection > kPage).
    auto menu_type = owl::DetermineContextMenuType(
        params.is_editable,
        params.link_url.is_empty() ? std::string() : params.link_url.spec(),
        params.media_type == blink::mojom::ContextMenuDataMediaType::kImage,
        sel_text_utf8);

    // Truncate to 10KB with UTF-8 boundary alignment via pure helper.
    std::string sel_text = owl::TruncateSelectionTextUTF8(sel_text_utf8);

    auto mojo_params = owl::mojom::ContextMenuParams::New();
    mojo_params->type = menu_type;
    mojo_params->is_editable = params.is_editable;
    mojo_params->link_url =
        params.link_url.is_empty()
            ? std::nullopt
            : std::optional<std::string>(params.link_url.spec());
    mojo_params->src_url =
        params.src_url.is_empty()
            ? std::nullopt
            : std::optional<std::string>(params.src_url.spec());
    mojo_params->has_image_contents = params.has_image_contents;
    mojo_params->selection_text =
        sel_text.empty() ? std::nullopt
                         : std::optional<std::string>(std::move(sel_text));
    mojo_params->page_url = params.page_url.spec();
    mojo_params->x = params.x;
    mojo_params->y = params.y;
    mojo_params->menu_id = current_menu_id_;

    (*observer_)->OnContextMenu(std::move(mojo_params));
    return true;
  }

  // WebContentsObserver: Increment menu_id on navigation so client can
  // discard stale context menus from a previous page.
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsInPrimaryMainFrame()) return;
    ++current_menu_id_;
    if (handle->IsSameDocument()) return;
    DispatchNavigationStarted(handle, /*is_redirect=*/false);
  }

  // WebContentsObserver: Redirect on main frame navigation.
  // No IsSameDocument() check needed: redirects only occur for cross-document
  // navigations (network-level 3xx). Same-document navigations cannot redirect.
  void DidRedirectNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsInPrimaryMainFrame()) return;
    DispatchNavigationStarted(handle, /*is_redirect=*/true);
  }

  // Phase 2+3: Execute context menu action with payload support.
  void ExecuteContextMenuAction(int32_t action, uint32_t menu_id,
                                const std::string& payload) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);

    // Stale menu_id guard: ignore actions from a previous page.
    if (menu_id != current_menu_id_) {
      LOG(WARNING) << "[OWL] ExecuteContextMenuAction stale menu_id="
                   << menu_id << " current=" << current_menu_id_;
      return;
    }

    if (!web_contents_) return;

    auto mojo_action = static_cast<owl::mojom::ContextMenuAction>(action);
    switch (mojo_action) {
      case owl::mojom::ContextMenuAction::kOpenLinkInNewTab: {
        // payload = link URL. Validate scheme (http/https only).
        GURL link_url(payload);
        if (!link_url.is_valid() || !link_url.SchemeIsHTTPOrHTTPS()) {
          LOG(WARNING) << "[OWL] kOpenLinkInNewTab rejected URL scheme: "
                       << GURL(payload).scheme();
          return;
        }
        // Single-tab mode: navigate current tab to the link URL.
        content::NavigationController::LoadURLParams load_params(link_url);
        load_params.transition_type = ui::PAGE_TRANSITION_LINK;
        web_contents_->GetController().LoadURLWithParams(load_params);
        break;
      }
      case owl::mojom::ContextMenuAction::kSearch: {
        // payload = selection text. Build Google search URL.
        if (payload.empty()) return;
        std::string collapsed =
            base::CollapseWhitespaceASCII(payload, /*trim_sequences_with_line_breaks=*/true);
        if (collapsed.empty()) return;
        std::string escaped = base::EscapeQueryParamValue(collapsed, /*use_plus=*/true);
        GURL search_url("https://www.google.com/search?q=" + escaped);
        if (!search_url.is_valid()) return;
        content::NavigationController::LoadURLParams load_params(search_url);
        load_params.transition_type = ui::PAGE_TRANSITION_GENERATED;
        web_contents_->GetController().LoadURLWithParams(load_params);
        break;
      }
      case owl::mojom::ContextMenuAction::kCopy:
        web_contents_->Copy();
        break;
      case owl::mojom::ContextMenuAction::kCut:
        web_contents_->Cut();
        break;
      case owl::mojom::ContextMenuAction::kPaste:
        web_contents_->Paste();
        break;
      case owl::mojom::ContextMenuAction::kSelectAll:
        web_contents_->SelectAll();
        break;

      // Phase 3: Copy link URL to clipboard.
      case owl::mojom::ContextMenuAction::kCopyLink: {
        // payload = link URL from context menu params.
        if (payload.empty()) {
          LOG(WARNING) << "[OWL] kCopyLink empty payload";
          return;
        }
        GURL link_url(payload);
        if (!link_url.is_valid() || !link_url.SchemeIsHTTPOrHTTPS()) {
          LOG(WARNING) << "[OWL] kCopyLink rejected URL scheme: "
                       << GURL(payload).scheme();
          return;
        }
        {
          ui::ScopedClipboardWriter writer(ui::ClipboardBuffer::kCopyPaste);
          writer.WriteText(base::UTF8ToUTF16(link_url.spec()));
        }
        LOG(INFO) << "[OWL] kCopyLink copied: "
                  << link_url.scheme() << "://" << link_url.host();
        break;
      }

      // Phase 3: Save image to ~/Downloads via DownloadManager.
      case owl::mojom::ContextMenuAction::kSaveImage: {
        // payload = src_url. Security: only allow http/https scheme.
        GURL src_url(payload);
        if (!src_url.is_valid() || !src_url.SchemeIsHTTPOrHTTPS()) {
          LOG(WARNING) << "[OWL] kSaveImage rejected URL scheme: "
                       << GURL(payload).scheme();
          return;
        }
        // Attempt to use DownloadManager for proper download (respects
        // OWLDownloadManagerDelegate → ~/Downloads).
        content::BrowserContext* browser_context =
            web_contents_->GetBrowserContext();
        content::DownloadManager* download_manager =
            browser_context ? browser_context->GetDownloadManager() : nullptr;
        if (download_manager) {
          static const net::NetworkTrafficAnnotationTag kSaveImageAnnotation =
              net::DefineNetworkTrafficAnnotation("owl_save_image", R"(
                semantics { sender: "OWL Save Image" description: "User-initiated image download from context menu." trigger: "User selects Save Image from context menu." data: "Image URL." destination: LOCAL })");
          auto* rfh = web_contents_->GetPrimaryMainFrame();
          std::unique_ptr<download::DownloadUrlParameters> params =
              std::make_unique<download::DownloadUrlParameters>(
                  src_url,
                  rfh->GetProcess()->GetDeprecatedID(),
                  rfh->GetRoutingID(),
                  kSaveImageAnnotation);
          params->set_referrer(web_contents_->GetLastCommittedURL());
          params->set_prompt(false);
          download_manager->DownloadUrl(std::move(params));
          LOG(INFO) << "[OWL] kSaveImage initiated download: "
                    << src_url.scheme() << "://" << src_url.host();
        } else {
          // Fallback: navigate to the image URL (triggers download via browser).
          LOG(WARNING) << "[OWL] kSaveImage no DownloadManager, navigating";
          content::NavigationController::LoadURLParams load_params(src_url);
          load_params.transition_type = ui::PAGE_TRANSITION_LINK;
          web_contents_->GetController().LoadURLWithParams(load_params);
        }
        break;
      }

      // Phase 3: Copy image data to clipboard.
      case owl::mojom::ContextMenuAction::kCopyImage: {
        // payload = src_url. Security: only allow http/https scheme.
        GURL src_url(payload);
        if (!src_url.is_valid() || !src_url.SchemeIsHTTPOrHTTPS()) {
          LOG(WARNING) << "[OWL] kCopyImage rejected URL scheme: "
                       << GURL(payload).scheme();
          // Notify observer of failure (no fallback URL available).
          if (observer_ && observer_->is_connected()) {
            (*observer_)->OnCopyImageResult(false, std::nullopt);
          }
          return;
        }
        // Use WebContents::DownloadImage to fetch image data, then write to
        // NSPasteboard. On failure, notify observer with fallback_url for
        // client-side "copy URL" degradation.
        std::string fallback_url_str = src_url.spec();
        web_contents_->DownloadImage(
            src_url,
            /*is_favicon=*/false,
            /*preferred_size=*/gfx::Size(),
            /*max_bitmap_size=*/0,
            /*bypass_cache=*/false,
            base::BindOnce(
                [](base::WeakPtr<RealWebContents> weak_self,
                   std::string fallback_url,
                   int id,
                   int http_status_code,
                   const GURL& image_url,
                   const std::vector<SkBitmap>& bitmaps,
                   const std::vector<gfx::Size>& sizes) {
                  if (!weak_self) return;
                  bool success = false;
                  if (!bitmaps.empty() && !bitmaps[0].drawsNothing()) {
                    // Write image data to NSPasteboard.
                    NSImage* ns_image =
                        skia::SkBitmapToNSImage(bitmaps[0]);
                    if (ns_image) {
                      NSPasteboard* pasteboard =
                          [NSPasteboard generalPasteboard];
                      [pasteboard clearContents];
                      [pasteboard writeObjects:@[ ns_image ]];
                      success = true;
                      LOG(INFO) << "[OWL] kCopyImage wrote image to pasteboard";
                    }
                  }
                  if (!success) {
                    LOG(WARNING) << "[OWL] kCopyImage download failed, "
                                 << "notifying observer with fallback_url";
                  }
                  // Notify observer of result.
                  if (weak_self->observer_ &&
                      weak_self->observer_->is_connected()) {
                    std::optional<std::string> fb =
                        success ? std::nullopt
                                : std::make_optional(fallback_url);
                    (*weak_self->observer_)
                        ->OnCopyImageResult(success, std::move(fb));
                  }
                },
                weak_factory_.GetWeakPtr(), fallback_url_str));
        break;
      }

      // Phase 3: Copy image src URL to clipboard.
      case owl::mojom::ContextMenuAction::kCopyImageUrl: {
        // payload = src_url. Security: only allow http/https scheme.
        GURL src_url(payload);
        if (!src_url.is_valid() || !src_url.SchemeIsHTTPOrHTTPS()) {
          LOG(WARNING) << "[OWL] kCopyImageUrl rejected URL scheme: "
                       << GURL(payload).scheme();
          return;
        }
        {
          ui::ScopedClipboardWriter writer(ui::ClipboardBuffer::kCopyPaste);
          writer.WriteText(base::UTF8ToUTF16(src_url.spec()));
        }
        LOG(INFO) << "[OWL] kCopyImageUrl copied: "
                  << src_url.scheme() << "://" << src_url.host();
        break;
      }

      // Phase 3: View page source. Uses Host's own URL (not payload) for safety.
      case owl::mojom::ContextMenuAction::kViewSource: {
        // Security: use the Host's known committed URL, never trust payload.
        GURL page_url = web_contents_->GetLastCommittedURL();
        if (!page_url.is_valid() || !page_url.SchemeIsHTTPOrHTTPS()) {
          LOG(WARNING) << "[OWL] kViewSource rejected page URL scheme: "
                       << page_url.scheme();
          return;
        }
        GURL view_source_url("view-source:" + page_url.spec());
        if (!view_source_url.is_valid()) {
          LOG(WARNING) << "[OWL] kViewSource invalid view-source URL";
          return;
        }
        content::NavigationController::LoadURLParams load_params(
            view_source_url);
        load_params.transition_type = ui::PAGE_TRANSITION_GENERATED;
        web_contents_->GetController().LoadURLWithParams(load_params);
        LOG(INFO) << "[OWL] kViewSource navigating to: "
                  << page_url.scheme() << "://" << page_url.host();
        break;
      }

      default:
        LOG(WARNING) << "[OWL] ExecuteContextMenuAction unknown action="
                     << action;
        break;
    }
  }

  // Phase 33: Find-in-Page
  int32_t Find(std::string query, bool forward, bool match_case) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_) return 0;

    int32_t request_id = ++find_request_id_;

    auto options = blink::mojom::FindOptions::New();
    options->forward = forward;
    options->match_case = match_case;
    // new_session = true when query changes, false for find next/prev.
    options->new_session = (query != last_find_query_);
    last_find_query_ = query;

    web_contents_->Find(request_id, base::UTF8ToUTF16(query),
                        std::move(options), /*skip_delay=*/false);
    return request_id;
  }

  void StopFinding(int32_t action) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_) return;

    content::StopFindAction stop_action;
    switch (action) {
      case 1: stop_action = content::STOP_FIND_ACTION_KEEP_SELECTION; break;
      case 2: stop_action = content::STOP_FIND_ACTION_ACTIVATE_SELECTION; break;
      default: stop_action = content::STOP_FIND_ACTION_CLEAR_SELECTION; break;
    }
    web_contents_->StopFinding(stop_action);
    last_find_query_.clear();
  }

  // Phase 34: Zoom control.
  void SetZoom(double level) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_) return;
    // Clamp to blink min/max zoom factors.
    double min_level = blink::ZoomFactorToZoomLevel(blink::kMinimumBrowserZoomFactor);
    double max_level = blink::ZoomFactorToZoomLevel(blink::kMaximumBrowserZoomFactor);
    level = std::clamp(level, min_level, max_level);
    content::HostZoomMap::SetZoomLevel(web_contents_.get(), level);
  }

  double GetZoom() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_) return 0.0;
    return content::HostZoomMap::GetZoomLevel(web_contents_.get());
  }

  void OnZoomChanged(const content::HostZoomMap::ZoomLevelChange& change) {
    if (observer_ && observer_->is_connected()) {
      double level = content::HostZoomMap::GetZoomLevel(web_contents_.get());
      (*observer_)->OnZoomLevelChanged(level);
    }
  }

  // WebContentsDelegate override:
  void FindReply(content::WebContents* web_contents,
                 int request_id,
                 int number_of_matches,
                 const gfx::Rect& selection_rect,
                 int active_match_ordinal,
                 bool final_update) override {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (observer_ && observer_->is_connected()) {
      (*observer_)->OnFindReply(request_id, number_of_matches,
                                active_match_ordinal, final_update);
    }
  }

  // Called by cursor swizzle callback (via GetActiveRealWebContents).
  void NotifyCursorChanged(owl::mojom::CursorType cursor_type) {
    if (observer_ && observer_->is_connected()) {
      (*observer_)->OnCursorChanged(cursor_type);
    }
  }

  // Resize the viewport to match the client's window size.
  void ResizeViewport(const gfx::Size& dip_size, float scale_factor) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);  // Phase 35: thread guard
    if (!web_contents_) return;

    // Phase 35: Store client-reported scale as defensive fallback.
    if (scale_factor > 0) {
      if (client_scale_ != scale_factor) {
        // Scale changed — restart polling so CheckRenderSurface re-emits
        // OnRenderSurfaceChanged with the updated scale. The timer may have
        // already been stopped after the initial stable detection.
        stable_count_ = 0;
        if (!render_surface_timer_.IsRunning()) {
          StartRenderSurfacePolling();
        }
      }
      client_scale_ = scale_factor;
    }

    web_contents_->Resize(gfx::Rect(dip_size));

    if (offscreen_window_) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      [offscreen_window_ setContentSize:NSMakeSize(dip_size.width(),
                                                    dip_size.height())];
      [CATransaction commit];
    }

    VLOG(1) << "[OWL] Viewport resized to " << dip_size.width()
            << "x" << dip_size.height() << " @" << scale_factor << "x";
  }

 private:
  // Ensure the renderer is visible, focused, and accepting input.
  // Shared by constructor and NavigateTo() to avoid duplication.
  void EnsureRendererReady() {
    web_contents_->WasShown();
    if (auto* rwhv = web_contents_->GetRenderWidgetHostView()) {
      rwhv->Focus();
      auto* rwhi = content::RenderWidgetHostImpl::From(
          rwhv->GetRenderWidgetHost());
      if (rwhi) rwhi->ForceFirstFrameAfterNavigationTimeout();
    }
  }

  void DelayedReForce() {
    if (!web_contents_) return;
    auto* rfh = web_contents_->GetPrimaryMainFrame();
    if (!rfh) return;
    auto* rwhi = content::RenderWidgetHostImpl::From(rfh->GetRenderWidgetHost());
    if (!rwhi) return;
    if (rwhi->GetView()) rwhi->GetView()->Focus();
    rwhi->ForceFirstFrameAfterNavigationTimeout();
  }

  // Dispatch OnNavigationStarted for both initial and redirect navigations.
  void DispatchNavigationStarted(content::NavigationHandle* handle,
                                 bool is_redirect) {
    if (!observer_ || !observer_->is_connected()) return;
    (*observer_)->OnNavigationStarted(
        BuildNavigationEvent(handle, is_redirect, /*http_status_code=*/0));
  }

  void NotifyPageInfo() {
    if (!observer_ || !observer_->is_connected()) return;
    if (!web_contents_) return;

    auto info = owl::mojom::PageInfo::New();
    info->title = base::UTF16ToUTF8(web_contents_->GetTitle());
    info->url = web_contents_->GetVisibleURL().spec();
    info->is_loading = web_contents_->IsLoading();
    info->can_go_back = web_contents_->GetController().CanGoBack();
    info->can_go_forward = web_contents_->GetController().CanGoForward();
    (*observer_)->OnPageInfoChanged(std::move(info));
  }

  void StartRenderSurfacePolling() {
    // Poll every 100ms for the compositor's CALayerHost to appear.
    // This is called on the browser UI thread (NSApp run loop).
    render_surface_timer_.Start(
        FROM_HERE, base::Milliseconds(100),
        base::BindRepeating(&RealWebContents::CheckRenderSurface,
                            base::Unretained(this)));
  }

  void CheckRenderSurface() {
    if (!web_contents_) {
      DVLOG(1) << "[OWL] CheckRenderSurface: no web_contents";
      return;
    }

    gfx::NativeView native_view = web_contents_->GetNativeView();
    if (!native_view) {
      DVLOG(1) << "[OWL] CheckRenderSurface: native_view is null";
      return;
    }

    NSView* ns_view = native_view.GetNativeNSView();
    if (!ns_view) {
      DVLOG(1) << "[OWL] CheckRenderSurface: ns_view is null";
      return;
    }
    if (!ns_view.layer) {
      DVLOG(1) << "[OWL] CheckRenderSurface: ns_view.layer is null (wantsLayer="
                << ns_view.wantsLayer << ")";
      return;
    }

    // Log layer tree for debugging (first few polls only).
    if (poll_count_++ < 5) {
      LogLayerTree(ns_view.layer, 0);
    }

    // Walk the layer tree looking for a CALayerHost with non-zero contextId.
    // Require the same contextId for 2 consecutive polls before notifying,
    // to avoid emitting a stale contextId that lingers briefly after navigation.
    uint32_t context_id = FindCAContextId(ns_view.layer);
    if (context_id != 0) {
      if (context_id != last_context_id_) {
        last_context_id_ = context_id;
        stable_count_ = 1;
      } else {
        stable_count_++;
      }

      if (stable_count_ >= 2) {
        DCHECK_CURRENTLY_ON(content::BrowserThread::UI);  // Phase 35: thread guard
        CGSize size = ns_view.layer.bounds.size;

        // Phase 35: Three-level scale fallback for Retina correctness.
        // 1. CALayer contentsScale (authoritative — set by compositor)
        // 2. offscreen_window_ backingScaleFactor (window-level)
        // 3. client_scale_ (Client-reported, defensive fallback)
        // Final fallback: 1.0f
        float scale = ns_view.layer.contentsScale;
        if (!std::isfinite(scale) || scale <= 0) {
          if (offscreen_window_) {
            scale = [offscreen_window_ backingScaleFactor];
            DVLOG(1) << "[OWL] contentsScale<=0, using backingScaleFactor="
                      << scale;
          }
        }
        if ((!std::isfinite(scale) || scale <= 0) && client_scale_ > 0) {
          scale = client_scale_;
          LOG(WARNING) << "[OWL] backingScaleFactor<=0, using client_scale_="
                       << scale;
        }
        if (!std::isfinite(scale) || scale <= 0) {
          scale = 1.0f;
          LOG(WARNING) << "[OWL] All scale sources invalid, defaulting to 1.0";
        }

        LOG(INFO) << "[OWL] Render surface stable! ca_context_id="
                  << context_id << " size=" << size.width << "x"
                  << size.height << " scale=" << scale
                  << " backingScaleFactor="
                  << (offscreen_window_
                          ? [offscreen_window_ backingScaleFactor]
                          : -1.0);

        if (observer_ && observer_->is_connected()) {
          gfx::Size pixel_size(size.width * scale, size.height * scale);
          (*observer_)->OnRenderSurfaceChanged(
              context_id,
              mojo::PlatformHandle(),
              pixel_size,
              scale);
        }

        render_surface_timer_.Stop();
      }
    } else {
      stable_count_ = 0;
    }
  }

  NSWindow* offscreen_window_ = nil;
  int poll_count_ = 0;
  int stable_count_ = 0;

  void SetupOffscreenWindow() {
    NSView* ns_view = web_contents_->GetNativeView().GetNativeNSView();
    if (!ns_view) return;

    // Create an offscreen window to host the web content's NSView.
    // This activates layer-backing so the compositor can produce CALayerHost.
    offscreen_window_ = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1200, 800)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    offscreen_window_.contentView = ns_view;
    [ns_view setWantsLayer:YES];

    // Trigger compositor frame production with an invisible window.
    // setAlphaValue:0.01 keeps window nearly invisible but macOS still
    // considers it "visible" — needed for RenderWidgetHostViewMac::IsShowing()
    // to return true, otherwise InputRouter drops all forwarded events.
    [offscreen_window_ setAlphaValue:0.01];
    [offscreen_window_ setIgnoresMouseEvents:YES];
    [offscreen_window_ setCollectionBehavior:
        NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorIgnoresCycle |
        NSWindowCollectionBehaviorStationary];

    // Phase 35: Position offscreen window on the main screen so it inherits
    // the screen's backingScaleFactor (2.0 on Retina). Without this, the
    // window may land on a virtual 1x screen and the compositor renders at 1x.
    NSScreen* main_screen = [NSScreen mainScreen];
    if (main_screen) {
      NSRect screen_frame = [main_screen frame];
      [offscreen_window_ setFrameOrigin:screen_frame.origin];
      LOG(INFO) << "[OWL] offscreen_window positioned on mainScreen, "
                << "backingScaleFactor="
                << [offscreen_window_ backingScaleFactor];
    } else {
      LOG(WARNING) << "[OWL] [NSScreen mainScreen] returned nil, "
                   << "offscreen_window may use wrong scale";
    }

    [offscreen_window_ orderFront:nil];
    LOG(INFO) << "[OWL] Host window created (invisible) for WebContents rendering";
  }

  void LogLayerTree(CALayer* layer, int depth) {
    NSString* indent = [@"" stringByPaddingToLength:depth*2
                            withString:@" " startingAtIndex:0];
    DVLOG(1) << "[OWL] layer: " << [indent UTF8String]
              << [NSStringFromClass([layer class]) UTF8String]
              << " bounds=" << layer.bounds.size.width << "x" << layer.bounds.size.height
              << " sublayers=" << layer.sublayers.count;
    for (CALayer* sub in layer.sublayers) {
      LogLayerTree(sub, depth + 1);
    }
  }

  uint32_t FindCAContextId(CALayer* layer) {
    // Check if this layer is a CALayerHost with a contextId.
    if ([layer isKindOfClass:NSClassFromString(@"CALayerHost")]) {
      uint32_t cid = [(CALayerHost*)layer contextId];
      if (cid != 0) return cid;
    }

    // Recurse into sublayers.
    for (CALayer* sub in layer.sublayers) {
      uint32_t cid = FindCAContextId(sub);
      if (cid != 0) return cid;
    }
    return 0;
  }

  const uint64_t wid_;  // webview_id for IDMap keying.
  std::unique_ptr<content::WebContents> web_contents_;
  mojo::Remote<owl::mojom::WebViewObserver>* observer_;  // Not owned.
  raw_ptr<OWLHistoryService> history_service_;  // Not owned, injected.
  base::RepeatingTimer render_surface_timer_;
  uint32_t last_context_id_ = 0;
  float client_scale_ = 0;  // Phase 35: Client-reported scale (defensive fallback).
  // Context menu: monotonically increasing ID (incremented on each menu and navigation).
  uint32_t current_menu_id_ = 0;
  // Phase 33: Find-in-Page state.
  int32_t find_request_id_ = 0;
  std::string last_find_query_;
  // Phase 3 HTTP Auth: pending auth challenges keyed by auth_id.
  std::map<uint64_t, base::WeakPtr<OWLLoginDelegate>> pending_auth_map_;
  // Auth failure counts keyed by "origin|realm" (max 3 before auto-cancel).
  std::map<std::string, int> auth_failure_counts_;
  static constexpr int kMaxAuthFailures = 3;

  // Phase 34: Zoom subscription. MUST be before weak_factory_ for correct
  // destructor order (subscription cancelled before weak pointers invalidated).
  base::CallbackListSubscription zoom_subscription_;
  // weak_factory_ MUST be the last member (Chromium convention: ensures correct
  // destructor order — weak pointers invalidated before other members destroyed).
  base::WeakPtrFactory<RealWebContents> weak_factory_{this};
};

// Swizzled updateCursor: — must be defined after RealWebContents class.
static void OWL_swizzled_updateCursor(id self, SEL _cmd, NSCursor* cursor) {
  ((void(*)(id, SEL, NSCursor*))g_original_updateCursor)(self, _cmd, cursor);
  auto* rwc = GetActiveRealWebContents();
  if (rwc) {
    rwc->NotifyCursorChanged(OWLCursorTypeFromNSCursor(cursor));
  }
}

void RealNavigate(const GURL& url,
                  mojo::Remote<owl::mojom::WebViewObserver>* observer) {
  OWLHistoryService* history_service = g_owl_history_service;
  uint64_t wid = g_active_webview_id;
  auto* existing = g_real_web_contents_map->Lookup(wid);
  if (existing) {
    // Reuse existing WebContents for this WebView — preserves navigation history.
    existing->UpdateObserver(observer);
    existing->NavigateTo(url);
  } else {
    // First navigation for this WebView — create a new RealWebContents.
    auto* rwc = new RealWebContents(wid, url, observer, history_service);
    g_real_web_contents_map->AddWithID(rwc, wid);
  }
}

void RealGoBack() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  rwc->GoBack();
}

void RealGoForward() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  rwc->GoForward();
}

void RealReload() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  rwc->Reload();
}

void RealStop() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  rwc->Stop();
}

void RealDetachObserver() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (rwc) {
    rwc->DetachObserver();
    g_real_web_contents_map->Remove(g_active_webview_id);
    delete rwc;
  }
}

void RealUpdateObserver(
    mojo::Remote<owl::mojom::WebViewObserver>* observer) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (rwc) {
    rwc->UpdateObserver(observer);
  }
}

void RealResizeViewport(const gfx::Size& dip_size, float scale_factor) {
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  rwc->ResizeViewport(dip_size, scale_factor);
}

// === Enum mapping: OWL → Blink (explicit switch-case, NO static_cast) ===

blink::WebInputEvent::Type ToBlinkMouseType(owl::mojom::MouseEventType t) {
  switch (t) {
    case owl::mojom::MouseEventType::kMouseDown:
      return blink::WebInputEvent::Type::kMouseDown;
    case owl::mojom::MouseEventType::kMouseUp:
      return blink::WebInputEvent::Type::kMouseUp;
    case owl::mojom::MouseEventType::kMouseMoved:
      return blink::WebInputEvent::Type::kMouseMove;
    case owl::mojom::MouseEventType::kMouseEntered:
      return blink::WebInputEvent::Type::kMouseEnter;
    case owl::mojom::MouseEventType::kMouseExited:
      return blink::WebInputEvent::Type::kMouseLeave;
  }
}

blink::WebPointerProperties::Button ToBlinkButton(
    owl::mojom::MouseButton b) {
  switch (b) {
    case owl::mojom::MouseButton::kNone:
      return blink::WebPointerProperties::Button::kNoButton;
    case owl::mojom::MouseButton::kLeft:
      return blink::WebPointerProperties::Button::kLeft;
    case owl::mojom::MouseButton::kRight:
      return blink::WebPointerProperties::Button::kRight;
    case owl::mojom::MouseButton::kMiddle:
      return blink::WebPointerProperties::Button::kMiddle;
    case owl::mojom::MouseButton::kBack:
      return blink::WebPointerProperties::Button::kBack;
    case owl::mojom::MouseButton::kForward:
      return blink::WebPointerProperties::Button::kForward;
  }
}

int ToBlinkModifiers(uint32_t owl_mods) {
  int blink = 0;
  if (owl_mods & 0x01) blink |= blink::WebInputEvent::kShiftKey;
  if (owl_mods & 0x02) blink |= blink::WebInputEvent::kControlKey;
  if (owl_mods & 0x04) blink |= blink::WebInputEvent::kAltKey;
  if (owl_mods & 0x08) blink |= blink::WebInputEvent::kMetaKey;
  if (owl_mods & 0x10) blink |= blink::WebInputEvent::kCapsLockOn;
  if (owl_mods & 0x20) blink |= blink::WebInputEvent::kIsAutoRepeat;
  if (owl_mods & 0x40) blink |= blink::WebInputEvent::kLeftButtonDown;
  if (owl_mods & 0x80) blink |= blink::WebInputEvent::kMiddleButtonDown;
  if (owl_mods & 0x100) blink |= blink::WebInputEvent::kRightButtonDown;
  return blink;
}

blink::WebMouseWheelEvent::Phase ToBlinkScrollPhase(
    owl::mojom::ScrollPhase p) {
  switch (p) {
    case owl::mojom::ScrollPhase::kPhaseNone:
      return blink::WebMouseWheelEvent::kPhaseNone;
    case owl::mojom::ScrollPhase::kPhaseBegan:
      return blink::WebMouseWheelEvent::kPhaseBegan;
    case owl::mojom::ScrollPhase::kPhaseChanged:
      return blink::WebMouseWheelEvent::kPhaseChanged;
    case owl::mojom::ScrollPhase::kPhaseEnded:
      return blink::WebMouseWheelEvent::kPhaseEnded;
    case owl::mojom::ScrollPhase::kPhaseCancelled:
      return blink::WebMouseWheelEvent::kPhaseCancelled;
    case owl::mojom::ScrollPhase::kPhaseMayBegin:
      return blink::WebMouseWheelEvent::kPhaseMayBegin;
  }
}

// === Event injection ===

content::RenderWidgetHostImpl* GetRWHI() {
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return nullptr;
  auto* wc = rwc->GetWebContents();
  if (!wc) return nullptr;
  // Use primary main frame's RWH — more reliable than RWHV after navigation.
  auto* rfh = wc->GetPrimaryMainFrame();
  if (!rfh) return nullptr;
  return content::RenderWidgetHostImpl::From(rfh->GetRenderWidgetHost());
}

void EnsureFocus() {
  auto* rwhi = GetRWHI();
  if (!rwhi) return;
  if (auto* view = rwhi->GetView()) {
    view->Focus();
  }
  rwhi->ForceFirstFrameAfterNavigationTimeout();
}

void RealInjectMouseEvent(owl::mojom::MouseEventPtr event) {
  auto* rwh = GetRWHI();
  if (!rwh) {
    LOG(WARNING) << "[OWL] InjectMouseEvent: RWH is null";
    return;
  }

  // Focus on mouseDown so the renderer accepts keyboard events.
  if (event->type == owl::mojom::MouseEventType::kMouseDown) {
    EnsureFocus();
  }

  blink::WebMouseEvent web_event;
  web_event.SetType(ToBlinkMouseType(event->type));
  web_event.button = ToBlinkButton(event->button);
  web_event.pointer_type = blink::WebPointerProperties::PointerType::kMouse;
  web_event.id = 1;
  web_event.SetPositionInWidget(event->x, event->y);
  web_event.SetPositionInScreen(event->global_x, event->global_y);
  web_event.SetModifiers(ToBlinkModifiers(event->modifiers));
  web_event.click_count = event->click_count;
  web_event.SetTimeStamp(event->timestamp);

  // For mouseDown, also set the corresponding button modifier flag.
  if (event->type == owl::mojom::MouseEventType::kMouseDown) {
    int btn_mod = 0;
    if (event->button == owl::mojom::MouseButton::kLeft)
      btn_mod = blink::WebInputEvent::kLeftButtonDown;
    else if (event->button == owl::mojom::MouseButton::kRight)
      btn_mod = blink::WebInputEvent::kRightButtonDown;
    else if (event->button == owl::mojom::MouseButton::kMiddle)
      btn_mod = blink::WebInputEvent::kMiddleButtonDown;
    web_event.SetModifiers(web_event.GetModifiers() | btn_mod);
  }

  rwh->ForwardMouseEvent(web_event);
}

void RealInjectKeyEvent(owl::mojom::KeyEventPtr event) {
  auto* rwh = GetRWHI();
  if (!rwh) {
    LOG(WARNING) << "[OWL] InjectKeyEvent: RWH is null";
    return;
  }
  blink::WebInputEvent::Type type;
  switch (event->type) {
    case owl::mojom::KeyEventType::kRawKeyDown:
      type = blink::WebInputEvent::Type::kRawKeyDown;
      break;
    case owl::mojom::KeyEventType::kKeyUp:
      type = blink::WebInputEvent::Type::kKeyUp;
      break;
    case owl::mojom::KeyEventType::kChar:
      type = blink::WebInputEvent::Type::kChar;
      break;
  }

  input::NativeWebKeyboardEvent web_event(
      type, ToBlinkModifiers(event->modifiers), event->timestamp);
  web_event.native_key_code = event->native_key_code;
  // Map macOS key code → Windows virtual key code (used by JS event.keyCode).
  web_event.windows_key_code = static_cast<int>(
      ui::KeyboardCodeFromKeyCode(event->native_key_code));
  // dom_code and dom_key are required for Chromium to dispatch DOM KeyboardEvents.
  // Without these, keydown events are silently dropped.
  web_event.dom_code = static_cast<int>(
      ui::KeycodeConverter::NativeKeycodeToDomCode(event->native_key_code));
  ui::DomKey dom_key;
  ui::KeyboardCode dummy_keycode;
  if (ui::DomCodeToUsLayoutDomKey(
          static_cast<ui::DomCode>(web_event.dom_code),
          /*flags=*/0, &dom_key, &dummy_keycode)) {
    web_event.dom_key = static_cast<int>(dom_key);
  }
  web_event.os_event = gfx::NativeEvent();
  web_event.skip_if_unhandled = false;

  // Only set text for printable characters. Control chars (Enter=\r,
  // Tab=\t, Escape=\x1b) must NOT have text set on RawKeyDown — otherwise
  // Chromium auto-generates a Char event that inserts the control char
  // as text (e.g., newline in textarea instead of form submission).
  if (event->characters.has_value() && !event->characters->empty()) {
    std::u16string chars16 = base::UTF8ToUTF16(*event->characters);
    if (!chars16.empty() && chars16[0] >= 0x20 && chars16[0] != 0x7F) {
      web_event.text[0] = chars16[0];
    }
  }
  if (event->unmodified_characters.has_value() &&
      !event->unmodified_characters->empty()) {
    std::u16string uchars16 =
        base::UTF8ToUTF16(*event->unmodified_characters);
    if (!uchars16.empty() && uchars16[0] >= 0x20 && uchars16[0] != 0x7F) {
      web_event.unmodified_text[0] = uchars16[0];
    }
  }

  VLOG(1) << "[OWL] InjectKeyEvent: type=" << static_cast<int>(event->type)
          << " nativeKey=" << event->native_key_code
          << " wkc=" << web_event.windows_key_code
          << " text[0]=" << (int)web_event.text[0]
          << " unmod[0]=" << (int)web_event.unmodified_text[0];

  rwh->ForwardKeyboardEvent(web_event);
  // Caller (OWLRemoteLayerView) is responsible for sending separate
  // RawKeyDown + Char events. No auto-supplementation here.
}

void RealInjectWheelEvent(owl::mojom::WheelEventPtr event) {
  auto* rwh = GetRWHI();
  if (!rwh) {
    LOG(WARNING) << "[OWL] InjectWheelEvent: RWH is null";
    return;
  }
  DVLOG(1) << "[OWL] InjectWheelEvent: dx=" << event->delta_x
            << " dy=" << event->delta_y;

  blink::WebMouseWheelEvent web_event;
  web_event.SetType(blink::WebInputEvent::Type::kMouseWheel);
  web_event.SetPositionInWidget(event->x, event->y);
  web_event.SetPositionInScreen(event->global_x, event->global_y);
  web_event.delta_x = event->delta_x;
  web_event.delta_y = event->delta_y;
  web_event.SetModifiers(ToBlinkModifiers(event->modifiers));
  web_event.phase = ToBlinkScrollPhase(event->phase);
  web_event.momentum_phase = ToBlinkScrollPhase(event->momentum_phase);
  web_event.SetTimeStamp(event->timestamp);

  rwh->ForwardWheelEvent(web_event);
}

void RealEvaluateJS(
    const std::string& expression,
    base::OnceCallback<void(const std::string&, int32_t)> callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);

  auto* rwc = GetActiveRealWebContents();
  if (!rwc) {
    std::move(callback).Run("No WebContents", 1);
    return;
  }
  auto* wc = rwc->GetWebContents();
  if (!wc) {
    std::move(callback).Run("WebContents is null", 1);
    return;
  }
  // static_cast to RenderFrameHostImpl: needed for the 6-parameter
  // ExecuteJavaScriptForTests overload (with resolve_promises and
  // JavaScriptExecutionResultType callback), which only exists on the Impl.
  auto* rfh = static_cast<content::RenderFrameHostImpl*>(
      wc->GetPrimaryMainFrame());
  if (!rfh) {
    std::move(callback).Run("No primary frame", 1);
    return;
  }

  // resolve_promises=true: auto-await Promise results.
  // Note: a never-resolving Promise (e.g. `new Promise(()=>{})`) will cause
  // this callback to never fire. Swift-side timeout (10s) handles this case.
  rfh->ExecuteJavaScriptForTests(
      base::UTF8ToUTF16(expression),
      /*has_user_gesture=*/false,
      /*resolve_promises=*/true,
      /*honor_js_content_settings=*/false,
      content::ISOLATED_WORLD_ID_GLOBAL,
      base::BindOnce(
          [](base::OnceCallback<void(const std::string&, int32_t)> cb,
             blink::mojom::JavaScriptExecutionResultType type,
             base::Value result) {
            int32_t result_type =
                (type == blink::mojom::JavaScriptExecutionResultType::kSuccess)
                    ? 0
                    : 1;
            if (result.is_none()) {
              std::move(cb).Run("", result_type);
              return;
            }
            auto json = base::WriteJson(result);
            if (!json.has_value()) {
              std::move(cb).Run("JSON serialization failed", 1);
              return;
            }
            std::move(cb).Run(*json, result_type);
          },
          std::move(callback)));
}

// Ensure the renderer widget has focus so it accepts IME events.
// Keyboard events go through InputRouter which doesn't check focus,
// but IME events go through WidgetInputHandler → WidgetBase which
// checks ShouldHandleImeEvents() → HasFocus(). Without focus, all
// ImeSetComposition/ImeCommitText/ImeFinishComposingText calls are
// silently dropped by the renderer.
//
// Problem: browser-side is_focused_ can be true (stale) while the
// renderer-side has_focus_ is false (e.g., after navigation creates a
// new renderer widget). Force-reset by calling LostFocus+GotFocus so
// SetFocus(true) definitely reaches the renderer.
void EnsureImeFocus() {
  auto* rwhi = GetRWHI();
  if (!rwhi) return;

  // Only force-sync on first IME call or after webview switch.
  if (g_ime_focus_synced && g_ime_focus_webview_id == g_active_webview_id)
    return;

  LOG(WARNING) << "[OWL-HOST-IME] force-syncing renderer focus"
               << " is_focused=" << rwhi->is_focused();
  // Unconditional reset: LostFocus clears is_focused_, GotFocus re-sets it
  // and sends SetFocus(true) to the renderer.
  if (rwhi->is_focused()) {
    rwhi->LostFocus();
  }
  rwhi->GotFocus();
  g_ime_focus_synced = true;
  g_ime_focus_webview_id = g_active_webview_id;
}

void RealImeSetComposition(const std::string& text,
                           int sel_start, int sel_end,
                           int repl_start, int repl_end) {
  auto* rwh = GetRWHI();
  LOG(WARNING) << "[OWL-HOST-IME] ImeSetComposition text='" << text
               << "' rwh=" << (rwh ? "OK" : "NULL")
               << " focused=" << (rwh ? rwh->is_focused() : false);
  if (!rwh) return;
  EnsureImeFocus();
  std::u16string text16 = base::UTF8ToUTF16(text);
  std::vector<ui::ImeTextSpan> spans;
  if (!text16.empty()) {
    spans.emplace_back(ui::ImeTextSpan::Type::kComposition,
                       0, text16.length(),
                       ui::ImeTextSpan::Thickness::kThin,
                       ui::ImeTextSpan::UnderlineStyle::kSolid,
                       SK_ColorTRANSPARENT);
  }
  gfx::Range repl_range = (repl_start < 0)
      ? gfx::Range::InvalidRange()
      : gfx::Range(repl_start, repl_end);
  rwh->ImeSetComposition(text16, spans, repl_range, sel_start, sel_end);
}

void RealImeCommitText(const std::string& text,
                       int repl_start, int repl_end) {
  auto* rwh = GetRWHI();
  LOG(WARNING) << "[OWL-HOST-IME] ImeCommitText text='" << text
               << "' rwh=" << (rwh ? "OK" : "NULL")
               << " focused=" << (rwh ? rwh->is_focused() : false);
  if (!rwh) return;
  EnsureImeFocus();
  gfx::Range repl_range = (repl_start < 0)
      ? gfx::Range::InvalidRange()
      : gfx::Range(repl_start, repl_end);
  rwh->ImeCommitText(base::UTF8ToUTF16(text), {}, repl_range, 0);
}

void RealImeFinishComposing() {
  auto* rwh = GetRWHI();
  LOG(WARNING) << "[OWL-HOST-IME] ImeFinishComposing"
               << " rwh=" << (rwh ? "OK" : "NULL")
               << " focused=" << (rwh ? rwh->is_focused() : false);
  if (!rwh) return;
  EnsureImeFocus();
  rwh->ImeFinishComposingText(false);
}

// Phase 34: Zoom free functions.
void RealSetZoom(double level) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (rwc) rwc->SetZoom(level);
}

double RealGetZoom() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return 0.0;
  return rwc->GetZoom();
}

// Phase 33: Find-in-Page free functions.
int32_t RealFind(std::string query, bool forward, bool match_case) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return 0;
  return rwc->Find(std::move(query), forward, match_case);
}

void RealStopFinding(int32_t action) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  rwc->StopFinding(action);
}

// Context menu: Execute action (Phase 2).
void RealExecuteContextMenuAction(int32_t action, uint32_t menu_id,
                                  const std::string& payload) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  rwc->ExecuteContextMenuAction(action, menu_id, payload);
}

// Phase 3 HTTP Auth: Notify observer of auth challenge.
void RealNotifyAuth(const std::string& url, const std::string& realm,
                    const std::string& scheme, uint64_t auth_id,
                    bool is_proxy,
                    base::WeakPtr<OWLLoginDelegate> delegate) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) {
    // No WebContents — cancel the delegate.
    if (delegate) {
      delegate->Cancel();
    }
    return;
  }
  rwc->NotifyAuth(url, realm, scheme, auth_id, is_proxy,
                   std::move(delegate));
}

// Phase 3 HTTP Auth: Respond to pending auth challenge.
void RealRespondToAuth(uint64_t auth_id,
                       const std::string* username,
                       const std::string* password) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  rwc->RespondToAuth(auth_id, username, password);
}

}  // namespace

}  // namespace owl

extern "C" void OWLRealWebContents_Init(
    content::BrowserContext* browser_context) {
  owl::g_browser_context = browser_context;
  owl::g_real_navigate_func = &owl::RealNavigate;
  owl::g_real_resize_func = &owl::RealResizeViewport;
  owl::g_real_mouse_event_func = &owl::RealInjectMouseEvent;
  owl::g_real_key_event_func = &owl::RealInjectKeyEvent;
  owl::g_real_wheel_event_func = &owl::RealInjectWheelEvent;
  owl::g_real_eval_js_func = &owl::RealEvaluateJS;
  owl::g_real_ime_set_composition_func = &owl::RealImeSetComposition;
  owl::g_real_ime_commit_text_func = &owl::RealImeCommitText;
  owl::g_real_ime_finish_composing_func = &owl::RealImeFinishComposing;
  // Phase 32: Navigation history + observer lifecycle.
  owl::g_real_go_back_func = &owl::RealGoBack;
  owl::g_real_go_forward_func = &owl::RealGoForward;
  owl::g_real_reload_func = &owl::RealReload;
  owl::g_real_stop_func = &owl::RealStop;
  owl::g_real_detach_observer_func = &owl::RealDetachObserver;
  owl::g_real_update_observer_func = &owl::RealUpdateObserver;
  // Phase 33: Find-in-Page
  owl::g_real_find_func = &owl::RealFind;
  owl::g_real_stop_finding_func = &owl::RealStopFinding;
  // Phase 34: Zoom
  owl::g_real_set_zoom_func = &owl::RealSetZoom;
  owl::g_real_get_zoom_func = &owl::RealGetZoom;
  // Context menu
  owl::g_real_execute_context_menu_action_func =
      &owl::RealExecuteContextMenuAction;
  // Phase 3 HTTP Auth
  owl::g_real_notify_auth_func = &owl::RealNotifyAuth;
  owl::g_real_respond_to_auth_func = &owl::RealRespondToAuth;
  LOG(INFO) << "[OWL] Real WebContents rendering enabled";
}
