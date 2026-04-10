// Copyright 2026 AntlerAI. All rights reserved.
// Unit tests for OWLSSLHostStateDelegate.
// Tests are organized by AC (Acceptance Criteria) from
// phase-4-ssl-security.md section 8.1.

#include "third_party/owl/host/owl_ssl_host_state_delegate.h"

#include <string>

#include "base/functional/callback.h"
#include "content/public/browser/ssl_host_state_delegate.h"
#include "net/base/net_errors.h"
#include "net/cert/x509_certificate.h"
#include "net/test/cert_test_util.h"
#include "net/test/test_certificate_data.h"
#include "net/test/test_data_directory.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// Aliases for readability.
using CertJudgment = content::SSLHostStateDelegate::CertJudgment;

const char kHostA[] = "example.com";
const char kHostB[] = "other.com";
constexpr int kCertErrorExpired = net::ERR_CERT_DATE_INVALID;
constexpr int kCertErrorAuthority = net::ERR_CERT_AUTHORITY_INVALID;

// =============================================================================
// Test fixture
// =============================================================================

class OWLSSLHostStateDelegateTest : public testing::Test {
 protected:
  void SetUp() override {
    delegate_ = std::make_unique<OWLSSLHostStateDelegate>();

    // Load a real test certificate from Chromium's test data.
    cert_ =
        net::ImportCertFromFile(net::GetTestCertsDirectory(), "ok_cert.pem");
    ASSERT_TRUE(cert_);

    // Load a second certificate to verify fingerprint isolation.
    cert_b_ = net::ImportCertFromFile(net::GetTestCertsDirectory(),
                                      "root_ca_cert.pem");
    ASSERT_TRUE(cert_b_);
  }

  // Create a fresh delegate (simulates process restart -> session reset).
  void ResetDelegate() {
    delegate_ = std::make_unique<OWLSSLHostStateDelegate>();
  }

  std::unique_ptr<OWLSSLHostStateDelegate> delegate_;
  scoped_refptr<net::X509Certificate> cert_;
  scoped_refptr<net::X509Certificate> cert_b_;
};

// =============================================================================
// AC-P4-6: AllowCert then QueryPolicy returns ALLOWED (same host+cert+error)
// =============================================================================

// AC-P4-6: AllowCert stores the exception; QueryPolicy retrieves it.
TEST_F(OWLSSLHostStateDelegateTest, AllowCertAndQueryPolicy) {
  // Before AllowCert, policy should be DENIED.
  EXPECT_EQ(delegate_->QueryPolicy(kHostA, *cert_, kCertErrorExpired,
                                   /*storage_partition=*/nullptr),
            CertJudgment::DENIED);

  // Allow the certificate for kHostA with a specific error.
  delegate_->AllowCert(kHostA, *cert_, kCertErrorExpired,
                       /*storage_partition=*/nullptr);

  // AC-P4-6: After AllowCert, same (host, cert, error) -> ALLOWED.
  EXPECT_EQ(delegate_->QueryPolicy(kHostA, *cert_, kCertErrorExpired,
                                   /*storage_partition=*/nullptr),
            CertJudgment::ALLOWED);
}

// =============================================================================
// AC-P4-6: Different error code -> DENIED (fingerprint matches but error
// differs)
// =============================================================================

// AC-P4-6: AllowCert(err=A) then QueryPolicy(err=B) -> DENIED.
TEST_F(OWLSSLHostStateDelegateTest, DifferentErrorNotAllowed) {
  delegate_->AllowCert(kHostA, *cert_, kCertErrorExpired,
                       /*storage_partition=*/nullptr);

  // Same host, same cert, different error -> DENIED.
  EXPECT_EQ(delegate_->QueryPolicy(kHostA, *cert_, kCertErrorAuthority,
                                   /*storage_partition=*/nullptr),
            CertJudgment::DENIED);
}

// =============================================================================
// AC-P4-6: Different host -> DENIED (error and cert match but host differs)
// =============================================================================

// AC-P4-6: AllowCert(host=a.com) then QueryPolicy(host=b.com) -> DENIED.
TEST_F(OWLSSLHostStateDelegateTest, DifferentHostNotAllowed) {
  delegate_->AllowCert(kHostA, *cert_, kCertErrorExpired,
                       /*storage_partition=*/nullptr);

  // Different host, same cert and error -> DENIED.
  EXPECT_EQ(delegate_->QueryPolicy(kHostB, *cert_, kCertErrorExpired,
                                   /*storage_partition=*/nullptr),
            CertJudgment::DENIED);
}

// =============================================================================
// AC-P4-6: Clear(null filter) clears all exceptions
// =============================================================================

// AC-P4-6: Clear with null filter clears all allowed certificates.
TEST_F(OWLSSLHostStateDelegateTest, ClearAll) {
  delegate_->AllowCert(kHostA, *cert_, kCertErrorExpired,
                       /*storage_partition=*/nullptr);
  delegate_->AllowCert(kHostB, *cert_b_, kCertErrorAuthority,
                       /*storage_partition=*/nullptr);

  // Precondition: both allowed.
  EXPECT_EQ(delegate_->QueryPolicy(kHostA, *cert_, kCertErrorExpired, nullptr),
            CertJudgment::ALLOWED);
  EXPECT_EQ(
      delegate_->QueryPolicy(kHostB, *cert_b_, kCertErrorAuthority, nullptr),
      CertJudgment::ALLOWED);

  // Clear with null (empty) callback -> all entries removed.
  delegate_->Clear(base::RepeatingCallback<bool(const std::string&)>());

  // AC-P4-6: After ClearAll, all queries return DENIED.
  EXPECT_EQ(delegate_->QueryPolicy(kHostA, *cert_, kCertErrorExpired, nullptr),
            CertJudgment::DENIED);
  EXPECT_EQ(
      delegate_->QueryPolicy(kHostB, *cert_b_, kCertErrorAuthority, nullptr),
      CertJudgment::DENIED);
}

// =============================================================================
// AC-P4-6: Clear(host filter) only clears matching host
// =============================================================================

// AC-P4-6: Clear with host filter removes only matching entries.
TEST_F(OWLSSLHostStateDelegateTest, ClearHostFilter) {
  delegate_->AllowCert(kHostA, *cert_, kCertErrorExpired,
                       /*storage_partition=*/nullptr);
  delegate_->AllowCert(kHostB, *cert_b_, kCertErrorAuthority,
                       /*storage_partition=*/nullptr);

  // Clear only kHostA entries.
  delegate_->Clear(base::BindRepeating(
      [](const std::string& host) -> bool { return host == kHostA; }));

  // AC-P4-6: kHostA cleared -> DENIED.
  EXPECT_EQ(delegate_->QueryPolicy(kHostA, *cert_, kCertErrorExpired, nullptr),
            CertJudgment::DENIED);

  // AC-P4-6: kHostB untouched -> still ALLOWED.
  EXPECT_EQ(
      delegate_->QueryPolicy(kHostB, *cert_b_, kCertErrorAuthority, nullptr),
      CertJudgment::ALLOWED);
}

// =============================================================================
// AC-P4-6: Session reset -- new delegate instance has no remembered exceptions
// =============================================================================

// AC-P4-6: New OWLSSLHostStateDelegate has empty state (session-level memory).
TEST_F(OWLSSLHostStateDelegateTest, SessionReset) {
  delegate_->AllowCert(kHostA, *cert_, kCertErrorExpired,
                       /*storage_partition=*/nullptr);

  // Precondition: allowed before reset.
  EXPECT_EQ(delegate_->QueryPolicy(kHostA, *cert_, kCertErrorExpired, nullptr),
            CertJudgment::ALLOWED);

  // Simulate process restart -- new delegate instance.
  ResetDelegate();

  // AC-P4-6: After session reset, QueryPolicy returns DENIED.
  EXPECT_EQ(delegate_->QueryPolicy(kHostA, *cert_, kCertErrorExpired, nullptr),
            CertJudgment::DENIED);
}

// =============================================================================
// AC-P4-6: HasAllowException tracks certificate exceptions
// =============================================================================

// AC-P4-6: HasAllowException returns true after AllowCert, false after Clear.
TEST_F(OWLSSLHostStateDelegateTest, HasAllowException) {
  // Initially no exceptions.
  EXPECT_FALSE(
      delegate_->HasAllowException(kHostA, /*storage_partition=*/nullptr));

  delegate_->AllowCert(kHostA, *cert_, kCertErrorExpired,
                       /*storage_partition=*/nullptr);

  // AC-P4-6: HasAllowException returns true after AllowCert.
  EXPECT_TRUE(
      delegate_->HasAllowException(kHostA, /*storage_partition=*/nullptr));

  // Unrelated host should not have exception.
  EXPECT_FALSE(
      delegate_->HasAllowException(kHostB, /*storage_partition=*/nullptr));

  // Clear all.
  delegate_->Clear(base::RepeatingCallback<bool(const std::string&)>());

  // AC-P4-6: HasAllowException returns false after Clear.
  EXPECT_FALSE(
      delegate_->HasAllowException(kHostA, /*storage_partition=*/nullptr));
}

}  // namespace
}  // namespace owl
