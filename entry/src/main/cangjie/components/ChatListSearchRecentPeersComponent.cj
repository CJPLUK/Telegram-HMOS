package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

/**
 * 最近联系人搜索节点组件
 *
 * 对应 iOS ChatListSearchRecentPeersNode
 * 在搜索界面顶部显示最近联系人的水平滚动列表
 *
 * 参考: input/Telegram-iOS/submodules/ChatListSearchRecentPeersNode/Sources/ChatListSearchRecentPeersNode.swift
 */
@Component
public class ChatListSearchRecentPeersComponent {
    @State var recentPeers: ArrayList<ChatEntry> = ArrayList<ChatEntry>()
    @State var isLoading: Bool = true

    public func aboutToAppear(): Unit {
        this.loadRecentPeers()
    }

    private func loadRecentPeers(): Unit {
        this.isLoading = true
        let _ = spawn {
            let service = getChatListSearchRecentPeersService()
            // The iOS global-search surface currently exposes the most recent
            // peer as a single quick target before a query is entered.
            let chats = service.getRecentPeers(limit: 1)
            let entries = ArrayList<ChatEntry>()
            for (c in chats) {
                entries.add(ChatEntry(c))
            }
            launch {
                this.recentPeers = entries
                this.isLoading = false
            }
        }
    }

    private func onPeerClick(chat: Chat): Unit {
        setSelectedChat(chat.id, chat.name, chat.peerType)
        setSelectedChatDraft(chat.draftText)
        setSelectedChatUsername(chat.username)
        routerPush("ChatRoomPage", chat.name)
    }

    public func build() {
        if (this.isLoading) {
            Row {
                LoadingProgress()
                    .width(24)
                    .height(24)
                    .color(0x317AFF)
            }
            .width(100.percent)
            .height(86)
            .justifyContent(FlexAlign.Center)
        } else if (this.recentPeers.isEmpty()) {
            Column {}
                .width(100.percent)
                .height(0)
        } else {
            Scroll {
                Row {
                    ForEach(this.recentPeers, itemGenerator: { entry: ChatEntry, index: Int64 =>
                        Column {
                            Column {
                                Avatar(
                                    avatarUrl: entry.chat.avatarLocalPath,
                                    displayName: entry.chat.name,
                                    avatarSize: 50,
                                    avatarColor: entry.chat.avatarColor,
                                    isOnline: entry.chat.isOnline && !entry.chat.isGroup && !entry.chat.isChannel,
                                    showOnlineIndicator: !entry.chat.isGroup && !entry.chat.isChannel
                                )
                                Text(entry.chat.name)
                                    .fontSize(12)
                                    .fontColor(0x000000)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .width(60)
                                    .textAlign(TextAlign.Center)
                                    .margin(top: 4)
                            }
                            .width(70)
                            .margin(right: 12)
                            .onClick({ evt =>
                                this.onPeerClick(entry.chat)
                            })
                        }
                    })
                }
                .padding(left: 16, right: 16, top: 8, bottom: 8)
            }
            .scrollable(ScrollDirection.Horizontal)
            .width(100.percent)
            .height(86)
        }
    }
}
