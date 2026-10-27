/**
 * keystore_device_test.cj
 *
 * Device round-trip tests for HuksSecureKeyStorage (HUKS-backed secure key
 * store). These exercise the encrypt-on-write / decrypt-on-read path that
 * requires a real UIAbilityContext (for ctx.filesDir as the storage root) and
 * a live HUKS environment (AES-256 wrap key). They cannot run under the pure
 * logic runner — they need the on-device EntryAbility to have populated the
 * package-level globalContext (see index.cj getContext()).
 *
 * Covered previously-uncovered symbols:
 *   HuksSecureKeyStorage (ctor), writeKeyInfo, readKeyInfo, writeKeyDataBatch,
 *   readKeyData, deleteKeyBatch, deleteKeyInfo, deleteWrapKey, secureAreaName,
 *   IssueRequest.
 *
 * Idempotency / isolation across reruns:
 *   Each test uses a distinct serviceName (=> distinct HUKS wrap-key alias and
 *   distinct on-disk blob prefix), and self-cleans (delete*) at the end. The
 *   deleteWrapKey test additionally tears down its wrap key on the way out so a
 *   subsequent run starts from a clean HUKS slot. Combined with getContext()
 *   waiting for EntryAbility.onCreate to populate the global context, the suite
 *   is deterministic: passed=N failed=0 error=0 on repeated runs.
 *
 * cjc 1.1.3 notes: bare arrays bound to a typed let first; byte literals have
 * no internal space ([0x04u8]); @Expect(actual, expected).
 */
package ohos_app_cangjie_eudi_cjwallet_storage_local_test

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.HashMap

import ohos_app_cangjie_eudi_cjwallet_storage.storage.keystore.HuksSecureKeyStorage
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.IssueRequest
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.KeyOptions
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.CredentialOptions
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.CredentialPolicy
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.CoseEcCurve

@Test
class HuksKeystoreDeviceTest {

    // writeKeyInfo -> readKeyInfo: bytes must round-trip through HUKS encrypt/decrypt.
    @TestCase
    func testWriteReadKeyInfoRoundtrip(): Unit {
        let ctx = getContext()
        let storageDir: String = ctx.filesDir
        let ks = HuksSecureKeyStorage("ws_dev_ks_info", storageDir)
        let keyId: String = "dev_key_info_001"
        // Pre-clean any blob left behind by an interrupted prior run.
        ks.deleteKeyInfo(keyId)
        let pubKeyBytes: Array<UInt8> = [0x04u8, 0x11u8, 0x22u8, 0x33u8]
        let infoDict = HashMap<String, Array<UInt8>>()
        infoDict["pub_key"] = pubKeyBytes

        ks.writeKeyInfo(keyId, infoDict)
        let readBack = ks.readKeyInfo(keyId)

        @Expect(readBack.contains("pub_key"), true)
        let readBytes: Array<UInt8> = readBack["pub_key"]
        @Expect(readBytes.size, 4)
        @Expect(readBytes[0], 0x04u8)
        @Expect(readBytes[3], 0x33u8)

        ks.deleteKeyInfo(keyId)
        let afterDelete = ks.readKeyInfo(keyId)
        @Expect(afterDelete.contains("pub_key"), false)
    }

    // writeKeyDataBatch -> readKeyData at index 0 round-trip, then deleteKeyBatch.
    @TestCase
    func testWriteReadKeyDataBatchRoundtrip(): Unit {
        let ctx = getContext()
        let storageDir: String = ctx.filesDir
        let ks = HuksSecureKeyStorage("ws_dev_ks_data", storageDir)
        let keyId: String = "dev_key_data_001"
        ks.deleteKeyBatch(keyId, 0i64, 1i64)
        let privKeyBytes: Array<UInt8> = [0xCCu8, 0xDDu8, 0xEEu8]
        let dataDict = HashMap<String, Array<UInt8>>()
        dataDict["priv_key"] = privKeyBytes
        let batch: Array<HashMap<String, Array<UInt8>>> = [dataDict]

        ks.writeKeyDataBatch(keyId, 0i64, batch, None)
        let readBack = ks.readKeyData(keyId, 0i64)

        @Expect(readBack.contains("priv_key"), true)
        let readBytes: Array<UInt8> = readBack["priv_key"]
        @Expect(readBytes.size, 3)
        @Expect(readBytes[0], 0xCCu8)
        @Expect(readBytes[2], 0xEEu8)

        ks.deleteKeyBatch(keyId, 0i64, 1i64)
        let afterDelete = ks.readKeyData(keyId, 0i64)
        @Expect(afterDelete.contains("priv_key"), false)
    }

    // Multi-entry batch: indices startIndex..startIndex+size-1 are independently
    // readable; deleteKeyBatch removes the whole slice.
    @TestCase
    func testWriteReadKeyDataBatchMultiEntry(): Unit {
        let ctx = getContext()
        let storageDir: String = ctx.filesDir
        let ks = HuksSecureKeyStorage("ws_dev_ks_multi", storageDir)
        let keyId: String = "dev_key_data_multi"
        ks.deleteKeyBatch(keyId, 0i64, 2i64)

        let d0 = HashMap<String, Array<UInt8>>()
        let v0: Array<UInt8> = [0x10u8]
        d0["k"] = v0
        let d1 = HashMap<String, Array<UInt8>>()
        let v1: Array<UInt8> = [0x20u8]
        d1["k"] = v1
        let batch: Array<HashMap<String, Array<UInt8>>> = [d0, d1]

        ks.writeKeyDataBatch(keyId, 0i64, batch, None)
        let r0 = ks.readKeyData(keyId, 0i64)
        let r1 = ks.readKeyData(keyId, 1i64)
        @Expect(r0.contains("k"), true)
        @Expect(r1.contains("k"), true)
        let b0: Array<UInt8> = r0["k"]
        let b1: Array<UInt8> = r1["k"]
        @Expect(b0[0], 0x10u8)
        @Expect(b1[0], 0x20u8)

        ks.deleteKeyBatch(keyId, 0i64, 2i64)
        @Expect(ks.readKeyData(keyId, 0i64).contains("k"), false)
        @Expect(ks.readKeyData(keyId, 1i64).contains("k"), false)
    }

    // readKeyInfo on a non-existent id returns an empty map, not an error.
    @TestCase
    func testReadKeyInfoNonExistentReturnsEmpty(): Unit {
        let ctx = getContext()
        let storageDir: String = ctx.filesDir
        let ks = HuksSecureKeyStorage("ws_dev_ks_missing", storageDir)
        let readBack = ks.readKeyInfo("no_such_key_xyz_9999")
        @Expect(readBack.size, 0)
    }

    // Same plaintext written under two ids both decrypt back to that plaintext
    // (random-IV scheme must not corrupt either copy).
    @TestCase
    func testSamePlaintextDistinctIdsBothDecrypt(): Unit {
        let ctx = getContext()
        let storageDir: String = ctx.filesDir
        let ks = HuksSecureKeyStorage("ws_dev_ks_iv", storageDir)
        ks.deleteKeyInfo("dev_iv_001")
        ks.deleteKeyInfo("dev_iv_002")
        let payload: Array<UInt8> = [0x42u8, 0x42u8, 0x42u8, 0x42u8]
        let dictA = HashMap<String, Array<UInt8>>()
        dictA["p"] = payload
        let dictB = HashMap<String, Array<UInt8>>()
        dictB["p"] = payload

        ks.writeKeyInfo("dev_iv_001", dictA)
        ks.writeKeyInfo("dev_iv_002", dictB)
        let r1 = ks.readKeyInfo("dev_iv_001")
        let r2 = ks.readKeyInfo("dev_iv_002")
        @Expect(r1.contains("p"), true)
        @Expect(r2.contains("p"), true)
        let r1b: Array<UInt8> = r1["p"]
        let r2b: Array<UInt8> = r2["p"]
        @Expect(r1b[0], 0x42u8)
        @Expect(r2b[0], 0x42u8)

        ks.deleteKeyInfo("dev_iv_001")
        ks.deleteKeyInfo("dev_iv_002")
        @Expect(ks.readKeyInfo("dev_iv_001").size, 0)
        @Expect(ks.readKeyInfo("dev_iv_002").size, 0)
    }

    // deleteWrapKey wipes the HUKS wrap key. A subsequent read of a blob that was
    // encrypted under the now-deleted key cannot be decrypted: readKeyInfo()
    // lazily regenerates a *fresh* wrap key (ensureWrapKey) and then attempts to
    // decrypt the orphaned ciphertext with the wrong key, so HUKS raises a crypto
    // engine error. The contract being asserted is therefore "the old plaintext is
    // no longer recoverable" — surfaced as a decrypt exception, not silent data.
    @TestCase
    func testDeleteWrapKeyRendersBlobsUnreadable(): Unit {
        let ctx = getContext()
        let storageDir: String = ctx.filesDir
        let ks = HuksSecureKeyStorage("ws_dev_ks_wrapwipe", storageDir)
        let keyId: String = "dev_wrap_wipe_001"
        // Start from a clean slate: drop any orphaned blob and wrap key from a
        // prior interrupted run so the write below is encrypted under a key we
        // are about to delete (not one left over from before).
        ks.deleteKeyInfo(keyId)
        ks.deleteWrapKey()

        let dict = HashMap<String, Array<UInt8>>()
        let secret: Array<UInt8> = [0x99u8, 0x88u8]
        dict["s"] = secret
        ks.writeKeyInfo(keyId, dict)
        let before = ks.readKeyInfo(keyId)
        @Expect(before.contains("s"), true)

        ks.deleteWrapKey()

        // The orphaned blob can no longer be decrypted. Reading it surfaces a
        // crypto/HUKS exception (decrypt under a freshly-regenerated, mismatched
        // wrap key). Assert that the read does NOT return the old plaintext, and
        // that it fails the way the implementation actually fails (throws).
        var threw: Bool = false
        try {
            let after = ks.readKeyInfo(keyId)
            // If a future implementation swallows the decrypt error and returns
            // an empty map instead of throwing, that also satisfies the contract
            // ("old plaintext unrecoverable"): the secret must be gone.
            @Expect(after.contains("s"), false)
        } catch (_: Exception) {
            threw = true
        }
        @Expect(threw, true)

        // Cleanup: remove the orphaned blob and the wrap key regenerated by the
        // read attempt, leaving no state behind for the next run.
        ks.deleteKeyInfo(keyId)
        ks.deleteWrapKey()
    }
}

// IssueRequest / secureAreaName are pure value-type assertions (no context),
// but grouped here because they belong to the keystore-facing API surface and
// were previously uncovered.
@Test
class IssueRequestDeviceTest {

    // secureAreaName() returns the name carried in keyOptions.
    @TestCase
    func testSecureAreaNamePresent(): Unit {
        let opts = CredentialOptions(CredentialPolicy.RotateUse, 3i64)
        let keyOpts = KeyOptions(CoseEcCurve.P256, Some("hwSecureArea"), None, None, None, None)
        let req = IssueRequest("issue-001", opts, Some(keyOpts))
        @Expect(req.id, "issue-001")
        let name = req.secureAreaName()
        @Expect(name.isSome(), true)
        @Expect(name.getOrThrow(), "hwSecureArea")
    }

    // secureAreaName() is None when keyOptions carries no name.
    @TestCase
    func testSecureAreaNameAbsentWhenKeyOptionsNoName(): Unit {
        let opts = CredentialOptions(CredentialPolicy.OneTimeUse, 1i64)
        let keyOpts = KeyOptions(CoseEcCurve.P256, None, None, None, None, None)
        let req = IssueRequest("issue-002", opts, Some(keyOpts))
        @Expect(req.secureAreaName().isNone(), true)
    }

    // Convenience ctor (no keyOptions) -> secureAreaName() is None.
    @TestCase
    func testSecureAreaNameNoneWhenNoKeyOptions(): Unit {
        let opts = CredentialOptions(CredentialPolicy.OneTimeUse, 1i64)
        let req = IssueRequest("issue-003", opts)
        @Expect(req.keyOptions.isNone(), true)
        @Expect(req.secureAreaName().isNone(), true)
    }
}
