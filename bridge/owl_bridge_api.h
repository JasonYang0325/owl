// Copyright 2026 AntlerAI. All rights reserved.
// OWL Bridge C-ABI — Swift-callable functions for Mojo IPC.
// Modeled after ChatGPT Atlas's OwlBridge architecture.
//
// Threading: All functions are safe to call from any thread unless noted.
// Callbacks are always dispatched on the main thread (dispatch_get_main_queue).
//
// Memory ownership:
// - ReadMessage: returned data/handles owned by caller, free with OWLBridge_Free
// - WriteMessage: handles consumed on success, caller retains on failure
// - All char* returns: free with OWLBridge_Free

#ifndef THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_API_H_
#define THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_API_H_

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OWL_EXPORT __attribute__((visibility("default")))

// === Lifecycle ===

// Initialize Mojo runtime. Must be called once from main thread before
// any other OWLBridge function. Creates IO thread + IPC support internally.
// Does NOT create a main-thread TaskExecutor (SwiftUI owns the run loop).
OWL_EXPORT void OWLBridge_Initialize(void);

// === Host Process ===

// Callback for LaunchHost.
// Success: pipe > 0, pid > 0, error_msg = NULL
// Failure: pipe = 0, pid = 0, error_msg != NULL
// Guaranteed exactly-once on main thread.
typedef void (*OWLBridge_LaunchCallback)(uint64_t session_pipe,
                                         pid_t child_pid,
                                         const char* error_msg,
                                         void* context);

// Launch owl_host process. Callback fires on main thread.
// Internally: PlatformChannel + LaunchProcess + OutgoingInvitation on IO thread.
OWL_EXPORT void OWLBridge_LaunchHost(const char* host_path,
                          const char* user_data_dir,
                          uint16_t devtools_port,
                          OWLBridge_LaunchCallback callback,
                          void* callback_context);

// === Message Pipes ===

// Create a message pipe pair. Both handles owned by caller.
OWL_EXPORT void OWLBridge_CreateMessagePipe(uint64_t* handle0, uint64_t* handle1);

// Close a Mojo handle. Must be called for all owned handles.
OWL_EXPORT void OWLBridge_CloseHandle(uint64_t handle);

// Write a message to a pipe.
// On success (returns 0): handles in array are consumed (caller loses ownership).
// On failure (returns non-0): caller still owns all handles.
OWL_EXPORT int OWLBridge_WriteMessage(uint64_t pipe_handle,
                           const void* data, uint32_t data_size,
                           const uint64_t* handles, uint32_t num_handles);

// Read a message from a pipe (non-blocking).
// Returns 0 on success, MOJO_RESULT_SHOULD_WAIT if no message available.
// On success: *out_data and *out_handles allocated by bridge, free with OWLBridge_Free.
OWL_EXPORT int OWLBridge_ReadMessage(uint64_t pipe_handle,
                          void** out_data, uint32_t* out_data_size,
                          uint64_t** out_handles, uint32_t* out_num_handles);

// Watch a pipe for readability. Callback fires on main thread when readable.
// Thread-safe: internally PostTasks to IO thread to register MojoWatcher.
// Callback may fire multiple times until handle is closed.
typedef void (*OWLBridge_PipeReadableCallback)(uint64_t pipe_handle,
                                               int result,
                                               void* context);
OWL_EXPORT int OWLBridge_WatchPipe(uint64_t pipe_handle,
                        OWLBridge_PipeReadableCallback callback,
                        void* callback_context);

// Cancel a pipe watch. Idempotent (no-op if watch_id is unknown or already fired).
// Thread-safe: internally PostTasks to IO thread.
OWL_EXPORT void OWLBridge_CancelWatch(uint64_t watch_id);

// === Memory ===

// Free memory allocated by OWLBridge (ReadMessage data/handles, strings).
OWL_EXPORT void OWLBridge_Free(void* ptr);

// === Initialization state (for OWLMojoThread Phase 25 awareness) ===
// 1 after OWLBridge_Initialize() completes. Prevents double mojo::core::Init().
OWL_EXPORT extern int g_owl_bridge_initialized;

// === High-level Session API (all callbacks on main thread) ===

// Get host info from the active session.
typedef void (*OWLBridge_HostInfoCallback)(const char* version,
                                           const char* user_data_dir,
                                           uint16_t devtools_port,
                                           const char* error_msg,
                                           void* context);
OWL_EXPORT void OWLBridge_GetHostInfo(OWLBridge_HostInfoCallback callback,
                                      void* callback_context);

// Create a browser context in the active session.
// Callback fires with context_id > 0 on success.
typedef void (*OWLBridge_ContextCallback)(uint64_t context_id,
                                          const char* error_msg,
                                          void* context);
OWL_EXPORT void OWLBridge_CreateBrowserContext(const char* partition_name,
                                               int off_the_record,
                                               OWLBridge_ContextCallback callback,
                                               void* callback_context);

// Create a web view in the given browser context.
// Callback fires with webview_id > 0 on success (Host-assigned ID).
typedef void (*OWLBridge_WebViewCallback)(uint64_t webview_id,
                                          const char* error_msg,
                                          void* context);
OWL_EXPORT void OWLBridge_CreateWebView(uint64_t context_id,
                                         OWLBridge_WebViewCallback callback,
                                         void* callback_context);

// Destroy a web view by ID. Pipe disconnect triggers Host-side cleanup.
// Callback fires on main thread after local cleanup is complete.
typedef void (*OWLBridge_DestroyWebViewCallback)(const char* error_msg,
                                                  void* context);
OWL_EXPORT void OWLBridge_DestroyWebView(uint64_t webview_id,
                                          OWLBridge_DestroyWebViewCallback callback,
                                          void* callback_context);

// Set the active web view. Only one web view can be active at a time.
// Sends SetActive(true) to the new active view and SetActive(false) to
// the previously active one. webview_id=0 deactivates all.
// Callback fires on main thread after Mojo calls are dispatched.
typedef void (*OWLBridge_SetActiveCallback)(const char* error_msg,
                                             void* context);
OWL_EXPORT void OWLBridge_SetActiveWebView(uint64_t webview_id,
                                             OWLBridge_SetActiveCallback callback,
                                             void* callback_context);

// Get the currently active web view ID. Returns 0 if none active.
// Thread-safe (reads atomic).
OWL_EXPORT uint64_t OWLBridge_GetActiveWebViewId(void);

// Navigate a web view to a URL.
typedef void (*OWLBridge_NavigateCallback)(int success,
                                           int http_status,
                                           const char* error_msg,
                                           void* context);
OWL_EXPORT void OWLBridge_Navigate(uint64_t webview_id,
                                    const char* url,
                                    OWLBridge_NavigateCallback callback,
                                    void* callback_context);

// Set a callback for page info updates (title, URL, loading state).
typedef void (*OWLBridge_PageInfoCallback)(uint64_t webview_id,
                                            const char* title,
                                            const char* url,
                                            int is_loading,
                                            int can_go_back,
                                            int can_go_forward,
                                            void* context);
OWL_EXPORT void OWLBridge_SetPageInfoCallback(uint64_t webview_id,
                                               OWLBridge_PageInfoCallback callback,
                                               void* callback_context);

// Set a callback for render surface updates (CALayerHost context ID).
typedef void (*OWLBridge_RenderSurfaceCallback)(uint64_t webview_id,
                                                 uint32_t ca_context_id,
                                                 uint32_t pixel_width,
                                                 uint32_t pixel_height,
                                                 float scale_factor,
                                                 void* context);
OWL_EXPORT void OWLBridge_SetRenderSurfaceCallback(uint64_t webview_id,
                                                     OWLBridge_RenderSurfaceCallback callback,
                                                     void* callback_context);

// === View Geometry ===

// Update viewport size for a web view.
// dip_width/dip_height: CSS pixels (DIP), NOT physical pixels.
// scale_factor: device scale (Retina = 2.0).
// Success: error_msg = NULL. Failure: error_msg != NULL.
// Callback guaranteed exactly-once on main thread.
typedef void (*OWLBridge_UpdateGeometryCallback)(const char* error_msg,
                                                  void* context);
OWL_EXPORT void OWLBridge_UpdateViewGeometry(
    uint64_t webview_id,
    uint32_t dip_width,
    uint32_t dip_height,
    float scale_factor,
    OWLBridge_UpdateGeometryCallback callback,
    void* callback_context);

// === Input Events (fire-and-forget, no callback) ===

// Mouse event. Coordinates in DIP, top-left origin (caller handles Y-flip).
// type: 0=Down, 1=Up, 2=Moved, 3=Entered, 4=Exited
// button: 0=None, 1=Left, 2=Right, 3=Middle
// timestamp: NSEvent.timestamp (seconds since boot)
OWL_EXPORT void OWLBridge_SendMouseEvent(
    uint64_t webview_id,
    int type, int button,
    float x, float y,
    float global_x, float global_y,
    uint32_t modifiers,
    int click_count,
    double timestamp);

// Key event. native_key_code is macOS virtual key code.
// type: 0=RawKeyDown, 1=KeyUp, 2=Char
// characters: UTF-8, nullable. Bridge copies before PostTask.
OWL_EXPORT void OWLBridge_SendKeyEvent(
    uint64_t webview_id,
    int type,
    int native_key_code,
    uint32_t modifiers,
    const char* characters,
    const char* unmodified_characters,
    double timestamp);

// Wheel/trackpad scroll. Coordinates in DIP, top-left origin.
// phase/momentum_phase: ScrollPhase enum (0-5)
// delta_units: 0=PrecisePixel, 1=Pixel, 2=Page
OWL_EXPORT void OWLBridge_SendWheelEvent(
    uint64_t webview_id,
    float x, float y,
    float global_x, float global_y,
    float delta_x, float delta_y,
    uint32_t modifiers,
    int phase, int momentum_phase,
    int delta_units,
    double timestamp);

// Callback for unhandled key events (renderer did not preventDefault).
typedef void (*OWLBridge_UnhandledKeyCallback)(
    uint64_t webview_id,
    int type, int native_key_code, uint32_t modifiers,
    const char* characters, void* context);
OWL_EXPORT void OWLBridge_SetUnhandledKeyCallback(
    uint64_t webview_id,
    OWLBridge_UnhandledKeyCallback callback,
    void* callback_context);

// Callback for cursor type changes (host notifies client when renderer changes cursor).
// cursor_type: CursorType enum (0=Pointer, 1=Hand, 2=IBeam, etc.)
typedef void (*OWLBridge_CursorChangeCallback)(
    uint64_t webview_id,
    int32_t cursor_type, void* context);
OWL_EXPORT void OWLBridge_SetCursorChangeCallback(
    uint64_t webview_id,
    OWLBridge_CursorChangeCallback callback,
    void* callback_context);

// === IME (Input Method Editor) Events ===

// IME composition: update marked text in renderer. Fire-and-forget.
// text: UTF-8. Bridge copies before PostTask (safe after caller returns).
// replacement_start/end: -1 = InvalidRange (no replacement).
OWL_EXPORT void OWLBridge_ImeSetComposition(
    uint64_t webview_id,
    const char* text,
    int32_t selection_start,
    int32_t selection_end,
    int32_t replacement_start,
    int32_t replacement_end);

// IME commit: insert final text. Fire-and-forget.
OWL_EXPORT void OWLBridge_ImeCommitText(
    uint64_t webview_id,
    const char* text,
    int32_t replacement_start,
    int32_t replacement_end);

// IME finish composing without new text. Fire-and-forget.
OWL_EXPORT void OWLBridge_ImeFinishComposing(uint64_t webview_id);

// Callback for caret rect updates (view-local DIP, top-left origin).
// Used by NSTextInputClient.firstRectForCharacterRange: for IME candidate positioning.
typedef void (*OWLBridge_CaretRectCallback)(
    uint64_t webview_id,
    float x, float y, float width, float height, void* context);
OWL_EXPORT void OWLBridge_SetCaretRectCallback(
    uint64_t webview_id,
    OWLBridge_CaretRectCallback callback,
    void* callback_context);

// === JavaScript Evaluation (testing only, requires --enable-owl-test-js) ===

// Evaluate JavaScript in the web view's main frame.
// Result is JSON-serialized. Auto-resolves Promises.
// Callback fires on main thread (exactly once, always async).
// result_type: 0=success, 1=exception.
typedef void (*OWLBridge_JSResultCallback)(
    const char* result,    // JSON string or error message. Never NULL.
    int32_t result_type,   // 0=success, 1=exception
    void* context);
OWL_EXPORT void OWLBridge_EvaluateJavaScript(
    uint64_t webview_id,
    const char* expression,
    OWLBridge_JSResultCallback callback,
    void* callback_context);

// === Find-in-Page ===

// Find text in the web view. Callback fires on main thread with request_id.
// query: UTF-8 search text. NULL/empty → callback(0, ctx) immediately.
// forward: 1=forward, 0=backward.
// match_case: 1=case-sensitive, 0=case-insensitive.
typedef void (*OWLBridge_FindCallback)(int32_t request_id, void* ctx);
OWL_EXPORT void OWLBridge_Find(uint64_t webview_id,
                                const char* query,
                                int forward,
                                int match_case,
                                OWLBridge_FindCallback callback,
                                void* callback_context);

// Stop find action enum (aligned with Mojom StopFindAction).
typedef enum {
    OWLBridgeStopFindAction_ClearSelection = 0,
    OWLBridgeStopFindAction_KeepSelection = 1,
    OWLBridgeStopFindAction_ActivateSelection = 2,
} OWLBridgeStopFindAction;

// Stop searching (fire-and-forget).
OWL_EXPORT void OWLBridge_StopFinding(uint64_t webview_id,
                                       OWLBridgeStopFindAction action);

// Find result callback (incremental, may fire multiple times).
// final_update: 1=final result for this request, 0=intermediate.
typedef void (*OWLBridge_FindResultCallback)(
    uint64_t webview_id,
    int32_t request_id,
    int32_t number_of_matches,
    int32_t active_match_ordinal,
    int final_update,
    void* ctx);
OWL_EXPORT void OWLBridge_SetFindResultCallback(
    uint64_t webview_id,
    OWLBridge_FindResultCallback callback,
    void* callback_context);

// === Zoom Control (Phase 34) ===

// Set zoom level. 0.0 = 100%, positive = zoom in, negative = zoom out.
// Callback fires on main thread (ack only).
typedef void (*OWLBridge_ZoomCallback)(void* ctx);
OWL_EXPORT void OWLBridge_SetZoomLevel(uint64_t webview_id, double level,
                                        OWLBridge_ZoomCallback callback,
                                        void* callback_context);

// Get current zoom level. Callback fires on main thread with level.
typedef void (*OWLBridge_GetZoomCallback)(double level, void* ctx);
OWL_EXPORT void OWLBridge_GetZoomLevel(uint64_t webview_id,
                                        OWLBridge_GetZoomCallback callback,
                                        void* callback_context);

// Zoom changed notification (HostZoomMap fires on level change).
typedef void (*OWLBridge_ZoomChangedCallback)(uint64_t webview_id,
                                              double new_level, void* ctx);
OWL_EXPORT void OWLBridge_SetZoomChangedCallback(
    uint64_t webview_id,
    OWLBridge_ZoomChangedCallback callback,
    void* callback_context);

// === Bookmarks (Phase 35) ===

// Add callback: returns JSON-encoded BookmarkItem on success.
typedef void (*OWLBridge_BookmarkAddCallback)(const char* bookmark_json,
                                              const char* error_msg,
                                              void* context);

// GetAll callback: returns JSON array of all bookmarks.
typedef void (*OWLBridge_BookmarkListCallback)(const char* json_array,
                                                const char* error_msg,
                                                void* context);

// Remove/Update callback: returns success bool.
typedef void (*OWLBridge_BookmarkResultCallback)(int success,
                                                  const char* error_msg,
                                                  void* context);

// Add a bookmark. parent_id may be NULL (defaults to bookmarks bar).
// Validates URL (http/https only) and title (non-empty, <=1024).
OWL_EXPORT void OWLBridge_BookmarkAdd(const char* title,
                                       const char* url,
                                       const char* parent_id,
                                       OWLBridge_BookmarkAddCallback callback,
                                       void* callback_context);

// Get all bookmarks. Callback fires with JSON array string.
OWL_EXPORT void OWLBridge_BookmarkGetAll(OWLBridge_BookmarkListCallback callback,
                                          void* callback_context);

// Remove a bookmark by ID. Callback fires with success=1/0.
OWL_EXPORT void OWLBridge_BookmarkRemove(const char* bookmark_id,
                                          OWLBridge_BookmarkResultCallback callback,
                                          void* callback_context);

// Update a bookmark's title and/or URL. Pass NULL for fields to keep unchanged.
OWL_EXPORT void OWLBridge_BookmarkUpdate(const char* bookmark_id,
                                          const char* title,
                                          const char* url,
                                          OWLBridge_BookmarkResultCallback callback,
                                          void* callback_context);

// === History (Phase 2 History) ===

// Callback for bool result operations (Delete, Clear).
typedef void (*OWLBridge_HistoryBoolCallback)(int success,
                                              const char* error_msg,
                                              void* context);

// Callback for int result operations (DeleteRange).
typedef void (*OWLBridge_HistoryIntCallback)(int32_t result,
                                             const char* error_msg,
                                             void* context);

// Callback for query operations (QueryByTime, QueryByVisitCount).
// json_array: JSON array of HistoryEntry objects. total: total count for pagination
// (only meaningful for QueryByTime; QueryByVisitCount sets total = -1).
typedef void (*OWLBridge_HistoryQueryCallback)(const char* json_array,
                                               int32_t total,
                                               const char* error_msg,
                                               void* context);

// Query history by time (most recent first). Results ordered by last_visit_time DESC.
// query: substring search over URL/title. Empty string = all entries.
// max_results: max entries to return. offset: pagination offset.
OWL_EXPORT void OWLBridge_HistoryQueryByTime(const char* query,
                                              int32_t max_results,
                                              int32_t offset,
                                              OWLBridge_HistoryQueryCallback callback,
                                              void* context);

// Query history by visit count (most visited first). Results ordered by visit_count DESC.
// query: substring search over URL/title. Empty string = all entries.
// max_results: max entries to return (top-N, no pagination).
OWL_EXPORT void OWLBridge_HistoryQueryByVisitCount(const char* query,
                                                    int32_t max_results,
                                                    OWLBridge_HistoryQueryCallback callback,
                                                    void* context);

// Delete a single URL from history.
OWL_EXPORT void OWLBridge_HistoryDelete(const char* url,
                                         OWLBridge_HistoryBoolCallback callback,
                                         void* context);

// Delete all visits in [start_time, end_time) based on last_visit_time.
// Times are seconds since Unix epoch (as double).
OWL_EXPORT void OWLBridge_HistoryDeleteRange(double start_time,
                                              double end_time,
                                              OWLBridge_HistoryIntCallback callback,
                                              void* context);

// Delete all history.
OWL_EXPORT void OWLBridge_HistoryClear(OWLBridge_HistoryBoolCallback callback,
                                        void* context);

// === Permissions (Phase 2 Permissions) ===

// Permission request callback (triggered when renderer requests a permission).
// origin: requesting origin (UTF-8, e.g. "https://example.com").
// permission_type: PermissionType enum (0=Camera, 1=Mic, 2=Geo, 3=Notifications).
// request_id: unique ID for this request, pass back via RespondToPermission.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_PermissionRequestCallback)(
    uint64_t webview_id,
    const char* origin,
    int permission_type,
    uint64_t request_id,
    void* context);

// Permission list callback (GetAll result).
// json_array: JSON array of {origin, type, status} objects. NULL on error.
// error_msg: NULL on success.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_PermissionListCallback)(
    const char* json_array,
    const char* error_msg,
    void* context);

// Permission query callback (GetPermission result).
// status: PermissionStatus enum (0=Granted, 1=Denied, 2=Ask).
typedef void (*OWLBridge_PermissionGetCallback)(
    int status,
    const char* error_msg,
    void* context);

// Register permission request callback (global, not per-webview).
// Fires each time OnPermissionRequest arrives. Set NULL to unregister.
OWL_EXPORT void OWLBridge_SetPermissionRequestCallback(
    OWLBridge_PermissionRequestCallback callback,
    void* callback_context);

// Respond to a permission request. request_id corresponds to OnPermissionRequest.
// status: PermissionStatus enum (0=Granted, 1=Denied, 2=Ask).
// Invalid request_id is silently ignored.
OWL_EXPORT void OWLBridge_RespondToPermission(
    uint64_t request_id,
    int status);

// Query a single permission.
OWL_EXPORT void OWLBridge_PermissionGet(
    const char* origin,
    int permission_type,
    OWLBridge_PermissionGetCallback callback,
    void* callback_context);

// Get all stored permissions. Callback returns JSON array.
OWL_EXPORT void OWLBridge_PermissionGetAll(
    OWLBridge_PermissionListCallback callback,
    void* callback_context);

// Set a permission status for (origin, type). Fire-and-forget.
// status: PermissionStatus enum (0=Granted, 1=Denied, 2=Ask).
// When status=Ask, equivalent to OWLBridge_PermissionReset.
OWL_EXPORT void OWLBridge_PermissionSet(
    const char* origin,
    int permission_type,
    int status);

// Reset a single permission (restore to Ask). Fire-and-forget.
OWL_EXPORT void OWLBridge_PermissionReset(
    const char* origin,
    int permission_type);

// Reset all permissions. Fire-and-forget.
OWL_EXPORT void OWLBridge_PermissionResetAll(void);

// === SSL Security (Phase 4) ===

// SSL error callback (triggered when displaying SSLErrorPage).
// url: URL with cert error (UTF-8).
// cert_subject: certificate subject name (UTF-8).
// error_description: net error string, e.g. "net::ERR_CERT_DATE_INVALID".
// error_id: unique ID, pass to OWLBridge_RespondToSSLError.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_SSLErrorCallback)(
    uint64_t webview_id,
    const char* url,
    const char* cert_subject,
    const char* error_description,
    uint64_t error_id,
    void* context);

// Register SSL error callback (global, not per-webview). Set NULL to unregister.
OWL_EXPORT void OWLBridge_SetSSLErrorCallback(
    OWLBridge_SSLErrorCallback callback,
    void* callback_context);

// Respond to an SSL error. error_id corresponds to SSLErrorCallback.
// proceed=1: record cert exception, reload page.
// proceed=0: do not load, error page remains (go back to safety).
// Invalid error_id is silently ignored.
OWL_EXPORT void OWLBridge_RespondToSSLError(uint64_t error_id, int proceed);

// Security state changed callback (pushed after each navigation commit).
// level: 0=Secure, 1=Info, 2=Warning, 3=Dangerous
// cert_subject: certificate CN (empty string if no certificate).
// error_description: error description (empty string if no error).
typedef void (*OWLBridge_SecurityStateCallback)(
    uint64_t webview_id,
    int32_t level,
    const char* cert_subject,
    const char* error_description,
    void* context);

// Register security state callback (per-webview).
OWL_EXPORT void OWLBridge_SetSecurityStateCallback(
    uint64_t webview_id,
    OWLBridge_SecurityStateCallback callback,
    void* callback_context);

// === History Change Observer (Phase 3 History Push) ===

// History changed callback (triggered when a new URL visit is recorded).
// url: the visited URL (UTF-8). Callback guaranteed on main thread.
typedef void (*OWLBridge_HistoryChangedCallback)(const char* url, void* context);

// Register history changed callback (global, not per-webview). Set NULL to unregister.
OWL_EXPORT void OWLBridge_SetHistoryChangedCallback(
    OWLBridge_HistoryChangedCallback callback, void* callback_context);

// === Downloads (Phase 2 Download Manager) ===

// Query callback (JSON array of DownloadItem objects).
typedef void (*OWLBridge_DownloadListCallback)(
    const char* json_array,    // JSON-encoded array of DownloadItem
    const char* error_msg,     // NULL on success
    void* context);

// Push event callback (single download event).
// event_type: 0=created, 1=updated, 2=removed
typedef void (*OWLBridge_DownloadEventCallback)(
    const char* json_item,     // JSON-encoded single DownloadItem
    int32_t event_type,        // 0=created, 1=updated, 2=removed
    void* context);

// Query all downloads. Callback fires on main thread with JSON array.
OWL_EXPORT void OWLBridge_DownloadGetAll(
    OWLBridge_DownloadListCallback callback, void* ctx);

// Control operations (fire-and-forget, no callback).
OWL_EXPORT void OWLBridge_DownloadPause(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadResume(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadCancel(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadRemoveEntry(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadOpenFile(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadShowInFolder(uint32_t download_id);

// Register push event callback. Set callback=NULL to unregister.
// Internally PostTask to IO thread for thread safety.
OWL_EXPORT void OWLBridge_SetDownloadCallback(
    OWLBridge_DownloadEventCallback callback, void* ctx);

// === Context Menu ===

// Context menu type enum (aligned with Mojom ContextMenuType).
typedef enum {
    OWLBridgeContextMenuType_Page = 0,
    OWLBridgeContextMenuType_Link = 1,
    OWLBridgeContextMenuType_Image = 2,
    OWLBridgeContextMenuType_Selection = 3,
    OWLBridgeContextMenuType_Editable = 4,
} OWLBridgeContextMenuType;

// Context menu callback (triggered when user right-clicks in the web view).
// type: ContextMenuType enum.
// is_editable: 1 if input/contentEditable, 0 otherwise.
// link_url: nullable, URL string if right-clicked on a link.
// src_url: nullable, URL string if right-clicked on an image.
// has_image_contents: 1 if media type is image, 0 otherwise.
// selection_text: nullable, selected text (truncated to 10KB).
// page_url: top-level page URL (never NULL).
// x, y: DIP coordinates, view-local.
// menu_id: monotonic ID incremented on navigation; use to discard stale menus.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_ContextMenuCallback)(
    uint64_t webview_id,
    int32_t type,
    int is_editable,
    const char* link_url,
    const char* src_url,
    int has_image_contents,
    const char* selection_text,
    const char* page_url,
    int32_t x,
    int32_t y,
    uint32_t menu_id,
    void* context);

// Register context menu callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetContextMenuCallback(
    uint64_t webview_id,
    OWLBridge_ContextMenuCallback callback,
    void* callback_context);

// Context menu action enum (aligned with Mojom ContextMenuAction).
typedef enum {
    OWLBridgeContextMenuAction_CopyLink = 0,
    OWLBridgeContextMenuAction_CopyImage = 1,
    OWLBridgeContextMenuAction_SaveImage = 2,
    OWLBridgeContextMenuAction_Copy = 3,
    OWLBridgeContextMenuAction_Cut = 4,
    OWLBridgeContextMenuAction_Paste = 5,
    OWLBridgeContextMenuAction_SelectAll = 6,
    OWLBridgeContextMenuAction_OpenLinkInNewTab = 7,
    OWLBridgeContextMenuAction_Search = 8,
    OWLBridgeContextMenuAction_CopyImageUrl = 9,   // Phase 3
    OWLBridgeContextMenuAction_ViewSource = 10,     // Phase 3
} OWLBridgeContextMenuAction;

// Execute a context menu action.
// menu_id must match the latest OnContextMenu's menu_id; stale IDs are ignored.
// payload: optional C string for actions that need extra data:
//   kOpenLinkInNewTab → link URL, kSearch → selection text,
//   kSaveImage/kCopyImage/kCopyImageUrl → src_url. NULL for others.
OWL_EXPORT void OWLBridge_ExecuteContextMenuAction(
    uint64_t webview_id,
    int32_t action,
    uint32_t menu_id,
    const char* payload);

// Phase 3: Copy-image async result callback.
// success: 1=image data written to NSPasteboard, 0=download failed.
// fallback_url: src_url for client-side "copy URL" degradation. NULL on success.
typedef void (*OWLBridge_CopyImageResultCallback)(
    uint64_t webview_id,
    int success, const char* fallback_url, void* context);

// Register copy-image result callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetCopyImageResultCallback(
    uint64_t webview_id,
    OWLBridge_CopyImageResultCallback callback,
    void* callback_context);

// === HTTP Auth (Phase 3) ===

// Auth challenge callback (triggered when server sends 401/407).
// url: URL requiring auth (UTF-8).
// realm: authentication realm (UTF-8, may be empty).
// scheme: auth scheme, e.g. "basic", "digest" (UTF-8).
// auth_id: unique ID, pass to OWLBridge_RespondToAuth.
// is_proxy: 1 for 407 Proxy-Authenticate, 0 for 401 WWW-Authenticate.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_AuthRequiredCallback)(
    uint64_t webview_id,
    const char* url,
    const char* realm,
    const char* scheme,
    uint64_t auth_id,
    int is_proxy,
    void* context);

// Register auth required callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetAuthRequiredCallback(
    uint64_t webview_id,
    OWLBridge_AuthRequiredCallback callback,
    void* callback_context);

// Respond to an HTTP auth challenge. auth_id corresponds to AuthRequiredCallback.
// username=NULL means cancel (no credentials provided).
// password may be NULL (treated as empty string).
// Invalid auth_id is silently ignored.
OWL_EXPORT void OWLBridge_RespondToAuth(
    uint64_t auth_id,
    const char* username,
    const char* password);

// === Load Finished (deterministic page-load-complete signal) ===

// Load finished callback. Fires when the main frame finishes loading.
// success: 1=success, 0=failure.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_LoadFinishedCallback)(
    uint64_t webview_id,
    int success,
    void* context);

// Register load finished callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetLoadFinishedCallback(
    uint64_t webview_id,
    OWLBridge_LoadFinishedCallback callback,
    void* callback_context);

// === Navigation Lifecycle (Phase 2 — per-webview callbacks) ===

// Navigation started callback. Fires when a navigation begins.
// nav_id: unique navigation ID (monotonic).
// url: target URL (UTF-8).
// is_user_initiated: 1 if user-initiated, 0 if programmatic.
// is_redirect: 1 if this is a server redirect, 0 otherwise.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_NavigationStartedCallback)(
    uint64_t webview_id,
    int64_t nav_id, const char* url, int is_user_initiated,
    int is_redirect, void* ctx);

// Navigation committed callback. Fires when the response headers are received.
// nav_id: matches the navigation started nav_id.
// url: committed URL (may differ from started URL due to redirects).
// http_status: HTTP status code (200, 404, etc.).
// Callback guaranteed on main thread.
typedef void (*OWLBridge_NavigationCommittedCallback)(
    uint64_t webview_id,
    int64_t nav_id, const char* url, int http_status, void* ctx);

// Navigation error callback. Fires when a navigation fails.
// nav_id: matches the navigation started nav_id.
// url: URL that failed.
// error_code: Chromium net error code (negative, e.g. -105 = ERR_NAME_NOT_RESOLVED).
// error_desc: human-readable error description (UTF-8).
// Callback guaranteed on main thread.
typedef void (*OWLBridge_NavigationErrorCallback)(
    uint64_t webview_id,
    int64_t nav_id, const char* url, int error_code,
    const char* error_desc, void* ctx);

// Register navigation started callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetNavigationStartedCallback(
    uint64_t webview_id, OWLBridge_NavigationStartedCallback callback, void* ctx);

// Register navigation committed callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetNavigationCommittedCallback(
    uint64_t webview_id, OWLBridge_NavigationCommittedCallback callback, void* ctx);

// Register navigation error callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetNavigationErrorCallback(
    uint64_t webview_id, OWLBridge_NavigationErrorCallback callback, void* ctx);

// === Storage (Cookie/Storage Management) ===

// Callback for GetCookieDomains / GetStorageUsage (JSON array results).
// json_array: JSON-encoded array. NULL on error.
// error_msg: NULL on success.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_StorageJsonCallback)(const char* json_array,
                                              const char* error_msg,
                                              void* context);

// Callback for DeleteCookiesForDomain (returns deleted count).
typedef void (*OWLBridge_StorageIntCallback)(int32_t value,
                                             const char* error_msg,
                                             void* context);

// Callback for ClearBrowsingData (returns success bool).
typedef void (*OWLBridge_StorageBoolCallback)(int success,
                                              const char* error_msg,
                                              void* context);

// Get all cookie domains with counts.
// Callback fires on main thread with JSON: [{"domain":"...","count":N}]
OWL_EXPORT void OWLBridge_StorageGetCookieDomains(
    OWLBridge_StorageJsonCallback callback, void* ctx);

// Delete all cookies for a specific domain.
// Callback fires on main thread with deleted count.
OWL_EXPORT void OWLBridge_StorageDeleteDomain(
    const char* domain,
    OWLBridge_StorageIntCallback callback, void* ctx);

// Clear browsing data by type mask.
// data_types: bitmask (0x01=Cookies, 0x02=Cache, 0x04=LocalStorage,
//             0x08=SessionStorage, 0x10=IndexedDB).
// start_time/end_time: seconds since Unix epoch (as double).
// Callback fires on main thread with success=1/0.
OWL_EXPORT void OWLBridge_StorageClearData(
    uint32_t data_types, double start_time, double end_time,
    OWLBridge_StorageBoolCallback callback, void* ctx);

// Get storage usage per origin.
// Callback fires on main thread with JSON: [{"origin":"...","usage_bytes":N}]
OWL_EXPORT void OWLBridge_StorageGetUsage(
    OWLBridge_StorageJsonCallback callback, void* ctx);

// === Console Message (Phase 2) ===

// Console message callback (triggered when renderer logs to console).
// level: ConsoleLevel enum (0=Verbose, 1=Info, 2=Warning, 3=Error).
// message: UTF-8 message text (truncated to 10KB by Host).
// source: source file URL (UTF-8).
// line: line number (0 = unknown).
// timestamp: seconds since Unix epoch (as double).
// Callback guaranteed on main thread.
typedef void (*OWLBridge_ConsoleMessageCallback)(
    uint64_t webview_id,
    int level, const char* message, const char* source,
    int line, double timestamp, void* ctx);

// Register console message callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetConsoleMessageCallback(
    uint64_t webview_id,
    OWLBridge_ConsoleMessageCallback callback,
    void* callback_context);

// === New Tab / Close Tab (Phase 3 Multi-tab) ===

// New tab requested callback (triggered when Host detects target="_blank",
// Cmd+Click, or window.open with user gesture).
// url: target URL for the new tab (UTF-8).
// foreground: 1=activate immediately, 0=open in background.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_NewTabRequestedCallback)(
    uint64_t webview_id,
    const char* url,
    int foreground,
    void* context);

// Register new tab requested callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetNewTabRequestedCallback(
    uint64_t webview_id,
    OWLBridge_NewTabRequestedCallback callback,
    void* callback_context);

// Close requested callback (triggered when Host receives window.close()).
// Callback guaranteed on main thread.
typedef void (*OWLBridge_CloseRequestedCallback)(
    uint64_t webview_id,
    void* context);

// Register close requested callback (per-webview). Set callback=NULL to unregister.
OWL_EXPORT void OWLBridge_SetCloseRequestedCallback(
    uint64_t webview_id,
    OWLBridge_CloseRequestedCallback callback,
    void* callback_context);

// === Input Helpers ===

// Convert native macOS key code to DOM key code.
OWL_EXPORT int OWLBridge_DomCodeFromNativeKeyCode(int native_key_code);

// === URL Helpers ===

// Canonicalize a URL string. Returns NULL if invalid.
// Caller must free result with OWLBridge_Free.
OWL_EXPORT char* OWLBridge_CanonicalizeUrl(const char* input);

// Returns 1 if input looks like a URL, 0 if search query.
OWL_EXPORT int OWLBridge_InputLooksLikeURL(const char* input);

#ifdef __cplusplus
}
#endif

#endif  // THIRD_PARTY_OWL_BRIDGE_OWL_BRIDGE_API_H_
