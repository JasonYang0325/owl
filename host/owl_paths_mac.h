// Copyright 2026 AntlerAI. All rights reserved.
// Bundle path overrides for OWL Host on macOS.
// Must be called before ContentMain() — sets Framework, Helper, and Outer
// bundle paths so Chromium can discover Helper Apps for GPU/Renderer processes.

#ifndef THIRD_PARTY_OWL_HOST_OWL_PATHS_MAC_H_
#define THIRD_PARTY_OWL_HOST_OWL_PATHS_MAC_H_

namespace owl {

// Override Framework, Outer, and Child Process paths for the OWL Host bundle.
// Modeled after content/shell/app/paths_apple.mm.
// |is_subprocess| should be true for GPU/Renderer/Utility helpers.
void OverrideOWLBundlePaths(bool is_subprocess);

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_PATHS_MAC_H_
