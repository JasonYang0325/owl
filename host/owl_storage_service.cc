// Copyright 2026 AntlerAI. All rights reserved.
#include "third_party/owl/host/owl_storage_service.h"

#include <algorithm>

namespace owl {

OWLStorageService::OWLStorageService() = default;
OWLStorageService::~OWLStorageService() = default;

void OWLStorageService::Bind(
    mojo::PendingReceiver<owl::mojom::StorageService> receiver) {
  AddReceiver(std::move(receiver));
}

void OWLStorageService::AddReceiver(
    mojo::PendingReceiver<owl::mojom::StorageService> receiver) {
  receivers_.Add(this, std::move(receiver));
}

void OWLStorageService::GetCookieDomains(GetCookieDomainsCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::vector<owl::mojom::CookieDomainPtr> domains;
  domains.reserve(cookies_.size());
  for (const auto& [domain, count] : cookies_) {
    auto entry = owl::mojom::CookieDomain::New();
    entry->domain = domain;
    entry->cookie_count = count;
    domains.push_back(std::move(entry));
  }
  // Sort by domain for deterministic output.
  std::sort(domains.begin(), domains.end(),
            [](const auto& a, const auto& b) {
              return a->domain < b->domain;
            });
  std::move(callback).Run(std::move(domains));
}

void OWLStorageService::DeleteCookiesForDomain(
    const std::string& domain,
    DeleteCookiesForDomainCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = cookies_.find(domain);
  if (it == cookies_.end()) {
    std::move(callback).Run(0);
    return;
  }
  int32_t count = it->second;
  cookies_.erase(it);
  std::move(callback).Run(count);
}

void OWLStorageService::ClearBrowsingData(uint32_t data_types,
                                          double start_time,
                                          double end_time,
                                          ClearBrowsingDataCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);

  // Reject if any unknown bits are set.
  if (data_types & ~kAllDataTypes) {
    std::move(callback).Run(false);
    return;
  }

  // Reject if no data types requested.
  if (data_types == 0) {
    std::move(callback).Run(false);
    return;
  }

  // kDataTypeCookies = 0x01
  if (data_types & 0x01) {
    cookies_.clear();
  }

  // kDataTypeCache = 0x02 — no-op in memory mode.
  // kDataTypeLocalStorage = 0x04 — clears storage_usage_ as approximation.
  if (data_types & 0x04) {
    storage_usage_.clear();
  }

  // kDataTypeSessionStorage = 0x08 — no-op in memory mode.
  // kDataTypeIndexedDB = 0x10 — no-op in memory mode.

  std::move(callback).Run(true);
}

void OWLStorageService::GetStorageUsage(GetStorageUsageCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::vector<owl::mojom::StorageUsageEntryPtr> usage;
  usage.reserve(storage_usage_.size());
  for (const auto& [origin, bytes] : storage_usage_) {
    auto entry = owl::mojom::StorageUsageEntry::New();
    entry->origin = origin;
    entry->usage_bytes = bytes;
    usage.push_back(std::move(entry));
  }
  std::sort(usage.begin(), usage.end(),
            [](const auto& a, const auto& b) {
              return a->origin < b->origin;
            });
  std::move(callback).Run(std::move(usage));
}

void OWLStorageService::AddCookieForTesting(const std::string& domain) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  cookies_[domain]++;
}

void OWLStorageService::AddStorageUsageForTesting(const std::string& origin,
                                                  int64_t usage_bytes) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  storage_usage_[origin] = usage_bytes;
}

}  // namespace owl
