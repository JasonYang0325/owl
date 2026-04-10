// Copyright 2026 AntlerAI. All rights reserved.
// Tests for OWLMainDelegate — content client factory methods.

#include "third_party/owl/host/owl_main_delegate.h"

#include "content/public/gpu/content_gpu_client.h"
#include "content/public/renderer/content_renderer_client.h"
#include "content/public/utility/content_utility_client.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

TEST(OWLMainDelegateTest, CreateContentClient) {
  OWLMainDelegate delegate;
  content::ContentClient* client = delegate.CreateContentClient();
  ASSERT_NE(nullptr, client);
}

TEST(OWLMainDelegateTest, CreateContentBrowserClient) {
  OWLMainDelegate delegate;
  content::ContentBrowserClient* client =
      delegate.CreateContentBrowserClient();
  ASSERT_NE(nullptr, client);
}

TEST(OWLMainDelegateTest, CreateContentGpuClient) {
  OWLMainDelegate delegate;
  content::ContentGpuClient* client = delegate.CreateContentGpuClient();
  ASSERT_NE(nullptr, client);
}

TEST(OWLMainDelegateTest, CreateContentRendererClient) {
  OWLMainDelegate delegate;
  content::ContentRendererClient* client =
      delegate.CreateContentRendererClient();
  ASSERT_NE(nullptr, client);
}

TEST(OWLMainDelegateTest, CreateContentUtilityClient) {
  OWLMainDelegate delegate;
  content::ContentUtilityClient* client =
      delegate.CreateContentUtilityClient();
  ASSERT_NE(nullptr, client);
}

TEST(OWLMainDelegateTest, BasicStartupCompleteReturnsNullopt) {
  OWLMainDelegate delegate;
  EXPECT_FALSE(delegate.BasicStartupComplete().has_value());
}

TEST(OWLMainDelegateTest, PreBrowserMainReturnsNullopt) {
  OWLMainDelegate delegate;
  EXPECT_FALSE(delegate.PreBrowserMain().has_value());
}

TEST(OWLContentClientTest, GetLocalizedStringReturnsEmpty) {
  OWLContentClient client;
  EXPECT_TRUE(client.GetLocalizedString(0).empty());
}

}  // namespace
}  // namespace owl
