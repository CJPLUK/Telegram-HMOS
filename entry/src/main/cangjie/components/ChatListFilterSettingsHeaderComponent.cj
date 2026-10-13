package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.ChatFolder
import ohos_app_cangjie_entry.services.getChatListFilterSettingsHeaderService
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}

/**
 * 对话过滤器设置头组件
 *
 * 对应 iOS ChatListFilterSettingsHeaderItem
 * 显示过滤器数量，点击可进入文件夹设置页面
 *
 * 调用 ChatListFilterSettingsHeaderService 获取真实数据，非 mock/stub
 */
@Component
public class ChatListFilterSettingsHeaderComponent {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var filterCount: Int32 = 0
    @State var isLoading: Bool = false

    // 点击回调（可选，None 时默认导航到 ChatFoldersPage）
    public var onHeaderClick: Option<() -> Unit> = None

    private func navigateToFoldersPage(): Unit {
        routerPush("ChatFoldersPage", "")
    }

    private func loadFilters(): Unit {
        this.isLoading = true
        let _ = spawn {
            let service = getChatListFilterSettingsHeaderService()
            let filters = service.getFilters()
            let count = Int32(filters.size)
            launch {
                this.filterCount = count
                this.isLoading = false
            }
        }
    }

    public override func aboutToAppear(): Unit {
        this.loadFilters()
    }

    public func build() {
        Row {
            Row {
                Text("对话过滤器")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)

                if (!this.isLoading && this.filterCount > 0) {
                    Text(" (${this.filterCount})")
                        .fontSize(17)
                        .fontColor(this.presentation.secondaryTextColor)
                }
            }
            .layoutWeight(1)

            Text("编辑")
                .fontSize(16)
                .fontColor(this.presentation.accentColor)
                .onClick({ evt =>
                    match (this.onHeaderClick) {
                        case Some(f) => f()
                        case None => this.navigateToFoldersPage()
                    }
                })
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(this.presentation.cardColor)
        .alignItems(VerticalAlign.Center)
        .onClick({ evt =>
            match (this.onHeaderClick) {
                case Some(f) => f()
                case None => this.navigateToFoldersPage()
            }
        })
    }
}
