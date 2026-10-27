/**
 * storage_types_test.cj
 *
 * Unit tests for the storage-layer enumerations and error type
 * (eudi_cjwallet_storage.storage.types):
 *   - DocumentStatus rawValue / fromRaw / isDeferred
 *   - SavedKeyChainDataType rawValue / fromRaw (4-char keychain raw values)
 *   - StorageError fields (description, code) and Exception.message plumbing
 *
 * Pure value-type logic; no UIAbilityContext required, so these run on-device.
 */
package ohos_app_cangjie_eudi_cjwallet_storage_local_test

import std.unittest.*
import std.unittest.testmacro.*

import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.DocumentStatus
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.SavedKeyChainDataType
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.StorageError

@Test
class DocumentStatusTest {

    @TestCase
    func testRawValue(): Unit {
        @Expect(DocumentStatus.Issued.rawValue(), "issued")
        @Expect(DocumentStatus.Deferred.rawValue(), "deferred")
        @Expect(DocumentStatus.Pending.rawValue(), "pending")
    }

    @TestCase
    func testFromRawKnown(): Unit {
        match (DocumentStatus.fromRaw("issued")) {
            case Some(s) => @Expect(s.rawValue(), "issued")
            case None => @Expect(false)
        }
        match (DocumentStatus.fromRaw("deferred")) {
            case Some(s) => @Expect(s.rawValue(), "deferred")
            case None => @Expect(false)
        }
        match (DocumentStatus.fromRaw("pending")) {
            case Some(s) => @Expect(s.rawValue(), "pending")
            case None => @Expect(false)
        }
    }

    @TestCase
    func testFromRawUnknown(): Unit {
        @Expect(DocumentStatus.fromRaw("revoked").isNone())
        @Expect(DocumentStatus.fromRaw("").isNone())
    }

    @TestCase
    func testIsDeferred(): Unit {
        @Expect(DocumentStatus.Deferred.isDeferred(), true)
        @Expect(DocumentStatus.Issued.isDeferred(), false)
        @Expect(DocumentStatus.Pending.isDeferred(), false)
    }

    @TestCase
    func testRoundTrip(): Unit {
        for (s in [DocumentStatus.Issued, DocumentStatus.Deferred, DocumentStatus.Pending]) {
            match (DocumentStatus.fromRaw(s.rawValue())) {
                case Some(r) => @Expect(r.rawValue(), s.rawValue())
                case None => @Expect(false)
            }
        }
    }
}

@Test
class SavedKeyChainDataTypeTest {

    @TestCase
    func testRawValuesAreFourChars(): Unit {
        @Expect(SavedKeyChainDataType.Doc.rawValue(), "sdoc")
        @Expect(SavedKeyChainDataType.DocPresent.rawValue(), "pdoc")
        @Expect(SavedKeyChainDataType.Key.rawValue(), "skey")
        @Expect(SavedKeyChainDataType.KeyInfo.rawValue(), "skei")
        // iOS parity requires 4-char raw values
        @Expect(SavedKeyChainDataType.Doc.rawValue().size, 4)
        @Expect(SavedKeyChainDataType.KeyInfo.rawValue().size, 4)
    }

    @TestCase
    func testFromRawKnown(): Unit {
        match (SavedKeyChainDataType.fromRaw("sdoc")) {
            case Some(t) => @Expect(t.rawValue(), "sdoc")
            case None => @Expect(false)
        }
        match (SavedKeyChainDataType.fromRaw("skei")) {
            case Some(t) => @Expect(t.rawValue(), "skei")
            case None => @Expect(false)
        }
    }

    @TestCase
    func testFromRawUnknown(): Unit {
        @Expect(SavedKeyChainDataType.fromRaw("xxxx").isNone())
        @Expect(SavedKeyChainDataType.fromRaw("doc").isNone())
    }

    @TestCase
    func testRoundTrip(): Unit {
        let all = [
            SavedKeyChainDataType.Doc,
            SavedKeyChainDataType.DocPresent,
            SavedKeyChainDataType.Key,
            SavedKeyChainDataType.KeyInfo
        ]
        for (t in all) {
            match (SavedKeyChainDataType.fromRaw(t.rawValue())) {
                case Some(r) => @Expect(r.rawValue(), t.rawValue())
                case None => @Expect(false)
            }
        }
    }
}

@Test
class StorageErrorTest {

    @TestCase
    func testFullConstructor(): Unit {
        let err = StorageError("disk full", 42)
        @Expect(err.description, "disk full")
        @Expect(err.code, 42)
        // message inherited from Exception, set via super(description)
        @Expect(err.message, "disk full")
    }

    @TestCase
    func testConvenienceConstructorDefaultsCodeZero(): Unit {
        let err = StorageError("not found")
        @Expect(err.description, "not found")
        @Expect(err.code, 0)
        @Expect(err.message, "not found")
    }

    @TestCase
    func testIsThrowableException(): Unit {
        var caught = false
        var msg = ""
        try {
            throw StorageError("boom", 7)
        } catch (e: StorageError) {
            caught = true
            msg = e.description
            @Expect(e.code, 7)
        }
        @Expect(caught, true)
        @Expect(msg, "boom")
    }

    @TestCase
    func testCatchableAsException(): Unit {
        var caught = false
        try {
            throw StorageError("generic")
        } catch (e: Exception) {
            caught = true
            @Expect(e.message, "generic")
        }
        @Expect(caught, true)
    }
}
