package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getGlobalOverlayService

/**
 * GlobalOverlayHost — 应用级通用 overlay 宿主组件（P2-008）
 *
 * 对应 iOS Telegram 根容器统一 present 层：
 *   iOS 通过根 UIViewController.present(...) 在应用最上层显示 alert / tooltip /
 *   banner / sheet，本组件是 HarmonyOS 侧的等价宿主。
 *
 * 挂载位置：MainTabPage.build() 内最外层 Stack 中，位于来电覆盖层之下，
 *   OverlayStatusView 之下（允许 OverlayStatusView 和来电继续覆盖最顶层），
 *   DialogHost/ToastHost/UndoToast 之上（作为更通用的 overlay 入口）。
 *
 * 工作方式：
 *   - 每 300ms tick 轮询 GlobalOverlayService.getEpoch()
 *   - 若 epoch 变化则拉取新状态重绘
 *   - isAnyVisible()==true 时在屏幕中央显示栈顶 overlay 卡片
 *   - 点击外部遮罩或 dismiss 按钮时调用 getGlobalOverlayService().dismissTop()
 *
 * 不渲染时为 0 尺寸空组件，不占布局空间。
 */
@Component
public class GlobalOverlayHost {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var visible: Bool = false
    @State var topLabel: String = ""
    @State var topId: String = ""
    @State var seenEpoch: Int64 = -1

    public func aboutToAppear(): Unit {
        spawn {
            while (true) {
                sleep(Duration.millisecond * 300)
                let svc = getGlobalOverlayService()
                let epoch = svc.getEpoch()
                if (epoch != this.seenEpoch) {
                    let isVis = svc.isAnyVisible()
                    let topOpt = svc.getTop()
                    let label = match (topOpt) {
                        case Some(e) => e.label
                        case None => ""
                    }
                    let tid = match (topOpt) {
                        case Some(e) => e.id
                        case None => ""
                    }
                    launch {
                        this.seenEpoch = epoch
                        this.visible = isVis
                        this.topLabel = label
                        this.topId = tid
                    }
                }
            }
        }
    }

    public func build() {
        if (this.visible) {
            Stack(alignContent: Alignment.Center) {
                Column {
                    Column {
                        if (this.topLabel.size > 0) {
                            Text(this.topLabel)
                                .fontSize(16)
                                .fontColor(0xFF1C1C1E)
                                .textAlign(TextAlign.Center)
                                .margin(bottom: 16)
                        }
                        Button(trSource("OK"))
                            .width(120)
                            .height(40)
                            .borderRadius(20)
                            .backgroundColor(0xFF007AFF)
                            .fontColor(0xFFFFFFFF)
                            .fontSize(16)
                            .onClick({ _e: ClickEvent =>
                                Hilog.info(0, "CjTelegram",
                                    "[GlobalOverlayHost] dismiss id=${this.topId}")
                                getGlobalOverlayService().dismissTop()
                            })
                    }
                    .padding(24)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(14)
                    .width(280)
                    .alignItems(HorizontalAlign.Center)
                    .justifyContent(FlexAlign.Center)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x88000000)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _e: ClickEvent =>
                    getGlobalOverlayService().dismissTop()
                })
            }
            .width(100.percent)
            .height(100.percent)
        }
    }
}
