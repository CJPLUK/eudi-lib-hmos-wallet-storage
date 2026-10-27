# eudi_lib_wallet_storage

EU Digital Identity Wallet 的**凭证存储层**(仓颉 / HarmonyOS),移植自欧盟委员会官方参考实现 [eudi-lib-ios-wallet-storage](https://github.com/eu-digital-identity-wallet/eudi-lib-ios-wallet-storage)。

> iOS 用 Keychain 存文档与密钥;鸿蒙无 Keychain drop-in,故**文档 blob → 加密 RDB(RelationalStore)**、**密钥 → HUKS(UniversalKeystoreKit)**。

## 功能(3 子域)

| 子包 | 能力 | 实现策略 |
|---|---|---|
| **types** | `Document`(存储文档模型,UUID 风格唯一 id)、`IssueRequest`、`DocumentStatus`/`SavedKeyChainDataType`/`DocDataFormat` 枚举、`StorageError`;消费 mdoc-data-model 凭证类型 | reimplement |
| **keystore** | `SecureKeyStorage` 接口(复用上游 mdoc-data-model 接口)+ `HuksSecureKeyStorage`:HUKS AES-256-CBC 包裹密钥(SecureRandom 随机 IV)、密钥信息/数据 blob CBOR 序列化加密存储 | wrap_platform → HUKS |
| **docstore** | `DataStorageService` 接口(loadDocument/loadDocuments(status)/saveDocument/deleteDocument(s)/loadDocumentMetadata/deleteDocumentCredential)+ `RdbStorageService`:加密 RDB(`StoreConfig encrypt:true`,SQLCipher 静态加密),DOCUMENTS+CREDENTIALS 双表 | wrap_platform → 加密 RDB |

## 仓库结构(团队统一 cbor 形态)

```
eudi_lib_wallet_storage/
├── eudi_cjwallet_storage/          ← HAR 模块(pkg ohos_app_cangjie_eudi_cjwallet_storage)
│   ├── src/main/cangjie/index.cj   ← runWalletStorageDemo()(密钥往返 + 加密 RDB 文档 CRUD + 多文档回归守卫)
│   └── src/main/cangjie/storage/   ← types / keystore / docstore
├── entry/                         ← 测试面板 HAP(27 个设备 E2E + "Run Wallet-Storage Demo")
│   └── libs/{stdx, arm64-v8a}/    ← stdx 1.1.3.1 + OpenSSL/libsecurec 运行时件
└── third_party/                   ← (gitignored)上游锁定 clone,见下
```

## 上游依赖(首次构建前 — 扁平 third_party,含二级传递)

依赖 mdoc-data-model / core-crypto / cbor;mdoc-data-model 又依赖 cbor+core-crypto(二级传递)。解法:third_party **平铺全闭包**,改写 mdoc-data-model clone 的相对路径上跳一层(详见团队 lib-packaging-spec §9):

```bash
cd third_party
git clone https://github.com/CJPLUK/eudi-lib-hmos-mdoc-data-model && (cd eudi_lib_mdoc_data_model && git checkout v0.1.0)
git clone https://github.com/CJPLUK/eudi-lib-hmos-core-crypto           && (cd eudi_lib_core_crypto && git checkout v0.1.0)
git clone https://github.com/CJPLUK/eudi-lib-hmos-cbor            && (cd eudi_lib_cbor && git checkout v0.1.0)
sed -i '' 's|\.\./third_party/|../../|g' eudi_lib_mdoc_data_model/eudi_cjmdoc_data_model/cjpm.toml
```

> **stdx 版本要求 1.1.3.1**(110 文件,含 `stdx.crypto.common`);1.1.0-beta 会因 DerBlob 包迁移导致上游编译失败(见 lib-packaging-spec §10)。

## 下游消费(cjpm path 依赖)

```toml
[dependencies]
  [dependencies.ohos_app_cangjie_eudi_cjwallet_storage]
    path = "../third_party/eudi_lib_wallet_storage/eudi_cjwallet_storage"
```

```cangjie
import ohos_app_cangjie_eudi_cjwallet_storage.storage.types.*
import ohos_app_cangjie_eudi_cjwallet_storage.storage.keystore.*
import ohos_app_cangjie_eudi_cjwallet_storage.storage.docstore.*
```

## 构建与验证

构建命令、环境变量、运行时件要求同团队 lib-packaging-spec,参照 [eudi_lib_mdoc_security](https://github.com/CJPLUK/eudi-lib-hmos-mdoc-security) README 的"构建"一节。

- **27 个设备端 E2E**(`entry/.../unittest_engine.cj`,OpenHarmonyTestRunner,真机):types 10 + HUKS 密钥 6 + 加密 RDB 文档 CRUD 7 + demo 4。
- 测试面板:app 内点 **Run Wallet-Storage Demo** → `OK: doc_crud=PASS, key_roundtrip=PASS, encrypted_rdb=on, multidoc_byStatus=PASS, ids_distinct=true, ...`(密钥往返 + 加密 RDB CRUD + 多文档唯一 id 回归守卫,真机实证)。

> **凭证唯一 id**:`Document.newId()` 用毫秒时间戳 + 进程内单调计数器,保证同一刻创建的多个文档拿到不同 id(避免主键冲突覆盖 / 数据丢失)。

## License

[Apache License 2.0](LICENSE)。本项目为 eudi-lib-ios-wallet-storage(© European Commission)的衍生移植,归属与捆绑件声明见 [NOTICE](NOTICE)。
