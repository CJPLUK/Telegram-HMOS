package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getPassportService, getCachedSecureIdAccessContext}
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * P2-279 个人详情表单 (PassportPersonalDetailsPage)
 *
 * Gaps fixed:
 *   - native-language 名字块 (nativeFirstName / nativeLastName / nativeMiddleName)
 *   - 居住国 / 公民国 Select picker (residenceCountry / citizenshipCountry)
 *   - 表单完整性校验 (必填字段非空)
 *   - secure value 真实调用 PassportService.saveSecureValue
 *
 * TL ctor: secureValueTypePersonalDetails#9d2a81e3
 *
 * Country selection uses a predefined list of common country codes;
 * a full ISO country picker is beyond this unit's scope.
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 */
@HybridComponentEntry
@Component
public class PassportPersonalDetailsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var firstName: String = ""
    @State var lastName: String = ""
    @State var middleName: String = ""
    @State var dateOfBirth: String = ""
    @State var gender: String = ""

    @State var nativeFirstName: String = ""
    @State var nativeLastName: String = ""
    @State var nativeMiddleName: String = ""

    @State var residenceCountryIndex: Int32 = 0
    @State var residenceCountry: String = ""
    @State var citizenshipCountryIndex: Int32 = 0
    @State var citizenshipCountry: String = ""

    @State var isSaving: Bool = false
    @State var validationError: String = ""

    private let countryCodes: Array<String> = [
        "", "RU", "US", "DE", "CN", "FR", "GB", "IT", "ES", "JP", "KR",
        "UA", "PL", "BY", "KZ", "UZ", "AZ", "AM", "GE", "TJ", "TM",
        "BR", "MX", "AR", "TR", "IN", "SA", "AE", "IL", "EG", "ZA",
        "CA", "AU", "NL", "SE", "NO", "DK", "FI", "CH", "AT", "BE",
        "PT", "CZ", "RO", "HU", "BG", "GR", "HR", "SK", "SI"
    ]
    private let countryLabels: Array<String> = [
        "(Select country)", "Russia", "United States", "Germany", "China",
        "France", "United Kingdom", "Italy", "Spain", "Japan", "South Korea",
        "Ukraine", "Poland", "Belarus", "Kazakhstan", "Uzbekistan",
        "Azerbaijan", "Armenia", "Georgia", "Tajikistan", "Turkmenistan",
        "Brazil", "Mexico", "Argentina", "Turkey", "India", "Saudi Arabia",
        "UAE", "Israel", "Egypt", "South Africa",
        "Canada", "Australia", "Netherlands", "Sweden", "Norway", "Denmark",
        "Finland", "Switzerland", "Austria", "Belgium",
        "Portugal", "Czechia", "Romania", "Hungary", "Bulgaria", "Greece",
        "Croatia", "Slovakia", "Slovenia"
    ]

    private func buildCountryOptions(): Array<SelectOption> {
        var opts = Array<SelectOption>(this.countryLabels.size, { i: Int64 =>
            SelectOption(value: this.countryLabels[i])
        })
        return opts
    }

    private func validateForm(): String {
        if (this.firstName.size == 0) { return "First name is required" }
        if (this.lastName.size == 0) { return "Last name is required" }
        if (this.dateOfBirth.size == 0) { return "Date of birth is required" }
        if (this.gender.size == 0) { return "Gender is required" }
        if (this.residenceCountry.size == 0) { return "Residence country is required" }
        if (this.citizenshipCountry.size == 0) { return "Citizenship country is required" }
        return ""
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
        let fn = this.firstName
        let ln = this.lastName
        let mn = this.middleName
        let dob = this.dateOfBirth
        let gnd = this.gender
        let nFn = this.nativeFirstName
        let nLn = this.nativeLastName
        let nMn = this.nativeMiddleName
        let res = this.residenceCountry
        let cit = this.citizenshipCountry
        let _ = spawn {
            let service = getPassportService()
            var dataJson = "{\"first_name\":\"" + fn + "\","
            dataJson = dataJson + "\"last_name\":\"" + ln + "\","
            dataJson = dataJson + "\"middle_name\":\"" + mn + "\","
            dataJson = dataJson + "\"birth_date\":\"" + dob + "\","
            dataJson = dataJson + "\"gender\":\"" + gnd + "\","
            dataJson = dataJson + "\"first_name_native\":\"" + nFn + "\","
            dataJson = dataJson + "\"last_name_native\":\"" + nLn + "\","
            dataJson = dataJson + "\"middle_name_native\":\"" + nMn + "\","
            dataJson = dataJson + "\"residence_country_code\":\"" + res + "\","
            dataJson = dataJson + "\"country_code\":\"" + cit + "\"}"
            let dataBytes = ByteUtils.stringToBytes(dataJson)
            match (getCachedSecureIdAccessContext()) {
                case Some(ctx) =>
                    // secureValueTypePersonalDetails#9d2a81e3
                    let _ = service.encryptAndSaveSecureValue(dataBytes, 0x9d2a81e3, ctx)
                case None =>
                    Hilog.warn(0, "CjTelegram", "[P2-279] SecureId context not available at save time")
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
                Text(trSource("Personal Details"))
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
                    Text("Legal Name")
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .margin(top: 16, bottom: 8)
                        .alignSelf(ItemAlign.Start)

                    Text(trSource("First Name"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "First name", text: this.firstName)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.firstName = v
                        })

                    Text(trSource("Last Name"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Last name", text: this.lastName)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.lastName = v
                        })

                    Text("Middle Name (optional)")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Middle name", text: this.middleName)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.middleName = v
                        })

                    Text(trSource("Date of Birth"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "DD.MM.YYYY", text: this.dateOfBirth)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.dateOfBirth = v
                        })

                    Text(trSource("Gender"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Male / Female", text: this.gender)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.gender = v
                        })

                    Text("Country of Citizenship")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    Select(this.buildCountryOptions())
                        .selected(this.citizenshipCountryIndex)
                        .value(if (this.citizenshipCountry.size > 0) {
                            this.citizenshipCountry
                        } else {
                            "(Select country)"
                        })
                        .width(100.percent)
                        .height(44)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onSelect({ idx: Int32, _text: String =>
                            let newIdx = idx
                            let codes = this.countryCodes
                            if (newIdx >= 0 && Int64(newIdx) < codes.size) {
                                this.citizenshipCountryIndex = newIdx
                                this.citizenshipCountry = codes[Int64(newIdx)]
                            }
                        })

                    Text("Country of Residence")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    Select(this.buildCountryOptions())
                        .selected(this.residenceCountryIndex)
                        .value(if (this.residenceCountry.size > 0) {
                            this.residenceCountry
                        } else {
                            "(Select country)"
                        })
                        .width(100.percent)
                        .height(44)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onSelect({ idx: Int32, _text: String =>
                            let newIdx = idx
                            let codes = this.countryCodes
                            if (newIdx >= 0 && Int64(newIdx) < codes.size) {
                                this.residenceCountryIndex = newIdx
                                this.residenceCountry = codes[Int64(newIdx)]
                            }
                        })

                    Text("Name in native language (optional)")
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .margin(top: 24, bottom: 8)
                        .alignSelf(ItemAlign.Start)

                    Text("Required when your name in passport uses non-Latin characters")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 12)
                        .alignSelf(ItemAlign.Start)

                    Text("First Name (native)")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "First name in native script", text: this.nativeFirstName)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.nativeFirstName = v
                        })

                    Text("Last Name (native)")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Last name in native script", text: this.nativeLastName)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.nativeLastName = v
                        })

                    Text("Middle Name (native, optional)")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Middle name in native script", text: this.nativeMiddleName)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.nativeMiddleName = v
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
    }
}
