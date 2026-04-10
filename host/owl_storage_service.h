// Copyright 2026 AntlerAI. All rights reserved.
#ifndef THIRD_PARTY_OWL_HOST_OWL_STORAGE_SERVICE_H_
#define THIRD_PARTY_OWL_HOST_OWL_STORAGE_SERVICE_H_

#include <string>
#include <unordered_map>
#include <vector>

#include "base/sequence_checker.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "third_party/owl/mojom/storage.mojom.h"

namespace owl {

// Implements owl.mojom.StorageService for cookie and storage management.
// In production, this wraps content::StoragePartition; in tests, it operates
// with in-memory data for deterministic verification.
//
// All methods run on the UI thread.
class OWLStorageService : public owl::mojom::StorageService {
 public:
  // Memory-only mode (for tests and off-the-record).
  OWLStorageService();
  ~OWLStorageService() override;

  OWLStorageService(const OWLStorageService&) = delete;
  OWLStorageService& operator=(const OWLStorageService&) = delete;

  // Bind a single receiver (convenience, delegates to AddReceiver).
  void Bind(mojo::PendingReceiver<owl::mojom::StorageService> receiver);

  // Add a new pipe endpoint (multiple clients supported via ReceiverSet).
  void AddReceiver(mojo::PendingReceiver<owl::mojom::StorageService> receiver);

  // owl::mojom::StorageService:
  void GetCookieDomains(GetCookieDomainsCallback callback) override;
  void DeleteCookiesForDomain(const std::string& domain,
                              DeleteCookiesForDomainCallback callback) override;
  void ClearBrowsingData(uint32_t data_types,
                         double start_time,
                         double end_time,
                         ClearBrowsingDataCallback callback) override;
  void GetStorageUsage(GetStorageUsageCallback callback) override;

  // --- Test helpers ---
  // Add a cookie for testing (domain -> count incremented).
  void AddCookieForTesting(const std::string& domain);

  // Add storage usage entry for testing.
  void AddStorageUsageForTesting(const std::string& origin,
                                 int64_t usage_bytes);

  // Valid data_types mask (OR of all known bits).
  static constexpr uint32_t kAllDataTypes = 0x1F;  // 0x01|0x02|0x04|0x08|0x10

 private:
  // In-memory cookie store: domain -> cookie_count.
  std::unordered_map<std::string, int32_t> cookies_;

  // In-memory storage usage: origin -> usage_bytes.
  std::unordered_map<std::string, int64_t> storage_usage_;

  mojo::ReceiverSet<owl::mojom::StorageService> receivers_;

  SEQUENCE_CHECKER(sequence_checker_);
};

}  // namespace owl
#endif  // THIRD_PARTY_OWL_HOST_OWL_STORAGE_SERVICE_H_
