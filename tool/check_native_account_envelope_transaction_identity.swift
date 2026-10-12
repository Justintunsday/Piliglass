import Foundation

private enum TransactionFixtureError: Error { case failed(String), injected }

@main private struct AccountEnvelopeTransactionIdentityChecks {
  /// Patches the actual Dart envelope JSON for negative identity-shape cases.
  /// Re-serialization keeps integer number tokens (all fixture magnitudes stay
  /// inside JSONSerialization's exact integer range).
  private static func patchedEnvelope(
    _ data: Data, _ mutate: (inout [String: Any]) -> Void
  ) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TransactionFixtureError.failed("envelope JSON object expected")
    }
    mutate(&root)
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }

  /// Codex R11 legacy-water matrix: an omitted/null schema-3 high-water plus a
  /// delete of the maximum/last login must persist the pre-transform effective
  /// water, so no historical key/generation can be reused after a reopen.
  /// Deliberately separate from the giant main body: the strict-concurrency
  /// type checker scales badly with one enormous function.
  private static func checkLegacyWaterMatrix(
    codec: PiliAccountLiveMemoryShadowCodec,
    base: PiliAccountLiveMemoryShadow,
    key: PiliCookieUTF16,
    record: PiliAccountLiveMemoryRecord,
    cleared: PiliOrderedCookieArchive
  ) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw TransactionFixtureError.failed(label) }
      checks += 1
    }
    guard let legacySecondKey = base.records[2].storageKeyUnits else {
      throw TransactionFixtureError.failed("missing legacy second key")
    }
    let legacySecondGeneration = base.records[2].generation
    let legacyShapes: [String] = ["omitted", "null"]
    let deleteModes: [String] = ["maximum", "last"]
    for legacyShape in legacyShapes {
      for deleteMode in deleteModes {
        let legacyNamespace = UUID()
        let legacyVault = PiliAccountEnvelopeStagingStore(
          secrets: PiliAccountKeychainSecretStore(stagingNamespace: legacyNamespace))
        let legacyStore = PiliAccountEnvelopeTransactionStore(vault: legacyVault)
        do {
          try await legacyVault.importShadow(codec.encode(base))
          _ = try await legacyStore.adoptMissingIdentities()
          guard let adoptedLegacy = try await legacyVault.loadShadow() else {
            throw TransactionFixtureError.failed("missing legacy adopted shadow")
          }
          let legacyWire = try patchedEnvelope(codec.encode(adoptedLegacy)) { root in
            if legacyShape == "omitted" {
              root.removeValue(forKey: "generationHighWater")
            } else {
              root["generationHighWater"] = NSNull()
            }
          }
          let decodedLegacy = try codec.decode(legacyWire)
          try check(decodedLegacy.generationHighWater == nil &&
            decodedLegacy.effectiveGenerationHighWater ==
              max(record.generation, legacySecondGeneration),
            "legacy \(legacyShape) water decodes as the live derivation")
          try await legacyVault.importShadow(legacyWire)
          let lossyStore = PiliAccountEnvelopeTransactionStore(vault: legacyVault)
          let preDeleteWater = max(record.generation, legacySecondGeneration)
          _ = try await lossyStore.applyDelete(
            recordKeyUnits: key, expectedGeneration: record.generation)
          if deleteMode == "last" {
            _ = try await lossyStore.applyDelete(
              recordKeyUnits: legacySecondKey, expectedGeneration: legacySecondGeneration)
          }
          guard let deletedLegacy = try await legacyVault.loadShadow() else {
            throw TransactionFixtureError.failed("missing legacy deleted shadow")
          }
          try check(deletedLegacy.generationHighWater == preDeleteWater,
                    "legacy \(legacyShape) \(deleteMode) delete persists the pre-transform water")
          let reopenedLegacyVault = PiliAccountEnvelopeStagingStore(
            secrets: PiliAccountKeychainSecretStore(stagingNamespace: legacyNamespace))
          let reopenedLegacyStore = PiliAccountEnvelopeTransactionStore(vault: reopenedLegacyVault)
          guard let reopenedLegacy = try await reopenedLegacyVault.loadShadow() else {
            throw TransactionFixtureError.failed("missing legacy reopened shadow")
          }
          try check(reopenedLegacy.generationHighWater == preDeleteWater,
                    "legacy \(legacyShape) \(deleteMode) water survives reopen")
          guard let beforeLegacyReuse = try await reopenedLegacyVault.loadShadowSnapshot() else {
            throw TransactionFixtureError.failed("missing legacy reuse snapshot")
          }
          do {
            _ = try await reopenedLegacyStore.applyInstall(PiliAccountShadowInstall(
              storageKeyUnits: key, mid: record.mid, generation: record.generation,
              accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [],
              activated: false, jar: cleared))
            throw TransactionFixtureError.failed(
              "legacy \(legacyShape) \(deleteMode) identical generation reuse accepted")
          } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
          let afterLegacyReuse = try await reopenedLegacyVault.loadShadowSnapshot()
          try check(afterLegacyReuse?.transactionID == beforeLegacyReuse.transactionID &&
            afterLegacyReuse?.envelope == beforeLegacyReuse.envelope,
            "legacy \(legacyShape) \(deleteMode) reuse publishes nothing")
          for contextCheck in ["cookie", "credentials"] {
            do {
              if contextCheck == "cookie" {
                _ = try await reopenedLegacyStore.applyCookieDeleteAll(
                  recordKeyUnits: key, expectedGeneration: record.generation)
              } else {
                _ = try await reopenedLegacyStore.applyCredentials(
                  recordKeyUnits: key, expectedGeneration: record.generation,
                  accessKeyUnits: nil, refreshTokenUnits: nil)
              }
              throw TransactionFixtureError.failed(
                "legacy \(legacyShape) \(deleteMode) old \(contextCheck) context accepted")
            } catch PiliAccountShadowTransactionError.unknownRecordKey { checks += 1 }
          }
          _ = try await reopenedLegacyStore.applyInstall(PiliAccountShadowInstall(
            storageKeyUnits: key, mid: record.mid, generation: record.generation + 1,
            accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [],
            activated: false, jar: cleared))
          guard let legitLegacy = try await reopenedLegacyVault.loadShadow() else {
            throw TransactionFixtureError.failed("missing legacy legitimate shadow")
          }
          try check(legitLegacy.generationHighWater == record.generation + 1,
                    "legacy \(legacyShape) \(deleteMode) larger generation persists")
          do {
            _ = try await reopenedLegacyStore.applyCookieDeleteAll(
              recordKeyUnits: key, expectedGeneration: record.generation)
            throw TransactionFixtureError.failed(
              "legacy \(legacyShape) \(deleteMode) old context matched the new identity")
          } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
          do {
            _ = try await reopenedLegacyStore.applyCredentials(
              recordKeyUnits: key, expectedGeneration: record.generation,
              accessKeyUnits: nil, refreshTokenUnits: nil)
            throw TransactionFixtureError.failed(
              "legacy \(legacyShape) \(deleteMode) old credentials matched the new identity")
          } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
          try await reopenedLegacyVault.discardShadow()
        } catch {
          try? await legacyVault.discardShadow()
          throw error
        }
      }
    }
    return checks
  }

  static func main() async throws {
    guard CommandLine.arguments.count == 2 else {
      throw TransactionFixtureError.failed("fresh live actual Dart envelope golden required")
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]],
          let value = cases.first(where: { $0["id"] as? String == "stored-10-2-owner-2-10" })?["envelope"] else {
      throw TransactionFixtureError.failed("actual Dart envelope missing")
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let codec = PiliAccountLiveMemoryShadowCodec()
    let base = try codec.decode(data)
    guard base.records.count == 3 else { throw TransactionFixtureError.failed("expected anonymous + two login records") }
    let record = base.records[1]
    guard let key = record.storageKeyUnits, key.units == Array("10".utf16) else {
      throw TransactionFixtureError.failed("expected raw storage key 10")
    }
    let reducer = PiliNativeOrderedCookieReducer()
    let location = PiliOrderedCookieResponseLocation(host: "api.bilibili.com", path: "/x/test")
    let now: Int64 = 1_700_000_000_123_456
    let fields = ["txn-cookie=txn-value; Path=/; Domain=.bilibili.com"]
    let saved = try reducer.save(record.jar, fields: fields, representation: .separated,
                                 location: location, nowMicroseconds: now)
    let deleted = try reducer.delete(saved, host: "bilibili.com", withDomainSharedCookie: true)
    guard deleted.domainBuckets.isEmpty else {
      throw TransactionFixtureError.failed("actual domain deletion fixture missing")
    }
    let cleared = try reducer.deleteAll(deleted)
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw TransactionFixtureError.failed(label) }
      checks += 1
    }
    // Legacy captures carry no durable identity. Adoption mints one persisted
    // canonical identity per login record, upgrades to schema 3, survives a
    // real Keychain close/reopen and stays stable across existing transactions.
    try check(base.schemaVersion == 2, "the actual Dart golden is a schema-2 envelope")
    try check(base.records.allSatisfy { $0.durableIdentity == nil },
              "legacy records carry no durable identity")
    let identityNamespace = UUID()
    let identityVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: identityNamespace))
    let identityStore = PiliAccountEnvelopeTransactionStore(vault: identityVault)
    do {
      try await identityVault.importShadow(codec.encode(base))
      let adopted = try await identityStore.adoptMissingIdentities()
      try check(adopted.adopted == base.records.count - 1,
                "adoption mints one identity per login record")
      try check(adopted.transactionID != nil, "adoption publishes once")
      try check(adopted.nativeWritesAllowed == false && adopted.authoritySwitchAllowed == false,
                "adoption never grants authority")
      guard let adoptedShadow = try await identityVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing adopted shadow")
      }
      try check(adoptedShadow.schemaVersion == 3, "adoption upgrades to schema 3")
      let identities = adoptedShadow.records.map { $0.durableIdentity }
      try check(identities[0] == nil, "anonymous record keeps no identity")
      let loginIdentities = identities.dropFirst()
      try check(loginIdentities.allSatisfy { $0 != nil },
                "every login record has an identity")
      try check(Set(loginIdentities.compactMap { $0 }).count == loginIdentities.count,
                "identities are unique")
      try check(loginIdentities.allSatisfy {
        $0.map(PiliAccountLiveMemoryShadow.isCanonicalDurableIdentity) == true
      }, "identities are canonical lowercase UUID text")
      let reopenedVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: identityNamespace))
      let reopened = try await reopenedVault.loadShadow()
      try check(reopened?.records.map { $0.durableIdentity } == identities,
                "identities survive real Keychain close/reopen")
      let reopenedStore = PiliAccountEnvelopeTransactionStore(vault: reopenedVault)
      _ = try await reopenedStore.applyActivated(
        recordKeyUnits: key, expectedGeneration: record.generation, activated: true)
      let afterMutation = try await reopenedVault.loadShadow()
      try check(afterMutation?.records[1].durableIdentity == identities[1],
                "existing transactions preserve the record identity")
      guard let beforeSecond = try await reopenedVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing adopted snapshot")
      }
      let secondAdopt = try await reopenedStore.adoptMissingIdentities()
      try check(secondAdopt.adopted == 0 && secondAdopt.transactionID == nil,
                "re-adoption is a no-op")
      let afterSecond = try await reopenedVault.loadShadowSnapshot()
      try check(afterSecond?.transactionID == beforeSecond.transactionID,
                "no-op adoption keeps the pointer identity")
      try await reopenedVault.discardShadow()
    } catch {
      try? await identityVault.discardShadow()
      throw error
    }

    // Identity shape errors fail explicitly and publish nothing. The identity
    // wire shape is a UTF-16 unit array, exactly like storageKeyUnits.
    func identityUnits(_ text: String) -> [Int] {
      Array(text.utf16).map { Int($0) }
    }
    func expectRejectedIdentity(_ label: String, _ expected: PiliAccountLiveMemoryShadowError,
                                _ mutate: @escaping (inout [String: Any]) -> Void) throws {
      let patched = try patchedEnvelope(data, mutate)
      do {
        _ = try codec.decode(patched)
        throw TransactionFixtureError.failed(label)
      } catch let error as PiliAccountLiveMemoryShadowError {
        try check(error == expected, label)
      }
    }
    try expectRejectedIdentity("malformed identity accepted", .invalidEnvelope) { root in
      var records = root["records"] as? [[String: Any]] ?? []
      records[1]["durableIdentity"] = [97, 98, 99]
      root["records"] = records
    }
    try expectRejectedIdentity("oversized identity accepted", .resourceLimit) { root in
      var records = root["records"] as? [[String: Any]] ?? []
      records[1]["durableIdentity"] = Array(repeating: 97, count: 4000)
      // Schema 3 reaches the identity preflight; schema 2 rejects the key shape
      // first, so the budget check needs the modern version.
      root["schemaVersion"] = 3
      root["records"] = records
    }
    try expectRejectedIdentity("anonymous identity accepted", .invalidEnvelope) { root in
      var records = root["records"] as? [[String: Any]] ?? []
      records[0]["durableIdentity"] = identityUnits("00000000-0000-4000-8000-000000000000")
      root["records"] = records
    }
    try expectRejectedIdentity("unknown identity variant accepted", .invalidEnvelope) { root in
      var records = root["records"] as? [[String: Any]] ?? []
      records[1]["durableIdentityx"] = identityUnits("00000000-0000-4000-8000-000000000000")
      root["records"] = records
    }
    try expectRejectedIdentity("duplicate identities accepted under schema 3", .invalidEnvelope) { root in
      var records = root["records"] as? [[String: Any]] ?? []
      records[1]["durableIdentity"] = identityUnits("00000000-0000-4000-8000-000000000000")
      records[2]["durableIdentity"] = identityUnits("00000000-0000-4000-8000-000000000000")
      root["schemaVersion"] = 3
      root["records"] = records
    }
    try expectRejectedIdentity("schema 3 with a missing identity accepted", .invalidEnvelope) { root in
      var records = root["records"] as? [[String: Any]] ?? []
      records[1]["durableIdentity"] = identityUnits("00000000-0000-4000-8000-000000000001")
      root["schemaVersion"] = 3
      root["records"] = records
    }
    try expectRejectedIdentity("schema 2 with an explicit null identity accepted", .invalidEnvelope) { root in
      var records = root["records"] as? [[String: Any]] ?? []
      records[1]["durableIdentity"] = NSNull()
      root["records"] = records
    }

    // Install appends one complete login record to an adopted envelope: next
    // contiguous index, matching stored/owner order, untouched selections,
    // anonymous and existing records, minted canonical identity.
    let installNamespace = UUID()
    let installVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: installNamespace))
    let installStore = PiliAccountEnvelopeTransactionStore(vault: installVault)
    do {
      try await installVault.importShadow(codec.encode(base))
      _ = try await installStore.adoptMissingIdentities()
      guard let adoptedShadow = try await installVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing install adoption shadow")
      }
      let newKey = PiliCookieUTF16(units: Array("install-target".utf16))
      let install = PiliAccountShadowInstall(
        storageKeyUnits: newKey, mid: 424242, generation: record.generation + 1000,
        accessKeyUnits: PiliCookieUTF16(units: Array("install-access".utf16)),
        refreshTokenUnits: nil, persistedPurposes: [.video], activated: true, jar: cleared)
      let receipt = try await installStore.applyInstall(install)
      try check(receipt.record == adoptedShadow.records.count,
                "install appends the next contiguous record")
      try check(receipt.nativeWritesAllowed == false && receipt.authoritySwitchAllowed == false,
                "install never grants authority")
      guard let installed = try await installVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing installed shadow")
      }
      try check(installed.records.count == adoptedShadow.records.count + 1,
                "install adds exactly one record")
      try check(installed.records.map { $0.record } == Array(0..<installed.records.count),
                "install keeps contiguous record numbering")
      let newRecord = installed.records[installed.records.count - 1]
      try check(newRecord.storageKeyUnits == newKey && newRecord.mid == 424242 &&
        newRecord.isLogin, "install stores the exact key and mid")
      try check(newRecord.accessKeyUnits?.units == Array("install-access".utf16) &&
        newRecord.refreshTokenUnits == nil && newRecord.activated &&
        newRecord.persistedPurposes == [.video],
        "install stores credentials, purposes and activation")
      try check(newRecord.jar == cleared, "install stores the exact jar")
      try check(newRecord.durableIdentity.map(PiliAccountLiveMemoryShadow.isCanonicalDurableIdentity) == true,
                "install mints a canonical identity")
      try check(installed.records.dropLast().map { $0.durableIdentity } ==
        adoptedShadow.records.map { $0.durableIdentity },
        "install leaves existing identities untouched")
      try check(installed.records[0] == adoptedShadow.records[0] &&
        installed.records[1] == adoptedShadow.records[1] &&
        installed.records[2] == adoptedShadow.records[2],
        "install leaves anonymous and existing records untouched")
      let expectedOrder = PiliAccountLiveMemoryOrderEntry(
        keyUnits: newKey, record: newRecord.record)
      try check(installed.storedOrder == adoptedShadow.storedOrder + [expectedOrder],
                "install appends the stored order entry")
      try check(installed.ownerOrder == adoptedShadow.ownerOrder + [expectedOrder],
                "install appends the owner order entry")
      try check(installed.selections == adoptedShadow.selections &&
        installed.history == adoptedShadow.history && installed.revision == adoptedShadow.revision,
        "install keeps selections, history and revision")
      let reopenedInstallVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: installNamespace))
      let reopenedInstall = try await reopenedInstallVault.loadShadow()
      try check(reopenedInstall == installed, "installed envelope survives real Keychain close/reopen")
      guard let beforeRejects = try await reopenedInstallVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing install reject snapshot")
      }
      let reopenedInstallStore = PiliAccountEnvelopeTransactionStore(vault: reopenedInstallVault)
      do {
        _ = try await reopenedInstallStore.applyInstall(install)
        throw TransactionFixtureError.failed("duplicate install accepted")
      } catch PiliAccountShadowTransactionError.duplicateRecordKey { checks += 1 }
      let secondKey = PiliCookieUTF16(units: Array("install-target-2".utf16))
      do {
        _ = try await reopenedInstallStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: secondKey, mid: 1, generation: install.generation,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [],
          activated: false, jar: cleared))
        throw TransactionFixtureError.failed("duplicate generation install accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await reopenedInstallStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: []), mid: 1, generation: install.generation + 1,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [],
          activated: false, jar: cleared))
        throw TransactionFixtureError.failed("empty key install accepted")
      } catch PiliAccountShadowTransactionError.invalidInstall { checks += 1 }
      do {
        _ = try await reopenedInstallStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: secondKey, mid: 1, generation: install.generation + 1,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [.main, .main],
          activated: false, jar: cleared))
        throw TransactionFixtureError.failed("duplicate purpose install accepted")
      } catch PiliAccountShadowTransactionError.invalidInstall { checks += 1 }
      do {
        _ = try await reopenedInstallStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: secondKey, mid: 1, generation: install.generation + 1,
          accessKeyUnits: PiliCookieUTF16(units: Array(repeating: 97, count: 65537)),
          refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: cleared))
        throw TransactionFixtureError.failed("oversized install accepted")
      } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
      do {
        _ = try await reopenedInstallStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: secondKey, mid: 1, generation: 0,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [],
          activated: false, jar: cleared))
        throw TransactionFixtureError.failed("zero generation install accepted")
      } catch PiliAccountShadowTransactionError.invalidInstall { checks += 1 }
      let afterRejects = try await reopenedInstallVault.loadShadowSnapshot()
      try check(afterRejects?.transactionID == beforeRejects.transactionID &&
        afterRejects?.envelope == beforeRejects.envelope,
        "install rejections never publish a new candidate")
      try await reopenedInstallVault.discardShadow()
    } catch {
      try? await installVault.discardShadow()
      throw error
    }

    // A schema-2 envelope cannot be installed into directly: adoption is the
    // explicit upgrade gate, so nothing changes shape silently.
    let legacyInstallNamespace = UUID()
    let legacyInstallVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: legacyInstallNamespace))
    let legacyInstallStore = PiliAccountEnvelopeTransactionStore(vault: legacyInstallVault)
    do {
      try await legacyInstallVault.importShadow(codec.encode(base))
      guard let legacyBefore = try await legacyInstallVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing legacy install snapshot")
      }
      do {
        _ = try await legacyInstallStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: Array("legacy-install".utf16)),
          mid: 1, generation: record.generation + 2000, accessKeyUnits: nil,
          refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: cleared))
        throw TransactionFixtureError.failed("schema-2 install accepted")
      } catch PiliAccountShadowTransactionError.invalidInstall { checks += 1 }
      let legacyAfter = try await legacyInstallVault.loadShadowSnapshot()
      try check(legacyAfter?.transactionID == legacyBefore.transactionID &&
        legacyAfter?.envelope == legacyBefore.envelope,
        "schema-2 install never publishes")
      try await legacyInstallVault.discardShadow()
    } catch {
      try? await legacyInstallVault.discardShadow()
      throw error
    }

    // Delete + reinstall ABA: the reinstall gets a new generation, so an old
    // request holding the original key+generation is rejected. The deleted
    // generation itself must also be refused (historical reuse).
    let abaNamespace = UUID()
    let abaVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: abaNamespace))
    let abaStore = PiliAccountEnvelopeTransactionStore(vault: abaVault)
    do {
      try await abaVault.importShadow(codec.encode(base))
      _ = try await abaStore.adoptMissingIdentities()
      _ = try await abaStore.applyDelete(recordKeyUnits: key, expectedGeneration: record.generation)
      // Historical reuse: the deleted record's own generation is below the
      // persisted high-water and must be rejected, not merely a +9000 choice.
      guard let beforeAbaReuse = try await abaVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing ABA reuse snapshot")
      }
      do {
        _ = try await abaStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: key, mid: record.mid, generation: record.generation,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
          jar: cleared))
        throw TransactionFixtureError.failed("historical generation reuse after delete accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      let afterAbaReuse = try await abaVault.loadShadowSnapshot()
      try check(afterAbaReuse?.transactionID == beforeAbaReuse.transactionID &&
        afterAbaReuse?.envelope == beforeAbaReuse.envelope,
        "historical generation reuse never publishes")
      guard let adoptedAba = try await abaVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing adopted ABA shadow")
      }
      let abaHighWater = adoptedAba.effectiveGenerationHighWater
      _ = try await abaStore.applyInstall(PiliAccountShadowInstall(
        storageKeyUnits: key, mid: record.mid, generation: abaHighWater + 9000,
        accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
        jar: cleared))
      do {
        _ = try await abaStore.applyCookieDeleteAll(
          recordKeyUnits: key, expectedGeneration: record.generation)
        throw TransactionFixtureError.failed("ABA old generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await abaStore.applyCredentials(recordKeyUnits: key,
          expectedGeneration: record.generation, accessKeyUnits: nil, refreshTokenUnits: nil)
        throw TransactionFixtureError.failed("ABA old credentials generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      // The high-water survives a real Keychain reopen: neither the removed
      // generation nor an intermediate one can seed a new record.
      let reopenedAbaVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: abaNamespace))
      let reopenedAbaStore = PiliAccountEnvelopeTransactionStore(vault: reopenedAbaVault)
      guard let reopenedAba = try await reopenedAbaVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing reopened ABA shadow")
      }
      try check(reopenedAba.generationHighWater == abaHighWater + 9000,
                "generation high-water persists across reopen")
      for reuse in [record.generation, abaHighWater + 5000] {
        do {
          _ = try await reopenedAbaStore.applyInstall(PiliAccountShadowInstall(
            storageKeyUnits: PiliCookieUTF16(units: Array("aba-reuse".utf16)), mid: 2,
            generation: reuse, accessKeyUnits: nil, refreshTokenUnits: nil,
            persistedPurposes: [], activated: false, jar: cleared))
          throw TransactionFixtureError.failed("historical generation reuse after reopen accepted")
        } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      }
      // Overflow boundary: Int64.max is accepted once and permanently closes
      // further allocation (no wraparound).
      _ = try await reopenedAbaStore.applyInstall(PiliAccountShadowInstall(
        storageKeyUnits: PiliCookieUTF16(units: Array("aba-max".utf16)), mid: 3,
        generation: Int64.max, accessKeyUnits: nil, refreshTokenUnits: nil,
        persistedPurposes: [], activated: false, jar: cleared))
      do {
        _ = try await reopenedAbaStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: Array("aba-past-max".utf16)), mid: 4,
          generation: Int64.max, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [], activated: false, jar: cleared))
        throw TransactionFixtureError.failed("generation allocation past Int64.max accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      try await reopenedAbaVault.discardShadow()
    } catch {
      try? await abaVault.discardShadow()
      throw error
    }

    // Legacy schema-3 envelopes without the persisted high-water fall back to
    // the maximum record generation; the next install persists the value.
    let compatNamespace = UUID()
    let compatVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: compatNamespace))
    let compatStore = PiliAccountEnvelopeTransactionStore(vault: compatVault)
    do {
      try await compatVault.importShadow(codec.encode(base))
      _ = try await compatStore.adoptMissingIdentities()
      guard let adoptedCompat = try await compatVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing compat adopted shadow")
      }
      let patchedWire = try patchedEnvelope(codec.encode(adoptedCompat)) { root in
        root.removeValue(forKey: "generationHighWater")
      }
      let decodedCompat = try codec.decode(patchedWire)
      try check(decodedCompat.generationHighWater == nil &&
        decodedCompat.effectiveGenerationHighWater == adoptedCompat.effectiveGenerationHighWater,
        "legacy schema-3 fallback derives the effective high-water")
      let compatMax = adoptedCompat.effectiveGenerationHighWater
      let compatReopenVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: compatNamespace))
      try await compatReopenVault.importShadow(patchedWire)
      let compatReopenStore = PiliAccountEnvelopeTransactionStore(vault: compatReopenVault)
      do {
        _ = try await compatReopenStore.applyInstall(PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: Array("compat-reuse".utf16)), mid: 5,
          generation: compatMax, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [], activated: false, jar: cleared))
        throw TransactionFixtureError.failed("legacy schema-3 effective reuse accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      _ = try await compatReopenStore.applyInstall(PiliAccountShadowInstall(
        storageKeyUnits: PiliCookieUTF16(units: Array("compat-new".utf16)), mid: 6,
        generation: compatMax + 1, accessKeyUnits: nil, refreshTokenUnits: nil,
        persistedPurposes: [], activated: false, jar: cleared))
      guard let compatPersisted = try await compatReopenVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing compat persisted shadow")
      }
      try check(compatPersisted.generationHighWater == compatMax + 1,
                "next install persists the monotonic high-water")
      try await compatReopenVault.discardShadow()
    } catch {
      try? await compatVault.discardShadow()
      throw error
    }

    checks += try await Self.checkLegacyWaterMatrix(
      codec: codec, base: base, key: key, record: record, cleared: cleared)

    // Import G1→G2→G1: a replaced generation cannot be re-imported, including
    // after a real Keychain reopen.
    let reuseNamespace = UUID()
    let reuseVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: reuseNamespace))
    let reuseStore = PiliAccountEnvelopeTransactionStore(vault: reuseVault)
    do {
      guard let reuseKey = base.records[2].storageKeyUnits else {
        throw TransactionFixtureError.failed("missing reuse key")
      }
      try await reuseVault.importShadow(codec.encode(base))
      _ = try await reuseStore.adoptMissingIdentities()
      let firstGen = record.generation + 20000
      _ = try await reuseStore.applyImport([PiliAccountShadowInstall(
        storageKeyUnits: reuseKey, mid: 7, generation: firstGen,
        accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
        jar: cleared)])
      _ = try await reuseStore.applyImport([PiliAccountShadowInstall(
        storageKeyUnits: reuseKey, mid: 8, generation: firstGen + 1,
        accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
        jar: cleared)])
      guard let beforeReuseImport = try await reuseVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing reuse import snapshot")
      }
      do {
        _ = try await reuseStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: reuseKey, mid: 9, generation: firstGen,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
          jar: cleared)])
        throw TransactionFixtureError.failed("G1→G2→G1 import reuse accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      let afterReuseImport = try await reuseVault.loadShadowSnapshot()
      try check(afterReuseImport?.transactionID == beforeReuseImport.transactionID &&
        afterReuseImport?.envelope == beforeReuseImport.envelope,
        "G1→G2→G1 import reuse never publishes")
      let reopenedReuseVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: reuseNamespace))
      let reopenedReuseStore = PiliAccountEnvelopeTransactionStore(vault: reopenedReuseVault)
      do {
        _ = try await reopenedReuseStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: reuseKey, mid: 9, generation: firstGen,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
          jar: cleared)])
        throw TransactionFixtureError.failed("G1 reuse accepted after reopen")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      try await reopenedReuseVault.discardShadow()
    } catch {
      try? await reuseVault.discardShadow()
      throw error
    }

    // Delete renumbers remaining records, remaps both orders and every slot
    // with the Dart policy, derives history again and preserves identities.
    let deleteNamespace = UUID()
    let deleteVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: deleteNamespace))
    let deleteStore = PiliAccountEnvelopeTransactionStore(vault: deleteVault)
    do {
      guard let secondKey = base.records[2].storageKeyUnits else {
        throw TransactionFixtureError.failed("missing second key")
      }
      let secondGeneration = base.records[2].generation
      try await deleteVault.importShadow(codec.encode(base))
      _ = try await deleteStore.adoptMissingIdentities()
      guard let adoptedDelete = try await deleteVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing delete adoption shadow")
      }
      _ = try await deleteStore.applyTemporarySelection(
        recordKeyUnits: key, expectedGeneration: record.generation, purpose: .heartbeat)
      _ = try await deleteStore.applyPurposeChange(
        recordKeyUnits: secondKey, expectedGeneration: secondGeneration,
        purpose: .recommend, previousKeyUnits: nil, previousExpectedGeneration: nil)
      guard let beforeDelete = try await deleteVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing delete fixture shadow")
      }
      try check(beforeDelete.selections == [0, 1, 2, 0] && beforeDelete.history == 1,
                "delete fixture has a heartbeat slot and a recommend slot")
      let secondIdentity = beforeDelete.records[2].durableIdentity
      let deleteReceipt = try await deleteStore.applyDelete(
        recordKeyUnits: key, expectedGeneration: record.generation)
      try check(deleteReceipt.record == 1 && deleteReceipt.nativeWritesAllowed == false &&
        deleteReceipt.authoritySwitchAllowed == false,
        "delete targets the exact record and never grants authority")
      guard let afterDelete = try await deleteVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing deleted shadow")
      }
      try check(afterDelete.records.count == 2 && afterDelete.records.map { $0.record } == [0, 1],
                "delete renumbers remaining records contiguously")
      try check(afterDelete.records[1].storageKeyUnits == secondKey &&
        afterDelete.records[1].durableIdentity == secondIdentity,
        "delete preserves the remaining record and its identity")
      let expectedOrder = PiliAccountLiveMemoryOrderEntry(keyUnits: secondKey, record: 1)
      try check(afterDelete.storedOrder == [expectedOrder] &&
        afterDelete.ownerOrder == [expectedOrder],
        "delete removes and renumbers both orders")
      try check(afterDelete.selections == [0, 0, 1, 0],
                "delete sends the deleted slot to anonymous and shifts later slots")
      try check(afterDelete.history == 0, "delete derives history from the remapped slots")
      do {
        _ = try await deleteStore.applyDelete(
          recordKeyUnits: secondKey, expectedGeneration: secondGeneration + 1)
        throw TransactionFixtureError.failed("stale delete generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await deleteStore.applyDelete(
          recordKeyUnits: key, expectedGeneration: record.generation)
        throw TransactionFixtureError.failed("unknown delete key accepted")
      } catch PiliAccountShadowTransactionError.unknownRecordKey { checks += 1 }
      let lastReceipt = try await deleteStore.applyDelete(
        recordKeyUnits: secondKey, expectedGeneration: secondGeneration)
      try check(lastReceipt.record == 1, "delete of the last login record targets its exact index")
      guard let anonymousOnly = try await deleteVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing anonymous-only shadow")
      }
      try check(anonymousOnly.records.count == 1 && anonymousOnly.records[0].durableIdentity == nil &&
        anonymousOnly.storedOrder.isEmpty && anonymousOnly.ownerOrder.isEmpty &&
        anonymousOnly.selections == [0, 0, 0, 0] && anonymousOnly.history == 0,
        "deleting every login record leaves a valid anonymous-only envelope")
      let reopenedDeleteVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: deleteNamespace))
      try check(try await reopenedDeleteVault.loadShadow() == anonymousOnly,
                "deleted envelope survives real Keychain close/reopen")
      guard let beforeDeleteRejects = try await reopenedDeleteVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing delete reject snapshot")
      }
      let reopenedDeleteStore = PiliAccountEnvelopeTransactionStore(vault: reopenedDeleteVault)
      do {
        _ = try await reopenedDeleteStore.applyDelete(
          recordKeyUnits: secondKey, expectedGeneration: secondGeneration)
        throw TransactionFixtureError.failed("unknown delete key accepted")
      } catch PiliAccountShadowTransactionError.unknownRecordKey { checks += 1 }
      do {
        _ = try await reopenedDeleteStore.applyDelete(
          recordKeyUnits: PiliCookieUTF16(units: Array("anonymous".utf16)),
          expectedGeneration: 1)
        throw TransactionFixtureError.failed("anonymous delete accepted")
      } catch PiliAccountShadowTransactionError.unknownRecordKey { checks += 1 }
      let afterDeleteRejects = try await reopenedDeleteVault.loadShadowSnapshot()
      try check(afterDeleteRejects?.transactionID == beforeDeleteRejects.transactionID &&
        afterDeleteRejects?.envelope == beforeDeleteRejects.envelope,
        "delete rejections never publish")
      try await reopenedDeleteVault.discardShadow()
    } catch {
      try? await deleteVault.discardShadow()
      throw error
    }

    // Import replaces exact existing keys in place (identity preserved) and
    // appends new keys with minted identities in input order.
    let importNamespace = UUID()
    let importVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: importNamespace))
    let importStore = PiliAccountEnvelopeTransactionStore(vault: importVault)
    do {
      try await importVault.importShadow(codec.encode(base))
      _ = try await importStore.adoptMissingIdentities()
      _ = try await importStore.applyTemporarySelection(
        recordKeyUnits: key, expectedGeneration: record.generation, purpose: .heartbeat)
      guard let adoptedImport = try await importVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing import adoption shadow")
      }
      let newKey = PiliCookieUTF16(units: Array("import-new".utf16))
      let replacement = PiliAccountShadowInstall(
        storageKeyUnits: key, mid: 777, generation: record.generation + 5000,
        accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [.main],
        activated: false, jar: cleared)
      let fresh = PiliAccountShadowInstall(
        storageKeyUnits: newKey, mid: 888, generation: record.generation + 5001,
        accessKeyUnits: PiliCookieUTF16(units: Array("import-access".utf16)),
        refreshTokenUnits: nil, persistedPurposes: [.video], activated: true, jar: cleared)
      let importReceipt = try await importStore.applyImport([replacement, fresh])
      try check(importReceipt.replaced == 1 && importReceipt.appended == 1 &&
        importReceipt.nativeWritesAllowed == false &&
        importReceipt.authoritySwitchAllowed == false,
        "import reports replaced/appended and never grants authority")
      guard let imported = try await importVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing imported shadow")
      }
      try check(imported.records.count == adoptedImport.records.count + 1, "import adds only new keys")
      try check(imported.records[1].generation == record.generation + 5000 &&
        imported.records[1].mid == 777 && imported.records[1].persistedPurposes == [.main] &&
        imported.records[1].activated == false && imported.records[1].jar == cleared,
        "import replaces the exact record in place")
      try check(imported.records[1].durableIdentity == adoptedImport.records[1].durableIdentity,
                "import preserves the replaced record identity")
      let appendedRecord = imported.records[imported.records.count - 1]
      try check(appendedRecord.storageKeyUnits == newKey && appendedRecord.mid == 888 &&
        appendedRecord.persistedPurposes == [.video] && appendedRecord.activated &&
        appendedRecord.accessKeyUnits?.units == Array("import-access".utf16),
        "import appends the new record with its fields")
      try check(appendedRecord.durableIdentity.map(PiliAccountLiveMemoryShadow.isCanonicalDurableIdentity) == true,
                "appended import record has a canonical identity")
      let expectedImportOrder = PiliAccountLiveMemoryOrderEntry(
        keyUnits: newKey, record: appendedRecord.record)
      try check(imported.storedOrder == adoptedImport.storedOrder + [expectedImportOrder],
                "import appends the new key to the stored order")
      let replacedOrder = PiliAccountLiveMemoryOrderEntry(keyUnits: key, record: 1)
      let remainingOwners = adoptedImport.ownerOrder.filter { $0.keyUnits != key }
      try check(imported.ownerOrder == remainingOwners + [replacedOrder, expectedImportOrder],
                "import re-inserts the replaced owner after the remaining registry")
      try check(adoptedImport.selections[1] == 1 &&
        adoptedImport.history == 1,
        "import fixture holds a temporary heartbeat selection")
      var expectedSelections = [0, 0, 0, 0]
      for orderEntry in imported.ownerOrder {
        for purpose in imported.records[orderEntry.record].persistedPurposes {
          switch purpose {
          case .main: expectedSelections[0] = orderEntry.record
          case .heartbeat: expectedSelections[1] = orderEntry.record
          case .recommend: expectedSelections[2] = orderEntry.record
          case .video: expectedSelections[3] = orderEntry.record
          }
        }
      }
      try check(imported.selections == expectedSelections,
                "import rebuilds every slot from owner order and purposes")
      try check(imported.selections[0] == 1 &&
        imported.selections[3] == appendedRecord.record,
        "replaced and appended owners own their rebuilt slots")
      let importedHeartbeat = imported.selections[1]
      try check(imported.history ==
        (imported.records[importedHeartbeat].isLogin ? importedHeartbeat : imported.selections[0]),
        "import derives history from the rebuilt slots")
      try check(imported.revision == adoptedImport.revision,
                "import keeps the capture-local revision")
      try check(imported.records[2] == adoptedImport.records[2],
                "import leaves untouched records unchanged")
      let reopenedImportVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: importNamespace))
      try check(try await reopenedImportVault.loadShadow() == imported,
                "imported envelope survives real Keychain close/reopen")
      let reopenedImportStore = PiliAccountEnvelopeTransactionStore(vault: reopenedImportVault)
      // The replaced key must use a genuinely new generation: old requests for
      // the original key+generation are rejected.
      do {
        _ = try await reopenedImportStore.applyCookieDeleteAll(
          recordKeyUnits: key, expectedGeneration: record.generation)
        throw TransactionFixtureError.failed("old generation write accepted after import")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await reopenedImportStore.applyCredentials(recordKeyUnits: key,
          expectedGeneration: record.generation, accessKeyUnits: nil, refreshTokenUnits: nil)
        throw TransactionFixtureError.failed("old generation credentials accepted after import")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      let newGenerationReceipt = try await reopenedImportStore.applyCookieDeleteAll(
        recordKeyUnits: key, expectedGeneration: record.generation + 5000)
      try check(newGenerationReceipt.record == 1,
                "replacement generation accepts new writes")
      guard let beforeImportRejects = try await reopenedImportVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing import reject snapshot")
      }
      let duplicateKeyEntries = [fresh, fresh]
      do {
        _ = try await reopenedImportStore.applyImport(duplicateKeyEntries)
        throw TransactionFixtureError.failed("duplicate import key accepted")
      } catch PiliAccountShadowTransactionError.duplicateRecordKey { checks += 1 }
      do {
        _ = try await reopenedImportStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: key, mid: 1, generation: record.generation + 5000,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [],
          activated: false, jar: cleared)])
        throw TransactionFixtureError.failed("replaced generation reuse accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await reopenedImportStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: []), mid: 1,
          generation: record.generation + 6000, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [], activated: false, jar: cleared)])
        throw TransactionFixtureError.failed("empty import key accepted")
      } catch PiliAccountShadowTransactionError.invalidImport { checks += 1 }
      do {
        _ = try await reopenedImportStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: Array("import-bad".utf16)), mid: 1,
          generation: record.generation + 6001, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [.main, .main], activated: false, jar: cleared)])
        throw TransactionFixtureError.failed("duplicate import purpose accepted")
      } catch PiliAccountShadowTransactionError.invalidImport { checks += 1 }
      do {
        _ = try await reopenedImportStore.applyImport([
          PiliAccountShadowInstall(storageKeyUnits: PiliCookieUTF16(units: Array("import-a".utf16)),
            mid: 1, generation: record.generation + 6002, accessKeyUnits: nil,
            refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: cleared),
          PiliAccountShadowInstall(storageKeyUnits: PiliCookieUTF16(units: Array("import-b".utf16)),
            mid: 2, generation: record.generation + 6002, accessKeyUnits: nil,
            refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: cleared)])
        throw TransactionFixtureError.failed("duplicate import generations accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await reopenedImportStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: Array("import-c".utf16)), mid: 1,
          generation: base.records[2].generation, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [], activated: false, jar: cleared)])
        throw TransactionFixtureError.failed("generation collision with untouched record accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await reopenedImportStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: Array("import-d".utf16)), mid: 1,
          generation: record.generation + 6004,
          accessKeyUnits: PiliCookieUTF16(units: Array(repeating: 97, count: 65537)),
          refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: cleared)])
        throw TransactionFixtureError.failed("oversized import accepted")
      } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
      // The cb00312 key-first ordering classifies generation <= 0 as
      // staleGeneration on import (install keeps invalidInstall); pinned so the
      // documented classification cannot drift silently.
      do {
        _ = try await reopenedImportStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: Array("import-zero".utf16)), mid: 1,
          generation: 0, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [], activated: false, jar: cleared)])
        throw TransactionFixtureError.failed("zero import generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await reopenedImportStore.applyImport([PiliAccountShadowInstall(
          storageKeyUnits: PiliCookieUTF16(units: Array("import-negative".utf16)), mid: 1,
          generation: -1, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [], activated: false, jar: cleared)])
        throw TransactionFixtureError.failed("negative import generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      let afterImportRejects = try await reopenedImportVault.loadShadowSnapshot()
      try check(afterImportRejects?.transactionID == beforeImportRejects.transactionID &&
        afterImportRejects?.envelope == beforeImportRejects.envelope,
        "import rejections never publish")
      try await reopenedImportVault.discardShadow()
    } catch {
      try? await importVault.discardShadow()
      throw error
    }

    // A schema-2 envelope cannot be deleted from or imported into directly.
    for (label, legacyError) in [("delete", PiliAccountShadowTransactionError.invalidDelete),
                                 ("import", .invalidImport)] {
      let legacyNamespace = UUID()
      let legacyVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: legacyNamespace))
      let legacyStore = PiliAccountEnvelopeTransactionStore(vault: legacyVault)
      do {
        try await legacyVault.importShadow(codec.encode(base))
        guard let legacyBefore = try await legacyVault.loadShadowSnapshot() else {
          throw TransactionFixtureError.failed("missing legacy \(label) snapshot")
        }
        do {
          if label == "delete" {
            _ = try await legacyStore.applyDelete(recordKeyUnits: key,
              expectedGeneration: record.generation)
          } else {
            _ = try await legacyStore.applyImport([PiliAccountShadowInstall(
              storageKeyUnits: key, mid: 1, generation: record.generation + 7000,
              accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [],
              activated: false, jar: cleared)])
          }
          throw TransactionFixtureError.failed("schema-2 \(label) accepted")
        } catch let error as PiliAccountShadowTransactionError {
          try check(error == legacyError, "schema-2 \(label) is rejected before publishing")
        }
        let legacyAfter = try await legacyVault.loadShadowSnapshot()
        try check(legacyAfter?.transactionID == legacyBefore.transactionID &&
          legacyAfter?.envelope == legacyBefore.envelope,
          "schema-2 \(label) never publishes")
        try await legacyVault.discardShadow()
      } catch {
        try? await legacyVault.discardShadow()
        throw error
      }
    }

    // Buvid seed mirrors Dart `??=`: only a missing buvid3 is appended, an
    // existing one is an idempotent no-op, and rejections publish nothing.
    let buvidNamespace = UUID()
    let buvidVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: buvidNamespace))
    let buvidStore = PiliAccountEnvelopeTransactionStore(vault: buvidVault)
    do {
      try await buvidVault.importShadow(codec.encode(base))
      _ = try await buvidStore.adoptMissingIdentities()
      // The capture jars already carry constructor-seeded buvid3 cookies, so
      // strip the record first to exercise the missing-value path.
      _ = try await buvidStore.applyCookieDeleteAll(
        recordKeyUnits: key, expectedGeneration: record.generation)
      guard let stripped = try await buvidVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing stripped buvid shadow")
      }
      try check(stripped.records[1].jar.domainBuckets.isEmpty &&
        stripped.records[1].jar.hostBuckets.isEmpty,
        "buvid fixture record is stripped")
      // The API length ceiling fails intentionally (resourceLimit) before any
      // field construction; over-long values never reach the parser.
      guard let beforeBuvidBudget = try await buvidVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing buvid budget snapshot")
      }
      do {
        _ = try await buvidStore.applyBuvidSeed(
          recordKeyUnits: key, expectedGeneration: record.generation,
          valueUnits: PiliCookieUTF16(units: Array(repeating: 0x61, count: 70000)),
          nowMicroseconds: now)
        throw TransactionFixtureError.failed("oversized buvid value accepted")
      } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
      do {
        _ = try await buvidStore.applyBuvidSeed(
          recordKeyUnits: key, expectedGeneration: record.generation,
          valueUnits: PiliCookieUTF16(units: Array(
            repeating: 0x61, count: PiliAccountEnvelopeTransactionStore.buvidMaximumValueUnits + 1)),
          nowMicroseconds: now)
        throw TransactionFixtureError.failed("buvid value one unit over the ceiling accepted")
      } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
      let afterBuvidBudget = try await buvidVault.loadShadowSnapshot()
      try check(afterBuvidBudget?.transactionID == beforeBuvidBudget.transactionID &&
        afterBuvidBudget?.envelope == beforeBuvidBudget.envelope,
        "length-ceiling buvid rejections never publish")
      // A valid ordinary value whose addition exceeds a shrunk encoded-byte
      // budget is rejected by the shared codec ledger with resourceLimit.
      guard let beforeBuvidTight = try await buvidVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing tight buvid snapshot")
      }
      let strippedBytes = try codec.encode(stripped).count
      var tightBuvidLimits = PiliOrderedCookieArchiveLimits.standard
      tightBuvidLimits.maximumEncodedBytes = strippedBytes
      let tightBuvidStore = PiliAccountEnvelopeTransactionStore(
        vault: buvidVault, limits: tightBuvidLimits)
      do {
        _ = try await tightBuvidStore.applyBuvidSeed(
          recordKeyUnits: key, expectedGeneration: record.generation,
          valueUnits: PiliCookieUTF16(
            units: Array("11111111-2222-4333-8444-55555555555512345infoc".utf16)),
          nowMicroseconds: now)
        throw TransactionFixtureError.failed("buvid beyond the byte budget accepted")
      } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
      let afterBuvidTight = try await buvidVault.loadShadowSnapshot()
      try check(afterBuvidTight?.transactionID == beforeBuvidTight.transactionID &&
        afterBuvidTight?.envelope == beforeBuvidTight.envelope,
        "byte-budget buvid rejection publishes nothing")
      let buvidValue = PiliCookieUTF16(
        units: Array("11111111-2222-4333-8444-55555555555512345infoc".utf16))
      let seedReceipt = try await buvidStore.applyBuvidSeed(
        recordKeyUnits: key, expectedGeneration: record.generation,
        valueUnits: buvidValue, nowMicroseconds: now)
      try check(seedReceipt.seeded && seedReceipt.transactionID != nil &&
        seedReceipt.nativeWritesAllowed == false &&
        seedReceipt.authoritySwitchAllowed == false,
        "buvid seed publishes once and never grants authority")
      guard let seeded = try await buvidVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing seeded buvid shadow")
      }
      let domainKey = PiliCookieUTF16(units: Array("bilibili.com".utf16))
      let pathKey = PiliCookieUTF16(units: Array("/".utf16))
      let nameKey = PiliCookieUTF16(units: Array("buvid3".utf16))
      guard let bucket = seeded.records[1].jar.domainBuckets.first(where: {
        $0.keyUnits == domainKey
      }), let path = bucket.paths.first(where: { $0.keyUnits == pathKey }),
        let entry = path.cookies.first(where: { $0.keyUnits == nameKey }) else {
        throw TransactionFixtureError.failed("seeded buvid3 missing")
      }
      try check(entry.valueUnits == buvidValue, "buvid seed stores the exact value")
      try check(path.cookies.count == 1 && path.cookies.last?.keyUnits == nameKey,
                "buvid seed appends exactly one entry")
      try check(seeded.records[1].durableIdentity == stripped.records[1].durableIdentity &&
        seeded.records[1].storageKeyUnits == stripped.records[1].storageKeyUnits,
        "buvid seed keeps the record identity")
      try check(seeded.records[0] == stripped.records[0] &&
        seeded.records[2] == stripped.records[2],
        "buvid seed leaves other records unchanged")
      try check(seeded.storedOrder == stripped.storedOrder &&
        seeded.ownerOrder == stripped.ownerOrder &&
        seeded.selections == stripped.selections &&
        seeded.history == stripped.history &&
        seeded.revision == stripped.revision,
        "buvid seed keeps orders, slots and revision")
      let reopenedBuvidVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: buvidNamespace))
      try check(try await reopenedBuvidVault.loadShadow() == seeded,
                "seeded buvid survives real Keychain close/reopen")
      guard let beforeSecondSeed = try await reopenedBuvidVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing second buvid snapshot")
      }
      let reopenedBuvidStore = PiliAccountEnvelopeTransactionStore(vault: reopenedBuvidVault)
      let secondSeed = try await reopenedBuvidStore.applyBuvidSeed(
        recordKeyUnits: key, expectedGeneration: record.generation,
        valueUnits: PiliCookieUTF16(units: Array("other-buvid-value".utf16)),
        nowMicroseconds: now + 1)
      try check(!secondSeed.seeded && secondSeed.transactionID == nil,
                "existing buvid3 is an idempotent no-op")
      let afterSecondSeed = try await reopenedBuvidVault.loadShadowSnapshot()
      try check(afterSecondSeed?.transactionID == beforeSecondSeed.transactionID &&
        afterSecondSeed?.envelope == beforeSecondSeed.envelope,
        "idempotent buvid seed publishes nothing")
      do {
        _ = try await reopenedBuvidStore.applyBuvidSeed(
          recordKeyUnits: PiliCookieUTF16(units: Array("missing".utf16)),
          expectedGeneration: record.generation, valueUnits: buvidValue,
          nowMicroseconds: now)
        throw TransactionFixtureError.failed("unknown buvid key accepted")
      } catch PiliAccountShadowTransactionError.unknownRecordKey { checks += 1 }
      do {
        _ = try await reopenedBuvidStore.applyBuvidSeed(
          recordKeyUnits: key, expectedGeneration: record.generation + 1,
          valueUnits: buvidValue, nowMicroseconds: now)
        throw TransactionFixtureError.failed("stale buvid generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await reopenedBuvidStore.applyBuvidSeed(
          recordKeyUnits: key, expectedGeneration: record.generation,
          valueUnits: PiliCookieUTF16(units: []), nowMicroseconds: now)
        throw TransactionFixtureError.failed("empty buvid value accepted")
      } catch PiliAccountShadowTransactionError.invalidBuvid { checks += 1 }
      do {
        _ = try await reopenedBuvidStore.applyBuvidSeed(
          recordKeyUnits: key, expectedGeneration: record.generation,
          valueUnits: PiliCookieUTF16(units: [0x4E2D]), nowMicroseconds: now)
        throw TransactionFixtureError.failed("non-ASCII buvid value accepted")
      } catch PiliAccountShadowTransactionError.invalidBuvid { checks += 1 }
      do {
        _ = try await reopenedBuvidStore.applyBuvidSeed(
          recordKeyUnits: key, expectedGeneration: record.generation,
          valueUnits: PiliCookieUTF16(units: [0x61, 0x3B, 0x62]), nowMicroseconds: now)
        throw TransactionFixtureError.failed("separator buvid value accepted")
      } catch PiliAccountShadowTransactionError.invalidBuvid { checks += 1 }
      let afterBuvidRejects = try await reopenedBuvidVault.loadShadowSnapshot()
      try check(afterBuvidRejects?.transactionID == beforeSecondSeed.transactionID &&
        afterBuvidRejects?.envelope == beforeSecondSeed.envelope,
        "buvid rejections never publish")
      try await reopenedBuvidVault.discardShadow()
    } catch {
      try? await buvidVault.discardShadow()
      throw error
    }

    // Exactly the documented ceiling is accepted; a one-unit-larger value is
    // rejected with zero publication (already covered) — this proves the
    // boundary itself is usable.
    let capNamespace = UUID()
    let capVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: capNamespace))
    let capStore = PiliAccountEnvelopeTransactionStore(vault: capVault)
    do {
      try await capVault.importShadow(codec.encode(base))
      _ = try await capStore.adoptMissingIdentities()
      _ = try await capStore.applyCookieDeleteAll(
        recordKeyUnits: key, expectedGeneration: record.generation)
      let capValue = PiliCookieUTF16(units: Array(
        repeating: 0x61, count: PiliAccountEnvelopeTransactionStore.buvidMaximumValueUnits))
      let capReceipt = try await capStore.applyBuvidSeed(
        recordKeyUnits: key, expectedGeneration: record.generation,
        valueUnits: capValue, nowMicroseconds: now)
      try check(capReceipt.seeded, "the documented buvid ceiling itself is accepted")
      let reopenedCapVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: capNamespace))
      guard let capShadow = try await reopenedCapVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing cap shadow")
      }
      let capDomain = PiliCookieUTF16(units: Array("bilibili.com".utf16))
      let capPath = PiliCookieUTF16(units: Array("/".utf16))
      let capName = PiliCookieUTF16(units: Array("buvid3".utf16))
      try check(capShadow.records[1].jar.domainBuckets
        .first(where: { $0.keyUnits == capDomain })?
        .paths.first(where: { $0.keyUnits == capPath })?
        .cookies.first(where: { $0.keyUnits == capName })?
        .valueUnits == capValue,
        "ceiling value survives real Keychain close/reopen")
      try await reopenedCapVault.discardShadow()
    } catch {
      try? await capVault.discardShadow()
      throw error
    }

    // Non-empty sibling cookies keep their order; a `buvid3` Cookie.name under
    // a different map key does not satisfy presence; an expired buvid3 is
    // still a map-key no-op.
    let jarOrderNamespace = UUID()
    let jarOrderVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: jarOrderNamespace))
    let jarOrderStore = PiliAccountEnvelopeTransactionStore(vault: jarOrderVault)
    do {
      func units(_ text: String) -> PiliCookieUTF16 {
        PiliCookieUTF16(units: Array(text.utf16))
      }
      try await jarOrderVault.importShadow(codec.encode(base))
      _ = try await jarOrderStore.adoptMissingIdentities()
      let orderKey = units("buvid-order")
      // Hand-built non-empty jar without buvid3: the golden jars already carry
      // the constructor-seeded buvid3, which would make the seed a no-op.
      let siblingEntry = PiliOrderedCookieEntry(
        keyUnits: units("sibling-cookie"), nameUnits: units("sibling-cookie"),
        valueUnits: units("sibling-value"), cookieDomainUnits: units(".bilibili.com"),
        cookiePathUnits: units("/"), secure: false, httpOnly: false, sameSite: nil,
        expiresMicroseconds: nil, maxAgeSeconds: nil, createdSeconds: 1)
      let siblingJar = PiliOrderedCookieArchive(
        schemaVersion: 2, ignoreExpires: true,
        provenance: PiliOrderedCookieProvenance(
          capture: "live", priorPersistence: .unknown,
          legacyHiveAttributesIncomplete: true, currentBucketOrderComplete: true),
        domainBuckets: [PiliOrderedCookieBucket(keyUnits: units("bilibili.com"),
          paths: [PiliOrderedCookiePath(keyUnits: units("/"), cookies: [siblingEntry])])],
        hostBuckets: [])
      _ = try await jarOrderStore.applyInstall(PiliAccountShadowInstall(
        storageKeyUnits: orderKey, mid: 999, generation: record.generation + 12000,
        accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
        jar: siblingJar))
      let orderSeed = try await jarOrderStore.applyBuvidSeed(
        recordKeyUnits: orderKey, expectedGeneration: record.generation + 12000,
        valueUnits: units("order-seed-value"), nowMicroseconds: now)
      try check(orderSeed.seeded, "seed into a non-empty sibling jar publishes")
      guard let orderShadow = try await jarOrderVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing jar order shadow")
      }
      guard let orderBucket = orderShadow.records[3].jar.domainBuckets.first(where: {
        $0.keyUnits == units("bilibili.com")
      }), let orderPath = orderBucket.paths.first(where: { $0.keyUnits == units("/") }) else {
        throw TransactionFixtureError.failed("missing jar order bucket")
      }
      try check(orderPath.cookies.count == 2 &&
        orderPath.cookies[0].keyUnits == units("sibling-cookie") &&
        orderPath.cookies[1].keyUnits == units("buvid3") &&
        orderPath.cookies[0].valueUnits == units("sibling-value"),
        "buvid appends after existing sibling cookies without reordering them")

      // A different map key whose Cookie.name is buvid3 must not satisfy the
      // map-key presence check.
      let aliasEntry = PiliOrderedCookieEntry(
        keyUnits: units("buvid3-alias"), nameUnits: units("buvid3"),
        valueUnits: units("aliased"), cookieDomainUnits: units(".bilibili.com"),
        cookiePathUnits: units("/"), secure: false, httpOnly: false, sameSite: nil,
        expiresMicroseconds: nil, maxAgeSeconds: nil, createdSeconds: 1)
      let aliasJar = PiliOrderedCookieArchive(
        schemaVersion: 2, ignoreExpires: true,
        provenance: PiliOrderedCookieProvenance(
          capture: "live", priorPersistence: .unknown,
          legacyHiveAttributesIncomplete: true, currentBucketOrderComplete: true),
        domainBuckets: [PiliOrderedCookieBucket(keyUnits: units("bilibili.com"),
          paths: [PiliOrderedCookiePath(keyUnits: units("/"), cookies: [aliasEntry])])],
        hostBuckets: [])
      let aliasKey = units("buvid-alias")
      _ = try await jarOrderStore.applyInstall(PiliAccountShadowInstall(
        storageKeyUnits: aliasKey, mid: 1000, generation: record.generation + 13000,
        accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
        jar: aliasJar))
      let aliasSeed = try await jarOrderStore.applyBuvidSeed(
        recordKeyUnits: aliasKey, expectedGeneration: record.generation + 13000,
        valueUnits: units("alias-seed-value"), nowMicroseconds: now)
      try check(aliasSeed.seeded,
                "a buvid3 Cookie.name under another map key does not satisfy presence")
      guard let aliasShadow = try await jarOrderVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing alias shadow")
      }
      guard let aliasPath = aliasShadow.records[4].jar.domainBuckets.first(where: {
        $0.keyUnits == units("bilibili.com")
      })?.paths.first(where: { $0.keyUnits == units("/") }) else {
        throw TransactionFixtureError.failed("missing alias path")
      }
      try check(aliasPath.cookies.count == 2 &&
        aliasPath.cookies[0].keyUnits == units("buvid3-alias") &&
        aliasPath.cookies[1].keyUnits == units("buvid3"),
        "alias entry is kept and the real map key is appended")
      let aliasSecond = try await jarOrderStore.applyBuvidSeed(
        recordKeyUnits: aliasKey, expectedGeneration: record.generation + 13000,
        valueUnits: units("alias-second"), nowMicroseconds: now + 1)
      try check(!aliasSecond.seeded, "the appended map key makes the second seed a no-op")

      // An expired buvid3 map key is still a no-op: presence follows the map
      // key, not the expiry.
      let expiredEntry = PiliOrderedCookieEntry(
        keyUnits: units("buvid3"), nameUnits: units("buvid3"),
        valueUnits: units("expired"), cookieDomainUnits: units(".bilibili.com"),
        cookiePathUnits: units("/"), secure: false, httpOnly: false, sameSite: nil,
        expiresMicroseconds: 1, maxAgeSeconds: nil, createdSeconds: 1)
      let expiredJar = PiliOrderedCookieArchive(
        schemaVersion: 2, ignoreExpires: true,
        provenance: PiliOrderedCookieProvenance(
          capture: "live", priorPersistence: .unknown,
          legacyHiveAttributesIncomplete: true, currentBucketOrderComplete: true),
        domainBuckets: [PiliOrderedCookieBucket(keyUnits: units("bilibili.com"),
          paths: [PiliOrderedCookiePath(keyUnits: units("/"), cookies: [expiredEntry])])],
        hostBuckets: [])
      let expiredKey = units("buvid-expired")
      _ = try await jarOrderStore.applyInstall(PiliAccountShadowInstall(
        storageKeyUnits: expiredKey, mid: 1001, generation: record.generation + 14000,
        accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [], activated: false,
        jar: expiredJar))
      guard let beforeExpiredSeed = try await jarOrderVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing expired seed snapshot")
      }
      let expiredReceipt = try await jarOrderStore.applyBuvidSeed(
        recordKeyUnits: expiredKey, expectedGeneration: record.generation + 14000,
        valueUnits: units("expired-seed"), nowMicroseconds: now)
      try check(!expiredReceipt.seeded && expiredReceipt.transactionID == nil,
                "an expired existing buvid3 is still a map-key no-op")
      let afterExpiredSeed = try await jarOrderVault.loadShadowSnapshot()
      try check(afterExpiredSeed?.transactionID == beforeExpiredSeed.transactionID &&
        afterExpiredSeed?.envelope == beforeExpiredSeed.envelope,
        "expired-buvid no-op publishes nothing")
      try await jarOrderVault.discardShadow()
    } catch {
      try? await jarOrderVault.discardShadow()
      throw error
    }

    // A schema-2 envelope cannot seed buvid directly.
    let legacyBuvidNamespace = UUID()
    let legacyBuvidVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: legacyBuvidNamespace))
    let legacyBuvidStore = PiliAccountEnvelopeTransactionStore(vault: legacyBuvidVault)
    do {
      try await legacyBuvidVault.importShadow(codec.encode(base))
      guard let legacyBuvidBefore = try await legacyBuvidVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing legacy buvid snapshot")
      }
      do {
        _ = try await legacyBuvidStore.applyBuvidSeed(recordKeyUnits: key,
          expectedGeneration: record.generation,
          valueUnits: PiliCookieUTF16(units: Array("legacy-buvid".utf16)),
          nowMicroseconds: now)
        throw TransactionFixtureError.failed("schema-2 buvid seed accepted")
      } catch PiliAccountShadowTransactionError.invalidBuvid { checks += 1 }
      let legacyBuvidAfter = try await legacyBuvidVault.loadShadowSnapshot()
      try check(legacyBuvidAfter?.transactionID == legacyBuvidBefore.transactionID &&
        legacyBuvidAfter?.envelope == legacyBuvidBefore.envelope,
        "schema-2 buvid seed never publishes")
      try await legacyBuvidVault.discardShadow()
    } catch {
      try? await legacyBuvidVault.discardShadow()
      throw error
    }

    print("\(checks) native account envelope identity transaction checks passed")
  }
}
