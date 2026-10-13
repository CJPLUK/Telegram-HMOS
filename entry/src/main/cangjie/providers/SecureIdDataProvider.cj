package ohos_app_cangjie_entry.providers

import ohos_app_cangjie_entry.services.{
    getSecureIdEngineService, SecureIdEngineService,
    SecureIdAuthForm, SecureValueModel, SecureValueFullModel, UploadedSecureFile,
    SentCodeModel, SentEmailCodeModel,
    SecureIdAccessContext, generateSecureSecretData, typeNameToTLObject,
    secureValueTypeConstructorToName
}
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

/**
 * SecureIdDataProvider — 将 SecureId API 数据转为 UI 可用的 ViewModel
 *
 * 对应 iOS TelegramEngine SecureId 的 UI 层适配
 * 职责：
 * - 委托 SecureIdEngineService 执行 TL 调用
 * - 将授权表单、SecureValue 等转为 UI 可消费的格式
 * - 提供文档类型显示名、图标等辅助方法
 * - 覆盖 iOS SecureIdValueKey 的全部 13 种类型（相比基础版新增 6 种）
 *
 * 新增类型（相比原基础实现）:
 *   internal_passport, utility_bill, bank_statement,
 *   rental_agreement, passport_registration, temporary_registration
 */
public class SecureIdDataProvider {
    private let engineService = getSecureIdEngineService()

    /**
     * accessSecureId — 使用账号密码解锁 SecureId
     * 对应 iOS: TelegramEngine.SecureId.accessSecureId(password:)
     * 返回: Some(SecureIdAccessContext) on success, None on failure
     */
    public func accessSecureId(password: String): Option<SecureIdAccessContext> {
        return this.engineService.accessSecureId(password)
    }

    /**
     * generateNewSecureSecret — 生成新的随机 secure secret
     * 对应 iOS: generateSecureSecretData()
     * 用于首次设置 Passport 时生成 secret
     */
    public func generateNewSecureSecret(): Array<Byte> {
        return generateSecureSecretData()
    }

    /**
     * 获取授权表单（供 PassportPage 等使用）
     * 对应 iOS: account.getAuthorizationForm
     */
    public func getAuthorizationForm(botId: Int64, scope: String, publicKey: String): Option<SecureIdAuthForm> {
        return this.engineService.getAuthorizationForm(botId, scope, publicKey)
    }

    /**
     * 根据类型名列表获取已保存的 SecureValue (account.getSecureValue#73665bc2)
     * 将 typeName 转为 TL SecureValueType 对象后调用 account.getSecureValue
     * 覆盖全部 13 种类型。返回完整模型含加密数据和文件引用。
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
        return this.engineService.getSecureValues(types)
    }

    /**
     * getAllSecureIdValues — 获取全部 SecureValue (account.getAllSecureValues#b288bc7d)
     * iOS: TelegramCore SecureId getAllSecureValues
     * 返回所有已存储的 SecureValue，不过滤类型。
     * Codegen verify: method 0xb288bc7d, response Vector<secureValue#187fa0ca>
     */
    public func getAllSecureIdValues(): ArrayList<SecureValueFullModel> {
        return this.engineService.getAllSecureValues()
    }

    /**
     * uploadSecureIdFile — 加密并上传 Passport 文件
     * iOS: TelegramCore/SecureId/UploadSecureIdFile.swift uploadSecureIdFile
     * 流程: 生成 fileSecret → SHA256(plain) → AES-256-CBC 加密 → FileUploadService 上传
     *       → inputSecureFileUploaded#3334b0f0
     * accessSecret: 来自 SecureIdAccessContext.secret (已解锁)
     */
    public func uploadSecureIdFile(fileBytes: Array<Byte>, fileName: String, accessSecret: Array<Byte>): Option<UploadedSecureFile> {
        return this.engineService.uploadSecureIdFile(fileBytes, fileName, accessSecret)
    }

    /**
     * 保存 SecureValue
     * value: 已加密的 InputSecureValue 字节流（调用方负责加密）
     * secureSecretId: 当前 SecureIdAccessContext.id
     */
    public func saveSecureValue(value: Array<Byte>, secureSecretId: Int64): Option<SecureValueModel> {
        return this.engineService.saveSecureValue(value, secureSecretId)
    }

    /**
     * 提交授权
     * credentials/valueHashes: 已加密字节流（调用方负责加密）
     */
    public func acceptAuthorization(botId: Int64, scope: String, publicKey: String, credentials: Array<Byte>, valueHashes: Array<Byte>): Bool {
        return this.engineService.acceptAuthorization(botId, scope, publicKey, credentials, valueHashes)
    }

    /**
     * 删除指定类型的 SecureValue
     * 覆盖全部 13 种类型
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
            this.engineService.deleteSecureValue(types)
        }
    }

    /**
     * 发送手机验证码
     */
    public func sendVerifyPhoneCode(phoneNumber: String): Option<SentCodeModel> {
        return this.engineService.sendVerifyPhoneCode(phoneNumber)
    }

    /**
     * 确认手机验证码
     */
    public func confirmVerifyPhone(phoneCodeHash: String, code: String, phoneNumber: String): Bool {
        return this.engineService.confirmVerifyPhone(phoneCodeHash, code, phoneNumber)
    }

    /**
     * 发送邮箱验证码
     */
    public func sendVerifyEmailCode(email: String): Option<SentEmailCodeModel> {
        return this.engineService.sendVerifyEmailCode(email)
    }

    /**
     * 确认邮箱验证码
     */
    public func confirmVerifyEmail(email: String, code: String): Bool {
        return this.engineService.confirmVerifyEmail(email, code)
    }

    /**
     * getPassportConfiguration — 获取 Passport 国家/语言配置
     * 对应 iOS: help.getPassportConfig
     * 返回 JSON 字符串（国家语言映射）
     */
    public func getPassportConfiguration(hash: Int32): String {
        return this.engineService.getPassportConfiguration(hash)
    }

    /**
     * 文档类型显示名（供 UI 展示）
     * 覆盖全部 13 种 iOS SecureIdValueKey 类型
     */
    public func getTypeDisplayName(typeName: String): String {
        if (typeName == "personal_details") { return "Personal Details" }
        if (typeName == "passport") { return "Passport" }
        if (typeName == "internal_passport") { return "Internal Passport" }
        if (typeName == "driver_license") { return "Driver's License" }
        if (typeName == "identity_card") { return "Identity Card" }
        if (typeName == "address") { return "Address" }
        if (typeName == "utility_bill") { return "Utility Bill" }
        if (typeName == "bank_statement") { return "Bank Statement" }
        if (typeName == "rental_agreement") { return "Rental Agreement" }
        if (typeName == "passport_registration") { return "Passport Registration" }
        if (typeName == "temporary_registration") { return "Temporary Registration" }
        if (typeName == "phone") { return "Phone Number" }
        if (typeName == "email") { return "Email Address" }
        return typeName
    }

    /**
     * 文档类型图标（供 UI 展示）
     * 覆盖全部 13 种 iOS SecureIdValueKey 类型
     */
    public func getTypeIcon(typeName: String): String {
        if (typeName == "personal_details") { return "person" }
        if (typeName == "passport") { return "doc.text" }
        if (typeName == "internal_passport") { return "doc.text.fill" }
        if (typeName == "driver_license") { return "car" }
        if (typeName == "identity_card") { return "creditcard" }
        if (typeName == "address") { return "mappin" }
        if (typeName == "utility_bill") { return "doc.plaintext" }
        if (typeName == "bank_statement") { return "banknote" }
        if (typeName == "rental_agreement") { return "house" }
        if (typeName == "passport_registration") { return "doc.badge.plus" }
        if (typeName == "temporary_registration") { return "clock" }
        if (typeName == "phone") { return "phone" }
        if (typeName == "email") { return "envelope" }
        return "doc"
    }

    /**
     * isDocumentType — 判断该类型是否需要文档扫描件
     * 对应 iOS SecureIdValue.fileReferences 逻辑
     */
    public func isDocumentType(typeName: String): Bool {
        if (typeName == "passport") { return true }
        if (typeName == "internal_passport") { return true }
        if (typeName == "driver_license") { return true }
        if (typeName == "identity_card") { return true }
        if (typeName == "utility_bill") { return true }
        if (typeName == "bank_statement") { return true }
        if (typeName == "rental_agreement") { return true }
        if (typeName == "passport_registration") { return true }
        if (typeName == "temporary_registration") { return true }
        return false
    }

    /**
     * requiresSelfie — 判断该类型是否支持 selfie
     * 对应 iOS SecureIdValueAdditionalData.selfie
     */
    public func requiresSelfie(typeName: String): Bool {
        if (typeName == "passport") { return true }
        if (typeName == "internal_passport") { return true }
        if (typeName == "driver_license") { return true }
        if (typeName == "identity_card") { return true }
        return false
    }

    /**
     * supportsTranslation — 判断该类型是否支持翻译文件
     * 对应 iOS SecureIdValueAdditionalData.translation
     */
    public func supportsTranslation(typeName: String): Bool {
        if (typeName == "passport") { return true }
        if (typeName == "internal_passport") { return true }
        if (typeName == "driver_license") { return true }
        if (typeName == "identity_card") { return true }
        if (typeName == "utility_bill") { return true }
        if (typeName == "bank_statement") { return true }
        if (typeName == "rental_agreement") { return true }
        if (typeName == "passport_registration") { return true }
        if (typeName == "temporary_registration") { return true }
        return false
    }

    /**
     * supportsNativeNames — 判断该类型是否支持本地语言姓名
     * 对应 iOS SecureIdValueAdditionalData.nativeNames (仅 personal_details)
     */
    public func supportsNativeNames(typeName: String): Bool {
        return typeName == "personal_details"
    }

    /**
     * getAllSupportedTypeNames — 获取全部支持的 13 种类型名列表
     */
    public func getAllSupportedTypeNames(): ArrayList<String> {
        let result = ArrayList<String>()
        result.add("personal_details")
        result.add("passport")
        result.add("internal_passport")
        result.add("driver_license")
        result.add("identity_card")
        result.add("address")
        result.add("utility_bill")
        result.add("bank_statement")
        result.add("rental_agreement")
        result.add("passport_registration")
        result.add("temporary_registration")
        result.add("phone")
        result.add("email")
        return result
    }
}
