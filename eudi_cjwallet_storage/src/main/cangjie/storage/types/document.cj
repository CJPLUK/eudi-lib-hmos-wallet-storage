/*
 * document.cj
 *
 * Wallet-storage document model (storage layer).
 * Mirrors iOS Sources/WalletStorage/Document.swift.
 *
 * NAMING NOTE: The upstream mdoc-data-model package also exposes a class named
 * `Document` (ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.Document).
 * That class represents the ISO 18013-5 CBOR presentation-layer document.
 * THIS class is the storage-layer wrapper: it carries a persistent id, lifecycle
 * status, raw bytes to persist, and metadata — it is NOT the same as the mdoc
 * presentation Document. Downstream code that needs both must use
 * fully-qualified package names or import aliases to disambiguate.
 *
 * iOS references:
 *   Sources/WalletStorage/Document.swift
 *   eudi-lib-ios-iso18013-data-model/Sources/MdocDataModel18013/DocumentClaims/DocDataFormat.swift
 */
package ohos_app_cangjie_eudi_cjwallet_storage.storage.types

import std.time.DateTime

/* ====================================================================== */
/* DocDataFormat                                                           */
/* ====================================================================== */

/**
 * Encoding format of the raw credential bytes stored in Document.data.
 * Mirrors iOS DocDataFormat enum (MdocDataModel18013).
 *
 * Raw values are short strings matching the iOS keychain storage convention.
 */
public enum DocDataFormat {
    | Cbor
    | Sdjwt

    /** Raw string value matching iOS rawValue. */
    public func rawValue(): String {
        match (this) {
            case Cbor => return "cbor"
            case Sdjwt => return "sjwt"
        }
    }

    /** Human-readable IANA media-type description of the format. */
    public func describe(): String {
        match (this) {
            case Cbor => return "mso_mdoc"
            case Sdjwt => return "vc+sd-jwt"
        }
    }

    /** Construct from raw string; returns None for unknown values. */
    public static func fromRaw(raw: String): ?DocDataFormat {
        match (raw) {
            case "cbor" => return Some(DocDataFormat.Cbor)
            case "sjwt" => return Some(DocDataFormat.Sdjwt)
            case _ => return None
        }
    }
}

/* ====================================================================== */
/* Document                                                                */
/* ====================================================================== */

/**
 * Storage-layer document wrapper.
 *
 * Carries all fields needed to persist and retrieve a wallet credential.
 * The raw bytes in `data` encode either an IssuerSigned CBOR structure
 * (when docDataFormat == Cbor) or an SD-JWT (when docDataFormat == Sdjwt).
 *
 * Mirrors iOS Document struct (Sources/WalletStorage/Document.swift).
 *
 * Field mapping (iOS → Cangjie):
 *   id: String                    (UUID string)
 *   docType: String               (e.g. "org.iso.18013.5.1.mDL")
 *   docDataFormat: DocDataFormat  (Cbor | Sdjwt)
 *   data: Array<UInt8>            (iOS Data → Cangjie Array<UInt8>)
 *   docKeyInfo: ?Array<UInt8>     (serialised key info bytes)
 *   keyIndex: Int64               (0-based key index in a batch)
 *   createdAt: DateTime           (iOS Date → Cangjie DateTime)
 *   modifiedAt: ?DateTime
 *   metadata: ?Array<UInt8>       (opaque metadata, e.g. display JSON)
 *   displayName: ?String
 *   status: DocumentStatus
 */
public class Document {
    /** Persistent unique identifier for this document (UUID string). */
    public var id: String
    /** Document type string, e.g. "org.iso.18013.5.1.mDL". */
    public let docType: String
    /** Encoding format of the raw bytes in `data`. */
    public let docDataFormat: DocDataFormat
    /** Raw encoded credential bytes (IssuerSigned CBOR or SD-JWT). */
    public let data: Array<UInt8>
    /** Serialised key information bytes (CborValue-encoded KeyOptions / public key info). */
    public var docKeyInfo: ?Array<UInt8>
    /**
     * Index of the key in a batch credential set.
     * 0-based; maps to iOS keyIndex (default 0).
     */
    public var keyIndex: Int64
    /** Timestamp when this document was first stored. */
    public let createdAt: DateTime
    /** Timestamp of the last modification, or None if never modified after creation. */
    public let modifiedAt: ?DateTime
    /** Optional opaque metadata bytes (e.g. display-metadata JSON encoded as UTF-8). */
    public var metadata: ?Array<UInt8>
    /** Human-readable display name for this credential (e.g. "My Driving Licence"). */
    public var displayName: ?String
    /** Current lifecycle status of the document. */
    public let status: DocumentStatus

    /**
     * Full constructor — all fields explicit.
     * Used when reconstructing a Document from persistent storage.
     */
    public init(
        id: String,
        docType: String,
        docDataFormat: DocDataFormat,
        data: Array<UInt8>,
        docKeyInfo: ?Array<UInt8>,
        keyIndex: Int64,
        createdAt: DateTime,
        modifiedAt: ?DateTime,
        metadata: ?Array<UInt8>,
        displayName: ?String,
        status: DocumentStatus
    ) {
        this.id = id
        this.docType = docType
        this.docDataFormat = docDataFormat
        this.data = data
        this.docKeyInfo = docKeyInfo
        this.keyIndex = keyIndex
        this.createdAt = createdAt
        this.modifiedAt = modifiedAt
        this.metadata = metadata
        this.displayName = displayName
        this.status = status
    }

    /**
     * Convenience constructor for new documents.
     * Assigns a time-based id and sets createdAt to the current UTC time.
     * keyIndex defaults to 0, modifiedAt to None.
     * Mirrors iOS Document.init(docType:docDataFormat:data:docKeyInfo:…:status:).
     */
    public init(
        docType: String,
        docDataFormat: DocDataFormat,
        data: Array<UInt8>,
        docKeyInfo: ?Array<UInt8>,
        metadata: ?Array<UInt8>,
        displayName: ?String,
        status: DocumentStatus
    ) {
        this.id = Document.newId()
        this.docType = docType
        this.docDataFormat = docDataFormat
        this.data = data
        this.docKeyInfo = docKeyInfo
        this.keyIndex = 0
        this.createdAt = DateTime.now()
        this.modifiedAt = None
        this.metadata = metadata
        this.displayName = displayName
        this.status = status
    }

    /**
     * Whether this document is in deferred issuance state.
     * Mirrors iOS Document.isDeferred computed property.
     */
    public func isDeferred(): Bool {
        return this.status.isDeferred()
    }

    /**
     * Raw string representation of the document status.
     * Mirrors iOS Document.statusDescription computed property.
     */
    public func statusDescription(): String {
        return this.status.rawValue()
    }

    /**
     * Return the four-tuple used for data transfer, mirroring iOS getDataForTransfer().
     * Returns (docId, data) pair, (docId, metadata?) pair,
     *         (docId, formatRaw) pair, and (docId, docKeyInfo?) pair.
     */
    public func getDataForTransfer(): (
        (String, Array<UInt8>),
        (String, ?Array<UInt8>),
        (String, String),
        (String, ?Array<UInt8>)
    ) {
        let docPair: (String, Array<UInt8>) = (this.id, this.data)
        let metaPair: (String, ?Array<UInt8>) = (this.id, this.metadata)
        let fmtPair: (String, String) = (this.id, this.docDataFormat.rawValue())
        let keyPair: (String, ?Array<UInt8>) = (this.id, this.docKeyInfo)
        return (docPair, metaPair, fmtPair, keyPair)
    }

    /**
     * Generate a unique id string suitable for use as a document id.
     * Format: "doc-<unix_milliseconds>-<monotonic_seq>".
     * Uses millisecond timestamp combined with a static monotonic counter so that
     * even documents created within the same millisecond receive distinct ids.
     * Downstream callers (e.g. docstore) may override the id after construction.
     */
    static var seq: Int64 = 0
    static func newId(): String {
        let ts = DateTime.now().toUnixTimeStamp()
        Document.seq++
        return "doc-" + ts.toMilliseconds().toString() + "-" + Document.seq.toString()
    }
}
