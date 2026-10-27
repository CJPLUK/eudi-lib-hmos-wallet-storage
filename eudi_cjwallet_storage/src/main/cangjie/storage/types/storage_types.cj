/*
 * storage_types.cj
 *
 * Wallet-storage enumerations and error type.
 * Mirrors iOS Sources/WalletStorage/Enumerations.swift and StorageError.swift.
 *
 * iOS references:
 *   Sources/WalletStorage/Enumerations.swift — DocumentStatus, SavedKeyChainDataType
 *   Sources/WalletStorage/StorageError.swift  — StorageError
 *   Sources/WalletStorage/IssueRequest.swift  — IssueRequest
 */
package ohos_app_cangjie_eudi_cjwallet_storage.storage.types

import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.KeyOptions
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.CredentialOptions

/* ====================================================================== */
/* DocumentStatus                                                          */
/* ====================================================================== */

/**
 * Current lifecycle status of a wallet document.
 * Mirrors iOS DocumentStatus enum (case values align with rawValue strings).
 */
public enum DocumentStatus {
    | Issued
    | Deferred
    | Pending

    /** Raw string value matching iOS rawValue. */
    public func rawValue(): String {
        match (this) {
            case Issued => return "issued"
            case Deferred => return "deferred"
            case Pending => return "pending"
        }
    }

    /** Construct from raw string; returns None for unknown values. */
    public static func fromRaw(raw: String): ?DocumentStatus {
        match (raw) {
            case "issued" => return Some(DocumentStatus.Issued)
            case "deferred" => return Some(DocumentStatus.Deferred)
            case "pending" => return Some(DocumentStatus.Pending)
            case _ => return None
        }
    }

    /** Whether this document is in deferred issuance state. */
    public func isDeferred(): Bool {
        match (this) {
            case Deferred => return true
            case _ => return false
        }
    }
}

/* ====================================================================== */
/* SavedKeyChainDataType                                                   */
/* ====================================================================== */

/**
 * Type of data item saved in key storage.
 * Raw value must be a 4-length string due to keychain requirements (iOS parity).
 * Mirrors iOS SavedKeyChainDataType enum.
 */
public enum SavedKeyChainDataType {
    | Doc
    | DocPresent
    | Key
    | KeyInfo

    /** Raw string value matching iOS rawValue (4-char strings). */
    public func rawValue(): String {
        match (this) {
            case Doc => return "sdoc"
            case DocPresent => return "pdoc"
            case Key => return "skey"
            case KeyInfo => return "skei"
        }
    }

    /** Construct from raw string; returns None for unknown values. */
    public static func fromRaw(raw: String): ?SavedKeyChainDataType {
        match (raw) {
            case "sdoc" => return Some(SavedKeyChainDataType.Doc)
            case "pdoc" => return Some(SavedKeyChainDataType.DocPresent)
            case "skey" => return Some(SavedKeyChainDataType.Key)
            case "skei" => return Some(SavedKeyChainDataType.KeyInfo)
            case _ => return None
        }
    }
}

/* ====================================================================== */
/* StorageError                                                            */
/* ====================================================================== */

/**
 * Error type for wallet storage operations.
 * Mirrors iOS StorageError struct (LocalizedError).
 *
 * Cangjie constraint (R-105): Exception subclass must NOT re-declare `message`.
 * The description and code are stored in separate fields; message is surfaced
 * via the inherited Exception.message property (set by super(description)).
 */
public class StorageError <: Exception {
    /** Human-readable error description. */
    public let description: String
    /** Numeric error code (0 = general error). */
    public let code: Int64

    public init(description: String, code: Int64) {
        super(description)
        this.description = description
        this.code = code
    }

    /** Convenience constructor with default code 0. */
    public init(description: String) {
        super(description)
        this.description = description
        this.code = 0
    }
}

/* ====================================================================== */
/* IssueRequest                                                            */
/* ====================================================================== */

/**
 * Credential issuance request carrying key and credential options.
 * Mirrors iOS IssueRequest struct (Sources/WalletStorage/IssueRequest.swift).
 *
 * The iOS version references SecureArea (an actor) and holds a secureArea
 * instance at construction time.  In this Cangjie storage-layer implementation,
 * IssueRequest is a pure value holder; the SecureArea lookup is deferred to the
 * keystore layer (ws_keystore), which has access to SecureAreaRegistry.
 */
public class IssueRequest {
    /** Key identifier (UUID string). */
    public let id: String
    /** Credential options controlling batch size and usage policy. */
    public let credentialOptions: CredentialOptions
    /** Optional key creation options (curve, secure area name, …). */
    public var keyOptions: ?KeyOptions

    public init(id: String, credentialOptions: CredentialOptions, keyOptions: ?KeyOptions) {
        this.id = id
        this.credentialOptions = credentialOptions
        this.keyOptions = keyOptions
    }

    /** Convenience constructor with no key options. */
    public init(id: String, credentialOptions: CredentialOptions) {
        this.id = id
        this.credentialOptions = credentialOptions
        this.keyOptions = None
    }

    /** Name of the secure area specified in keyOptions, or None if not set. */
    public func secureAreaName(): ?String {
        match (this.keyOptions) {
            case Some(ko) => return ko.secureAreaName
            case None => return None
        }
    }
}
