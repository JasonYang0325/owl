// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#ifndef THIRD_PARTY_OWL_HOST_OWL_CONTEXT_MENU_UTILS_H_
#define THIRD_PARTY_OWL_HOST_OWL_CONTEXT_MENU_UTILS_H_

#include <string>

#include "third_party/owl/mojom/web_view.mojom.h"

namespace owl {

// Determines the context menu type using the priority chain:
//   kEditable > kLink > kImage > kSelection > kPage
// Pure function: no side effects, no dependencies on global state.
owl::mojom::ContextMenuType DetermineContextMenuType(
    bool is_editable,
    const std::string& link_url,
    bool has_image_contents,
    const std::string& selection_text);

// Truncates UTF-8 selection text to 10KB (10240 bytes) without breaking
// multibyte sequences. If the text is within the limit, returns it unchanged.
// Pure function: no side effects.
std::string TruncateSelectionTextUTF8(const std::string& text);

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_CONTEXT_MENU_UTILS_H_
