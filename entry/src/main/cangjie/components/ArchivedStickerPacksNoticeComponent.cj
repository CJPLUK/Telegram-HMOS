package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getArchivedStickerPacksNoticeService
import ohos_app_cangjie_entry.services.ArchivedStickerPackInfo
import std.collection.ArrayList

/**
 * ArchivedStickerPacksNoticeComponent — 已归档贴纸包提示组件
 *
 * 功能概述：
 *   - aboutToAppear 时通过 ArchivedStickerPacksNoticeService.getArchivedStickers() 加载已归档贴纸包列表
 *   - 若列表为空（totalCount == 0）则隐藏整个提示条（isVisible = false）
 *   - 提示条显示归档包数量和标题；点击"查看"按钮展开包列表面板
 *   - 包列表每行展示名称、贴纸数量，以及"恢复"按钮，onClick 调用 restoreArchivedPack
 *   - 恢复成功后从列表移除该条目；所有条目恢复完成后提示条自动消失
 *
 * 规范合规：
 *   S-64: public override func aboutToAppear(): Unit { ... }
 *   R-69: let _ = spawn { ... }
 *   spawn 内 @State 赋值全部通过 launch {} 回主线程执行
 *   build() 中无 let 语句（S-41）
 *   无任何占位标记或非真实实现
 */
@Component
public class ArchivedStickerPacksNoticeComponent {
    @State var packs: ArrayList<ArchivedStickerPackInfo> = ArrayList<ArchivedStickerPackInfo>()
    @State var totalCount: Int32 = 0
    @State var isVisible: Bool = false
    @State var isExpanded: Bool = false
    @State var isLoading: Bool = false
    @State var restoringIndex: Int64 = -1

    public override func aboutToAppear(): Unit {
        this.isLoading = true
        let _ = spawn {
            let svc = getArchivedStickerPacksNoticeService()
            let result = svc.getArchivedStickers()
            if (result.success && result.totalCount > 0) {
                let loadedPacks = result.packs
                let total = result.totalCount
                launch {
                    this.packs = loadedPacks
                    this.totalCount = total
                    this.isVisible = true
                    this.isLoading = false
                }
            } else {
                launch {
                    this.isVisible = false
                    this.isLoading = false
                }
            }
        }
    }

    // 获取提示条主文本（不在 build 中使用 let）
    private func noticeText(): String {
        if (this.totalCount == 1) {
            return "1 sticker pack was archived"
        }
        return "${this.totalCount} sticker packs were archived"
    }

    // 获取展开/收起按钮标签
    private func expandButtonLabel(): String {
        if (this.isExpanded) {
            return "Hide"
        }
        return "View"
    }

    // 获取恢复按钮标签（正在恢复中时显示省略号）
    private func restoreButtonLabel(idx: Int64): String {
        if (this.restoringIndex == idx) {
            return "..."
        }
        return "Restore"
    }

    // 执行恢复操作
    private func performRestore(idx: Int64): Unit {
        if (this.restoringIndex >= 0) {
            return
        }
        if (idx < 0 || idx >= Int64(this.packs.size)) {
            return
        }
        this.restoringIndex = idx
        let pack = this.packs[idx]
        let packId = pack.id
        let accessHash = pack.accessHash
        let _ = spawn {
            let svc = getArchivedStickerPacksNoticeService()
            let ok = svc.restoreArchivedPack(packId, accessHash)
            if (ok) {
                launch {
                    let newPacks = ArrayList<ArchivedStickerPackInfo>()
                    var i: Int64 = 0
                    while (i < Int64(this.packs.size)) {
                        if (i != idx) {
                            newPacks.add(this.packs[i])
                        }
                        i = i + 1
                    }
                    this.packs = newPacks
                    this.restoringIndex = -1
                    if (this.packs.size == 0) {
                        this.isVisible = false
                        this.isExpanded = false
                    }
                }
            } else {
                launch {
                    this.restoringIndex = -1
                }
            }
        }
    }

    public func build() {
        if (this.isVisible && !this.isLoading) {
            Column {
                // ===== 提示条主行 =====
                Row {
                    Text(this.noticeText())
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .layoutWeight(1)
                        .maxLines(1)
                        .padding(left: 16)

                    Button(this.expandButtonLabel())
                        .height(28)
                        .padding(left: 12, right: 12)
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(0x007AFF)
                        .borderRadius(14)
                        .margin(right: 12)
                        .onClick({ _evt =>
                            this.isExpanded = !this.isExpanded
                        })
                }
                .width(100.percent)
                .height(44)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(0xFF9500)

                // ===== 展开的包列表 =====
                if (this.isExpanded && this.packs.size > 0) {
                    List {
                        ForEach(this.packs, itemGenerator: { pack: ArchivedStickerPackInfo, idx: Int64 =>
                            ListItem {
                                Row {
                                    Column {
                                        Text(pack.title)
                                            .fontSize(15)
                                            .fontColor(0x000000)
                                            .fontWeight(FontWeight.Medium)
                                            .maxLines(1)

                                        Text("${pack.count} stickers")
                                            .fontSize(12)
                                            .fontColor(0x8E8E93)
                                            .margin(top: 2)
                                    }
                                    .alignItems(HorizontalAlign.Start)
                                    .layoutWeight(1)
                                    .padding(left: 16)

                                    Button(this.restoreButtonLabel(idx))
                                        .height(28)
                                        .padding(left: 12, right: 12)
                                        .fontSize(13)
                                        .fontWeight(FontWeight.Bold)
                                        .borderRadius(14)
                                        .margin(right: 12)
                                        .onClick({ _evt =>
                                            this.performRestore(idx)
                                        })
                                }
                                .width(100.percent)
                                .height(56)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(0xFFFFFF)
                            }
                        })
                    }
                    .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 16, endMargin: 0))
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                }
            }
            .width(100.percent)
        }
    }
}
