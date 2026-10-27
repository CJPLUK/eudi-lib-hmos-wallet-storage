/**
 * docstore_device_test.cj
 *
 * Device round-trip tests for RdbStorageService (encrypted RDB document store,
 * which implements the DataStorageService interface). These require a real
 * UIAbilityContext (RdbStorageService(context, dbName) opens an encrypted
 * RelationalStore under the app sandbox) and therefore cannot run under the
 * pure logic runner. They exercise the full CRUD path:
 *   saveDocument -> loadDocument / loadDocumentMetadata / loadDocuments
 *                -> deleteDocument / deleteDocuments / deleteDocumentCredential.
 *
 * Covered previously-uncovered symbols:
 *   RdbStorageService (ctor + DataStorageService impl), saveDocument,
 *   loadDocument, loadDocumentMetadata, loadDocuments, deleteDocument,
 *   deleteDocuments, deleteDocumentCredential.
 *
 * Each test self-cleans so the suite is idempotent.
 *
 * cjc 1.1.3 notes: bare arrays bound to typed let first; byte literals no
 * internal space; .isSome()/.isNone() for Option; @Expect(actual, expected).
 */
package ohos_app_cangjie_eudi_cjwallet_storage_local_test

import std.unittest.*
import std.unittest.testmacro.*

import ohos_app_cangjie_eudi_cjwallet_storage.storage.docstore.RdbStorageService
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.Document
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.DocDataFormat
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.DocumentStatus

@Test
class RdbDocstoreDeviceTest {

    // saveDocument -> loadDocument: byte-level + field consistency.
    @TestCase
    func testSaveAndLoadDocumentByteLevelConsistency(): Unit {
        let ctx = getContext()
        let svc = RdbStorageService(ctx, "ws_dev_crud.db")
        let demoData: Array<UInt8> = [0x01u8, 0x02u8, 0x03u8, 0x04u8, 0x05u8]
        let doc = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            demoData,
            None,
            None,
            Some("Dev Licence"),
            DocumentStatus.Issued
        )
        let docId = doc.id

        svc.saveDocument(doc, None, true)
        let loaded = svc.loadDocument(docId, DocumentStatus.Issued)
        @Expect(loaded.isSome(), true)
        let loadedDoc = loaded.getOrThrow()
        @Expect(loadedDoc.id, docId)
        @Expect(loadedDoc.data.size, 5)
        @Expect(loadedDoc.data[0], 0x01u8)
        @Expect(loadedDoc.data[4], 0x05u8)
        @Expect(loadedDoc.docType, "org.iso.18013.5.1.mDL")
        @Expect(loadedDoc.status.rawValue(), "issued")

        svc.deleteDocument(docId, DocumentStatus.Issued)
        @Expect(svc.loadDocument(docId, DocumentStatus.Issued).isNone(), true)
    }

    // loadDocuments(status): bulk load returns the saved doc among results.
    @TestCase
    func testLoadDocumentsByStatusContainsSaved(): Unit {
        let ctx = getContext()
        let svc = RdbStorageService(ctx, "ws_dev_list.db")
        let data: Array<UInt8> = [0xAAu8, 0xBBu8]
        let doc = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            data,
            None,
            None,
            Some("List Doc"),
            DocumentStatus.Issued
        )
        svc.saveDocument(doc, None, true)

        let issuedList = svc.loadDocuments(DocumentStatus.Issued)
        @Expect(issuedList.isSome(), true)
        let arr = issuedList.getOrThrow()
        var found = false
        for (d in arr) {
            if (d.id == doc.id) {
                found = true
            }
        }
        @Expect(found, true)

        svc.deleteDocument(doc.id, DocumentStatus.Issued)
    }

    // loadDocumentMetadata: returns the document (delegates to load by id);
    // metadata blob round-trips when present.
    @TestCase
    func testLoadDocumentMetadataRoundtrip(): Unit {
        let ctx = getContext()
        let svc = RdbStorageService(ctx, "ws_dev_meta.db")
        let metaBytes: Array<UInt8> = [0x7Bu8, 0x7Du8]
        let data: Array<UInt8> = [0x01u8]
        let doc = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            data,
            None,
            Some(metaBytes),
            Some("Meta Doc"),
            DocumentStatus.Issued
        )
        svc.saveDocument(doc, None, true)

        let meta = svc.loadDocumentMetadata(doc.id)
        @Expect(meta.isSome(), true)
        let metaDoc = meta.getOrThrow()
        @Expect(metaDoc.id, doc.id)
        @Expect(metaDoc.metadata.isSome(), true)
        let mb: Array<UInt8> = metaDoc.metadata.getOrThrow()
        @Expect(mb.size, 2)
        @Expect(mb[0], 0x7Bu8)

        svc.deleteDocument(doc.id, DocumentStatus.Issued)
    }

    // deleteDocument: after deletion loadDocument returns None.
    @TestCase
    func testDeleteDocumentThenLoadNone(): Unit {
        let ctx = getContext()
        let svc = RdbStorageService(ctx, "ws_dev_del.db")
        let data: Array<UInt8> = [0x11u8]
        let doc = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            data,
            None,
            None,
            None,
            DocumentStatus.Issued
        )
        svc.saveDocument(doc, None, true)
        @Expect(svc.loadDocument(doc.id, DocumentStatus.Issued).isSome(), true)
        svc.deleteDocument(doc.id, DocumentStatus.Issued)
        @Expect(svc.loadDocument(doc.id, DocumentStatus.Issued).isNone(), true)
    }

    // deleteDocuments(status): bulk delete removes every doc of that status.
    @TestCase
    func testDeleteDocumentsByStatusBulk(): Unit {
        let ctx = getContext()
        let svc = RdbStorageService(ctx, "ws_dev_bulkdel.db")
        let data: Array<UInt8> = [0x22u8]
        let doc1 = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            data,
            None,
            None,
            None,
            DocumentStatus.Pending
        )
        let doc2 = Document(
            "org.iso.18013.5.1.pid.1",
            DocDataFormat.Cbor,
            data,
            None,
            None,
            None,
            DocumentStatus.Pending
        )
        svc.saveDocument(doc1, None, true)
        svc.saveDocument(doc2, None, true)

        svc.deleteDocuments(DocumentStatus.Pending)
        @Expect(svc.loadDocument(doc1.id, DocumentStatus.Pending).isNone(), true)
        @Expect(svc.loadDocument(doc2.id, DocumentStatus.Pending).isNone(), true)
    }

    // deleteDocumentCredential: removes one credential batch item by id+index.
    // We save a batch doc with one credential, delete credential index 0, then
    // confirm the parent doc still loads (only the credential row is gone).
    @TestCase
    func testDeleteDocumentCredential(): Unit {
        let ctx = getContext()
        let svc = RdbStorageService(ctx, "ws_dev_cred.db")
        let data: Array<UInt8> = [0x33u8]
        let batchDoc = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            data,
            None,
            None,
            Some("Batch Doc"),
            DocumentStatus.Issued
        )
        let credData: Array<UInt8> = [0x44u8]
        let credDoc = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            credData,
            None,
            None,
            Some("Cred 0"),
            DocumentStatus.Issued
        )
        let credBatch: Array<Document> = [credDoc]
        svc.saveDocument(batchDoc, Some(credBatch), true)

        svc.deleteDocumentCredential(batchDoc.id, 0i64)
        let stillThere = svc.loadDocument(batchDoc.id, DocumentStatus.Issued)
        @Expect(stillThere.isSome(), true)

        svc.deleteDocument(batchDoc.id, DocumentStatus.Issued)
        @Expect(svc.loadDocument(batchDoc.id, DocumentStatus.Issued).isNone(), true)
    }

    // allowOverwrite=true: re-saving same id replaces the stored bytes.
    @TestCase
    func testAllowOverwriteReplacesBytes(): Unit {
        let ctx = getContext()
        let svc = RdbStorageService(ctx, "ws_dev_overwrite.db")
        let data1: Array<UInt8> = [0xAAu8]
        let doc1 = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            data1,
            None,
            None,
            Some("V1"),
            DocumentStatus.Issued
        )
        svc.saveDocument(doc1, None, true)
        let loaded1 = svc.loadDocument(doc1.id, DocumentStatus.Issued)
        @Expect(loaded1.isSome(), true)
        @Expect(loaded1.getOrThrow().data[0], 0xAAu8)

        let data2: Array<UInt8> = [0xBBu8]
        let doc2 = Document(
            doc1.id,
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            data2,
            None,
            0i64,
            doc1.createdAt,
            None,
            None,
            Some("V2"),
            DocumentStatus.Issued
        )
        svc.saveDocument(doc2, None, true)
        let loaded2 = svc.loadDocument(doc1.id, DocumentStatus.Issued)
        @Expect(loaded2.isSome(), true)
        @Expect(loaded2.getOrThrow().data[0], 0xBBu8)

        svc.deleteDocument(doc1.id, DocumentStatus.Issued)
    }
}
