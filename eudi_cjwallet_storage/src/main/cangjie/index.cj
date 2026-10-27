// HAR root package anchor (S-003): the root src/main/cangjie dir must contain
// at least one .cj file so cjpm scans the storage sub-packages, and so the
// entry module (which declares this HAR as a dependency from scaffold time)
// compiles the HAR on every build.
package ohos_app_cangjie_eudi_cjwallet_storage

import std.collection.HashMap
import kit.AbilityKit.UIAbilityContext
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.Document
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.DocumentStatus
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.DocDataFormat
import ohos_app_cangjie_eudi_cjwallet_storage.storage.keystore.HuksSecureKeyStorage
import ohos_app_cangjie_eudi_cjwallet_storage.storage.docstore.RdbStorageService

/**
 * End-to-end wallet-storage demo.
 *
 * Exercises the three storage layers (types, keystore, docstore) in a single
 * roundtrip so that the entry shell can display the result string.
 *
 * Returns a result string of the form:
 *   "OK: doc_crud=PASS, key_roundtrip=PASS, encrypted_rdb=on"
 * or honest failure descriptions if a sub-chain does not complete.
 *
 * - context: UIAbilityContext from UIAbility.onCreate; required by
 *   RdbStorageService (encrypted RDB) and used to derive the HUKS
 *   key-storage directory (context.filesDir).
 */
public func runWalletStorageDemo(context: UIAbilityContext): String {
    var docCrud: String = "FAIL"
    var keyRoundtrip: String = "FAIL"

    // ------------------------------------------------------------------ //
    // 1. Document CRUD roundtrip via RdbStorageService (encrypted RDB)    //
    // ------------------------------------------------------------------ //
    try {
        let svc = RdbStorageService(context, "wallet_demo.db")

        // Construct a synthetic Document with known bytes
        let demoData: Array<UInt8> = [0x01u8, 0x02u8, 0x03u8, 0x04u8]
        let doc = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            demoData,
            None,
            None,
            Some("Demo Licence"),
            DocumentStatus.Issued
        )
        let docId: String = doc.id

        // saveDocument
        svc.saveDocument(doc, None, true)

        // loadDocument — verify bytes match
        let loaded: ?Document = svc.loadDocument(docId, DocumentStatus.Issued)
        let loadedOk: Bool = match (loaded) {
            case Some(d) =>
                d.data.size == demoData.size && d.data[0] == 0x01u8 && d.data[3] == 0x04u8
            case None => false
        }

        // loadDocuments(status) — must return at least one entry
        let all: ?Array<Document> = svc.loadDocuments(DocumentStatus.Issued)
        let listOk: Bool = match (all) {
            case Some(docs) => docs.size > 0
            case None => false
        }

        // deleteDocument — confirm removal
        svc.deleteDocument(docId, DocumentStatus.Issued)
        let afterDelete: ?Document = svc.loadDocument(docId, DocumentStatus.Issued)
        let deleteOk: Bool = match (afterDelete) {
            case None => true
            case Some(_) => false
        }

        if (loadedOk && listOk && deleteOk) {
            docCrud = "PASS"
        } else {
            docCrud = "FAIL(loadedOk=" + loadedOk.toString() +
                      ",listOk=" + listOk.toString() +
                      ",deleteOk=" + deleteOk.toString() + ")"
        }
    } catch (e: Exception) {
        docCrud = "FAIL(" + e.message + ")"
    }

    // ------------------------------------------------------------------ //
    // 2. Key roundtrip via HuksSecureKeyStorage                           //
    // ------------------------------------------------------------------ //
    try {
        let storageDir: String = context.filesDir
        let ks = HuksSecureKeyStorage("eudi_demo", storageDir)

        let keyId: String = "demo_key_001"
        let infoData: Array<UInt8> = [0xAAu8, 0xBBu8]
        let dataData: Array<UInt8> = [0xCCu8, 0xDDu8]

        // Build info and data dicts
        var infoDict = HashMap<String, Array<UInt8>>()
        infoDict["pub_key"] = infoData
        var dataDict = HashMap<String, Array<UInt8>>()
        dataDict["priv_key"] = dataData

        // writeKeyInfo / writeKeyDataBatch
        ks.writeKeyInfo(keyId, infoDict)
        ks.writeKeyDataBatch(keyId, 0, [dataDict], None)

        // readKeyInfo — verify
        let readInfo = ks.readKeyInfo(keyId)
        let infoOk: Bool = readInfo.contains("pub_key")

        // readKeyData — verify
        let readData = ks.readKeyData(keyId, 0)
        let dataOk: Bool = readData.contains("priv_key")

        // deleteKey (info + batch index 0)
        ks.deleteKeyInfo(keyId)
        ks.deleteKeyBatch(keyId, 0, 1)

        if (infoOk && dataOk) {
            keyRoundtrip = "PASS"
        } else {
            keyRoundtrip = "FAIL(infoOk=" + infoOk.toString() +
                           ",dataOk=" + dataOk.toString() + ")"
        }
    } catch (e: Exception) {
        keyRoundtrip = "FAIL(" + e.message + ")"
    }

    // ------------------------------------------------------------------ //
    // 3. Multidoc: replicate testLoadDocumentsByStatus failure scenario   //
    //    Two documents created back-to-back (same second).                //
    //    Before newId fix: id collision → second save overwrites first    //
    //    → loadDocuments(Issued) returns None.  After fix: both ids are   //
    //    distinct → exactly 1 Issued doc in the dedicated verify db.      //
    // ------------------------------------------------------------------ //
    var multidocByStatus: String = "FAIL"
    var idsDistinct: String = "FAIL"
    var mdId1: String = "?"
    var mdId2: String = "?"
    try {
        let mdSvc = RdbStorageService(context, "verify_multidoc.db")
        let mdIssued = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            [0xAAu8, 0xBBu8],
            None,
            None,
            Some("Issued Doc"),
            DocumentStatus.Issued
        )
        let mdDeferred = Document(
            "org.iso.18013.5.1.mDL",
            DocDataFormat.Cbor,
            [0xAAu8, 0xBBu8],
            None,
            None,
            Some("Deferred Doc"),
            DocumentStatus.Deferred
        )
        mdSvc.saveDocument(mdIssued, None, true)
        mdSvc.saveDocument(mdDeferred, None, true)
        mdId1 = mdIssued.id
        mdId2 = mdDeferred.id
        let mdIssuedList: ?Array<Document> = mdSvc.loadDocuments(DocumentStatus.Issued)
        let mdOk: Bool = match (mdIssuedList) {
            case Some(arr) => arr.size == 1
            case None => false
        }
        let distinct: Bool = mdId1 != mdId2
        multidocByStatus = if (mdOk) { "PASS" } else { "FAIL" }
        idsDistinct = distinct.toString()
    } catch (e: Exception) {
        multidocByStatus = "FAIL(" + e.message + ")"
        idsDistinct = "error"
    }

    return "OK: doc_crud=" + docCrud + ", key_roundtrip=" + keyRoundtrip + ", encrypted_rdb=on" +
           ", multidoc_byStatus=" + multidocByStatus +
           ", ids_distinct=" + idsDistinct +
           ", id1=" + mdId1 +
           ", id2=" + mdId2
}
