package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.components.{AnimatedStickerComponent, ITEM_LIST_TEXT_SECONDARY}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * 换号说明前置屏 (diag-suite_settings_root-TC-0083.md round4 M-2-b)
 *
 * 对位源侧 PrivacyIntroController
 * (submodules/SettingsUI/Sources/Privacy and Security/PrivacyIntroController.swift)：
 * 一个 mode 参数化的通用说明屏，三个 mode（.passcode / .twoStepVerification /
 * .changePhoneNumber）复用同一份渲染节点（PrivacyIntroControllerNode.swift）。本轮只落地
 * .changePhoneNumber 一个 mode，但参数化结构本身按源侧结构建起——D4.4 明令禁止把
 * "源侧是通用中间层"这种结构级差异压成"只服务换号"的单 mode 特判。
 *
 * 三处入口（EditProfilePage.cj:612 / SettingsPage.cj:864 / SettingsPageService.cj:155
 * 搜索索引）收敛到本页，通过 paramJson 的 "proceed" 字段承载 replace_top/push 二元语义
 * （PeerInfo 两入口=replace_top、搜索入口=push，二者源侧本身如此，不是笔误，不得统一）。
 */
public enum PrivacyIntroMode {
    | ChangePhoneNumber
}

private func modeAnimationRawfileName(mode: PrivacyIntroMode): String {
    match (mode) {
        case PrivacyIntroMode.ChangePhoneNumber => "ChangePhoneNumber.tgs"
    }
}

private func modeControllerTitle(mode: PrivacyIntroMode): String {
    match (mode) {
        case PrivacyIntroMode.ChangePhoneNumber => "Change Number"
    }
}

private func modeText(mode: PrivacyIntroMode): String {
    match (mode) {
        case PrivacyIntroMode.ChangePhoneNumber =>
            "You can change your Telegram number here. Your account and all your cloud data — messages, media, contacts, etc. will be moved to the new number."
    }
}

private func modeButtonTitle(mode: PrivacyIntroMode): String {
    match (mode) {
        case PrivacyIntroMode.ChangePhoneNumber => "Change Number"
    }
}

private func modeNotice(mode: PrivacyIntroMode): String {
    match (mode) {
        // 换号与 2FA 在源侧合并返回 ""（PrivacyIntroController.swift:83-84）。
        case PrivacyIntroMode.ChangePhoneNumber => ""
    }
}

// documentId 是 AnimatedStickerComponent 的帧缓存 key，固定负常量，避免与消息贴纸的
// 真实 document id（恒为正）冲突。
private let CHANGE_PHONE_INTRO_ANIM_DOC_ID: Int64 = -9001001

@HybridComponentEntry
@Component
public class ChangePhoneIntroPage {
    @State var loaded: Bool = false
    @State var phoneDisplay: String = ""
    @State var proceedMode: String = "replace_top"
    @State var animLocalPath: String = ""

    private let mode: PrivacyIntroMode = PrivacyIntroMode.ChangePhoneNumber

    // diag-suite_settings_root-TC-0083.md round5 F1：动画沙箱路径的提取必须先于首次
    // build()——AnimatedStickerComponent 用无装饰 `var` 在 aboutToAppear() 里一次性快照
    // localPath，之后父组件状态再变也不会回灌（同类范式见 pages/UsernameSettingsPage.cj:52-68）。
    // extractIntroAnimation() 本体纯同步（readRawFileBytes + FileIo.write，无 spawn/网络），
    // 挪到这里不引入卡顿风险。ensureLoaded() 的其余职责（proceed 解析、phoneDisplay 格式化）
    // 保持原样留在 .onAppear，因为它们只喂内建组件属性，不受本缺陷影响。
    public override func aboutToAppear(): Unit {
        this.extractIntroAnimation()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 幂等守卫写法照抄 auth/PhoneInputPage.cj:154-166 takePending() 用法。proceed 字段
        // 解析失败/缺省一律回落 "replace_top"（PeerInfo 两处入口的默认语义）。
        let rawParam = takePending("ChangePhoneIntroPage")
        let parsed = JsonParser.parseObject(rawParam)
        let proceed = parsed.getString("proceed")
        if (proceed == "push") {
            this.proceedMode = "push"
        } else {
            this.proceedMode = "replace_top"
        }
        match (getAuthStorage().getUserData()) {
            case Some(userData) => this.phoneDisplay = this.formatPhoneDisplay(userData.phone)
            case None => ()
        }
    }

    // 对位 pages/EditProfilePage.cj:120-129 displayPhoneNumberFormatted() 同款格式化路径
    // （parsePhoneNumber -> 国家码+本地号成功则 formatPhoneNumber，否则回落 "+<原始号>"）。
    // 不新写格式化函数。
    private func formatPhoneDisplay(phone: String): String {
        if (phone.size == 0) { return "" }
        let parsedNumber = parsePhoneNumber("+${phone}")
        if (parsedNumber.countryCode.size > 0 && parsedNumber.nationalNumber.size > 0) {
            return formatPhoneNumber(parsedNumber.countryCode, parsedNumber.nationalNumber)
        }
        return "+${phone}"
    }

    // 把 rawfile/ChangePhoneNumber.tgs 提取到沙箱——形状照抄
    // auth/PhoneInputPage.cj:189-215 extractPhoneIllustration()（ctx 判空、mkdir 的
    // try/catch、每次覆盖写，避免升级后残留旧资源）。禁用 @rawfile() 宏：该宏生成
    // __GenerateResource__ native 符号调用，在 CJ so 加载时无法解析，导致 SIGSEGV
    // （证据注释见 auth/SplashPage.cj:284-286 同一坑）。
    private func extractIntroAnimation(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let introDir = filesDir + "/change_phone_intro"
                try { FileIo.mkdir(introDir) } catch (_e: Exception) {}
                let name = modeAnimationRawfileName(this.mode)
                let targetPath = introDir + "/" + name
                match (readRawFileBytes(name)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[ChangePhoneIntroPage] extractIntroAnimation: readRawFileBytes returned None for ${name}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.animLocalPath = "file://" + targetPath
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[ChangePhoneIntroPage] extractIntroAnimation: write failed for ${name}")
                            }
                        }
                }
        }
    }

    // proceed 语义按源侧保留二元差异（PeerInfo 两处入口 = replaceTopController；
    // 设置搜索入口 = push，SettingsSearchableItems.swift:202），由 ensureLoaded() 解析出的
    // this.proceedMode 承载，不按路由名/来源写 if 分支。
    private func onProceedClick(): Unit {
        if (this.proceedMode == "push") {
            routerPush("ChangePhonePage", "")
        } else {
            routerReplaceTop("ChangePhonePage", "")
        }
    }

    public func build() {
        Column {
            // 导航栏——源侧只有 arguments.animateIn 为真时才挂 Cancel
            // （PrivacyIntroController.swift:128-130），本链路两条入口都不传该 argument，
            // 且说明屏本身可正常交互式返回（不同于号码输入屏），故只保留默认返回入口，
            // 不加 Cancel/Close。
            Row {
                Text("‹")
                    .fontSize(36)
                    .fontColor(0x000000)
                    .width(52)
                    .height(52)
                    .borderRadius(26)
                    .backgroundColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
                    .onClick({ evt => routerPop() })

                Text(modeControllerTitle(this.mode))
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)

                Row { }.width(52)
            }
            .width(100.percent)
            .height(64.0 + getSafeAreaTop())
            .padding(left: 12, right: 12, top: getSafeAreaTop())
            .backgroundColor(0xF2F2F7)
            .alignItems(VerticalAlign.Center)

            Column {
                // 固定 180x180 容器：源侧动画区尺寸恒定，不因内容缺席而塌陷
                // （PrivacyIntroControllerNode.swift:141）。守卫与 MessageBubble.cj:1073
                // 既有调用点同构——localPath 非空才是 AnimatedStickerComponent 的调用契约
                // （组件头注释 :34「已下载的 .tgs 本地路径」）。路径为空时容器内渲染空，
                // 不放置任何 emoji/静态图/占位文案——源侧此处无兜底内容。
                Stack(alignContent: Alignment.Center) {
                    if (this.animLocalPath.size > 0) {
                        AnimatedStickerComponent(
                            documentId: CHANGE_PHONE_INTRO_ANIM_DOC_ID,
                            localPath: this.animLocalPath,
                            displaySize: 180.0
                        )
                    }
                }
                .width(180)
                .height(180)

                Text(this.phoneDisplay)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(ITEM_LIST_TEXT_SECONDARY)
                    .textAlign(TextAlign.Center)
                    .margin(top: 16)

                Text(modeText(this.mode))
                    .fontSize(14)
                    .fontColor(ITEM_LIST_TEXT_SECONDARY)
                    .textAlign(TextAlign.Center)
                    .margin(top: 16)

                Button(modeButtonTitle(this.mode))
                    .width(100.percent)
                    .height(52)
                    .borderRadius(26)
                    .backgroundColor(0xFFFFFF)
                    .fontColor(0x007AFF)
                    .fontSize(17)
                    .margin(top: 40)
                    .onClick({ evt => this.onProceedClick() })

                // notice 区：本 mode 为空串，渲染空即可，不得自造补充说明文案。
                if (modeNotice(this.mode).size > 0) {
                    Text(modeNotice(this.mode))
                        .fontSize(13)
                        .fontColor(ITEM_LIST_TEXT_SECONDARY)
                        .textAlign(TextAlign.Center)
                        .margin(top: 16)
                }
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Center)
            .padding(left: 30, right: 30, top: 40)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
