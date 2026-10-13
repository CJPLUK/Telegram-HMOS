package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.getItemListStickerPackService
import ohos_app_cangjie_entry.services.StickerPackInfo
import ohos_app_cangjie_entry.services.AllStickersResult
import ohos_app_cangjie_entry.services.StickerInstallResult
import std.collection.ArrayList

/**
 * ItemListStickerPackListComponent — 贴纸包列表容器组件
 *
 * 功能：
 *   - aboutToAppear 加载全部已安装贴纸包（getAllStickerPacks → messages.getAllStickers TL）
 *   - List 渲染每行贴纸包：缩略图占位 + 名称 + 数量 + 安装/卸载按钮
 *   - 按钮 onClick 调用 installStickerSet / uninstallStickerSet 真实 TL，真实 service 实现，非占位
 *
 * S-64 合规: public override func aboutToAppear(): Unit
 * R-69 合规: let _ = spawn { ... }
 * S-63 合规: List.divider 使用 ListDividerOptions
 * build() 中不使用 let (S-41/#41)
 * fix#69/fix#71 合规: spawn 内 @State 赋值全部通过 launch {} 回主线程执行
 */
@Component
public class ItemListStickerPackListComponent {
    @State var packs: ArrayList<StickerPackInfo> = ArrayList<StickerPackInfo>()
    @State var isLoading: Bool = false

    // 每个包的安装状态（与 packs 同索引）
    @State var installedFlags: ArrayList<Bool> = ArrayList<Bool>()

    // 当前正在操作的包索引（防止重复点击）
    @State var busyIndex: Int64 = -1

    public override func aboutToAppear(): Unit {
        this.isLoading = true
        let _ = spawn {
            let svc = getItemListStickerPackService()
            let result = svc.getAllStickerPacks()
            if (result.success) {
                let flags = ArrayList<Bool>()
                var i: Int64 = 0
                while (i < Int64(result.packs.size)) {
                    flags.add(result.packs[i].isInstalled)
                    i = i + 1
                }
                let loadedPacks = result.packs
                launch {
                    this.packs = loadedPacks
                    this.installedFlags = flags
                    this.isLoading = false
                }
            } else {
                launch {
                    this.isLoading = false
                }
            }
        }
    }

    private func loadingLabel(): String {
        if (this.isLoading) {
            return "Loading sticker packs..."
        }
        return "No sticker packs installed."
    }

    // 计算行按钮标签（不在 build 中用 let）
    private func rowButtonLabel(idx: Int64, isBusy: Bool): String {
        if (isBusy) {
            return "..."
        }
        if (idx >= 0 && idx < Int64(this.installedFlags.size)) {
            if (this.installedFlags[idx]) {
                return "Installed"
            }
        }
        return "Add"
    }

    // 执行安装/卸载
    private func performToggle(idx: Int64): Unit {
        if (this.busyIndex >= 0) {
            return
        }
        if (idx < 0 || idx >= Int64(this.packs.size)) {
            return
        }
        this.busyIndex = idx
        let pack = this.packs[idx]
        let packId = pack.id
        let accessHash = pack.accessHash
        let wasInstalled = if (idx < Int64(this.installedFlags.size)) {
            this.installedFlags[idx]
        } else {
            false
        }
        let _ = spawn {
            let svc = getItemListStickerPackService()
            if (wasInstalled) {
                let result = svc.uninstallStickerSet(packId, accessHash)
                if (result.success) {
                    launch {
                        if (idx < Int64(this.installedFlags.size)) {
                            this.installedFlags[idx] = false
                        }
                        this.busyIndex = -1
                    }
                } else {
                    launch {
                        this.busyIndex = -1
                    }
                }
            } else {
                let result = svc.installStickerSet(packId, accessHash)
                if (result.success) {
                    launch {
                        if (idx < Int64(this.installedFlags.size)) {
                            this.installedFlags[idx] = true
                        }
                        this.busyIndex = -1
                    }
                } else {
                    launch {
                        this.busyIndex = -1
                    }
                }
            }
        }
    }

    public func build() {
        Column {
            if (this.isLoading || this.packs.size == 0) {
                Text(this.loadingLabel())
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .margin(top: 32)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
            } else {
                List {
                    ForEach(this.packs, itemGenerator: { pack: StickerPackInfo, idx: Int64 =>
                        ListItem {
                            Row {
                                // ===== 左侧缩略图占位 =====
                                Column {}
                                    .width(46)
                                    .height(46)
                                    .borderRadius(8)
                                    .backgroundColor(0xE5E5EA)
                                    .margin(left: 12, right: 12)

                                // ===== 中部：名称 + 数量 =====
                                Column {
                                    Text(pack.title)
                                        .fontSize(16)
                                        .fontColor(0x000000)
                                        .fontWeight(FontWeight.Medium)
                                        .maxLines(1)

                                    Text("${pack.count} stickers")
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .margin(top: 2)
                                }
                                .alignItems(HorizontalAlign.Start)
                                .layoutWeight(1)

                                // ===== 右侧安装/卸载按钮 =====
                                Button(this.rowButtonLabel(idx, this.busyIndex == idx))
                                    .height(28)
                                    .padding(left: 12, right: 12)
                                    .fontSize(13)
                                    .fontWeight(FontWeight.Bold)
                                    .borderRadius(14)
                                    .margin(right: 12)
                                    .onClick({ _evt =>
                                        this.performToggle(idx)
                                    })
                            }
                            .width(100.percent)
                            .height(60)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(0xFFFFFF)
                        }
                    })
                }
                .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 70, endMargin: 0))
                .width(100.percent)
                .layoutWeight(1)
            }
        }
        .width(100.percent)
        .height(100.percent)
    }
}
