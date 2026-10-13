package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.*
import ohos_app_cangjie_entry.components.{AnimatedStickerComponent}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * TwoFactorAuthSplashPage — RC-2 现代 2FA 引导屏 (diag-suite_settings_privacy-TC-0141.md §6.2)
 *
 * 对位源侧 `TwoFactorAuthSplashScreen.swift`（`.intro` mode）：账号未设 2FA 密码时，
 * 从 `PrivacySettingsPage.cj openTwoStepVerification()` 分叉到本屏，而不是直落
 * `TwoFactorAuthPage`。本屏只展示说明 + 一个"Set Additional Password"按钮，点击后
 * push `TwoFactorCreatePasswordPage`（RC-2 的 `Create Password` 屏，同批新建）。
 *
 * 文案逐字取自 `Telegram/Telegram-iOS/en.lproj/Localizable.strings:5013-5015`
 * （`TwoFactorSetup.Intro.Title/Text/Action`）。布局常量取自
 * `TwoFactorAuthSplashScreen.swift:271-333`（`containerLayoutUpdated`）：
 * 动画显示尺寸 124x124（`:177 animationSize`，不是 `setup()` 里的 248 离屏渲染尺寸）、
 * `iconSpacing=8`、`titleSpacing=19`、标题 `Font.bold(32.0)`、正文 `Font.regular(16.0)`、
 * 按钮 `height=50 cornerRadius=11`、`buttonSideInset=48`。
 *
 * 动画播放：`AnimatedStickerComponent` 直接吃 `.tgs`（经 `libentry.so` 的
 * `tg_lottie_*` 桥，内部 zlib 解压 + rlottie 渲染），不需要任何 PNG 帧提取管线——
 * 先例 `pages/ChangePhoneIntroPage.cj`（`ChangePhoneNumber.tgs` 与源侧 md5 相同、原样
 * 播放）。本屏同构：`resources/rawfile/TwoFactorSetupIntro.tgs` 原样拷自源仓
 * `submodules/PasswordSetupUI/Resources/TwoFactorSetupIntro.tgs`，未转码/未抽帧。
 *
 * 已知限制：源侧 `playbackMode: .once`（播放一次后停在末帧），
 * `AnimatedStickerComponent` 只支持循环播放（`components/AnimatedStickerComponent.cj`
 * `startStreamPlayback` 到 `frameCount-1` 后回绕到 0），本屏会持续循环播放该引导动画，
 * 而非播放一次后定格——与已批准先例 `ChangePhoneIntroPage.cj`（同一 SDK 能力缺口）
 * 现状一致，不在本轮范围内单独解决。
 */
private let TWO_FACTOR_SPLASH_ANIM_DOC_ID: Int64 = -9003100

@HybridComponentEntry
@Component
public class TwoFactorAuthSplashPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var animLocalPath: String = ""

    // 形状照抄 pages/ChangePhoneIntroPage.cj:83-85 extractIntroAnimation() 调用点：
    // 沙箱路径提取必须先于首次 build()，用无装饰 var 一次性快照的调用契约见该文件注释。
    public override func aboutToAppear(): Unit {
        this.extractSplashAnimation()
    }

    // 形状照抄 pages/ChangePhoneIntroPage.cj:118-150 extractIntroAnimation()：纯同步
    // （readRawFileBytes + FileIo.write，无 spawn/网络），禁用 @rawfile() 宏（该宏生成
    // __GenerateResource__ native 符号调用，在 CJ so 加载时无法解析，导致 SIGSEGV，
    // 证据见 auth/SplashPage.cj:284-286）。
    private func extractSplashAnimation(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let dir = filesDir + "/two_factor_splash"
                try { FileIo.mkdir(dir) } catch (_e: Exception) {}
                let name = "TwoFactorSetupIntro.tgs"
                let targetPath = dir + "/" + name
                match (readRawFileBytes(name)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[TwoFactorAuthSplashPage] extractSplashAnimation: readRawFileBytes returned None for ${name}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.animLocalPath = "file://" + targetPath
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[TwoFactorAuthSplashPage] extractSplashAnimation: write failed for ${name}")
                            }
                        }
                }
        }
    }

    // 对位源侧 :100-107 push(TwoFactorDataInputScreen(mode: .password(...)))——目标侧的
    // Create Password 屏是同批新建的 TwoFactorCreatePasswordPage（RC-2 §6.3）。
    private func onSetPasswordTap(): Unit {
        routerPush("TwoFactorCreatePasswordPage")
    }

    // RC-P3（diag round2 §6.3）：返回控件图形，与 app/TelegramNavBar.cj:194 的 .legacy
    // 分支同一资源。`navBackArrowLegacyRes()` 是 app 包内可见函数（非 public），跨包不可
    // 访问，本页独立持有一份同值访问器（同形态见 TwoFactorCreatePasswordPage.cj）。
    private func navBackArrowIcon(): AppResource {
        return @r(app.media.nav_back_arrow_legacy)
    }

    public func build() {
        Column {
            // 导航栏：源侧 `hasBackButton = true`（:70-76，`.intro` mode 恒有返回项、
            // 无右侧按钮、无居中标题——大字标题在正文区，不在 nav bar）。
            // RC-P3：图形+文字同为热区，数值与 TelegramNavBar.cj:194-200 的 .legacy 分支
            // 逐值一致（13×22、margin(left:6)、17pt）。
            Row {
                Row {
                    Image(this.navBackArrowIcon())
                        .width(13)
                        .height(22)
                        .fillColor(0x007AFF)
                    Text(trSource("Back"))
                        .fontSize(17)
                        .fontColor(0x007AFF)
                        .margin(left: 6)
                }
                .onClick({ evt => routerPop() })
                Blank().layoutWeight(1)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // 固定 124x124 容器，对位 :177 animationSize（不是 setup() 的 248 渲染尺寸）。
                    Stack(alignContent: Alignment.Center) {
                        if (this.animLocalPath.size > 0) {
                            AnimatedStickerComponent(
                                documentId: TWO_FACTOR_SPLASH_ANIM_DOC_ID,
                                localPath: this.animLocalPath,
                                displaySize: 124.0
                            )
                        }
                    }
                    .width(124)
                    .height(124)
                    .margin(top: 40)

                    // TwoFactorSetup.Intro.Title (Localizable.strings:5013)
                    Text(trSource("Additional Password"))
                        .fontSize(32)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .textAlign(TextAlign.Center)
                        .margin(top: 8)
                        .padding(left: 32, right: 32)
                        .width(100.percent)

                    // TwoFactorSetup.Intro.Text (Localizable.strings:5014, 含硬换行)
                    Text(trSource("You can set a password that will be\nrequired when you log in on a new device in addition to the code you get via SMS."))
                        .fontSize(16)
                        .fontColor(0x000000)
                        .textAlign(TextAlign.Center)
                        .margin(top: 19)
                        .padding(left: 32, right: 32)
                        .width(100.percent)
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
            }
            .align(Alignment.Top)
            .layoutWeight(1)

            // TwoFactorSetup.Intro.Action (Localizable.strings:5015)——SolidRoundedButtonNode
            // 形态：height=50 cornerRadius=11 buttonSideInset=48（:272/:275/:303）。
            Column {
                Button(trSource("Set Additional Password"))
                    .width(100.percent)
                    .height(50)
                    .fontSize(17)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x007AFF)
                    .borderRadius(11)
                    .onClick({ evt => this.onSetPasswordTap() })
            }
            .width(100.percent)
            .padding(left: 48, right: 48, bottom: 40)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(bottom: getSafeAreaBottom())
    }
}
