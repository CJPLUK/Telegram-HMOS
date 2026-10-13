package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import stdx.crypto.digest.MD5
import stdx.encoding.hex.toHexString

/**
 * Passport (SecureId) 服务
 *
 * 封装 Telegram Passport 相关 TL 方法调用
 * 使用 getMTProtoClient() 进行 API 调用
 */
public class SecureIdRequiredType {
    public var typeName: String = ""
    public var isProvided: Bool = false
    // Flags parsed from secureRequiredType TL (oneOf group, selfie/translation requirements)
    public var selfieRequired: Bool = false
    public var translationRequired: Bool = false
    public var isOneOfGroup: Bool = false
    public var oneOfOptions: ArrayList<String> = ArrayList<String>()
    // Provided value hash (SHA256 of the plaintext data — the 'opaqueHash' in iOS)
    public var valueHash: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * SecureFileRef — represents one secure file within a SecureValue
 * Corresponds to secureFile#e0277a62 fields (id, access_hash, size, dc_id, date, file_hash, secret)
 */
public class SecureFileRef {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var size: Int64 = 0
    public var dcId: Int32 = 0
    public var date: Int32 = 0
    public var fileHash: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var secret: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * SecureValueFullModel — full secureValue#187fa0ca parse result
 * iOS: SecureIdValue (type, data, files, frontSideFile, backSideFile, selfieFile,
 *                     translationFiles, plainData, hash)
 */
public class SecureValueFullModel {
    public var typeName: String = ""
    public var encryptedData: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dataHash: Array<Byte> = Array<Byte>(0, repeat: 0)
    // encryptedSecret = AES-CBC(valueSecret, SHA512(accessCtx.secret||dataHash)[0..32+16])
    // Needed by P2-283 grantSecureIdAccessFull to decrypt and include in credentials JSON.
    public var encryptedSecret: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var frontSideFile: Option<SecureFileRef> = None
    public var backSideFile: Option<SecureFileRef> = None
    public var selfieFile: Option<SecureFileRef> = None
    public var translationFiles: ArrayList<SecureFileRef> = ArrayList<SecureFileRef>()
    public var files: ArrayList<SecureFileRef> = ArrayList<SecureFileRef>()
    public var plainDataType: String = ""
    public var plainDataValue: String = ""
    public var hash: Array<Byte> = Array<Byte>(0, repeat: 0)
}

public class SecureIdAuthForm {
    public var botId: Int64 = 0
    public var scope: String = ""
    public var requiredTypes: ArrayList<SecureIdRequiredType> = ArrayList<SecureIdRequiredType>()
    public var values: ArrayList<SecureValueFullModel> = ArrayList<SecureValueFullModel>()
    public var privacyPolicyUrl: String = ""
    public var botName: String = ""
    // Filled by caller before passing to PassportPage
    public var callbackUrl: String = ""
    public var opaqueNonce: String = ""
    public var opaquePayload: String = ""
    public var publicKey: String = ""
}

public class SecureValueModel {
    public var typeName: String = ""
    public var hash: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * UploadedSecureFile — result of a successful uploadSecureIdFile call
 * Contains the InputSecureFileUploaded TL object and file metadata.
 */
public class UploadedSecureFile {
    public var inputSecureFile: InputSecureFileUploaded = InputSecureFileUploaded()
    public var fileHash: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var encryptedSecret: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * prependPaddingPassport — iOS SecureIdPadding.swift paddedSecureIdData()
 * Layout: [paddingCount:1 byte][random padding: paddingCount-1 bytes][data]
 * Total length is a multiple of 16.
 * paddingCount is in range [47, 254], adjusted so (paddingCount + data.size) % 16 == 0.
 */
private func prependPaddingPassport(data: Array<Byte>): Array<Byte> {
    let basePad = ByteUtils.randomBytes(1)
    var paddingCount: Int64 = 47 + (Int64(basePad[0]) % Int64(255 - 47))
    let rem = (data.size + paddingCount) % 16
    paddingCount = paddingCount - rem
    let totalSize = paddingCount + data.size
    let result = Array<Byte>(totalSize, repeat: 0)
    result[0] = UInt8(paddingCount & 0xFF)
    let rndBytes = ByteUtils.randomBytes(paddingCount - 1)
    for (i in 1..paddingCount) {
        result[i] = rndBytes[i - 1]
    }
    for (i in 0..data.size) {
        result[paddingCount + i] = data[i]
    }
    return result
}

private func computeMd5HexPassport(data: Array<Byte>): String {
    let md5 = MD5()
    md5.write(data)
    let digest = md5.finish()
    return toHexString(digest)
}

public class SentCodeModel {
    public var phoneCodeHash: String = ""
    public var codeType: String = ""
    public var timeout: Int32 = 0
}

public class SentEmailCodeModel {
    public var length: Int32 = 0
}

// ==================== SecureId session cache ====================

/**
 * _cachedSecureIdAccessContext — process-level cache for the unlocked SecureId context.
 * Set by the password-unlock flow (P2-281) after a successful accessSecureId() call.
 * Cleared on logout. Pages check this before attempting encrypted save.
 */
private var _cachedSecureIdAccessContext: Option<SecureIdAccessContext> = None

public func setCachedSecureIdAccessContext(ctx: SecureIdAccessContext): Unit {
    _cachedSecureIdAccessContext = Some(ctx)
}

public func clearCachedSecureIdAccessContext(): Unit {
    _cachedSecureIdAccessContext = None
}

public func getCachedSecureIdAccessContext(): Option<SecureIdAccessContext> {
    return _cachedSecureIdAccessContext
}

// ==================== Secure value encryption helpers ====================

/**
 * buildInputSecureValueBytes — serializes inputSecureValue#db21d0a7 with only the
 * SecureData field set (flags bit 0).  No files, no front/back/selfie, no plain_data.
 *
 * TL layout:
 *   inputSecureValue#db21d0a7
 *     flags:# (int32, bit 0 = has data)
 *     type:SecureValueType   (4-byte constructor id, no extra fields for most types)
 *     data:flags.0?SecureData
 *       secureData#8aeabec3
 *         data:bytes         (encryptedData)
 *         data_hash:bytes    (dataHash = SHA256 of padded plaintext)
 *         secret:bytes       (encryptedSecret = AES-CBC(valueSecret, key, iv) with access ctx)
 *     (no files, no translations, no front/back/selfie, no plain_data)
 */
private func buildInputSecureValueBytes(
    docTypeCtor: UInt32,
    encryptedData: Array<Byte>,
    dataHash: Array<Byte>,
    encryptedSecret: Array<Byte>
): Array<Byte> {
    let s = TLSerializer()
    s.writeUInt32(0xdb21d0a7)    // inputSecureValue ctor
    s.writeInt32(1)               // flags = 0x1: bit 0 = has data
    s.writeUInt32(docTypeCtor)    // SecureValueType (bare — ctor only, no fields)
    // SecureData#8aeabec3
    s.writeUInt32(0x8aeabec3)
    s.writeBytes(encryptedData)
    s.writeBytes(dataHash)
    s.writeBytes(encryptedSecret)
    return s.getBytes()
}

private var _passportServiceInstance: Option<PassportService> = None
private var _pendingDocumentType: String = "passport"

public func setPendingPassportDocumentType(typeName: String): Unit {
    _pendingDocumentType = typeName
}

public func getPendingPassportDocumentType(): String {
    return _pendingDocumentType
}

// ==================== P2-280: Passport photo capture state ====================
// Pending captured photo slot ("front" / "back" / "selfie" / "translation") and file path.
// Set by the camera/gallery result handler in PassportDocumentPage, read on aboutToAppear.

private var _pendingPassportPhotoSlot: String = ""
private var _pendingPassportPhotoPath: String = ""

public func setPendingPassportPhoto(slot: String, filePath: String): Unit {
    _pendingPassportPhotoSlot = slot
    _pendingPassportPhotoPath = filePath
}

public func getPendingPassportPhotoSlot(): String {
    return _pendingPassportPhotoSlot
}

public func getPendingPassportPhotoPath(): String {
    return _pendingPassportPhotoPath
}

public func clearPendingPassportPhoto(): Unit {
    _pendingPassportPhotoSlot = ""
    _pendingPassportPhotoPath = ""
}

public func getPassportService(): PassportService {
    match (_passportServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PassportService()
            _passportServiceInstance = Some(inst)
            return inst
    }
}

public class PassportService {

    /**
     * account.getAuthorizationForm — 获取 SecureId 授权表单
     */
    public func getSecureIdAuthForm(botId: Int64, scope: String, publicKey: String): Option<SecureIdAuthForm> {
        let client = getMTProtoClient()
        let req = AccountGetAuthorizationForm()
        req.botId = botId
        req.scope = scope
        req.publicKey = publicKey
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return None
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let _ = d.readInt32()
            let _ = d.readString()
            return None
        }
        return parseSecureIdAuthForm(ctor, d)
    }

    private func parseSecureIdAuthForm(ctor: UInt32, d: TLDeserializer): Option<SecureIdAuthForm> {
        if (ctor != 0xad2e1cd8) {
            return None
        }
        let r = SecureIdAuthForm()
        let flags = d.readInt32()
        let reqVecCtor = d.readUInt32()
        if (reqVecCtor != TLConstructors.VECTOR) {
            return None
        }
        let reqCount = d.readInt32()
        for (_i in 0..Int64(reqCount)) {
            let reqCtor = d.readUInt32()
            if (reqCtor == 0x829d99da) {
                // secureRequiredType#829d99da flags:# type:SecureValueType
                // flags bits: selfie(1), translation(2), native_name(4)
                let reqFlags = d.readInt32()
                let typeCtor = d.readUInt32()
                let reqType = SecureIdRequiredType()
                reqType.typeName = secureRequiredTypeName(typeCtor)
                reqType.selfieRequired = (reqFlags & 2) != 0
                reqType.translationRequired = (reqFlags & 4) != 0
                r.requiredTypes.add(reqType)
            } else if (reqCtor == 0x027477b4) {
                // secureRequiredTypeOneOf#027477b4 types:Vector<SecureRequiredType>
                let oneOfVecCtor = d.readUInt32()
                let groupReq = SecureIdRequiredType()
                groupReq.isOneOfGroup = true
                groupReq.typeName = "one_of"
                if (oneOfVecCtor == TLConstructors.VECTOR) {
                    let n = d.readInt32()
                    for (_j in 0..Int64(n)) {
                        let inner = parseInnerRequiredType(d)
                        groupReq.oneOfOptions.add(inner)
                    }
                    if (groupReq.oneOfOptions.size > 0) {
                        groupReq.typeName = groupReq.oneOfOptions[0]
                    }
                }
                r.requiredTypes.add(groupReq)
            } else {
                // unknown variant — skip gracefully
                let reqType = SecureIdRequiredType()
                reqType.typeName = "unknown"
                r.requiredTypes.add(reqType)
            }
        }
        let valVecCtor = d.readUInt32()
        if (valVecCtor != TLConstructors.VECTOR) {
            return None
        }
        let valuesCount = d.readInt32()
        for (_i in 0..Int64(valuesCount)) {
            let sv = parseSecureValueFull(d)
            r.values.add(sv)
        }
        // Mark provided status on required types
        for (reqType in r.requiredTypes) {
            for (sv in r.values) {
                if (sv.typeName == reqType.typeName) {
                    reqType.isProvided = true
                    reqType.valueHash = sv.hash
                }
                if (reqType.isOneOfGroup) {
                    for (opt in reqType.oneOfOptions) {
                        if (sv.typeName == opt) {
                            reqType.isProvided = true
                            reqType.valueHash = sv.hash
                        }
                    }
                }
            }
        }
        let errVecCtor = d.readUInt32()
        if (errVecCtor != TLConstructors.VECTOR) {
            return None
        }
        let errorsCount = d.readInt32()
        for (_i in 0..Int64(errorsCount)) {
            skipSecureValueError(d)
        }
        let usrVecCtor = d.readUInt32()
        if (usrVecCtor != TLConstructors.VECTOR) {
            return None
        }
        let usersCount = d.readInt32()
        for (_i in 0..Int64(usersCount)) {
            let usr = UserResponse.deserializeBoxed(d)
            if (usr.id == r.botId || r.botName.size == 0) {
                let name = usr.firstName
                let last = usr.lastName
                if (last.size > 0) {
                    r.botName = name + " " + last
                } else if (name.size > 0) {
                    r.botName = name
                } else if (usr.username.size > 0) {
                    r.botName = "@" + usr.username
                }
            }
        }
        if ((flags & 1) != 0) {
            r.privacyPolicyUrl = d.readString()
        }
        return Some(r)
    }

    /**
     * parseInnerRequiredType — reads one secureRequiredType entry from a oneOf vector
     * Returns the type name string
     */
    private func parseInnerRequiredType(d: TLDeserializer): String {
        let innerCtor = d.readUInt32()
        if (innerCtor == 0x829d99da) {
            let _ = d.readInt32()  // flags
            let typeCtor = d.readUInt32()
            return secureRequiredTypeName(typeCtor)
        } else if (innerCtor == 0x027477b4) {
            let innerVecCtor = d.readUInt32()
            if (innerVecCtor == TLConstructors.VECTOR) {
                let n = d.readInt32()
                for (_i in 0..Int64(n)) {
                    skipSecureRequiredType(d)
                }
            }
            return "one_of"
        }
        return "unknown"
    }

    /**
     * parseSecureValueFull — fully deserializes secureValue#187fa0ca
     * secureValue#187fa0ca flags:# type:SecureValueType
     *   data:flags.0?SecureData
     *   front_side:flags.1?InputSecureFile
     *   reverse_side:flags.2?InputSecureFile
     *   selfie:flags.3?InputSecureFile
     *   translation:flags.6?Vector<InputSecureFile>
     *   files:flags.4?Vector<InputSecureFile>
     *   plain_data:flags.5?SecurePlainData
     *   hash:bytes = SecureValue
     */
    private func parseSecureValueFull(d: TLDeserializer): SecureValueFullModel {
        let sv = SecureValueFullModel()
        try {
            let svCtor = d.readUInt32()
            if (svCtor != 0x187fa0ca) {
                return sv
            }
            let flags = d.readInt32()
            let typeCtor = d.readUInt32()
            sv.typeName = secureRequiredTypeName(typeCtor)
            if ((flags & 1) != 0) {
                let dataCtor = d.readUInt32()
                if (dataCtor == 0x8aeabec3) {
                    sv.encryptedData = d.readBytes()
                    sv.dataHash = d.readBytes()
                    sv.encryptedSecret = d.readBytes()
                }
            }
            if ((flags & 2) != 0) {
                sv.frontSideFile = Some(parseSecureFileRef(d))
            }
            if ((flags & 4) != 0) {
                sv.backSideFile = Some(parseSecureFileRef(d))
            }
            if ((flags & 8) != 0) {
                sv.selfieFile = Some(parseSecureFileRef(d))
            }
            if ((flags & 64) != 0) {
                let translVecCtor = d.readUInt32()
                if (translVecCtor == TLConstructors.VECTOR) {
                    let n = d.readInt32()
                    for (_j in 0..Int64(n)) {
                        sv.translationFiles.add(parseSecureFileRef(d))
                    }
                }
            }
            if ((flags & 16) != 0) {
                let filesVecCtor = d.readUInt32()
                if (filesVecCtor == TLConstructors.VECTOR) {
                    let n = d.readInt32()
                    for (_j in 0..Int64(n)) {
                        sv.files.add(parseSecureFileRef(d))
                    }
                }
            }
            if ((flags & 32) != 0) {
                let pdCtor = d.readUInt32()
                let pdValue = d.readString()
                if (pdCtor == 0x7d6099dd) {
                    sv.plainDataType = "phone"
                    sv.plainDataValue = pdValue
                } else if (pdCtor == 0x21ec5a5f) {
                    sv.plainDataType = "email"
                    sv.plainDataValue = pdValue
                }
            }
            sv.hash = d.readBytes()
        } catch (e: Exception) {
            Hilog.warn(0, "CjTelegram", "[Passport] parseSecureValueFull exception")
        }
        return sv
    }

    /**
     * parseSecureFileRef — deserializes secureFile#7d09c27e / secureFileEmpty#64199744
     * secureFile#7d09c27e id:long access_hash:long size:long dc_id:int date:int
     *   file_hash:bytes secret:bytes = SecureFile
     * secureFileEmpty#64199744 = SecureFile
     */
    private func parseSecureFileRef(d: TLDeserializer): SecureFileRef {
        let f = SecureFileRef()
        try {
            let fCtor = d.readUInt32()
            if (fCtor == 0x7d09c27e) {
                f.id = d.readInt64()
                f.accessHash = d.readInt64()
                f.size = d.readInt64()
                f.dcId = d.readInt32()
                f.date = d.readInt32()
                f.fileHash = d.readBytes()
                f.secret = d.readBytes()
            } else if (fCtor == 0x64199744) {
                f.id = 0
            }
        } catch (e: Exception) {
            Hilog.warn(0, "CjTelegram", "[Passport] parseSecureFileRef exception")
        }
        return f
    }

    private func secureRequiredTypeName(ctor: UInt32): String {
        if (ctor == 0x9d2a81e3) { return "personal_details" }
        if (ctor == 0x3dac6a00) { return "passport" }
        if (ctor == 0x99a48f23) { return "internal_passport" }
        if (ctor == 0x06e425c4) { return "driver_license" }
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

    private func skipSecureValue(d: TLDeserializer): Unit {
        let ctor = d.readUInt32()
        if (ctor == 0x187fa0ca) {
            let flags = d.readInt32()
            let _ = d.readUInt32()
            if ((flags & 1) != 0) { skipSecureData(d) }
            if ((flags & 2) != 0) { skipSecureFile(d) }
            if ((flags & 4) != 0) { skipSecureFile(d) }
            if ((flags & 8) != 0) { skipSecureFile(d) }
            if ((flags & 64) != 0) {
                let skipTranslVecCtor = d.readUInt32()
                if (skipTranslVecCtor == TLConstructors.VECTOR) {
                    let n = d.readInt32()
                    for (_j in 0..Int64(n)) { skipSecureFile(d) }
                }
            }
            if ((flags & 16) != 0) {
                let skipFilesVecCtor = d.readUInt32()
                if (skipFilesVecCtor == TLConstructors.VECTOR) {
                    let n = d.readInt32()
                    for (_j in 0..Int64(n)) { skipSecureFile(d) }
                }
            }
            if ((flags & 32) != 0) { skipSecurePlainData(d) }
            let _ = d.readBytes()
        }
    }

    private func skipSecureData(d: TLDeserializer): Unit {
        let _ = d.readUInt32()
        let _ = d.readBytes()
        let _ = d.readBytes()
        let _ = d.readBytes()
    }

    private func skipSecureFile(d: TLDeserializer): Unit {
        let fCtor = d.readUInt32()
        if (fCtor == 0x7d09c27e) {
            let _ = d.readInt64()
            let _ = d.readInt64()
            let _ = d.readInt64()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readBytes()
            let _ = d.readBytes()
        }
    }

    private func skipSecurePlainData(d: TLDeserializer): Unit {
        let _ = d.readUInt32()
        let _ = d.readString()
    }

    private func skipSecureValueError(d: TLDeserializer): Unit {
        let _ = d.readUInt32()
        let _ = d.readString()
        let _ = d.readString()
    }

    private func skipSecureRequiredType(d: TLDeserializer): Unit {
        let ctor = d.readUInt32()
        if (ctor == 0x829d99da) {
            let _ = d.readInt32()
            let _ = d.readUInt32()
        } else if (ctor == 0x027477b4) {
            let skipOneOfVecCtor = d.readUInt32()
            if (skipOneOfVecCtor == TLConstructors.VECTOR) {
                let n = d.readInt32()
                for (_i in 0..Int64(n)) {
                    skipSecureRequiredType(d)
                }
            }
        }
    }

    /**
     * account.acceptAuthorization — 提交 SecureId 授权
     */
    public func acceptSecureIdAuth(botId: Int64, scope: String, publicKey: String, credentials: Array<Byte>, valueHashes: Array<Byte>): Bool {
        let client = getMTProtoClient()
        let req = AccountAcceptAuthorization()
        req.botId = botId
        req.scope = scope
        req.publicKey = publicKey
        req.valueHashesBytes = valueHashes
        req.credentialsBytes = credentials
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == 0x997275b5
    }

    /**
     * grantSecureIdAccessFull — P2-283 full grant flow:
     *   1. Collect provided values from form.values matching required types
     *   2. Build credentials JSON: {"secure_data":{...}, "nonce":"..."}
     *   3. AES-256-CBC encrypt credentials JSON with credentials secret
     *   4. RSA-OAEP encrypt credentials secret with bot public key
     *   5. Build value_hashes TL vector
     *   6. Send acceptAuthorization
     *   Returns: (success, error)
     *
     * iOS reference: GrantSecureIdAccess.swift grantSecureIdAccess
     * credentialsSecret = generateSecureSecretData() (32 bytes, checksum mod 255==239)
     * credentials JSON = {"secure_data":{typeName:{data:{data_hash, secret}}}, "nonce":nonce}
     * encryptedCredentials = AES-CBC-encrypt(paddedJSON, key derived from credSecret+SHA256(paddedJSON))
     * encryptedSecret = RSA-OAEP(botPubKey, credSecret)
     */
    public func grantSecureIdAccessFull(
        botId: Int64,
        scope: String,
        publicKey: String,
        nonce: String,
        form: SecureIdAuthForm,
        accessCtx: SecureIdAccessContext
    ): Bool {
        // Step 1: collect provided values from form
        let providedValues = ArrayList<SecureValueFullModel>()
        for (sv in form.values) {
            if (sv.typeName != "unknown" && sv.hash.size > 0) {
                providedValues.add(sv)
            }
        }

        // Step 2: build credentials secret (32 bytes, checksum == 239)
        let credSecret = generateSecureSecretData()

        // Step 3: build credentials JSON
        let credJson = buildCredentialsJson(providedValues, nonce, accessCtx)

        // Step 4: encrypt credentials JSON with AES-256-CBC
        let paddedCred = prependPaddingPassport(credJson)
        let credHash = SHA256.hash(paddedCred)
        let credSecretHash = SHA512.hash(ByteUtils.concat2(credSecret, credHash))
        let credKey = ByteUtils.slice(credSecretHash, 0, 32)
        let credIv = ByteUtils.slice(credSecretHash, 32, 48)
        let encryptedCred = AES256CBC.encrypt(paddedCred, credKey, credIv)

        // Step 5: RSA-OAEP encrypt credentials secret with bot public key
        let encryptedSecret = rsaOaepEncrypt(publicKey, credSecret)
        if (encryptedSecret.size == 0) {
            Hilog.warn(0, "CjTelegram", "[Passport] RSA-OAEP encrypt failed")
            return false
        }

        // Step 6: build value_hashes TL bytes
        let valueHashBytes = buildValueHashesTLBytes(providedValues)

        // Step 7: build credentials TL bytes (secureCredentialsEncrypted#33f0ea47)
        let credBytes = buildCredentialsTLBytes(encryptedCred, credHash, encryptedSecret)

        // Step 8: call acceptAuthorization
        return this.acceptSecureIdAuth(botId, scope, publicKey, credBytes, valueHashBytes)
    }

    /**
     * buildCredentialsJson — builds the credentials JSON payload
     * iOS: generateCredentials() in GrantSecureIdAccess.swift:138-295
     *
     * Structure per value (mirrors iOS GrantSecureIdAccess.swift:230-275):
     *   typeName: {
     *     "data": {"data_hash": b64, "secret": b64},          // if dataHash present
     *     "files": [{"file_hash": b64, "secret": b64}, ...],  // if files non-empty
     *     "translation": [{"file_hash": b64, "secret": b64}, ...], // if translations non-empty
     *     "selfie": {"file_hash": b64, "secret": b64},        // if selfie present
     *     "front_side": {"file_hash": b64, "secret": b64},    // if frontSide present
     *     "reverse_side": {"file_hash": b64, "secret": b64},  // if backSide present
     *   }
     * File secret: decryptedFileSecret = AES256CBC.decrypt(file.secret,
     *   key=SHA512(accessCtx.secret||file.fileHash)[0..32],
     *   iv=SHA512(accessCtx.secret||file.fileHash)[32..48])
     * (iOS: decryptedSecureIdFileSecret in UploadSecureIdFile.swift:53-63)
     */
    private func buildCredentialsJson(
        values: ArrayList<SecureValueFullModel>,
        nonce: String,
        accessCtx: SecureIdAccessContext
    ): Array<Byte> {
        var secureData = "{"
        var first = true
        for (sv in values) {
            if (!first) {
                secureData = secureData + ","
            }
            first = false
            let typeName = sv.typeName

            var valueDict = "{"
            var firstField = true

            // data section: present when encryptedData has dataHash
            if (sv.dataHash.size > 0) {
                let dataHashB64 = base64Encode(sv.dataHash)
                let decryptedSecret = decryptValueSecret(sv, accessCtx)
                let secretB64 = base64Encode(decryptedSecret)
                if (!firstField) { valueDict = valueDict + "," }
                firstField = false
                valueDict = valueDict + "\"data\":{\"data_hash\":\"" + dataHashB64 + "\",\"secret\":\"" + secretB64 + "\"}"
            }

            // files section (array) — iOS: value.files map file_hash+secret
            if (sv.files.size > 0) {
                if (!firstField) { valueDict = valueDict + "," }
                firstField = false
                valueDict = valueDict + "\"files\":["
                var firstFile = true
                for (f in sv.files) {
                    if (!firstFile) { valueDict = valueDict + "," }
                    firstFile = false
                    let fSecret = decryptFileSecret(f, accessCtx)
                    valueDict = valueDict + "{\"file_hash\":\"" + base64Encode(f.fileHash) + "\",\"secret\":\"" + base64Encode(fSecret) + "\"}"
                }
                valueDict = valueDict + "]"
            }

            // translation section (array) — iOS: value.translations map file_hash+secret
            if (sv.translationFiles.size > 0) {
                if (!firstField) { valueDict = valueDict + "," }
                firstField = false
                valueDict = valueDict + "\"translation\":["
                var firstTrans = true
                for (f in sv.translationFiles) {
                    if (!firstTrans) { valueDict = valueDict + "," }
                    firstTrans = false
                    let fSecret = decryptFileSecret(f, accessCtx)
                    valueDict = valueDict + "{\"file_hash\":\"" + base64Encode(f.fileHash) + "\",\"secret\":\"" + base64Encode(fSecret) + "\"}"
                }
                valueDict = valueDict + "]"
            }

            // selfie section (single object) — iOS: value.selfie
            match (sv.selfieFile) {
                case Some(f) =>
                    if (!firstField) { valueDict = valueDict + "," }
                    firstField = false
                    let fSecret = decryptFileSecret(f, accessCtx)
                    valueDict = valueDict + "\"selfie\":{\"file_hash\":\"" + base64Encode(f.fileHash) + "\",\"secret\":\"" + base64Encode(fSecret) + "\"}"
                case None => ()
            }

            // front_side section (single object) — iOS: value.frontSide
            match (sv.frontSideFile) {
                case Some(f) =>
                    if (!firstField) { valueDict = valueDict + "," }
                    firstField = false
                    let fSecret = decryptFileSecret(f, accessCtx)
                    valueDict = valueDict + "\"front_side\":{\"file_hash\":\"" + base64Encode(f.fileHash) + "\",\"secret\":\"" + base64Encode(fSecret) + "\"}"
                case None => ()
            }

            // reverse_side section (single object) — iOS: value.backSide
            match (sv.backSideFile) {
                case Some(f) =>
                    if (!firstField) { valueDict = valueDict + "," }
                    firstField = false
                    let fSecret = decryptFileSecret(f, accessCtx)
                    valueDict = valueDict + "\"reverse_side\":{\"file_hash\":\"" + base64Encode(f.fileHash) + "\",\"secret\":\"" + base64Encode(fSecret) + "\"}"
                case None => ()
            }

            valueDict = valueDict + "}"
            secureData = secureData + "\"" + typeName + "\":" + valueDict
        }
        secureData = secureData + "}"
        let dict = "{\"secure_data\":" + secureData + ",\"nonce\":\"" + nonce + "\"}"
        return ByteUtils.stringToBytes(dict)
    }

    /**
     * decryptFileSecret — derives the plaintext file secret from its encrypted form
     * iOS: decryptedSecureIdFileSecret(context, fileHash, encryptedSecret) in UploadSecureIdFile.swift:53-63
     *   secretHash = SHA512(accessCtx.secret || file.fileHash)
     *   key = secretHash[0..32], iv = secretHash[32..48]
     *   decryptedSecret = AES256CBC.decrypt(file.encryptedSecret, key, iv)
     */
    private func decryptFileSecret(f: SecureFileRef, accessCtx: SecureIdAccessContext): Array<Byte> {
        if (f.fileHash.size == 0 || f.secret.size == 0) {
            return Array<Byte>(0, repeat: 0)
        }
        let sHash = SHA512.hash(ByteUtils.concat2(accessCtx.secret, f.fileHash))
        let sKey = ByteUtils.slice(sHash, 0, 32)
        let sIv = ByteUtils.slice(sHash, 32, 48)
        return AES256CBC.decrypt(f.secret, sKey, sIv)
    }

    /**
     * decryptValueSecret — reverses AES-CBC to get the plaintext value secret
     * stored encryptedSecret = AES-CBC(valueSecret, key, iv)
     *   where secretHash = SHA512(accessCtx.secret || sv.dataHash)
     *         key = secretHash[0..32], iv = secretHash[32..48]
     */
    private func decryptValueSecret(sv: SecureValueFullModel, accessCtx: SecureIdAccessContext): Array<Byte> {
        if (sv.dataHash.size == 0 || sv.encryptedSecret.size == 0) {
            return Array<Byte>(0, repeat: 0)
        }
        // Reverse AES-CBC to get plaintext value secret:
        //   secretHash = SHA512(accessCtx.secret || sv.dataHash)
        //   key = secretHash[0..32], iv = secretHash[32..48]
        // iOS: decryptedValueSecret(accessContext, encryptedValueSecret, valueHash)
        let sHash = SHA512.hash(ByteUtils.concat2(accessCtx.secret, sv.dataHash))
        let sKey = ByteUtils.slice(sHash, 0, 32)
        let sIv = ByteUtils.slice(sHash, 32, 48)
        return AES256CBC.decrypt(sv.encryptedSecret, sKey, sIv)
    }

    /**
     * base64Encode — encode bytes to base64 string (standard alphabet)
     * Simple implementation without external dependency
     */
    private func base64Encode(data: Array<Byte>): String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        var result = ""
        var i: Int64 = 0
        while (i < data.size) {
            let b0 = UInt32(data[i])
            let b1: UInt32 = if (i + 1 < data.size) { UInt32(data[i + 1]) } else { 0 }
            let b2: UInt32 = if (i + 2 < data.size) { UInt32(data[i + 2]) } else { 0 }
            let idx0 = Int64(b0 >> 2)
            let idx1 = Int64(((b0 & 3) << 4) | (b1 >> 4))
            let idx2 = Int64(((b1 & 15) << 2) | (b2 >> 6))
            let idx3 = Int64(b2 & 63)
            result = result + chars[idx0..idx0 + 1]
            result = result + chars[idx1..idx1 + 1]
            result = result + if (i + 1 < data.size) { chars[idx2..idx2 + 1] } else { "=" }
            result = result + if (i + 2 < data.size) { chars[idx3..idx3 + 1] } else { "=" }
            i = i + 3
        }
        return result
    }

    /**
     * rsaOaepEncrypt — RSA-OAEP encrypt data with bot PEM public key
     * iOS: MTRsaEncryptPKCS1OAEP(encryptionProvider, publicKey, data)
     * Delegates to passportRsaOaepEncrypt (PassportRsaUtils.cj) to avoid SHA256 name collision.
     */
    private func rsaOaepEncrypt(pemKey: String, data: Array<Byte>): Array<Byte> {
        return passportRsaOaepEncrypt(pemKey, data)
    }

    /**
     * buildValueHashesTLBytes — serializes Vector<SecureValueHash> as TL bytes
     * secureValueHash#ed1ecdb0 type:SecureValueType hash:bytes
     * SecureValueType is a bare ctor (4 bytes, no fields)
     */
    private func buildValueHashesTLBytes(values: ArrayList<SecureValueFullModel>): Array<Byte> {
        let s = TLSerializer()
        s.writeUInt32(TLConstructors.VECTOR)
        s.writeInt32(Int32(values.size))
        for (sv in values) {
            s.writeUInt32(0xed1ecdb0)   // secureValueHash ctor
            let typeCtorOpt = typeNameToCtorId(sv.typeName)
            let typeCtor: UInt32 = match (typeCtorOpt) {
                case Some(c) => c
                case None => 0
            }
            s.writeUInt32(typeCtor)     // SecureValueType (bare ctor only)
            s.writeBytes(sv.hash)
        }
        return s.getBytes()
    }

    /**
     * buildCredentialsTLBytes — serializes secureCredentialsEncrypted#33f0ea47
     * secureCredentialsEncrypted#33f0ea47 data:bytes hash:bytes secret:bytes
     */
    private func buildCredentialsTLBytes(
        encryptedData: Array<Byte>,
        dataHash: Array<Byte>,
        encryptedSecret: Array<Byte>
    ): Array<Byte> {
        let s = TLSerializer()
        s.writeUInt32(0x33f0ea47)   // secureCredentialsEncrypted ctor
        s.writeBytes(encryptedData)
        s.writeBytes(dataHash)
        s.writeBytes(encryptedSecret)
        return s.getBytes()
    }

    /**
     * typeNameToCtorId — maps SecureValue type name to TL constructor ID
     */
    private func typeNameToCtorId(typeName: String): Option<UInt32> {
        if (typeName == "personal_details") { return Some(UInt32(0x9d2a81e3)) }
        if (typeName == "passport") { return Some(UInt32(0x3dac6a00)) }
        if (typeName == "internal_passport") { return Some(UInt32(0x99a48f23)) }
        if (typeName == "driver_license") { return Some(UInt32(0x06e425c4)) }
        if (typeName == "identity_card") { return Some(UInt32(0xa0d0744b)) }
        if (typeName == "address") { return Some(UInt32(0xcbe31e26)) }
        if (typeName == "utility_bill") { return Some(UInt32(0xfc36954e)) }
        if (typeName == "bank_statement") { return Some(UInt32(0x89137c0d)) }
        if (typeName == "rental_agreement") { return Some(UInt32(0x8b883488)) }
        if (typeName == "passport_registration") { return Some(UInt32(0x99e3806a)) }
        if (typeName == "temporary_registration") { return Some(UInt32(0xea02ec33)) }
        if (typeName == "phone") { return Some(UInt32(0xb320aadb)) }
        if (typeName == "email") { return Some(UInt32(0x8e3ca7ee)) }
        return None
    }

    /**
     * account.getSecureValue#73665bc2 — 获取指定类型的 SecureValue
     * Returns full model including encrypted data, files, plain_data.
     */
    public func getSecureValues(types: ArrayList<TLObject>): ArrayList<SecureValueFullModel> {
        let result = ArrayList<SecureValueFullModel>()
        let client = getMTProtoClient()
        let req = AccountGetSecureValue()
        req.typeObjects = types
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return result
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return result
        }
        if (ctor == TLConstructors.VECTOR) {
            let n = d.readInt32()
            for (_i in 0..Int64(n)) {
                result.add(parseSecureValueFull(d))
            }
        }
        return result
    }

    /**
     * account.getAllSecureValues#b288bc7d — 获取所有 SecureValue（无类型过滤）
     * iOS: account.getAllSecureValues in TelegramCore SecureId
     * Codegen verify: method ctor 0xb288bc7d, response Vector<secureValue#187fa0ca>
     */
    public func getAllSecureValues(): ArrayList<SecureValueFullModel> {
        let result = ArrayList<SecureValueFullModel>()
        let client = getMTProtoClient()
        let req = AccountGetAllSecureValues()
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return result
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return result
        }
        if (ctor == TLConstructors.VECTOR) {
            let n = d.readInt32()
            for (_i in 0..Int64(n)) {
                result.add(parseSecureValueFull(d))
            }
        }
        return result
    }

    /**
     * uploadSecureIdFile — encrypt and upload a Passport document file
     *
     * iOS reference: uploadSecureIdFile in TelegramCore/SecureId/UploadSecureIdFile.swift
     *
     * Protocol (matches iOS UploadSecureIdFile.swift + SecureIdPadding.swift):
     *   1. Generate random 32-byte file secret.
     *   2. Prepend-pad plainFileBytes: [paddingCount][paddingCount-1 random bytes][data],
     *        totalLength is multiple of 16.
     *   3. Compute file_hash = SHA256(paddedFileBytes).
     *   4. Derive key/iv from secret and file_hash:
     *        hash = SHA512(secret || file_hash)
     *        key  = hash[0..32], iv = hash[32..48]
     *   5. Encrypt paddedFileBytes with AES-256-CBC(key, iv).
     *   6. Upload encrypted bytes via FileUploadService → InputFileUploaded / InputFileBig.
     *   7. Wrap as inputSecureFileUploaded#3334b0f0.
     *   8. Encrypt fileSecret (32 bytes, already block-aligned, no extra padding) with:
     *        secretHash = SHA512(accessContext.secret || file_hash)
     *        secretKey  = secretHash[0..32], secretIv = secretHash[32..48]
     *        encryptedSecret = AES-256-CBC-encrypt(fileSecret, secretKey, secretIv)
     *
     * Returns UploadedSecureFile on success, None on failure.
     */
    public func uploadSecureIdFile(
        fileBytes: Array<Byte>,
        fileName: String,
        accessSecret: Array<Byte>
    ): Option<UploadedSecureFile> {
        if (fileBytes.size == 0) {
            return None
        }

        let fileSecret = ByteUtils.randomBytes(32)

        let paddedFileData = prependPaddingPassport(fileBytes)
        let fileHash = SHA256.hash(paddedFileData)

        let derivedKeyIv = SHA512.hash(ByteUtils.concat2(fileSecret, fileHash))
        let fileKey = ByteUtils.slice(derivedKeyIv, 0, 32)
        let fileIv = ByteUtils.slice(derivedKeyIv, 32, 48)

        let encrypted = AES256CBC.encrypt(paddedFileData, fileKey, fileIv)

        let uploadResult = getFileUploadService().uploadFile(encrypted, fileName)
        let inputFile = match (uploadResult) {
            case None => return None
            case Some(f) => f
        }

        let isSmall = Int64(encrypted.size) < 10485760
        var md5hex: String = ""
        if (isSmall) {
            md5hex = computeMd5HexPassport(encrypted)
        }

        let inputSecureFile = InputSecureFileUploaded()
        let uploadCtor = inputFile.getConstructorId()
        if (uploadCtor == 0xf52ff27f) {
            match (inputFile as InputFileUploaded) {
                case Some(f) =>
                    inputSecureFile.id = f.id
                    inputSecureFile.parts = f.parts
                case None => return None
            }
        } else if (uploadCtor == 0xfa4f0bb5) {
            match (inputFile as InputFileBig) {
                case Some(f) =>
                    inputSecureFile.id = f.id
                    inputSecureFile.parts = f.parts
                case None => return None
            }
        } else {
            return None
        }
        inputSecureFile.md5Checksum = md5hex
        inputSecureFile.fileHash = fileHash

        let secretDerived = SHA512.hash(ByteUtils.concat2(accessSecret, fileHash))
        let secretKey = ByteUtils.slice(secretDerived, 0, 32)
        let secretIv = ByteUtils.slice(secretDerived, 32, 48)
        let encryptedSecret = AES256CBC.encrypt(fileSecret, secretKey, secretIv)

        inputSecureFile.secret = encryptedSecret

        let r = UploadedSecureFile()
        r.inputSecureFile = inputSecureFile
        r.fileHash = fileHash
        r.encryptedSecret = encryptedSecret
        return Some(r)
    }

    /**
     * account.saveSecureValue — 保存 SecureValue
     */
    public func saveSecureValue(value: Array<Byte>, secureSecretId: Int64): Option<SecureValueModel> {
        let client = getMTProtoClient()
        let req = AccountSaveSecureValue()
        req.valueBytes = value
        req.secureSecretId = secureSecretId
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return None
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return None
        }
        let r = SecureValueModel()
        if (ctor == 0x187fa0ca) {
            let flags = d.readInt32()
            let _ = d.readUInt32()
            if ((flags & 1) != 0) { skipSecureData(d) }
            if ((flags & 2) != 0) { skipSecureFile(d) }
            if ((flags & 4) != 0) { skipSecureFile(d) }
            if ((flags & 8) != 0) { skipSecureFile(d) }
            if ((flags & 64) != 0) {
                let saveTranslVecCtor = d.readUInt32()
                if (saveTranslVecCtor == TLConstructors.VECTOR) {
                    let n = d.readInt32()
                    for (_j in 0..Int64(n)) { skipSecureFile(d) }
                }
            }
            if ((flags & 16) != 0) {
                let saveFilesVecCtor = d.readUInt32()
                if (saveFilesVecCtor == TLConstructors.VECTOR) {
                    let n = d.readInt32()
                    for (_j in 0..Int64(n)) { skipSecureFile(d) }
                }
            }
            if ((flags & 32) != 0) { skipSecurePlainData(d) }
            r.hash = d.readBytes()
        }
        return Some(r)
    }

    /**
     * encryptAndSaveSecureValue — encrypts plainData with AES-256-CBC per Telegram Passport
     * protocol and calls account.saveSecureValue with the correct secureSecretId.
     *
     * Matches iOS SaveSecureIdValue.swift encryptedSecureValueData() + makeInputSecureValue().
     *
     * Protocol (data-only value, no file attachments):
     *   1. paddedData = prependPaddingPassport(plainData)      — same 16-byte-aligned padding
     *   2. dataHash   = SHA256(paddedData)
     *   3. Generate random valueSecret (32 bytes, satisfying checksum mod-255 == 239)
     *   4. valueSecretHash = SHA512(valueSecret || dataHash)
     *      valueKey = valueSecretHash[0..32], valueIv = valueSecretHash[32..48]
     *   5. encryptedData = AES256CBC.encrypt(paddedData, valueKey, valueIv)
     *   6. secretHash = SHA512(accessContext.secret || dataHash)
     *      secretKey  = secretHash[0..32],  secretIv  = secretHash[32..48]
     *   7. encryptedSecret = AES256CBC.encrypt(valueSecret, secretKey, secretIv)
     *   8. Build inputSecureValue#db21d0a7 TL bytes → call account.saveSecureValue
     */
    public func encryptAndSaveSecureValue(
        plainData: Array<Byte>,
        docTypeCtor: UInt32,
        accessContext: SecureIdAccessContext
    ): Option<SecureValueModel> {
        let paddedData = prependPaddingPassport(plainData)
        let dataHash = SHA256.hash(paddedData)

        let valueSecret = generateSecureSecretData()

        let vsHash = SHA512.hash(ByteUtils.concat2(valueSecret, dataHash))
        let valueKey = ByteUtils.slice(vsHash, 0, 32)
        let valueIv  = ByteUtils.slice(vsHash, 32, 48)
        let encryptedData = AES256CBC.encrypt(paddedData, valueKey, valueIv)

        let sHash = SHA512.hash(ByteUtils.concat2(accessContext.secret, dataHash))
        let secretKey = ByteUtils.slice(sHash, 0, 32)
        let secretIv  = ByteUtils.slice(sHash, 32, 48)
        let encryptedSecret = AES256CBC.encrypt(valueSecret, secretKey, secretIv)

        let inputSecureValueBytes = buildInputSecureValueBytes(
            docTypeCtor, encryptedData, dataHash, encryptedSecret)

        return this.saveSecureValue(inputSecureValueBytes, accessContext.id)
    }

    /**
     * saveSecureValueWithFiles — P2-280: 保存包含文件附件的 SecureValue
     *
     * iOS reference: makeInputSecureValue() in SaveSecureIdValue.swift
     * 支持 front_side / reverse_side / selfie / translation / files 五个文件槽。
     *
     * inputSecureValue#db21d0a7 flags:# type:SecureValueType
     *   data:flags.0?SecureData
     *   front_side:flags.1?InputSecureFile
     *   reverse_side:flags.2?InputSecureFile
     *   selfie:flags.3?InputSecureFile
     *   translation:flags.6?Vector<InputSecureFile>
     *   files:flags.4?Vector<InputSecureFile>
     *
     * flags bitmask:
     *   bit 0: has data
     *   bit 1: has front_side
     *   bit 2: has reverse_side
     *   bit 3: has selfie
     *   bit 4: has files
     *   bit 6: has translation
     */
    public func saveSecureValueWithFiles(
        plainData: Array<Byte>,
        docTypeCtor: UInt32,
        accessContext: SecureIdAccessContext,
        frontSide: Option<UploadedSecureFile>,
        reverseSide: Option<UploadedSecureFile>,
        selfieFile: Option<UploadedSecureFile>,
        translationFiles: ArrayList<UploadedSecureFile>,
        attachmentFiles: ArrayList<UploadedSecureFile>
    ): Option<SecureValueModel> {
        // Build flags
        var flags: Int32 = 0
        let hasData = plainData.size > 0
        if (hasData) { flags = flags | 1 }
        match (frontSide) { case Some(_) => flags = flags | 2; case None => () }
        match (reverseSide) { case Some(_) => flags = flags | 4; case None => () }
        match (selfieFile) { case Some(_) => flags = flags | 8; case None => () }
        if (attachmentFiles.size > 0) { flags = flags | 16 }
        if (translationFiles.size > 0) { flags = flags | 64 }

        let s = TLSerializer()
        s.writeUInt32(0xdb21d0a7)       // inputSecureValue ctor
        s.writeInt32(flags)
        s.writeUInt32(docTypeCtor)      // SecureValueType (bare ctor only)

        // data section (flag bit 0)
        if (hasData) {
            let paddedData = prependPaddingPassport(plainData)
            let dataHash = SHA256.hash(paddedData)
            let valueSecret = generateSecureSecretData()
            let vsHash = SHA512.hash(ByteUtils.concat2(valueSecret, dataHash))
            let valueKey = ByteUtils.slice(vsHash, 0, 32)
            let valueIv  = ByteUtils.slice(vsHash, 32, 48)
            let encryptedData = AES256CBC.encrypt(paddedData, valueKey, valueIv)
            let sHash = SHA512.hash(ByteUtils.concat2(accessContext.secret, dataHash))
            let secretKey = ByteUtils.slice(sHash, 0, 32)
            let secretIv  = ByteUtils.slice(sHash, 32, 48)
            let encryptedSecret = AES256CBC.encrypt(valueSecret, secretKey, secretIv)
            // secureData#8aeabec3
            s.writeUInt32(0x8aeabec3)
            s.writeBytes(encryptedData)
            s.writeBytes(dataHash)
            s.writeBytes(encryptedSecret)
        }

        // front_side (flag bit 1)
        match (frontSide) {
            case Some(f) => writeInputSecureFile(s, f)
            case None => ()
        }

        // reverse_side (flag bit 2)
        match (reverseSide) {
            case Some(f) => writeInputSecureFile(s, f)
            case None => ()
        }

        // selfie (flag bit 3)
        match (selfieFile) {
            case Some(f) => writeInputSecureFile(s, f)
            case None => ()
        }

        // translation (flag bit 6) — Vector<InputSecureFile>
        if (translationFiles.size > 0) {
            s.writeUInt32(TLConstructors.VECTOR)
            s.writeInt32(Int32(translationFiles.size))
            for (f in translationFiles) {
                writeInputSecureFile(s, f)
            }
        }

        // files (flag bit 4) — Vector<InputSecureFile>
        if (attachmentFiles.size > 0) {
            s.writeUInt32(TLConstructors.VECTOR)
            s.writeInt32(Int32(attachmentFiles.size))
            for (f in attachmentFiles) {
                writeInputSecureFile(s, f)
            }
        }

        return this.saveSecureValue(s.getBytes(), accessContext.id)
    }

    /**
     * writeInputSecureFile — 序列化 inputSecureFileUploaded#3334b0f0 到 TLSerializer
     */
    private func writeInputSecureFile(s: TLSerializer, f: UploadedSecureFile): Unit {
        s.writeUInt32(0x3334b0f0)       // inputSecureFileUploaded ctor
        s.writeInt64(f.inputSecureFile.id)
        s.writeInt32(f.inputSecureFile.parts)
        s.writeString(f.inputSecureFile.md5Checksum)
        s.writeBytes(f.fileHash)
        s.writeBytes(f.encryptedSecret)
    }

    /**
     * account.deleteSecureValue — 删除 SecureValue
     */
    public func deleteSecureValue(types: ArrayList<TLObject>): Unit {
        let client = getMTProtoClient()
        let req = AccountDeleteSecureValue()
        req.typeObjects = types
        let _ = client.sendRequest(req.toBytes())
    }

    /**
     * account.sendVerifyPhoneCode — 发送手机验证码 (Passport)
     */
    public func sendVerifyPhoneCode(phoneNumber: String): Option<SentCodeModel> {
        let client = getMTProtoClient()
        let req = AccountSendVerifyPhoneCode()
        req.phoneNumber = phoneNumber
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return None
        }
        let sentCode = AuthSentCodeResponse.deserialize(data)
        let r = SentCodeModel()
        r.phoneCodeHash = sentCode.phoneCodeHash
        r.timeout = sentCode.timeout
        return Some(r)
    }

    /**
     * account.verifyPhone — 确认手机验证码
     */
    public func confirmVerifyPhone(phoneCodeHash: String, code: String, phoneNumber: String): Bool {
        let client = getMTProtoClient()
        let req = AccountVerifyPhone()
        req.phoneNumber = phoneNumber
        req.phoneCodeHash = phoneCodeHash
        req.phoneCode = code
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == 0x997275b5
    }

    /**
     * account.sendVerifyEmailCode — 发送邮箱验证码 (Passport)
     */
    public func sendVerifyEmailCode(email: String): Option<SentEmailCodeModel> {
        let client = getMTProtoClient()
        let req = AccountSendVerifyEmailCode()
        req.email = email
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return None
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return None
        }
        let r = SentEmailCodeModel()
        if (ctor == 0x4b3e4e4a) {
            r.length = d.readInt32()
        }
        return Some(r)
    }

    /**
     * account.verifyEmail — 确认邮箱验证码
     */
    public func confirmVerifyEmail(email: String, code: String): Bool {
        let client = getMTProtoClient()
        let req = AccountVerifyEmail()
        req.code = code
        let data = client.sendRequest(req.toBytes())
        if (data.size == 0) {
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            return false
        }
        return ctor == 0x2b96cd1b || ctor == 0xe1bb0d61
    }
}
