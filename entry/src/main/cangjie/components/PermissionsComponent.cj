package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getPermissionsService,
    PermissionType
}
import ohos.resource.__GenerateResource__

/**
 * PermissionsComponent — 权限请求 UI 引导卡片
 *
 * 对应 iOS Telegram 联系人列表权限嵌入 UX：
 * - ContactListNode.swift 中 permissionInfo + permissionEnable 行
 * - 在未授权时列表顶部嵌入引导块："允许访问通讯录以找到朋友" + 授权按钮
 *
 * 用法（ContactListPage 内嵌）:
 *   PermissionsComponent(
 *       permType: PermissionType.Contacts,
 *       title: "Allow Telegram Access Your Contacts",
 *       description: "To find your friends, Telegram needs access to your contacts.",
 *       buttonText: "Allow Access",
 *       onGranted: { => this.contactsPermGranted = true }
 *   )
 *
 * 死状态防护: isGranted 和 isRequesting 均为内部 @State，
 * 仅由 requestPermission() 回调在 launch{} 中更新（S-001 合规）。
 * 外部通过 onGranted 回调通知父组件刷新其权限态 @State。
 */
@Component
public class PermissionsComponent {
    public var permType: PermissionType = PermissionType.Camera
    public var title: String = "需要权限"
    public var description: String = "此功能需要相应权限才能使用"
    public var buttonText: String = "授权"
    public var onGranted: () -> Unit = { => }

    @State var isRequesting: Bool = false
    @State var isGranted: Bool = false

    func requestPermission(): Unit {
        if (this.isRequesting || this.isGranted) {
            return
        }
        this.isRequesting = true
        let svc = getPermissionsService()
        let perm = this.permType
        let grantedCb = this.onGranted
        svc.requestPermission(perm, { granted: Bool =>
            launch {
                this.isRequesting = false
                this.isGranted = granted
                if (granted) {
                    grantedCb()
                }
            }
        })
    }

    func getButtonLabel(): String {
        if (this.isRequesting) {
            return "Requesting..."
        }
        return this.buttonText
    }

    public func build() {
        if (this.isGranted) {
            Column { }
                .width(0)
                .height(0)
        } else {
            Column {
                Column {
                    Row {
                        Column {
                            // 资源保真修复：真实矢量图标（Item List/Icons/Members.imageset 转 SVG）替代 emoji 字形
                            Image(@r(app.media.misc_ic_members))
                                .width(36)
                                .height(36)
                                .fillColor(0xFFFFFFFF)
                        }
                        .width(60)
                        .height(60)
                        .borderRadius(30)
                        .backgroundColor(0xFF317AFF)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)

                        Column {
                            Text(this.title)
                                .fontSize(15)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFF000000)
                                .width(100.percent)
                                .maxLines(2)
                                .textOverflow(TextOverflow.Ellipsis)

                            Text(this.description)
                                .fontSize(13)
                                .fontColor(0xFF8E8E93)
                                .margin(top: 4)
                                .width(100.percent)
                                .maxLines(3)
                                .textOverflow(TextOverflow.Ellipsis)
                        }
                        .layoutWeight(1)
                        .padding(left: 12)
                        .alignItems(HorizontalAlign.Start)
                        .justifyContent(FlexAlign.Center)
                    }
                    .width(100.percent)
                    .alignItems(VerticalAlign.Center)
                    .padding(bottom: 12)

                    Button(this.getButtonLabel())
                        .width(100.percent)
                        .height(44)
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFFFFFFFF)
                        .backgroundColor(if (this.isRequesting) { 0xFF8E8E93 } else { 0xFF317AFF })
                        .borderRadius(10)
                        .enabled(!this.isRequesting)
                        .onClick({ _ => this.requestPermission() })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 16, bottom: 16)
                .backgroundColor(0xFFF5F5F5)
                .borderRadius(12)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 8)
            .backgroundColor(0xFFFFFFFF)
        }
    }
}
