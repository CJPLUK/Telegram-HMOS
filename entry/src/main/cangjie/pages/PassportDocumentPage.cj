package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import kit.CameraKit.CameraPosition
import ohos_app_cangjie_entry.services.{
    getPassportService, getPendingPassportDocumentType,
    setPendingPassportDocumentType, getCachedSecureIdAccessContext,
    setPendingPassportPhoto, getPendingPassportPhotoSlot,
    getPendingPassportPhotoPath, clearPendingPassportPhoto,
    UploadedSecureFile, getCameraService, getAppFilesDir
}
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * P2-277 身份文档表单 (PassportDocumentPage)（混合工程迁移版）
 *
 * Covers: passport / internal_passport / identity_card / driver_license
 * P2-280 Document Photo Capture: 每个 slot（front/back/selfie/translation）真实
 *   "Add Photo" 按钮，导航到 PassportDocumentCameraPage / PassportDocumentGalleryPage。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹 + .hideTitleBar，只留内容 + .onAppear
 *  - aboutToAppear 分两部分：文档类型初始化（一次性 ensureLoaded）+ 相机/相册返回时
 *    的 pending-photo 回填（每次 onAppear 都要跑，故 consumePendingPhoto 不加守卫）
 *  - pushPathByName → routerPush；pop → routerPop
 *
 * TL ctor references:
 *   secureValueTypePassport#3dac6a00 / InternalPassport#99a48f23 /
 *   IdentityCard#a0d0744b / DriverLicense#6e425c4
 */
@HybridComponentEntry
@Component
public class PassportDocumentPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var documentType: String = "passport"
    @State var selectedDocIndex: Int32 = 0

    @State var firstName: String = ""
    @State var lastName: String = ""
    @State var middleName: String = ""
    @State var dateOfBirth: String = ""
    @State var gender: String = ""
    @State var nationality: String = ""
    @State var documentNumber: String = ""
    @State var expiryDate: String = ""

    @State var nativeFirstName: String = ""
    @State var nativeLastName: String = ""
    @State var nativeMiddleName: String = ""

    // P2-280: Document photo slots — file paths after capture/selection
    @State var frontPhotoPath: String = ""
    @State var backPhotoPath: String = ""
    @State var selfiePhotoPath: String = ""
    @State var translationPhotoPath: String = ""

    @State var isSaving: Bool = false
    @State var isUploading: Bool = false
    @State var uploadProgressText: String = ""
    @State var validationError: String = ""

    @State var loaded: Bool = false

    private let docTypes: Array<String> = [
        "passport", "internal_passport", "identity_card", "driver_license"
    ]
    private let docLabels: Array<String> = [
        "Passport", "Internal Passport", "Identity Card", "Driver's License"
    ]

    /**
     * 一次性文档类型初始化（原 aboutToAppear 首段逻辑）。
     */
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let pending = getPendingPassportDocumentType()
        if (pending == "passport" || pending == "internal_passport" ||
            pending == "identity_card" || pending == "driver_license") {
            this.documentType = pending
            this.selectedDocIndex = this.indexForDocType(pending)
        }
    }

    /**
     * P2-280: 每次页面 onAppear 都需消费一次相机/相册返回的 pending photo（不加守卫）。
     * 从相机/相册页返回后，本混合页组件 .onAppear 会再次触发，读取并回填对应 slot。
     */
    private func consumePendingPhoto(): Unit {
        let slot = getPendingPassportPhotoSlot()
        let path = getPendingPassportPhotoPath()
        if (slot.size > 0 && path.size > 0) {
            let slotCopy = slot
            let pathCopy = path
            clearPendingPassportPhoto()
            if (slotCopy == "front") {
                this.frontPhotoPath = pathCopy
            } else if (slotCopy == "back") {
                this.backPhotoPath = pathCopy
            } else if (slotCopy == "selfie") {
                this.selfiePhotoPath = pathCopy
            } else if (slotCopy == "translation") {
                this.translationPhotoPath = pathCopy
            }
        }
    }

    private func indexForDocType(typeName: String): Int32 {
        if (typeName == "passport") { return 0 }
        if (typeName == "internal_passport") { return 1 }
        if (typeName == "identity_card") { return 2 }
        if (typeName == "driver_license") { return 3 }
        return 0
    }

    private func docDisplayName(typeName: String): String {
        if (typeName == "passport") { return "Passport" }
        if (typeName == "internal_passport") { return "Internal Passport" }
        if (typeName == "identity_card") { return "Identity Card" }
        if (typeName == "driver_license") { return "Driver's License" }
        return "Document"
    }

    private func buildDocTypeOptions(): Array<SelectOption> {
        let opts: Array<SelectOption> = [
            SelectOption(value: "Passport"),
            SelectOption(value: "Internal Passport"),
            SelectOption(value: "Identity Card"),
            SelectOption(value: "Driver's License")
        ]
        return opts
    }

    private func validateForm(): String {
        if (this.firstName.size == 0) { return "First name is required" }
        if (this.lastName.size == 0) { return "Last name is required" }
        if (this.dateOfBirth.size == 0) { return "Date of birth is required" }
        if (this.gender.size == 0) { return "Gender is required" }
        if (this.nationality.size == 0) { return "Nationality is required" }
        if (this.documentNumber.size == 0) { return "Document number is required" }
        if (this.expiryDate.size == 0) { return "Expiry date is required" }
        return ""
    }

    private func docTypeCtorForName(typeName: String): UInt32 {
        if (typeName == "passport") { return 0x3dac6a00 }
        if (typeName == "internal_passport") { return 0x99a48f23 }
        if (typeName == "identity_card") { return 0xa0d0744b }
        if (typeName == "driver_license") { return 0x06e425c4 }
        return 0x3dac6a00
    }

    /**
     * readFileBytes — reads a file from disk into a byte array.
     */
    private func readFileBytes(path: String): Array<Byte> {
        if (path.size == 0) {
            return Array<Byte>(0, repeat: 0)
        }
        try {
            let stat = FileIo.stat(path)
            let size = stat.size
            if (size <= 0) {
                return Array<Byte>(0, repeat: 0)
            }
            let file = FileIo.open(path, mode: 0o0)
            let buf = Array<Byte>(size, repeat: 0)
            let _ = FileIo.read(file.fd, buf)
            FileIo.close(file)
            return buf
        } catch (e: Exception) {
            Hilog.warn(0, "CjTelegram", "[P2-280] readFileBytes failed path=${path}")
            return Array<Byte>(0, repeat: 0)
        }
    }

    /**
     * onSave — P2-277 + P2-280
     */
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
        this.isUploading = true
        this.uploadProgressText = "Preparing..."

        let docType = this.documentType
        let fn = this.firstName
        let ln = this.lastName
        let mn = this.middleName
        let dob = this.dateOfBirth
        let gnd = this.gender
        let nat = this.nationality
        let docNum = this.documentNumber
        let exp = this.expiryDate
        let nFn = this.nativeFirstName
        let nLn = this.nativeLastName
        let nMn = this.nativeMiddleName
        let docCtor = this.docTypeCtorForName(docType)

        let frontPath = this.frontPhotoPath
        let backPath = this.backPhotoPath
        let selfiePath = this.selfiePhotoPath
        let translPath = this.translationPhotoPath

        let _ = spawn {
            let service = getPassportService()
            var dataJson = "{\"first_name\":\"" + fn + "\","
            dataJson = dataJson + "\"last_name\":\"" + ln + "\","
            dataJson = dataJson + "\"middle_name\":\"" + mn + "\","
            dataJson = dataJson + "\"birth_date\":\"" + dob + "\","
            dataJson = dataJson + "\"gender\":\"" + gnd + "\","
            dataJson = dataJson + "\"country_code\":\"" + nat + "\","
            dataJson = dataJson + "\"document_no\":\"" + docNum + "\","
            dataJson = dataJson + "\"expiry_date\":\"" + exp + "\","
            dataJson = dataJson + "\"first_name_native\":\"" + nFn + "\","
            dataJson = dataJson + "\"last_name_native\":\"" + nLn + "\","
            dataJson = dataJson + "\"middle_name_native\":\"" + nMn + "\"}"
            let dataBytes = ByteUtils.stringToBytes(dataJson)

            match (getCachedSecureIdAccessContext()) {
                case None =>
                    Hilog.warn(0, "CjTelegram", "[P2-277/280] SecureId context not available at save time")
                    launch {
                        this.isSaving = false
                        this.isUploading = false
                        this.validationError = "Passport session expired — please unlock again"
                    }
                case Some(ctx) =>
                    let accessSecret = ctx.secret

                    // Upload front side
                    launch { this.uploadProgressText = "Uploading front side..." }
                    var frontUploaded: Option<UploadedSecureFile> = None
                    if (frontPath.size > 0) {
                        let bytes = this.readFileBytes(frontPath)
                        if (bytes.size > 0) {
                            frontUploaded = service.uploadSecureIdFile(bytes, "front.jpg", accessSecret)
                        }
                    }

                    // Upload back side
                    launch { this.uploadProgressText = "Uploading back side..." }
                    var backUploaded: Option<UploadedSecureFile> = None
                    if (backPath.size > 0) {
                        let bytes = this.readFileBytes(backPath)
                        if (bytes.size > 0) {
                            backUploaded = service.uploadSecureIdFile(bytes, "back.jpg", accessSecret)
                        }
                    }

                    // Upload selfie
                    launch { this.uploadProgressText = "Uploading selfie..." }
                    var selfieUploaded: Option<UploadedSecureFile> = None
                    if (selfiePath.size > 0) {
                        let bytes = this.readFileBytes(selfiePath)
                        if (bytes.size > 0) {
                            selfieUploaded = service.uploadSecureIdFile(bytes, "selfie.jpg", accessSecret)
                        }
                    }

                    // Upload translation
                    launch { this.uploadProgressText = "Uploading translation..." }
                    let translUploaded = ArrayList<UploadedSecureFile>()
                    if (translPath.size > 0) {
                        let bytes = this.readFileBytes(translPath)
                        if (bytes.size > 0) {
                            let translResult = service.uploadSecureIdFile(bytes, "translation.jpg", accessSecret)
                            match (translResult) {
                                case Some(f) => translUploaded.add(f)
                                case None => ()
                            }
                        }
                    }

                    // Save SecureValue with data + all uploaded file refs
                    launch { this.uploadProgressText = "Saving..." }
                    let emptyFiles = ArrayList<UploadedSecureFile>()
                    let _ = service.saveSecureValueWithFiles(
                        dataBytes,
                        docCtor,
                        ctx,
                        frontUploaded,
                        backUploaded,
                        selfieUploaded,
                        translUploaded,
                        emptyFiles
                    )
                    launch {
                        this.isSaving = false
                        this.isUploading = false
                        this.uploadProgressText = ""
                        routerPop()
                    }
            }
        }
    }

    /**
     * openCameraForSlot — navigate to PassportDocumentCameraPage.
     */
    private func openCameraForSlot(slot: String): Unit {
        setPendingPassportPhoto(slot, "")
        routerPush("PassportDocumentCameraPage", slot)
    }

    /**
     * openGalleryForSlot — navigate to PassportDocumentGalleryPage.
     */
    private func openGalleryForSlot(slot: String): Unit {
        setPendingPassportPhoto(slot, "")
        routerPush("PassportDocumentGalleryPage", slot)
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
                Text(trSource("Identity Document"))
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

            if (this.isUploading) {
                Row {
                    LoadingProgress()
                        .width(20)
                        .height(20)
                    Text(this.uploadProgressText)
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(left: 8)
                }
                .width(100.percent)
                .height(32)
                .padding(left: 16, right: 16)
                .backgroundColor(0xFFF3CD)
                .justifyContent(FlexAlign.Start)
                .alignItems(VerticalAlign.Center)
            }

            Scroll() {
                Column {
                    Text("Document Type")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)

                    Select(this.buildDocTypeOptions())
                        .selected(this.selectedDocIndex)
                        .value(this.docDisplayName(this.documentType))
                        .width(100.percent)
                        .height(44)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onSelect({ idx: Int32, _text: String =>
                            let newIdx = idx
                            if (newIdx >= 0 && Int64(newIdx) < Int64(4)) {
                                this.selectedDocIndex = newIdx
                                this.documentType = this.docTypes[Int64(newIdx)]
                            }
                        })

                    Text(trSource("First Name"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
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

                    Text("Nationality (Country Code)")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "e.g. RU, US, DE", text: this.nationality)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.nationality = v
                        })

                    Text(trSource("Document Number"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "Document number", text: this.documentNumber)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.documentNumber = v
                        })

                    Text(trSource("Expiry Date"))
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 16, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    TextInput(placeholder: "DD.MM.YYYY", text: this.expiryDate)
                        .fontSize(16)
                        .height(44)
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(8)
                        .onChange({ v: String =>
                            this.expiryDate = v
                        })

                    Text("Name in native language (optional)")
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .margin(top: 24, bottom: 8)
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

                    // ---- P2-280: Document Photos Section ----
                    Text("Document Photos")
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .margin(top: 24, bottom: 8)
                        .alignSelf(ItemAlign.Start)

                    Text(trSource("Front Side"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    this.buildFrontPhotoSlot()

                    Text("Back Side")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 12, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    this.buildBackPhotoSlot()

                    Text("Selfie with Document")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 12, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    this.buildSelfiePhotoSlot()

                    Text("Translation (optional)")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 12, bottom: 4)
                        .alignSelf(ItemAlign.Start)
                    this.buildTranslPhotoSlot()

                    if (this.validationError.size > 0) {
                        Text(this.validationError)
                            .fontSize(13)
                            .fontColor(0xE53935)
                            .margin(top: 12)
                            .alignSelf(ItemAlign.Start)
                    }

                    Button(if (this.isSaving) { "Saving..." } else { "Save" })
                        .fontSize(17)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(if (this.isSaving) { 0xBBBBBB } else { 0x0088CC })
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
        .onAppear({ =>
            this.ensureLoaded()
            this.consumePendingPhoto()
        })
    }

    /**
     * buildFrontPhotoSlot
     */
    @Builder
    func buildFrontPhotoSlot() {
        if (this.frontPhotoPath.size > 0) {
            Row {
                Column {
                    Text("Photo Added")
                        .fontSize(14)
                        .fontColor(0x43A047)
                    Text(if (this.frontPhotoPath.size > 40) {
                        "..." + this.frontPhotoPath[this.frontPhotoPath.size - 30..this.frontPhotoPath.size]
                    } else { this.frontPhotoPath })
                        .fontSize(11)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text(trSource("Remove"))
                    .fontSize(14)
                    .fontColor(0xE53935)
                    .onClick({ _ => this.frontPhotoPath = "" })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 12, right: 12)
            .backgroundColor(0xF0FFF0)
            .borderRadius(8)
            .alignItems(VerticalAlign.Center)
        } else {
            Row {
                Button(trSource("Camera"))
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x0088CC)
                    .height(36)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick({ _ => this.openCameraForSlot("front") })
                Blank().width(8)
                Button(trSource("Gallery"))
                    .fontSize(14)
                    .fontColor(0x0088CC)
                    .backgroundColor(0xE3F2FD)
                    .height(36)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick({ _ => this.openGalleryForSlot("front") })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 0, right: 0, top: 8, bottom: 8)
        }
    }

    /**
     * buildBackPhotoSlot
     */
    @Builder
    func buildBackPhotoSlot() {
        if (this.backPhotoPath.size > 0) {
            Row {
                Column {
                    Text("Photo Added")
                        .fontSize(14)
                        .fontColor(0x43A047)
                    Text(if (this.backPhotoPath.size > 40) {
                        "..." + this.backPhotoPath[this.backPhotoPath.size - 30..this.backPhotoPath.size]
                    } else { this.backPhotoPath })
                        .fontSize(11)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text(trSource("Remove"))
                    .fontSize(14)
                    .fontColor(0xE53935)
                    .onClick({ _ => this.backPhotoPath = "" })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 12, right: 12)
            .backgroundColor(0xF0FFF0)
            .borderRadius(8)
            .alignItems(VerticalAlign.Center)
        } else {
            Row {
                Button(trSource("Camera"))
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x0088CC)
                    .height(36)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick({ _ => this.openCameraForSlot("back") })
                Blank().width(8)
                Button(trSource("Gallery"))
                    .fontSize(14)
                    .fontColor(0x0088CC)
                    .backgroundColor(0xE3F2FD)
                    .height(36)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick({ _ => this.openGalleryForSlot("back") })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 0, right: 0, top: 8, bottom: 8)
        }
    }

    /**
     * buildSelfiePhotoSlot
     */
    @Builder
    func buildSelfiePhotoSlot() {
        if (this.selfiePhotoPath.size > 0) {
            Row {
                Column {
                    Text("Photo Added")
                        .fontSize(14)
                        .fontColor(0x43A047)
                    Text(if (this.selfiePhotoPath.size > 40) {
                        "..." + this.selfiePhotoPath[this.selfiePhotoPath.size - 30..this.selfiePhotoPath.size]
                    } else { this.selfiePhotoPath })
                        .fontSize(11)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text(trSource("Remove"))
                    .fontSize(14)
                    .fontColor(0xE53935)
                    .onClick({ _ => this.selfiePhotoPath = "" })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 12, right: 12)
            .backgroundColor(0xF0FFF0)
            .borderRadius(8)
            .alignItems(VerticalAlign.Center)
        } else {
            Row {
                Button(trSource("Camera"))
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x0088CC)
                    .height(36)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick({ _ => this.openCameraForSlot("selfie") })
                Blank().width(8)
                Button(trSource("Gallery"))
                    .fontSize(14)
                    .fontColor(0x0088CC)
                    .backgroundColor(0xE3F2FD)
                    .height(36)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick({ _ => this.openGalleryForSlot("selfie") })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 0, right: 0, top: 8, bottom: 8)
        }
    }

    /**
     * buildTranslPhotoSlot
     */
    @Builder
    func buildTranslPhotoSlot() {
        if (this.translationPhotoPath.size > 0) {
            Row {
                Column {
                    Text("Photo Added")
                        .fontSize(14)
                        .fontColor(0x43A047)
                    Text(if (this.translationPhotoPath.size > 40) {
                        "..." + this.translationPhotoPath[this.translationPhotoPath.size - 30..this.translationPhotoPath.size]
                    } else { this.translationPhotoPath })
                        .fontSize(11)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text(trSource("Remove"))
                    .fontSize(14)
                    .fontColor(0xE53935)
                    .onClick({ _ => this.translationPhotoPath = "" })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 12, right: 12)
            .backgroundColor(0xF0FFF0)
            .borderRadius(8)
            .alignItems(VerticalAlign.Center)
        } else {
            Row {
                Button(trSource("Camera"))
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x0088CC)
                    .height(36)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick({ _ => this.openCameraForSlot("translation") })
                Blank().width(8)
                Button(trSource("Gallery"))
                    .fontSize(14)
                    .fontColor(0x0088CC)
                    .backgroundColor(0xE3F2FD)
                    .height(36)
                    .layoutWeight(1)
                    .borderRadius(8)
                    .onClick({ _ => this.openGalleryForSlot("translation") })
            }
            .width(100.percent)
            .height(56)
            .padding(left: 0, right: 0, top: 8, bottom: 8)
        }
    }
}

/**
 * PassportDocumentCameraPage — inline camera capture for document photo slots.（混合工程迁移版）
 * Route: "PassportDocumentCameraPage", param = slot string
 *
 * 混合迁移改动：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去 NavDestination + .hideTitleBar；+ .onAppear/.onDisAppear
 *  - aboutToAppear（wire camera + init）→ ensureLoaded()；aboutToDisappear（releaseCamera）→ cleanup()
 *  - onReady param(slot) → takePending("PassportDocumentCameraPage")；pop → routerPop
 */
@HybridComponentEntry
@Component
public class PassportDocumentCameraPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var slotName: String = "front"
    @State var captureStatusText: String = "Camera ready — tap to capture"

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        // 原 .onReady 参数接收：slot（经 ParamStore takePending 取代 navDestination param）
        let taken = takePending("PassportDocumentCameraPage")
        if (taken.size > 0 && taken != "{}") {
            this.slotName = taken
        }

        // 原 aboutToAppear：wire onPhotoSaved → 回填 pending slot，再 pop
        let svc = getCameraService()
        svc.onPhotoSaved = { path: String =>
            let slot = this.slotName
            let realPath = path
            setPendingPassportPhoto(slot, realPath)
            Hilog.info(0, "CjTelegram", "[PassportDocumentCameraPage] photo captured slot=${slot} path=${realPath}")
            launch {
                this.captureStatusText = "Photo captured!"
                routerPop()
            }
        }
        svc.onError = { msg: String =>
            let errMsg = msg
            launch {
                this.captureStatusText = "Camera error: " + errMsg
            }
        }
        // Initialize camera in background
        let _ = spawn {
            let sid = svc.initCamera(CameraPosition.CameraPositionBack)
            launch {
                if (sid.size > 0) {
                    this.captureStatusText = "Camera ready — tap to capture"
                } else {
                    this.captureStatusText = "Camera unavailable"
                }
            }
        }
    }

    private func cleanup(): Unit {
        getCameraService().releaseCamera()
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
                Text(trSource("Take Photo"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Text(trSource(""))
                    .fontSize(17)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(0xFF000000)
            .alignItems(VerticalAlign.Center)

            Column {
                Text("Document slot: " + this.slotName)
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(bottom: 16)
                Text(this.captureStatusText)
                    .fontSize(14)
                    .fontColor(0xFFFFFF)
                    .margin(bottom: 32)
                Button("Capture Photo")
                    .fontSize(16)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x0088CC)
                    .width(200)
                    .height(44)
                    .borderRadius(8)
                    .onClick({ _ =>
                        let _ = spawn { getCameraService().capturePhoto() }
                    })
            }
            .width(100.percent)
            .layoutWeight(1)
            .backgroundColor(0xFF1C1C1E)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF1C1C1E)
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }
}

/**
 * PassportDocumentGalleryPage — inline photo gallery for document slot selection.（混合工程迁移版）
 * Route: "PassportDocumentGalleryPage", param = slot string
 *
 * 混合迁移改动：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去 NavDestination + .hideTitleBar；+ .onAppear
 *  - aboutToAppear（scanPhotos）→ ensureLoaded()
 *  - onReady param(slot) → takePending("PassportDocumentGalleryPage")；pop → routerPop
 */
@HybridComponentEntry
@Component
public class PassportDocumentGalleryPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var slotName: String = "front"
    @State var isLoading: Bool = true
    @State var availablePhotos: ArrayList<String> = ArrayList<String>()
    @State var selectedUri: String = ""

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true

        // 原 .onReady 参数接收：slot（经 ParamStore takePending 取代 navDestination param）
        let taken = takePending("PassportDocumentGalleryPage")
        if (taken.size > 0 && taken != "{}") {
            this.slotName = taken
        }

        this.scanPhotos()
    }

    private func scanPhotos(): Unit {
        let _ = spawn {
            let photos = ArrayList<String>()
            let filesDir = getAppFilesDir()
            if (filesDir.size > 0) {
                this.scanDirectory(filesDir + "/photos", photos)
                this.scanDirectory(filesDir + "/saved_photos", photos)
                this.scanDirectory(filesDir + "/passport_photos", photos)
            }
            launch {
                this.availablePhotos = photos
                this.isLoading = false
            }
            Hilog.info(0, "CjTelegram", "[PassportDocumentGalleryPage] Found ${photos.size} photos")
        }
    }

    private func scanDirectory(dirPath: String, results: ArrayList<String>): Unit {
        try {
            let exists = FileIo.access(dirPath)
            if (!exists) { return }
            let entries = FileIo.listFile(dirPath)
            for (entry in entries) {
                let lower = entry.toAsciiLower()
                if (lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png")) {
                    results.add(dirPath + "/" + entry)
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PassportDocumentGalleryPage] scanDirectory error: ${e}")
        }
    }

    private func confirmSelection(): Unit {
        let uri = this.selectedUri
        let slot = this.slotName
        if (uri.size > 0 && slot.size > 0) {
            setPendingPassportPhoto(slot, uri)
            Hilog.info(0, "CjTelegram", "[PassportDocumentGalleryPage] confirmed slot=${slot} uri=${uri}")
        }
        routerPop()
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x0088CC)
                    .onClick({ _ => routerPop() })
                Blank()
                Text(trSource("Choose Photo"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                if (this.selectedUri.size > 0) {
                    Text("Use")
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .onClick({ _ => this.confirmSelection() })
                } else {
                    Text(trSource(""))
                        .fontSize(17)
                }
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
                    Text("Loading photos...")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.availablePhotos.size == 0) {
                Column {
                    Text("No local photos found.")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                    Text("Photos saved in the app will appear here.")
                        .fontSize(13)
                        .fontColor(0xC7C7CC)
                        .margin(top: 6)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll {
                    Column {
                        ForEach(
                            Array<String>(this.availablePhotos.size, { i: Int64 => this.availablePhotos[i] }),
                            itemGenerator: { uri: String, _idx: Int64 =>
                                Stack(alignContent: Alignment.TopEnd) {
                                    Image(uri)
                                        .width(100.percent)
                                        .height(100)
                                        .objectFit(ImageFit.Cover)
                                        .borderRadius(6)
                                        .opacity(if (this.selectedUri == uri) { 0.7 } else { 1.0 })
                                    if (this.selectedUri == uri) {
                                        Column {
                                            Text(trSource("Selected"))
                                                .fontSize(12)
                                                .fontColor(0xFFFFFF)
                                                .fontWeight(FontWeight.Bold)
                                        }
                                        .width(80)
                                        .height(28)
                                        .backgroundColor(0x007AFF)
                                        .borderRadius(14)
                                        .justifyContent(FlexAlign.Center)
                                        .alignItems(HorizontalAlign.Center)
                                        .margin(top: 6, right: 6)
                                    }
                                }
                                .width(100.percent)
                                .margin(bottom: 4)
                                .onClick({ _ =>
                                    this.selectedUri = uri
                                })
                            }
                        )
                    }
                    .width(100.percent)
                    .padding(8)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Off)
            }

            Button(if (this.selectedUri.size > 0) { "Use This Photo" } else { "Select a Photo Above" })
                .fontSize(16)
                .fontColor(0xFFFFFF)
                .backgroundColor(if (this.selectedUri.size > 0) { 0x0088CC } else { 0xC7C7CC })
                .width(100.percent)
                .height(48)
                .margin(top: 8, bottom: 16)
                .padding(left: 16, right: 16)
                .enabled(this.selectedUri.size > 0)
                .onClick({ _ => this.confirmSelection() })
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }
}
