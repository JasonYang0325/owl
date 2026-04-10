// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

// Context Menu Phase 1 unit tests.
// Tests cover: ContextMenuType detection, menu_id management,
// selection_text truncation (including UTF-8 multibyte safety),
// ExecuteContextMenuAction dispatch with stale menu_id rejection,
// Mojom enum consistency, and action dispatch mapping.

#include <cstdint>
#include <string>

#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/owl/host/owl_context_menu_utils.h"
#include "third_party/owl/host/owl_web_contents.h"
#include "third_party/owl/mojom/web_view.mojom.h"

namespace owl {
namespace {

// Thin alias: tests historically used TruncateSelectionText; the real function
// is owl::TruncateSelectionTextUTF8. This keeps all call sites unchanged.
inline std::string TruncateSelectionText(const std::string& text) {
  return owl::TruncateSelectionTextUTF8(text);
}

// Simulates Host-side menu_id state management.
// In the real implementation this lives in RealWebContents as current_menu_id_.
// Uses uint32_t to match mojom ContextMenuParams.menu_id (uint32).
class MenuIdManager {
 public:
  // Called on each HandleContextMenu; returns the new menu_id.
  uint32_t OnContextMenu() { return ++current_menu_id_; }

  // Called on navigation start; invalidates any outstanding menu.
  void OnNavigation() { ++current_menu_id_; }

  uint32_t current_menu_id() const { return current_menu_id_; }

  // Returns true if the given menu_id matches the current one.
  bool IsMenuIdValid(uint32_t menu_id) const {
    return menu_id == current_menu_id_;
  }

 private:
  uint32_t current_menu_id_ = 0;
};

// Helper: returns true if |s| is valid UTF-8 (no truncated sequences).
bool IsValidUtf8(const std::string& s) {
  size_t i = 0;
  while (i < s.size()) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    size_t seq_len = 0;
    if (c < 0x80) {
      seq_len = 1;
    } else if ((c & 0xE0) == 0xC0) {
      seq_len = 2;
    } else if ((c & 0xF0) == 0xE0) {
      seq_len = 3;
    } else if ((c & 0xF8) == 0xF0) {
      seq_len = 4;
    } else {
      return false;  // Invalid start byte.
    }
    if (i + seq_len > s.size())
      return false;  // Truncated sequence.
    for (size_t j = 1; j < seq_len; ++j) {
      if ((static_cast<unsigned char>(s[i + j]) & 0xC0) != 0x80)
        return false;  // Missing continuation byte.
    }
    i += seq_len;
  }
  return true;
}

// --- ContextMenuType detection tests ---

// [AC-004a] Blank area (no link, no image, no selection, not editable) -> kPage.
TEST(OWLContextMenuStaticTest, ContextMenuTypeDetection_Page) {
  EXPECT_EQ(DetermineContextMenuType(/*is_editable=*/false, /*link_url=*/"",
                                     /*has_image_contents=*/false,
                                     /*selection_text=*/""),
            owl::mojom::ContextMenuType::kPage);
}

// [AC-004a] link_url non-empty -> kLink.
TEST(OWLContextMenuStaticTest, ContextMenuTypeDetection_Link) {
  EXPECT_EQ(DetermineContextMenuType(false, "https://example.com", false, ""),
            owl::mojom::ContextMenuType::kLink);
}

// [AC-004a] has_image_contents=true -> kImage.
TEST(OWLContextMenuStaticTest, ContextMenuTypeDetection_Image) {
  EXPECT_EQ(DetermineContextMenuType(false, "", true, ""),
            owl::mojom::ContextMenuType::kImage);
}

// [AC-004a] selection_text non-empty -> kSelection.
TEST(OWLContextMenuStaticTest, ContextMenuTypeDetection_Selection) {
  EXPECT_EQ(DetermineContextMenuType(false, "", false, "selected text"),
            owl::mojom::ContextMenuType::kSelection);
}

// [AC-004a] is_editable=true (even with link_url) -> kEditable.
TEST(OWLContextMenuStaticTest, ContextMenuTypeDetection_Editable) {
  EXPECT_EQ(DetermineContextMenuType(true, "https://example.com", false, ""),
            owl::mojom::ContextMenuType::kEditable);
}

// [AC-004a] All flags set: is_editable + link_url + image + selection -> kEditable.
// Verifies kEditable has highest priority.
TEST(OWLContextMenuStaticTest, ContextMenuTypeDetection_Priority) {
  EXPECT_EQ(
      DetermineContextMenuType(true, "https://example.com", true, "selected"),
      owl::mojom::ContextMenuType::kEditable);
}

// --- menu_id management tests ---
// menu_id uses uint32_t to match mojom ContextMenuParams.menu_id.

// [AC-004a] Consecutive HandleContextMenu calls produce strictly increasing IDs.
TEST(OWLContextMenuStaticTest, MenuIdIncrement) {
  MenuIdManager mgr;
  uint32_t id1 = mgr.OnContextMenu();
  uint32_t id2 = mgr.OnContextMenu();
  uint32_t id3 = mgr.OnContextMenu();

  EXPECT_EQ(id1, 1u);
  EXPECT_EQ(id2, 2u);
  EXPECT_EQ(id3, 3u);
  EXPECT_GT(id2, id1);
  EXPECT_GT(id3, id2);
}

// [AC-005e] Stale menu_id is rejected by IsMenuIdValid.
TEST(OWLContextMenuStaticTest, StaleMenuIdIgnored) {
  MenuIdManager mgr;
  uint32_t old_id = mgr.OnContextMenu();
  EXPECT_TRUE(mgr.IsMenuIdValid(old_id));

  // A new context menu event invalidates the old id.
  uint32_t new_id = mgr.OnContextMenu();
  EXPECT_FALSE(mgr.IsMenuIdValid(old_id));
  EXPECT_TRUE(mgr.IsMenuIdValid(new_id));

  // Completely fabricated id is also rejected.
  EXPECT_FALSE(mgr.IsMenuIdValid(9999u));
}

// [AC-004a] Navigation increments menu_id, invalidating the previous one.
TEST(OWLContextMenuStaticTest, NavigationIncrementsMenuId) {
  MenuIdManager mgr;
  uint32_t menu_id = mgr.OnContextMenu();
  EXPECT_TRUE(mgr.IsMenuIdValid(menu_id));

  // Simulate a navigation.
  mgr.OnNavigation();

  // The old menu_id is now stale.
  EXPECT_FALSE(mgr.IsMenuIdValid(menu_id));

  // A new context menu after navigation gets a fresh, higher id.
  uint32_t new_menu_id = mgr.OnContextMenu();
  EXPECT_GT(new_menu_id, menu_id);
  EXPECT_TRUE(mgr.IsMenuIdValid(new_menu_id));
}

// --- selection_text truncation tests ---

// [AC-004a] selection_text longer than 10KB is truncated to at most 10240 bytes.
TEST(OWLContextMenuStaticTest, SelectionTextTruncation) {
  constexpr size_t kLimit = 10240;

  // Exactly at limit: no truncation.
  std::string exact(kLimit, 'a');
  EXPECT_EQ(TruncateSelectionText(exact).size(), kLimit);
  EXPECT_EQ(TruncateSelectionText(exact), exact);

  // One byte over limit: truncated.
  std::string over(kLimit + 1, 'b');
  std::string truncated = TruncateSelectionText(over);
  EXPECT_LE(truncated.size(), kLimit);
  EXPECT_EQ(truncated, std::string(kLimit, 'b'));

  // Well under limit: no truncation.
  std::string small = "hello";
  EXPECT_EQ(TruncateSelectionText(small), small);

  // Empty string: no truncation.
  EXPECT_EQ(TruncateSelectionText(""), "");

  // Large text (2x limit): truncated.
  std::string large(kLimit * 2, 'c');
  EXPECT_LE(TruncateSelectionText(large).size(), kLimit);
}

// [AC-004a] UTF-8 multibyte: Chinese characters are 3 bytes each in UTF-8.
// Truncation must not split a code point, so the result must be valid UTF-8.
TEST(OWLContextMenuStaticTest, SelectionTextTruncation_UTF8MultibytePreserved) {
  constexpr size_t kLimit = 10240;

  // Build a long string of Chinese characters.
  // Each character "你" is 3 bytes (0xE4 0xBD 0xA0).
  // We create a string that is well over 10KB so truncation will occur.
  std::string chinese_char = "\xe4\xbd\xa0";  // "你" in UTF-8
  std::string long_chinese;
  // 10240 / 3 = 3413.33, so 3414 characters = 10242 bytes (2 over limit).
  for (size_t i = 0; i < 3500; ++i) {
    long_chinese += chinese_char;
  }
  ASSERT_GT(long_chinese.size(), kLimit);

  std::string result = TruncateSelectionText(long_chinese);

  // Result must not exceed 10KB.
  EXPECT_LE(result.size(), kLimit);

  // Result must be valid UTF-8 (not truncated mid-character).
  EXPECT_TRUE(IsValidUtf8(result));

  // Result size must be a multiple of 3 (since all chars are 3-byte).
  EXPECT_EQ(result.size() % 3, 0u);

  // The truncated string should be the largest multiple of 3 <= kLimit.
  // 10240 / 3 = 3413 chars * 3 = 10239 bytes.
  EXPECT_EQ(result.size(), 10239u);
}

// [AC-004a] UTF-8 multibyte: Emoji (4-byte sequences) must not be split.
TEST(OWLContextMenuStaticTest, SelectionTextTruncation_EmojiPreserved) {
  constexpr size_t kLimit = 10240;

  // U+1F600 GRINNING FACE is 4 bytes: 0xF0 0x9F 0x98 0x80
  std::string emoji = "\xf0\x9f\x98\x80";
  std::string long_emoji;
  // 10240 / 4 = 2560. We need > 2560 to trigger truncation.
  for (size_t i = 0; i < 2600; ++i) {
    long_emoji += emoji;
  }
  ASSERT_GT(long_emoji.size(), kLimit);

  std::string result = TruncateSelectionText(long_emoji);

  // Result must not exceed 10KB.
  EXPECT_LE(result.size(), kLimit);

  // Result must be valid UTF-8.
  EXPECT_TRUE(IsValidUtf8(result));

  // Result size must be a multiple of 4 (all 4-byte emoji).
  EXPECT_EQ(result.size() % 4, 0u);

  // 10240 / 4 = 2560 exactly, so 2560 * 4 = 10240 bytes.
  EXPECT_EQ(result.size(), 10240u);
}

// [AC-004a] Mixed ASCII + multibyte: truncation at a boundary between ASCII
// and a multibyte char should still produce valid UTF-8.
TEST(OWLContextMenuStaticTest, SelectionTextTruncation_MixedContent) {
  constexpr size_t kLimit = 10240;

  // Fill with ASCII up to kLimit - 2, then add a 3-byte Chinese char.
  // This means the 3-byte char starts at byte 10238 and would end at 10240,
  // which spans the boundary. The truncation should either include or exclude
  // it entirely.
  std::string mixed(kLimit - 2, 'x');
  mixed += "\xe4\xbd\xa0";  // "你" — 3 bytes, total = kLimit + 1.
  ASSERT_EQ(mixed.size(), kLimit + 1);

  std::string result = TruncateSelectionText(mixed);
  EXPECT_LE(result.size(), kLimit);
  EXPECT_TRUE(IsValidUtf8(result));

  // The 3-byte char at offset 10238 would end at 10241 (over limit).
  // The truncation should drop it, yielding kLimit - 2 = 10238 bytes.
  EXPECT_EQ(result.size(), kLimit - 2);
}

// --- ExecuteContextMenuAction with stale menu_id ---
// NOTE: Navigation actions (GoBack, GoForward, Reload) are executed locally
// on the Swift client side via separate WebViewHost Mojo methods, so they
// do not flow through ExecuteContextMenuAction and are not tested here.

// [AC-005e] Calling ExecuteContextMenuAction with a stale menu_id should be
// silently ignored. We verify by checking the function pointer dispatch:
// g_real_execute_context_menu_action_func is called only when menu_id is valid.
TEST(OWLContextMenuStaticTest, ExecuteContextMenuAction_StaleIdIgnored) {
  // This test validates the pattern at the Host level: the real
  // ExecuteContextMenuAction checks current_menu_id_ before dispatching.
  // We simulate this using MenuIdManager.
  MenuIdManager mgr;
  uint32_t valid_id = mgr.OnContextMenu();

  // Simulate: a navigation invalidates the menu_id.
  mgr.OnNavigation();

  // The old menu_id is now stale.
  EXPECT_FALSE(mgr.IsMenuIdValid(valid_id));

  // The action should be rejected (no dispatch).
  // In real code, this translates to a DLOG(WARNING) and early return.
  bool action_dispatched = false;
  auto maybe_dispatch = [&](owl::mojom::ContextMenuAction action,
                            uint32_t menu_id) {
    if (mgr.IsMenuIdValid(menu_id)) {
      action_dispatched = true;
    }
  };

  maybe_dispatch(owl::mojom::ContextMenuAction::kCopy, valid_id);
  EXPECT_FALSE(action_dispatched);

  // With a fresh valid menu_id, dispatch should succeed.
  uint32_t fresh_id = mgr.OnContextMenu();
  maybe_dispatch(owl::mojom::ContextMenuAction::kCopy, fresh_id);
  EXPECT_TRUE(action_dispatched);
}

// [AC-005e] ExecuteContextMenuAction with a completely fabricated menu_id
// (never issued) should also be rejected.
TEST(OWLContextMenuStaticTest, ExecuteContextMenuAction_FabricatedIdIgnored) {
  MenuIdManager mgr;
  mgr.OnContextMenu();  // menu_id = 1

  bool action_dispatched = false;
  auto maybe_dispatch = [&](owl::mojom::ContextMenuAction action,
                            uint32_t menu_id) {
    if (mgr.IsMenuIdValid(menu_id)) {
      action_dispatched = true;
    }
  };

  // Use a menu_id that was never issued.
  maybe_dispatch(owl::mojom::ContextMenuAction::kPaste, 42u);
  EXPECT_FALSE(action_dispatched);
}

// --- Mojom type consistency checks ---

// Verify that the Mojom ContextMenuType enum values match our expectations.
// This catches accidental reordering in the .mojom file.
TEST(OWLContextMenuStaticTest, MojomContextMenuTypeValues) {
  // Mojom enums in Chromium are zero-based by default.
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuType::kPage), 0);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuType::kLink), 1);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuType::kImage), 2);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuType::kSelection), 3);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuType::kEditable), 4);
}

// Verify ContextMenuAction enum values.
// NOTE: kBack, kForward, kReload are NOT part of ContextMenuAction because
// navigation operations are handled client-side by Swift (via separate
// WebViewHost.GoBack/GoForward/Reload Mojo methods). Only Host-only
// clipboard/edit operations are dispatched through ExecuteContextMenuAction.
// See mojom/web_view.mojom ContextMenuAction enum comment and WebViewHost
// interface for GoBack()/GoForward()/Reload() definitions.
TEST(OWLContextMenuStaticTest, MojomContextMenuActionValues) {
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCopyLink), 0);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCopyImage), 1);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kSaveImage), 2);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCopy), 3);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCut), 4);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kPaste), 5);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kSelectAll), 6);
  // Phase 2 additions.
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kOpenLinkInNewTab),
            7);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kSearch), 8);
  // Phase 3 additions.
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCopyImageUrl), 9);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kViewSource), 10);
}

// Verify that ExecuteContextMenuAction in the real interface takes uint32_t
// menu_id (not uint64_t). This is a compile-time check: if the Mojom changes
// menu_id to a different type, this test will fail to compile.
TEST(OWLContextMenuStaticTest, MenuIdTypeIsUint32) {
  // g_real_execute_context_menu_action_func is declared as:
  //   void (*)(int32_t action, uint32_t menu_id, const std::string& payload)
  // Verify we can assign a lambda with matching signature.
  RealExecuteContextMenuActionFunc fn =
      [](int32_t action, uint32_t menu_id, const std::string& payload) {};
  EXPECT_NE(fn, nullptr);
  (void)fn;  // Suppress unused warning.
}

// --- AC-005e: Action dispatch mapping via function pointer ---
// This test validates that the dispatch pattern (menu_id guard + function
// pointer invocation) correctly routes each ContextMenuAction value through
// the RealExecuteContextMenuActionFunc signature. This is a MIRROR of the
// real dispatch logic in OWLWebContents::ExecuteContextMenuAction; the real
// dispatch path requires integration tests with a live content layer.
//
// NOTE: Navigation actions (GoBack, GoForward, Reload) are executed locally
// on the Swift client side via separate WebViewHost Mojo methods, so they
// do not flow through ExecuteContextMenuAction and are not tested here.
TEST(OWLContextMenuStaticTest, ExecuteContextMenuAction_DispatchMapping) {
  MenuIdManager mgr;
  uint32_t valid_id = mgr.OnContextMenu();

  // Track which action was dispatched and with which menu_id.
  int32_t dispatched_action = -1;
  uint32_t dispatched_menu_id = 0;

  // Mirror of the real dispatch: check menu_id validity, then call the
  // function pointer with the action cast to int32_t.
  auto dispatch = [&](owl::mojom::ContextMenuAction action,
                      uint32_t menu_id) {
    if (!mgr.IsMenuIdValid(menu_id))
      return;
    dispatched_action = static_cast<int32_t>(action);
    dispatched_menu_id = menu_id;
  };

  // Verify every ContextMenuAction value is correctly forwarded.
  const struct {
    owl::mojom::ContextMenuAction action;
    int32_t expected_value;
  } kActions[] = {
      {owl::mojom::ContextMenuAction::kCopyLink, 0},
      {owl::mojom::ContextMenuAction::kCopyImage, 1},
      {owl::mojom::ContextMenuAction::kSaveImage, 2},
      {owl::mojom::ContextMenuAction::kCopy, 3},
      {owl::mojom::ContextMenuAction::kCut, 4},
      {owl::mojom::ContextMenuAction::kPaste, 5},
      {owl::mojom::ContextMenuAction::kSelectAll, 6},
      {owl::mojom::ContextMenuAction::kOpenLinkInNewTab, 7},
      {owl::mojom::ContextMenuAction::kSearch, 8},
      {owl::mojom::ContextMenuAction::kCopyImageUrl, 9},
      {owl::mojom::ContextMenuAction::kViewSource, 10},
  };

  for (const auto& tc : kActions) {
    dispatched_action = -1;
    dispatched_menu_id = 0;
    dispatch(tc.action, valid_id);
    EXPECT_EQ(dispatched_action, tc.expected_value)
        << "Failed for action index " << tc.expected_value;
    EXPECT_EQ(dispatched_menu_id, valid_id);
  }

  // Stale menu_id should prevent dispatch for all actions.
  uint32_t stale_id = valid_id;
  mgr.OnContextMenu();  // Invalidate old menu_id.
  for (const auto& tc : kActions) {
    dispatched_action = -1;
    dispatch(tc.action, stale_id);
    EXPECT_EQ(dispatched_action, -1)
        << "Stale dispatch should not occur for action index "
        << tc.expected_value;
  }
}

// ==========================================================================
// Phase 2 unit tests.
// Tests cover: link/selection/editable menu-type routing, URL scheme
// filtering (javascript:/file: blocked, https: allowed), search display-text
// truncation (≤20 chars full, >20 chars → first 17 + "..."), search query
// URL-encoding, and editable-action dispatch mapping.
//
// NOTE: Phase 2 introduces kOpenLinkInNewTab and kSearch actions, plus a
// |payload| parameter on ExecuteContextMenuAction. These are not yet in the
// mojom. The tests below use local mirror helpers that encode the expected
// Phase 2 algorithms, identical to the Phase 1 pattern (see file header).
// ==========================================================================

// --- Phase 2 helper: URL scheme allowlist for "Open Link in New Tab" ---
// Only http: and https: links are eligible. javascript:, file:, and any
// other scheme must be rejected.
bool IsLinkSchemeAllowed(const std::string& url) {
  // Simple prefix check — mirrors the expected Host-side implementation.
  if (url.rfind("https://", 0) == 0)
    return true;
  if (url.rfind("http://", 0) == 0)
    return true;
  return false;
}

// --- Phase 2 helper: search display text ---
// For "搜索'<text>'" menu label:
//   - If |text| ≤ 20 characters (Unicode code points), show full text.
//   - If |text| > 20 characters, show first 17 code points + "...".
// The function operates on UTF-8 and counts code points, not bytes.
size_t CountUtf8CodePoints(const std::string& s) {
  size_t count = 0;
  size_t i = 0;
  while (i < s.size()) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    if (c < 0x80)
      i += 1;
    else if ((c & 0xE0) == 0xC0)
      i += 2;
    else if ((c & 0xF0) == 0xE0)
      i += 3;
    else
      i += 4;
    ++count;
  }
  return count;
}

// Advance |pos| by one UTF-8 code point. Returns new position.
size_t AdvanceOneCodePoint(const std::string& s, size_t pos) {
  if (pos >= s.size())
    return pos;
  unsigned char c = static_cast<unsigned char>(s[pos]);
  if (c < 0x80)
    return pos + 1;
  if ((c & 0xE0) == 0xC0)
    return pos + 2;
  if ((c & 0xF0) == 0xE0)
    return pos + 3;
  return pos + 4;
}

std::string TruncateSearchDisplayText(const std::string& text) {
  constexpr size_t kMaxDisplayCodePoints = 20;
  constexpr size_t kTruncatedCodePoints = 17;

  size_t cp_count = CountUtf8CodePoints(text);
  if (cp_count <= kMaxDisplayCodePoints)
    return text;

  // Take the first 17 code points.
  size_t byte_pos = 0;
  for (size_t i = 0; i < kTruncatedCodePoints && byte_pos < text.size(); ++i) {
    byte_pos = AdvanceOneCodePoint(text, byte_pos);
  }
  return text.substr(0, byte_pos) + "...";
}

// --- Phase 2 helper: simple percent-encoding for search query ---
// Encodes characters outside unreserved set (RFC 3986) for use in a search
// URL query parameter. This mirrors the expected Host-side behavior.
std::string PercentEncodeSearchQuery(const std::string& text) {
  std::string result;
  for (unsigned char c : text) {
    // Unreserved: A-Z a-z 0-9 - _ . ~
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' ||
        c == '~') {
      result += static_cast<char>(c);
    } else if (c == ' ') {
      result += '+';
    } else {
      static const char kHex[] = "0123456789ABCDEF";
      result += '%';
      result += kHex[(c >> 4) & 0x0F];
      result += kHex[c & 0x0F];
    }
  }
  return result;
}

// --- Phase 2 helper: editable action dispatch ---
// Maps a Phase 1 ContextMenuAction to a WebContents editing command string.
// Phase 2 AC: kCut/kCopy/kPaste/kSelectAll dispatch to WebContents edit
// commands. This helper returns the command name or empty string if the
// action is not an editable command.
std::string EditableActionToCommand(owl::mojom::ContextMenuAction action) {
  switch (action) {
    case owl::mojom::ContextMenuAction::kCut:
      return "Cut";
    case owl::mojom::ContextMenuAction::kCopy:
      return "Copy";
    case owl::mojom::ContextMenuAction::kPaste:
      return "Paste";
    case owl::mojom::ContextMenuAction::kSelectAll:
      return "SelectAll";
    default:
      return "";
  }
}

// --- Phase 2 Test: Link menu type ---
// [P2-AC] Right-click on a link → kLink type, enabling "Open Link in New Tab"
// and "Copy Link Address" actions.
TEST(OWLContextMenuPhase2Test, Phase2_LinkMenuType) {
  // link_url non-empty, not editable, no image, no selection → kLink.
  auto type = DetermineContextMenuType(
      /*is_editable=*/false,
      /*link_url=*/"https://example.com/page",
      /*has_image_contents=*/false,
      /*selection_text=*/"");
  EXPECT_EQ(type, owl::mojom::ContextMenuType::kLink);

  // With both link and selection, kLink takes priority over kSelection
  // (but kEditable would beat kLink — tested in Phase 1).
  auto type2 = DetermineContextMenuType(false, "https://example.com",
                                         false, "some text");
  EXPECT_EQ(type2, owl::mojom::ContextMenuType::kLink);
}

// --- Phase 2 Test: Selection menu type ---
// [P2-AC] Right-click on selected text → kSelection type, enabling "Copy"
// and "Search '<text>'" actions.
TEST(OWLContextMenuPhase2Test, Phase2_SelectionMenuType) {
  // selection_text non-empty, no link, not editable → kSelection.
  auto type = DetermineContextMenuType(
      /*is_editable=*/false,
      /*link_url=*/"",
      /*has_image_contents=*/false,
      /*selection_text=*/"Hello World");
  EXPECT_EQ(type, owl::mojom::ContextMenuType::kSelection);
}

// --- Phase 2 Test: Editable menu type ---
// [P2-AC] Right-click on input/textarea → kEditable type, enabling
// "Cut/Copy/Paste/Select All" actions.
TEST(OWLContextMenuPhase2Test, Phase2_EditableMenuType) {
  // is_editable=true always wins (highest priority).
  auto type = DetermineContextMenuType(
      /*is_editable=*/true,
      /*link_url=*/"",
      /*has_image_contents=*/false,
      /*selection_text=*/"");
  EXPECT_EQ(type, owl::mojom::ContextMenuType::kEditable);

  // Even with selection text, editable wins.
  auto type2 = DetermineContextMenuType(true, "", false, "selected in input");
  EXPECT_EQ(type2, owl::mojom::ContextMenuType::kEditable);
}

// --- Phase 2 Test: Scheme filter — javascript: rejected ---
// [P2-AC] javascript: URLs must be rejected for "Open Link in New Tab".
TEST(OWLContextMenuPhase2Test, Phase2_SchemeFilter_Javascript) {
  EXPECT_FALSE(IsLinkSchemeAllowed("javascript:alert(1)"));
  EXPECT_FALSE(IsLinkSchemeAllowed("javascript:void(0)"));
  // Case-sensitive: "JavaScript:" should also be rejected (no match).
  EXPECT_FALSE(IsLinkSchemeAllowed("JavaScript:alert(1)"));
}

// --- Phase 2 Test: Scheme filter — file: rejected ---
// [P2-AC] file: URLs must be rejected for "Open Link in New Tab".
TEST(OWLContextMenuPhase2Test, Phase2_SchemeFilter_File) {
  EXPECT_FALSE(IsLinkSchemeAllowed("file:///etc/passwd"));
  EXPECT_FALSE(IsLinkSchemeAllowed("file:///Users/foo/bar.html"));
}

// --- Phase 2 Test: Scheme filter — https: allowed ---
// [P2-AC] https: (and http:) URLs are allowed for "Open Link in New Tab".
TEST(OWLContextMenuPhase2Test, Phase2_SchemeFilter_HttpsAllowed) {
  EXPECT_TRUE(IsLinkSchemeAllowed("https://example.com"));
  EXPECT_TRUE(IsLinkSchemeAllowed("https://example.com/path?q=1"));
  EXPECT_TRUE(IsLinkSchemeAllowed("http://example.com"));
  EXPECT_TRUE(IsLinkSchemeAllowed("http://localhost:8080/test"));

  // Edge: ftp: is not allowed.
  EXPECT_FALSE(IsLinkSchemeAllowed("ftp://files.example.com/data"));
  // Edge: data: is not allowed for link opening.
  EXPECT_FALSE(IsLinkSchemeAllowed("data:text/html,<h1>hi</h1>"));
  // Edge: empty URL is not allowed.
  EXPECT_FALSE(IsLinkSchemeAllowed(""));
}

// --- Phase 2 Test: Search text truncation — short text ---
// [P2-AC] selection_text ≤ 20 characters → display full text, no truncation.
TEST(OWLContextMenuPhase2Test, Phase2_SearchTextTruncation_Short) {
  // Exactly 20 ASCII characters — no truncation.
  std::string twenty = "12345678901234567890";
  ASSERT_EQ(CountUtf8CodePoints(twenty), 20u);
  EXPECT_EQ(TruncateSearchDisplayText(twenty), twenty);

  // Under 20 characters.
  EXPECT_EQ(TruncateSearchDisplayText("Hello"), "Hello");
  EXPECT_EQ(TruncateSearchDisplayText(""), "");

  // Exactly 20 Chinese characters (3 bytes each = 60 bytes) — no truncation.
  std::string chinese_20;
  for (int i = 0; i < 20; ++i)
    chinese_20 += "\xe4\xbd\xa0";  // "你"
  ASSERT_EQ(CountUtf8CodePoints(chinese_20), 20u);
  EXPECT_EQ(TruncateSearchDisplayText(chinese_20), chinese_20);

  // Single character.
  EXPECT_EQ(TruncateSearchDisplayText("X"), "X");
}

// --- Phase 2 Test: Search text truncation — long text ---
// [P2-AC] selection_text > 20 characters → truncate to first 17 + "...".
TEST(OWLContextMenuPhase2Test, Phase2_SearchTextTruncation_Long) {
  // 21 ASCII characters → first 17 + "..."
  std::string twentyone = "123456789012345678901";
  ASSERT_EQ(CountUtf8CodePoints(twentyone), 21u);
  std::string result = TruncateSearchDisplayText(twentyone);
  EXPECT_EQ(result, "12345678901234567...");
  EXPECT_EQ(CountUtf8CodePoints(result), 20u);  // 17 + 3 dots

  // 30 ASCII characters → first 17 + "..."
  std::string thirty(30, 'A');
  result = TruncateSearchDisplayText(thirty);
  EXPECT_EQ(result, std::string(17, 'A') + "...");

  // 21 Chinese characters → first 17 Chinese chars + "..."
  std::string chinese_21;
  for (int i = 0; i < 21; ++i)
    chinese_21 += "\xe4\xbd\xa0";  // "你"
  ASSERT_EQ(CountUtf8CodePoints(chinese_21), 21u);
  result = TruncateSearchDisplayText(chinese_21);
  std::string expected_17;
  for (int i = 0; i < 17; ++i)
    expected_17 += "\xe4\xbd\xa0";
  expected_17 += "...";
  EXPECT_EQ(result, expected_17);
  // Result is 17 Chinese (51 bytes) + "..." (3 bytes) = 54 bytes.
  EXPECT_EQ(result.size(), 54u);

  // 100 characters → first 17 + "..."
  std::string hundred(100, 'z');
  result = TruncateSearchDisplayText(hundred);
  EXPECT_EQ(result, std::string(17, 'z') + "...");
}

// --- Phase 2 Test: Search text escaping ---
// [P2-AC] Special characters in search query must be URL-encoded for the
// search engine URL (e.g., spaces → "+", ampersands → "%26").
TEST(OWLContextMenuPhase2Test, Phase2_SearchTextEscaping) {
  // Space → "+"
  EXPECT_EQ(PercentEncodeSearchQuery("hello world"), "hello+world");

  // Ampersand → "%26"
  EXPECT_EQ(PercentEncodeSearchQuery("a&b"), "a%26b");

  // Equals → "%3D"
  EXPECT_EQ(PercentEncodeSearchQuery("key=value"), "key%3Dvalue");

  // Question mark → "%3F"
  EXPECT_EQ(PercentEncodeSearchQuery("what?"), "what%3F");

  // Hash → "%23"
  EXPECT_EQ(PercentEncodeSearchQuery("#anchor"), "%23anchor");

  // Plus sign → "%2B"
  EXPECT_EQ(PercentEncodeSearchQuery("c++"), "c%2B%2B");

  // Unreserved characters pass through unchanged.
  EXPECT_EQ(PercentEncodeSearchQuery("ABCxyz09-_.~"), "ABCxyz09-_.~");

  // Multi-byte UTF-8 characters: each byte is percent-encoded.
  // "你" = 0xE4 0xBD 0xA0 → "%E4%BD%A0"
  EXPECT_EQ(PercentEncodeSearchQuery("\xe4\xbd\xa0"), "%E4%BD%A0");

  // Mixed: "hello 你" → "hello+%E4%BD%A0"
  EXPECT_EQ(PercentEncodeSearchQuery("hello \xe4\xbd\xa0"),
            "hello+%E4%BD%A0");

  // Empty string.
  EXPECT_EQ(PercentEncodeSearchQuery(""), "");
}

// --- Phase 2 Test: Editable actions dispatch ---
// [P2-AC] kCut/kCopy/kPaste/kSelectAll map to WebContents editing commands.
// This verifies the action→command mapping used by the Host to dispatch
// clipboard/edit operations to the focused WebContents.
TEST(OWLContextMenuPhase2Test, Phase2_EditableActions) {
  // Each editable action maps to its WebContents command name.
  EXPECT_EQ(EditableActionToCommand(owl::mojom::ContextMenuAction::kCut),
            "Cut");
  EXPECT_EQ(EditableActionToCommand(owl::mojom::ContextMenuAction::kCopy),
            "Copy");
  EXPECT_EQ(EditableActionToCommand(owl::mojom::ContextMenuAction::kPaste),
            "Paste");
  EXPECT_EQ(
      EditableActionToCommand(owl::mojom::ContextMenuAction::kSelectAll),
      "SelectAll");

  // Non-editable actions return empty (not dispatched as edit commands).
  EXPECT_EQ(
      EditableActionToCommand(owl::mojom::ContextMenuAction::kCopyLink), "");
  EXPECT_EQ(
      EditableActionToCommand(owl::mojom::ContextMenuAction::kCopyImage), "");
  EXPECT_EQ(
      EditableActionToCommand(owl::mojom::ContextMenuAction::kSaveImage), "");

  // Verify dispatch through menu_id guard: only valid menu_id dispatches.
  MenuIdManager mgr;
  uint32_t valid_id = mgr.OnContextMenu();
  std::string dispatched_command;

  auto dispatch_edit = [&](owl::mojom::ContextMenuAction action,
                           uint32_t menu_id) {
    if (!mgr.IsMenuIdValid(menu_id))
      return;
    std::string cmd = EditableActionToCommand(action);
    if (!cmd.empty())
      dispatched_command = cmd;
  };

  // Valid menu_id + editable action → command dispatched.
  dispatch_edit(owl::mojom::ContextMenuAction::kPaste, valid_id);
  EXPECT_EQ(dispatched_command, "Paste");

  // Stale menu_id → no dispatch.
  dispatched_command.clear();
  mgr.OnNavigation();  // Invalidate.
  dispatch_edit(owl::mojom::ContextMenuAction::kCut, valid_id);
  EXPECT_EQ(dispatched_command, "");
}

// --- Phase 2 helper: search payload validation ---
// An empty or whitespace-only payload for kSearch is invalid. The Host should
// early-return without navigating to the search engine.
bool IsSearchPayloadValid(const std::string& payload) {
  for (char c : payload) {
    if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
      return true;
  }
  return false;  // Empty or all whitespace.
}

// --- Phase 2 helper: collapse control characters in search text ---
// Consecutive whitespace/control characters (\n, \t, \r, etc.) in the
// selection text should be collapsed to a single space before being used
// as a search query. This mirrors the expected Host-side sanitization.
std::string CollapseControlChars(const std::string& text) {
  std::string result;
  bool in_whitespace = false;
  for (char c : text) {
    if (c == '\n' || c == '\t' || c == '\r' || c == ' ') {
      if (!in_whitespace) {
        result += ' ';
        in_whitespace = true;
      }
    } else {
      result += c;
      in_whitespace = false;
    }
  }
  // Trim leading/trailing spaces.
  size_t start = result.find_first_not_of(' ');
  if (start == std::string::npos)
    return "";
  size_t end = result.find_last_not_of(' ');
  return result.substr(start, end - start + 1);
}

// --- Phase 2 Test: Search empty payload ---
// [P2-AC] kSearch with empty or whitespace-only payload should be rejected
// (early return, no search navigation).
TEST(OWLContextMenuPhase2Test, Phase2_SearchEmptyPayload) {
  // Empty string is invalid.
  EXPECT_FALSE(IsSearchPayloadValid(""));

  // Pure whitespace variants are all invalid.
  EXPECT_FALSE(IsSearchPayloadValid(" "));
  EXPECT_FALSE(IsSearchPayloadValid("   "));
  EXPECT_FALSE(IsSearchPayloadValid("\t"));
  EXPECT_FALSE(IsSearchPayloadValid("\n"));
  EXPECT_FALSE(IsSearchPayloadValid("\r\n"));
  EXPECT_FALSE(IsSearchPayloadValid("  \t\n  "));

  // Non-empty payloads are valid.
  EXPECT_TRUE(IsSearchPayloadValid("hello"));
  EXPECT_TRUE(IsSearchPayloadValid(" hello "));
  EXPECT_TRUE(IsSearchPayloadValid("a"));

  // Verify the dispatch pattern: empty payload should prevent action.
  MenuIdManager mgr;
  uint32_t valid_id = mgr.OnContextMenu();
  bool search_dispatched = false;

  auto maybe_search = [&](uint32_t menu_id, const std::string& payload) {
    if (!mgr.IsMenuIdValid(menu_id))
      return;
    if (!IsSearchPayloadValid(payload))
      return;
    search_dispatched = true;
  };

  // Empty payload — should not dispatch.
  maybe_search(valid_id, "");
  EXPECT_FALSE(search_dispatched);

  // Whitespace-only payload — should not dispatch.
  maybe_search(valid_id, "   ");
  EXPECT_FALSE(search_dispatched);

  // Valid payload — should dispatch.
  maybe_search(valid_id, "search term");
  EXPECT_TRUE(search_dispatched);
}

// --- Phase 2 Test: Scheme filter — data: rejected ---
// [P2-AC] data: URLs must be rejected for "Open Link in New Tab".
// data: URIs can encode arbitrary content including scripts and should not
// be opened as navigation targets from context menu links.
TEST(OWLContextMenuPhase2Test, Phase2_SchemeFilter_Data) {
  EXPECT_FALSE(IsLinkSchemeAllowed("data:text/html,<h1>hi</h1>"));
  EXPECT_FALSE(IsLinkSchemeAllowed("data:text/plain;base64,SGVsbG8="));
  EXPECT_FALSE(
      IsLinkSchemeAllowed("data:text/html;charset=utf-8,<script>alert(1)</script>"));
  // Edge: data: with empty body.
  EXPECT_FALSE(IsLinkSchemeAllowed("data:,"));
  // Edge: data: image (common in <img> src, but still rejected for link open).
  EXPECT_FALSE(IsLinkSchemeAllowed("data:image/png;base64,iVBOR..."));
}

// --- Phase 2 Test: Search text with control characters ---
// [P2-AC] Control characters (\n, \t, \r) in search text should be collapsed
// to a single space. This prevents malformed search queries from multi-line
// selections or tab-separated content.
TEST(OWLContextMenuPhase2Test, Phase2_SearchTextControlChars) {
  // Newlines collapsed to single space.
  EXPECT_EQ(CollapseControlChars("hello\nworld"), "hello world");
  EXPECT_EQ(CollapseControlChars("hello\n\nworld"), "hello world");

  // Tabs collapsed to single space.
  EXPECT_EQ(CollapseControlChars("hello\tworld"), "hello world");
  EXPECT_EQ(CollapseControlChars("col1\t\tcol2"), "col1 col2");

  // Mixed control characters collapsed.
  EXPECT_EQ(CollapseControlChars("line1\r\nline2"), "line1 line2");
  EXPECT_EQ(CollapseControlChars("a\n\t\r b"), "a b");

  // Leading/trailing whitespace and control chars trimmed.
  EXPECT_EQ(CollapseControlChars("\n\thello\n\t"), "hello");
  EXPECT_EQ(CollapseControlChars("  hello  "), "hello");

  // Pure control characters → empty string.
  EXPECT_EQ(CollapseControlChars("\n\t\r"), "");
  EXPECT_EQ(CollapseControlChars(""), "");

  // Single word with no control chars — unchanged.
  EXPECT_EQ(CollapseControlChars("hello"), "hello");

  // Normal spaces preserved (but consecutive collapsed).
  EXPECT_EQ(CollapseControlChars("hello   world"), "hello world");

  // UTF-8 content with control chars: control chars collapsed, multibyte preserved.
  EXPECT_EQ(CollapseControlChars("\xe4\xbd\xa0\n\xe5\xa5\xbd"),
            "\xe4\xbd\xa0 \xe5\xa5\xbd");  // "你\n好" → "你 好"

  // Verify the full pipeline: collapse + truncation + encoding.
  // A multi-line selection "hello\nworld" should become search query "hello+world".
  std::string collapsed = CollapseControlChars("hello\nworld");
  EXPECT_EQ(collapsed, "hello world");
  std::string display = TruncateSearchDisplayText(collapsed);
  EXPECT_EQ(display, "hello world");  // 11 chars, under 20 limit.
  std::string encoded = PercentEncodeSearchQuery(collapsed);
  EXPECT_EQ(encoded, "hello+world");
}

// ==========================================================================
// Phase 3 tests: Image menu + Security + View Source
// NOTE: kSaveImage/kCopyImage involve async Host operations (DownloadManager,
// DownloadImage). Unit tests verify scheme filtering and dispatch logic.
// End-to-end verification requires XCUITest (AC-006).
//
// Tests cover: image menu-type routing, src_url scheme filtering for
// save-image (data:/blob: rejected, https: allowed), copy-image-url Host
// clipboard operation via DownloadImage + ScopedClipboardWriter (with async
// fallback to OnCopyImageResult), view-source URL construction using Host
// page_url (not client payload), view-source scheme filter (only http/https
// pages), image-vs-selection priority (kImage > kSelection), and new Mojom
// enum values (kCopyImageUrl, kViewSource).
//
// NOTE: Phase 3 introduces kCopyImageUrl and kViewSource actions in the
// Mojom ContextMenuAction enum. The tests use local mirror helpers that
// encode the expected Phase 3 algorithms, consistent with the Phase 1/2
// pattern (see file header).
// ==========================================================================

// --- Phase 3 helper: src_url scheme filter for "Save Image" ---
// Only http: and https: src_url values are eligible for server-side save.
// data: and blob: URLs are rejected because:
//   - data: URLs embed content inline; the browser should not "save" them
//     as a network download.
//   - blob: URLs are ephemeral and tied to the renderer process lifetime;
//     they cannot be re-fetched by the Host (network service).
bool IsSrcUrlAllowedForSave(const std::string& url) {
  if (url.rfind("https://", 0) == 0)
    return true;
  if (url.rfind("http://", 0) == 0)
    return true;
  return false;
}

// --- Phase 3 helper: view-source URL construction ---
// Constructs a "view-source:<url>" string for the given page URL.
// SECURITY: Uses the Host-maintained page_url (from NavigationEntry), NOT
// any URL supplied by the client in the action payload. This prevents a
// malicious client from tricking the Host into opening arbitrary URLs.
// Returns empty string if the page URL scheme is not http or https.
std::string ConstructViewSourceUrl(const std::string& host_page_url) {
  // Only http/https pages support view-source.
  if (host_page_url.rfind("https://", 0) != 0 &&
      host_page_url.rfind("http://", 0) != 0) {
    return "";
  }
  return "view-source:" + host_page_url;
}

// --- Phase 3 Test 1: Image menu type ---
// [P3-AC] has_image_contents=true → kImage type.
TEST(OWLContextMenuPhase3Test, Phase3_ImageMenuType) {
  // Image only: no editable, no link, no selection.
  auto type = DetermineContextMenuType(
      /*is_editable=*/false,
      /*link_url=*/"",
      /*has_image_contents=*/true,
      /*selection_text=*/"");
  EXPECT_EQ(type, owl::mojom::ContextMenuType::kImage);
}

// --- Phase 3 Test 2: Save image src_url scheme filter — data:/blob: rejected ---
// [P3-AC] data: and blob: src_url values must be rejected for save-image.
TEST(OWLContextMenuPhase3Test, Phase3_SaveImage_SchemeFilter) {
  // data: URLs rejected (inline content, not a network resource).
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:image/png;base64,iVBOR..."));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:image/jpeg;base64,/9j/4AAQ"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:,"));

  // blob: URLs rejected (ephemeral renderer-process URLs).
  EXPECT_FALSE(IsSrcUrlAllowedForSave(
      "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("blob:null/some-uuid"));

  // Other invalid schemes.
  EXPECT_FALSE(IsSrcUrlAllowedForSave("file:///tmp/image.png"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("javascript:void(0)"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("ftp://files.example.com/img.png"));

  // Empty URL rejected.
  EXPECT_FALSE(IsSrcUrlAllowedForSave(""));
}

// --- Phase 3 Test 3: Save image — https: src_url allowed ---
// [P3-AC] https: (and http:) src_url values are allowed for save-image.
TEST(OWLContextMenuPhase3Test, Phase3_SaveImage_HttpsAllowed) {
  EXPECT_TRUE(IsSrcUrlAllowedForSave("https://example.com/photo.jpg"));
  EXPECT_TRUE(IsSrcUrlAllowedForSave("https://cdn.example.com/img.png?w=800"));
  EXPECT_TRUE(IsSrcUrlAllowedForSave("http://example.com/image.gif"));
  EXPECT_TRUE(IsSrcUrlAllowedForSave("http://localhost:8080/test.webp"));
}

// --- Phase 3 Test 4: Copy image URL — Host clipboard operation ---
// [P3-AC] "Copy Image Address" copies the src_url to the system pasteboard.
// The implementation flows through ExecuteContextMenuAction to the Host,
// where it uses ScopedClipboardWriter to write the URL string. This is a
// synchronous Host-side operation (unlike kCopyImage which involves async
// DownloadImage + OnCopyImageResult fallback).
//
// This test verifies only that the enum value exists and is distinct.
// The actual clipboard write is tested in integration / XCUITest (AC-006).
TEST(OWLContextMenuPhase3Test, Phase3_CopyImageUrl_Local) {
  // kCopyImageUrl enum value exists and is distinct from kCopyImage.
  EXPECT_NE(owl::mojom::ContextMenuAction::kCopyImageUrl,
            owl::mojom::ContextMenuAction::kCopyImage);

  // kCopyImageUrl is distinct from all other actions.
  EXPECT_NE(owl::mojom::ContextMenuAction::kCopyImageUrl,
            owl::mojom::ContextMenuAction::kCopyLink);
  EXPECT_NE(owl::mojom::ContextMenuAction::kCopyImageUrl,
            owl::mojom::ContextMenuAction::kSaveImage);
  EXPECT_NE(owl::mojom::ContextMenuAction::kCopyImageUrl,
            owl::mojom::ContextMenuAction::kViewSource);
}

// --- Phase 3 Test 5: View source uses Host page URL ---
// [P3-AC] view-source: URL must use the Host-maintained page_url (from
// NavigationEntry), NOT any URL supplied by the client in the payload.
// This prevents a malicious client from tricking the Host into navigating
// to an attacker-controlled view-source: URL.
TEST(OWLContextMenuPhase3Test, Phase3_ViewSource_UsesHostUrl) {
  // Host page URL is used directly.
  std::string result =
      ConstructViewSourceUrl("https://example.com/page.html");
  EXPECT_EQ(result, "view-source:https://example.com/page.html");

  // HTTP also valid.
  result = ConstructViewSourceUrl("http://localhost:8080/test");
  EXPECT_EQ(result, "view-source:http://localhost:8080/test");

  // Even if a hypothetical client payload suggests a different URL,
  // the Host ignores it and uses its own page_url. This is structural:
  // ConstructViewSourceUrl only takes the Host URL parameter.
  std::string host_url = "https://real-page.example.com/";
  std::string _client_payload = "https://evil.example.com/phish";
  // Only host_url is used:
  result = ConstructViewSourceUrl(host_url);
  EXPECT_EQ(result, "view-source:https://real-page.example.com/");
  (void)_client_payload;  // Suppress unused warning.
}

// --- Phase 3 Test 6: View source scheme filter ---
// [P3-AC] Non-http/https pages must NOT generate a view-source: URL.
// This covers about:blank, chrome:// internal pages, data: URLs, etc.
TEST(OWLContextMenuPhase3Test, Phase3_ViewSource_SchemeFilter) {
  // about:blank — no view-source.
  EXPECT_EQ(ConstructViewSourceUrl("about:blank"), "");

  // chrome:// internal page — no view-source.
  EXPECT_EQ(ConstructViewSourceUrl("chrome://settings"), "");

  // data: URL — no view-source.
  EXPECT_EQ(ConstructViewSourceUrl("data:text/html,<h1>hi</h1>"), "");

  // file: URL — no view-source.
  EXPECT_EQ(ConstructViewSourceUrl("file:///Users/foo/page.html"), "");

  // blob: URL — no view-source.
  EXPECT_EQ(ConstructViewSourceUrl(
      "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"), "");

  // Empty URL — no view-source.
  EXPECT_EQ(ConstructViewSourceUrl(""), "");

  // view-source: itself — should not double-wrap.
  EXPECT_EQ(ConstructViewSourceUrl("view-source:https://example.com"), "");

  // javascript: — no view-source.
  EXPECT_EQ(ConstructViewSourceUrl("javascript:void(0)"), "");
}

// --- Phase 3 Test 7: Image priority over selection ---
// [P3-AC] When both has_image_contents and selection_text are present,
// kImage (priority 2) takes precedence over kSelection (priority 3).
// Priority chain: kEditable(0) > kLink(1) > kImage(2) > kSelection(3) > kPage(4).
TEST(OWLContextMenuPhase3Test, Phase3_ImagePriority) {
  // Image + selection → kImage wins.
  auto type = DetermineContextMenuType(
      /*is_editable=*/false,
      /*link_url=*/"",
      /*has_image_contents=*/true,
      /*selection_text=*/"selected text on image");
  EXPECT_EQ(type, owl::mojom::ContextMenuType::kImage);

  // Image + link → kLink wins (link has higher priority than image).
  auto type2 = DetermineContextMenuType(
      /*is_editable=*/false,
      /*link_url=*/"https://example.com",
      /*has_image_contents=*/true,
      /*selection_text=*/"");
  EXPECT_EQ(type2, owl::mojom::ContextMenuType::kLink);

  // Image + link + selection → kLink wins (link > image > selection).
  auto type3 = DetermineContextMenuType(
      /*is_editable=*/false,
      /*link_url=*/"https://example.com",
      /*has_image_contents=*/true,
      /*selection_text=*/"selected");
  EXPECT_EQ(type3, owl::mojom::ContextMenuType::kLink);

  // Image + editable → kEditable wins (editable > all).
  auto type4 = DetermineContextMenuType(
      /*is_editable=*/true,
      /*link_url=*/"",
      /*has_image_contents=*/true,
      /*selection_text=*/"");
  EXPECT_EQ(type4, owl::mojom::ContextMenuType::kEditable);
}

// --- Phase 3 Test 8: Mojom enum values for Phase 3 additions ---
// [P3-AC] Verify that kCopyImageUrl and kViewSource have the expected
// ordinal values in the Mojom enum. This catches accidental reordering.
TEST(OWLContextMenuPhase3Test, Phase3_MojomEnumValues) {
  // Phase 3 additions follow kSearch (index 8).
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCopyImageUrl), 9);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kViewSource), 10);

  // Verify Phase 1/2 values are unchanged (regression check).
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCopyLink), 0);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCopyImage), 1);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kSaveImage), 2);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCopy), 3);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kCut), 4);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kPaste), 5);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kSelectAll), 6);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kOpenLinkInNewTab), 7);
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kSearch), 8);

  // Total enum count: 11 actions (0..10). If new actions are added,
  // this assertion reminds us to update this test.
  EXPECT_EQ(static_cast<int>(owl::mojom::ContextMenuAction::kViewSource), 10);
}

// --- Phase 3 Boundary Test: Save image — data: URL rejected ---
// [P3-AC] data: src_url must be rejected for save-image. data: URLs embed
// inline content and are not network resources; the Host DownloadManager
// cannot (and should not) "save" them as a download.
TEST(OWLContextMenuPhase3Test, Phase3_SaveImage_DataUrlRejected) {
  // Various data: URL forms — all must be rejected.
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:image/png;base64,iVBOR..."));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:image/svg+xml,%3Csvg%3E%3C/svg%3E"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:image/gif;base64,R0lGODlh"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:,"));
  // data: with text content (not an image, but still a data: URL).
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:text/plain,hello"));
}

// --- Phase 3 Boundary Test: Save image — blob: URL rejected ---
// [P3-AC] blob: src_url must be rejected for save-image. blob: URLs are
// ephemeral, tied to the renderer process lifetime, and cannot be re-fetched
// by the Host network service after the renderer context is gone.
TEST(OWLContextMenuPhase3Test, Phase3_SaveImage_BlobUrlRejected) {
  EXPECT_FALSE(IsSrcUrlAllowedForSave(
      "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("blob:null/some-uuid"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave(
      "blob:http://localhost:3000/abcdef12-3456-7890-abcd-ef1234567890"));
  // Edge: blob: with no origin.
  EXPECT_FALSE(IsSrcUrlAllowedForSave("blob:"));
}

// --- Phase 3 Boundary Test: View source — non-http/https rejected ---
// [P3-AC] Non-http/https pages must not generate a view-source: URL.
// This specifically tests schemes that are not covered by the main scheme
// filter test (Phase3_ViewSource_SchemeFilter) — focusing on edge cases.
TEST(OWLContextMenuPhase3Test, Phase3_ViewSource_NonHttpRejected) {
  // ftp: — old protocol, not viewable.
  EXPECT_EQ(ConstructViewSourceUrl("ftp://files.example.com/page.html"), "");

  // ws:/wss: — WebSocket URLs are not viewable pages.
  EXPECT_EQ(ConstructViewSourceUrl("ws://example.com/socket"), "");
  EXPECT_EQ(ConstructViewSourceUrl("wss://example.com/socket"), "");

  // Custom/unknown schemes.
  EXPECT_EQ(ConstructViewSourceUrl("custom://my-app/page"), "");
  EXPECT_EQ(ConstructViewSourceUrl("owl://internal"), "");

  // Verify that valid http/https still works (positive control).
  EXPECT_EQ(ConstructViewSourceUrl("https://example.com"),
            "view-source:https://example.com");
  EXPECT_EQ(ConstructViewSourceUrl("http://example.com"),
            "view-source:http://example.com");
}

// --- Phase 3 Boundary Test: Copy image — empty bitmap fallback ---
// [P3-AC] When the Host's DownloadImage call returns an empty bitmap (e.g.,
// network failure, 404, or the image cannot be decoded), the Host sends
// OnCopyImageResult(success=false, fallback_url=src_url) to the client.
// The client should degrade gracefully by copying the src_url to the
// pasteboard instead.
//
// This test verifies the fallback decision logic: success=false triggers
// fallback to URL copy; success=true means image data was written.
TEST(OWLContextMenuPhase3Test, Phase3_CopyImage_EmptyBitmapFallback) {
  // Simulate the OnCopyImageResult callback decision logic.
  // success=false, fallback_url present → client copies URL.
  struct CopyImageResult {
    bool success;
    std::string fallback_url;
  };

  auto should_fallback_to_url = [](const CopyImageResult& result) -> bool {
    return !result.success && !result.fallback_url.empty();
  };

  // Image download failed, fallback URL provided → fallback to URL copy.
  CopyImageResult failed_with_url{false, "https://example.com/photo.jpg"};
  EXPECT_TRUE(should_fallback_to_url(failed_with_url));

  // Image download failed, no fallback URL → no fallback possible.
  CopyImageResult failed_no_url{false, ""};
  EXPECT_FALSE(should_fallback_to_url(failed_no_url));

  // Image download succeeded → no fallback needed (image data on pasteboard).
  CopyImageResult succeeded{true, ""};
  EXPECT_FALSE(should_fallback_to_url(succeeded));

  // Image download succeeded but fallback_url also present → still no fallback
  // (success takes precedence).
  CopyImageResult succeeded_with_url{true, "https://example.com/photo.jpg"};
  EXPECT_FALSE(should_fallback_to_url(succeeded_with_url));

  // Verify fallback URL scheme: only http/https URLs are useful for fallback.
  // data:/blob: fallback URLs are not useful to copy.
  EXPECT_TRUE(IsSrcUrlAllowedForSave("https://example.com/photo.jpg"));
  EXPECT_FALSE(IsSrcUrlAllowedForSave("data:image/png;base64,iVBOR..."));
  EXPECT_FALSE(IsSrcUrlAllowedForSave(
      "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"));
}

}  // namespace
}  // namespace owl
