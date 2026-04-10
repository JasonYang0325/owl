// Copyright 2026 AntlerAI. All rights reserved.
// Session-level SSL certificate exception storage for OWL Host.
// Implements content::SSLHostStateDelegate with in-memory storage
// that resets on process restart (satisfies AC-P4-6).

#ifndef THIRD_PARTY_OWL_HOST_OWL_SSL_HOST_STATE_DELEGATE_H_
#define THIRD_PARTY_OWL_HOST_OWL_SSL_HOST_STATE_DELEGATE_H_

#include <set>
#include <string>

#include "content/public/browser/ssl_host_state_delegate.h"
#include "net/cert/x509_certificate.h"

namespace owl {

class OWLSSLHostStateDelegate : public content::SSLHostStateDelegate {
 public:
  OWLSSLHostStateDelegate();
  ~OWLSSLHostStateDelegate() override;

  OWLSSLHostStateDelegate(const OWLSSLHostStateDelegate&) = delete;
  OWLSSLHostStateDelegate& operator=(const OWLSSLHostStateDelegate&) = delete;

  // content::SSLHostStateDelegate:
  void AllowCert(const std::string& host,
                 const net::X509Certificate& cert,
                 int error,
                 content::StoragePartition* storage_partition) override;

  void Clear(
      base::RepeatingCallback<bool(const std::string&)> host_filter) override;

  CertJudgment QueryPolicy(const std::string& host,
                            const net::X509Certificate& cert,
                            int error,
                            content::StoragePartition* storage_partition) override;

  void HostRanInsecureContent(const std::string& host,
                              InsecureContentType content_type) override;
  bool DidHostRunInsecureContent(
      const std::string& host,
      InsecureContentType content_type) override;

  void AllowHttpForHost(const std::string& host,
                        content::StoragePartition* storage_partition) override;
  bool IsHttpAllowedForHost(
      const std::string& host,
      content::StoragePartition* storage_partition) override;

  void RevokeUserAllowExceptions(const std::string& host) override;

  void SetHttpsEnforcementForHost(
      const std::string& host,
      bool enforce,
      content::StoragePartition* storage_partition) override;
  bool IsHttpsEnforcedForUrl(
      const GURL& url,
      content::StoragePartition* storage_partition) override;

  bool HasAllowException(
      const std::string& host,
      content::StoragePartition* storage_partition) override;
  bool HasAllowExceptionForAnyHost(
      content::StoragePartition* storage_partition) override;

 private:
  // Key for the allowed cert set: (host, cert_fingerprint_sha256, net_error).
  // cert_fingerprint is base::Base64Encode of the chain fingerprint.
  struct AllowKey {
    std::string host;
    std::string cert_fingerprint;
    int error;

    bool operator<(const AllowKey& other) const;
  };

  // Session-level storage: not persisted to disk.
  // Process restart clears all entries (AC-P4-6).
  std::set<AllowKey> allowed_certs_;
  std::set<std::string> ran_mixed_content_;
  std::set<std::string> ran_cert_error_content_;
  std::set<std::string> http_allowed_hosts_;
};

}  // namespace owl

#endif  // THIRD_PARTY_OWL_HOST_OWL_SSL_HOST_STATE_DELEGATE_H_
