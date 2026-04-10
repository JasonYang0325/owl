// Copyright 2026 AntlerAI. All rights reserved.
// OWL Bridge C-ABI implementation.

#include "third_party/owl/bridge/owl_bridge_api.h"

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/containers/flat_map.h"
#include "base/memory/ptr_util.h"

#include "base/apple/bundle_locations.h"
#include "base/apple/foundation_util.h"
#include "base/at_exit.h"
#include "base/no_destructor.h"
#include "base/command_line.h"
#include "base/feature_list.h"
#include "base/files/file_path.h"
#include "base/check_op.h"
#include "base/logging.h"
#include "base/logging/logging_settings.h"
#include "base/message_loop/message_pump_type.h"
#include "base/process/launch.h"
#include "base/process/process.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/single_thread_task_executor.h"
#include "base/threading/thread.h"
#include "mojo/core/embedder/embedder.h"
#include "mojo/core/embedder/scoped_ipc_support.h"
#include "mojo/public/c/system/core.h"
#include "mojo/public/cpp/platform/platform_channel.h"
#include "mojo/public/cpp/system/handle.h"
#include "mojo/public/cpp/system/invitation.h"
#include "mojo/public/cpp/system/message_pipe.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "mojo/public/cpp/system/simple_watcher.h"
#include "base/json/json_writer.h"
#include "base/time/time.h"
#include "base/values.h"
#include "third_party/owl/mojom/bookmarks.mojom.h"
#include "third_party/owl/mojom/downloads.mojom.h"
#include "third_party/owl/mojom/history.mojom.h"
#include "third_party/owl/mojom/permissions.mojom.h"
#include "third_party/owl/mojom/session.mojom.h"
#include "third_party/owl/mojom/storage.mojom.h"
#include "third_party/owl/mojom/browser_context.mojom.h"
#include "third_party/owl/mojom/owl_input_types.mojom.h"
#include "third_party/owl/mojom/owl_types.mojom.h"
#include "third_party/owl/mojom/web_view.mojom.h"
#include "url/gurl.h"

namespace {

base::AtExitManager* g_exit_manager = nullptr;
base::NoDestructor<std::unique_ptr<base::Thread>> g_io_thread;
base::NoDestructor<std::unique_ptr<mojo::core::ScopedIPCSupport>> g_ipc_support;
std::atomic<bool> g_initialized{false};

// Session/Context/WebView state — all Remotes bound on IO thread.
struct SessionState {
  mojo::Remote<owl::mojom::SessionHost> remote;
};
base::NoDestructor<std::unique_ptr<SessionState>> g_session;

}  // namespace

// Exported flag for OWLMojoThread Phase 25 awareness.
// OWL_EXPORT ensures visibility across dylib boundary.
OWL_EXPORT int g_owl_bridge_initialized = 0;

// === Lifecycle ===

void OWLBridge_Initialize() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    CHECK(pthread_main_np()) << "OWLBridge_Initialize must be called on main thread";

    // === Step 1: Base prerequisites ===
    g_exit_manager = new base::AtExitManager();

    if (!base::CommandLine::InitializedForCurrentProcess()) {
      base::CommandLine::Init(0, nullptr);
    }

    if (!base::FeatureList::GetInstance()) {
      base::FeatureList::InitInstance("", "");
    }

    logging::LoggingSettings log_settings;
    log_settings.logging_dest = logging::LOG_TO_SYSTEM_DEBUG_LOG |
                                 logging::LOG_TO_STDERR;
    logging::InitLogging(log_settings);

    // Match BaseBundleID with OWL Host so MachPortRendezvous service names
    // align between parent (Swift client) and child (OWL Host.app).
    // Without this, base::LaunchProcess registers the rendezvous server
    // with the Swift client's bundle ID, but the child looks it up with
    // "com.antlerai.owl-host" from its own Info.plist.
    base::apple::SetBaseBundleIDOverride("com.antlerai.owl-host");

    LOG(INFO) << "[OWL] base prerequisites initialized";

    // === Step 2: Mojo runtime ===
    mojo::core::Configuration config;
    // Client (Swift) is the parent/broker — it sends the Mojo invitation.
    // IPCZ requires the invitation sender to be the broker node.
    config.is_broker_process = true;
    mojo::core::Init(config);
    LOG(INFO) << "[OWL] mojo::core::Init() completed";

    // NOTE: No main-thread TaskExecutor — NS_RUNLOOP pump crashes with SwiftUI.
    // All Mojo Remote operations go through IO thread via PostTask.
    // ObjC++ bridge classes (OWLBridgeSession etc.) cannot be used directly
    // from Swift in this configuration. Use C-ABI high-level functions instead.

    // === Step 3: IO Thread + IPC ===
    *g_io_thread = std::make_unique<base::Thread>("owl-connector-io");
    base::Thread::Options thread_opts(base::MessagePumpType::IO, 0);
    CHECK((*g_io_thread)->StartWithOptions(std::move(thread_opts)));

    *g_ipc_support = std::make_unique<mojo::core::ScopedIPCSupport>(
        (*g_io_thread)->task_runner(),
        mojo::core::ScopedIPCSupport::ShutdownPolicy::FAST);

    g_initialized.store(true, std::memory_order_release);
    g_owl_bridge_initialized = 1;
    LOG(INFO) << "[OWL] fully initialized";
  });
}

// === Host Process ===

void OWLBridge_LaunchHost(const char* host_path,
                          const char* user_data_dir,
                          uint16_t devtools_port,
                          OWLBridge_LaunchCallback callback,
                          void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire))
      << "Call OWLBridge_Initialize first";

  std::string path(host_path);
  std::string data_dir(user_data_dir);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string path, std::string data_dir, uint16_t port,
             OWLBridge_LaunchCallback cb, void* ctx) {
            mojo::PlatformChannel channel;

            base::FilePath host_file_path(path);
            base::CommandLine command_line(host_file_path);
            command_line.AppendSwitchASCII("user-data-dir", data_dir);
            command_line.AppendSwitchASCII("devtools-port",
                                           base::NumberToString(port));
            // Enable Chrome DevTools Protocol for E2E testing / diagnostics.
            // Use explicit port when set, otherwise default to 9222 for dev.
            uint16_t debug_port = port > 0 ? port : 9222;
            command_line.AppendSwitchASCII("remote-debugging-port",
                                           base::NumberToString(debug_port));
            // Dev-only: no sandbox. Production requires signed Helper Apps.
            command_line.AppendSwitch("no-sandbox");
            // Test-only JS evaluation gate. Keep host default-closed unless the
            // launcher explicitly opts in via environment.
            const char* enable_test_js = std::getenv("OWL_ENABLE_TEST_JS");
            if (enable_test_js && std::string(enable_test_js) == "1") {
              command_line.AppendSwitch("enable-owl-test-js");
            }

            base::LaunchOptions opts;
            channel.PrepareToPassRemoteEndpoint(&opts, &command_line);
            base::Process process = base::LaunchProcess(command_line, opts);
            channel.RemoteProcessLaunchAttempted();

            if (!process.IsValid()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, 0, "Failed to launch owl_host", ctx);
              });
              return;
            }

            pid_t pid = process.Pid();

            mojo::OutgoingInvitation invitation;
            mojo::ScopedMessagePipeHandle pipe =
                invitation.AttachMessagePipe(uint64_t{0});
            mojo::OutgoingInvitation::Send(std::move(invitation),
                                           process.Handle(),
                                           channel.TakeLocalEndpoint());

            // Bind session Remote on IO thread.
            *g_session = std::make_unique<SessionState>();
            (*g_session)->remote.Bind(
                mojo::PendingRemote<owl::mojom::SessionHost>(
                    std::move(pipe), 0));
            (*g_session)->remote.set_disconnect_handler(base::BindOnce([]() {
              LOG(ERROR) << "[OWL] Session Remote DISCONNECTED!";
            }));
            LOG(INFO) << "[OWL] Session Remote bound on IO thread";

            // Return session ID to caller.
            uint64_t session_id = 1;
            dispatch_async(dispatch_get_main_queue(), ^{
              cb(session_id, pid, nullptr, ctx);
            });
          },
          std::move(path), std::move(data_dir), devtools_port, callback, ctx));
}

// === Message Pipes ===

void OWLBridge_CreateMessagePipe(uint64_t* handle0, uint64_t* handle1) {
  MojoHandle h0, h1;
  MojoResult result = MojoCreateMessagePipe(nullptr, &h0, &h1);
  if (result == MOJO_RESULT_OK) {
    *handle0 = h0;
    *handle1 = h1;
  } else {
    *handle0 = 0;
    *handle1 = 0;
  }
}

void OWLBridge_CloseHandle(uint64_t handle) {
  if (handle != 0) {
    MojoClose(static_cast<MojoHandle>(handle));
  }
}

int OWLBridge_WriteMessage(uint64_t pipe_handle,
                           const void* data,
                           uint32_t data_size,
                           const uint64_t* handles,
                           uint32_t num_handles) {
  MojoMessageHandle message;
  MojoResult result = MojoCreateMessage(nullptr, &message);
  if (result != MOJO_RESULT_OK)
    return result;

  void* buffer = nullptr;
  uint32_t buffer_size_out = 0;
  MojoAppendMessageDataOptions append_opts = {
      sizeof(MojoAppendMessageDataOptions),
      MOJO_APPEND_MESSAGE_DATA_FLAG_COMMIT_SIZE};
  result = MojoAppendMessageData(
      message, data_size,
      reinterpret_cast<const MojoHandle*>(handles), num_handles,
      &append_opts, &buffer, &buffer_size_out);
  if (result != MOJO_RESULT_OK) {
    MojoDestroyMessage(message);
    return result;
  }

  if (data && data_size > 0) {
    memcpy(buffer, data, data_size);
  }

  result = MojoWriteMessage(static_cast<MojoHandle>(pipe_handle),
                            message, nullptr);
  if (result != MOJO_RESULT_OK) {
    MojoDestroyMessage(message);
  }
  return result;
}

int OWLBridge_ReadMessage(uint64_t pipe_handle,
                          void** out_data,
                          uint32_t* out_data_size,
                          uint64_t** out_handles,
                          uint32_t* out_num_handles) {
  MojoMessageHandle message;
  MojoResult result = MojoReadMessage(
      static_cast<MojoHandle>(pipe_handle), nullptr, &message);
  if (result != MOJO_RESULT_OK) {
    *out_data = nullptr;
    *out_data_size = 0;
    *out_handles = nullptr;
    *out_num_handles = 0;
    return result;
  }

  void* buffer = nullptr;
  uint32_t buffer_size = 0;
  uint32_t num_handles = 0;
  result = MojoGetMessageData(message, nullptr, &buffer, &buffer_size,
                              nullptr, &num_handles);
  if (result != MOJO_RESULT_OK) {
    MojoDestroyMessage(message);
    *out_data = nullptr;
    *out_data_size = 0;
    *out_handles = nullptr;
    *out_num_handles = 0;
    return result;
  }

  if (buffer_size > 0) {
    *out_data = malloc(buffer_size);
    memcpy(*out_data, buffer, buffer_size);
    *out_data_size = buffer_size;
  } else {
    *out_data = nullptr;
    *out_data_size = 0;
  }

  if (num_handles > 0) {
    auto* handle_buf =
        static_cast<MojoHandle*>(malloc(num_handles * sizeof(MojoHandle)));
    MojoGetMessageData(message, nullptr, &buffer, &buffer_size,
                       handle_buf, &num_handles);
    *out_handles = reinterpret_cast<uint64_t*>(handle_buf);
    *out_num_handles = num_handles;
  } else {
    *out_handles = nullptr;
    *out_num_handles = 0;
  }

  MojoDestroyMessage(message);
  return MOJO_RESULT_OK;
}

struct WatchState {
  uint64_t pipe_handle;
  uint64_t watch_id;
  OWLBridge_PipeReadableCallback callback;
  void* context;
  std::unique_ptr<mojo::SimpleWatcher> watcher;
};

// BH-004: WatchState self-managed lifecycle map.
// All operations (insert/erase/lookup) must happen on the IO thread.
base::NoDestructor<base::flat_map<uint64_t, std::unique_ptr<WatchState>>>
    g_watch_states;
std::atomic<uint64_t> g_next_watch_id{1};

int OWLBridge_WatchPipe(uint64_t pipe_handle,
                        OWLBridge_PipeReadableCallback callback,
                        void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));

  uint64_t watch_id = g_next_watch_id.fetch_add(1, std::memory_order_relaxed);
  auto state = std::make_unique<WatchState>();
  state->pipe_handle = pipe_handle;
  state->watch_id = watch_id;
  state->callback = callback;
  state->context = ctx;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::unique_ptr<WatchState> state) {
            uint64_t wid = state->watch_id;
            WatchState* raw = state.get();
            (*g_watch_states)[wid] = std::move(state);

            raw->watcher = std::make_unique<mojo::SimpleWatcher>(
                FROM_HERE, mojo::SimpleWatcher::ArmingPolicy::AUTOMATIC,
                (*g_io_thread)->task_runner());
            raw->watcher->Watch(
                mojo::Handle(static_cast<MojoHandle>(raw->pipe_handle)),
                MOJO_HANDLE_SIGNAL_READABLE,
                MOJO_WATCH_CONDITION_SATISFIED,
                base::BindRepeating(
                    [](uint64_t watch_id, MojoResult result,
                       const mojo::HandleSignalsState&) {
                      auto it = g_watch_states->find(watch_id);
                      if (it == g_watch_states->end()) return;
                      WatchState* s = it->second.get();
                      OWLBridge_PipeReadableCallback cb = s->callback;
                      uint64_t handle = s->pipe_handle;
                      void* ctx = s->context;

                      if (result == MOJO_RESULT_CANCELLED) {
                        // Pipe closed: reset watcher first, then erase from map.
                        // Erasing the unique_ptr will delete the WatchState.
                        s->watcher.reset();
                        g_watch_states->erase(it);
                      }

                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(handle, result, ctx);
                      });
                    },
                    wid));
          },
          std::move(state)));

  return 0;
}

void OWLBridge_CancelWatch(uint64_t watch_id) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce([](uint64_t wid) {
        auto it = g_watch_states->find(wid);
        if (it == g_watch_states->end()) return;  // Already cancelled or fired.
        it->second->watcher.reset();
        g_watch_states->erase(it);
      }, watch_id));
}

// === High-level Session API ===

namespace {

// Browser context state — bound on IO thread.
struct ContextState {
  mojo::Remote<owl::mojom::BrowserContextHost> remote;
};
base::NoDestructor<std::unique_ptr<ContextState>> g_context;

// Bookmark service state — bound on IO thread, per-context.
struct BookmarkState {
  mojo::Remote<owl::mojom::BookmarkService> remote;
};
base::NoDestructor<std::unique_ptr<BookmarkState>> g_bookmark_service;

// History service state — bound on IO thread, per-context.
struct HistoryState {
  mojo::Remote<owl::mojom::HistoryService> remote;
};
base::NoDestructor<std::unique_ptr<HistoryState>> g_history_service;

// Permission service state — bound on IO thread, per-context.
struct PermissionServiceState {
  mojo::Remote<owl::mojom::PermissionService> remote;
};
base::NoDestructor<std::unique_ptr<PermissionServiceState>> g_permission_service;

// Permission request callback — global (not per-webview).
// Design decision: permission requests bind to BrowserContext, and the current
// architecture has one context, so a global variable is simplest.
// Only read/written on main thread (C-ABI guarantees callbacks on main thread).
static OWLBridge_PermissionRequestCallback g_permission_request_cb = nullptr;
static void* g_permission_request_ctx = nullptr;

// Phase 4: SSL error callback — global (not per-webview).
static OWLBridge_SSLErrorCallback g_ssl_error_cb = nullptr;
static void* g_ssl_error_ctx = nullptr;

// Phase 3 HTTP Auth: auth required callback — per-webview.
static OWLBridge_AuthRequiredCallback g_auth_required_cb = nullptr;
static void* g_auth_required_ctx = nullptr;

// BH-011: Request origin maps (request_id/error_id/auth_id → webview_id).
// Used to route responses to the correct WebView instead of g_active_webview_id.
// All accessed on IO thread (Observer callbacks run on IO thread).
base::NoDestructor<std::map<uint64_t, uint64_t>> g_permission_request_origins;
base::NoDestructor<std::map<uint64_t, uint64_t>> g_ssl_error_origins;
base::NoDestructor<std::map<uint64_t, uint64_t>> g_auth_request_origins;

// History changed callback — global (not per-webview).
static OWLBridge_HistoryChangedCallback g_history_changed_cb = nullptr;
static void* g_history_changed_ctx = nullptr;

// HistoryObserver implementation (receives Host→Client history change notifications).
class HistoryObserverImpl : public owl::mojom::HistoryObserver {
 public:
  void OnHistoryChanged(const std::string& url) override {
    if (!g_history_changed_cb) return;
    std::string url_copy = url;
    auto cb = g_history_changed_cb;
    auto ctx = g_history_changed_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(url_copy.c_str(), ctx);
    });
  }
};

base::NoDestructor<std::unique_ptr<HistoryObserverImpl>> g_history_observer;
base::NoDestructor<std::unique_ptr<mojo::Receiver<owl::mojom::HistoryObserver>>>
    g_history_observer_receiver;

// Download push event callback — only read/written on IO thread.
static OWLBridge_DownloadEventCallback g_download_event_cb = nullptr;
static void* g_download_event_ctx = nullptr;

// Convert a single mojom DownloadItem to JSON string.
// Defined here (before DownloadObserverImpl) so the observer can call it.
std::string DownloadItemToJson(
    const owl::mojom::DownloadItemPtr& item) {
  base::DictValue dict;
  dict.Set("id", static_cast<int>(item->id));
  dict.Set("url", item->url);
  dict.Set("filename", item->filename);
  dict.Set("mime_type", item->mime_type);
  dict.Set("total_bytes", static_cast<double>(item->total_bytes));
  dict.Set("received_bytes", static_cast<double>(item->received_bytes));
  dict.Set("speed_bytes_per_sec",
           static_cast<double>(item->speed_bytes_per_sec));
  dict.Set("state", static_cast<int>(item->state));
  dict.Set("can_resume", item->can_resume);
  dict.Set("target_path", item->target_path);
  if (item->error_description.has_value()) {
    dict.Set("error_description", item->error_description.value());
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(dict)), &json);
  return json;
}

// DownloadObserver implementation (receives Host→Client download notifications).
class DownloadObserverImpl : public owl::mojom::DownloadObserver {
 public:
  void OnDownloadCreated(owl::mojom::DownloadItemPtr item) override {
    DispatchEvent(std::move(item), 0);  // event_type=0 (created)
  }
  void OnDownloadUpdated(owl::mojom::DownloadItemPtr item) override {
    DispatchEvent(std::move(item), 1);  // event_type=1 (updated)
  }
  void OnDownloadRemoved(uint32_t id) override {
    if (!g_download_event_cb) return;
    auto cb = g_download_event_cb;
    auto ctx = g_download_event_ctx;
    // Build minimal JSON for removed event (id + default fields).
    base::DictValue dict;
    dict.Set("id", static_cast<int>(id));
    dict.Set("url", "");
    dict.Set("filename", "");
    dict.Set("state",
             static_cast<int>(owl::mojom::DownloadState::kCancelled));
    std::string json;
    base::JSONWriter::Write(base::Value(std::move(dict)), &json);
    // Copy json into block (prevent UAF).
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(json.c_str(), 2, ctx);  // event_type=2 (removed)
    });
  }

 private:
  void DispatchEvent(owl::mojom::DownloadItemPtr item, int32_t type) {
    if (!g_download_event_cb) return;
    std::string json = DownloadItemToJson(item);
    auto cb = g_download_event_cb;
    auto ctx = g_download_event_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(json.c_str(), type, ctx);
    });
  }
};

// Download service state — bound on IO thread.
struct DownloadState {
  mojo::Remote<owl::mojom::DownloadService> remote;
  // Observer lifecycle managed here (prevent premature destruction).
  std::unique_ptr<DownloadObserverImpl> observer_impl;
  std::unique_ptr<mojo::Receiver<owl::mojom::DownloadObserver>>
      observer_receiver;
};
base::NoDestructor<std::unique_ptr<DownloadState>> g_download_service;

// Storage service state — bound on IO thread, per-context.
struct StorageState {
  mojo::Remote<owl::mojom::StorageService> remote;
};
base::NoDestructor<std::unique_ptr<StorageState>> g_storage_service;

// Forward declaration (defined below, after WebViewEntry).
class WebViewObserverImpl;

// Phase 1 multi-WebView: per-webview state and callbacks.
struct WebViewEntry {
  mojo::Remote<owl::mojom::WebViewHost> remote;
  std::unique_ptr<mojo::Receiver<owl::mojom::WebViewObserver>> observer_receiver;
  // Observer impl must outlive the receiver (prevent use-after-free).
  std::unique_ptr<WebViewObserverImpl> observer_impl;
  // Observer for page info and render surface callbacks.
  OWLBridge_PageInfoCallback page_info_cb = nullptr;
  void* page_info_ctx = nullptr;
  OWLBridge_RenderSurfaceCallback render_surface_cb = nullptr;
  void* render_surface_ctx = nullptr;
  OWLBridge_UnhandledKeyCallback unhandled_key_cb = nullptr;
  void* unhandled_key_ctx = nullptr;
  OWLBridge_CursorChangeCallback cursor_cb = nullptr;
  void* cursor_ctx = nullptr;
  OWLBridge_CaretRectCallback caret_rect_cb = nullptr;
  void* caret_rect_ctx = nullptr;
  OWLBridge_FindResultCallback find_result_callback = nullptr;
  void* find_result_ctx = nullptr;
  OWLBridge_ZoomChangedCallback zoom_changed_callback = nullptr;
  void* zoom_changed_ctx = nullptr;
  // Phase 4: Security state callback (per-webview).
  OWLBridge_SecurityStateCallback security_state_cb = nullptr;
  void* security_state_ctx = nullptr;
  // Context menu callback (per-webview).
  OWLBridge_ContextMenuCallback context_menu_cb = nullptr;
  void* context_menu_ctx = nullptr;
  // Phase 3: Copy-image result callback (per-webview).
  OWLBridge_CopyImageResultCallback copy_image_result_cb = nullptr;
  void* copy_image_result_ctx = nullptr;
  // Phase 2 Navigation: navigation lifecycle callbacks (per-webview).
  OWLBridge_NavigationStartedCallback nav_started_cb = nullptr;
  void* nav_started_ctx = nullptr;
  OWLBridge_NavigationCommittedCallback nav_committed_cb = nullptr;
  void* nav_committed_ctx = nullptr;
  OWLBridge_NavigationErrorCallback nav_error_cb = nullptr;
  void* nav_error_ctx = nullptr;
  // Console message callback (per-webview, Phase 2).
  OWLBridge_ConsoleMessageCallback console_message_cb = nullptr;
  void* console_message_ctx = nullptr;
  // Phase 3 Multi-tab: new tab requested callback (per-webview).
  OWLBridge_NewTabRequestedCallback new_tab_requested_cb = nullptr;
  void* new_tab_requested_ctx = nullptr;
  // Phase 3 Multi-tab: close requested callback (per-webview).
  OWLBridge_CloseRequestedCallback close_requested_cb = nullptr;
  void* close_requested_ctx = nullptr;
  // Load finished callback (per-webview).
  OWLBridge_LoadFinishedCallback load_finished_cb = nullptr;
  void* load_finished_ctx = nullptr;
};

// Map of all WebView entries keyed by Host-assigned webview_id.
base::NoDestructor<std::map<uint64_t, std::unique_ptr<WebViewEntry>>> g_webviews;

// Currently active webview_id. 0 = none active.
// UI thread only — no atomic needed.
uint64_t g_active_webview_id = 0;

// Helper: look up a WebViewEntry by ID. Returns nullptr if not found.
// Must be called on IO thread (where entries live).
// Phase 2: webview_id=0 is no longer accepted as "active" — callers must
// pass the correct webview_id explicitly.
WebViewEntry* GetWebViewEntry(uint64_t webview_id) {
  // DCHECK in debug builds to catch callers that still pass webview_id=0.
  // In release, we silently return nullptr for backwards compatibility.
  DCHECK_NE(webview_id, 0u)
      << "GetWebViewEntry called with webview_id=0; callers must pass a "
         "valid webview_id (Phase 2 audit)";
  if (webview_id == 0) return nullptr;
  auto it = g_webviews->find(webview_id);
  if (it == g_webviews->end()) return nullptr;
  return it->second.get();
}

// Phase 2: g_compat_webview removed. All code paths use GetWebViewEntry(webview_id).

// WebViewObserver implementation (receives Host→Client callbacks on IO thread).
// Phase 1: Holds webview_id, not raw pointer — safe against reallocation.
class WebViewObserverImpl : public owl::mojom::WebViewObserver {
 public:
  explicit WebViewObserverImpl(uint64_t webview_id) : webview_id_(webview_id) {}

  // Resolve the entry on each callback (safe against entry destruction).
  WebViewEntry* entry() const { return GetWebViewEntry(webview_id_); }

  void OnPageInfoChanged(owl::mojom::PageInfoPtr info) override {
    auto* e = entry();
    if (!e || !e->page_info_cb) return;
    uint64_t wid = webview_id_;
    std::string title = info->title;
    std::string url = info->url;
    bool loading = info->is_loading;
    bool back = info->can_go_back;
    bool fwd = info->can_go_forward;
    auto cb = e->page_info_cb;
    auto ctx = e->page_info_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, title.c_str(), url.c_str(), loading ? 1 : 0,
         back ? 1 : 0, fwd ? 1 : 0, ctx);
    });
  }

  void OnLoadFinished(bool success) override {
    LOG(INFO) << "[OWL] load finished, success=" << success
              << " webview_id=" << webview_id_;
    auto* e = entry();
    if (!e || !e->load_finished_cb) return;
    uint64_t wid = webview_id_;
    int ok = success ? 1 : 0;
    auto cb = e->load_finished_cb;
    auto ctx = e->load_finished_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, ok, ctx);
    });
  }

  void OnRenderSurfaceChanged(uint32_t ca_context_id,
                               mojo::PlatformHandle io_surface_port,
                               const gfx::Size& pixel_size,
                               float scale_factor) override {
    auto* e = entry();
    if (!e || !e->render_surface_cb) return;
    uint64_t wid = webview_id_;
    uint32_t ctx_id = ca_context_id;
    uint32_t w = pixel_size.width();
    uint32_t h = pixel_size.height();
    float s = scale_factor;
    auto cb = e->render_surface_cb;
    auto ctx = e->render_surface_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, ctx_id, w, h, s, ctx);
    });
  }

  void OnUnhandledKeyEvent(owl::mojom::KeyEventPtr event) override {
    auto* e = entry();
    if (!e || !e->unhandled_key_cb) return;
    uint64_t wid = webview_id_;
    int type = static_cast<int>(event->type);
    int key_code = event->native_key_code;
    uint32_t mods = event->modifiers;
    std::string chars = event->characters.value_or("");
    auto cb = e->unhandled_key_cb;
    auto ctx = e->unhandled_key_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, type, key_code, mods,
         chars.empty() ? nullptr : chars.c_str(), ctx);
    });
  }

  void OnCursorChanged(owl::mojom::CursorType cursor_type) override {
    auto* e = entry();
    if (!e || !e->cursor_cb) return;
    uint64_t wid = webview_id_;
    int32_t ct = static_cast<int32_t>(cursor_type);
    auto cb = e->cursor_cb;
    auto ctx = e->cursor_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, ct, ctx);
    });
  }

  void OnCaretRectChanged(const gfx::Rect& caret_rect) override {
    auto* e = entry();
    if (!e || !e->caret_rect_cb) return;
    uint64_t wid = webview_id_;
    float x = caret_rect.x();
    float y = caret_rect.y();
    float w = caret_rect.width();
    float h = caret_rect.height();
    auto cb = e->caret_rect_cb;
    auto ctx = e->caret_rect_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, x, y, w, h, ctx);
    });
  }

  void OnFindReply(int32_t request_id,
                   int32_t number_of_matches,
                   int32_t active_match_ordinal,
                   bool final_update) override {
    auto* e = entry();
    if (!e || !e->find_result_callback) return;
    uint64_t wid = webview_id_;
    auto cb = e->find_result_callback;
    auto ctx = e->find_result_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, request_id, number_of_matches, active_match_ordinal,
         final_update ? 1 : 0, ctx);
    });
  }

  void OnZoomLevelChanged(double new_level) override {
    auto* e = entry();
    if (!e || !e->zoom_changed_callback) return;
    uint64_t wid = webview_id_;
    auto cb = e->zoom_changed_callback;
    auto ctx = e->zoom_changed_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, new_level, ctx);
    });
  }

  void OnPermissionRequest(const std::string& origin,
                           owl::mojom::PermissionType type,
                           uint64_t request_id) override {
    if (!g_permission_request_cb) return;
    uint64_t wid = webview_id_;
    // BH-011: Record request_id → webview_id for correct routing.
    (*g_permission_request_origins)[request_id] = wid;
    std::string origin_copy = origin;
    int type_int = static_cast<int>(type);
    auto cb = g_permission_request_cb;
    auto ctx = g_permission_request_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, origin_copy.c_str(), type_int, request_id, ctx);
    });
  }

  // Phase 4: SSL error notification.
  void OnSSLError(const std::string& url,
                  const std::string& cert_subject,
                  const std::string& error_description,
                  uint64_t error_id) override {
    if (!g_ssl_error_cb) return;
    uint64_t wid = webview_id_;
    // BH-011: Record error_id → webview_id for correct routing.
    (*g_ssl_error_origins)[error_id] = wid;
    std::string url_copy = url;
    std::string subject_copy = cert_subject;
    std::string desc_copy = error_description;
    auto cb = g_ssl_error_cb;
    auto ctx = g_ssl_error_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, url_copy.c_str(), subject_copy.c_str(), desc_copy.c_str(),
         error_id, ctx);
    });
  }

  // Phase 4: Security state changed notification.
  void OnSecurityStateChanged(int32_t level,
                               const std::string& cert_subject,
                               const std::string& error_description) override {
    auto* e = entry();
    if (!e || !e->security_state_cb) return;
    uint64_t wid = webview_id_;
    std::string subject_copy = cert_subject;
    std::string desc_copy = error_description;
    auto cb = e->security_state_cb;
    auto ctx = e->security_state_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, level, subject_copy.c_str(), desc_copy.c_str(), ctx);
    });
  }

  // Context menu notification.
  void OnContextMenu(owl::mojom::ContextMenuParamsPtr params) override {
    auto* e = entry();
    if (!e || !e->context_menu_cb) return;
    uint64_t wid = webview_id_;
    int32_t type = static_cast<int32_t>(params->type);
    int is_editable = params->is_editable ? 1 : 0;
    // Value-capture std::string to prevent UAF across dispatch_async.
    std::string link_url = params->link_url.value_or("");
    std::string src_url = params->src_url.value_or("");
    int has_image = params->has_image_contents ? 1 : 0;
    std::string selection_text = params->selection_text.value_or("");
    std::string page_url = params->page_url;
    int32_t x = params->x;
    int32_t y = params->y;
    uint32_t menu_id = params->menu_id;
    auto cb = e->context_menu_cb;
    auto ctx = e->context_menu_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, type, is_editable,
         link_url.empty() ? nullptr : link_url.c_str(),
         src_url.empty() ? nullptr : src_url.c_str(),
         has_image,
         selection_text.empty() ? nullptr : selection_text.c_str(),
         page_url.c_str(),
         x, y, menu_id, ctx);
    });
  }

  // Phase 3: Copy-image async result.
  void OnCopyImageResult(bool success,
                         const std::optional<std::string>& fallback_url) override {
    auto* e = entry();
    if (!e || !e->copy_image_result_cb) return;
    uint64_t wid = webview_id_;
    int success_int = success ? 1 : 0;
    std::string fb = fallback_url.value_or("");
    auto cb = e->copy_image_result_cb;
    auto ctx = e->copy_image_result_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, success_int,
         fb.empty() ? nullptr : fb.c_str(),
         ctx);
    });
  }

  // Phase 3 HTTP Auth: auth challenge notification.
  void OnAuthRequired(const std::string& url,
                      const std::string& realm,
                      const std::string& scheme,
                      uint64_t auth_id,
                      bool is_proxy) override {
    if (!g_auth_required_cb) return;
    uint64_t wid = webview_id_;
    // BH-011: Record auth_id → webview_id for correct routing.
    (*g_auth_request_origins)[auth_id] = wid;
    std::string url_copy = url;
    std::string realm_copy = realm;
    std::string scheme_copy = scheme;
    int proxy_int = is_proxy ? 1 : 0;
    auto cb = g_auth_required_cb;
    auto ctx = g_auth_required_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, url_copy.c_str(), realm_copy.c_str(), scheme_copy.c_str(),
         auth_id, proxy_int, ctx);
    });
  }

  // Console message (Phase 2: C-ABI callback wiring).
  void OnConsoleMessage(owl::mojom::ConsoleMessagePtr message) override {
    auto* e = entry();
    if (!e || !e->console_message_cb) return;
    uint64_t wid = webview_id_;
    int level = static_cast<int>(message->level);
    std::string msg = message->message;
    std::string source = message->source;
    int line = message->line_number;
    double timestamp = message->timestamp;
    auto cb = e->console_message_cb;
    auto ctx = e->console_message_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, level, msg.c_str(), source.c_str(), line, timestamp, ctx);
    });
  }

  // Navigation lifecycle events (Phase 2: C-ABI callback wiring).
  void OnNavigationStarted(owl::mojom::NavigationEventPtr event) override {
    auto* e = entry();
    if (!e || !e->nav_started_cb) return;
    uint64_t wid = webview_id_;
    int64_t nav_id = event->navigation_id;
    std::string url = event->url;
    int user_init = event->is_user_initiated ? 1 : 0;
    int redirect = event->is_redirect ? 1 : 0;
    auto cb = e->nav_started_cb;
    auto ctx = e->nav_started_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, nav_id, url.c_str(), user_init, redirect, ctx);
    });
  }

  void OnNavigationCommitted(owl::mojom::NavigationEventPtr event) override {
    auto* e = entry();
    if (!e || !e->nav_committed_cb) return;
    uint64_t wid = webview_id_;
    int64_t nav_id = event->navigation_id;
    std::string url = event->url;
    int status = event->http_status_code;
    auto cb = e->nav_committed_cb;
    auto ctx = e->nav_committed_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, nav_id, url.c_str(), status, ctx);
    });
  }

  // Note: OnNavigationFailed has 4 scalar params, NOT NavigationEventPtr.
  void OnNavigationFailed(int64_t navigation_id,
                          const std::string& url,
                          int32_t error_code,
                          const std::string& error_description) override {
    auto* e = entry();
    if (!e || !e->nav_error_cb) return;
    uint64_t wid = webview_id_;
    int64_t nav_id = navigation_id;
    std::string u = url;
    std::string desc = error_description;
    auto cb = e->nav_error_cb;
    auto ctx = e->nav_error_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, nav_id, u.c_str(), error_code, desc.c_str(), ctx);
    });
  }

  // Phase 3 Multi-tab: New tab requested by Host (target="_blank", Cmd+Click,
  // window.open with user gesture).
  void OnNewTabRequested(const std::string& url, bool foreground) override {
    auto* e = entry();
    if (!e || !e->new_tab_requested_cb) return;
    uint64_t wid = webview_id_;
    std::string url_copy = url;
    int fg = foreground ? 1 : 0;
    auto cb = e->new_tab_requested_cb;
    auto ctx = e->new_tab_requested_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, url_copy.c_str(), fg, ctx);
    });
  }

  // Phase 3 Multi-tab: Host requests client to close this WebView
  // (e.g., window.close()).
  void OnWebViewCloseRequested() override {
    LOG(INFO) << "[OWL] OnWebViewCloseRequested for webview_id="
              << webview_id_;
    auto* e = entry();
    if (!e || !e->close_requested_cb) return;
    uint64_t wid = webview_id_;
    auto cb = e->close_requested_cb;
    auto ctx = e->close_requested_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(wid, ctx);
    });
  }

 private:
  uint64_t webview_id_;
};

}  // namespace

void OWLBridge_GetHostInfo(OWLBridge_HostInfoCallback callback, void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  CHECK(*g_session) << "No active session";

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_HostInfoCallback cb, void* ctx) {
            (*g_session)->remote->GetHostInfo(base::BindOnce(
                [](OWLBridge_HostInfoCallback cb, void* ctx,
                   const std::string& version,
                   const std::string& user_data_dir,
                   uint16_t devtools_port) {
                  std::string v = version;
                  std::string d = user_data_dir;
                  uint16_t p = devtools_port;
                  dispatch_async(dispatch_get_main_queue(), ^{
                    cb(v.c_str(), d.c_str(), p, nullptr, ctx);
                  });
                },
                cb, ctx));
          },
          callback, ctx));
}

// BH-014: Shared state for parallel service initialization.
// All callbacks run on the IO thread (Mojo single-sequence guarantee).
struct ServiceInitState {
  OWLBridge_ContextCallback cb;
  void* ctx;
  int completed = 0;
  std::vector<std::string> errors;
  static constexpr int kTotalServices = 5;  // Bookmark, History, Permission, Download, Storage

  void OnServiceDone(bool success, const std::string& service_name) {
    if (!success) {
      errors.push_back(service_name);
    }
    ++completed;
    if (completed == kTotalServices) {
      // All services attempted — dispatch result to main thread.
      if (errors.empty()) {
        auto final_cb = cb;
        auto final_ctx = ctx;
        dispatch_async(dispatch_get_main_queue(), ^{
          final_cb(1, nullptr, final_ctx);
        });
      } else {
        std::string error_msg = "Services failed: ";
        for (size_t i = 0; i < errors.size(); ++i) {
          if (i > 0) error_msg += ", ";
          error_msg += errors[i];
        }
        auto final_cb = cb;
        auto final_ctx = ctx;
        dispatch_async(dispatch_get_main_queue(), ^{
          final_cb(1, error_msg.c_str(), final_ctx);
        });
      }
    }
  }
};

void OWLBridge_CreateBrowserContext(const char* partition_name,
                                    int off_the_record,
                                    OWLBridge_ContextCallback callback,
                                    void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  CHECK(*g_session) << "No active session";

  std::string partition = partition_name ? partition_name : "";
  bool otr = off_the_record != 0;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string partition, bool otr,
             OWLBridge_ContextCallback cb, void* ctx) {
            auto config = owl::mojom::ProfileConfig::New();
            if (!partition.empty())
              config->partition_name = partition;
            config->off_the_record = otr;

            LOG(INFO) << "[OWL] Calling CreateBrowserContext on IO thread"
                      << " remote.is_connected=" << (*g_session)->remote.is_connected()
                      << " remote.is_bound=" << (*g_session)->remote.is_bound();
            (*g_session)->remote->CreateBrowserContext(
                std::move(config),
                base::BindOnce(
                    [](OWLBridge_ContextCallback cb, void* ctx,
                       mojo::PendingRemote<owl::mojom::BrowserContextHost>
                           context_remote) {
                      if (!context_remote.is_valid()) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                          cb(0, "CreateBrowserContext failed", ctx);
                        });
                        return;
                      }
                      LOG(INFO) << "[OWL] CreateBrowserContext response received";
                      *g_context = std::make_unique<ContextState>();
                      (*g_context)->remote.Bind(std::move(context_remote));

                      // BH-014: Parallel service initialization.
                      auto state = std::make_shared<ServiceInitState>();
                      state->cb = cb;
                      state->ctx = ctx;

                      // 1. BookmarkService
                      (*g_context)->remote->GetBookmarkService(
                          base::BindOnce(
                              [](std::shared_ptr<ServiceInitState> state,
                                 mojo::PendingRemote<owl::mojom::BookmarkService>
                                     bm_remote) {
                                if (bm_remote.is_valid()) {
                                  *g_bookmark_service =
                                      std::make_unique<BookmarkState>();
                                  (*g_bookmark_service)->remote.Bind(
                                      std::move(bm_remote));
                                  (*g_bookmark_service)->remote
                                      .set_disconnect_handler(
                                          base::BindOnce([]() {
                                            LOG(ERROR) << "[OWL] BookmarkService disconnected";
                                            g_bookmark_service->reset();
                                          }));
                                  LOG(INFO) << "[OWL] BookmarkService bound";
                                  state->OnServiceDone(true, "BookmarkService");
                                } else {
                                  LOG(ERROR) << "[OWL] GetBookmarkService returned invalid remote";
                                  state->OnServiceDone(false, "BookmarkService");
                                }
                              },
                              state));

                      // 2. HistoryService
                      (*g_context)->remote->GetHistoryService(
                          base::BindOnce(
                              [](std::shared_ptr<ServiceInitState> state,
                                 mojo::PendingRemote<owl::mojom::HistoryService>
                                     hs_remote) {
                                if (hs_remote.is_valid()) {
                                  *g_history_service =
                                      std::make_unique<HistoryState>();
                                  (*g_history_service)->remote.Bind(
                                      std::move(hs_remote));
                                  (*g_history_service)->remote
                                      .set_disconnect_handler(
                                          base::BindOnce([]() {
                                            LOG(ERROR) << "[OWL] HistoryService disconnected";
                                            g_history_service->reset();
                                          }));
                                  LOG(INFO) << "[OWL] HistoryService bound";
                                  // Set up HistoryObserver for push notifications.
                                  *g_history_observer =
                                      std::make_unique<HistoryObserverImpl>();
                                  *g_history_observer_receiver =
                                      std::make_unique<mojo::Receiver<owl::mojom::HistoryObserver>>(
                                          g_history_observer->get());
                                  mojo::PendingRemote<owl::mojom::HistoryObserver>
                                      observer_remote;
                                  (*g_history_observer_receiver)
                                      ->Bind(observer_remote
                                                 .InitWithNewPipeAndPassReceiver());
                                  (*g_history_service)->remote->SetObserver(
                                      std::move(observer_remote));
                                  LOG(INFO) << "[OWL] HistoryObserver bound";
                                  state->OnServiceDone(true, "HistoryService");
                                } else {
                                  LOG(ERROR) << "[OWL] GetHistoryService returned invalid remote";
                                  state->OnServiceDone(false, "HistoryService");
                                }
                              },
                              state));

                      // 3. PermissionService
                      (*g_context)->remote->GetPermissionService(
                          base::BindOnce(
                              [](std::shared_ptr<ServiceInitState> state,
                                 mojo::PendingRemote<owl::mojom::PermissionService>
                                     ps_remote) {
                                if (ps_remote.is_valid()) {
                                  *g_permission_service =
                                      std::make_unique<PermissionServiceState>();
                                  (*g_permission_service)->remote.Bind(
                                      std::move(ps_remote));
                                  (*g_permission_service)->remote
                                      .set_disconnect_handler(
                                          base::BindOnce([]() {
                                            LOG(ERROR) << "[OWL] PermissionService disconnected";
                                            g_permission_service->reset();
                                          }));
                                  LOG(INFO) << "[OWL] PermissionService bound";
                                  state->OnServiceDone(true, "PermissionService");
                                } else {
                                  LOG(ERROR) << "[OWL] GetPermissionService returned invalid remote";
                                  state->OnServiceDone(false, "PermissionService");
                                }
                              },
                              state));

                      // 4. DownloadService
                      (*g_context)->remote->GetDownloadService(
                          base::BindOnce(
                              [](std::shared_ptr<ServiceInitState> state,
                                 mojo::PendingRemote<owl::mojom::DownloadService>
                                     ds_remote) {
                                if (ds_remote.is_valid()) {
                                  *g_download_service =
                                      std::make_unique<DownloadState>();
                                  (*g_download_service)->remote.Bind(
                                      std::move(ds_remote));
                                  (*g_download_service)->remote
                                      .set_disconnect_handler(
                                          base::BindOnce([]() {
                                            LOG(ERROR) << "[OWL] DownloadService disconnected";
                                            g_download_service->reset();
                                          }));
                                  LOG(INFO) << "[OWL] DownloadService bound";
                                  // Set up DownloadObserver for push notifications.
                                  (*g_download_service)->observer_impl =
                                      std::make_unique<DownloadObserverImpl>();
                                  (*g_download_service)->observer_receiver =
                                      std::make_unique<mojo::Receiver<owl::mojom::DownloadObserver>>(
                                          (*g_download_service)->observer_impl.get());
                                  mojo::PendingRemote<owl::mojom::DownloadObserver>
                                      obs_remote;
                                  (*g_download_service)->observer_receiver
                                      ->Bind(obs_remote
                                                 .InitWithNewPipeAndPassReceiver());
                                  // Register observer via BrowserContextHost.
                                  (*g_context)->remote->SetDownloadObserver(
                                      std::move(obs_remote));
                                  LOG(INFO) << "[OWL] DownloadObserver bound";
                                  state->OnServiceDone(true, "DownloadService");
                                } else {
                                  LOG(WARNING) << "[OWL] GetDownloadService returned invalid remote (no download service yet — this is expected at startup)";
                                  // DownloadService is nullable in Mojom — treat null as
                                  // graceful degradation, not failure.
                                  state->OnServiceDone(true, "DownloadService");
                                }
                              },
                              state));

                      // 5. StorageService
                      (*g_context)->remote->GetStorageService(
                          base::BindOnce(
                              [](std::shared_ptr<ServiceInitState> state,
                                 mojo::PendingRemote<owl::mojom::StorageService>
                                     ss_remote) {
                                if (ss_remote.is_valid()) {
                                  *g_storage_service =
                                      std::make_unique<StorageState>();
                                  (*g_storage_service)->remote.Bind(
                                      std::move(ss_remote));
                                  (*g_storage_service)->remote
                                      .set_disconnect_handler(
                                          base::BindOnce([]() {
                                            LOG(ERROR) << "[OWL] StorageService disconnected";
                                            g_storage_service->reset();
                                          }));
                                  LOG(INFO) << "[OWL] StorageService bound";
                                  state->OnServiceDone(true, "StorageService");
                                } else {
                                  LOG(ERROR) << "[OWL] GetStorageService returned invalid remote";
                                  state->OnServiceDone(false, "StorageService");
                                }
                              },
                              state));
                    },
                    cb, ctx));
          },
          std::move(partition), otr, callback, ctx));
}

void OWLBridge_CreateWebView(uint64_t context_id,
                              OWLBridge_WebViewCallback callback,
                              void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  CHECK(*g_context) << "No active browser context";

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_WebViewCallback cb, void* ctx) {
            // Deferred-bind pattern: create a pipe pair up front but only
            // bind the receiver after we know the real webview_id.  This
            // avoids the placeholder-observer + SetObserver dance that
            // caused observer-pipe mis-binding and lost OnLoadFinished
            // events.
            mojo::PendingRemote<owl::mojom::WebViewObserver> observer_remote;
            auto observer_pending_receiver =
                observer_remote.InitWithNewPipeAndPassReceiver();

            (*g_context)->remote->CreateWebView(
                std::move(observer_remote),
                base::BindOnce(
                    [](OWLBridge_WebViewCallback cb, void* ctx,
                       mojo::PendingReceiver<owl::mojom::WebViewObserver>
                           pending_receiver,
                       uint64_t webview_id,
                       mojo::PendingRemote<owl::mojom::WebViewHost>
                           webview_remote) {
                      if (!webview_remote.is_valid() || webview_id == 0) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                          cb(0, "CreateWebView failed", ctx);
                        });
                        return;
                      }
                      // Now we know the real webview_id — create the
                      // observer impl and bind the deferred receiver.
                      auto entry = std::make_unique<WebViewEntry>();
                      entry->observer_impl =
                          std::make_unique<WebViewObserverImpl>(webview_id);
                      entry->observer_receiver =
                          std::make_unique<mojo::Receiver<owl::mojom::WebViewObserver>>(
                              entry->observer_impl.get(),
                              std::move(pending_receiver));
                      entry->remote.Bind(std::move(webview_remote));

                      // Insert into map.
                      (*g_webviews)[webview_id] = std::move(entry);

                      // Auto-activate the first webview.
                      if (g_active_webview_id == 0) {
                        g_active_webview_id = webview_id;
                      }

                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(webview_id, nullptr, ctx);
                      });
                    },
                    cb, ctx, std::move(observer_pending_receiver)));
          },
          callback, ctx));
}

void OWLBridge_DestroyWebView(uint64_t webview_id,
                              OWLBridge_DestroyWebViewCallback callback,
                              void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  if (webview_id == 0) {
    if (callback) {
      dispatch_async(dispatch_get_main_queue(), ^{
        callback("webview_id=0 is not valid for destroy", ctx);
      });
    }
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_DestroyWebViewCallback cb, void* ctx) {
            auto it = g_webviews->find(wid);
            if (it == g_webviews->end()) {
              if (cb) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  cb("WebView not found", ctx);
                });
              }
              return;
            }
            // Erase entry — pipe disconnect triggers Host-side cleanup.
            g_webviews->erase(it);

            // BH-011: Clean up orphaned request origin entries for this webview.
            std::erase_if(*g_permission_request_origins,
                          [wid](const auto& pair) { return pair.second == wid; });
            std::erase_if(*g_ssl_error_origins,
                          [wid](const auto& pair) { return pair.second == wid; });
            std::erase_if(*g_auth_request_origins,
                          [wid](const auto& pair) { return pair.second == wid; });

            // Clear active if it was this one.
            if (g_active_webview_id == wid) {
              g_active_webview_id = 0;
            }

            if (cb) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, ctx);
              });
            }
          },
          webview_id, callback, ctx));
}

void OWLBridge_SetActiveWebView(uint64_t webview_id,
                                 OWLBridge_SetActiveCallback callback,
                                 void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_SetActiveCallback cb, void* ctx) {
            uint64_t prev_id = g_active_webview_id;

            // Deactivate previous if different.
            if (prev_id != 0 && prev_id != wid) {
              auto* prev = GetWebViewEntry(prev_id);
              if (prev && prev->remote.is_connected()) {
                prev->remote->SetActive(false);
              }
            }

            if (wid == 0) {
              // Deactivate all.
              g_active_webview_id = 0;
            } else {
              auto* entry = GetWebViewEntry(wid);
              if (!entry) {
                if (cb) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                    cb("WebView not found", ctx);
                  });
                }
                return;
              }
              if (entry->remote.is_connected()) {
                entry->remote->SetActive(true);
              }
              g_active_webview_id = wid;
            }

            if (cb) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, ctx);
              });
            }
          },
          webview_id, callback, ctx));
}

uint64_t OWLBridge_GetActiveWebViewId(void) {
  return g_active_webview_id;
}

void OWLBridge_Navigate(uint64_t webview_id,
                         const char* url,
                         OWLBridge_NavigateCallback callback,
                         void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));

  std::string url_str(url);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, std::string url_str,
             OWLBridge_NavigateCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, 0, "WebView not found or disconnected", ctx);
              });
              return;
            }
            GURL gurl(url_str);
            e->remote->Navigate(
                gurl,
                base::BindOnce(
                    [](OWLBridge_NavigateCallback cb, void* ctx,
                       owl::mojom::NavigationResultPtr result) {
                      int success = result->success ? 1 : 0;
                      int status = result->http_status_code;
                      std::string err =
                          result->error_description.value_or("");
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(success, status,
                           err.empty() ? nullptr : err.c_str(), ctx);
                      });
                    },
                    cb, ctx));
          },
          webview_id, std::move(url_str), callback, ctx));
}

void OWLBridge_SetPageInfoCallback(uint64_t webview_id,
                                    OWLBridge_PageInfoCallback callback,
                                    void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_PageInfoCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->page_info_cb = cb;
            e->page_info_ctx = ctx;
          },
          webview_id, callback, ctx));
}

void OWLBridge_SetLoadFinishedCallback(uint64_t webview_id,
                                        OWLBridge_LoadFinishedCallback callback,
                                        void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_LoadFinishedCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->load_finished_cb = cb;
            e->load_finished_ctx = ctx;
          },
          webview_id, callback, ctx));
}

void OWLBridge_SetRenderSurfaceCallback(uint64_t webview_id,
                                         OWLBridge_RenderSurfaceCallback callback,
                                         void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_RenderSurfaceCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->render_surface_cb = cb;
            e->render_surface_ctx = ctx;
          },
          webview_id, callback, ctx));
}

// === View Geometry ===

void OWLBridge_UpdateViewGeometry(uint64_t webview_id,
                                   uint32_t dip_width,
                                   uint32_t dip_height,
                                   float scale_factor,
                                   OWLBridge_UpdateGeometryCallback callback,
                                   void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));

  gfx::Size dip_size(dip_width, dip_height);
  float scale = scale_factor;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, gfx::Size dip_size, float scale,
             OWLBridge_UpdateGeometryCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) {
              if (cb) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  cb("WebView not found or disconnected", ctx);
                });
              }
              return;
            }
            e->remote->UpdateViewGeometry(
                dip_size, scale,
                base::BindOnce(
                    [](OWLBridge_UpdateGeometryCallback cb, void* ctx) {
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          webview_id, dip_size, scale, callback, ctx));
}

// === Input Events (fire-and-forget) ===

void OWLBridge_SendMouseEvent(uint64_t webview_id,
                               int type, int button,
                               float x, float y,
                               float global_x, float global_y,
                               uint32_t modifiers,
                               int click_count,
                               double timestamp) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  auto event = owl::mojom::MouseEvent::New();
  event->type = static_cast<owl::mojom::MouseEventType>(type);
  event->button = static_cast<owl::mojom::MouseButton>(button);
  event->x = x;
  event->y = y;
  event->global_x = global_x;
  event->global_y = global_y;
  event->modifiers = modifiers;
  event->click_count = click_count;
  event->timestamp = base::TimeTicks() + base::Seconds(timestamp);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, owl::mojom::MouseEventPtr evt) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            e->remote->SendMouseEvent(std::move(evt));
          },
          webview_id, std::move(event)));
}

void OWLBridge_SendKeyEvent(uint64_t webview_id,
                             int type,
                             int native_key_code,
                             uint32_t modifiers,
                             const char* characters,
                             const char* unmodified_characters,
                             double timestamp) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  auto event = owl::mojom::KeyEvent::New();
  event->type = static_cast<owl::mojom::KeyEventType>(type);
  event->native_key_code = native_key_code;
  event->modifiers = modifiers;
  event->timestamp = base::TimeTicks() + base::Seconds(timestamp);
  if (characters) event->characters = std::string(characters);
  if (unmodified_characters)
    event->unmodified_characters = std::string(unmodified_characters);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, owl::mojom::KeyEventPtr evt) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            e->remote->SendKeyEvent(std::move(evt));
          },
          webview_id, std::move(event)));
}

void OWLBridge_SendWheelEvent(uint64_t webview_id,
                               float x, float y,
                               float global_x, float global_y,
                               float delta_x, float delta_y,
                               uint32_t modifiers,
                               int phase, int momentum_phase,
                               int delta_units,
                               double timestamp) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  auto event = owl::mojom::WheelEvent::New();
  event->x = x;
  event->y = y;
  event->global_x = global_x;
  event->global_y = global_y;
  event->delta_x = delta_x;
  event->delta_y = delta_y;
  event->modifiers = modifiers;
  event->phase = static_cast<owl::mojom::ScrollPhase>(phase);
  event->momentum_phase = static_cast<owl::mojom::ScrollPhase>(momentum_phase);
  event->delta_units =
      static_cast<owl::mojom::ScrollDeltaUnits>(delta_units);
  event->timestamp = base::TimeTicks() + base::Seconds(timestamp);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, owl::mojom::WheelEventPtr evt) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            e->remote->SendWheelEvent(std::move(evt));
          },
          webview_id, std::move(event)));
}

void OWLBridge_SetUnhandledKeyCallback(uint64_t webview_id,
                                        OWLBridge_UnhandledKeyCallback callback,
                                        void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_UnhandledKeyCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->unhandled_key_cb = cb;
            e->unhandled_key_ctx = ctx;
          },
          webview_id, callback, ctx));
}

void OWLBridge_SetCursorChangeCallback(uint64_t webview_id,
                                        OWLBridge_CursorChangeCallback callback,
                                        void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_CursorChangeCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->cursor_cb = cb;
            e->cursor_ctx = ctx;
          },
          webview_id, callback, ctx));
}

void OWLBridge_SetCaretRectCallback(uint64_t webview_id,
                                     OWLBridge_CaretRectCallback callback,
                                     void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_CaretRectCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->caret_rect_cb = cb;
            e->caret_rect_ctx = ctx;
          },
          webview_id, callback, ctx));
}

// === IME Events ===

void OWLBridge_ImeSetComposition(uint64_t webview_id,
                                  const char* text,
                                  int32_t selection_start,
                                  int32_t selection_end,
                                  int32_t replacement_start,
                                  int32_t replacement_end) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  // Copy text before PostTask to prevent UAF (text is C string from ObjC .UTF8String).
  std::string text_copy(text ? text : "");
  int32_t ss = selection_start, se = selection_end;
  int32_t rs = replacement_start, re = replacement_end;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, std::string t, int32_t ss, int32_t se,
             int32_t rs, int32_t re) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            e->remote->SendImeSetComposition(std::move(t), ss, se, rs, re);
          },
          webview_id, std::move(text_copy), ss, se, rs, re));
}

void OWLBridge_ImeCommitText(uint64_t webview_id,
                              const char* text,
                              int32_t replacement_start,
                              int32_t replacement_end) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  std::string text_copy(text ? text : "");
  int32_t rs = replacement_start, re = replacement_end;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, std::string t, int32_t rs, int32_t re) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            e->remote->SendImeCommitText(std::move(t), rs, re);
          },
          webview_id, std::move(text_copy), rs, re));
}

void OWLBridge_ImeFinishComposing(uint64_t webview_id) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce([](uint64_t wid) {
        auto* e = GetWebViewEntry(wid);
        if (!e || !e->remote.is_connected()) return;
        e->remote->SendImeFinishComposing();
      }, webview_id));
}

// === Find-in-Page ===

void OWLBridge_Find(uint64_t webview_id,
                    const char* query,
                    int forward,
                    int match_case,
                    OWLBridge_FindCallback callback,
                    void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  if (!callback) return;
  // Empty/null query: still call callback(0) to maintain C-ABI contract.
  if (!query || !*query) {
    dispatch_async(dispatch_get_main_queue(), ^{ callback(0, ctx); });
    return;
  }
  std::string query_str(query);  // Copy before PostTask.

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, std::string q, bool fwd, bool mc,
             OWLBridge_FindCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{ cb(0, ctx); });
              return;
            }
            e->remote->Find(
                q, fwd, mc,
                base::BindOnce(
                    [](OWLBridge_FindCallback cb, void* ctx,
                       int32_t request_id) {
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(request_id, ctx);
                      });
                    },
                    cb, ctx));
          },
          webview_id, std::move(query_str), forward != 0, match_case != 0,
          callback, ctx));
}

void OWLBridge_StopFinding(uint64_t webview_id,
                            OWLBridgeStopFindAction action) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  // Explicit switch-case per project convention (no static_cast for enums).
  owl::mojom::StopFindAction mojom_action;
  switch (action) {
    case OWLBridgeStopFindAction_KeepSelection:
      mojom_action = owl::mojom::StopFindAction::kKeepSelection; break;
    case OWLBridgeStopFindAction_ActivateSelection:
      mojom_action = owl::mojom::StopFindAction::kActivateSelection; break;
    case OWLBridgeStopFindAction_ClearSelection:
    default:
      mojom_action = owl::mojom::StopFindAction::kClearSelection; break;
  }
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, owl::mojom::StopFindAction act) {
            auto* e = GetWebViewEntry(wid);
            if (e && e->remote.is_connected()) {
              e->remote->StopFinding(act);
            }
          },
          webview_id, mojom_action));
}

void OWLBridge_SetFindResultCallback(uint64_t webview_id,
                                      OWLBridge_FindResultCallback callback,
                                      void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_FindResultCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->find_result_callback = cb;
            e->find_result_ctx = ctx;
          },
          webview_id, callback, ctx));
}

// === Zoom Control (Phase 34) ===

void OWLBridge_SetZoomLevel(uint64_t webview_id, double level,
                             OWLBridge_ZoomCallback callback, void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  (*g_io_thread)->task_runner()->PostTask(FROM_HERE,
      base::BindOnce([](uint64_t wid, double lvl,
                        OWLBridge_ZoomCallback cb, void* ctx) {
        auto* e = GetWebViewEntry(wid);
        if (e && e->remote.is_connected()) {
          e->remote->SetZoomLevel(lvl,
              base::BindOnce([](OWLBridge_ZoomCallback cb, void* ctx) {
                dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(ctx); });
              }, cb, ctx));
        } else if (cb) {
          dispatch_async(dispatch_get_main_queue(), ^{ cb(ctx); });
        }
      }, webview_id, level, callback, ctx));
}

void OWLBridge_GetZoomLevel(uint64_t webview_id,
                             OWLBridge_GetZoomCallback callback, void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  if (!callback) return;
  (*g_io_thread)->task_runner()->PostTask(FROM_HERE,
      base::BindOnce([](uint64_t wid, OWLBridge_GetZoomCallback cb, void* ctx) {
        auto* e = GetWebViewEntry(wid);
        if (e && e->remote.is_connected()) {
          e->remote->GetZoomLevel(
              base::BindOnce([](OWLBridge_GetZoomCallback cb, void* ctx,
                               double level) {
                dispatch_async(dispatch_get_main_queue(), ^{ cb(level, ctx); });
              }, cb, ctx));
        } else {
          dispatch_async(dispatch_get_main_queue(), ^{ cb(0.0, ctx); });
        }
      }, webview_id, callback, ctx));
}

void OWLBridge_SetZoomChangedCallback(uint64_t webview_id,
                                       OWLBridge_ZoomChangedCallback callback,
                                       void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_ZoomChangedCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->zoom_changed_callback = cb;
            e->zoom_changed_ctx = ctx;
          },
          webview_id, callback, ctx));
}

// === JavaScript Evaluation ===

void OWLBridge_EvaluateJavaScript(uint64_t webview_id,
                                   const char* expression,
                                   OWLBridge_JSResultCallback callback,
                                   void* ctx) {
  if (!callback) return;

  // All error paths async to guarantee exactly-once + always-async.
  if (!expression) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback("expression is NULL", 1, ctx);
    });
    return;
  }

  std::string expr(expression);
  auto cb = callback;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, std::string expr,
             OWLBridge_JSResultCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb("No webview remote", 1, ctx);
              });
              return;
            }
            e->remote->EvaluateJavaScript(
                expr,
                base::BindOnce(
                    [](OWLBridge_JSResultCallback cb, void* ctx,
                       const std::string& result, int32_t result_type) {
                      std::string r = result;
                      int32_t rt = result_type;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(r.c_str(), rt, ctx);
                      });
                    },
                    cb, ctx));
          },
          webview_id, std::move(expr), cb, ctx));
}

// === Bookmarks (Phase 35) ===

namespace {

// Convert a BookmarkItem to JSON string via base::Value::Dict + JSONWriter.
std::string BookmarkItemToJson(const owl::mojom::BookmarkItemPtr& item) {
  base::DictValue dict;
  dict.Set("id", item->id);
  dict.Set("title", item->title);
  dict.Set("url", item->url);
  if (item->parent_id.has_value()) {
    dict.Set("parent_id", item->parent_id.value());
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(dict)), &json);
  return json;
}

// Convert a list of BookmarkItems to a JSON array string.
std::string BookmarkListToJson(
    const std::vector<owl::mojom::BookmarkItemPtr>& items) {
  base::ListValue list;
  for (const auto& item : items) {
    base::DictValue dict;
    dict.Set("id", item->id);
    dict.Set("title", item->title);
    dict.Set("url", item->url);
    if (item->parent_id.has_value()) {
      dict.Set("parent_id", item->parent_id.value());
    }
    list.Append(std::move(dict));
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(list)), &json);
  return json;
}

}  // namespace

void OWLBridge_BookmarkAdd(const char* title,
                            const char* url,
                            const char* parent_id,
                            OWLBridge_BookmarkAddCallback callback,
                            void* ctx) {
  if (!callback) return;
  if (!title || !url) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, "title and url are required", ctx);
    });
    return;
  }
  if (!*g_bookmark_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, "No bookmark service", ctx);
    });
    return;
  }

  std::string t(title);
  std::string u(url);
  std::optional<std::string> pid;
  if (parent_id) {
    pid = std::string(parent_id);
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string t, std::string u, std::optional<std::string> pid,
             OWLBridge_BookmarkAddCallback cb, void* ctx) {
            if (!*g_bookmark_service ||
                !(*g_bookmark_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, "BookmarkService disconnected", ctx);
              });
              return;
            }
            (*g_bookmark_service)->remote->Add(
                t, u, std::move(pid),
                base::BindOnce(
                    [](OWLBridge_BookmarkAddCallback cb, void* ctx,
                       owl::mojom::BookmarkItemPtr item) {
                      if (!item) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                          cb(nullptr, "Add failed (invalid title or URL)", ctx);
                        });
                        return;
                      }
                      std::string json = BookmarkItemToJson(item);
                      auto cb_copy = cb;
                      auto ctx_copy = ctx;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb_copy(json.c_str(), nullptr, ctx_copy);
                      });
                    },
                    cb, ctx));
          },
          std::move(t), std::move(u), std::move(pid), callback, ctx));
}

void OWLBridge_BookmarkGetAll(OWLBridge_BookmarkListCallback callback,
                               void* ctx) {
  if (!callback) return;
  if (!*g_bookmark_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, "No bookmark service", ctx);
    });
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_BookmarkListCallback cb, void* ctx) {
            if (!*g_bookmark_service ||
                !(*g_bookmark_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, "BookmarkService disconnected", ctx);
              });
              return;
            }
            (*g_bookmark_service)->remote->GetAll(
                base::BindOnce(
                    [](OWLBridge_BookmarkListCallback cb, void* ctx,
                       std::vector<owl::mojom::BookmarkItemPtr> items) {
                      std::string json = BookmarkListToJson(items);
                      auto cb_copy = cb;
                      auto ctx_copy = ctx;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb_copy(json.c_str(), nullptr, ctx_copy);
                      });
                    },
                    cb, ctx));
          },
          callback, ctx));
}

void OWLBridge_BookmarkRemove(const char* bookmark_id,
                               OWLBridge_BookmarkResultCallback callback,
                               void* ctx) {
  if (!callback) return;
  if (!bookmark_id) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "bookmark_id is required", ctx);
    });
    return;
  }
  if (!*g_bookmark_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "No bookmark service", ctx);
    });
    return;
  }

  std::string id(bookmark_id);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string id, OWLBridge_BookmarkResultCallback cb, void* ctx) {
            if (!*g_bookmark_service ||
                !(*g_bookmark_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, "BookmarkService disconnected", ctx);
              });
              return;
            }
            (*g_bookmark_service)->remote->Remove(
                id,
                base::BindOnce(
                    [](OWLBridge_BookmarkResultCallback cb, void* ctx,
                       bool success) {
                      int s = success ? 1 : 0;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(s, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          std::move(id), callback, ctx));
}

void OWLBridge_BookmarkUpdate(const char* bookmark_id,
                               const char* title,
                               const char* url,
                               OWLBridge_BookmarkResultCallback callback,
                               void* ctx) {
  if (!callback) return;
  if (!bookmark_id) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "bookmark_id is required", ctx);
    });
    return;
  }
  if (!*g_bookmark_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "No bookmark service", ctx);
    });
    return;
  }

  std::string id(bookmark_id);
  std::optional<std::string> t = title ? std::make_optional(std::string(title))
                                       : std::nullopt;
  std::optional<std::string> u = url ? std::make_optional(std::string(url))
                                     : std::nullopt;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string id, std::optional<std::string> t,
             std::optional<std::string> u,
             OWLBridge_BookmarkResultCallback cb, void* ctx) {
            if (!*g_bookmark_service ||
                !(*g_bookmark_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, "BookmarkService disconnected", ctx);
              });
              return;
            }
            (*g_bookmark_service)->remote->Update(
                id, std::move(t), std::move(u),
                base::BindOnce(
                    [](OWLBridge_BookmarkResultCallback cb, void* ctx,
                       bool success) {
                      int s = success ? 1 : 0;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(s, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          std::move(id), std::move(t), std::move(u), callback, ctx));
}

// === History (Phase 2 History) ===

namespace {

// Convert a list of mojom HistoryEntries to a JSON array string.
std::string HistoryEntryListToJson(
    const std::vector<owl::mojom::HistoryEntryPtr>& entries) {
  base::ListValue list;
  for (const auto& entry : entries) {
    base::DictValue dict;
    // base::Value has no int64 type; use string to avoid double precision loss.
    dict.Set("visit_id", base::NumberToString(entry->id));
    dict.Set("url", entry->url);
    dict.Set("title", entry->title);
    dict.Set("visit_time", entry->visit_time.InSecondsFSinceUnixEpoch());
    dict.Set("last_visit_time",
             entry->last_visit_time.InSecondsFSinceUnixEpoch());
    dict.Set("visit_count", entry->visit_count);
    list.Append(std::move(dict));
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(list)), &json);
  return json;
}

}  // namespace

void OWLBridge_HistoryQueryByTime(const char* query,
                                   int32_t max_results,
                                   int32_t offset,
                                   OWLBridge_HistoryQueryCallback callback,
                                   void* ctx) {
  if (!callback) return;
  if (!*g_history_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, 0, "No history service", ctx);
    });
    return;
  }

  std::string q(query ? query : "");

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string q, int32_t max, int32_t offset,
             OWLBridge_HistoryQueryCallback cb, void* ctx) {
            if (!*g_history_service ||
                !(*g_history_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, 0, "HistoryService disconnected", ctx);
              });
              return;
            }
            (*g_history_service)->remote->QueryByTime(
                q, max, offset,
                base::BindOnce(
                    [](OWLBridge_HistoryQueryCallback cb, void* ctx,
                       std::vector<owl::mojom::HistoryEntryPtr> entries,
                       int32_t total) {
                      std::string json = HistoryEntryListToJson(entries);
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(json.c_str(), total, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          std::move(q), max_results, offset, callback, ctx));
}

void OWLBridge_HistoryQueryByVisitCount(const char* query,
                                         int32_t max_results,
                                         OWLBridge_HistoryQueryCallback callback,
                                         void* ctx) {
  if (!callback) return;
  if (!*g_history_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, 0, "No history service", ctx);
    });
    return;
  }

  std::string q(query ? query : "");

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string q, int32_t max,
             OWLBridge_HistoryQueryCallback cb, void* ctx) {
            if (!*g_history_service ||
                !(*g_history_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, 0, "HistoryService disconnected", ctx);
              });
              return;
            }
            (*g_history_service)->remote->QueryByVisitCount(
                q, max,
                base::BindOnce(
                    [](OWLBridge_HistoryQueryCallback cb, void* ctx,
                       std::vector<owl::mojom::HistoryEntryPtr> entries) {
                      std::string json = HistoryEntryListToJson(entries);
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(json.c_str(), -1, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          std::move(q), max_results, callback, ctx));
}

void OWLBridge_HistoryDelete(const char* url,
                              OWLBridge_HistoryBoolCallback callback,
                              void* ctx) {
  if (!callback) return;
  if (!url) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "url is required", ctx);
    });
    return;
  }
  if (!*g_history_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "No history service", ctx);
    });
    return;
  }

  std::string u(url);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string u, OWLBridge_HistoryBoolCallback cb, void* ctx) {
            if (!*g_history_service ||
                !(*g_history_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, "HistoryService disconnected", ctx);
              });
              return;
            }
            (*g_history_service)->remote->Delete(
                u,
                base::BindOnce(
                    [](OWLBridge_HistoryBoolCallback cb, void* ctx,
                       bool success) {
                      int s = success ? 1 : 0;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(s, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          std::move(u), callback, ctx));
}

void OWLBridge_HistoryDeleteRange(double start_time,
                                   double end_time,
                                   OWLBridge_HistoryIntCallback callback,
                                   void* ctx) {
  if (!callback) return;
  if (!*g_history_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "No history service", ctx);
    });
    return;
  }

  base::Time start = base::Time::FromSecondsSinceUnixEpoch(start_time);
  base::Time end = base::Time::FromSecondsSinceUnixEpoch(end_time);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::Time start, base::Time end,
             OWLBridge_HistoryIntCallback cb, void* ctx) {
            if (!*g_history_service ||
                !(*g_history_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, "HistoryService disconnected", ctx);
              });
              return;
            }
            (*g_history_service)->remote->DeleteRange(
                start, end,
                base::BindOnce(
                    [](OWLBridge_HistoryIntCallback cb, void* ctx,
                       int32_t deleted_count) {
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(deleted_count, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          start, end, callback, ctx));
}

void OWLBridge_HistoryClear(OWLBridge_HistoryBoolCallback callback,
                             void* ctx) {
  if (!callback) return;
  if (!*g_history_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "No history service", ctx);
    });
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_HistoryBoolCallback cb, void* ctx) {
            if (!*g_history_service ||
                !(*g_history_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, "HistoryService disconnected", ctx);
              });
              return;
            }
            (*g_history_service)->remote->Clear(
                base::BindOnce(
                    [](OWLBridge_HistoryBoolCallback cb, void* ctx,
                       bool success) {
                      int s = success ? 1 : 0;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(s, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          callback, ctx));
}

// === Permissions ===

void OWLBridge_SetPermissionRequestCallback(
    OWLBridge_PermissionRequestCallback callback,
    void* callback_context) {
  // main thread only (consistent with all C-ABI registration functions).
  g_permission_request_cb = callback;
  g_permission_request_ctx = callback_context;
}

void OWLBridge_RespondToPermission(uint64_t request_id, int status) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  // Range check: PermissionStatus is 0=Granted, 1=Denied, 2=Ask.
  // Out-of-range values default to DENIED to prevent undefined enum values.
  if (status < 0 || status > 2) {
    LOG(WARNING) << "[OWL] RespondToPermission: invalid status "
                 << status << ", defaulting to DENIED";
    status = 1;  // kDenied
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t rid, int st) {
            // BH-011: Look up originating webview from map instead of
            // g_active_webview_id.
            auto it = g_permission_request_origins->find(rid);
            if (it == g_permission_request_origins->end()) return;
            uint64_t wid = it->second;
            g_permission_request_origins->erase(it);

            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            e->remote->RespondToPermissionRequest(
                rid, static_cast<owl::mojom::PermissionStatus>(st));
          },
          request_id, status));
}

void OWLBridge_PermissionGet(const char* origin,
                              int permission_type,
                              OWLBridge_PermissionGetCallback callback,
                              void* ctx) {
  if (!callback) return;
  if (!origin) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(2, "origin is required", ctx);  // 2 = kAsk
    });
    return;
  }
  if (!*g_permission_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(2, "No permission service", ctx);
    });
    return;
  }

  // Range check permission_type (0-3).
  if (permission_type < 0 || permission_type > 3) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(2, "Invalid permission type", ctx);
    });
    return;
  }

  std::string origin_str(origin);
  auto perm_type = static_cast<owl::mojom::PermissionType>(permission_type);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string origin_str, owl::mojom::PermissionType perm_type,
             OWLBridge_PermissionGetCallback cb, void* ctx) {
            if (!*g_permission_service ||
                !(*g_permission_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(2, "PermissionService disconnected", ctx);
              });
              return;
            }
            (*g_permission_service)->remote->GetPermission(
                origin_str, perm_type,
                base::BindOnce(
                    [](OWLBridge_PermissionGetCallback cb, void* ctx,
                       owl::mojom::PermissionStatus status) {
                      int s = static_cast<int>(status);
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(s, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          std::move(origin_str), perm_type, callback, ctx));
}

void OWLBridge_PermissionGetAll(OWLBridge_PermissionListCallback callback,
                                 void* ctx) {
  if (!callback) return;
  if (!*g_permission_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, "No permission service", ctx);
    });
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_PermissionListCallback cb, void* ctx) {
            if (!*g_permission_service ||
                !(*g_permission_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, "PermissionService disconnected", ctx);
              });
              return;
            }
            (*g_permission_service)->remote->GetAllPermissions(
                base::BindOnce(
                    [](OWLBridge_PermissionListCallback cb, void* ctx,
                       std::vector<owl::mojom::SitePermissionPtr> perms) {
                      base::ListValue list;
                      for (const auto& p : perms) {
                        base::DictValue dict;
                        dict.Set("origin", p->origin);
                        dict.Set("type", static_cast<int>(p->type));
                        dict.Set("status", static_cast<int>(p->status));
                        list.Append(std::move(dict));
                      }
                      std::string json;
                      base::JSONWriter::Write(list, &json);
                      std::string json_copy = json;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(json_copy.c_str(), nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          callback, ctx));
}

void OWLBridge_PermissionSet(const char* origin,
                             int permission_type,
                             int status) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!origin) return;
  if (permission_type < 0 || permission_type > 3) return;
  if (status < 0 || status > 2) return;
  if (!*g_permission_service) return;

  std::string origin_str(origin);
  auto perm_type = static_cast<owl::mojom::PermissionType>(permission_type);
  auto perm_status = static_cast<owl::mojom::PermissionStatus>(status);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string origin_str, owl::mojom::PermissionType perm_type,
             owl::mojom::PermissionStatus perm_status) {
            if (!*g_permission_service ||
                !(*g_permission_service)->remote.is_connected()) return;
            (*g_permission_service)->remote->SetPermission(
                origin_str, perm_type, perm_status);
          },
          std::move(origin_str), perm_type, perm_status));
}

void OWLBridge_PermissionReset(const char* origin, int permission_type) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!origin) return;
  if (permission_type < 0 || permission_type > 3) return;
  if (!*g_permission_service) return;

  std::string origin_str(origin);
  auto perm_type = static_cast<owl::mojom::PermissionType>(permission_type);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string origin_str, owl::mojom::PermissionType perm_type) {
            if (!*g_permission_service ||
                !(*g_permission_service)->remote.is_connected()) return;
            (*g_permission_service)->remote->ResetPermission(
                origin_str, perm_type);
          },
          std::move(origin_str), perm_type));
}

void OWLBridge_PermissionResetAll(void) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!*g_permission_service) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce([]() {
        if (!*g_permission_service ||
            !(*g_permission_service)->remote.is_connected()) return;
        (*g_permission_service)->remote->ResetAll();
      }));
}

// === SSL Security (Phase 4) ===

void OWLBridge_SetSSLErrorCallback(
    OWLBridge_SSLErrorCallback callback,
    void* callback_context) {
  // main thread only (consistent with all C-ABI registration functions).
  g_ssl_error_cb = callback;
  g_ssl_error_ctx = callback_context;
}

void OWLBridge_RespondToSSLError(uint64_t error_id, int proceed) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t eid, bool p) {
            // BH-011: Look up originating webview from map.
            auto it = g_ssl_error_origins->find(eid);
            if (it == g_ssl_error_origins->end()) return;
            uint64_t wid = it->second;
            g_ssl_error_origins->erase(it);

            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            e->remote->RespondToSSLError(eid, p);
          },
          error_id, proceed != 0));
}

void OWLBridge_SetSecurityStateCallback(
    uint64_t webview_id,
    OWLBridge_SecurityStateCallback callback,
    void* callback_context) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_SecurityStateCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->security_state_cb = cb;
            e->security_state_ctx = ctx;
          },
          webview_id, callback, callback_context));
}

// === HTTP Auth (Phase 3) ===

void OWLBridge_SetAuthRequiredCallback(
    uint64_t webview_id,
    OWLBridge_AuthRequiredCallback callback,
    void* callback_context) {
  // main thread only (consistent with all C-ABI registration functions).
  g_auth_required_cb = callback;
  g_auth_required_ctx = callback_context;
}

void OWLBridge_RespondToAuth(
    uint64_t auth_id,
    const char* username,
    const char* password) {
  if (!g_initialized.load(std::memory_order_acquire)) return;

  // username=NULL means cancel.
  std::optional<std::string> u;
  std::optional<std::string> p;
  if (username) {
    u = std::string(username);
    p = password ? std::string(password) : std::string();
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t aid, std::optional<std::string> user,
             std::optional<std::string> pass) {
            // BH-011: Look up originating webview from map.
            auto it = g_auth_request_origins->find(aid);
            if (it == g_auth_request_origins->end()) return;
            uint64_t wid = it->second;
            g_auth_request_origins->erase(it);

            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            e->remote->RespondToAuthChallenge(aid, user, pass);
          },
          auth_id, std::move(u), std::move(p)));
}

// === History Observer (Push Pipeline) ===

void OWLBridge_SetHistoryChangedCallback(
    OWLBridge_HistoryChangedCallback callback,
    void* callback_context) {
  // main thread only (consistent with all C-ABI registration functions).
  g_history_changed_cb = callback;
  g_history_changed_ctx = callback_context;
}

// === Downloads (Phase 2 Download Manager) ===

namespace {

// Convert a list of mojom DownloadItems to a JSON array string.
std::string DownloadItemListToJson(
    const std::vector<owl::mojom::DownloadItemPtr>& items) {
  base::ListValue list;
  for (const auto& item : items) {
    base::DictValue dict;
    dict.Set("id", static_cast<int>(item->id));
    dict.Set("url", item->url);
    dict.Set("filename", item->filename);
    dict.Set("mime_type", item->mime_type);
    dict.Set("total_bytes", static_cast<double>(item->total_bytes));
    dict.Set("received_bytes", static_cast<double>(item->received_bytes));
    dict.Set("speed_bytes_per_sec",
             static_cast<double>(item->speed_bytes_per_sec));
    dict.Set("state", static_cast<int>(item->state));
    dict.Set("can_resume", item->can_resume);
    dict.Set("target_path", item->target_path);
    if (item->error_description.has_value()) {
      dict.Set("error_description", item->error_description.value());
    }
    list.Append(std::move(dict));
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(list)), &json);
  return json;
}

}  // namespace

void OWLBridge_DownloadGetAll(OWLBridge_DownloadListCallback callback,
                               void* ctx) {
  if (!callback) return;
  if (!*g_download_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, "No download service", ctx);
    });
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_DownloadListCallback cb, void* ctx) {
            if (!*g_download_service ||
                !(*g_download_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, "DownloadService disconnected", ctx);
              });
              return;
            }
            (*g_download_service)->remote->GetAll(
                base::BindOnce(
                    [](OWLBridge_DownloadListCallback cb, void* ctx,
                       std::vector<owl::mojom::DownloadItemPtr> items) {
                      std::string json = DownloadItemListToJson(items);
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(json.c_str(), nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          callback, ctx));
}

void OWLBridge_DownloadPause(uint32_t download_id) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!*g_download_service) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint32_t id) {
            if (!*g_download_service ||
                !(*g_download_service)->remote.is_connected()) return;
            (*g_download_service)->remote->Pause(id);
          },
          download_id));
}

void OWLBridge_DownloadResume(uint32_t download_id) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!*g_download_service) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint32_t id) {
            if (!*g_download_service ||
                !(*g_download_service)->remote.is_connected()) return;
            (*g_download_service)->remote->Resume(id);
          },
          download_id));
}

void OWLBridge_DownloadCancel(uint32_t download_id) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!*g_download_service) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint32_t id) {
            if (!*g_download_service ||
                !(*g_download_service)->remote.is_connected()) return;
            (*g_download_service)->remote->Cancel(id);
          },
          download_id));
}

void OWLBridge_DownloadRemoveEntry(uint32_t download_id) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!*g_download_service) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint32_t id) {
            if (!*g_download_service ||
                !(*g_download_service)->remote.is_connected()) return;
            (*g_download_service)->remote->RemoveEntry(id);
          },
          download_id));
}

void OWLBridge_DownloadOpenFile(uint32_t download_id) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!*g_download_service) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint32_t id) {
            if (!*g_download_service ||
                !(*g_download_service)->remote.is_connected()) return;
            (*g_download_service)->remote->OpenFile(id);
          },
          download_id));
}

void OWLBridge_DownloadShowInFolder(uint32_t download_id) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!*g_download_service) return;

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint32_t id) {
            if (!*g_download_service ||
                !(*g_download_service)->remote.is_connected()) return;
            (*g_download_service)->remote->ShowInFolder(id);
          },
          download_id));
}

void OWLBridge_SetDownloadCallback(OWLBridge_DownloadEventCallback callback,
                                    void* ctx) {
  // PostTask to IO thread for thread safety — g_download_event_cb/ctx are
  // only read on IO thread (by DownloadObserverImpl).
  if (!g_initialized.load(std::memory_order_acquire)) {
    g_download_event_cb = callback;
    g_download_event_ctx = ctx;
    return;
  }
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_DownloadEventCallback cb, void* ctx) {
            g_download_event_cb = cb;
            g_download_event_ctx = ctx;
          },
          callback, ctx));
}

// === Context Menu ===

void OWLBridge_SetContextMenuCallback(
    uint64_t webview_id,
    OWLBridge_ContextMenuCallback callback,
    void* callback_context) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_ContextMenuCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->context_menu_cb = cb;
            e->context_menu_ctx = ctx;
          },
          webview_id, callback, callback_context));
}

void OWLBridge_ExecuteContextMenuAction(
    uint64_t webview_id,
    int32_t action,
    uint32_t menu_id,
    const char* payload) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  // Copy payload before PostTask (caller may free after return).
  std::optional<std::string> payload_str;
  if (payload) {
    payload_str = std::string(payload);
  }
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, int32_t act, uint32_t mid,
             std::optional<std::string> pl) {
            auto* e = GetWebViewEntry(wid);
            if (!e || !e->remote.is_connected()) return;
            // Map int32_t to Mojom enum.
            owl::mojom::ContextMenuAction mojo_action;
            switch (act) {
              case 0: mojo_action = owl::mojom::ContextMenuAction::kCopyLink; break;
              case 1: mojo_action = owl::mojom::ContextMenuAction::kCopyImage; break;
              case 2: mojo_action = owl::mojom::ContextMenuAction::kSaveImage; break;
              case 3: mojo_action = owl::mojom::ContextMenuAction::kCopy; break;
              case 4: mojo_action = owl::mojom::ContextMenuAction::kCut; break;
              case 5: mojo_action = owl::mojom::ContextMenuAction::kPaste; break;
              case 6: mojo_action = owl::mojom::ContextMenuAction::kSelectAll; break;
              case 7: mojo_action = owl::mojom::ContextMenuAction::kOpenLinkInNewTab; break;
              case 8: mojo_action = owl::mojom::ContextMenuAction::kSearch; break;
              case 9: mojo_action = owl::mojom::ContextMenuAction::kCopyImageUrl; break;
              case 10: mojo_action = owl::mojom::ContextMenuAction::kViewSource; break;
              default: return;  // Invalid action, ignore.
            }
            e->remote->ExecuteContextMenuAction(mojo_action, mid,
                                                std::move(pl));
          },
          webview_id, action, menu_id, std::move(payload_str)));
}

// Phase 3: Copy-image result callback registration.
void OWLBridge_SetCopyImageResultCallback(
    uint64_t webview_id,
    OWLBridge_CopyImageResultCallback callback,
    void* callback_context) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_CopyImageResultCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->copy_image_result_cb = cb;
            e->copy_image_result_ctx = ctx;
          },
          webview_id, callback, callback_context));
}

// === Navigation Lifecycle Callbacks (Phase 2) ===

void OWLBridge_SetNavigationStartedCallback(
    uint64_t webview_id,
    OWLBridge_NavigationStartedCallback callback,
    void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_NavigationStartedCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->nav_started_cb = cb;
            e->nav_started_ctx = ctx;
          },
          webview_id, callback, ctx));
}

void OWLBridge_SetNavigationCommittedCallback(
    uint64_t webview_id,
    OWLBridge_NavigationCommittedCallback callback,
    void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_NavigationCommittedCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->nav_committed_cb = cb;
            e->nav_committed_ctx = ctx;
          },
          webview_id, callback, ctx));
}

void OWLBridge_SetNavigationErrorCallback(
    uint64_t webview_id,
    OWLBridge_NavigationErrorCallback callback,
    void* ctx) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_NavigationErrorCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->nav_error_cb = cb;
            e->nav_error_ctx = ctx;
          },
          webview_id, callback, ctx));
}

// === Console Message Callback (Phase 2) ===

void OWLBridge_SetConsoleMessageCallback(
    uint64_t webview_id,
    OWLBridge_ConsoleMessageCallback callback,
    void* callback_context) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_ConsoleMessageCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->console_message_cb = cb;
            e->console_message_ctx = ctx;
          },
          webview_id, callback, callback_context));
}

// === New Tab / Close Tab (Phase 3 Multi-tab) ===

void OWLBridge_SetNewTabRequestedCallback(
    uint64_t webview_id,
    OWLBridge_NewTabRequestedCallback callback,
    void* callback_context) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_NewTabRequestedCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->new_tab_requested_cb = cb;
            e->new_tab_requested_ctx = ctx;
          },
          webview_id, callback, callback_context));
}

void OWLBridge_SetCloseRequestedCallback(
    uint64_t webview_id,
    OWLBridge_CloseRequestedCallback callback,
    void* callback_context) {
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t wid, OWLBridge_CloseRequestedCallback cb, void* ctx) {
            auto* e = GetWebViewEntry(wid);
            if (!e) return;
            e->close_requested_cb = cb;
            e->close_requested_ctx = ctx;
          },
          webview_id, callback, callback_context));
}

// === Storage (Cookie/Storage Management) ===

namespace {

// Convert a list of mojom CookieDomains to a JSON array string.
std::string CookieDomainListToJson(
    const std::vector<owl::mojom::CookieDomainPtr>& domains) {
  base::ListValue list;
  for (const auto& domain : domains) {
    base::DictValue dict;
    dict.Set("domain", domain->domain);
    dict.Set("count", domain->cookie_count);
    list.Append(std::move(dict));
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(list)), &json);
  return json;
}

// Convert a list of mojom StorageUsageEntries to a JSON array string.
std::string StorageUsageListToJson(
    const std::vector<owl::mojom::StorageUsageEntryPtr>& usage) {
  base::ListValue list;
  for (const auto& entry : usage) {
    base::DictValue dict;
    dict.Set("origin", entry->origin);
    dict.Set("usage_bytes", static_cast<double>(entry->usage_bytes));
    list.Append(std::move(dict));
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(list)), &json);
  return json;
}

}  // namespace

void OWLBridge_StorageGetCookieDomains(
    OWLBridge_StorageJsonCallback callback, void* ctx) {
  if (!callback) return;
  if (!*g_storage_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, "No storage service", ctx);
    });
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_StorageJsonCallback cb, void* ctx) {
            if (!*g_storage_service ||
                !(*g_storage_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, "StorageService disconnected", ctx);
              });
              return;
            }
            (*g_storage_service)->remote->GetCookieDomains(
                base::BindOnce(
                    [](OWLBridge_StorageJsonCallback cb, void* ctx,
                       std::vector<owl::mojom::CookieDomainPtr> domains) {
                      std::string json = CookieDomainListToJson(domains);
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(json.c_str(), nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          callback, ctx));
}

void OWLBridge_StorageDeleteDomain(
    const char* domain,
    OWLBridge_StorageIntCallback callback, void* ctx) {
  if (!callback) return;
  if (!domain) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "domain is required", ctx);
    });
    return;
  }
  if (!*g_storage_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "No storage service", ctx);
    });
    return;
  }

  std::string d(domain);

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string d, OWLBridge_StorageIntCallback cb, void* ctx) {
            if (!*g_storage_service ||
                !(*g_storage_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, "StorageService disconnected", ctx);
              });
              return;
            }
            (*g_storage_service)->remote->DeleteCookiesForDomain(
                d,
                base::BindOnce(
                    [](OWLBridge_StorageIntCallback cb, void* ctx,
                       int32_t deleted_count) {
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(deleted_count, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          std::move(d), callback, ctx));
}

void OWLBridge_StorageClearData(
    uint32_t data_types, double start_time, double end_time,
    OWLBridge_StorageBoolCallback callback, void* ctx) {
  if (!callback) return;
  if (!*g_storage_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(0, "No storage service", ctx);
    });
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint32_t types, double start, double end,
             OWLBridge_StorageBoolCallback cb, void* ctx) {
            if (!*g_storage_service ||
                !(*g_storage_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(0, "StorageService disconnected", ctx);
              });
              return;
            }
            (*g_storage_service)->remote->ClearBrowsingData(
                types, start, end,
                base::BindOnce(
                    [](OWLBridge_StorageBoolCallback cb, void* ctx,
                       bool success) {
                      int s = success ? 1 : 0;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(s, nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          data_types, start_time, end_time, callback, ctx));
}

void OWLBridge_StorageGetUsage(
    OWLBridge_StorageJsonCallback callback, void* ctx) {
  if (!callback) return;
  if (!*g_storage_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, "No storage service", ctx);
    });
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_StorageJsonCallback cb, void* ctx) {
            if (!*g_storage_service ||
                !(*g_storage_service)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{
                cb(nullptr, "StorageService disconnected", ctx);
              });
              return;
            }
            (*g_storage_service)->remote->GetStorageUsage(
                base::BindOnce(
                    [](OWLBridge_StorageJsonCallback cb, void* ctx,
                       std::vector<owl::mojom::StorageUsageEntryPtr> usage) {
                      std::string json = StorageUsageListToJson(usage);
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(json.c_str(), nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          callback, ctx));
}

// === Memory ===

void OWLBridge_Free(void* ptr) {
  free(ptr);
}

// === URL Helpers ===

char* OWLBridge_CanonicalizeUrl(const char* input) {
  GURL url(input);
  if (!url.is_valid())
    return nullptr;
  std::string spec = url.spec();
  char* result = static_cast<char*>(malloc(spec.size() + 1));
  memcpy(result, spec.c_str(), spec.size() + 1);
  return result;
}

int OWLBridge_InputLooksLikeURL(const char* input) {
  std::string s(input);
  // Contains spaces → definitely a search query.
  if (s.find(' ') != std::string::npos)
    return 0;
  // Explicit scheme → treat as URL (http://, https://, file://, etc.).
  if (s.find("://") != std::string::npos)
    return 1;
  // localhost with optional port → URL.
  if (s.substr(0, 9) == "localhost")
    return 1;
  // Contains a dot (e.g. "example.com") → URL.
  if (s.find('.') != std::string::npos)
    return 1;
  return 0;
}
