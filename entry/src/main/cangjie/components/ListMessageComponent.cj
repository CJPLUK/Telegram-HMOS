package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    ListMessageItem,
    ListMessageDateGroup,
    ListMessageService,
    getListMessageService,
    LIST_MSG_TYPE_FILE,
    LIST_MSG_TYPE_LINK,
    LIST_MSG_TYPE_MUSIC
}
import ohos_app_cangjie_entry.models.Message
import std.collection.ArrayList
import ohos.resource.__GenerateResource__

/**
 * ListMessageComponent — 列表消息单行组件
 *
 * 对应 iOS ListMessageFileItemNode / ListMessageSnippetItemNode：
 *   - file 行: [扩展名色块] 文件名 + 大小  (右侧: 日期)
 *   - link 行: [缩略图/图标] 标题 + 站点名 (右侧: 日期)
 *   - music 行:[专辑封面/音符] 曲名 + 艺术家 + 时长 (右侧: 日期)
 *
 * 点击行为：
 *   - file: 若 localPath 非空则打开预览，否则触发 onDownload 回调
 *   - link: 触发 onOpenUrl 回调（由上层调用浏览器）
 *   - music: 触发 onPlayMusic 回调（由上层调用音频播放器）
 *
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 */
@Component
public class ListMessageComponent {
    @Prop var item: ListMessageItem

    // 回调：下载文件（item 为 file 类型且 localPath 为空时触发）
    public var onDownload: (Int64, String) -> Unit = { _id: Int64, _name: String => }

    // 回调：打开链接（item 为 link 类型时触发）
    public var onOpenUrl: (String) -> Unit = { _url: String => }

    // 回调：播放音乐（item 为 music 类型时触发）
    public var onPlayMusic: (Int64) -> Unit = { _id: Int64 => }

    private func getIconText(): String {
        let ext = this.item.fileExtension.toAsciiLower()
        if (ext.size > 0 && ext.size <= 4) {
            return ext.toAsciiUpper()
        }
        return "FILE"
    }

    private func getIconBgColor(): Int64 {
        return getListMessageService().extensionColor(this.item.fileExtension)
    }

    private func getFileSizeText(): String {
        return getListMessageService().formatFileSize(this.item.fileSize)
    }

    private func getMusicDurationText(): String {
        return getListMessageService().formatDuration(this.item.musicDuration)
    }

    private func getDateText(): String {
        let ts = this.item.timestamp
        if (ts <= 0) { return "" }
        let dayTs = ts % 86400
        let h = dayTs / 3600
        let m = (dayTs % 3600) / 60
        let hStr = if (h < 10) { "0${h}" } else { "${h}" }
        let mStr = if (m < 10) { "0${m}" } else { "${m}" }
        return "${hStr}:${mStr}"
    }

    private func handleTap() {
        let itype = this.item.itemType
        if (itype == LIST_MSG_TYPE_FILE) {
            if (this.item.localPath.size > 0) {
                Hilog.info(0, "CjTelegram", "[ListMsg] Open file")
                this.onDownload(this.item.msgId, this.item.localPath)
            } else {
                Hilog.info(0, "CjTelegram", "[ListMsg] Download file")
                this.onDownload(this.item.msgId, this.item.fileName)
            }
        } else if (itype == LIST_MSG_TYPE_LINK) {
            Hilog.info(0, "CjTelegram", "[ListMsg] Open link")
            this.onOpenUrl(this.item.linkUrl)
        } else if (itype == LIST_MSG_TYPE_MUSIC) {
            Hilog.info(0, "CjTelegram", "[ListMsg] Play music")
            this.onPlayMusic(this.item.msgId)
        }
    }

    public func build() {
        Row {
            // ---- 左侧图标区域 ----
            if (this.item.itemType == LIST_MSG_TYPE_FILE) {
                this.buildFileIcon()
            } else if (this.item.itemType == LIST_MSG_TYPE_LINK) {
                this.buildLinkIcon()
            } else {
                this.buildMusicIcon()
            }

            // ---- 中间内容区域 ----
            Column {
                if (this.item.itemType == LIST_MSG_TYPE_FILE) {
                    Text(this.item.fileName)
                        .fontSize(15)
                        .fontColor(0xFF1C1C1E)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    Text(this.getFileSizeText())
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 2)
                } else if (this.item.itemType == LIST_MSG_TYPE_LINK) {
                    Text(this.item.linkTitle)
                        .fontSize(15)
                        .fontColor(0xFF1C1C1E)
                        .maxLines(2)
                        .textOverflow(TextOverflow.Ellipsis)
                    Text(this.item.linkSiteName)
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 2)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                } else {
                    Text(this.item.musicTitle)
                        .fontSize(15)
                        .fontColor(0xFF1C1C1E)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    Text(this.getMusicArtistLine())
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                        .margin(top: 2)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)

            // ---- 右侧时间 ----
            Text(this.getDateText())
                .fontSize(12)
                .fontColor(0xFF8E8E93)
                .margin(left: 8)
        }
        .width(100.percent)
        .padding(12)
        .onClick({ _ => this.handleTap() })
    }

    @Builder
    func buildFileIcon() {
        Stack {
            Column {}
                .width(46)
                .height(46)
                .borderRadius(8)
                .backgroundColor(this.getIconBgColor())
            Text(this.getIconText())
                .fontSize(10)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
        }
        .width(46)
        .height(46)
    }

    @Builder
    func buildLinkIcon() {
        Stack {
            Column {}
                .width(46)
                .height(46)
                .borderRadius(8)
                .backgroundColor(0xFF72D5FD)
            // 资源保真修复：真实矢量图标（Item List/Icons/Link.imageset 转 SVG，复用 chatroom_ic_link）替代 emoji 字形
            Image(@r(app.media.chatroom_ic_link))
                .width(22)
                .height(22)
                .fillColor(0xFFFFFFFF)
        }
        .width(46)
        .height(46)
    }

    @Builder
    func buildMusicIcon() {
        Stack {
            Column {}
                .width(46)
                .height(46)
                .borderRadius(8)
                .backgroundColor(0xFF5E5CE6)
            Text("♫")
                .fontSize(22)
                .fontColor(0xFFFFFFFF)
        }
        .width(46)
        .height(46)
    }

    private func getMusicArtistLine(): String {
        let dur = this.getMusicDurationText()
        let artist = this.item.musicArtist
        if (artist.size > 0) {
            return "${artist} · ${dur}"
        }
        return dur
    }
}

/**
 * ListMessageDateHeaderComponent — 日期分组头
 *
 * 对应 iOS ListMessageDateHeaderNode：
 *   显示粗体月份年份文字，如 "January 2024"，字母全大写，背景浅灰。
 */
@Component
public class ListMessageDateHeaderComponent {
    @Prop var group: ListMessageDateGroup

    public func build() {
        Row {
            Text(this.group.displayText.toAsciiUpper())
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 8, bottom: 4)
        .backgroundColor(0xFFF2F2F7)
    }
}

/**
 * ListMessageGroupView — 含日期头的完整分组视图
 *
 * 内联渲染一个分组（日期头 + 若干行），供外层 ForEach 使用：
 *
 *   ForEach(groups, itemGenerator: { g: ListMessageDateGroup, _: Int64 =>
 *       ListMessageGroupView(
 *           group: g,
 *           onDownload: { id, name => ... },
 *           onOpenUrl: { url => ... },
 *           onPlayMusic: { id => ... }
 *       )
 *   })
 */
@Component
public class ListMessageGroupView {
    @Prop var group: ListMessageDateGroup

    public var onDownload: (Int64, String) -> Unit = { _id: Int64, _name: String => }
    public var onOpenUrl: (String) -> Unit = { _url: String => }
    public var onPlayMusic: (Int64) -> Unit = { _id: Int64 => }

    public func build() {
        Column {
            // 日期分组头
            ListMessageDateHeaderComponent(group: this.group)

            // 该分组内的每条列表项
            ForEach(this.group.items, itemGenerator: { item: ListMessageItem, _: Int64 =>
                Column {
                    ListMessageComponent(
                        item: item,
                        onDownload: this.onDownload,
                        onOpenUrl: this.onOpenUrl,
                        onPlayMusic: this.onPlayMusic
                    )
                    // 分隔线
                    Row {}
                        .width(100.percent)
                        .height(1)
                        .backgroundColor(0xFFE5E5EA)
                        .margin(left: 70)
                }
            })
        }
        .width(100.percent)
    }
}
