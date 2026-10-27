/*
 * data_storage_service.cj
 *
 * DataStorageService interface — document storage protocol.
 *
 * iOS reference:
 *   Sources/WalletStorage/DataStorageService.swift — DataStorageService protocol
 *
 * Method mapping (iOS → Cangjie):
 *   loadDocument(id:status:)            → loadDocument(id, status)
 *   loadDocumentMetadata(id:)           → loadDocumentMetadata(id)
 *   loadDocuments(status:)              → loadDocuments(status)
 *   saveDocument(_:batch:allowOverwrite:) → saveDocument(doc, batch, allowOverwrite)
 *   deleteDocument(id:status:)          → deleteDocument(id, status)
 *   deleteDocuments(status:)            → deleteDocuments(status)
 *   deleteDocumentCredential(id:index:) → deleteDocumentCredential(id, index)
 *
 * Package: ohos_app_cangjie_eudi_cjwallet_storage.storage.docstore
 */
package ohos_app_cangjie_eudi_cjwallet_storage.storage.docstore

import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.Document
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.DocumentStatus
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.StorageError

/**
 * Document storage service interface.
 *
 * Mirrors iOS DataStorageService protocol (actor).  In the HarmonyOS mapping
 * concurrency is managed by the caller; implementations are not required to be
 * actor-isolated but must be safe for sequential single-threaded access
 * (matching the iOS actor contract).
 *
 * All methods may throw StorageError on persistence failures.
 */
public interface DataStorageService {
    /**
     * Load a document with the specified id and status.
     *
     * If a batch of credentials has been saved, this method loads the
     * placeholder document (keyIndex 0) so the caller can determine the
     * appropriate batch entry to use.
     *
     * Returns None if no matching document is found.
     */
    func loadDocument(id: String, status: DocumentStatus): ?Document

    /**
     * Load display metadata for an issued document.
     *
     * Returns None if no document with the given id exists.
     */
    func loadDocumentMetadata(id: String): ?Document

    /**
     * Load all placeholder documents with the specified status.
     *
     * Returns None if no documents match; never returns an empty array.
     */
    func loadDocuments(status: DocumentStatus): ?Array<Document>

    /**
     * Persist a document and an optional batch of credential documents.
     *
     * When `batch` is provided each entry is stored with a compound key
     * `<id>_<index>` matching the iOS Keychain storage convention.
     * If `allowOverwrite` is false and a document with the same id already
     * exists, a StorageError is thrown.
     */
    func saveDocument(doc: Document, batch: ?Array<Document>, allowOverwrite: Bool): Unit

    /**
     * Delete a document and all associated credential batch items for the given
     * id and status.
     */
    func deleteDocument(id: String, status: DocumentStatus): Unit

    /**
     * Delete all documents (and their credential batches) with the given status.
     */
    func deleteDocuments(status: DocumentStatus): Unit

    /**
     * Delete a single credential batch item at the specified index.
     *
     * The compound row key used is `<id>_<index>`, matching the iOS pattern
     * `deleteDocumentCredential(id:index:)`.
     */
    func deleteDocumentCredential(id: String, index: Int64): Unit

    /**
     * Count the credential batch rows stored for the given document id
     * (batch entries only — the primary placeholder document is not included).
     * Backs the iOS `credentialsUsageCounts` (remaining/total) document badge.
     */
    func countDocumentCredentials(id: String): Int64
}
