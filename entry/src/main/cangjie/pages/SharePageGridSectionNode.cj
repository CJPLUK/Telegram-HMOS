package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.services.ShareTarget

/**
 * 分享控制器网格项 — 单个对话/联系人项
 *
 * 对应 iOS ShareControllerPeerGridItem / ShareControllerPeerGridItemNode
 * 显示：头像 + 名字 + 选中状态（打勾）
 */
@Component
public class SharePageGridSectionNode {
    var target: ShareTarget = ShareTarget()
    var isSelected: Bool = false
    var darkStyle: Bool = false
    public var onTap: () -> Unit = { => }

    func build() {
        Column {
            Stack(alignContent: Alignment.TopEnd) {
                // 头像
                if (this.target.name == "Saved Messages") {
                    Column {
                        Image(@r(app.media.avatar_ic_savedmsg))
                            .width(31)
                            .height(31)
                            .fillColor(0xFFFFFFFF)
                    }
                    .width(56)
                    .height(56)
                    .borderRadius(28)
                    .backgroundColor(0xFF34AADC)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.target.name == "Telegram") {
                    Column {
                        Image(@r(app.media.avatar_ic_telegram))
                            .width(36)
                            .height(36)
                            .fillColor(0xFFFFFFFF)
                    }
                    .width(56)
                    .height(56)
                    .borderRadius(28)
                    .backgroundColor(0xFF2AABEE)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.target.avatarLocalPath.size > 0) {
                    Image(this.target.avatarLocalPath)
                        .width(56)
                        .height(56)
                        .borderRadius(28)
                        .objectFit(ImageFit.Cover)
                } else {
                    Column {
                        Text(this.target.avatarText)
                            .fontSize(20)
                            .fontColor(0xFFFFFF)
                            .fontWeight(FontWeight.Medium)
                    }
                    .width(56)
                    .height(56)
                    .borderRadius(28)
                    .backgroundColor(this.target.avatarColor)
                    .justifyContent(FlexAlign.Center)
                }

                // 选中打勾
                if (this.isSelected) {
                    Column {
                        Text("✓")
                            .fontSize(12)
                            .fontColor(0xFFFFFF)
                    }
                    .width(22)
                    .height(22)
                    .borderRadius(11)
                    .backgroundColor(0x317AFF)
                    .justifyContent(FlexAlign.Center)
                    .margin(top: 2, right: 2)
                }
            }
            .width(56)
            .height(56)

            Text(this.target.name)
                .fontSize(12)
                .fontColor(if (this.darkStyle) { 0xFFFFFFFF } else { 0xFF000000 })
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .margin(top: 4)
                .width(70)
        }
        .width(80)
        .height(90)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt =>
            this.onTap()
        })
    }
}
