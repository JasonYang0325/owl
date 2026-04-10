// Copyright 2026 AntlerAI. All rights reserved.
#import "third_party/owl/client/OWLAddressBarController.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

TEST(OWLAddressBarControllerTest, HttpsUrlPassthrough) {
  NSURL* url = [OWLAddressBarController urlFromInput:@"https://example.com"];
  EXPECT_TRUE([url.absoluteString isEqualToString:@"https://example.com"]);
}

TEST(OWLAddressBarControllerTest, HttpUrlPassthrough) {
  NSURL* url = [OWLAddressBarController urlFromInput:@"http://example.com"];
  EXPECT_TRUE([url.absoluteString isEqualToString:@"http://example.com"]);
}

TEST(OWLAddressBarControllerTest, DataUrlPassthrough) {
  NSURL* url = [OWLAddressBarController urlFromInput:@"data:text/html,<h1>Hi</h1>"];
  EXPECT_TRUE([url.absoluteString hasPrefix:@"data:"]);
}

TEST(OWLAddressBarControllerTest, DomainGetsHttpsPrefix) {
  NSURL* url = [OWLAddressBarController urlFromInput:@"example.com"];
  EXPECT_TRUE([url.absoluteString isEqualToString:@"https://example.com"]);
}

TEST(OWLAddressBarControllerTest, DomainWithPathGetsHttps) {
  NSURL* url = [OWLAddressBarController urlFromInput:@"example.com/page"];
  EXPECT_TRUE([url.absoluteString isEqualToString:@"https://example.com/page"]);
}

TEST(OWLAddressBarControllerTest, SearchQuery) {
  NSURL* url = [OWLAddressBarController urlFromInput:@"how to code"];
  EXPECT_TRUE([url.absoluteString containsString:@"google.com/search"]);
  EXPECT_TRUE([url.absoluteString containsString:@"how%20to%20code"]);
}

TEST(OWLAddressBarControllerTest, EmptyInputReturnsNil) {
  EXPECT_EQ([OWLAddressBarController urlFromInput:@""], nil);
}

TEST(OWLAddressBarControllerTest, WhitespaceInputReturnsNil) {
  EXPECT_EQ([OWLAddressBarController urlFromInput:@"   "], nil);
}

TEST(OWLAddressBarControllerTest, ChineseSearchQuery) {
  NSURL* url = [OWLAddressBarController urlFromInput:@"浏览器开发"];
  EXPECT_TRUE([url.absoluteString containsString:@"google.com/search"]);
}

TEST(OWLAddressBarControllerTest, InputLooksLikeURL) {
  EXPECT_TRUE([OWLAddressBarController inputLooksLikeURL:@"example.com"]);
  EXPECT_TRUE([OWLAddressBarController inputLooksLikeURL:@"a.b.c"]);
  EXPECT_FALSE([OWLAddressBarController inputLooksLikeURL:@"hello world"]);
  EXPECT_FALSE([OWLAddressBarController inputLooksLikeURL:@"noperiod"]);
  EXPECT_FALSE([OWLAddressBarController inputLooksLikeURL:@"has space.com"]);
}

TEST(OWLAddressBarControllerTest, LeadingTrailingWhitespace) {
  NSURL* url = [OWLAddressBarController urlFromInput:@"  example.com  "];
  EXPECT_TRUE([url.absoluteString isEqualToString:@"https://example.com"]);
}

// BH-013: URL encoding — NSURLComponents auto-encodes query values.
TEST(OWLAddressBarControllerTest, SearchQueryEncodesPlus) {
  // AC-1: "C++ programming" must encode '+' as %2B in the query.
  NSURL* url = [OWLAddressBarController urlFromInput:@"C++ programming"];
  ASSERT_NE(url, nil);
  NSString* abs = url.absoluteString;
  EXPECT_TRUE([abs containsString:@"google.com/search"]);
  // '+' must be percent-encoded (%2B), not left as literal '+'.
  EXPECT_TRUE([abs containsString:@"%2B"]);
  EXPECT_FALSE([abs containsString:@"C++"]);
}

TEST(OWLAddressBarControllerTest, SearchQueryEncodesAmpersandAndEquals) {
  // AC-2: "a=1&b=2" must encode '&' and '=' so they are not mistaken
  // for query parameter separators.
  NSURL* url = [OWLAddressBarController urlFromInput:@"a=1&b=2"];
  ASSERT_NE(url, nil);
  NSString* abs = url.absoluteString;
  EXPECT_TRUE([abs containsString:@"google.com/search"]);
  // '=' and '&' in the search term must be percent-encoded.
  EXPECT_TRUE([abs containsString:@"%3D"] || [abs containsString:@"%3d"]);
  EXPECT_TRUE([abs containsString:@"%26"]);
}

// BH-020: inputLooksLikeURL heuristic improvements.
TEST(OWLAddressBarControllerTest, VersionNumberNotURL) {
  // AC-4: "1.0.0" should NOT be treated as a URL.
  EXPECT_FALSE([OWLAddressBarController inputLooksLikeURL:@"1.0.0"]);
  NSURL* url = [OWLAddressBarController urlFromInput:@"1.0.0"];
  ASSERT_NE(url, nil);
  // Should route to search, not to https://1.0.0
  EXPECT_TRUE([url.absoluteString containsString:@"google.com/search"]);
}

TEST(OWLAddressBarControllerTest, LocalhostWithPortIsURL) {
  // AC-5: "localhost:8080" is a URL.
  EXPECT_TRUE([OWLAddressBarController inputLooksLikeURL:@"localhost:8080"]);
  NSURL* url = [OWLAddressBarController urlFromInput:@"localhost:8080"];
  ASSERT_NE(url, nil);
  EXPECT_TRUE([url.absoluteString containsString:@"localhost"]);
}

TEST(OWLAddressBarControllerTest, IPAddressIsURL) {
  // AC-6: "192.168.1.1" is a URL.
  EXPECT_TRUE([OWLAddressBarController inputLooksLikeURL:@"192.168.1.1"]);
  NSURL* url = [OWLAddressBarController urlFromInput:@"192.168.1.1"];
  ASSERT_NE(url, nil);
  EXPECT_TRUE([url.absoluteString containsString:@"192.168.1.1"]);
}

}  // namespace
}  // namespace owl
