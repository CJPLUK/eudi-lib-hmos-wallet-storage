/*
 * rdb_storage_service.cj
 *
 * RdbStorageService — encrypted RDB implementation of DataStorageService.
 *
 * Design rationale (iOS Keychain → HarmonyOS encrypted RDB):
 *
 *   iOS persists documents as pairs of Keychain generic-password items keyed by
 *   a compound service-name that encodes (serviceName, dataType, status).
 *   On HarmonyOS the equivalent persistent, encrypted store is the RDB with
 *   `StoreConfig.encrypt = true` (OS-managed SQLCipher at S3 level).
 *
 *   Two tables mirror the iOS dual-item model:
 *
 *     DOCUMENTS   — one row per document (the "placeholder" / docPresent row).
 *                   Primary key: doc_id.
 *
 *     CREDENTIALS — one row per batch credential item.
 *                   Primary key: cred_id = "<doc_id>_<index>".
 *
 *   Static encryption: StoreConfig is configured with
 *     - RelationalStoreSecurityLevel.S3 (highest security level)
 *     - encrypt: true   (OS-level SQLCipher full-database encryption)
 *
 *   Context injection: getRdbStore() requires a UIAbilityContext.  The HAR
 *   layer avoids a hard dependency on the app lifecycle by receiving the
 *   context at construction time (matching the storageDir injection pattern
 *   used by HuksSecureKeyStorage).
 *
 * iOS references:
 *   Sources/WalletStorage/KeyChainStorageService.swift — KeyChainStorageService
 *   Sources/WalletStorage/DataStorageService.swift     — DataStorageService protocol
 *
 * Package: ohos_app_cangjie_eudi_cjwallet_storage.storage.docstore
 */
package ohos_app_cangjie_eudi_cjwallet_storage.storage.docstore

import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import ohos.business_exception.BusinessException
import std.collection.HashMap
import std.collection.ArrayList
import std.time.DateTime
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.Document
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.DocumentStatus
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.DocDataFormat
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.StorageError

/* ========================================================================= */
/* Constants                                                                   */
/* ========================================================================= */

let TABLE_DOCUMENTS: String = "DOCUMENTS"
let TABLE_CREDENTIALS: String = "CREDENTIALS"

let COL_DOC_ID: String = "doc_id"
let COL_STATUS: String = "status"
let COL_DOC_TYPE: String = "doc_type"
let COL_DATA: String = "data"
let COL_DOC_KEY_INFO: String = "doc_key_info"
let COL_KEY_INDEX: String = "key_index"
let COL_CREATED_AT: String = "created_at"
let COL_MODIFIED_AT: String = "modified_at"
let COL_METADATA: String = "metadata"
let COL_DISPLAY_NAME: String = "display_name"
let COL_DOC_DATA_FORMAT: String = "doc_data_format"

let COL_CRED_ID: String = "cred_id"
let COL_CRED_INDEX: String = "cred_index"

let SQL_CREATE_DOCUMENTS: String =
    "CREATE TABLE IF NOT EXISTS DOCUMENTS (" +
    "doc_id TEXT NOT NULL PRIMARY KEY, " +
    "status TEXT NOT NULL, " +
    "doc_type TEXT NOT NULL, " +
    "data BLOB NOT NULL, " +
    "doc_key_info BLOB, " +
    "key_index INTEGER NOT NULL DEFAULT 0, " +
    "created_at INTEGER NOT NULL, " +
    "modified_at INTEGER, " +
    "metadata BLOB, " +
    "display_name TEXT, " +
    "doc_data_format TEXT NOT NULL" +
    ")"

let SQL_CREATE_CREDENTIALS: String =
    "CREATE TABLE IF NOT EXISTS CREDENTIALS (" +
    "cred_id TEXT NOT NULL PRIMARY KEY, " +
    "doc_id TEXT NOT NULL, " +
    "cred_index INTEGER NOT NULL, " +
    "status TEXT NOT NULL, " +
    "doc_type TEXT NOT NULL, " +
    "data BLOB NOT NULL, " +
    "doc_key_info BLOB, " +
    "key_index INTEGER NOT NULL DEFAULT 0, " +
    "created_at INTEGER NOT NULL, " +
    "modified_at INTEGER, " +
    "metadata BLOB, " +
    "display_name TEXT, " +
    "doc_data_format TEXT NOT NULL" +
    ")"

/* ========================================================================= */
/* Internal helpers                                                            */
/* ========================================================================= */

/*
 * Determine whether a BusinessException represents a cursor out-of-bounds
 * condition (empty result set or past-last-row), as observed on real device
 * where goToFirstRow() and goToNextRow() throw instead of returning false.
 *
 * Only "out of bounds" messages are treated as boundary signals.
 * All other BusinessException messages are genuine errors and must propagate.
 */
func isCursorOutOfBounds(e: BusinessException): Bool {
    return e.message.contains("out of bounds")
}

/*
 * Convert DateTime to Unix epoch milliseconds for INTEGER storage.
 * Uses toUnixTimeStamp() which returns a Duration since UnixEpoch.
 */
func dateTimeToMillis(dt: DateTime): Int64 {
    return dt.toUnixTimeStamp().toMilliseconds()
}

/*
 * Convert Unix epoch milliseconds back to DateTime.
 * DateTime.fromUnixTimeStamp(Duration) takes a Duration since UnixEpoch.
 * Duration.millisecond * ms gives the Duration for ms milliseconds.
 */
func millisToDateTime(ms: Int64): DateTime {
    return DateTime.fromUnixTimeStamp(Duration.millisecond * ms)
}

/*
 * Build a ValuesBucket for a Document row in the DOCUMENTS table.
 * R-101: StorageError init uses positional params (no `!` in init signature).
 */
func documentToValues(doc: Document): HashMap<String, RelationalStoreValueType> {
    var values = HashMap<String, RelationalStoreValueType>()
    values.add(COL_DOC_ID, RelationalStoreValueType.StringValue(doc.id))
    values.add(COL_STATUS, RelationalStoreValueType.StringValue(doc.status.rawValue()))
    values.add(COL_DOC_TYPE, RelationalStoreValueType.StringValue(doc.docType))
    values.add(COL_DATA, RelationalStoreValueType.Uint8Array(doc.data))
    match (doc.docKeyInfo) {
        case Some(ki) => values.add(COL_DOC_KEY_INFO, RelationalStoreValueType.Uint8Array(ki))
        case None => ()
    }
    values.add(COL_KEY_INDEX, RelationalStoreValueType.Integer(doc.keyIndex))
    values.add(COL_CREATED_AT, RelationalStoreValueType.Integer(dateTimeToMillis(doc.createdAt)))
    match (doc.modifiedAt) {
        case Some(mdt) => values.add(COL_MODIFIED_AT, RelationalStoreValueType.Integer(dateTimeToMillis(mdt)))
        case None => values.add(COL_MODIFIED_AT, RelationalStoreValueType.Integer(0))
    }
    match (doc.metadata) {
        case Some(md) => values.add(COL_METADATA, RelationalStoreValueType.Uint8Array(md))
        case None => ()
    }
    match (doc.displayName) {
        case Some(dn) => values.add(COL_DISPLAY_NAME, RelationalStoreValueType.StringValue(dn))
        case None => values.add(COL_DISPLAY_NAME, RelationalStoreValueType.StringValue(""))
    }
    values.add(COL_DOC_DATA_FORMAT, RelationalStoreValueType.StringValue(doc.docDataFormat.rawValue()))
    return values
}

/*
 * Build a ValuesBucket for a credential batch item in the CREDENTIALS table.
 */
func credentialToValues(
    credId: String,
    credIndex: Int64,
    docId: String,
    doc: Document
): HashMap<String, RelationalStoreValueType> {
    var values = HashMap<String, RelationalStoreValueType>()
    values.add(COL_CRED_ID, RelationalStoreValueType.StringValue(credId))
    values.add(COL_DOC_ID, RelationalStoreValueType.StringValue(docId))
    values.add(COL_CRED_INDEX, RelationalStoreValueType.Integer(credIndex))
    values.add(COL_STATUS, RelationalStoreValueType.StringValue(doc.status.rawValue()))
    values.add(COL_DOC_TYPE, RelationalStoreValueType.StringValue(doc.docType))
    values.add(COL_DATA, RelationalStoreValueType.Uint8Array(doc.data))
    match (doc.docKeyInfo) {
        case Some(ki) => values.add(COL_DOC_KEY_INFO, RelationalStoreValueType.Uint8Array(ki))
        case None => ()
    }
    values.add(COL_KEY_INDEX, RelationalStoreValueType.Integer(doc.keyIndex))
    values.add(COL_CREATED_AT, RelationalStoreValueType.Integer(dateTimeToMillis(doc.createdAt)))
    match (doc.modifiedAt) {
        case Some(mdt) => values.add(COL_MODIFIED_AT, RelationalStoreValueType.Integer(dateTimeToMillis(mdt)))
        case None => values.add(COL_MODIFIED_AT, RelationalStoreValueType.Integer(0))
    }
    match (doc.metadata) {
        case Some(md) => values.add(COL_METADATA, RelationalStoreValueType.Uint8Array(md))
        case None => ()
    }
    match (doc.displayName) {
        case Some(dn) => values.add(COL_DISPLAY_NAME, RelationalStoreValueType.StringValue(dn))
        case None => values.add(COL_DISPLAY_NAME, RelationalStoreValueType.StringValue(""))
    }
    values.add(COL_DOC_DATA_FORMAT, RelationalStoreValueType.StringValue(doc.docDataFormat.rawValue()))
    return values
}

/*
 * Read a nullable BLOB column from ResultSet.
 * Returns None if the column value is empty (NULL columns read as zero-length).
 */
func readOptionalBlob(rs: ResultSet, colName: String): ?Array<UInt8> {
    let idx: Int32 = rs.getColumnIndex(colName)
    let blob: Array<UInt8> = rs.getBlob(idx)
    if (blob.size == 0) {
        return None
    }
    return Some(blob)
}

/*
 * Read a nullable TEXT column from ResultSet.
 * Returns None if the column value is an empty string (NULL columns).
 */
func readOptionalString(rs: ResultSet, colName: String): ?String {
    let idx: Int32 = rs.getColumnIndex(colName)
    let val: String = rs.getString(idx)
    if (val.isEmpty()) {
        return None
    }
    return Some(val)
}

/*
 * Reconstruct a Document from the current ResultSet row (DOCUMENTS table columns).
 */
func documentFromResultSet(rs: ResultSet, status: DocumentStatus): Document {
    let id: String = rs.getString(rs.getColumnIndex(COL_DOC_ID))
    let docType: String = rs.getString(rs.getColumnIndex(COL_DOC_TYPE))
    let formatRaw: String = rs.getString(rs.getColumnIndex(COL_DOC_DATA_FORMAT))
    let format: DocDataFormat = match (DocDataFormat.fromRaw(formatRaw)) {
        case Some(f) => f
        case None => DocDataFormat.Cbor
    }
    let data: Array<UInt8> = rs.getBlob(rs.getColumnIndex(COL_DATA))
    let docKeyInfo: ?Array<UInt8> = readOptionalBlob(rs, COL_DOC_KEY_INFO)
    let keyIndex: Int64 = rs.getLong(rs.getColumnIndex(COL_KEY_INDEX))
    let createdAtMs: Int64 = rs.getLong(rs.getColumnIndex(COL_CREATED_AT))
    let createdAt: DateTime = millisToDateTime(createdAtMs)
    let modifiedAtMs: Int64 = rs.getLong(rs.getColumnIndex(COL_MODIFIED_AT))
    let modifiedAt: ?DateTime = if (modifiedAtMs == 0) {
        None
    } else {
        Some(millisToDateTime(modifiedAtMs))
    }
    let metadata: ?Array<UInt8> = readOptionalBlob(rs, COL_METADATA)
    let displayName: ?String = readOptionalString(rs, COL_DISPLAY_NAME)
    return Document(
        id,
        docType,
        format,
        data,
        docKeyInfo,
        keyIndex,
        createdAt,
        modifiedAt,
        metadata,
        displayName,
        status
    )
}

/* ========================================================================= */
/* RdbStorageService                                                           */
/* ========================================================================= */

/**
 * Encrypted RDB implementation of DataStorageService.
 *
 * Wraps HarmonyOS RelationalStore (RDB) with OS-managed SQLCipher encryption
 * (`encrypt: true`, `S3` security level) to provide document-level persistence.
 *
 * Construction:
 *   RdbStorageService(context, "eudi_wallet.db")
 *
 * The `context` must be a UIAbilityContext (obtained from UIAbility.onCreate).
 * Passing an AbilityStage context will cause getRdbStore to throw at runtime
 * (S-012 in syntax_error.md).
 *
 * iOS mirror: KeyChainStorageService (actor)
 */
public class RdbStorageService <: DataStorageService {
    /** UIAbilityContext required by getRdbStore. */
    private let context: UIAbilityContext
    /** Database file name (e.g. "eudi_wallet.db"). */
    private let dbName: String
    /** Lazily initialised RDB store handle. */
    private var rdbStore: ?RdbStore

    /**
     * Create an RdbStorageService.
     *
     * - context: UIAbilityContext from UIAbility.onCreate (NOT AbilityStage context).
     * - dbName: name of the encrypted RDB file (e.g. "eudi_wallet.db").
     *
     * The RDB store is opened lazily on the first operation call.
     */
    public init(context: UIAbilityContext, dbName: String) {
        this.context = context
        this.dbName = dbName
        this.rdbStore = None
    }

    /* ---------------------------------------------------------------------- */
    /* Private helpers                                                         */
    /* ---------------------------------------------------------------------- */

    /**
     * Open (or return cached) the encrypted RDB store and ensure the schema
     * tables exist.
     *
     * StoreConfig:
     *   - RelationalStoreSecurityLevel.S3 — highest OS security classification
     *   - encrypt: true                   — SQLCipher full-database encryption
     *
     * Throws StorageError if the database cannot be opened.
     */
    private func getOrOpenStore(): RdbStore {
        if (this.rdbStore.isSome()) {
            return this.rdbStore.getOrThrow()
        }
        let config = StoreConfig(
            RelationalStoreSecurityLevel.S3,
            name: this.dbName,
            encrypt: true
        )
        try {
            let store: RdbStore = getRdbStore(this.context, config)
            store.executeSql(SQL_CREATE_DOCUMENTS)
            store.executeSql(SQL_CREATE_CREDENTIALS)
            this.rdbStore = Some(store)
            return store
        } catch (e: BusinessException) {
            throw StorageError("Failed to open RDB store: " + e.message)
        }
    }

    /**
     * Insert a row in the DOCUMENTS table.
     * On duplicate key (insert fails), update the row if allowOverwrite is true.
     * Throws StorageError if allowOverwrite is false and the document exists.
     */
    private func upsertDocument(store: RdbStore, doc: Document, allowOverwrite: Bool): Unit {
        let values = documentToValues(doc)
        try {
            store.insert(TABLE_DOCUMENTS, values)
        } catch (e: BusinessException) {
            if (allowOverwrite) {
                let pred = RdbPredicates(TABLE_DOCUMENTS)
                pred.equalTo(COL_DOC_ID, RelationalStoreValueType.StringValue(doc.id))
                let updateValues = documentToValues(doc)
                try {
                    store.update(updateValues, pred)
                } catch (ue: BusinessException) {
                    throw StorageError("Failed to update document: " + ue.message)
                }
            } else {
                throw StorageError("Failed to insert document (allowOverwrite=false): " + e.message)
            }
        }
    }

    /**
     * Insert or overwrite a credential batch item in the CREDENTIALS table.
     */
    private func upsertCredential(
        store: RdbStore,
        credId: String,
        credIndex: Int64,
        docId: String,
        doc: Document,
        allowOverwrite: Bool
    ): Unit {
        let values = credentialToValues(credId, credIndex, docId, doc)
        try {
            store.insert(TABLE_CREDENTIALS, values)
        } catch (e: BusinessException) {
            if (allowOverwrite) {
                let pred = RdbPredicates(TABLE_CREDENTIALS)
                pred.equalTo(COL_CRED_ID, RelationalStoreValueType.StringValue(credId))
                let updateValues = credentialToValues(credId, credIndex, docId, doc)
                try {
                    store.update(updateValues, pred)
                } catch (ue: BusinessException) {
                    throw StorageError("Failed to update credential: " + ue.message)
                }
            } else {
                throw StorageError("Failed to insert credential (allowOverwrite=false): " + e.message)
            }
        }
    }

    /* ---------------------------------------------------------------------- */
    /* DataStorageService interface implementation                             */
    /* ---------------------------------------------------------------------- */

    /**
     * Load a document with the specified id and status from the DOCUMENTS table.
     *
     * Returns None if no matching document is found.
     * Mirrors iOS loadDocument(id:status:).
     */
    public func loadDocument(id: String, status: DocumentStatus): ?Document {
        let store = this.getOrOpenStore()
        let pred = RdbPredicates(TABLE_DOCUMENTS)
        pred.equalTo(COL_DOC_ID, RelationalStoreValueType.StringValue(id))
        pred.equalTo(COL_STATUS, RelationalStoreValueType.StringValue(status.rawValue()))
        let columns: Array<String> = [
            COL_DOC_ID, COL_STATUS, COL_DOC_TYPE, COL_DATA, COL_DOC_KEY_INFO,
            COL_KEY_INDEX, COL_CREATED_AT, COL_MODIFIED_AT, COL_METADATA,
            COL_DISPLAY_NAME, COL_DOC_DATA_FORMAT
        ]
        var rs: ?ResultSet = None
        try {
            rs = Some(store.query(pred, columns: columns))
            let r = rs.getOrThrow()
            // Device behaviour (4 rounds of E2E evidence):
            // goToFirstRow() throws "out of bounds" on empty result sets instead
            // of returning false.  Wrap both cursor calls; treat out-of-bounds as
            // boundary, re-throw all other BusinessExceptions to the outer catch
            // (which closes rs and converts to StorageError).
            var positioned: Bool = false
            try {
                positioned = r.goToFirstRow()
            } catch (e: BusinessException) {
                if (isCursorOutOfBounds(e)) {
                    positioned = false
                } else {
                    throw e
                }
            }
            if (!positioned) {
                r.close()
                return None
            }
            let doc: Document = documentFromResultSet(r, status)
            r.close()
            return Some(doc)
        } catch (e: BusinessException) {
            match (rs) {
                case Some(r) => r.close()
                case None => ()
            }
            throw StorageError("loadDocument failed: " + e.message)
        }
    }

    /**
     * Load display metadata for the issued document with the given id.
     *
     * Queries DOCUMENTS for status=issued and returns the document (which
     * carries the metadata field).  Returns None if not found.
     *
     * Mirrors iOS loadDocumentMetadata(id:) which loads the placeholder
     * document with status=issued.
     */
    public func loadDocumentMetadata(id: String): ?Document {
        return this.loadDocument(id, DocumentStatus.Issued)
    }

    /**
     * Load all placeholder documents with the specified status.
     *
     * Uses raw SQL (querySql) instead of RdbPredicates to bypass a device-level
     * cursor anomaly: single-predicate RdbPredicates queries return an abnormal
     * ResultSet whose goToFirstRow/goToNextRow throw "out of bounds" even when
     * matching rows exist (5 rounds of E2E evidence).  The dual-predicate path
     * in loadDocument(id+status) is not affected and is left unchanged.
     *
     * Probe (fix-loaddocs-twocond): adds a second always-true predicate
     * "AND doc_id IS NOT NULL" to the WHERE clause.  Hypothesis: the device
     * RelationalStore cursor behaves correctly for two-condition querySql but
     * throws on single-condition querySql.  Semantics are unchanged (all stored
     * rows have a non-NULL doc_id by schema constraint).
     *
     * API: RdbStore.querySql(sql: String, bindArgs!: Array<RelationalStoreValueType>): ResultSet
     *
     * Returns None if no rows match.  Mirrors iOS loadDocuments(status:).
     */
    public func loadDocuments(status: DocumentStatus): ?Array<Document> {
        let store = this.getOrOpenStore()
        let sql: String =
            "SELECT " +
            COL_DOC_ID + ", " +
            COL_STATUS + ", " +
            COL_DOC_TYPE + ", " +
            COL_DATA + ", " +
            COL_DOC_KEY_INFO + ", " +
            COL_KEY_INDEX + ", " +
            COL_CREATED_AT + ", " +
            COL_MODIFIED_AT + ", " +
            COL_METADATA + ", " +
            COL_DISPLAY_NAME + ", " +
            COL_DOC_DATA_FORMAT +
            " FROM " + TABLE_DOCUMENTS +
            " WHERE " + COL_STATUS + " = ? AND " + COL_DOC_ID + " IS NOT NULL"
        let bindArgs: Array<RelationalStoreValueType> = [
            RelationalStoreValueType.StringValue(status.rawValue())
        ]
        var rs: ?ResultSet = None
        try {
            rs = Some(store.querySql(sql, bindArgs: bindArgs))
            let r = rs.getOrThrow()
            // Device behaviour (5 rounds of E2E evidence):
            // goToFirstRow() and goToNextRow() may throw "out of bounds" instead
            // of returning false when there are no (more) rows.  Retain the
            // try/catch boundary guard even with raw SQL for safety.
            var positioned: Bool = false
            try {
                positioned = r.goToFirstRow()
            } catch (e: BusinessException) {
                if (isCursorOutOfBounds(e)) {
                    positioned = false
                } else {
                    throw e
                }
            }
            if (!positioned) {
                r.close()
                return None
            }
            let docs = ArrayList<Document>()
            // Row 0 is already positioned by goToFirstRow(); read it directly.
            docs.add(documentFromResultSet(r, status))
            var more: Bool = true
            while (more) {
                try {
                    more = r.goToNextRow()
                } catch (e: BusinessException) {
                    if (isCursorOutOfBounds(e)) {
                        more = false
                    } else {
                        throw e
                    }
                }
                if (more) {
                    docs.add(documentFromResultSet(r, status))
                }
            }
            r.close()
            return Some(docs.toArray())
        } catch (e: BusinessException) {
            match (rs) {
                case Some(r) => r.close()
                case None => ()
            }
            throw StorageError("loadDocuments failed: " + e.message)
        }
    }

    /**
     * Persist a document and an optional batch of credential documents.
     *
     * The placeholder document is stored in DOCUMENTS.  Each batch item is
     * stored in CREDENTIALS with cred_id = "<doc.id>_<index>".
     *
     * Mirrors iOS saveDocument(_:batch:allowOverwrite:).
     */
    public func saveDocument(doc: Document, batch: ?Array<Document>, allowOverwrite: Bool): Unit {
        let store = this.getOrOpenStore()
        this.upsertDocument(store, doc, allowOverwrite)
        match (batch) {
            case Some(batchDocs) =>
                var i: Int64 = 0
                while (i < batchDocs.size) {
                    let credId: String = doc.id + "_" + i.toString()
                    this.upsertCredential(store, credId, i, doc.id, batchDocs[i], allowOverwrite)
                    i++
                }
            case None => ()
        }
    }

    /**
     * Delete a document and all its credential batch items.
     *
     * Deletes the DOCUMENTS row for (id, status) and all CREDENTIALS rows
     * where doc_id = id.
     *
     * Mirrors iOS deleteDocument(id:status:) → deleteDocumentHelper.
     */
    public func deleteDocument(id: String, status: DocumentStatus): Unit {
        let store = this.getOrOpenStore()
        try {
            let docPred = RdbPredicates(TABLE_DOCUMENTS)
            docPred.equalTo(COL_DOC_ID, RelationalStoreValueType.StringValue(id))
            docPred.equalTo(COL_STATUS, RelationalStoreValueType.StringValue(status.rawValue()))
            store.delete(docPred)
            let credPred = RdbPredicates(TABLE_CREDENTIALS)
            credPred.equalTo(COL_DOC_ID, RelationalStoreValueType.StringValue(id))
            store.delete(credPred)
        } catch (e: BusinessException) {
            throw StorageError("deleteDocument failed: " + e.message)
        }
    }

    /**
     * Delete all documents and their credential batch items with the given status.
     *
     * Uses bulk SQL DELETE for efficiency.
     * Mirrors iOS deleteDocuments(status:).
     */
    public func deleteDocuments(status: DocumentStatus): Unit {
        let store = this.getOrOpenStore()
        let statusStr: String = status.rawValue()
        try {
            let credPred = RdbPredicates(TABLE_CREDENTIALS)
            credPred.equalTo(COL_STATUS, RelationalStoreValueType.StringValue(statusStr))
            store.delete(credPred)
            let docPred = RdbPredicates(TABLE_DOCUMENTS)
            docPred.equalTo(COL_STATUS, RelationalStoreValueType.StringValue(statusStr))
            store.delete(docPred)
        } catch (e: BusinessException) {
            throw StorageError("deleteDocuments failed: " + e.message)
        }
    }

    /**
     * Delete a single credential batch item at the specified index.
     *
     * The compound key used is `<id>_<index>`, matching the iOS
     * `deleteDocumentCredential(id:index:)` pattern.
     */
    public func deleteDocumentCredential(id: String, index: Int64): Unit {
        let store = this.getOrOpenStore()
        let credId: String = id + "_" + index.toString()
        try {
            let pred = RdbPredicates(TABLE_CREDENTIALS)
            pred.equalTo(COL_CRED_ID, RelationalStoreValueType.StringValue(credId))
            store.delete(pred)
        } catch (e: BusinessException) {
            throw StorageError("deleteDocumentCredential failed: " + e.message)
        }
    }

    /**
     * Count the credential batch rows for the given document id (CREDENTIALS
     * table, exact doc_id match). Uses the same out-of-bounds cursor guard as
     * loadDocuments (device throws instead of returning false on empty sets).
     */
    public func countDocumentCredentials(id: String): Int64 {
        let store = this.getOrOpenStore()
        let pred = RdbPredicates(TABLE_CREDENTIALS)
        pred.equalTo(COL_DOC_ID, RelationalStoreValueType.StringValue(id))
        let columns: Array<String> = [COL_CRED_ID]
        var rs: ?ResultSet = None
        try {
            rs = Some(store.query(pred, columns: columns))
            let r = rs.getOrThrow()
            var n: Int64 = 0
            var positioned: Bool = false
            try {
                positioned = r.goToFirstRow()
            } catch (e: BusinessException) {
                if (isCursorOutOfBounds(e)) {
                    positioned = false
                } else {
                    throw e
                }
            }
            while (positioned) {
                n++
                try {
                    positioned = r.goToNextRow()
                } catch (e: BusinessException) {
                    if (isCursorOutOfBounds(e)) {
                        positioned = false
                    } else {
                        throw e
                    }
                }
            }
            r.close()
            return n
        } catch (e: BusinessException) {
            match (rs) {
                case Some(r) => r.close()
                case None => ()
            }
            throw StorageError("countDocumentCredentials failed: " + e.message)
        }
    }
}
