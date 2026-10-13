package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getPermissionsService, getDeviceAccessService}
import ohos_app_cangjie_entry.services.PermissionType
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * PermissionPage — 权限设置页面 (TPERM-UI-1)（混合工程迁移版）
 *
 * 对应 iOS PermissionController
 * 显示权限列表：Camera, Microphone, Contacts, Location, PhotoLibrary, Notifications
 * 每项显示状态，点击可请求权限
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（refreshAllPerms）→ 移到首次 build（.onAppear）
 */
@HybridComponentEntry
@Component
public class PermissionPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 状态编码（对位 PermissionsService.statusCode，与 iOS PermissionRequestStatus 四态
    // 对位）：0=Granted, 1=Denied, 2=NotRequested, 3=Unreachable, 4=Error。
    // 初值 2（NotRequested）：首次渲染前尚未查询服务层，与"未请求"语义一致。
    @State var cameraStatus: Int64 = 2
    @State var micStatus: Int64 = 2
    @State var contactsStatus: Int64 = 2
    @State var locationStatus: Int64 = 2
    @State var photoStatus: Int64 = 2
    @State var notifyStatus: Int64 = 2
    @State var loadingPerm: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.refreshAllPerms()
    }

    private func refreshAllPerms(): Unit {
        let svc = getPermissionsService()
        this.cameraStatus = svc.statusCode(PermissionType.Camera)
        this.micStatus = svc.statusCode(PermissionType.Microphone)
        this.contactsStatus = svc.statusCode(PermissionType.Contacts)
        this.locationStatus = svc.statusCode(PermissionType.Location)
        this.photoStatus = svc.statusCode(PermissionType.PhotoLibrary)
        this.notifyStatus = svc.statusCode(PermissionType.Notifications)
    }

    // 按状态分发（对位源侧 PermissionController.setState 的 allow 闭包，
    // PermissionController.swift:123-143）：
    //   0 Granted     -> 不可达，无对应可点元素（源侧 default: break）
    //   2 NotRequested -> 走系统弹窗申请（源侧 .requestable -> DeviceAccess.authorizeAccess）
    //   1 Denied / 4 Error -> 直接跳系统设置（源侧 .denied -> openAppSettings()）
    //   3 Unreachable -> 不可达，无对应可点元素（本构建 Contacts 恒为此态，
    //                     跳设置页解决不了"权限在本构建根本不存在"，故不跟随源侧
    //                     notifications 的 openAppSettings 兜底；目标平台特有约束，
    //                     源侧无对应物）
    private func onAllowTap(pt: PermissionType, label: String, status: Int64): Unit {
        if (status == 2) {
            if (this.loadingPerm.size > 0) { return }
            this.loadingPerm = label
            let svc = getPermissionsService()
            svc.requestPermission(pt, { granted: Bool =>
                launch {
                    this.loadingPerm = ""
                    this.refreshAllPerms()
                    if (granted) {
                        Hilog.info(0, "CjTelegram", "[PermissionPage] Granted: ${label}")
                    }
                }
            })
        } else if (status == 1 || status == 4) {
            this.openAppSettings()
        }
        // status == 0 / 3：无对应可点元素，理论上不可达；防御性 no-op。
    }

    // 返修（diag-suite_settings_notifications-TC-0442.md F1，第二处同错拷贝）：原实现在
    // 本函数自建与 PermissionsService.requestNotificationsPermission() 逐字相同的错误 Want
    // （Android 寻址写法 + 仓颉包名当 bundleName，HarmonyOS 解析不到，startAbility 抛
    // BusinessException 16000019，被 catch 吞成日志、UI 侧无反馈）。改为委托同一个已验证正确
    // 的单一实现 `DeviceAccessService.openSystemSettings()`（bundleName/abilityName 显式寻址
    // 系统设置应用），与 PermissionsService.cj 收敛到同一出口，不再各写各的 Want 字面量。
    private func openAppSettings(): Unit {
        getDeviceAccessService().openSystemSettings()
    }

    // D-115: @Builder 成员函数不能带参数从 build() 调用（宏把参数包成 ObservedProperty
    // 并按值捕获，@State 写回不进依赖图，行会永久冻结在首次 build 的初值上）。原先带参
    // `permRow(icon,label,granted,pt)` 正是这个坑，6 行状态文字全部与服务层脱钩——
    // 拆成 6 个无参 @Builder，内部只读裸 `this.<State 字段>`（对位 DebugSettingsPage.cj
    // buildConnectionSection() / PassportDocumentPage.cj buildFrontPhotoSlot() 等已验证
    // 同形先例）。

    @Builder
    func buildCameraRow() {
        ListItem {
            Row {
                Column {
                    Text("📷").fontSize(20)
                }
                .width(36).height(36).borderRadius(8).backgroundColor(0xE8E8ED)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin(right: 16)

                Text(trSource("Camera")).fontSize(17).fontColor(0x000000).layoutWeight(1)

                Text(
                    if (this.cameraStatus == 0) { "Allowed" }
                    else if (this.cameraStatus == 3) { "Unavailable" }
                    else { "Not allowed" }
                )
                    .fontSize(15)
                    .fontColor(if (this.cameraStatus == 0) { 0x34C759 } else { 0x8E8E93 })

                if (this.loadingPerm == "Camera") {
                    LoadingProgress().width(24).height(24).color(0x317AFF).margin(left: 8)
                } else if (this.cameraStatus == 2) {
                    Text(trSource("Allow"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Camera, "Camera", this.cameraStatus) })
                } else if (this.cameraStatus == 1 || this.cameraStatus == 4) {
                    Text(trSource("Open Settings"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Camera, "Camera", this.cameraStatus) })
                }
            }
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                if ((this.cameraStatus == 2 || this.cameraStatus == 1 || this.cameraStatus == 4) && this.loadingPerm.size == 0) {
                    this.onAllowTap(PermissionType.Camera, "Camera", this.cameraStatus)
                }
            })
        }
    }

    @Builder
    func buildMicrophoneRow() {
        ListItem {
            Row {
                Column {
                    Text("🎤").fontSize(20)
                }
                .width(36).height(36).borderRadius(8).backgroundColor(0xE8E8ED)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin(right: 16)

                Text("Microphone").fontSize(17).fontColor(0x000000).layoutWeight(1)

                Text(
                    if (this.micStatus == 0) { "Allowed" }
                    else if (this.micStatus == 3) { "Unavailable" }
                    else { "Not allowed" }
                )
                    .fontSize(15)
                    .fontColor(if (this.micStatus == 0) { 0x34C759 } else { 0x8E8E93 })

                if (this.loadingPerm == "Microphone") {
                    LoadingProgress().width(24).height(24).color(0x317AFF).margin(left: 8)
                } else if (this.micStatus == 2) {
                    Text(trSource("Allow"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Microphone, "Microphone", this.micStatus) })
                } else if (this.micStatus == 1 || this.micStatus == 4) {
                    Text(trSource("Open Settings"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Microphone, "Microphone", this.micStatus) })
                }
            }
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                if ((this.micStatus == 2 || this.micStatus == 1 || this.micStatus == 4) && this.loadingPerm.size == 0) {
                    this.onAllowTap(PermissionType.Microphone, "Microphone", this.micStatus)
                }
            })
        }
    }

    @Builder
    func buildContactsRow() {
        ListItem {
            Row {
                Column {
                    Text("👥").fontSize(20)
                }
                .width(36).height(36).borderRadius(8).backgroundColor(0xE8E8ED)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin(right: 16)

                Text(trSource("Contacts")).fontSize(17).fontColor(0x000000).layoutWeight(1)

                Text(
                    if (this.contactsStatus == 0) { "Allowed" }
                    else if (this.contactsStatus == 3) { "Unavailable" }
                    else { "Not allowed" }
                )
                    .fontSize(15)
                    .fontColor(if (this.contactsStatus == 0) { 0x34C759 } else { 0x8E8E93 })

                if (this.loadingPerm == "Contacts") {
                    LoadingProgress().width(24).height(24).color(0x317AFF).margin(left: 8)
                } else if (this.contactsStatus == 2) {
                    Text(trSource("Allow"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Contacts, "Contacts", this.contactsStatus) })
                } else if (this.contactsStatus == 1 || this.contactsStatus == 4) {
                    Text(trSource("Open Settings"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Contacts, "Contacts", this.contactsStatus) })
                }
                // status == 3 (Unreachable)：无动作元素——本构建 Contacts 恒不可申请
                // （见 PermissionsService.contactsStatusCode 的注释与理由）。
            }
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                if ((this.contactsStatus == 2 || this.contactsStatus == 1 || this.contactsStatus == 4) && this.loadingPerm.size == 0) {
                    this.onAllowTap(PermissionType.Contacts, "Contacts", this.contactsStatus)
                }
            })
        }
    }

    @Builder
    func buildLocationRow() {
        ListItem {
            Row {
                Column {
                    Text("📍").fontSize(20)
                }
                .width(36).height(36).borderRadius(8).backgroundColor(0xE8E8ED)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin(right: 16)

                Text(trSource("Location")).fontSize(17).fontColor(0x000000).layoutWeight(1)

                Text(
                    if (this.locationStatus == 0) { "Allowed" }
                    else if (this.locationStatus == 3) { "Unavailable" }
                    else { "Not allowed" }
                )
                    .fontSize(15)
                    .fontColor(if (this.locationStatus == 0) { 0x34C759 } else { 0x8E8E93 })

                if (this.loadingPerm == "Location") {
                    LoadingProgress().width(24).height(24).color(0x317AFF).margin(left: 8)
                } else if (this.locationStatus == 2) {
                    Text(trSource("Allow"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Location, "Location", this.locationStatus) })
                } else if (this.locationStatus == 1 || this.locationStatus == 4) {
                    Text(trSource("Open Settings"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Location, "Location", this.locationStatus) })
                }
            }
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                if ((this.locationStatus == 2 || this.locationStatus == 1 || this.locationStatus == 4) && this.loadingPerm.size == 0) {
                    this.onAllowTap(PermissionType.Location, "Location", this.locationStatus)
                }
            })
        }
    }

    @Builder
    func buildPhotoLibraryRow() {
        ListItem {
            Row {
                Column {
                    Text("🖼").fontSize(20)
                }
                .width(36).height(36).borderRadius(8).backgroundColor(0xE8E8ED)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin(right: 16)

                Text(trSource("Photo Library")).fontSize(17).fontColor(0x000000).layoutWeight(1)

                Text(
                    if (this.photoStatus == 0) { "Allowed" }
                    else if (this.photoStatus == 3) { "Unavailable" }
                    else { "Not allowed" }
                )
                    .fontSize(15)
                    .fontColor(if (this.photoStatus == 0) { 0x34C759 } else { 0x8E8E93 })

                if (this.loadingPerm == "Photo Library") {
                    LoadingProgress().width(24).height(24).color(0x317AFF).margin(left: 8)
                } else if (this.photoStatus == 2) {
                    Text(trSource("Allow"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.PhotoLibrary, "Photo Library", this.photoStatus) })
                } else if (this.photoStatus == 1 || this.photoStatus == 4) {
                    Text(trSource("Open Settings"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.PhotoLibrary, "Photo Library", this.photoStatus) })
                }
            }
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                if ((this.photoStatus == 2 || this.photoStatus == 1 || this.photoStatus == 4) && this.loadingPerm.size == 0) {
                    this.onAllowTap(PermissionType.PhotoLibrary, "Photo Library", this.photoStatus)
                }
            })
        }
    }

    @Builder
    func buildNotificationsRow() {
        ListItem {
            Row {
                Column {
                    Text("🔔").fontSize(20)
                }
                .width(36).height(36).borderRadius(8).backgroundColor(0xE8E8ED)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin(right: 16)

                Text(trSource("Notifications")).fontSize(17).fontColor(0x000000).layoutWeight(1)

                Text(
                    if (this.notifyStatus == 0) { "Allowed" }
                    else if (this.notifyStatus == 3) { "Unavailable" }
                    else { "Not allowed" }
                )
                    .fontSize(15)
                    .fontColor(if (this.notifyStatus == 0) { 0x34C759 } else { 0x8E8E93 })

                if (this.loadingPerm == "Notifications") {
                    LoadingProgress().width(24).height(24).color(0x317AFF).margin(left: 8)
                } else if (this.notifyStatus == 2) {
                    Text(trSource("Allow"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Notifications, "Notifications", this.notifyStatus) })
                } else if (this.notifyStatus == 1 || this.notifyStatus == 4) {
                    Text(trSource("Open Settings"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .margin(left: 12)
                        .onClick({ _evt => this.onAllowTap(PermissionType.Notifications, "Notifications", this.notifyStatus) })
                }
            }
            .width(100.percent)
            .height(52)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt =>
                if ((this.notifyStatus == 2 || this.notifyStatus == 1 || this.notifyStatus == 4) && this.loadingPerm.size == 0) {
                    this.onAllowTap(PermissionType.Notifications, "Notifications", this.notifyStatus)
                }
            })
        }
    }

    public func build() {
        Column {
            Row {
                Text("← Back")
                    .fontSize(17)
                    .fontColor(0x317AFF)
                    .onClick({ _evt => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Permissions"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                Blank().layoutWeight(1)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xF7F7F7)
            .alignItems(VerticalAlign.Center)

            Divider().color(0xE5E5EA).strokeWidth(0.5)

            List {
                ListItem {
                    Text("Allow Telegram to access these features.")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(16)
                }
                this.buildCameraRow()
                this.buildMicrophoneRow()
                this.buildContactsRow()
                this.buildLocationRow()
                this.buildPhotoLibraryRow()
                this.buildNotificationsRow()
            }
            .width(100.percent)
            .layoutWeight(1)
            .backgroundColor(0xFFFFFF)
            .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA, startMargin: 61, endMargin: 0))
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
