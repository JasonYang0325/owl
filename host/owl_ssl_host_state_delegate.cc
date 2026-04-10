// Copyright 2026 AntlerAI. All rights reserved.

#include "third_party/owl/host/owl_ssl_host_state_delegate.h"

#include <algorithm>

#include "base/base64.h"
#include "base/functional/callback.h"
#include "base/logging.h"
#include "net/cert/x509_certificate.h"

namespace owl {

namespace {

// Compute a deterministic fingerprint string for the certificate chain.
// Uses SHA-256 chain fingerprint, base64-encoded.
std::string CertFingerprint(const net::X509Certificate& cert) {
  net::SHA256HashValue hash = cert.CalculateChainFingerprint256();
  return base::Base64Encode(base::span<const uint8_t>(hash));
}

}  // namespace

bool OWLSSLHostStateDelegate::AllowKey::operator<(
    const AllowKey& other) const {
  if (host != other.host) return host < other.host;
  if (cert_fingerprint != other.cert_fingerprint)
    return cert_fingerprint < other.cert_fingerprint;
  return error < other.error;
}

OWLSSLHostStateDelegate::OWLSSLHostStateDelegate() = default;
OWLSSLHostStateDelegate::~OWLSSLHostStateDelegate() = default;

void OWLSSLHostStateDelegate::AllowCert(
    const std::string& host,
    const net::X509Certificate& cert,
    int error,
    content::StoragePartition* /*storage_partition*/) {
  AllowKey key{host, CertFingerprint(cert), error};
  allowed_certs_.insert(std::move(key));
  LOG(INFO) << "[OWL] SSL: AllowCert for host=" << host << " error=" << error;
}

void OWLSSLHostStateDelegate::Clear(
    base::RepeatingCallback<bool(const std::string&)> host_filter) {
  if (host_filter.is_null()) {
    allowed_certs_.clear();
    ran_mixed_content_.clear();
    ran_cert_error_content_.clear();
    http_allowed_hosts_.clear();
    return;
  }

  // Erase entries matching the host filter.
  std::erase_if(allowed_certs_, [&](const AllowKey& key) {
    return host_filter.Run(key.host);
  });
  std::erase_if(ran_mixed_content_, [&](const std::string& h) {
    return host_filter.Run(h);
  });
  std::erase_if(ran_cert_error_content_, [&](const std::string& h) {
    return host_filter.Run(h);
  });
  std::erase_if(http_allowed_hosts_, [&](const std::string& h) {
    return host_filter.Run(h);
  });
}

content::SSLHostStateDelegate::CertJudgment
OWLSSLHostStateDelegate::QueryPolicy(
    const std::string& host,
    const net::X509Certificate& cert,
    int error,
    content::StoragePartition* /*storage_partition*/) {
  AllowKey key{host, CertFingerprint(cert), error};
  if (allowed_certs_.count(key) > 0) {
    return ALLOWED;
  }
  return DENIED;
}

void OWLSSLHostStateDelegate::HostRanInsecureContent(
    const std::string& host,
    InsecureContentType content_type) {
  switch (content_type) {
    case MIXED_CONTENT:
      ran_mixed_content_.insert(host);
      break;
    case CERT_ERRORS_CONTENT:
      ran_cert_error_content_.insert(host);
      break;
  }
}

bool OWLSSLHostStateDelegate::DidHostRunInsecureContent(
    const std::string& host,
    InsecureContentType content_type) {
  switch (content_type) {
    case MIXED_CONTENT:
      return ran_mixed_content_.count(host) > 0;
    case CERT_ERRORS_CONTENT:
      return ran_cert_error_content_.count(host) > 0;
  }
  return false;
}

void OWLSSLHostStateDelegate::AllowHttpForHost(
    const std::string& host,
    content::StoragePartition* /*storage_partition*/) {
  http_allowed_hosts_.insert(host);
}

bool OWLSSLHostStateDelegate::IsHttpAllowedForHost(
    const std::string& host,
    content::StoragePartition* /*storage_partition*/) {
  return http_allowed_hosts_.count(host) > 0;
}

void OWLSSLHostStateDelegate::RevokeUserAllowExceptions(
    const std::string& host) {
  std::erase_if(allowed_certs_, [&](const AllowKey& key) {
    return key.host == host;
  });
  http_allowed_hosts_.erase(host);
}

void OWLSSLHostStateDelegate::SetHttpsEnforcementForHost(
    const std::string& /*host*/,
    bool /*enforce*/,
    content::StoragePartition* /*storage_partition*/) {
  // OWL does not enforce HTTPS-First Mode — no-op.
}

bool OWLSSLHostStateDelegate::IsHttpsEnforcedForUrl(
    const GURL& /*url*/,
    content::StoragePartition* /*storage_partition*/) {
  return false;
}

bool OWLSSLHostStateDelegate::HasAllowException(
    const std::string& host,
    content::StoragePartition* /*storage_partition*/) {
  // Check if any entry matches this host.
  for (const auto& key : allowed_certs_) {
    if (key.host == host) return true;
  }
  return http_allowed_hosts_.count(host) > 0;
}

bool OWLSSLHostStateDelegate::HasAllowExceptionForAnyHost(
    content::StoragePartition* /*storage_partition*/) {
  return !allowed_certs_.empty() || !http_allowed_hosts_.empty();
}

}  // namespace owl
