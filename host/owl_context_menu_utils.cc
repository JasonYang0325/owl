// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#include "third_party/owl/host/owl_context_menu_utils.h"

namespace owl {

owl::mojom::ContextMenuType DetermineContextMenuType(
    bool is_editable,
    const std::string& link_url,
    bool has_image_contents,
    const std::string& selection_text) {
  if (is_editable)
    return owl::mojom::ContextMenuType::kEditable;
  if (!link_url.empty())
    return owl::mojom::ContextMenuType::kLink;
  if (has_image_contents)
    return owl::mojom::ContextMenuType::kImage;
  if (!selection_text.empty())
    return owl::mojom::ContextMenuType::kSelection;
  return owl::mojom::ContextMenuType::kPage;
}

std::string TruncateSelectionTextUTF8(const std::string& text) {
  constexpr size_t kMaxBytes = 10240;
  if (text.size() <= kMaxBytes)
    return text;

  // Check whether the byte at the cut point is a UTF-8 continuation byte
  // (10xxxxxx). If so, the cut splits a multibyte sequence and we need to
  // walk back to drop the incomplete character. If the byte at the cut point
  // is a lead byte or ASCII, the preceding character is complete.
  size_t end = kMaxBytes;
  while (end > 0 &&
         (static_cast<unsigned char>(text[end]) & 0xC0) == 0x80) {
    --end;
  }
  return text.substr(0, end);
}

}  // namespace owl
