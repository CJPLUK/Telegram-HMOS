package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getPassportService, getPendingPassportDocumentType, getCachedSecureIdAccessContext}
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * P2-278 地址证明文档表单 (PassportAddressDocumentPage)（混合工程迁移版）
 *
 * Covers: utility_bill / bank_statement / rental_agreement /
 *         passport_registration / temporary_registration
 *
 * TL ctors:
 *   secureValueTypeUtilityBill#fc36954e
 *   secureValueTypeBankStatement#89137c0d
 *   secureValueTypeRentalAgreement#8b883488
 *   secureValueTypePassportRegistration#99e3806a
 *   secureValueTypeTemporaryRegistration#ea02ec33
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容 + .onAppear
 *  - aboutToAppear 有实逻辑（getPendingPassportDocumentType）→ ensureLoaded()
 *  - pop() → routerPop()
 */
@HybridComponentEntry
@Component
public class PassportAddressDocumentPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var documentSubType: String = "utility_bill"
    @State var selectedSubTypeIndex: Int32 = 0

    @State var street1: String = ""
    @State var street2: String = ""
    @State var city: String = ""
    @State var state: String = ""
    @State var postcode: String = ""
    @State var country: String = ""

    @State var isSaving: Bool = false
    @State var validationError: String = ""

    @State var loaded: Bool = false

    private let subTypes: Array<String> = [
        "utility_bill",
        "bank_statement",
        "rental_agreement",
        "passport_registration",
        "temporary_registration"
    ]
    private let subTypeLabels: Array<String> = [
        "Utility Bill",
        "Bank Statement",
        "Rental Agreement",
        "Passport Registration",
        "Temporary Registration"
    ]

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let pending = getPendingPassportDocumentType()
        let idx = this.indexForSubType(pending)
        if (idx >= 0) {
            this.documentSubType = pending
            this.selectedSubTypeIndex = Int32(idx)
        }
    }

    private func indexForSubType(typeName: String): Int64 {
        if (typeName == "utility_bill") { return 0 }
        if (typeName == "bank_statement") { return 1 }
        if (typeName == "rental_agreement") { return 2 }
        if (typeName == "passport_registration") { return 3 }
        if (typeName == "temporary_registration") { return 4 }
        return -1
    }

    private func subTypeDisplayName(typeName: String): String {
        if (typeName == "utility_bill") { return "Utility Bill" }
        if (typeName == "bank_statement") { return "Bank Statement" }
        if (typeName == "rental_agreement") { return "Rental Agreement" }
        if (typeName == "passport_registration") { return "Passport Registration" }
        if (typeName == "temporary_registration") { return "Temporary Registration" }
        return "Address Document"
    }

    private func buildSubTypeOptions(): Array<SelectOption> {
        let opts: Array<SelectOption> = [
            SelectOption(value: "Utility Bill"),
            SelectOption(value: "Bank Statement"),
            SelectOption(value: "Rental Agreement"),
            SelectOption(value: "Passport Registration"),
            SelectOption(value: "Temporary Registration")
        ]
        return opts
    }

    private func validateForm(): String {
        if (this.street1.size == 0) { return "Street address is required" }
        if (this.city.size == 0) { return "City is required" }
        if (this.postcode.size == 0) { return "Postcode is required" }
        if (this.country.size == 0) { return "Country is required" }
        return ""
    }

    private func addressDocTypeCtorForName(typeName: String): UInt32 {
        if (typeName == "utility_bill") { return 0xfc36954e }
        if (typeName == "bank_statement") { return 0x89137c0d }
        if (typeName == "rental_agreement") { return 0x8b883488 }
        if (typeName == "passport_registration") { return 0x99e3806a }
        if (typeName == "temporary_registration") { return 0xea02ec33 }
        return 0xfc36954e
    }

    private func onSave(): Unit {
        let errMsg = this.validateForm()
        if (errMsg.size > 0) {
            this.validationError = errMsg
            return
        }
        let accessCtxOpt = getCachedSecureIdAccessContext()
        match (accessCtxOpt) {
            case None =>
                this.validationError = "Passport must be unlocked first. Please enter your Passport password."
                return
            case Some(_) => ()
        }
        this.validationError = ""
        this.isSaving = true
        let subType = this.documentSubType
        let s1 = this.street1
        let s2 = this.street2
        let cty = this.city
        let st = this.state
        let pc = this.postcode
        let ctr = this.country
        let docCtor = this.addressDocTypeCtorForName(subType)
        let _ = spawn {
            let service = getPassportService()
            var dataJson = "{\"street_line1\":\"" + s1 + "\","
            dataJson = dataJson + "\"street_line2\":\"" + s2 + "\","
            dataJson = dataJson + "\"city\":\"" + cty + "\","
            dataJson = dataJson + "\"state\":\"" + st + "\","
            dataJson = dataJson + "\"post_code\":\"" + pc + "\","
            dataJson = dataJson + "\"country_code\":\"" + ctr + "\","
            dataJson = dataJson + "\"doc_type\":\"" + subType + "\"}"
            let dataBytes = ByteUtils.stringToBytes(dataJson)
            match (getCachedSecureIdAccessContext()) {
                case Some(ctx) =>
                    let _ = service.encryptAndSaveSecureValue(dataBytes, docCtor, ctx)
                case None =>
                    Hilog.warn(0, "CjTelegram", "[P2-278] SecureId context not available at save time")
            }
            launch {
                this.isSaving = false
                routerPop()
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
                Text("Address Document")
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

            Scroll() {
                Column {
                    Text("Document Type")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)

                    Select(this.buildSubTypeOptions())
                        .selected(this.selectedSubTypeIndex)
                        .value(this.subTypeDisplayName(this.documentSubType))
                        .width(100.percent)
                        .height(44)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onSelect({ idx: Int32, _text: String =>
                            let newIdx = idx
                            if (newIdx >= 0 && Int64(newIdx) < Int64(5)) {
                                this.selectedSubTypeIndex = newIdx
                                this.documentSubType = this.subTypes[Int64(newIdx)]
                            }
                        })

                    Text(trSource("Address"))
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .margin(top: 24, bottom: 8)
                        .alignSelf(ItemAlign.Start)

                    Text("Street Line 1")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Street address", text: this.street1)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.street1 = v
                        })

                    Text("Street Line 2 (optional)")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Apt, suite, etc.", text: this.street2)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.street2 = v
                        })

                    Text(trSource("City"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: trSource("City"), text: this.city)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.city = v
                        })

                    Text("State / Region (optional)")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "State or region", text: this.state)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.state = v
                        })

                    Text(trSource("Postcode"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Postal code", text: this.postcode)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.postcode = v
                        })

                    Text(trSource("Country"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Country code (e.g. US, DE)", text: this.country)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.country = v
                        })

                    Text("Document Scan")
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .margin(top: 24, bottom: 8)
                        .alignSelf(ItemAlign.Start)

                    Column {
                        Text("Add document scan")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .height(80)
                    .backgroundColor(0xF2F2F7)
                    .borderRadius(12)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ _ =>
                        Hilog.info(0, "CjTelegram", "[P2-278] doc scan: links to P2-280 camera unit")
                    })

                    if (this.validationError.size > 0) {
                        Text(this.validationError)
                            .fontSize(13)
                            .fontColor(0xE53935)
                            .margin(top: 12)
                            .alignSelf(ItemAlign.Start)
                    }

                    Button(trSource("Save"))
                        .fontSize(17)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x0088CC)
                        .width(100.percent)
                        .height(48)
                        .margin(top: 24, bottom: 24)
                        .enabled(!this.isSaving)
                        .onClick({ _ =>
                            this.onSave()
                        })
                }
                .width(100.percent)
                .padding(16)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
