// Copyright 2026 AntlerAI. All rights reserved.
// Minimal ContentGpuClient for OWL Host GPU subprocess.

#ifndef THIRD_PARTY_OWL_HOST_OWL_CONTENT_GPU_CLIENT_H_
#define THIRD_PARTY_OWL_HOST_OWL_CONTENT_GPU_CLIENT_H_

#include "content/public/gpu/content_gpu_client.h"

namespace owl {

class OWLContentGpuClient : public content::ContentGpuClient {
 public:
  OWLContentGpuClient() = default;
  ~OWLContentGpuClient() override = default;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_CONTENT_GPU_CLIENT_H_
