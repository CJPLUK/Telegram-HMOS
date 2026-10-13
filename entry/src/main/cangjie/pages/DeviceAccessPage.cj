package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getDeviceAccessService, DeviceAccessType, DeviceAccessStatus}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * DeviceAccessPage — 设备能力访问管理页面
 *
 * 对应 iOS DeviceAccess 模块的权限管理界面。
 * 展示相机、麦克风、相册、位置、通讯录五类权限的当前状态，
 * 支持点击请求权限，被拒绝时引导用户跳转系统设置。
 *
 * 路由注册：MainTabPage.pageMap 通过 pushPathByName("DeviceAccessPage") 跳转
 * 根容器：NavDestination（D-002）
 */
@HybridComponentEntry
@Component
public class DeviceAccessPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var cameraStatus: DeviceAccessStatus = DeviceAccessStatus.NotDetermined
    @State var micStatus: DeviceAccessStatus = DeviceAccessStatus.NotDetermined
    @State var photoStatus: DeviceAccessStatus = DeviceAccessStatus.NotDetermined
    @State var locationStatus: DeviceAccessStatus = DeviceAccessStatus.NotDetermined
    @State var contactsStatus: DeviceAccessStatus = DeviceAccessStatus.NotDetermined
    @State var requestingType: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.refreshAllStatuses()
    }

    private func refreshAllStatuses(): Unit {
        let svc = getDeviceAccessService()
        this.cameraStatus = svc.checkAccess(DeviceAccessType.Camera)
        this.micStatus = svc.checkAccess(DeviceAccessType.Microphone)
        this.photoStatus = svc.checkAccess(DeviceAccessType.PhotoLibrary)
        this.locationStatus = svc.checkAccess(DeviceAccessType.Location)
        this.contactsStatus = svc.checkAccess(DeviceAccessType.Contacts)
    }

    private func statusLabel(status: DeviceAccessStatus): String {
        match (status) {
            case DeviceAccessStatus.Authorized => return "Authorized"
            case DeviceAccessStatus.Denied => return "Denied"
            case DeviceAccessStatus.NotDetermined => return "Not Determined"
        }
    }

    private func isAuthorized(status: DeviceAccessStatus): Bool {
        match (status) {
            case DeviceAccessStatus.Authorized => return true
            case _ => return false
        }
    }

    private func requestAccess(accessType: DeviceAccessType, label: String): Unit {
        if (this.requestingType.size > 0) { return }
        this.requestingType = label
        let svc = getDeviceAccessService()
        svc.requestAccess(accessType, { granted: Bool =>
            launch {
                this.requestingType = ""
                this.refreshAllStatuses()
                if (granted) {
                    Hilog.info(0, "CjTelegram", "[DeviceAccessPage] Granted: ${label}")
                } else {
                    Hilog.info(0, "CjTelegram", "[DeviceAccessPage] Denied: ${label}")
                    svc.openSystemSettings()
                }
            }
        })
    }

    @Builder
    private func accessRow(icon: String, label: String, status: DeviceAccessStatus, accessType: DeviceAccessType) {
        ListItem {
            Row {
                Column {
                    Text(icon)
                        .fontSize(20)
                }
                .width(40)
                .height(40)
                .borderRadius(8)
                .backgroundColor(0xE8E8ED)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .margin(right: 12)

                Column {
                    Text(label)
                        .fontSize(16)
                        .fontColor(0x000000)
                        .fontWeight(FontWeight.Medium)
                    Text(this.statusLabel(status))
                        .fontSize(13)
                        .fontColor(if (this.isAuthorized(status)) { 0x34C759 } else { 0x8E8E93 })
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (this.requestingType == label) {
                    LoadingProgress()
                        .width(22)
                        .height(22)
                        .color(0x317AFF)
                } else if (this.isAuthorized(status)) {
                    Text("✓")
                        .fontSize(16)
                        .fontColor(0x34C759)
                        .fontWeight(FontWeight.Bold)
                } else {
                    Text(trSource("Allow"))
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .fontWeight(FontWeight.Medium)
                        .onClick({ _evt: ClickEvent => this.requestAccess(accessType, label) })
                }
            }
            .width(100.percent)
            .height(60)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(0xFFFFFF)
            .onClick({ _evt: ClickEvent =>
                if (!this.isAuthorized(status) && this.requestingType.size == 0) {
                    this.requestAccess(accessType, label)
                }
            })
        }
    }

    public func build() {
        Column {
                Row {
                    Text("< Back")
                        .fontSize(17)
                        .fontColor(0x317AFF)
                        .onClick({ _evt: ClickEvent => routerPop() })
                    Blank().layoutWeight(1)
                    Text("Device Access")
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
                        Text("Telegram needs access to the following device capabilities.")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 12)
                    }

                    this.accessRow("Camera", "Camera", this.cameraStatus, DeviceAccessType.Camera)
                    this.accessRow("Mic", "Microphone", this.micStatus, DeviceAccessType.Microphone)
                    this.accessRow("Photo", "Photo Library", this.photoStatus, DeviceAccessType.PhotoLibrary)
                    this.accessRow("Loc", "Location", this.locationStatus, DeviceAccessType.Location)
                    this.accessRow("Cont", "Contacts", this.contactsStatus, DeviceAccessType.Contacts)

                    ListItem {
                        Text("Tap 'Allow' to grant access. If denied, you will be redirected to Settings.")
                            .fontSize(12)
                            .fontColor(0x8E8E93)
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 8, bottom: 8)
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
                .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA, startMargin: 68, endMargin: 0))
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(bottom: getSafeAreaBottom())
            .onAppear({ => this.ensureLoaded() })
    }
}
