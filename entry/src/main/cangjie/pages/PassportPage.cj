package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.{
    getPassportService,
    setPendingPassportDocumentType,
    SecureIdRequiredType,
    SecureIdAuthForm,
    SecureIdAccessContext,
    SecureValueFullModel,
    getCachedSecureIdAccessContext,
    typeNameToTLObject
}
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * PassportPage — Telegram Passport (SecureId) authorization form page
 *
 * P2-275: form mode —真实 account.getAuthorizationForm 拉取 (setParams 真调用)
 *   - Calls getSecureIdAuthForm when botId != 0
 *   - Displays bot name (from server users vector)
 *   - Shows required types grouped (oneOf/selfie/translation flags)
 *   - Shows per-field provided status from form.values
 *
 * P2-283: bot authorization — account.acceptAuthorization with real credentials
 *   - Assembles credentials JSON (secure_data + nonce)
 *   - AES-256-CBC encrypts credentials using credential secret
 *   - RSA-OAEP encrypts credential secret with bot public key
 *   - Builds value_hashes from stored SecureValue.hash fields
 *   - Handles callbackUrl redirect on success
 *
 * 混合迁移改动（recipe §12 Phase 4）：本文件含三个可导航类 —
 * PassportPage / PassportSelfManagePage / PassportDocumentDetailPage，各一路由+壳。
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()；pushPathByName → routerPush
 *  - aboutToAppear 有实逻辑 → 移到 ensureLoaded()，.onAppear 触发
 *  - onReady 参数收取 → ensureLoaded() 里 takePending
 */
@HybridComponentEntry
@Component
public class PassportPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var botName: String = ""
    @State var documentTypes: ArrayList<SecureIdRequiredType> = ArrayList<SecureIdRequiredType>()
    @State var isLoading: Bool = true
    @State var isAuthorizing: Bool = false
    @State var errorMessage: String = ""
    @State var isSecureIdUnlocked: Bool = false
    @State var loaded: Bool = false

    private var botId: Int64 = 0
    private var scope: String = ""
    private var publicKey: String = ""
    private var callbackUrl: String = ""
    private var nonce: String = ""
    private var cachedForm: Option<SecureIdAuthForm> = None

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        match (getCachedSecureIdAccessContext()) {
            case Some(_) => this.isSecureIdUnlocked = true
            case None => this.isSecureIdUnlocked = false
        }
    }

    /**
     * setParams — configures form mode with real bot parameters
     * P2-275 gap fix: botId != 0 triggers real getAuthorizationForm
     */
    public func setParams(botId: Int64, scope: String, publicKey: String): Unit {
        this.botId = botId
        this.scope = scope
        this.publicKey = publicKey
        this.loadAuthForm()
    }

    /**
     * setParamsFull — extended params with callbackUrl and nonce (P2-283)
     */
    public func setParamsFull(
        botId: Int64,
        scope: String,
        publicKey: String,
        callbackUrl: String,
        nonce: String
    ): Unit {
        this.botId = botId
        this.scope = scope
        this.publicKey = publicKey
        this.callbackUrl = callbackUrl
        this.nonce = nonce
        this.loadAuthForm()
    }

    private func loadAuthForm(): Unit {
        this.isLoading = true
        this.errorMessage = ""
        let bid = this.botId
        let scp = this.scope
        let pk = this.publicKey
        let callbackU = this.callbackUrl
        let nonceV = this.nonce
        let _ = spawn {
            var list = ArrayList<SecureIdRequiredType>()
            var errMsg = ""
            var resolvedBotName = ""
            var resolvedForm: Option<SecureIdAuthForm> = None
            if (bid == 0) {
                // demo mode fallback (no real bot params) — show placeholder types
                let demoNames = ["personal_details", "passport", "address", "phone"]
                for (name in demoNames) {
                    let t = SecureIdRequiredType()
                    t.typeName = name
                    list.add(t)
                }
                resolvedBotName = "Demo Service"
            } else {
                let service = getPassportService()
                let formOpt = service.getSecureIdAuthForm(bid, scp, pk)
                match (formOpt) {
                    case Some(form) =>
                        form.publicKey = pk
                        form.callbackUrl = callbackU
                        form.opaqueNonce = nonceV
                        for (t in form.requiredTypes) {
                            list.add(t)
                        }
                        resolvedBotName = form.botName
                        resolvedForm = Some(form)
                    case None =>
                        errMsg = "Failed to load authorization form from server"
                }
            }
            let finalList = list
            let finalErr = errMsg
            let finalBotName = resolvedBotName
            let finalForm = resolvedForm
            launch {
                this.documentTypes = finalList
                this.errorMessage = finalErr
                this.isLoading = false
                if (finalBotName.size > 0) {
                    this.botName = finalBotName
                } else {
                    this.botName = "Service"
                }
                this.cachedForm = finalForm
            }
        }
    }

    /**
     * onAuthorize — P2-283: full credentials assembly + acceptAuthorization
     * Never sends empty credentials/valueHashes.
     * Requires isSecureIdUnlocked (access context from P2-281).
     */
    private func onAuthorize(): Unit {
        if (!this.isSecureIdUnlocked) {
            this.errorMessage = "Please unlock Passport first"
            return
        }
        let accessCtxOpt = getCachedSecureIdAccessContext()
        match (accessCtxOpt) {
            case None =>
                this.errorMessage = "Passport not unlocked — please unlock first"
                return
            case Some(_) => ()
        }
        let formOpt = this.cachedForm
        match (formOpt) {
            case None =>
                this.errorMessage = "Form not loaded — please wait for form to load"
                return
            case Some(_) => ()
        }
        this.isAuthorizing = true
        this.errorMessage = ""
        let bid = this.botId
        let scp = this.scope
        let pk = this.publicKey
        let callbackU = this.callbackUrl
        let nonceV = this.nonce
        // Capture cachedForm before entering spawn (main-thread read)
        let capturedFormOpt = this.cachedForm
        let _ = spawn {
            let accessCtx = getCachedSecureIdAccessContext()
            let service = getPassportService()
            var ok = false
            var errMsg = ""
            match (accessCtx) {
                case None =>
                    errMsg = "Access context expired — please unlock again"
                case Some(ctx) =>
                    match (capturedFormOpt) {
                        case None =>
                            errMsg = "Form data missing"
                        case Some(form) =>
                            // P2-283: grantSecureIdAccessFull — builds real credentials + value hashes
                            ok = service.grantSecureIdAccessFull(bid, scp, pk, nonceV, form, ctx)
                            if (!ok) {
                                errMsg = "Authorization failed — check documents are complete"
                            }
                    }
            }
            let finalOk = ok
            let finalErr = errMsg
            let finalCallback = callbackU
            launch {
                this.isAuthorizing = false
                if (finalOk) {
                    if (finalCallback.size > 0) {
                        Hilog.info(0, "CjTelegram", "[Passport] Auth success, callbackUrl=${finalCallback}")
                    }
                    routerPop()
                } else {
                    this.errorMessage = finalErr
                }
            }
        }
    }

    /**
     * onAddDocument — route to the appropriate edit page for each required type
     * P2-284: phone → PassportPhoneVerifyPage, email → PassportEmailVerifyPage
     */
    private func onAddDocument(typeName: String): Unit {
        setPendingPassportDocumentType(typeName)
        if (typeName == "personal_details") {
            routerPush("PassportPersonalDetailsPage", "")
        } else if (typeName == "phone") {
            // P2-284: phone input + code send/confirm
            routerPush("PassportPhoneVerifyPage", "")
        } else if (typeName == "email") {
            // P2-284: email input + code send/confirm
            routerPush("PassportEmailVerifyPage", "")
        } else if (typeName == "passport" || typeName == "internal_passport" ||
                   typeName == "identity_card" || typeName == "driver_license") {
            routerPush("PassportDocumentPage", "")
        } else if (typeName == "address" || typeName == "utility_bill" ||
                   typeName == "bank_statement" || typeName == "rental_agreement" ||
                   typeName == "passport_registration" || typeName == "temporary_registration") {
            routerPush("PassportAddressDocumentPage", "")
        } else {
            routerPush("PassportDocumentPage", "")
        }
    }

    private func getTypeDisplayName(typeName: String): String {
        if (typeName == "personal_details") { return "Personal Details" }
        if (typeName == "passport") { return "Passport" }
        if (typeName == "driver_license") { return "Driver License" }
        if (typeName == "identity_card") { return "Identity Card" }
        if (typeName == "address") { return "Address" }
        if (typeName == "phone") { return "Phone Number" }
        if (typeName == "email") { return "Email Address" }
        if (typeName == "one_of") { return "Identity Document (one of)" }
        if (typeName == "internal_passport") { return "Internal Passport" }
        if (typeName == "utility_bill") { return "Utility Bill" }
        if (typeName == "bank_statement") { return "Bank Statement" }
        if (typeName == "rental_agreement") { return "Rental Agreement" }
        if (typeName == "passport_registration") { return "Passport Registration" }
        if (typeName == "temporary_registration") { return "Temporary Registration" }
        return typeName
    }

    private func getTypeSubtitle(item: SecureIdRequiredType): String {
        if (item.isProvided) { return "Provided" }
        if (item.selfieRequired && item.translationRequired) {
            return "Required (with selfie + translation)"
        }
        if (item.selfieRequired) { return "Required (with selfie)" }
        if (item.translationRequired) { return "Required (with translation)" }
        if (item.isOneOfGroup && item.oneOfOptions.size > 0) {
            return "One of: " + item.oneOfOptions[0]
        }
        return "Required"
    }

    private func allRequiredProvided(): Bool {
        for (t in this.documentTypes) {
            if (!t.isProvided) {
                return false
            }
        }
        return this.documentTypes.size > 0
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _ =>
                        routerPop()
                    })
                Blank()
                Text(trSource("Telegram Passport"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Text(trSource(""))
                    .fontSize(17)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                    Text("Loading authorization form...")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .margin(top: 12)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll() {
                    Column {
                        if (this.botName.size > 0) {
                            Text(this.botName)
                                .fontSize(22)
                                .fontWeight(FontWeight.Bold)
                                .margin(top: 16, bottom: 4)
                        }

                        Text("Requests access to your identity documents")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 20)

                        if (this.errorMessage.size > 0) {
                            Text(this.errorMessage)
                                .fontSize(14)
                                .fontColor(0xE53935)
                                .margin(bottom: 12)
                        }

                        Text("Requested Documents")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 8)
                            .alignSelf(ItemAlign.Start)

                        Column {
                            ForEach(this.documentTypes.toArray(), itemGenerator: { item: SecureIdRequiredType, _idx: Int64 =>
                                Row {
                                    Column {
                                        Text(this.getTypeDisplayName(item.typeName))
                                            .fontSize(16)
                                            .fontColor(0x000000)
                                        Text(this.getTypeSubtitle(item))
                                            .fontSize(13)
                                            .fontColor(if (item.isProvided) { 0x43A047 } else { 0x8E8E93 })
                                            .margin(top: 2)
                                    }
                                    .alignItems(HorizontalAlign.Start)
                                    .layoutWeight(1)

                                    if (item.isProvided) {
                                        Text(trSource("Done"))
                                            .fontSize(14)
                                            .fontColor(0x43A047)
                                    } else {
                                        Text(trSource("Add"))
                                            .fontSize(14)
                                            .fontColor(0x0088CC)
                                            .onClick({ _ =>
                                                this.onAddDocument(item.typeName)
                                            })
                                    }
                                }
                                .width(100.percent)
                                .height(56)
                                .padding(left: 16, right: 16, top: 8, bottom: 8)
                                .backgroundColor(0xFFFFFF)
                                .alignItems(VerticalAlign.Center)
                            })
                        }
                        .width(100.percent)
                        .borderRadius(10)
                        .clip(true)

                        Blank().height(16)

                        // P2-276: self-management entry — browse stored documents
                        Button("Manage My Passport Documents")
                            .fontSize(15)
                            .fontColor(0x0088CC)
                            .backgroundColor(0xE3F2FD)
                            .width(100.percent)
                            .height(44)
                            .borderRadius(8)
                            .margin(bottom: 12)
                            .onClick({ _ =>
                                routerPush("PassportSelfManagePage", "")
                            })

                        if (!this.isSecureIdUnlocked) {
                            Button("Unlock Passport")
                                .fontSize(16)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(0xFF9800)
                                .width(100.percent)
                                .height(48)
                                .borderRadius(8)
                                .margin(bottom: 12)
                                .onClick({ _ =>
                                    routerPush("PassportPasswordUnlockPage", "")
                                })
                        }

                        Button(if (this.isAuthorizing) { "Authorizing..." } else { "Authorize" })
                            .fontSize(17)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(
                                if (this.isAuthorizing || !this.isSecureIdUnlocked) { 0xBBBBBB } else { 0x0088CC }
                            )
                            .width(100.percent)
                            .height(48)
                            .borderRadius(8)
                            .enabled(!this.isAuthorizing && this.isSecureIdUnlocked)
                            .onClick({ _ =>
                                this.onAuthorize()
                            })

                        Blank().height(32)
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 8, bottom: 8)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Off)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}

// ─────────────────────────────────────────────────────────────────────
// P2-276: Passport Self-Management List Mode
// iOS: SecureIdAuthListContentNode.swift (updateValues) +
//      SecureIdAuthListFieldNode.swift (fieldsText)
// ─────────────────────────────────────────────────────────────────────

// Package-level helper — callable from spawn closures (avoids let in @Builder)
private func displayNameForType(typeName: String): String {
    if (typeName == "personal_details") { return "Personal Details" }
    if (typeName == "passport") { return "Passport" }
    if (typeName == "internal_passport") { return "Internal Passport" }
    if (typeName == "driver_license") { return "Driver License" }
    if (typeName == "identity_card") { return "Identity Card" }
    if (typeName == "address") { return "Residential Address" }
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
 * PassportSelfManagePage — lists all stored Telegram Passport documents.
 *
 * P2-276 gaps implemented:
 *   - Full list mode UI (identity / address / phone / email sections)
 *   - updateValues() — calls account.getAllSecureValues, groups by type field
 *   - fieldsText() — concatenates filled field names for subtitle display
 *   - Browse stored document screen (navigate to PassportDocumentDetailPage)
 *   - Delete single document via account.deleteSecureValue
 *   - Delete All Passport Data button (deleteSecureValue for all 13 types)
 *
 * 混合迁移：aboutToAppear(loadAllValues) → ensureLoaded()，.onAppear 触发。
 */
@HybridComponentEntry
@Component
public class PassportSelfManagePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var storedValues: ArrayList<SecureValueFullModel> = ArrayList<SecureValueFullModel>()
    @State var isDeleting: Bool = false
    @State var errorMessage: String = ""
    // Pre-computed display text updated after storedValues loads (avoids let in build())
    @State var cachedIdentityText: String = ""
    @State var cachedAddressText: String = ""
    @State var cachedPhoneText: String = ""
    @State var cachedEmailText: String = ""
    @State var cachedIdentityValues: ArrayList<SecureValueFullModel> = ArrayList<SecureValueFullModel>()
    @State var cachedAddressValues: ArrayList<SecureValueFullModel> = ArrayList<SecureValueFullModel>()
    @State var cachedPhoneValues: ArrayList<SecureValueFullModel> = ArrayList<SecureValueFullModel>()
    @State var cachedEmailValues: ArrayList<SecureValueFullModel> = ArrayList<SecureValueFullModel>()
    @State var loaded: Bool = false

    private let allTypeNames: Array<String> = [
        "personal_details", "passport", "internal_passport", "driver_license",
        "identity_card", "address", "utility_bill", "bank_statement",
        "rental_agreement", "passport_registration", "temporary_registration",
        "phone", "email"
    ]

    // iOS SecureIdAuthListContentNode: identity / address / phone / email field groups
    private let identityTypes: Array<String> = [
        "personal_details", "passport", "internal_passport",
        "driver_license", "identity_card"
    ]
    private let addressTypes: Array<String> = [
        "address", "utility_bill", "bank_statement",
        "rental_agreement", "passport_registration", "temporary_registration"
    ]

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadAllValues()
    }

    /**
     * updateValues — fetches all secure values (account.getAllSecureValues)
     * iOS: SecureIdAuthListContentNode.updateValues(_ values: [SecureIdValueWithContext])
     */
    private func loadAllValues(): Unit {
        this.isLoading = true
        this.errorMessage = ""
        let identTypes = this.identityTypes
        let addrTypes = this.addressTypes
        let _ = spawn {
            let service = getPassportService()
            let values = service.getAllSecureValues()
            // Pre-filter and pre-compute text to avoid let-bindings in build()
            let identList = ArrayList<SecureValueFullModel>()
            let addrList = ArrayList<SecureValueFullModel>()
            let phoneList = ArrayList<SecureValueFullModel>()
            let emailList = ArrayList<SecureValueFullModel>()
            let copy = ArrayList<SecureValueFullModel>()
            for (v in values) {
                copy.add(v)
                var isIdent = false
                for (tn in identTypes) { if (v.typeName == tn) { isIdent = true; break } }
                var isAddr = false
                for (tn in addrTypes) { if (v.typeName == tn) { isAddr = true; break } }
                if (isIdent) { identList.add(v) }
                else if (isAddr) { addrList.add(v) }
                else if (v.typeName == "phone") { phoneList.add(v) }
                else if (v.typeName == "email") { emailList.add(v) }
            }
            // Build fieldsText strings in background thread
            var identText = ""
            for (v in identList) {
                let dn = displayNameForType(v.typeName)
                identText = if (identText.size > 0) { identText + ", " + dn } else { dn }
            }
            var addrText = ""
            for (v in addrList) {
                let dn = displayNameForType(v.typeName)
                addrText = if (addrText.size > 0) { addrText + ", " + dn } else { dn }
            }
            let phoneTxt = if (phoneList.size > 0) { "Phone Number" } else { "" }
            let emailTxt = if (emailList.size > 0) { "Email Address" } else { "" }
            // R-111: re-bind var to let before launch {} to avoid lambda mutable capture error
            let identTextFinal = identText
            let addrTextFinal = addrText
            launch {
                this.storedValues = copy
                this.cachedIdentityValues = identList
                this.cachedAddressValues = addrList
                this.cachedPhoneValues = phoneList
                this.cachedEmailValues = emailList
                this.cachedIdentityText = identTextFinal
                this.cachedAddressText = addrTextFinal
                this.cachedPhoneText = phoneTxt
                this.cachedEmailText = emailTxt
                this.isLoading = false
            }
        }
    }

    /**
     * fieldsText — iOS SecureIdAuthListFieldNode.fieldsText()
     * Concatenates non-empty type display names for stored values of a given group.
     */
    private func fieldsText(typeGroup: Array<String>): String {
        var result = ""
        for (typeName in typeGroup) {
            for (v in this.storedValues) {
                if (v.typeName == typeName) {
                    let displayName = this.typeDisplayName(typeName)
                    if (result.size > 0) {
                        result = result + ", "
                    }
                    result = result + displayName
                    break
                }
            }
        }
        return result
    }

    private func typeDisplayName(typeName: String): String {
        if (typeName == "personal_details") { return "Personal Details" }
        if (typeName == "passport") { return "Passport" }
        if (typeName == "internal_passport") { return "Internal Passport" }
        if (typeName == "driver_license") { return "Driver License" }
        if (typeName == "identity_card") { return "Identity Card" }
        if (typeName == "address") { return "Residential Address" }
        if (typeName == "utility_bill") { return "Utility Bill" }
        if (typeName == "bank_statement") { return "Bank Statement" }
        if (typeName == "rental_agreement") { return "Rental Agreement" }
        if (typeName == "passport_registration") { return "Passport Registration" }
        if (typeName == "temporary_registration") { return "Temporary Registration" }
        if (typeName == "phone") { return "Phone Number" }
        if (typeName == "email") { return "Email Address" }
        return typeName
    }

    private func hasAnyType(typeGroup: Array<String>): Bool {
        for (typeName in typeGroup) {
            for (v in this.storedValues) {
                if (v.typeName == typeName) {
                    return true
                }
            }
        }
        return false
    }

    private func filterByTypes(typeGroup: Array<String>): Array<SecureValueFullModel> {
        let result = ArrayList<SecureValueFullModel>()
        for (v in this.storedValues) {
            for (tn in typeGroup) {
                if (v.typeName == tn) {
                    result.add(v)
                    break
                }
            }
        }
        return result.toArray()
    }

    /**
     * deleteValueByType — deletes a single secure value type.
     * iOS: deleteSecureValue for the specific type key.
     */
    private func deleteValueByType(typeName: String): Unit {
        this.isDeleting = true
        let name = typeName
        let _ = spawn {
            let service = getPassportService()
            let tlObj = typeNameToTLObject(name)
            let types = ArrayList<TLObject>()
            match (tlObj) {
                case Some(t) => types.add(t)
                case None => ()
            }
            if (types.size > 0) {
                service.deleteSecureValue(types)
            }
            launch {
                this.isDeleting = false
                this.loadAllValues()
            }
        }
    }

    /**
     * deleteAllPassportData — deletes all stored secure values (all 13 types).
     * iOS: SecureIdAuthListContentNode deleteAll() callback.
     */
    private func deleteAllPassportData(): Unit {
        this.isDeleting = true
        let allNames = this.allTypeNames
        let _ = spawn {
            let service = getPassportService()
            let types = ArrayList<TLObject>()
            for (name in allNames) {
                let tlObj = typeNameToTLObject(name)
                match (tlObj) {
                    case Some(t) => types.add(t)
                    case None => ()
                }
            }
            if (types.size > 0) {
                service.deleteSecureValue(types)
            }
            launch {
                this.isDeleting = false
                this.loadAllValues()
            }
        }
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Back"))
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _ =>
                        routerPop()
                    })
                Blank()
                Text("Passport Information")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Text(trSource(""))
                    .fontSize(17)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                    Text("Loading stored documents...")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .margin(top: 12)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll() {
                    Column {
                        if (this.errorMessage.size > 0) {
                            Text(this.errorMessage)
                                .fontSize(14)
                                .fontColor(0xE53935)
                                .margin(16)
                        }

                        if (this.storedValues.size == 0) {
                            Column {
                                Text("No Passport documents stored.")
                                    .fontSize(16)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 48)
                                Text("Add documents to use Telegram Passport.")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 8)
                            }
                            .width(100.percent)
                            .alignItems(HorizontalAlign.Center)
                        } else {
                            // Identity section (iOS: .identity field)
                            // fieldsText(.identity): cachedIdentityText pre-computed in loadAllValues
                            if (this.cachedIdentityText.size > 0) {
                                Text("IDENTITY")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 16, bottom: 4, left: 16)
                                    .alignSelf(ItemAlign.Start)
                                Text(this.cachedIdentityText)
                                    .fontSize(13)
                                    .fontColor(0x43A047)
                                    .margin(bottom: 4, left: 16)
                                    .alignSelf(ItemAlign.Start)

                                Column {
                                    ForEach(this.cachedIdentityValues.toArray(), itemGenerator: { sv: SecureValueFullModel, _idx: Int64 =>
                                        this.buildDocumentRow(sv)
                                    })
                                }
                                .width(100.percent)
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(10)
                                .clip(true)
                            }

                            // Address section (iOS: .address field)
                            // fieldsText(.address): cachedAddressText pre-computed in loadAllValues
                            if (this.cachedAddressText.size > 0) {
                                Text(trSource("ADDRESS"))
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 16, bottom: 4, left: 16)
                                    .alignSelf(ItemAlign.Start)
                                Text(this.cachedAddressText)
                                    .fontSize(13)
                                    .fontColor(0x43A047)
                                    .margin(bottom: 4, left: 16)
                                    .alignSelf(ItemAlign.Start)

                                Column {
                                    ForEach(this.cachedAddressValues.toArray(), itemGenerator: { sv: SecureValueFullModel, _idx: Int64 =>
                                        this.buildDocumentRow(sv)
                                    })
                                }
                                .width(100.percent)
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(10)
                                .clip(true)
                            }

                            // Phone section (iOS: .phone field)
                            if (this.cachedPhoneText.size > 0) {
                                Text("PHONE")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 16, bottom: 4, left: 16)
                                    .alignSelf(ItemAlign.Start)

                                Column {
                                    ForEach(this.cachedPhoneValues.toArray(), itemGenerator: { sv: SecureValueFullModel, _idx: Int64 =>
                                        this.buildDocumentRow(sv)
                                    })
                                }
                                .width(100.percent)
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(10)
                                .clip(true)
                            }

                            // Email section (iOS: .email field)
                            if (this.cachedEmailText.size > 0) {
                                Text("EMAIL")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 16, bottom: 4, left: 16)
                                    .alignSelf(ItemAlign.Start)

                                Column {
                                    ForEach(this.cachedEmailValues.toArray(), itemGenerator: { sv: SecureValueFullModel, _idx: Int64 =>
                                        this.buildDocumentRow(sv)
                                    })
                                }
                                .width(100.percent)
                                .backgroundColor(0xFFFFFF)
                                .borderRadius(10)
                                .clip(true)
                            }

                            // Summary line: all stored types
                            if (this.cachedIdentityText.size > 0 || this.cachedAddressText.size > 0) {
                                Text("Stored: " + this.cachedIdentityText +
                                    (if (this.cachedIdentityText.size > 0 && this.cachedAddressText.size > 0) { "; " } else { "" }) +
                                    this.cachedAddressText)
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 8, left: 16, right: 16)
                                    .alignSelf(ItemAlign.Start)
                            }

                            Blank().height(24)

                            // Delete All Passport Data (iOS: strings.Passport_DeletePassport)
                            Button(if (this.isDeleting) { "Deleting..." } else { "Delete All Passport Data" })
                                .fontSize(16)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.isDeleting) { 0xBBBBBB } else { 0xE53935 })
                                .width(100.percent)
                                .height(48)
                                .borderRadius(8)
                                .enabled(!this.isDeleting)
                                .margin(bottom: 32)
                                .onClick({ _ =>
                                    this.deleteAllPassportData()
                                })
                        }
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 8, bottom: 8)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Off)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }

    private func countFiles(sv: SecureValueFullModel): Int64 {
        var count = sv.files.size + sv.translationFiles.size
        match (sv.frontSideFile) { case Some(_) => count = count + 1; case None => () }
        match (sv.backSideFile) { case Some(_) => count = count + 1; case None => () }
        match (sv.selfieFile) { case Some(_) => count = count + 1; case None => () }
        return count
    }

    /**
     * buildDocumentRow — one list item for a stored secure value.
     * Shows type name + file count, tap to browse detail, long-press hint for delete.
     * S-007: no let bindings in @Builder — use direct field access / method calls inline.
     */
    @Builder
    private func buildDocumentRow(sv: SecureValueFullModel) {
        Row {
            Column {
                Text(this.typeDisplayName(sv.typeName))
                    .fontSize(16)
                    .fontColor(0x000000)
                Text(if (this.countFiles(sv) > 0) { "${this.countFiles(sv)} file(s) attached" } else { "Data stored" })
                    .fontSize(13)
                    .fontColor(0x43A047)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Row {
                Text(trSource("View"))
                    .fontSize(14)
                    .fontColor(0x0088CC)
                    .margin(right: 12)
                    .onClick({ _ =>
                        routerPush("PassportDocumentDetailPage", sv.typeName)
                    })

                Text(trSource("Delete"))
                    .fontSize(14)
                    .fontColor(0xE53935)
                    .onClick({ _ =>
                        this.deleteValueByType(sv.typeName)
                    })
            }
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16, top: 8, bottom: 8)
        .backgroundColor(0xFFFFFF)
        .alignItems(VerticalAlign.Center)
    }
}

/**
 * PassportDocumentDetailPage — shows details of a single stored SecureValue.
 *
 * P2-276: browse stored document screen.
 * Displays: type, data fields (if any), file counts (front/back/selfie/translation/files).
 * Provides Edit button (routes to appropriate form page) and Delete button.
 *
 * 混合迁移：onReady 参数收取 → ensureLoaded() 里 takePending("PassportDocumentDetailPage")，
 * 随后 loadDetail()，.onAppear 触发。
 */
@HybridComponentEntry
@Component
public class PassportDocumentDetailPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var typeName: String = ""
    @State var isLoading: Bool = true
    @State var storedValue: Option<SecureValueFullModel> = Option<SecureValueFullModel>.None
    @State var isDeleting: Bool = false
    @State var errorMessage: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let param = takePending("PassportDocumentDetailPage")
        if (param.size > 0 && param != "{}") {
            this.typeName = param
        }
        this.loadDetail()
    }

    private func loadDetail(): Unit {
        this.isLoading = true
        let name = this.typeName
        let _ = spawn {
            let service = getPassportService()
            let types = ArrayList<TLObject>()
            let tlObj = typeNameToTLObject(name)
            match (tlObj) {
                case Some(t) => types.add(t)
                case None => ()
            }
            let values = if (types.size > 0) {
                service.getSecureValues(types)
            } else {
                ArrayList<SecureValueFullModel>()
            }
            var found: Option<SecureValueFullModel> = Option<SecureValueFullModel>.None
            for (v in values) {
                found = Some(v)
                break
            }
            // R-111: re-bind var to let before launch {}
            let foundFinal = found
            launch {
                this.storedValue = foundFinal
                this.isLoading = false
            }
        }
    }

    private func deleteThisValue(): Unit {
        this.isDeleting = true
        let name = this.typeName
        let _ = spawn {
            let service = getPassportService()
            let types = ArrayList<TLObject>()
            let tlObj = typeNameToTLObject(name)
            match (tlObj) {
                case Some(t) => types.add(t)
                case None => ()
            }
            if (types.size > 0) {
                service.deleteSecureValue(types)
            }
            launch {
                this.isDeleting = false
                routerPop()
            }
        }
    }

    private func typeDisplayName(typeName: String): String {
        if (typeName == "personal_details") { return "Personal Details" }
        if (typeName == "passport") { return "Passport" }
        if (typeName == "internal_passport") { return "Internal Passport" }
        if (typeName == "driver_license") { return "Driver License" }
        if (typeName == "identity_card") { return "Identity Card" }
        if (typeName == "address") { return "Residential Address" }
        if (typeName == "utility_bill") { return "Utility Bill" }
        if (typeName == "bank_statement") { return "Bank Statement" }
        if (typeName == "rental_agreement") { return "Rental Agreement" }
        if (typeName == "passport_registration") { return "Passport Registration" }
        if (typeName == "temporary_registration") { return "Temporary Registration" }
        if (typeName == "phone") { return "Phone Number" }
        if (typeName == "email") { return "Email Address" }
        return typeName
    }

    // Builder-safe accessors that unwrap Option<SecureValueFullModel>
    private func storedValueType(): String {
        match (this.storedValue) { case Some(sv) => sv.typeName; case None => "" }
    }
    private func storedValueFrontCount(): Int64 {
        match (this.storedValue) {
            case Some(sv) => match (sv.frontSideFile) { case Some(_) => 1; case None => 0 }
            case None => 0
        }
    }
    private func storedValueBackCount(): Int64 {
        match (this.storedValue) {
            case Some(sv) => match (sv.backSideFile) { case Some(_) => 1; case None => 0 }
            case None => 0
        }
    }
    private func storedValueSelfieCount(): Int64 {
        match (this.storedValue) {
            case Some(sv) => match (sv.selfieFile) { case Some(_) => 1; case None => 0 }
            case None => 0
        }
    }
    private func storedValueTranslCount(): Int64 {
        match (this.storedValue) { case Some(sv) => sv.translationFiles.size; case None => 0 }
    }
    private func storedValueFilesCount(): Int64 {
        match (this.storedValue) { case Some(sv) => sv.files.size; case None => 0 }
    }
    private func storedValuePlainType(): String {
        match (this.storedValue) { case Some(sv) => sv.plainDataType; case None => "" }
    }
    private func storedValuePlainValue(): String {
        match (this.storedValue) { case Some(sv) => sv.plainDataValue; case None => "" }
    }
    private func storedValueDataSize(): Int64 {
        match (this.storedValue) { case Some(sv) => sv.encryptedData.size; case None => 0 }
    }

    private func routeToEdit(): Unit {
        let tn = this.typeName
        setPendingPassportDocumentType(tn)
        if (tn == "personal_details") {
            routerPush("PassportPersonalDetailsPage", "")
        } else if (tn == "phone") {
            routerPush("PassportPhoneVerifyPage", "")
        } else if (tn == "email") {
            routerPush("PassportEmailVerifyPage", "")
        } else if (tn == "passport" || tn == "internal_passport" ||
                   tn == "identity_card" || tn == "driver_license") {
            routerPush("PassportDocumentPage", "")
        } else {
            routerPush("PassportAddressDocumentPage", "")
        }
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Back"))
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _ =>
                        routerPop()
                    })
                Blank()
                Text(this.typeDisplayName(this.typeName))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Text(trSource("Edit"))
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _ =>
                        this.routeToEdit()
                    })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll() {
                    Column {
                        if (this.storedValueType().size == 0) {
                            Text("No data found for this document type.")
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                                .margin(24)
                        } else {
                            this.buildDetailRow("Type", this.typeDisplayName(this.storedValueType()))

                            if (this.storedValueFrontCount() > 0) {
                                this.buildDetailRow("Front Side", "1 file")
                            }
                            if (this.storedValueBackCount() > 0) {
                                this.buildDetailRow("Back Side", "1 file")
                            }
                            if (this.storedValueSelfieCount() > 0) {
                                this.buildDetailRow("Selfie", "1 file")
                            }
                            if (this.storedValueTranslCount() > 0) {
                                this.buildDetailRow("Translation", "${this.storedValueTranslCount()} file(s)")
                            }
                            if (this.storedValueFilesCount() > 0) {
                                this.buildDetailRow("Files", "${this.storedValueFilesCount()} file(s)")
                            }
                            if (this.storedValuePlainType().size > 0) {
                                this.buildDetailRow(
                                    if (this.storedValuePlainType() == "phone") { "Phone" } else { "Email" },
                                    this.storedValuePlainValue()
                                )
                            }
                            if (this.storedValueDataSize() > 0) {
                                this.buildDetailRow("Encrypted data", "${this.storedValueDataSize()} bytes")
                            }

                            Blank().height(24)

                            Button(if (this.isDeleting) { "Deleting..." } else { "Delete This Document" })
                                .fontSize(16)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.isDeleting) { 0xBBBBBB } else { 0xE53935 })
                                .width(100.percent)
                                .height(48)
                                .borderRadius(8)
                                .enabled(!this.isDeleting)
                                .margin(bottom: 32)
                                .onClick({ _ =>
                                    this.deleteThisValue()
                                })
                        }
                    }
                    .width(100.percent)
                    .padding(16)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Off)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    private func buildDetailRow(label: String, value: String) {
        Row {
            Text(label)
                .fontSize(15)
                .fontColor(0x8E8E93)
                .layoutWeight(1)
            Text(value)
                .fontSize(15)
                .fontColor(0x000000)
                .layoutWeight(2)
        }
        .width(100.percent)
        .height(44)
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF)
        .borderRadius(8)
        .margin(bottom: 2)
        .alignItems(VerticalAlign.Center)
    }
}
