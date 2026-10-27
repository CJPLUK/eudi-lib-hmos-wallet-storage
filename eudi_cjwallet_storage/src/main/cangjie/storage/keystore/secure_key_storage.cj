/*
 * secure_key_storage.cj
 *
 * Re-exports the SecureKeyStorage interface from upstream mdoc-data-model so
 * that downstream consumers (ws_docstore) can import it from this module's
 * package without a direct dependency on mdoc-data-model.
 *
 * The interface is defined in:
 *   ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.SecureKeyStorage
 *
 * iOS reference:
 *   Sources/MdocDataModel18013/SecureArea/SecureKeyStorage.swift
 *
 * Package: ohos_app_cangjie_eudi_cjwallet_storage.storage.keystore
 */
package ohos_app_cangjie_eudi_cjwallet_storage.storage.keystore

import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.SecureKeyStorage
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.securearea.KeyOptions

/*
 * Re-export SecureKeyStorage as a public type alias so downstream callers can
 * simply import this package:
 *
 *   import ohos_app_cangjie_eudi_cjwallet_storage.storage.keystore.*
 *
 * and obtain both the interface and the concrete implementation from one place.
 */
public type WalletSecureKeyStorage = SecureKeyStorage
public type WalletKeyOptions = KeyOptions
