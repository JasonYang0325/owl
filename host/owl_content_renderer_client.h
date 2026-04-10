// Copyright 2026 AntlerAI. All rights reserved.
// Minimal ContentRendererClient for OWL Host Renderer subprocess.

#ifndef THIRD_PARTY_OWL_HOST_OWL_CONTENT_RENDERER_CLIENT_H_
#define THIRD_PARTY_OWL_HOST_OWL_CONTENT_RENDERER_CLIENT_H_

#include "content/public/renderer/content_renderer_client.h"

namespace owl {

class OWLContentRendererClient : public content::ContentRendererClient {
 public:
  OWLContentRendererClient() = default;
  ~OWLContentRendererClient() override = default;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_CONTENT_RENDERER_CLIENT_H_
