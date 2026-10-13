/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.CoreFileKit.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.providers.PrivacyDataProvider
import ohos_app_cangjie_entry.components.{ArchiveInfoContent, getEmptyAnimatedEmojiPixelMap}
import ohos_app_cangjie_entry.utils.readRawFileBytes
import ohos_app_cangjie_entry.services.{
    getGlobalAbilityContext,
    openAnimatedStickerFileStream,
    StreamingLottiePlayer
}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * ArchiveInfoScreen 弹层宿主（S2-A，归档说明弹层）。
 *
 * iOS ref: submodules/TelegramUI/Components/Settings/ArchiveInfoScreen/Sources/
 *   ArchiveInfoScreen.swift:150-309 `ArchiveInfoScreenComponent` / `ArchiveInfoScreen.init`
 *   —— SheetComponent 包裹 + "Got it" 关闭 + openSettings push 归档设置屏；
 *   navigationBarAppearance: .none、navigationPresentation = .flatModal。
 *
 * ⚠ 路由挂线缺口（本 Worker allowlist 不含以下文件，需后续轮次补齐；在此之前本页
 * 无法被 routerPush("ArchiveInfoPage", ...) 真正到达，详见 shell_settings_misc.md 交付报告）：
 *   1. entry/src/main/resources/base/profile/route_map.json —— 需新增 "ArchiveInfoPage"
 *      路由项（name + pageSourceFile + buildFunction）；ArkUI NavPathStack.pushPathByName
 *      的硬性前置条件（本项目全部路由，包括同类 ArchiveSettingsPage，均经此表注册，
 *      无 pageMap 兜底通道）。
 *   2. entry/src/main/ets/pages/ArchiveInfoPage.ets —— 需新建 NavDestination 壳，
 *      对位 entry/src/main/ets/pages/ArchiveSettingsPage.ets 的
 *      `CJHybridComponent({library:'ohos_app_cangjie_entry', component:'ArchiveInfoPage'})` 写法。
 *   3. entry/src/main/ets/router/CustomTransition.ets 的 MODAL_ROUTES —— 需把
 *      "ArchiveInfoPage" 加入集合，才能获得源侧 flatModal（竖直上滑 sheet）转场；
 *      在此之前若强行到达本页，会退化成默认横向 push 转场。
 *   4. pages/ChatListPage.cj 的两条入口边（N11 自动弹层 / N12 上下文菜单长按入口）
 *      不在本 feature 的 allowlist 内（归属 clist_* 系列 feature 的 target_files），
 *      本轮不接线，本页目前无任何调用方。
 *
 * 数据来源：keepArchivedUnmuted 取自 providers/PrivacyDataProvider.loadGlobalPrivacy()
 * （对位源侧 GlobalPrivacy = TelegramEngine.EngineData.Item.Configuration.GlobalPrivacy()）；
 * 取不到（异常）时静默降级为源侧默认值 true（对位源侧 E4：GlobalPrivacy 网络失败静默用
 * 本地缓存值），不弹任何 error UI。
 * 明确不读 AuthStorage.KEY_ARCHIVE_KEEP_UNMUTED —— 那是 ArchiveSettingsPage 的孤儿键，
 * 源侧无对应物且默认值与源侧相反（诊断报告判为另一缺陷根因 TC-0085 E1），不得带入本屏。
 */
// "Got it" 按钮左侧 anim_ok Lottie 的帧缓存 key（固定负常量，避免与消息贴纸的真实
// document id（恒为正）冲突）——命名与用法对位 pages/ChangePhoneIntroPage.cj:65
// CHANGE_PHONE_INTRO_ANIM_DOC_ID 同一先例，取另一个未占用的负值。
private let ARCHIVE_INFO_GOT_IT_ANIM_DOC_ID: Int64 = -9002001

@HybridComponentEntry
@Component
public class ArchiveInfoPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var keepArchivedUnmuted: Bool = true
    @State var loaded: Bool = false

    // "Got it" 按钮左侧 anim_ok Lottie 播放状态（对位源侧 ArchiveInfoScreen.swift:83-90
    // LottieComponent(startingPosition:.begin, playOnce:) —— 首次挂载播一次，播完停在末帧）。
    @State var gotItAnimReady: Bool = false
    var gotItAnimStream: Option<StreamingLottiePlayer> = None<StreamingLottiePlayer>
    @State var gotItAnimFrameIndex: Int64 = 0
    private var gotItAnimTimer: Option<Timer> = None<Timer>
    private var gotItAnimLocalPath: String = ""

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        spawn {
            var loadedValue = true
            try {
                let provider = PrivacyDataProvider()
                let data = provider.loadGlobalPrivacy()
                loadedValue = data.keepArchivedUnmuted
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ArchiveInfoPage] loadGlobalPrivacy error=${e}")
                loadedValue = true
            }
            let value = loadedValue
            launch {
                this.keepArchivedUnmuted = value
            }
        }
        this.extractGotItAnimation()
    }

    public override func aboutToDisappear(): Unit {
        this.stopGotItAnimPlayback()
    }

    // 把 rawfile/anim_ok.tgs 提取到沙箱——形状照抄
    // pages/ChangePhoneIntroPage.cj:109-141 extractIntroAnimation()（ctx 判空、mkdir 的
    // try/catch、每次覆盖写，避免升级后残留旧资源）。禁用 @rawfile() 宏：该宏生成
    // __GenerateResource__ native 符号调用，在 CJ so 加载时无法解析，导致 SIGSEGV
    // （证据注释见 auth/SplashPage.cj:284-286 同一坑）。
    private func extractGotItAnimation(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let animDir = filesDir + "/archive_info_anim"
                try { FileIo.mkdir(animDir) } catch (_e: Exception) {}
                let name = "anim_ok.tgs"
                let targetPath = animDir + "/" + name
                match (readRawFileBytes(name)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[ArchiveInfoPage] extractGotItAnimation: readRawFileBytes returned None for ${name}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.gotItAnimLocalPath = "file://" + targetPath
                                this.loadGotItAnimation()
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[ArchiveInfoPage] extractGotItAnimation: write failed for ${name}")
                            }
                        }
                }
        }
    }

    // 解码沙箱内的 anim_ok.tgs（同 AnimatedStickerComponent.aboutToAppear 的
    // ensureAnimatedStickerFileLoaded 调用形状：spawn 里做 CPU 密集的 rlottie 解码，
    // 完成后 launch 回主线程刷新 @State）。加载失败时 gotItAnimReady 保持 false，
    // 按钮静默降级为纯文字（不弹 error UI、不改按钮尺寸）。
    private func loadGotItAnimation(): Unit {
        let path = this.gotItAnimLocalPath
        if (path.size == 0) { return }
        let docId = ARCHIVE_INFO_GOT_IT_ANIM_DOC_ID
        spawn {
            match (openAnimatedStickerFileStream(docId, path)) {
                case Some(player) =>
                    if (player.getFrameCount() > 1) { let _ = player.prepareNextFrame(1) }
                    launch {
                        this.gotItAnimStream = Some(player)
                        this.gotItAnimReady = true
                        this.gotItAnimFrameIndex = 0
                        this.startGotItAnimPlayback()
                    }
                case None => ()
            }
        }
    }

    private func currentGotItAnimFrame(): PixelMap {
        match (this.gotItAnimStream) {
            case Some(player) =>
                match (player.getCurrentFrame()) {
                    case Some(frame) => return frame
                    case None => return getEmptyAnimatedEmojiPixelMap()
                }
            case None => return getEmptyAnimatedEmojiPixelMap()
        }
    }

    // 播放语义照抄 components/ProfileMuteIcon.cj:50-69 startPlayback()：播到末帧即停
    // （不循环），对位源侧 startingPosition:.begin + playOnce（区别于
    // AnimatedStickerComponent 的贴纸循环播放语义，Got it 是一次性播放场景）。
    private func startGotItAnimPlayback(): Unit {
        this.stopGotItAnimPlayback()
        var frameCount: Int64 = 0
        var frameInterval: Int32 = 0
        match (this.gotItAnimStream) {
            case Some(player) =>
                frameCount = player.getFrameCount()
                frameInterval = player.getFrameDurationMs()
            case None => return
        }
        let count = frameCount
        var interval = frameInterval
        if (count <= 1) { return }
        if (interval < 16) { interval = 16 }
        this.gotItAnimTimer = Some(Timer.repeat(
            Duration.millisecond * Int64(interval), Duration.millisecond * Int64(interval),
            { =>
                launch {
                    if (this.gotItAnimFrameIndex + 1 >= count) {
                        this.gotItAnimFrameIndex = count - 1
                        this.stopGotItAnimPlayback()
                    } else {
                        this.gotItAnimFrameIndex = this.gotItAnimFrameIndex + 1
                        match (this.gotItAnimStream) {
                            case Some(player) => let _ = player.advanceTo(this.gotItAnimFrameIndex)
                            case None => ()
                        }
                    }
                }
            }, style: CatchupStyle.Skip
        ))
    }

    private func stopGotItAnimPlayback(): Unit {
        match (this.gotItAnimTimer) {
            case Some(timer) =>
                timer.cancel()
                this.gotItAnimTimer = None<Timer>
            case None => ()
        }
    }

    // 正文点击：改用 routerReplaceTop（对位源侧 ArchiveInfoScreen.swift:220-233
    // `navigationController.pushViewController(...)` + `controller.dismiss()`——后者
    // 经 ViewController.dismiss → NavigationController.filterController(self) 按
    // controller 身份摘掉自己，与 NavigationController.swift:1548-1554
    // replaceTopController 净栈效果等价）。目标侧 NavPathStack 只有位置寻址，
    // routerReplaceTop（router/router.cj:33-37）已把该等价的最终栈形态原子实现——
    // 弹出栈顶一层、原地 push 新页面。不得拆成 routerPush + routerPop 两步：两次
    // 独立 interop 调用非原子，会引入转场竞态，且两步各自弹/推同一条全局唯一栈时
    // 会互相抵消（先前正是这个写法导致点击净效果为零）。先例：
    // pages/ChangePhoneIntroPage.cj:150。
    private func openSettings(): Unit {
        routerReplaceTop("ArchiveSettingsPage", "")
    }

    // Got it：只关闭弹层，不做任何其它事（源侧 buttonAction? 在现有两个调用点都没传值，
    // 等价于纯关闭，不得为它添加任何后续动作）。
    private func closeSheet(): Unit {
        routerPop()
    }

    public func build() {
        Column {
            Column {
                Column {
                    ArchiveInfoContent(
                        keepArchivedUnmuted: this.keepArchivedUnmuted,
                        onOpenSettings: { => this.openSettings() }
                    )
                }
                .width(100.percent)
                .margin(top: 24)

                Column {
                    // 源侧左侧 28x28 Lottie(anim_ok) 首次挂载播一次 + "Got it" 文字
                    // （ArchiveInfoScreen.swift:83-90 LottieComponent + ButtonTextContentComponent
                    // 在 HStack(spacing: 2.0) 里并排）。资源与解码通路照抄
                    // pages/ChangePhoneIntroPage.cj:33,109（rawfile .tgs → 沙箱提取）+
                    // components/AnimatedStickerComponent.cj 的 ensureAnimatedStickerFileLoaded
                    // 解码调用（同一套已在编 rlottie 桥），播放语义（播一次停末帧）照抄
                    // components/ProfileMuteIcon.cj:50-69 startPlayback()。
                    // 资源加载失败时静默降级为纯文字按钮，不弹 error UI、不改按钮尺寸
                    // （与 ProfileMuteIcon.cj:88-93 的 ready=false 兜底同型）。
                    Button() {
                        Row {
                            if (this.gotItAnimReady) {
                                Image(this.currentGotItAnimFrame())
                                    .id("archiveInfoGotItAnim_${this.gotItAnimFrameIndex}")
                                    .width(28)
                                    .height(28)
                                    .objectFit(ImageFit.Contain)
                                    .margin(right: 2)
                            }
                            Text(trSource("Got it"))
                                .fontSize(17)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFFFFFF)
                        }
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                    }
                        .width(100.percent)
                        .height(50)
                        .backgroundColor(0x317AFF)
                        .borderRadius(12)
                        .onClick({ _evt => this.closeSheet() })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 24, bottom: 16)
            }
            .width(100.percent)
            .backgroundColor(0xFFFFFF)
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
            .borderRadius(topLeft: 16, topRight: 16)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.End)
        .onAppear({ => this.ensureLoaded() })
    }
}
