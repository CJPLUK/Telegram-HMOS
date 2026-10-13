package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.*
import std.collection.ArrayList

/**
 * HorizontalPeerComponent — 水平用户项组件
 *
 * 水平滑动的用户头像+名字列表，用于最近联系人/在线好友展示。
 * 参考 iOS: Telegram-iOS/submodules/HorizontalPeerItem/Sources/HorizontalPeerItem.swift
 */
@Component
public class HorizontalPeerComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var items: ArrayList<HorizontalPeerItem> = ArrayList<HorizontalPeerItem>()
    @State var isLoading: Bool = false

    // 回调: (peerId, displayName, peerType) -> Unit，便于调用方导航
    public var onPeerClick: (Int64, String, String) -> Unit = { _peerId: Int64, _name: String, _ptype: String => }

    private func getAvatarColor(peerId: Int64): Int64 {
        let colors: Array<Int64> = [
            0xFFE91E63,
            0xFF9C27B0,
            0xFF3F51B5,
            0xFF03A9F4,
            0xFF009688,
            0xFF4CAF50,
            0xFFFF9800,
            0xFFFF5722
        ]
        let idx = peerId % 8
        let index = if (idx < 0) { Int64(-idx) } else { Int64(idx) }
        return colors[index]
    }

    private func getInitial(displayName: String): String {
        if (displayName.size > 0) {
            let runes = displayName.toRuneArray()
            if (runes.size > 0) {
                return runes[0].toString().toAsciiUpper()
            }
        }
        return "?"
    }

    private func loadPeers(): Unit {
        this.isLoading = true
        let _ = spawn {
            let service = getHorizontalPeerService()
            let peers = service.getRecentPeers(limit: Int32(12))
            launch {
                this.items = peers
                this.isLoading = false
            }
        }
    }

    public override func aboutToAppear(): Unit {
        this.loadPeers()
    }

    public func build() {
        Column {
            if (this.isLoading) {
                Text(trSource("Loading..."))
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .width(100.percent)
                    .height(80)
                    .textAlign(TextAlign.Center)
            } else {
                Scroll {
                    Row {
                        ForEach(this.items.toArray(), itemGenerator: { item: HorizontalPeerItem, _idx: Int64 =>
                            Column {
                                Stack(alignContent: Alignment.BottomEnd) {
                                    if (item.avatarLocalPath.size > 0) {
                                        Image(item.avatarLocalPath)
                                            .width(56)
                                            .height(56)
                                            .borderRadius(28)
                                            .objectFit(ImageFit.Cover)
                                    } else {
                                        Column {
                                            Text(this.getInitial(item.displayName))
                                                .fontSize(22)
                                                .fontWeight(FontWeight.Medium)
                                                .fontColor(0xFFFFFF)
                                        }
                                        .width(56)
                                        .height(56)
                                        .borderRadius(28)
                                        .backgroundColor(this.getAvatarColor(item.peerId))
                                        .justifyContent(FlexAlign.Center)
                                    }
                                    if (item.isOnline) {
                                        Column {}
                                            .width(14)
                                            .height(14)
                                            .borderRadius(7)
                                            .backgroundColor(0xFF4CD964)
                                            .border(width: 2, color: 0xFFFFFFFF)
                                    }
                                }
                                .width(56)
                                .height(56)
                                Text(item.displayName)
                                    .fontSize(12)
                                    .fontColor(0x000000)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .width(64)
                                    .textAlign(TextAlign.Center)
                                    .margin(top: 4)
                            }
                            .width(72)
                            .alignItems(HorizontalAlign.Center)
                            .onClick({ _evt =>
                                this.onPeerClick(item.peerId, item.displayName, item.peerType)
                            })
                        })
                    }
                    .padding(left: 12, right: 12)
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width(100.percent)
                .height(100)
            }
        }
        .width(100.percent)
    }
}
