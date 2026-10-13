package ohos_app_cangjie_entry.services

import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

// ==================== Missing SecureValueType TL constructors ====================
// These 6 types are defined here (services package) because TLMethods.cj only
// contains the 7 basic types. iOS SecureIdValueKey has 13 total types.

/**
 * secureValueTypeInternalPassport#99a48f23 = SecureValueType
 */
public class SecureValueTypeInternalPassport <: TLObject {
    public func getConstructorId(): UInt32 { return 0x99a48f23 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * secureValueTypeUtilityBill#fc36954e = SecureValueType
 */
public class SecureValueTypeUtilityBill <: TLObject {
    public func getConstructorId(): UInt32 { return 0xfc36954e }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * secureValueTypeBankStatement#89137c0d = SecureValueType
 */
public class SecureValueTypeBankStatement <: TLObject {
    public func getConstructorId(): UInt32 { return 0x89137c0d }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * secureValueTypeRentalAgreement#8b883488 = SecureValueType
 */
public class SecureValueTypeRentalAgreement <: TLObject {
    public func getConstructorId(): UInt32 { return 0x8b883488 }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * secureValueTypePassportRegistration#99e3806a = SecureValueType
 */
public class SecureValueTypePassportRegistration <: TLObject {
    public func getConstructorId(): UInt32 { return 0x99e3806a }
    public func serialize(serializer: TLSerializer) {}
}

/**
 * secureValueTypeTemporaryRegistration#ea02ec33 = SecureValueType
 */
public class SecureValueTypeTemporaryRegistration <: TLObject {
    public func getConstructorId(): UInt32 { return 0xea02ec33 }
    public func serialize(serializer: TLSerializer) {}
}

// ==================== SecureId Access Context ====================

/**
 * SecureIdAccessContext — 持有解密后的 secure secret 和 id
 * 对应 iOS SecureIdAccessContext { secret: Data, id: Int64 }
 * 用于后续 SecureValue 加解密操作
 *
 * 加密责任说明：SecureId 的 AES-256-CBC 加密/解密在 secret 解锁后由调用方执行。
 * accessSecureId 负责从 account.getPasswordSettings 中提取并解密 secure_secret（使用 PBKDF2-SHA512 + AES-256-CBC）。
 */
public class SecureIdAccessContext {
    public var secret: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var id: Int64 = 0
}

// ==================== Crypto helpers (mirroring iOS AccessSecureId.swift) ====================

/**
 * verifySecureSecret — 验证 secure secret 校验和
 * iOS: func verifySecureSecret(_ data: Data) -> Bool
 * 规则：所有字节之和 mod 255 == 239
 */
private func verifySecureSecret(data: Array<Byte>): Bool {
    var checksum: UInt32 = 0
    for (i in 0..data.size) {
        checksum = (checksum + UInt32(data[i])) % 255
    }
    return checksum == 239
}

/**
 * generateSecureSecretData — 生成满足校验和要求的随机 32 字节 secret
 * iOS: func generateSecureSecretData() -> Data?
 * 随机生成后调整最后字节使校验和 == 239
 */
public func generateSecureSecretData(): Array<Byte> {
    let secretData = ByteUtils.randomBytes(32)
    var checksum: UInt32 = 0
    for (i in 0..32) {
        checksum = (checksum + UInt32(secretData[i])) % 255
    }
    if (checksum != 239) {
        let needed: UInt32 = if (checksum <= 239) { 239 - checksum } else { 239 + 255 - checksum }
        secretData[31] = UInt8((UInt32(secretData[31]) + needed) % 256)
    }
    return secretData
}

/**
 * securePasswordKDF — 从密码和 PBKDF2 盐派生 48 字节密钥
 * 对应 iOS securePasswordKDF / SecurePasswordKdfAlgoSHA512
 * 输出: 32 字节 key + 16 字节 iv
 */
private func securePasswordKDF(password: String, salt: Array<Byte>): Array<Byte> {
    let passwordBytes = ByteUtils.stringToBytes(password)
    return PBKDF2SHA512.derive(passwordBytes, salt, 100000, 64)
}

// ==================== AccountGetPassword raw parse for secure_algo ====================

/**
 * 从 account.password TL 响应中提取 new_secure_algo 的 salt
 * account.password#957b50fb:
 *   flags:# has_recovery(0) has_secure_values(1) has_password(2)
 *   current_algo(2):PasswordKdfAlgo srp_B(2):bytes srp_id(2):long
 *   hint(3):string email_unconfirmed_pattern(4):string
 *   new_algo:PasswordKdfAlgo  new_secure_algo:SecurePasswordKdfAlgo  secure_random:bytes
 *   pending_reset_date(5):int  login_email_pattern(6):string
 *
 * SecurePasswordKdfAlgoSHA512#86471d92 salt:bytes = SecurePasswordKdfAlgo
 * SecurePasswordKdfAlgoUnknown#004c07dd = SecurePasswordKdfAlgo
 */
private func parseSecureAlgoSalt(data: Array<Byte>): Option<Array<Byte>> {
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()
        if (ctor != 0x957b50fb) {
            return None
        }
        let flags = d.readInt32()
        let hasPassword = (flags & 4) != 0
        if (hasPassword) {
            // current_algo: skip PasswordKdfAlgo
            let algoC = d.readUInt32()
            if (algoC == 0x3a912d4a) {
                let _ = d.readBytes()  // salt1
                let _ = d.readBytes()  // salt2
                let _ = d.readInt32()  // g
                let _ = d.readBytes()  // p
            } else if (algoC == 0xd45ab096) {
                let _ = d.readInt32()  // passwordKdfAlgoUnknown unknown-variant skip
            }
            let _ = d.readBytes()  // srp_B
            let _ = d.readInt64()  // srp_id
        }
        // hint (flags.3)
        if ((flags & 8) != 0) { let _ = d.readString() }
        // email_unconfirmed_pattern (flags.4)
        if ((flags & 16) != 0) { let _ = d.readString() }
        // new_algo: PasswordKdfAlgo (always present)
        let newAlgoC = d.readUInt32()
        if (newAlgoC == 0x3a912d4a) {
            let _ = d.readBytes()  // salt1
            let _ = d.readBytes()  // salt2
            let _ = d.readInt32()  // g
            let _ = d.readBytes()  // p
        }
        // new_secure_algo: SecurePasswordKdfAlgo (always present)
        let secureAlgoC = d.readUInt32()
        if (secureAlgoC == 0x86471d92) {
            // SecurePasswordKdfAlgoSHA512
            let salt = d.readBytes()
            return Some(salt)
        }
        return None
    } catch (e: Exception) {
        return None
    }
}

// ==================== SecureIdEngineService ====================

/**
 * SecureIdEngineService — Passport/SecureID 引擎门面
 *
 * 封装 Telegram Passport (身份验证) 相关操作：
 *   account.getAuthorizationForm / account.acceptAuthorization
 *   account.getSecureValue / account.saveSecureValue / account.deleteSecureValue
 *   account.sendVerifyPhoneCode / account.verifyPhone
 *   account.sendVerifyEmailCode / account.verifyEmail
 *   account.getPassword → accessSecureId (password unlock)
 *
 * 支持所有 13 种 iOS SecureIdValueKey 类型：
 *   personalDetails, passport, internalPassport, driversLicense, idCard,
 *   address, utilityBill, bankStatement, rentalAgreement,
 *   passportRegistration, temporaryRegistration, phone, email
 *
 * 委托 PassportService 执行大多数 TL 调用，直接处理 accessSecureId。
 * PassportPage、PassportDocumentPage 等 UI 可通过 getPassportService() 或本服务访问。
 */
public class SecureIdEngineService {
    private let passportService = getPassportService()

    /**
     * account.getAuthorizationForm — 获取 SecureId 授权表单
     * 对应 iOS: TelegramEngine.SecureId extension (via GrantSecureIdAccess.swift)
     */
    public func getAuthorizationForm(botId: Int64, scope: String, publicKey: String): Option<SecureIdAuthForm> {
        return this.passportService.getSecureIdAuthForm(botId, scope, publicKey)
    }

    /**
     * account.getSecureValue#73665bc2 — 获取指定类型的 SecureValue
     * types 应为 SecureValueType* TLObject 实例列表
     * Returns full model including encrypted data, files, plain_data.
     */
    public func getSecureValues(types: ArrayList<TLObject>): ArrayList<SecureValueFullModel> {
        return this.passportService.getSecureValues(types)
    }

    /**
     * account.getAllSecureValues#b288bc7d — 获取所有 SecureValue（无类型过滤）
     * iOS: account.getAllSecureValues in TelegramCore
     * Codegen verify: 0xb288bc7d (method), response Vector<secureValue#187fa0ca>
     */
    public func getAllSecureValues(): ArrayList<SecureValueFullModel> {
        return this.passportService.getAllSecureValues()
    }

    /**
     * account.saveSecureValue — 保存 SecureValue（加密后的 InputSecureValue 字节 + secretId）
     */
    public func saveSecureValue(value: Array<Byte>, secureSecretId: Int64): Option<SecureValueModel> {
        return this.passportService.saveSecureValue(value, secureSecretId)
    }

    /**
     * uploadSecureIdFile — encrypt and upload a Passport document file
     * iOS: TelegramCore/SecureId/UploadSecureIdFile.swift
     * Produces inputSecureFileUploaded#3334b0f0 with AES-256-CBC encryption.
     */
    public func uploadSecureIdFile(fileBytes: Array<Byte>, fileName: String, accessSecret: Array<Byte>): Option<UploadedSecureFile> {
        return this.passportService.uploadSecureIdFile(fileBytes, fileName, accessSecret)
    }

    /**
     * account.acceptAuthorization — 提交 SecureId 授权
     */
    public func acceptAuthorization(botId: Int64, scope: String, publicKey: String, credentials: Array<Byte>, valueHashes: Array<Byte>): Bool {
        return this.passportService.acceptSecureIdAuth(botId, scope, publicKey, credentials, valueHashes)
    }

    /**
     * account.deleteSecureValue — 删除 SecureValue
     */
    public func deleteSecureValue(types: ArrayList<TLObject>): Unit {
        this.passportService.deleteSecureValue(types)
    }

    /**
     * account.sendVerifyPhoneCode — 发送手机验证码 (Passport)
     */
    public func sendVerifyPhoneCode(phoneNumber: String): Option<SentCodeModel> {
        return this.passportService.sendVerifyPhoneCode(phoneNumber)
    }

    /**
     * account.verifyPhone — 确认手机验证码
     */
    public func confirmVerifyPhone(phoneCodeHash: String, code: String, phoneNumber: String): Bool {
        return this.passportService.confirmVerifyPhone(phoneCodeHash, code, phoneNumber)
    }

    /**
     * account.sendVerifyEmailCode — 发送邮箱验证码 (Passport)
     */
    public func sendVerifyEmailCode(email: String): Option<SentEmailCodeModel> {
        return this.passportService.sendVerifyEmailCode(email)
    }

    /**
     * account.verifyEmail — 确认邮箱验证码
     */
    public func confirmVerifyEmail(email: String, code: String): Bool {
        return this.passportService.confirmVerifyEmail(email, code)
    }

    /**
     * accessSecureId — 使用 Telegram 账号密码解锁 SecureId
     *
     * 对应 iOS: TelegramEngine.SecureId.accessSecureId(password:)
     *           → _internal_accessSecureId → _internal_requestTwoStepVerifiationSettings
     *
     * 流程 (对应 iOS AccessSecureId.swift:166-195 + TwoStepVerification.swift:40-88):
     *   1. account.getPasswordSettings(SRP proof) → passwordSettings#9a5c33e5
     *   2. 提取 secureSettings.secureSecretSettings#1527bcac:
     *        secureAlgo.salt, secure_secret(32 bytes 加密), secure_secret_id
     *   3. securePasswordKDF(password, secureAlgo.salt) → 48 字节
     *        key = derived[0..32], iv = derived[32..48] (16 字节, AES-CBC)
     *   4. AES256CBC.decrypt(encrypted_secret, key, iv) → decrypted secret
     *   5. verifySecureSecret(checksum == 239)
     *   6. 验证 SHA256(secret)[0..8] == secureSecretId
     *
     * iOS CryptoAES(!decrypt, key, iv, data) = AES-256-CBC (16字节 IV)
     * 参照 AccessSecureId.swift:11-17, :39-68, TwoStepVerification.swift:60-88
     *
     * 返回: Some(SecureIdAccessContext) on success, None on failure
     */
    public func accessSecureId(password: String): Option<SecureIdAccessContext> {
        let authSvc = getRealAuthService()
        // Step 1+2: account.getPasswordSettings via SRP → secureSecretSettings
        let settings = authSvc.getPasswordSettings(password)
        if (!settings.hasSecureSettings) {
            return None
        }
        let encryptedSecret = settings.secureSecret
        if (encryptedSecret.size != 32) {
            return None
        }
        let algoSalt = settings.secureAlgoSalt
        let storedSecretId = settings.secureSecretId

        // Step 3: securePasswordKDF(password, salt) → 48 bytes
        // key = derived[0..32], iv = derived[32..48] (16 bytes for AES-CBC)
        let derived = securePasswordKDF(password, algoSalt)
        let key = ByteUtils.slice(derived, 0, 32)
        let iv = ByteUtils.slice(derived, 32, 48)

        // Step 4: AES-256-CBC decrypt (iOS CryptoAES(false, key, iv, data))
        let decryptedSecret = AES256CBC.decrypt(encryptedSecret, key, iv)

        // Step 5: verify checksum
        if (!verifySecureSecret(decryptedSecret)) {
            return None
        }

        // Step 6: verify secretId matches — SHA256(secret)[0..8] as little-endian Int64
        let secretHash = SHA256.hash(decryptedSecret)
        var secretId: Int64 = 0
        for (i in 0..8) {
            secretId = secretId | (Int64(secretHash[i]) << (i * 8))
        }
        if (secretId != storedSecretId) {
            return None
        }

        let ctx = SecureIdAccessContext()
        ctx.secret = decryptedSecret
        ctx.id = secretId
        return Some(ctx)
    }

    /**
     * getPassportConfiguration — 获取 Passport RSA 公钥配置
     * 对应 iOS: help.getPassportConfig#c661ad08 hash:int = help.PassportConfig
     * help.passportConfig#a098d6af hash:int countries_langs:DataJSON = help.PassportConfig
     * help.passportConfigNotModified#2aeafa59 = help.PassportConfig
     *
     * 返回 countries_langs JSON 字符串 (若 notModified 返回空字符串)
     */
    public func getPassportConfiguration(hash: Int32): String {
        let client = getMTProtoClient()
        let req = HelpGetPassportConfig()
        req.hash = hash
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return ""
        }
        let d = TLDeserializer(data)
        try {
            let ctor = d.readUInt32()
            if (ctor == 0x2aeafa59) {
                return ""
            }
            if (ctor == 0xa098d6af) {
                let _ = d.readInt32()  // hash
                // DataJSON#7d748d04 data:string = DataJSON
                let dataJsonCtor = d.readUInt32()
                if (dataJsonCtor == 0x7d748d04) {
                    return d.readString()
                }
            }
        } catch (e: Exception) {
            return ""
        }
        return ""
    }

    /**
     * getSecureValuesByTypeNames — 便捷方法，按类型名列表获取 SecureValue
     * 覆盖全部 13 种 iOS SecureIdValueKey 类型
     */
    public func getSecureValuesByTypeNames(typeNames: ArrayList<String>): ArrayList<SecureValueFullModel> {
        let types = ArrayList<TLObject>()
        for (name in typeNames) {
            match (typeNameToTLObject(name)) {
                case Some(t) => types.add(t)
                case None => ()
            }
        }
        if (types.size == 0) {
            return ArrayList<SecureValueFullModel>()
        }
        return this.passportService.getSecureValues(types)
    }

    /**
     * deleteSecureValuesByTypeNames — 便捷方法，按类型名列表删除 SecureValue
     */
    public func deleteSecureValuesByTypeNames(typeNames: ArrayList<String>): Unit {
        let types = ArrayList<TLObject>()
        for (name in typeNames) {
            match (typeNameToTLObject(name)) {
                case Some(t) => types.add(t)
                case None => ()
            }
        }
        if (types.size > 0) {
            this.passportService.deleteSecureValue(types)
        }
    }
    /**
     * setupSecureSecret — P2-282
     *
     * 对应 iOS updateTwoStepVerificationSecureSecret():
     *   1. account.getPassword → 提取 new_secure_algo.salt
     *   2. generateSecureSecretData() → 新随机 32 字节 secret
     *   3. securePasswordKDF(password, salt) → 64 字节 key+iv
     *   4. AES-256-CBC 加密 secret
     *   5. SHA256(secret)[0..8] → secretId (little-endian Int64)
     *   6. 通过 computeCurrentPasswordSRP() 证明当前密码
     *   7. AccountUpdatePasswordSettings with setSecureSecret=true (flags.2)
     *
     * @param password 当前 2FA 密码（用于 SRP 验证 + 派生新 secret 加密密钥）
     * @return true 表示成功
     */
    public func setupSecureSecret(password: String): Bool {
        let client = getMTProtoClient()
        let req = AccountGetPassword()
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return false
        }
        // Step 1: extract new_secure_algo salt
        let saltOpt = parseSecureAlgoSalt(data)
        let algoSalt: Array<Byte>
        match (saltOpt) {
            case None => return false
            case Some(s) => algoSalt = s
        }
        // Step 2: generate new secret with valid checksum
        let secretData = generateSecureSecretData()
        // Step 3: derive key+iv via securePasswordKDF
        // key = derived[0..32], iv = derived[32..48] (16 bytes for AES-256-CBC)
        // iOS: passwordHash.subdata(in: 0..<32), passwordHash.subdata(in: 32..<48)
        let derived = securePasswordKDF(password, algoSalt)
        let key = ByteUtils.slice(derived, 0, 32)
        let iv = ByteUtils.slice(derived, 32, 48)
        // Step 4: encrypt secret with AES-256-CBC (iOS CryptoAES(true, key, iv, data))
        let encryptedSecret = AES256CBC.encrypt(secretData, key, iv)
        // Step 5: secretId = SHA256(secret)[0..8] little-endian
        let secretHash = SHA256.hash(secretData)
        var secretId: Int64 = 0
        for (i in 0..8) {
            secretId = secretId | (Int64(secretHash[i]) << (i * 8))
        }
        // Step 6: SRP proof of current password
        let authSvc = getRealAuthService()
        let srpProof = authSvc.computeCurrentPasswordSRP(password)
        // Step 7: send updatePasswordSettings with flag.2 only
        let upd = AccountUpdatePasswordSettings()
        upd.hasCurrentPassword = true
        upd.currentPasswordSRP = srpProof
        upd.setSecureSecret = true
        upd.secureAlgoSalt = algoSalt
        upd.secureSecret = encryptedSecret
        upd.secureSecretId = secretId
        let respData = client.sendRequest(upd.toBytes())
        if (respData.size < 4) {
            return false
        }
        let d = TLDeserializer(respData)
        try {
            let ctor = d.readUInt32()
            // boolTrue#997275b5
            return ctor == 0x997275b5
        } catch (e: Exception) {
            return false
        }
    }
}

// ==================== TL object factory for all 13 iOS value types ====================

/**
 * typeNameToTLObject — 将类型名字符串映射为对应的 TLObject
 * 覆盖 iOS SecureIdValueKey 全部 13 种类型
 */
public func typeNameToTLObject(typeName: String): Option<TLObject> {
    if (typeName == "personal_details") { return Some(SecureValueTypePersonalDetails()) }
    if (typeName == "passport") { return Some(SecureValueTypePassport()) }
    if (typeName == "internal_passport") { return Some(SecureValueTypeInternalPassport()) }
    if (typeName == "driver_license") { return Some(SecureValueTypeDriverLicense()) }
    if (typeName == "identity_card") { return Some(SecureValueTypeIdentityCard()) }
    if (typeName == "address") { return Some(SecureValueTypeAddress()) }
    if (typeName == "utility_bill") { return Some(SecureValueTypeUtilityBill()) }
    if (typeName == "bank_statement") { return Some(SecureValueTypeBankStatement()) }
    if (typeName == "rental_agreement") { return Some(SecureValueTypeRentalAgreement()) }
    if (typeName == "passport_registration") { return Some(SecureValueTypePassportRegistration()) }
    if (typeName == "temporary_registration") { return Some(SecureValueTypeTemporaryRegistration()) }
    if (typeName == "phone") { return Some(SecureValueTypePhone()) }
    if (typeName == "email") { return Some(SecureValueTypeEmail()) }
    return None
}

/**
 * secureValueTypeConstructorToName — TL 构造器 ID → 类型名字符串
 * 覆盖全部 13 种类型
 */
public func secureValueTypeConstructorToName(ctor: UInt32): String {
    if (ctor == 0x9d2a81e3) { return "personal_details" }
    if (ctor == 0x3dac6a00) { return "passport" }
    if (ctor == 0x99a48f23) { return "internal_passport" }
    if (ctor == 0x06e42544) { return "driver_license" }
    if (ctor == 0xa0d0744b) { return "identity_card" }
    if (ctor == 0xcbe31e26) { return "address" }
    if (ctor == 0xfc36954e) { return "utility_bill" }
    if (ctor == 0x89137c0d) { return "bank_statement" }
    if (ctor == 0x8b883488) { return "rental_agreement" }
    if (ctor == 0x99e3806a) { return "passport_registration" }
    if (ctor == 0xea02ec33) { return "temporary_registration" }
    if (ctor == 0xb320aadb) { return "phone" }
    if (ctor == 0x8e3ca7ee) { return "email" }
    return "unknown"
}

// ==================== TL helper: parse secure_random from account.password ====================

/**
 * parseSecureRandom — 从 account.password#957b50fb 中解析 secure_random 字段
 * secure_random 紧跟在 new_secure_algo 之后
 */
private func parseSecureRandom(data: Array<Byte>): Array<Byte> {
    let d = TLDeserializer(data)
    try {
        let ctor = d.readUInt32()
        if (ctor != 0x957b50fb) {
            return Array<Byte>(0, repeat: 0)
        }
        let flags = d.readInt32()
        let hasPassword = (flags & 4) != 0
        if (hasPassword) {
            let algoC = d.readUInt32()
            if (algoC == 0x3a912d4a) {
                let _ = d.readBytes()
                let _ = d.readBytes()
                let _ = d.readInt32()
                let _ = d.readBytes()
            }
            let _ = d.readBytes()
            let _ = d.readInt64()
        }
        if ((flags & 8) != 0) { let _ = d.readString() }
        if ((flags & 16) != 0) { let _ = d.readString() }
        // new_algo
        let newAlgoC = d.readUInt32()
        if (newAlgoC == 0x3a912d4a) {
            let _ = d.readBytes()
            let _ = d.readBytes()
            let _ = d.readInt32()
            let _ = d.readBytes()
        }
        // new_secure_algo
        let secureAlgoC = d.readUInt32()
        if (secureAlgoC == 0x86471d92) {
            let _ = d.readBytes()  // salt (already read in parseSecureAlgoSalt)
        }
        // secure_random (always present)
        return d.readBytes()
    } catch (e: Exception) {
        return Array<Byte>(0, repeat: 0)
    }
}

// ==================== HelpGetPassportConfig TL method ====================

/**
 * help.getPassportConfig#c661ad08 hash:int = help.PassportConfig
 */
public class HelpGetPassportConfig <: TLObject {
    public var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xc661ad08 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

// ==================== Singleton accessor ====================

private var _secureIdEngineInstance: Option<SecureIdEngineService> = None

public func getSecureIdEngineService(): SecureIdEngineService {
    match (_secureIdEngineInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SecureIdEngineService()
            _secureIdEngineInstance = Some(inst)
            return inst
    }
}
