// Copyright 2026 AntlerAI. All rights reserved.
// Minimal ContentUtilityClient for OWL Host Utility subprocess.

#ifndef THIRD_PARTY_OWL_HOST_OWL_CONTENT_UTILITY_CLIENT_H_
#define THIRD_PARTY_OWL_HOST_OWL_CONTENT_UTILITY_CLIENT_H_

#include "content/public/utility/content_utility_client.h"

namespace owl {

class OWLContentUtilityClient : public content::ContentUtilityClient {
 public:
  OWLContentUtilityClient() = default;
  ~OWLContentUtilityClient() override = default;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_CONTENT_UTILITY_CLIENT_H_
