package ohos_app_cangjie_entry.auth

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.ArrayList
import std.time.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.components.{PhotoPicker, SelectedPhoto, SolidRoundedButton}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.signalAccountSwitched
import ohos_app_cangjie_entry.core.services.getTelegramCore_AccountManagerService
import std.convert.*

// P2-016: Module-level pending avatar bytes (set by SignUpPage, consumed on upload)
// Using file-level var so aboutToDisappear can trigger upload without viewmodel coupling
private var _pendingSignupAvatarBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
private var _pendingSignupAvatarFileName: String = ""

public func setPendingSignupAvatar(bytes: Array<Byte>, fileName: String): Unit {
    _pendingSignupAvatarBytes = bytes
    _pendingSignupAvatarFileName = fileName
    Hilog.info(0, "CjTelegram", "[SignUpPage] Pending avatar set: ${bytes.size} bytes, ${fileName}")
}

public func clearPendingSignupAvatar(): Unit {
    _pendingSignupAvatarBytes = Array<Byte>(0, repeat: 0)
    _pendingSignupAvatarFileName = ""
}

public func hasPendingSignupAvatar(): Bool {
    return _pendingSignupAvatarBytes.size > 0
}

public func getPendingSignupAvatarBytes(): Array<Byte> {
    return _pendingSignupAvatarBytes
}

public func getPendingSignupAvatarFileName(): String {
    return _pendingSignupAvatarFileName
}

/**
 * 注册页面 — MTProto 真实注册 + 头像选择 (P2-016)
 *
 * Phase 7: 连接 MTProto 真实注册
 * P2-017: ToS Agree/Decline 弹窗 (help.getTermsOfServiceUpdate + Agree/Decline → decline→confirm→reset)
 * P2-016: 注册时头像选择（相册/相机 → 读取字节 → 预览 → 注册后上传）
 *
 * 头像选择流程：
 * 1. 用户点击头像圆圈 → showAvatarOptions = true（底部弹出操作面板）
 * 2. 选"从相册选择" → showPhotoPicker = true → PhotoPicker 显示
 * 3. 用户选择照片 → onSelect 回调 → 读取图片文件字节 → setPendingSignupAvatar()
 * 4. 显示已选照片预览（PixelMap via createImageSource）
 * 5. 注册完成后（aboutToDisappear）→ uploadPendingAvatar() → SettingsService.uploadAndSetProfilePhoto()
 *
 * 视频头像（P2-358 N-A 联动）：HarmonyOS 无 ReplayKit 等价视频录制扩展；
 * 视频头像上传 API（photos.uploadProfilePhoto with video flag）已在 SettingsService 实现（uploadVideoProfilePhoto），
 * 但无对应相机视频录制→裁剪→上传链路（录制页未接视频头像模式）。标注 N-A，视频头像不在注册流程提供。
 *
 * @State 规则：集合变更 temp-var 整体赋值。S-001：异步回调 UI 更新用 launch{}。
 */
@HybridComponentEntry
@Component
public class SignUpPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 名字（必填）
    @State var firstName: String = ""

    // 姓氏（选填）
    @State var lastName: String = ""

    // 头像文字（无照片时显示首字母）
    @State var avatarText: String = "U"

    // 加载状态
    @State var isLoading: Bool = false

    // P2-017: 已获取的 ToS 文本（空 = 无 ToS / 未加载）
    @State var tosText: String = ""

    // P2-017: ToS ID（用于 acceptTermsOfService 调用）
    @State var tosId: String = ""

    // P2-017: 是否正在获取 ToS
    @State var isFetchingTos: Bool = false

    // P2-016: 头像操作面板显示控制
    @State var showAvatarOptions: Bool = false

    // P2-016: 照片选择器显示控制
    @State var showPhotoPicker: Bool = false

    // P2-016: 已选照片 URI（用于 Image 预览）
    @State var selectedAvatarUri: String = ""

    // 混合迁移 auth-flow：原 EntryView @Consume isLoggedIn/tdAuthState/authError 无 provider →
    // 改写 app 级单例 getAuthViewModel()。注册成功由 AuthViewModel 回调 (onAuthorized) 置
    // isLoggedIn=true（无 router 访问），故本页 .onAppear 轮询守卫观测 isLoggedIn 变 true 后
    // routerReplace("MainTabPage")。

    // 混合迁移：观测登录成功后跳转的守卫（避免重复 routerReplace）
    @State var navigatedToMain: Bool = false

    // 添加账号路径由 CodeInputPage 透传；注册成功后需恢复原 activeSlot 并返回编辑页，
    // 不能像首次注册一样清栈进入新的 MainTabPage。
    @State var addAccountContext: String = ""
    @State var addAccountNewSlot: Int32 = -1
    @State var addAccountOriginalSlot: Int32 = -1

    // P2-016: 页面消失时上传待定头像（注册成功后导航离开时触发）
    // 混合迁移：原 aboutToDisappear override → cleanup()，经根容器 .onDisAppear 触发
    private func cleanup(): Unit {
        if (hasPendingSignupAvatar()) {
            let bytes = getPendingSignupAvatarBytes()
            let name = getPendingSignupAvatarFileName()
            clearPendingSignupAvatar()
            if (bytes.size > 0) {
                Hilog.info(0, "CjTelegram", "[SignUpPage] aboutToDisappear: uploading pending avatar (${bytes.size} bytes)")
                spawn {
                    let result = getSettingsService().uploadAndSetProfilePhoto(bytes, name)
                    Hilog.info(0, "CjTelegram", "[SignUpPage] Avatar upload result: success=${result.success}, photoId=${result.photoId}")
                    if (result.success) {
                        let userId = getCurrentUserId()
                        if (userId > 0) {
                            let filesDir = getAppFilesDir()
                            if (filesDir.size > 0) {
                                let avatarDir = filesDir + "/avatars"
                                try { FileIo.mkdir(avatarDir) } catch (_e: Exception) {}
                                let avatarPath = avatarDir + "/avatar_${userId}.jpg"
                                try {
                                    let outFile = FileIo.open(avatarPath, mode: 0o1101)
                                    FileIo.write(outFile.fd, bytes)
                                    FileIo.close(outFile)
                                    let uri = "file://" + avatarPath
                                    getUserPhotoService().setUserPhotoPath(userId, uri)
                                    Hilog.info(0, "CjTelegram", "[SignUpPage] Signup avatar cached locally: ${avatarPath}")
                                } catch (e: Exception) {
                                    Hilog.info(0, "CjTelegram", "[SignUpPage] Avatar local cache error: ${e}")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // SolidRoundedButton onClick 回调（单引用形式，避免多语句闭包宏推断问题）
    // 对应原 "Start Messaging" onClick：dismiss overlays + 触发注册流程
    private func startMessagingAction(): Unit {
        this.showAvatarOptions = false
        this.showPhotoPicker = false
        this.onStartMessagingClicked()
    }

    // P2-016: 从选中照片 URI 读取字节并存入 pending
    private func loadAndStoreAvatarBytes(photo: SelectedPhoto): Unit {
        let uriCopy = photo.uri
        let fileNameCopy = if (photo.fileName.size > 0) { photo.fileName } else { "avatar.jpg" }
        spawn {
            try {
                var realPath = uriCopy
                if (realPath.startsWith("file://")) {
                    realPath = realPath[7..]
                }
                let stat = FileIo.stat(realPath)
                let fileSize = stat.size
                if (fileSize <= 0) {
                    Hilog.info(0, "CjTelegram", "[SignUpPage] Avatar file empty, skip")
                    return
                }
                if (fileSize > 5242880) {
                    // > 5MB: skip (Telegram profile photo limit)
                    Hilog.info(0, "CjTelegram", "[SignUpPage] Avatar file too large (${fileSize} bytes), skip")
                    return
                }
                let file = FileIo.open(realPath, mode: 0o0)
                let photoData = Array<Byte>(fileSize, repeat: 0)
                let _ = FileIo.read(file.fd, photoData)
                FileIo.close(file)
                setPendingSignupAvatar(photoData, fileNameCopy)
                Hilog.info(0, "CjTelegram", "[SignUpPage] Avatar bytes loaded: ${photoData.size}")
                launch {
                    this.selectedAvatarUri = uriCopy
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SignUpPage] loadAndStoreAvatarBytes error: ${e}")
            }
        }
    }

    // P2-017: 返回前 200 字的 ToS 预览文本（build 内不能用 let，提取为方法）
    private func tosPreviewText(): String {
        if (this.tosText.size <= 200) { return this.tosText }
        let runes = this.tosText.toRuneArray()
        var s = ""
        var i = 0
        while (i < 200 && i < runes.size) {
            s = s + runes[i].toString()
            i = i + 1
        }
        return s + "..."
    }

    // P2-017: 返回前 300 字的 ToS 弹窗内容（showTosDialog 闭包内不能用 let）
    private func tosDialogText(): String {
        if (this.tosText.size <= 300) { return this.tosText }
        let runes = this.tosText.toRuneArray()
        var s = ""
        var i = 0
        while (i < 300 && i < runes.size) {
            s = s + runes[i].toString()
            i = i + 1
        }
        return s + "..."
    }

    func build() {
        Stack(alignContent: Alignment.TopStart) {
                // Main scrollable content
                Column {
                    // P2-016: 头像区域（可点击）
                    Stack(alignContent: Alignment.BottomEnd) {
                        if (this.selectedAvatarUri.size > 0) {
                            // 已选照片预览
                            Image(this.selectedAvatarUri)
                                .width(100)
                                .height(100)
                                .borderRadius(50)
                                .objectFit(ImageFit.Cover)
                        } else {
                            // 首字母占位圆圈
                            Column {
                                Text(this.avatarText)
                                    .fontSize(40)
                                    .fontColor(0xFFFFFF)
                            }
                            .width(100)
                            .height(100)
                            .borderRadius(50)
                            .backgroundColor(0x317AFF)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                        }

                        // P2-016: 相机图标角标（提示可点击添加头像）
                        Column {
                            Text("+")
                                .fontSize(18)
                                .fontColor(0xFFFFFF)
                        }
                        .width(28)
                        .height(28)
                        .borderRadius(14)
                        .backgroundColor(0x317AFF)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .border(width: 2, color: 0xFFFFFF, style: BorderStyle.Solid)
                    }
                    .width(100)
                    .height(100)
                    .margin(top: 60, bottom: 16)
                    .onClick({ _ =>
                        this.showAvatarOptions = !this.showAvatarOptions
                    })

                    // 提示文字
                    Text("Add Photo (Optional)")
                        .fontSize(14)
                        .fontColor(0x317AFF)
                        .margin(bottom: 24)
                        .onClick({ _ =>
                            this.showAvatarOptions = !this.showAvatarOptions
                        })

                    // 错误信息
                    if (getAuthViewModel().errorMessage.size > 0) {
                        Text(getAuthViewModel().errorMessage)
                            .fontSize(13)
                            .fontColor(0xFF3B30)
                            .margin(bottom: 16)
                            .padding(left: 24, right: 24)
                            .width(100.percent)
                    }

                    // 名字输入框
                    TextInput(placeholder: "First Name (required)")
                        .fontSize(18)
                        .width(100.percent)
                        .padding(left: 24, right: 24)
                        .margin(bottom: 8)
                        .onChange({ value: String =>
                            this.firstName = value
                            if (value.size > 0) {
                                this.avatarText = value.toRuneArray()[0].toString()
                            } else {
                                this.avatarText = "U"
                            }
                        })

                    // 姓氏输入框
                    TextInput(placeholder: "Last Name (optional)")
                        .fontSize(18)
                        .width(100.percent)
                        .padding(left: 24, right: 24)
                        .margin(top: 12)
                        .onChange({ value: String =>
                            this.lastName = value
                        })

                    // P2-017: ToS 说明文字（若已获取到真实 ToS 文本则显示前 200 字）
                    if (this.tosText.size > 0) {
                        Text(this.tosPreviewText())
                            .fontSize(11)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .padding(left: 32, right: 32)
                            .margin(top: 16)
                    } else {
                        Text("By signing up you agree to the Telegram Terms of Service and Privacy Policy.")
                            .fontSize(12)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .padding(left: 32, right: 32)
                            .margin(top: 24)
                    }

                    // Start Messaging 按钮（SolidRoundedButton 原子）
                    // loading 态：isLoading || isFetchingTos 时显示转圈（合并两种加载状态）
                    // enabled：firstName 非空才可点击（与原逻辑一致）
                    // onClick 单行形式：先 dismiss overlays 再调注册逻辑（原 onClick 逻辑一致）
                    Column {
                        SolidRoundedButton(
                            title: "Start Messaging",
                            onClick: this.startMessagingAction,
                            loading: this.isLoading || this.isFetchingTos,
                            enabled: this.firstName.size > 0
                        )
                    }
                    .margin(top: 40, left: 24, right: 24)
                    .width(100.percent)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFFFFFF)
                .alignItems(HorizontalAlign.Center)

                // P2-016: 头像操作面板（底部弹出）
                if (this.showAvatarOptions) {
                    // 背景遮罩
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ _ =>
                            this.showAvatarOptions = false
                        })

                    // 操作面板
                    Column {
                        Row {
                            Text(trSource("Choose from Gallery"))
                                .fontSize(16)
                                .fontColor(0x317AFF)
                                .onClick({ _ =>
                                    this.showAvatarOptions = false
                                    this.showPhotoPicker = true
                                })
                        }
                        .width(100.percent)
                        .height(48)
                        .justifyContent(FlexAlign.Center)

                        Divider().color(0xE5E5EA).strokeWidth(1)

                        Row {
                            Text(trSource("Cancel"))
                                .fontSize(16)
                                .fontColor(0x000000)
                                .onClick({ _ =>
                                    this.showAvatarOptions = false
                                })
                        }
                        .width(100.percent)
                        .height(48)
                        .justifyContent(FlexAlign.Center)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(10)
                    .position(x: 0, y: 60.percent)
                    .padding(left: 16, right: 16)
                }

                // P2-016: 照片选择器覆盖层
                if (this.showPhotoPicker) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ _ =>
                            this.showPhotoPicker = false
                        })

                    Column {
                        PhotoPicker(
                            maxSelect: 1,
                            onSelect: { photos: ArrayList<SelectedPhoto> =>
                                this.showPhotoPicker = false
                                if (!photos.isEmpty()) {
                                    this.loadAndStoreAvatarBytes(photos[0])
                                }
                            },
                            onClose: { =>
                                this.showPhotoPicker = false
                            }
                        )
                    }
                    .width(100.percent)
                    .position(x: 0, y: 40.percent)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .onAppear({ => this.observeLoginAndNavigate() })
            .onDisAppear({ => this.cleanup() })
    }

    // 混合迁移 auth-flow：注册完成由 AuthViewModel.onAuthorized 回调置 isLoggedIn=true（无 router
    // 访问）。本页 spawn 轮询观测该状态，一旦为 true → routerReplace 进主 tab（守卫防重复）。
    private func observeLoginAndNavigate(): Unit {
        let rawParam = takePending("SignUpPage")
        if (rawParam.size > 0 && rawParam.startsWith("addaccount:")) {
            this.addAccountContext = rawParam
            let parts = rawParam.split(":")
            if (parts.size >= 3) {
                try {
                    this.addAccountNewSlot = Int32(Int64.parse(parts[1]))
                    this.addAccountOriginalSlot = Int32(Int64.parse(parts[2]))
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SignUpPage] add account context parse failed: ${e}")
                    this.addAccountContext = ""
                }
            }
        }

        let capturedAddContext = this.addAccountContext
        let capturedNewSlot = this.addAccountNewSlot
        let capturedOriginalSlot = this.addAccountOriginalSlot
        let _ = spawn {
            while (!this.navigatedToMain) {
                let authorized = if (capturedAddContext.size > 0) {
                    match (getRealAuthService().getState()) {
                        case RealAuthState.Authorized => true
                        case _ => false
                    }
                } else {
                    getAuthViewModel().isLoggedIn
                }
                if (authorized) {
                    if (capturedAddContext.size > 0 && capturedNewSlot >= 0 && capturedOriginalSlot >= 0) {
                        // 注册头像必须在 activeSlot 仍指向新账号时上传；若先恢复原 slot，
                        // cleanup() 的异步上传会错误修改原账号头像。
                        if (hasPendingSignupAvatar()) {
                            let bytes = getPendingSignupAvatarBytes()
                            let fileName = getPendingSignupAvatarFileName()
                            clearPendingSignupAvatar()
                            if (bytes.size > 0) {
                                let uploadResult = getSettingsService().uploadAndSetProfilePhoto(bytes, fileName)
                                Hilog.info(0, "CjTelegram", "[SignUpPage] Added account avatar upload result=${uploadResult.success}")
                            }
                        }
                        getTelegramCore_AccountManagerService().completeAddAccount(capturedNewSlot, capturedOriginalSlot)
                        // S7-16: the added account is now current (iOS setCurrentId).
                        let _ = getRealAuthService().tryRestoreLogin()
                    }
                    launch {
                        if (!this.navigatedToMain) {
                            this.navigatedToMain = true
                            if (capturedAddContext.size > 0 && capturedNewSlot >= 0 && capturedOriginalSlot >= 0) {
                                signalAccountSwitched(false)
                                routerReplace("MainTabPage", "{}")
                                Hilog.info(0, "CjTelegram", "[SignUpPage] Added account registration complete, switched to the new account")
                            } else {
                                routerReplace("MainTabPage", "{}")
                                Hilog.info(0, "CjTelegram", "[SignUpPage] Registration complete, navigating to MainTabPage")
                            }
                        }
                    }
                    break
                }
                sleep(Duration.millisecond * 300)
            }
        }
    }

    /**
     * P2-017: "Start Messaging" 点击处理
     *
     * 若已有 ToS（tosId 非空）则直接弹 ToS 对话框。
     * 否则先获取 ToS，若有更新内容则弹框，无内容则直接注册。
     */
    private func onStartMessagingClicked() {
        if (this.firstName.size == 0) { return }

        if (this.tosId.size > 0) {
            // 已经获取过 ToS，直接弹框
            this.showTosDialog()
            return
        }

        // 首次：获取 ToS
        this.isFetchingTos = true
        getAuthViewModel().errorMessage = ""
        spawn {
            try {
                let authService = getRealAuthService()
                let tosResp = authService.getTermsOfService()
                launch {
                    this.isFetchingTos = false
                    if (tosResp.hasUpdate && tosResp.text.size > 0) {
                        this.tosText = tosResp.text
                        this.tosId = tosResp.termsId
                        Hilog.info(0, "CjTelegram", "[SignUpPage] ToS loaded: id=${tosResp.termsId} len=${tosResp.text.size}")
                        this.showTosDialog()
                    } else {
                        // 无需显示 ToS → 直接注册
                        Hilog.info(0, "CjTelegram", "[SignUpPage] No ToS update required, proceeding directly")
                        this.submitRegistration(acceptedTos: false)
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SignUpPage] getTermsOfService error: ${e}")
                launch {
                    this.isFetchingTos = false
                    // ToS 获取失败时退化：直接注册（与 iOS 行为一致，ToS 不阻止注册流程）
                    this.submitRegistration(acceptedTos: false)
                }
            }
        }
    }

    /**
     * P2-017: 显示 ToS Agree/Decline 弹窗
     * iOS: TextAlertAction Agree → acceptTermsOfService → signUp
     *       TextAlertAction Decline → 二次确认弹窗 → 确认 → logout
     */
    private func showTosDialog() {
        let tosIdCapture = this.tosId
        let tosMsg = this.tosDialogText()

        getUIContext().showAlertDialog(
            AlertDialogParamWithButtons(
                message: tosMsg,
                title: "Terms of Service",
                primaryButton: AlertDialogButtonOptions(
                    value: "Agree",
                    action: {=>
                        // P2-017: Agree → accept ToS → then sign up
                        Hilog.info(0, "CjTelegram", "[SignUpPage] ToS Agreed, accepting and registering")
                        spawn {
                            let authService = getRealAuthService()
                            let accepted = authService.acceptTermsOfService(tosIdCapture)
                            Hilog.info(0, "CjTelegram", "[SignUpPage] acceptTermsOfService result: ${accepted}")
                            launch {
                                this.submitRegistration(acceptedTos: true)
                            }
                        }
                    }
                ),
                secondaryButton: AlertDialogButtonOptions(
                    value: "Decline",
                    action: {=>
                        // P2-017: Decline → 二次确认弹窗
                        Hilog.info(0, "CjTelegram", "[SignUpPage] ToS Declined, showing confirm dialog")
                        this.showTosDeclineConfirmDialog()
                    }
                )
            )
        )
    }

    /**
     * P2-017: 二次确认弹窗 (decline → confirm → account reset / logout)
     * iOS: Login_TermsOfServiceDecline → "Decline" → logout → back to phone entry
     * Note: 不在 Cancel 分支递归调用 showTosDialog（避免 Cangjie 宏循环检测报错）
     *       用户 Cancel 后 ToS 对话框自然关闭，可再次点击 "Start Messaging" 重新弹出。
     */
    private func showTosDeclineConfirmDialog() {
        getUIContext().showAlertDialog(
            AlertDialogParamWithButtons(
                message: "If you decline the Terms of Service, your account will be deleted. This action cannot be undone.",
                title: "Decline Terms of Service",
                primaryButton: AlertDialogButtonOptions(
                    value: "Cancel",
                    action: {=>
                        // User cancelled decline — dismiss dialog (user can re-tap "Start Messaging")
                        Hilog.info(0, "CjTelegram", "[SignUpPage] Decline cancelled")
                    }
                ),
                secondaryButton: AlertDialogButtonOptions(
                    value: "Decline",
                    action: {=>
                        // Confirmed decline → logout + reset to phone entry
                        Hilog.info(0, "CjTelegram", "[SignUpPage] ToS decline confirmed, logging out")
                        clearPendingSignupAvatar()
                        spawn {
                            let authService = getRealAuthService()
                            authService.logout()
                            Hilog.info(0, "CjTelegram", "[SignUpPage] Logout complete after ToS decline")
                            launch {
                                this.tosText = ""
                                this.tosId = ""
                                getAuthViewModel().errorMessage = ""
                                // Pop back through CodeInputPage to PhoneInputPage
                                routerPop()
                                routerPop()
                            }
                        }
                    }
                )
            )
        )
    }

    /**
     * 提交注册
     * @param acceptedTos: 是否已显示并接受 ToS（仅影响日志，注册本身无差异）
     */
    private func submitRegistration(acceptedTos!: Bool = false) {
        this.isLoading = true
        Hilog.info(0, "CjTelegram", "[SignUpPage] submitRegistration acceptedTos=${acceptedTos} hasAvatar=${hasPendingSignupAvatar()}")

        let authVM = getAuthViewModel()
        authVM.signUp(this.firstName, this.lastName)
    }
}
