/*
 * huks_secure_key_storage.cj
 *
 * HuksSecureKeyStorage — HUKS-backed implementation of SecureKeyStorage.
 *
 * Design rationale (iOS Keychain → HUKS + file store mapping):
 *
 *   iOS stores key-info (public key metadata) and key-data (raw key bytes)
 *   as Keychain items keyed by serviceName+id.  On HarmonyOS the mapping is:
 *
 *     Wrapping key (DEK):
 *       A per-serviceName AES-256 key is generated inside HUKS under alias
 *       "<serviceName>_wrap".  This key never leaves HUKS.
 *
 *     Metadata / data blob storage:
 *       Each dict (HashMap<String, Array<UInt8>>) is CBOR-serialised, then
 *       AES-256-CBC encrypted using the wrapping key via HUKS init/finish
 *       sessions.  A fresh 16-byte cryptographically-secure random IV is
 *       generated per-encryption call via stdx.crypto.crypto.SecureRandom.
 *       The resulting (16-byte IV || ciphertext) is persisted as a flat
 *       binary file under `storageDir`:
 *
 *         key-info  : <storageDir>/<serviceName>_info_<id>
 *         key-data  : <storageDir>/<serviceName>_data_<id>_<index>
 *
 *       Using std.fs.File for file I/O avoids the requirement for a
 *       UIAbilityContext at the HAR level; callers pass in the app filesDir
 *       path at construction time.
 *
 * Alias naming (max 128 bytes per HUKS contract):
 *   wrapping key : "<serviceName>_wrap"
 *
 * File naming (under storageDir):
 *   key-info     : "<serviceName>_info_<id>"
 *   key-data[i]  : "<serviceName>_data_<id>_<i>"
 *
 * Thread safety: not internally synchronised; callers must serialise if
 * multiple threads share one instance (mirrors iOS actor isolation model).
 *
 * iOS reference:
 *   Sources/WalletStorage/KeyChainSecureKeyStorage.swift
 * mdoc-data-model upstream interface:
 *   ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.SecureKeyStorage
 */
package ohos_app_cangjie_eudi_cjwallet_storage.storage.keystore

import std.collection.HashMap
import std.collection.ArrayList
import std.fs.File
import std.fs.exists
import std.fs.remove
import std.fs.Path
import kit.UniversalKeystoreKit.*
import kit.PerformanceAnalysisKit.Hilog
import stdx.crypto.crypto.SecureRandom
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.SecureKeyStorage
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.KeyOptions
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.SecureAreaError
import ohos_app_cangjie_eudi_cjcbor.cbor.CborValue
import ohos_app_cangjie_eudi_cjcbor.cbor.decodeCbor

/* ========================================================================= */
/* Internal helpers — dict serialisation                                      */
/* ========================================================================= */

/*
 * Serialise HashMap<String, Array<UInt8>> to CBOR bytes.
 * CBOR layout: Map[ TextString(key) -> ByteString(value), ... ]
 */
func serializeDict(dict: HashMap<String, Array<UInt8>>): Array<UInt8> {
    let pairs = ArrayList<(CborValue, CborValue)>()
    for ((k, v) in dict) {
        pairs.add((CborValue.TextStringVal(k), CborValue.ByteStringVal(v)))
    }
    return CborValue.MapVal(pairs).encode()
}

/*
 * Deserialise CBOR bytes back to HashMap<String, Array<UInt8>>.
 * Returns empty map on malformed input rather than throwing, to mirror iOS
 * Keychain behaviour of returning an empty dict on decode errors.
 */
func deserializeDict(bytes: Array<UInt8>): HashMap<String, Array<UInt8>> {
    let result = HashMap<String, Array<UInt8>>()
    try {
        let cbor = decodeCbor(bytes)
        match (cbor) {
            case CborValue.MapVal(pairs) =>
                for ((k, v) in pairs) {
                    match ((k, v)) {
                        case (CborValue.TextStringVal(key), CborValue.ByteStringVal(val)) =>
                            result[key] = val
                        case _ => ()
                    }
                }
            case _ => ()
        }
    } catch (_: Exception) {
        ()
    }
    return result
}

/* ========================================================================= */
/* Internal helpers — HUKS AES-256-CBC encrypt / decrypt                     */
/* ========================================================================= */

/*
 * Build the HUKS properties array for AES-256-CBC operations.
 * `purpose` is HUKS_KEY_PURPOSE_ENCRYPT or HUKS_KEY_PURPOSE_DECRYPT.
 */
func buildAesCbcProperties(purpose: UInt32, iv: Array<UInt8>): Array<HuksParam> {
    return [
        HuksParam(
            HuksTag.HUKS_TAG_ALGORITHM,
            HuksParamValue.Uint32Value(HuksKeyAlg.HUKS_ALG_AES)
        ),
        HuksParam(
            HuksTag.HUKS_TAG_KEY_SIZE,
            HuksParamValue.Uint32Value(HuksKeySize.HUKS_AES_KEY_SIZE_256)
        ),
        HuksParam(
            HuksTag.HUKS_TAG_PURPOSE,
            HuksParamValue.Uint32Value(purpose)
        ),
        HuksParam(
            HuksTag.HUKS_TAG_PADDING,
            HuksParamValue.Uint32Value(HuksKeyPadding.HUKS_PADDING_PKCS7)
        ),
        HuksParam(
            HuksTag.HUKS_TAG_BLOCK_MODE,
            HuksParamValue.Uint32Value(HuksCipherMode.HUKS_MODE_CBC)
        ),
        HuksParam(
            HuksTag.HUKS_TAG_IV,
            HuksParamValue.BytesValue(iv)
        )
    ]
}

/*
 * AES-256-CBC encrypt `plaintext` using the HUKS key at `wrapAlias`.
 * Returns IV(16) || ciphertext.
 * A fresh 16-byte cryptographically-secure random IV is generated for each
 * call via stdx.crypto.crypto.SecureRandom (priv: true), ensuring that
 * identical plaintexts produce distinct ciphertexts.
 */
func huksAesEncrypt(wrapAlias: String, plaintext: Array<UInt8>): Array<UInt8> {
    let secureRandom = SecureRandom(priv: true)
    let iv: Array<UInt8> = secureRandom.nextBytes(16)
    let props = buildAesCbcProperties(HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, iv)
    let session = initSession(wrapAlias, HuksOptions(properties: props, inData: Array<UInt8>()))
    let result = finishSession(session.handle, HuksOptions(properties: props, inData: plaintext))
    let cipherBytes: Array<UInt8> = match (result) {
        case Some(b) => b.toArray()
        case None => throw SecureAreaError("huksAesEncrypt: finishSession returned no data")
    }
    let output = ArrayList<UInt8>()
    for (b in iv) { output.add(b) }
    for (b in cipherBytes) { output.add(b) }
    return output.toArray()
}

/*
 * AES-256-CBC decrypt `ivAndCipher` using the HUKS key at `wrapAlias`.
 * `ivAndCipher` must be IV(16) || ciphertext as produced by huksAesEncrypt.
 */
func huksAesDecrypt(wrapAlias: String, ivAndCipher: Array<UInt8>): Array<UInt8> {
    if (ivAndCipher.size < 17) {
        throw SecureAreaError("huksAesDecrypt: input too short (need IV + at least 1 byte)")
    }
    let iv = Array<UInt8>(16, {i => ivAndCipher[i]})
    let ciphertext = Array<UInt8>(ivAndCipher.size - 16, {i => ivAndCipher[i + 16]})
    let props = buildAesCbcProperties(HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, iv)
    let session = initSession(wrapAlias, HuksOptions(properties: props, inData: Array<UInt8>()))
    let result = finishSession(session.handle, HuksOptions(properties: props, inData: ciphertext))
    match (result) {
        case Some(b) => return b.toArray()
        case None => throw SecureAreaError("huksAesDecrypt: finishSession returned no data")
    }
}

/* ========================================================================= */
/* Internal helpers — file-based encrypted blob persistence                  */
/* ========================================================================= */

/*
 * Persist `plainBytes` to file at `filePath`, encrypted with `wrapAlias`.
 * Overwrites any existing file at that path.
 */
func storeBlob(wrapAlias: String, filePath: String, plainBytes: Array<UInt8>): Unit {
    let encBytes = huksAesEncrypt(wrapAlias, plainBytes)
    let p = Path(filePath)
    if (exists(p)) {
        remove(p)
    }
    File.writeTo(p, encBytes)
}

/*
 * Load and decrypt bytes from `filePath`.
 * Returns None if the file does not exist.
 */
func loadBlob(wrapAlias: String, filePath: String): ?Array<UInt8> {
    let p = Path(filePath)
    if (!exists(p)) {
        return None
    }
    let encBytes = File.readFrom(p)
    return Some(huksAesDecrypt(wrapAlias, encBytes))
}

func wrapKeyGenerateProperties(neverExport: Bool): Array<HuksParam> {
    let list = ArrayList<HuksParam>()
    list.add(HuksParam(
        HuksTag.HUKS_TAG_ALGORITHM,
        HuksParamValue.Uint32Value(HuksKeyAlg.HUKS_ALG_AES)
    ))
    list.add(HuksParam(
        HuksTag.HUKS_TAG_KEY_SIZE,
        HuksParamValue.Uint32Value(HuksKeySize.HUKS_AES_KEY_SIZE_256)
    ))
    list.add(HuksParam(
        HuksTag.HUKS_TAG_PURPOSE,
        HuksParamValue.Uint32Value(
            HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
        )
    ))
    list.add(HuksParam(
        HuksTag.HUKS_TAG_PADDING,
        HuksParamValue.Uint32Value(HuksKeyPadding.HUKS_PADDING_PKCS7)
    ))
    list.add(HuksParam(
        HuksTag.HUKS_TAG_BLOCK_MODE,
        HuksParamValue.Uint32Value(HuksCipherMode.HUKS_MODE_CBC)
    ))
    if (neverExport) {
        list.add(HuksParam(
            HuksTag.HUKS_TAG_KEY_STORAGE_FLAG,
            HuksParamValue.Uint32Value(HuksKeyStorageType.HUKS_STORAGE_ONLY_USED_IN_HUKS)
        ))
    }
    return list.toArray()
}

func tryDeleteHuksAlias(alias: String): Unit {
    try {
        deleteKeyItem(alias, HuksOptions())
    } catch (_: Exception) {
        ()
    }
}

func generateWrapKey(alias: String): Unit {
    // Never-export wrap key at the HUKS default (DE) storage level so
    // hasKeyItem / encrypt / decrypt keep using empty HuksOptions.
    try {
        generateKeyItem(
            alias,
            HuksOptions(
                properties: wrapKeyGenerateProperties(true),
                inData: Array<UInt8>()
            )
        )
        Hilog.info(0, "HuksStorage", "wrap key generated alias=" + alias + " neverExport=1")
        return
    } catch (eNe: Exception) {
        tryDeleteHuksAlias(alias)
        Hilog.info(0, "HuksStorage", "wrap key neverExport failed alias=" + alias + " " + eNe.message)
    }
    generateKeyItem(
        alias,
        HuksOptions(
            properties: wrapKeyGenerateProperties(false),
            inData: Array<UInt8>()
        )
    )
    Hilog.info(0, "HuksStorage", "wrap key generated alias=" + alias + " neverExport=0")
}

/* ========================================================================= */
/* HuksSecureKeyStorage                                                       */
/* ========================================================================= */

/**
 * HUKS-backed SecureKeyStorage implementation.
 *
 * Uses:
 *   - A per-serviceName AES-256 wrapping key inside HUKS (generated lazily)
 *   - HUKS AES-256-CBC init/finish sessions for encrypt/decrypt
 *   - std.fs.File for encrypted blob persistence (no UIAbilityContext needed)
 *   - CBOR serialisation (via ohos_app_cangjie_eudi_cjcbor) for dict encoding
 *
 * Construction:
 *   HuksSecureKeyStorage(serviceName: "eudi_wallet", storageDir: context.filesDir)
 *
 * iOS mirror: KeyChainSecureKeyStorage (actor)
 */
public class HuksSecureKeyStorage <: SecureKeyStorage {
    /** Service name used as alias prefix; mirrors iOS serviceName. */
    public let serviceName: String

    /**
     * Absolute path to the directory where encrypted metadata blobs are stored.
     * Typically `context.filesDir` from a UIAbility.
     * Must exist before any write operations are called.
     */
    public let storageDir: String

    /** HUKS alias for the AES-256 wrapping / data-encryption key. */
    private let wrapAlias: String

    /**
     * Create a HuksSecureKeyStorage.
     *
     * - serviceName: prefix for all HUKS aliases and file names; must be a
     *   valid filename component (no path separators).
     * - storageDir: absolute path to the directory where encrypted blobs
     *   should be stored.  The directory must already exist.
     */
    public init(serviceName: String, storageDir: String) {
        this.serviceName = serviceName
        this.storageDir = storageDir
        this.wrapAlias = serviceName + "_wrap"
    }

    /* ---------------------------------------------------------------------- */
    /* Private helpers                                                         */
    /* ---------------------------------------------------------------------- */

    /** Ensure the wrapping AES-256 key exists in HUKS; generate if missing. */
    private func ensureWrapKey(): Unit {
        if (!hasKeyItem(this.wrapAlias, HuksOptions())) {
            generateWrapKey(this.wrapAlias)
        }
    }

    /** Build the file path for key-info metadata of the given document id. */
    private func infoPath(id: String): String {
        return this.storageDir + "/" + this.serviceName + "_info_" + id
    }

    /** Build the file path for key-data at the given batch index. */
    private func dataPath(id: String, index: Int64): String {
        return this.storageDir + "/" + this.serviceName + "_data_" + id + "_" + index.toString()
    }

    /* ---------------------------------------------------------------------- */
    /* SecureKeyStorage interface                                              */
    /* ---------------------------------------------------------------------- */

    /**
     * Read public key metadata for the given document id.
     * Returns an empty map if no key-info has been written yet.
     *
     * Mirrors iOS KeyChainSecureKeyStorage.readKeyInfo(id:).
     */
    public func readKeyInfo(id: String): HashMap<String, Array<UInt8>> {
        this.ensureWrapKey()
        match (loadBlob(this.wrapAlias, this.infoPath(id))) {
            case Some(bytes) => return deserializeDict(bytes)
            case None => return HashMap<String, Array<UInt8>>()
        }
    }

    /**
     * Read key material at the given batch index.
     * Returns an empty map if no data has been written at this index.
     *
     * Mirrors iOS KeyChainSecureKeyStorage.readKeyData(id:index:).
     */
    public func readKeyData(id: String, index: Int64): HashMap<String, Array<UInt8>> {
        this.ensureWrapKey()
        match (loadBlob(this.wrapAlias, this.dataPath(id, index))) {
            case Some(bytes) => return deserializeDict(bytes)
            case None => return HashMap<String, Array<UInt8>>()
        }
    }

    /**
     * Persist public key metadata for the given document id.
     *
     * Mirrors iOS KeyChainSecureKeyStorage.writeKeyInfo(id:dict:).
     */
    public func writeKeyInfo(id: String, dict: HashMap<String, Array<UInt8>>): Unit {
        this.ensureWrapKey()
        let bytes = serializeDict(dict)
        storeBlob(this.wrapAlias, this.infoPath(id), bytes)
    }

    /**
     * Persist a batch of key-data entries.
     *
     * Each entry in `dicts` is stored at index startIndex + i.
     * `keyOptions` is accepted for interface compatibility; the wrapping key
     * configuration is fixed at AES-256-CBC and is not influenced by it.
     *
     * Mirrors iOS KeyChainSecureKeyStorage.writeKeyDataBatch(id:startIndex:dicts:keyOptions:).
     */
    public func writeKeyDataBatch(
        id: String,
        startIndex: Int64,
        dicts: Array<HashMap<String, Array<UInt8>>>,
        keyOptions: ?KeyOptions
    ): Unit {
        if (dicts.size == 0) {
            return
        }
        this.ensureWrapKey()
        var i: Int64 = 0
        while (i < dicts.size) {
            let bytes = serializeDict(dicts[i])
            storeBlob(this.wrapAlias, this.dataPath(id, startIndex + i), bytes)
            i++
        }
    }

    /**
     * Delete a slice of key-data entries.
     *
     * Deletes entries at indices startIndex … startIndex+batchSize-1.
     * No-op for entries that do not exist.
     *
     * Mirrors iOS KeyChainSecureKeyStorage.deleteKeyBatch(id:startIndex:batchSize:).
     */
    public func deleteKeyBatch(id: String, startIndex: Int64, batchSize: Int64): Unit {
        var i: Int64 = 0
        while (i < batchSize) {
            let p = Path(this.dataPath(id, startIndex + i))
            if (exists(p)) {
                remove(p)
            }
            i++
        }
    }

    /**
     * Delete key metadata for the given document id.
     *
     * Mirrors iOS KeyChainSecureKeyStorage.deleteKeyInfo(id:).
     */
    public func deleteKeyInfo(id: String): Unit {
        let p = Path(this.infoPath(id))
        if (exists(p)) {
            remove(p)
        }
    }

    /**
     * Delete the wrapping AES-256 key from HUKS.
     *
     * After calling this method all previously encrypted blobs become
     * permanently unreadable.  Call this only when completely wiping the
     * key store (e.g. during account deletion / factory reset).
     */
    public func deleteWrapKey(): Unit {
        if (hasKeyItem(this.wrapAlias, HuksOptions())) {
            deleteKeyItem(this.wrapAlias, HuksOptions())
        }
    }
}
