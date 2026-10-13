package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.ui_context.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.Want
import kit.CoreFileKit.*
import std.collection.ArrayList
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.*
import ohos_app_cangjie_entry.components.AnimatedStickerComponent
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}

/**
 * DevicesPage — 设备管理页面（活跃会话） (Phase J2)（混合工程迁移版）
 *
 * 功能:
 * - 显示当前账号所有活跃会话
 * - 支持终止其他设备的会话
 * - 使用 account.getAuthorizations 获取会话列表（经 PrivacyEngineService，见下）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容（内部 Stack）
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑（loadDevices）→ ensureLoaded()，根 Stack .onAppear 触发
 *  - 源页 hideTitleBar(true)，故 ArkTS 壳 hideTitleBar(true)
 *
 * TC-0134/0135/0137 round2 返修（diag-suite_settings_privacy-TC-0134-round2.md +
 * diag-suite_settings_privacy-TC-0135-0136-0137-round2.md）：
 *  - 数据层：删除私有有损解析旁路（原 parseAuthorizations + DeviceSessionItem），
 *    改走 getPrivacyEngineService().getActiveSessions()，直接持有 AuthorizationInfo
 *    （core/mtproto/TLResponses.cj）与 authorizationTtlDays，见 §6.1。
 *  - 渲染层：三段文本改绑正确字段 + 复刻源侧清洗/相对时间算法，terminate 行并入
 *    THIS DEVICE 卡、补 Learn More 脚注与 Edit 三态、修分区头宽度、删全屏 loading，见 §6.2。
 *  - 破坏性确认层收敛到单一入口 ConfirmActionOverlay（同包内 WebSessionsPage.cj 复用），见 §8.2。
 *  - 自动登出（TTL）分区：数据随 getActiveSessions() 自动到位，渲染 + 4 档菜单 + 回流，见 §8.3。
 *
 * TC-0134/0137 round3 返修（diag-suite_settings_privacy-TC-0134-round3.md +
 * diag-suite_settings_privacy-TC-0137-round3.md）：
 *  - 会话行：删多余 chevron、第 3 段单行截断、两处脚注左对齐（外包 Row+width(100%) 复刻
 *    分区头写法）、"If Inactive For" 行补 disclosure chevron、图标合成方向改为品牌色铺底
 *    +白色图形（D5 代码半，与 17 个品牌矢量资源到位与否无关）。
 *  - 导航栏：返回控件改 .glass 圆形 pill、Edit 补白色胶囊 pill（容器下沉进
 *    devices.size>1 分支，避免空 pill）。
 *  - 字面量/格式：THIS DEVICE → CURRENT SESSION（源码值，故意与当前 iOS 参照截图不一致）；
 *    短日期分隔符 "." → "/"（复刻源侧无 locale pattern 时的 fallback 分支，日/月次序、
 *    两位年、无后缀三项本已一致，locale 推导本身是平台能力缺口，不做）。
 *  - TTL 菜单：ttlMenuOverlay()（自绘全屏 overlay，含目标自造的 20% 全屏压暗）删除，改为
 *    ttlMenuContent()（仅卡片内容）+ bindPopup 直接锚定在行右值节点上；被锚行右值与新增
 *    chevron 联动 opacity 0.5/1.0（对位源侧 updateHasContextMenu，只碰这两个节点）。
 *
 * TC-0135 A8/B1 本轮返修（diag-suite_settings_privacy-TC-0135-0136-0137-round2.md §8.1 +
 * diag-suite_settings_privacy-TC-0135-B1-swipe-reveal.md §6 M-B1-a〜g，替换了 round2 §8.2
 * 第 7 条的原文修法）：
 *  - 新建 pages/RecentSessionScreen.cj（+ ets 壳 + route_map.json 条目）承载会话详情屏，
 *    当前会话行与其它会话行的 onClick 均改为 routerPush("RecentSessionScreen", ...)，
 *    原「点行→弹终止确认」语义整体删除。
 *  - 「其它设备」卡改用 List + ListItem + swipeAction(end:, onOffsetChange:) 实现左滑
 *    reveal（照抄 SettingsPage.cj 已验证形态），终止入口收敛到详情屏底部按钮与列表行左滑
 *    两处，两者共用同一个 showTerminateConfirm/ConfirmActionOverlay 入口。
 *  - 三段文本格式化函数（deviceIconTint/cleanAppVersion/trimmedLocation/activityLabel 等）
 *    从 DevicesPage 私有方法提升为包级顶层函数，供 RecentSessionScreen.cj 复用同一套口径
 *    （不得另写一份格式化）。
 *
 * TC-0134 round6 返修（diag-suite_settings_privacy-TC-0134-round6.md，推翻此前"资源前置、
 * 非返修单"的分类——hmos-resources-convert 批量前置只对 Android 生效，generic_ios 项目
 * 的资源转换向来由各 feature Worker 逐件完成）：
 *  - B1：rawfile/Devices.tgs 原样拷贝（与 rawfile/ChangePhoneNumber.tgs 同惯例，md5 校验
 *    与源一致）；header 从静态 set2_ic_devices 换成 AnimatedStickerComponent 播放
 *    （extractDevicesAnimation() 照抄 ChangePhoneIntroPage.cj:123-148 的沙箱提取形状；
 *    组件新增 playOnce/startDelayMs 两个参数，playOnce=true + startDelayMs=300 对位源侧
 *    playbackMode:.still(.start) + Queue.mainQueue().after(0.3)）。
 *  - D5：16 个 devices_ic_* 品牌矢量（8 件白色字形 A 类 + 8 件已合成整块 B 类）已转入
 *    资源树，deviceIconAsset()/deviceIconIsWhiteGlyph() 按 iconForSession 分支表选形状——
 *    A 类沿用品牌色铺底 + 内图铺满 30vp（此前 20vp 是错的），B 类整块铺满 30vp、不叠底色/
 *    fillColor（PDF 自带品牌色背景路径）。Edge.imageset 不转（源侧此屏死资产）。
 *  - Diff⑦：terminate 行首补 devices_ic_terminate（源 Item List/Block.imageset/Icon-2.pdf
 *    红色举手图标，不是灰色 stop.pdf），fillColor 运行时染红；文本随之从 32vp 挪到 74vp
 *    （与同卡当前会话行标题同一左内缩公式）。
 *
 * 已知限制（本轮明确不做，逐条见交付报告）：
 *  - A8 详情屏的「Accept on This Device」开关分区（case A6）：需要 AuthorizationInfo 新增
 *    apiId/passwordPending/encryptedRequestsDisabled/callRequestsDisabled 四个字段，只能
 *    从 core/mtproto/TLResponses.cj 补齐解析——该文件不在本 feature 当前 allowlist 内，
 *    本轮不新增/不越界改动，开关分区整段不渲染（非渲染错误值，是整块未装配）。
 *  - A8 顶部设备 Lottie 动画（RecentSessionScreen.cj 内，非本文件）：本轮只处理
 *    DevicesPage.cj 的 header 动画（B1），RecentSessionScreen 的对应动画不在本次
 *    round6 授权范围内，未改动。
 */

// ==================== 包级共享格式化函数 ====================
// TC-0135 A8（diag-suite_settings_privacy-TC-0135-0136-0137-round2.md §8.1 item2）：
// 「取值来源与 TC-0134-round2 §6.1 第 3 条的三段文本口径保持同一套函数，不得另写一份
// 格式化」——原为 DevicesPage 的 private 实例方法，本轮提升为包级顶层函数（无修饰符，
// Cangjie 默认可见性=包内可见，同包 pages/RecentSessionScreen.cj 直接调用，不 import、
// 不重写）。纯函数，不读任何 @State，行为与迁移前逐字相同。

// 会话行图标品牌色，判别输入与分支顺序照抄源侧 iconForSession(_:)
// （ItemListRecentSessionItem.swift:118-169），按 platform/deviceModel/
// systemVersion 三个字段依次匹配。TC-0134-round6 D5：品牌专属矢量已转入目标资源树
// （见下方 deviceIconAsset/deviceIconIsWhiteGlyph），本函数继续只负责品牌色这一半
// （A 类底色 + B 类不消费），与源侧同口径，本体不因图形接线而改动。
func deviceIconTint(platform: String, deviceModel: String, systemVersion: String): Int64 {
    let device = deviceModel.toAsciiLower()
    let plat = platform.toAsciiLower()
    let sysVer = systemVersion.toAsciiLower()

    if (device.contains("xbox")) { return 0xFF35C759 }
    if (device.contains("chrome") && !device.contains("chromebook")) { return 0xFF35C759 }
    if (device.contains("brave")) { return 0xFFFF9500 }
    if (device.contains("vivaldi")) { return 0xFFFF3C30 }
    if (device.contains("safari")) { return 0xFF0079FF }
    if (device.contains("firefox")) { return 0xFFFF9500 }
    if (device.contains("opera")) { return 0xFFFF3C30 }
    if (plat.contains("android")) { return 0xFF35C759 }
    if (device.contains("iphone")) { return 0xFF0079FF }
    if (device.contains("ipad")) { return 0xFF0079FF }
    if ((plat.contains("macos") || sysVer.contains("macos")) && device.contains("mac")) { return 0xFF0079FF }
    if (plat.contains("ios") || plat.contains("macos") || sysVer.contains("macos")) { return 0xFF0079FF }
    if (plat.contains("ubuntu") || sysVer.contains("ubuntu")) { return 0xFFFF9500 }
    if (plat.contains("linux") || sysVer.contains("linux")) { return 0xFF8E8E93 }
    if (plat.contains("windows") || sysVer.contains("windows")) { return 0xFF0079FF }
    return 0xFF8E8E93
}

// TC-0134-round6 D5（diag-suite_settings_privacy-TC-0134-round6.md §6.3）：会话行左侧
// 品牌矢量资源，按 iconForSession(_:) 分支选（ItemListRecentSessionItem.swift:118-169）。
// 分支判别输入与顺序逐条照抄上面的 deviceIconTint()，一条不增不减、不改顺序——两函数
// 只是同一份分支表的两个不同输出（色 vs 形），不得让它们的判别逻辑分叉。
// Image(<AppResource 返回函数调用>) 是本工程已验证先例（app/TelegramNavBar.cj:139/152/187
// navCloseIconRes()/navBackArrowGlassRes()），故用函数返回值而非把 @r() 塞进值级
// if/else 表达式分支（dev_pattern.md D-133 明令禁止后者，未见先例、置信度不足）。
func deviceIconAsset(platform: String, deviceModel: String, systemVersion: String): AppResource {
    let device = deviceModel.toAsciiLower()
    let plat = platform.toAsciiLower()
    let sysVer = systemVersion.toAsciiLower()

    if (device.contains("xbox")) { return @r(app.media.devices_ic_xbox) }
    if (device.contains("chrome") && !device.contains("chromebook")) { return @r(app.media.devices_ic_chrome) }
    if (device.contains("brave")) { return @r(app.media.devices_ic_brave) }
    if (device.contains("vivaldi")) { return @r(app.media.devices_ic_vivaldi) }
    if (device.contains("safari")) { return @r(app.media.devices_ic_safari) }
    if (device.contains("firefox")) { return @r(app.media.devices_ic_firefox) }
    if (device.contains("opera")) { return @r(app.media.devices_ic_opera) }
    if (plat.contains("android")) { return @r(app.media.devices_ic_android) }
    if (device.contains("iphone")) { return @r(app.media.devices_ic_iphone) }
    if (device.contains("ipad")) { return @r(app.media.devices_ic_ipad) }
    if ((plat.contains("macos") || sysVer.contains("macos")) && device.contains("mac")) { return @r(app.media.devices_ic_mac) }
    if (plat.contains("ios") || plat.contains("macos") || sysVer.contains("macos")) { return @r(app.media.devices_ic_ios) }
    if (plat.contains("ubuntu") || sysVer.contains("ubuntu")) { return @r(app.media.devices_ic_ubuntu) }
    if (plat.contains("linux") || sysVer.contains("linux")) { return @r(app.media.devices_ic_linux) }
    if (plat.contains("windows") || sysVer.contains("windows")) { return @r(app.media.devices_ic_windows) }
    return @r(app.media.devices_ic_generic)
}

// A 类（8 件白色字形，30pt 画布，源侧 renderSettingsIcon 铺底+mask 填白）判定；B 类
// （8 件已合成整块，72pt 画布，源侧 UIImage(bundleImageName:)/renderAttachAppIcon 原样
// 画满）反之。判别输入与分支顺序与 deviceIconAsset 完全一致（同一份分支表）。
func deviceIconIsWhiteGlyph(platform: String, deviceModel: String, systemVersion: String): Bool {
    let device = deviceModel.toAsciiLower()
    let plat = platform.toAsciiLower()
    let sysVer = systemVersion.toAsciiLower()

    if (device.contains("xbox")) { return false }
    if (device.contains("chrome") && !device.contains("chromebook")) { return true }
    if (device.contains("brave")) { return false }
    if (device.contains("vivaldi")) { return false }
    if (device.contains("safari")) { return false }
    if (device.contains("firefox")) { return false }
    if (device.contains("opera")) { return false }
    if (plat.contains("android")) { return true }
    if (device.contains("iphone")) { return true }
    if (device.contains("ipad")) { return true }
    if ((plat.contains("macos") || sysVer.contains("macos")) && device.contains("mac")) { return true }
    if (plat.contains("ios") || plat.contains("macos") || sysVer.contains("macos")) { return false }
    if (plat.contains("ubuntu") || sysVer.contains("ubuntu")) { return true }
    if (plat.contains("linux") || sysVer.contains("linux")) { return true }
    if (plat.contains("windows") || sysVer.contains("windows")) { return true }
    return false
}

// TC-0134 §6.1 item3：第 2 段应用名+版本清洗，逐步复刻
// ItemListRecentSessionItem.swift:298-301：① 删除全部 "APPSTORE" 子串；
// ② "BETA" → "Beta"；③ 去首尾空白；④ 若同时存在 " (" 与 ")"，删除从
// " (" 起到第一个 ")" 止（含两端）的整段。
func cleanAppVersion(raw: String): String {
    var v = raw.replace("APPSTORE", "")
    v = v.replace("BETA", "Beta")
    v = v.trimAscii()
    match (v.indexOf(" (")) {
        case Some(openIdx) =>
            let tail = v[openIdx..]
            match (tail.indexOf(")")) {
                case Some(relCloseIdx) =>
                    let closeIdx = openIdx + relCloseIdx
                    v = v[..openIdx] + v[(closeIdx + 1)..]
                case None => ()
            }
        case None => ()
    }
    return v
}

// TC-0134 §6.1 item3：第 3 段地点清洗，复刻 trimmedLocationName（源 :171-175）——
// 只替换 "United Arab Emirates" → "UAE"，其余原样。
func trimmedLocation(country: String): String {
    return country.replace("United Arab Emirates", "UAE")
}

func formatCountUnit(n: Int64, unit: String): String {
    if (n == 1) { return "1 " + unit }
    return "${n} " + unit + "s"
}

func localDateTimeOf(unixSec: Int64): DateTime {
    return DateTime.fromUnixTimeStamp(Duration.second * unixSec).inLocal()
}

func localDayIndexOf2(unixSec: Int64): Int64 {
    let dt = localDateTimeOf(unixSec)
    let offsetSec = dt.zoneOffset.toSeconds()
    let localWallSec = unixSec + offsetSec
    if (localWallSec >= 0) {
        return localWallSec / 86400
    }
    return (localWallSec - 86399) / 86400
}

func pad2i(v: Int64): String {
    if (v < 10) { return "0${v}" }
    return "${v}"
}

// "dd/MM/yy" 短日期，对位源侧 stringForTimestamp(day:month:year:) 的 Time_AtDate 分支。
// TC-0134-round3 §3.8：源侧四项（分隔符/次序/后缀/是否四位年）全部由系统 locale 经
// DateFormatter.dateFormat(fromTemplate:"MdY", locale:) 推导（PresenceStrings.swift:6-16 +
// PresentationData.swift:171-198）；仓颉 ohos.i18n.System 只有 getAppPreferredLanguage()
// 一个静态方法，无 region/CLDR pattern 入口，自建地区→格式表属未复刻的特判表，不做
// （平台能力缺口，已登记）。这里只复刻源侧在**取不到 locale pattern 时**自己走的
// fallback 分支（PresentationData.swift:172 dateSeparator="/" + :194 .dayFirst +
// 无后缀 + 两位年）：次序/后缀/两位年三项本已与该分支一致，只有分隔符原来错写成"."。
func shortDateDotted(unixSec: Int64): String {
    let dt = localDateTimeOf(unixSec)
    let yy = dt.year % 100
    return "${pad2i(dt.dayOfMonth)}/${pad2i(dt.month.toInteger())}/${pad2i(yy)}"
}

func hhmmOf(unixSec: Int64): String {
    let dt = localDateTimeOf(unixSec)
    return "${pad2i(dt.hour)}:${pad2i(dt.minute)}"
}

// TC-0134 §6.1 item4（白盒判定项，D4.4）：复刻 PresenceStrings.swift:487-524
// stringForRelativeActivityTimestamp 的分档语义——<60s "just now"；<3600s
// "N minute(s) ago"；跨年 → 短日期；同一本地日 → "N hour(s) ago"；昨天 →
// "yesterday at HH:mm"；其余 → 短日期。
func relativeActivityString(dateActive: Int32, now: Int32): String {
    let dateActiveSec = Int64(dateActive)
    let nowSec = Int64(now)
    let difference = nowSec - dateActiveSec
    if (difference < 60) { return "just now" }
    if (difference < 3600) {
        let n = difference / 60
        return formatCountUnit(n, "minute") + " ago"
    }
    let activeYear = localDateTimeOf(dateActiveSec).year
    let nowYear = localDateTimeOf(nowSec).year
    if (activeYear != nowYear) {
        return shortDateDotted(dateActiveSec)
    }
    let dayDiff = localDayIndexOf2(dateActiveSec) - localDayIndexOf2(nowSec)
    if (dayDiff == 0) {
        let n = difference / 3600
        return formatCountUnit(n, "hour") + " ago"
    }
    if (dayDiff == -1) {
        return "yesterday at " + hhmmOf(dateActiveSec)
    }
    return shortDateDotted(dateActiveSec)
}

func activityLabel(device: AuthorizationInfo): String {
    if (device.isCurrent) { return "online" }
    let nowSec = Int32(DateTime.now().toUnixTimeStamp().toSeconds())
    return relativeActivityString(device.dateActive, nowSec)
}

// TC-0134-round6 B1（diag-suite_settings_privacy-TC-0134-round6.md §6.4）：
// documentId 是 AnimatedStickerComponent 的帧缓存 key，固定负常量，与
// pages/ChangePhoneIntroPage.cj:65 的 CHANGE_PHONE_INTRO_ANIM_DOC_ID（-9001001）
// 不同值，避免帧缓存 key 撞车。
private let DEVICES_HEADER_ANIM_DOC_ID: Int64 = -9002001

// TC-0134：会话行第 3 段的分隔符。字符串与源侧 ItemListRecentSessionItem.swift:326
// 逐字节一致，不改内容；只在渲染侧补偿字体步进（见 fitActivityLabel 注释）。
let SESSION_SEP: String = " • "
// 分隔符总步进补偿：U+2022 在 HarmonyOS Sans 是 1.000 em、在源侧 SF Pro 是
// 0.4287 em，fontSize 15 下差 (1.0-0.4287)*15 = 8.571vp。
let SESSION_SEP_TRACKING_TOTAL: Float64 = -8.571
// 补偿的分配：ArkUI 的 letterSpacing 只削「字符后面的步进」，不重排字形本身，
// 所以不能把 8.571 全削在圆点上——HarmonyOS Sans 的 U+2022 字身宽 3.71vp、
// 左右 side bearing 各约 5.65vp，削超过右 bearing 就会让圆点压到后一个词上
// （已实测：全削在圆点上时圆点紧贴 label）。按「两侧墨迹间距保持均衡」分配：
//   前导空格步进归零（4.05 → 0），余下 4.521 由圆点与后随空格平摊。
let SEP_TRACK_LEAD: Float64 = -4.05
let SEP_TRACK_DOT: Float64 = -2.26
let SEP_TRACK_TRAIL: Float64 = -2.261

@HybridComponentEntry
@Component
public class DevicesPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var devices: ArrayList<AuthorizationInfo> = ArrayList<AuthorizationInfo>()
    @State var ttlDays: Int32 = 0
    @State var isLoading: Bool = true
    @State var showTerminateConfirm: Bool = false
    @State var terminateHash: Int64 = 0
    @State var showTerminateAllConfirm: Bool = false
    @State var terminatingAllOther: Bool = false
    @State var editingSessions: Bool = false
    @State var showTtlMenu: Bool = false
    @State var loaded: Bool = false
    // TC-0135 B1（diag-...-B1-swipe-reveal.md §6 M-B1-e）：swipeAction(end:) 面板行身份
    // 镜像，唯一写入点是 onOffsetChange（带 offset != 0.0 守卫），end: 闭包体内禁止赋值。
    @State var swipeRowSessionHash: Int64 = 0
    // TC-0134-round6 B1：header Lottie 沙箱路径，见 extractDevicesAnimation()。
    @State var animLocalPath: String = ""
    // TC-0134 dynattr：会话行第 3 段的实际可用宽度（vp）。源侧同一个量是
    // ItemListRecentSessionItem.swift:343 算出来的 constrainedSize.width
    // （含 editingOffset 项）；目标侧由 layoutWeight(1) 决定，用 onAreaChange 取实测值。
    // **必须两段各存一份**：编辑态下 ACTIVE SESSIONS 行整体右移让出删除控件，
    // 其可用宽度（实测 241.1vp）与不可编辑的当前会话行（恒 279.1vp）不同；
    // 共用一个 @State 会被后渲染的列表行覆盖，把当前会话行按窄盒截断。
    @State var currentSessionTextBoxVp: Float64 = 0.0
    @State var listSessionTextBoxVp: Float64 = 0.0
    // TC-0541 C4：系统 Dark All day 后本页仍画 Day 字面量。订一份 snapshot
    //（禁止第二份），build() 内读 this.presentation.* 才能热切刷新（D-125）。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // TC-0134-round6 B1（diag-suite_settings_privacy-TC-0134-round6.md §6.4）：动画沙箱
    // 路径提取必须先于首次 build()——AnimatedStickerComponent 用无装饰 `var` 在
    // aboutToAppear() 里一次性快照 localPath，之后父组件状态再变也不会回灌（同类范式见
    // pages/ChangePhoneIntroPage.cj:83-85）。extractDevicesAnimation() 本体纯同步
    // （readRawFileBytes + FileIo.write，无 spawn/网络），不引入卡顿风险。
    public override func aboutToAppear(): Unit {
        this.extractDevicesAnimation()
    }

    // 把 rawfile/Devices.tgs 提取到沙箱——形状照抄
    // pages/ChangePhoneIntroPage.cj:123-148 extractIntroAnimation()（ctx 判空、
    // mkdir 的 try/catch、每次覆盖写，避免升级后残留旧资源）。禁用 @rawfile() 宏：
    // 该宏生成 __GenerateResource__ native 符号调用，在 CJ so 加载时无法解析，导致
    // SIGSEGV（证据注释见 ChangePhoneIntroPage.cj:120-122 与 auth/SplashPage.cj:284-286）。
    private func extractDevicesAnimation(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let animDir = filesDir + "/devices_header_anim"
                try { FileIo.mkdir(animDir) } catch (_e: Exception) {}
                let name = "Devices.tgs"
                let targetPath = animDir + "/" + name
                match (readRawFileBytes(name)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[DevicesPage] extractDevicesAnimation: readRawFileBytes returned None for ${name}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.animLocalPath = "file://" + targetPath
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[DevicesPage] extractDevicesAnimation: write failed for ${name}")
                            }
                        }
                }
        }
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadDevices()
    }

    // ======== TC-0134 会话行第 3 段：分隔符步进补偿 + 字符级收尾 ========
    // 源侧 ItemListRecentSessionItem.swift:326 把第 3 段写成单串
    // "\(trimmedLocationName) • \(label)"，:341-343 用单次 TextNode.asyncLayout 做
    // maximumNumberOfLines:1 + truncationType:.end。目标侧要补两处平台缺口：
    //  (a) HarmonyOS Sans 的 U+2022 advance = 1.000 em，源侧 SF Pro = 0.4287 em，
    //      fontSize 15 下多吃 (1.0-0.4287)*15 = 8.57vp。Text/TextAttribute 不公开
    //      letterSpacing，Span 公开 → 把 " • " 拆成独立 Span 做步进补偿，
    //      字符串本身与源侧逐字节保持一致。
    //  (b) ArkUI 默认 WordBreak.Normal 是词级收尾（整词丢弃），Text 不公开
    //      wordBreak/ellipsisMode → 按源侧 .end 的同一算法（最长可容前缀 + 省略号）
    //      用 MeasureUtils.measureText 自行收尾。
    private func measure15(mu: MeasureUtils, t: String): Float64 {
        mu.measureText(MeasureOptions(textContent: t, fontSize: 15.0.vp))
    }

    // 预算（px）与分隔符实际步进（px）。分隔符步进 = 裸串宽 + 总 tracking 补偿。
    private func thirdLineBudgetPx(boxVp: Float64): Float64 {
        match (this.getUIContext().vp2px(boxVp.vp)) {
            case Some(v) => v.value
            case None => 0.0
        }
    }

    private func thirdLineSepPx(mu: MeasureUtils): Float64 {
        let track: Float64 = match (this.getUIContext().vp2px(SESSION_SEP_TRACKING_TOTAL.vp)) {
            case Some(v) => v.value
            case None => 0.0
        }
        this.measure15(mu, SESSION_SEP) + track
    }

    // 分隔符与活跃标签是否还能上屏。源侧 .end 是对整串收尾：当 location + 分隔符 +
    // 省略号本身都放不下时，收尾会吃进 location，分隔符与标签一并消失。
    func thirdLineKeepsSeparator(loc: String, boxVp: Float64): Bool {
        if (boxVp <= 0.0) { return true }
        let mu = this.getUIContext().getMeasureUtils()
        let budget = this.thirdLineBudgetPx(boxVp)
        if (budget <= 0.0) { return true }
        this.measure15(mu, loc) + this.thirdLineSepPx(mu) + this.measure15(mu, "\u{2026}") <= budget
    }

    // 源侧 truncationType:.end 的同一算法：保留最长可容前缀，尾部换成省略号。
    // 整串放得下时原样返回 lab（不加省略号）。
    func fitActivityLabel(loc: String, lab: String, boxVp: Float64): String {
        if (boxVp <= 0.0) { return lab }
        let mu = this.getUIContext().getMeasureUtils()
        let budget = this.thirdLineBudgetPx(boxVp)
        if (budget <= 0.0) { return lab }
        let headW = this.measure15(mu, loc) + this.thirdLineSepPx(mu)
        if (headW + this.measure15(mu, lab) <= budget) { return lab }
        return this.longestPrefixWithEllipsis(mu, lab, budget - headW)
    }

    // location 自身也放不下时，对 location 做同一套 .end 收尾。
    func fitLocationOnly(loc: String, boxVp: Float64): String {
        if (boxVp <= 0.0) { return loc }
        let mu = this.getUIContext().getMeasureUtils()
        let budget = this.thirdLineBudgetPx(boxVp)
        if (budget <= 0.0) { return loc }
        return this.longestPrefixWithEllipsis(mu, loc, budget)
    }

    // 二分找出「前缀 + 省略号」仍不超过 room 的最长前缀。room <= 省略号宽时返回省略号本身
    // （与 CoreText 一致：收尾标记优先于内容）。
    private func longestPrefixWithEllipsis(mu: MeasureUtils, text: String, room: Float64): String {
        let ell = "\u{2026}"
        let runes = text.toRuneArray()
        var lo: Int64 = 0
        var hi: Int64 = runes.size
        var best: Int64 = 0
        while (lo <= hi) {
            let mid = (lo + hi) / 2
            var cand = ""
            var i: Int64 = 0
            while (i < mid) { cand += runes[i].toString(); i++ }
            cand += ell
            if (this.measure15(mu, cand) <= room) {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        var out = ""
        var k: Int64 = 0
        while (k < best) { out += runes[k].toString(); k++ }
        out + ell
    }

    // TC-0134 §6.1 item1/2：删除私有有损旁路（原 parseAuthorizations 绕开引擎层，丢
    // authorization_ttl_days/app_version/date_active，硬截断 20 条），改走服务层，
    // 拿到的 AuthorizationInfo 保留全部字段、无条数上限（TLResponses.cj 全量解析）。
    func loadDevices(): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            var parsedDevices: ArrayList<AuthorizationInfo> = ArrayList<AuthorizationInfo>()
            var parsedTtlDays: Int32 = 0
            try {
                let resp = svc.getActiveSessions()
                parsedDevices = resp.sessions
                parsedTtlDays = resp.authorizationTtlDays
                Hilog.info(0, "CjTelegram", "Devices loaded")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "Devices load error")
            }
            let devs = parsedDevices
            let ttl = parsedTtlDays
            launch {
                this.devices = devs
                this.ttlDays = ttl
                this.isLoading = false
            }
        }
    }

    func terminateSession(hash: Int64): Unit {
        let _ = spawn {
            var newList: ArrayList<AuthorizationInfo> = ArrayList<AuthorizationInfo>()
            var success = false
            try {
                let client = getMTProtoClient()
                let req = AccountResetAuthorization()
                req.hash = hash
                let _ = client.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "Session terminated")
                for (d in this.devices) {
                    if (d.hash != hash) {
                        newList.add(d)
                    }
                }
                success = true
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "Terminate session error")
            }
            let ok = success
            let devList = newList
            launch {
                if (ok) { this.devices = devList }
                this.showTerminateConfirm = false
            }
        }
    }

    // TC-0135 §3.4/§8.2：实际终止逻辑不变，`if (!d.isCurrent)` 逐设备守卫原样保留。
    // 触发方只能来自 ConfirmActionOverlay 的破坏性回调（见 build() 内 showTerminateAllConfirm
    // 分支），调用前已弹二次确认——这是已落地的安全修复，不移除/不绕过。
    func terminateAllOther(): Unit {
        let _ = spawn {
            var newList: ArrayList<AuthorizationInfo> = ArrayList<AuthorizationInfo>()
            try {
                let client = getMTProtoClient()
                for (d in this.devices) {
                    if (!d.isCurrent) {
                        let req = AccountResetAuthorization()
                        req.hash = d.hash
                        let _ = client.sendRequest(req.toBytes())
                    }
                }
                for (d in this.devices) {
                    if (d.isCurrent) {
                        newList.add(d)
                    }
                }
                Hilog.info(0, "CjTelegram", "All other sessions terminated")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "Terminate all error")
            }
            let list = newList
            launch {
                this.devices = list
                this.terminatingAllOther = false
            }
        }
    }

    // TC-0137 §8.3 item12：选中某档 TTL → 已存在的 setSessionTtlDays(days)，成功后行右值
    // 更新为新档位；失败保持旧值；无成功/失败 toast（对位源侧 :913-915 的静默语义）。
    // 菜单本身在点击项时就同步关闭（不等 RPC），行右值只在 RPC 成功后回填。
    private func selectTtl(days: Int32): Unit {
        this.showTtlMenu = false
        let _ = spawn {
            let svc = getPrivacyEngineService()
            var ok = false
            try {
                ok = svc.setSessionTtlDays(days)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[DevicesPage] setSessionTtlDays error")
            }
            let success = ok
            let newDays = days
            launch {
                if (success) { this.ttlDays = newDays }
            }
        }
    }

    // 头部三件套之一：整宽 QR 按钮 → 过相机权限门后打开二维码扫描页做 Auth-Transfer 登录
    // 源侧 RecentSessionsController.swift:896-908 addDevice() 先 DeviceAccess.authorizeAccess(
    // to: .camera(.qrCode))，guard granted 之后才 push QrCodeScanScreen(subject:.authTransfer(...))；
    // QrScannerPage.cj 已实现同一扫码解码通路（tg://login?token=... → importLoginToken），
    // 直接复用，不新建能力。
    // TC-0134-round9 F-2（diag-suite_settings_privacy-TC-0134-round9.md §6.2）：此前本方法
    // 只有一行 routerPush，整条相机权限门在代码里根本不存在——权限未授予时用户被直接推进
    // 一个开不了相机的死屏（源侧此时停在本屏弹 alert，从不 push）。门放在调用方与源侧一致：
    // QrCodeScanScreen.swift 自身零 DeviceAccess 检查，故本轮也不往 QrScannerPage.cj 加检查。
    // 消费既有统一引擎 services/DeviceAccessService.cj（对位源侧 DeviceAccess.swift），
    // 不在本页手写第二份 AbilityAccessCtrl 逻辑。
    // 源侧两条未授权路径（.notDetermined 弹系统窗、拒绝后 alert；.denied/.restricted 直接
    // alert）在鸿蒙侧汇到同一个 requestPermissionsFromUser：已永久拒绝时它不弹窗、立即回
    // granted=false，与源侧"两条路径弹同一个 alert"逐条同构，故此处不分叉。
    private func openAddDevice(): Unit {
        let svc = getDeviceAccessService()
        match (svc.checkAccess(DeviceAccessType.Camera)) {
            case DeviceAccessStatus.Authorized =>
                // 源侧 .authorized ⇒ completion(true) ⇒ push，行为与本轮之前逐字相同
                routerPush("QrScannerPage", "authTransfer")
            case _ =>
                svc.requestAccess(DeviceAccessType.Camera, { granted: Bool =>
                    launch {
                        if (granted) {
                            routerPush("QrScannerPage", "authTransfer")
                        } else {
                            // 源侧 guard granted else { return }：不 push，只弹兜底 alert
                            this.showCameraAccessDeniedAlert()
                        }
                    }
                })
        }
    }

    // TC-0134-round9 F-2 兜底层：逐条对位源侧 DeviceAccess.swift:318-372 camera 分支的
    // standardTextAlertController——
    //   title   = AccessDenied.Title      （Telegram/Telegram-iOS/en.lproj/Localizable.strings:1265）
    //   message = AccessDenied.QrCamera   （同文件 :7326，取源码值而非参照截图的渲染值）
    //   左键    = Common.NotNow           （同文件 :2526），action 体为空——关掉之后什么都不
    //             发生：不 push 扫描屏、无第二个提示、不改任何状态
    //   右键    = AccessDenied.Settings   （同文件 :1294）→ 源侧 openSettings()，目标对位件
    //             DeviceAccessService.openSystemSettings()
    // 按钮次序（Not Now 左、Settings 右）照 DeviceAccess.swift:341 的 actions 数组；源侧未传
    // actionLayout: .vertical ⇒ 两按钮走默认横向，故 DialogButtonDirection.Horizontal。
    // textStyle 同 pages/DataStorageSettingsPage.cj:678 已验证形态（缺省时平台按字符断行会
    // 在词中折断）。
    private func showCameraAccessDeniedAlert(): Unit {
        let uiCtx = this.getUIContext()
        let notNowBtn = AlertDialogButtonOptions(value: "Not Now", action: { => () })
        let settingsBtn = AlertDialogButtonOptions(
            value: "Settings",
            action: { => getDeviceAccessService().openSystemSettings() }
        )
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            title: "Please Allow Access",
            message: "Telegram needs access to your camera to scan QR codes.\n\nOpen your device's Settings > Privacy > Camera and set Telegram to ON.",
            autoCancel: true,
            buttons: [notNowBtn, settingsBtn],
            buttonDirection: DialogButtonDirection.Horizontal,
            textStyle: WordBreak.BreakWord
        ))
    }

    // 头部说明句里的两个链接，源侧 openDesktopLink/openWebLink
    // （RecentSessionsController.swift:948-951），均 forceExternal 用系统外部浏览器打开
    private func openDesktopLink(): Unit {
        this.openExternalUrl("https://getdesktop.telegram.org")
    }

    private func openWebLink(): Unit {
        this.openExternalUrl("https://web.telegram.org")
    }

    // TC-0134 §6.2 item9：底部 Learn More 脚注链接，源侧 devicesInfo(AuthSessions_OtherDevices)
    // 的 linkAction → openOtherAppsUrl() → https://telegram.org/apps。
    private func openLearnMore(): Unit {
        this.openExternalUrl("https://telegram.org/apps")
    }

    private func openExternalUrl(url: String): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let want = Want(action: "ohos.want.action.viewData", uri: url)
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[DevicesPage] Opened URL: ${url}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[DevicesPage] openExternalUrl failed")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[DevicesPage] No context for openExternalUrl")
        }
    }

    // TC-0137 §4.4/§8.3 item10（白盒判定项）：复刻 NumericFormat.swift:86-121
    // timeIntervalString(usage:.generic, preferLowerValue:false) 对本屏用到的四档
    // （7/30/90/180 天）的分档口径——按秒数分别落进 week/month/year 三个桶。
    // 禁止照抄 PrivacySettingsPage.cj:ttlLabel()（另一 feature 的账号自毁阈值表，
    // 分档与大小写口径均不同）。
    private func sessionTtlLabel(days: Int32): String {
        let seconds = Int64(days) * 86400
        if (seconds < 60 * 60 * 24 * 30) {
            let weeks = seconds / (60 * 60 * 24 * 7)
            return formatCountUnit(weeks, "week")
        }
        if (seconds < 60 * 60 * 24 * 365) {
            let months = seconds / (60 * 60 * 24 * 30)
            return formatCountUnit(months, "month")
        }
        let years = seconds / (60 * 60 * 24 * 365)
        return formatCountUnit(years, "year")
    }

    // TC-0135 B1（diag-...-B1-swipe-reveal.md §6 M-B1-b）：「其它设备」预过滤 + 保序，
    // 供下方 List{ForEach} 使用；「本设备」卡片不进这个 List、不挂 swipeAction。
    private func otherDevices(): Array<AuthorizationInfo> {
        let result = ArrayList<AuthorizationInfo>()
        for (d in this.devices) {
            if (!d.isCurrent) {
                result.add(d)
            }
        }
        return result.toArray()
    }

    // TC-0135 A8（diag-...-round2.md §8.1 item3）：会话行 push 详情屏的路由参数，
    // 字段口径与下方顶层 RecentSessionScreen.parseRouteParam 一一对应。
    private func sessionRouteParam(device: AuthorizationInfo): String {
        let cur = if (device.isCurrent) { "1" } else { "0" }
        // S7-133: + apiId | passwordPending | encryptedRequestsDisabled | callRequestsDisabled
        // (the "Accept on This Device" toggles on RecentSessionScreen).
        let pp = if (device.passwordPending) { "1" } else { "0" }
        let enc = if (device.encryptedRequestsDisabled) { "1" } else { "0" }
        let call = if (device.callRequestsDisabled) { "1" } else { "0" }
        return "${device.hash}|${cur}|${device.deviceModel}|${device.platform}|${device.systemVersion}|${device.appName}|${device.appVersion}|${device.country}|${device.dateActive}|${device.apiId}|${pp}|${enc}|${call}"
    }

    // TC-0134-round3 Diff②：Edit 补白色胶囊 pill。容器下沉进 `devices.size > 1` 分支内层
    // （而非留在 build() 侧包一层），避免 devices.size <= 1 时本函数不产节点、pill 塌成一个
    // 44 高的空白胶囊——源侧此时右上角本就没有任何按钮节点。三态逻辑（spinner/勾/Edit 文案）
    // 一字不动，本条只补容器：高恒 44、宽随内容自适应、圆角 22（对位
    // NavigationBarImpl.swift:1019/1034：高 44、宽 = rightButtonsWidth、圆角 = 44*0.5）。
    @Builder
    private func editButtonContent() {
        if (this.devices.size > 1) {
            Row {
                if (this.terminatingAllOther) {
                    LoadingProgress().width(20).height(20)
                } else if (this.editingSessions) {
                    Image(@r(app.media.media_ic_check))
                        .width(20)
                        .height(20)
                        .fillColor(0x0088CC)
                        .onClick({ evt => this.editingSessions = false })
                } else {
                    Text(trSource("Edit"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.presentation.textColor)
                        .onClick({ evt => this.editingSessions = true })
                }
            }
            .height(44)
            .padding(left: 14, right: 14)
            .borderRadius(22)
            .backgroundColor(this.presentation.cardColor)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
        }
    }

    // TC-0137-round3 §6.1：4 档菜单改为 bindPopup 锚定在行右值节点上（对位源侧
    // .reference(sourceView: sourceNode.labelNode.view)）。本 @Builder 只产出菜单
    // **卡片内容**——不含全屏容器、不含压暗、不含居中；§2.2 逐像素比对已证源侧此菜单
    // 呈现下页面零施加压暗/模糊，全屏遮罩层是目标此前自造的视觉层，随旧 ttlMenuOverlay()
    // 一并删除。形状出处：components/AnimatedEmojiComponent.cj:414-427（已验证的同款
    // 受控 @State 布尔 + bind(builder, this) + popupColor: Color.Transparent +
    // enableArrow: false + autoCancel: true + onStateChange 回写状态）；不用
    // bindMenu/bindContextMenu——前者本工程无已验证先例（components/ImageViewer.cj:96
    // 同注记），后者是 LongPress 语义，与本处单击不符。
    // 图标列恒预留：当前值项显示对勾矢量，非当前值项用 opacity(0.0) 占位而非省略节点，
    // 避免非当前项文字左移。
    @Builder
    private func ttlMenuContent() {
        Column {
            ForEach([Int32(7), Int32(30), Int32(90), Int32(180)], itemGenerator: { days: Int32, idx: Int64 =>
                Column {
                    Row {
                        Image(@r(app.media.media_ic_check))
                            .width(18)
                            .height(18)
                            .fillColor(0x0088CC)
                            .opacity(if (days == this.ttlDays) { 1.0 } else { 0.0 })
                            .margin(right: 10)
                        Text(this.sessionTtlLabel(days))
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ evt => this.selectTtl(days) })

                    if (idx < 3) {
                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 16)
                    }
                }
            })
        }
        .width(240)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(14)
    }

    // TC-0135 B1 M-B1-d/e（diag-...-B1-swipe-reveal.md §6）：swipeAction(end:) 引用的
    // 无参 @Builder 成员函数（D-115 合规：无参数，体内只读裸 this. 字段——本函数只读
    // this.swipeRowSessionHash，不读 ForEach 闭包捕获的 device，规避 D-125）。
    // onClick 打开 round2 §8.2 item5 抽出的共享确认入口——把 terminateHash 指向当前展开
    // 行，复用 build() 内既有的 showTerminateConfirm/ConfirmActionOverlay（详情屏底部
    // 终止按钮同一个入口，见 M-B1-f），不新造第二份确认层。
    // 文案 "Terminate" 取源码值 AuthSessions_Terminate（ItemListRecentSessionItem.swift:290，
    // 不是确认层里的 "Terminate session"，两者不得混用）；底色/宽度沿用
    // SettingsPage.cj:679/:684 同族先例。
    @Builder
    private func buildTerminateSwipePanel() {
        Column {
            Text(trSource("Terminate"))
                .fontSize(14)
                .fontColor(0xFFFFFFFF)
        }
        .width(80)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xFF3B30)
        .onClick({ _ =>
            this.terminateHash = this.swipeRowSessionHash
            this.showTerminateConfirm = true
        })
    }

    /**
     * TC-0134-round5 §6.1：返回 chevron 的 Path 命令串。
     *
     * ArkUI Path 的 commands 坐标按 **px** 消费（ohos.arkui.component.path.cj.d:52
     * 的签名是裸 ResourceStr，字符串不携带单位；Path 上没有任何 viewBox/viewPort
     * 入口，viewPort 只存在于 Shape），而同组件的 .width/.height/.strokeWidth 是
     * Length、默认单位 vp（ohos.base.cj.d:253）。源侧 glassBackArrowImage
     * （NavigationButtonNode.swift:8-23）把点坐标画进 DrawingContext，由框架按
     * deviceScale 放大（GenerateImage.swift:628-635），这一次乘法在 ArkUI 侧必须
     * 由调用方自己补，否则图形缩到 1/density 并锚在组件框左上角（round5 N1'）。
     *
     * 坐标取值逐一对位源侧：44x44 画布，topRightPoint (24.6,14)，
     * centerPoint (17, 44*0.5=22)，第三点 (24.6, 44-14=30)。
     */
    private func backArrowCommands(): String {
        let scale: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let xRight: Float64 = 24.6 * scale
        let xApex: Float64 = 17.0 * scale
        let yTop: Float64 = 14.0 * scale
        let yMid: Float64 = 22.0 * scale
        let yBottom: Float64 = 30.0 * scale
        return "M${xRight} ${yTop} L${xApex} ${yMid} L${xRight} ${yBottom}"
    }

    public func build() {
            Stack {
                Column {
                    // 导航栏
                    // TC-0134 dynattr Diff-3：标题必须居中于**整条导航栏**，不是居中于
                    // 左右控件之间。源侧 NavigationBarImpl.swift:1082 ——
                    //   titleSize.width <= size.width - max(leftTitleInset, rightTitleInset)*2
                    //   ⇒ x = floor((size.width - titleSize.width) / 2)   // 屏居中
                    // 本页恒走该分支：标题字面量 "Devices" 实测 62.6vp，
                    // size.width 377.1vp、leftTitleInset 8+44=52、rightTitleInset 8+59.4=67.4，
                    // 377.1 - 67.4*2 = 242.3vp ≥ 62.6，判据静态恒真 ⇒ :1085 的
                    // 「挤到两侧内缩之间」分支在本页不可达，不复刻。
                    // 原写法 Row{ back; Blank(); Text; Blank(); edit } 实现的是 :1085 分支，
                    // 且按控件实宽而非内缩取中，实测左偏 (208-154)/2 = 27px = 7.7vp。
                    Stack(alignContent: Alignment.Center) {
                    Text(trSource("Devices"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)

                    Row {
                        // TC-0134-round3 Diff①：返回控件改 .glass 圆形 pill（形状照抄
                        // app/TelegramNavBar.cj:150-162，复刻形状不 import/调用该文件——该
                        // 文件全仓 0 个消费点，不在本 feature target_files 内）。"Back" 文字与
                        // "←" 字形一并消失（源侧 NavigationBarImpl.swift:459-462 在 .glass 下
                        // 无条件清空 caption）。
                        // TC-0134-round4 §6.2：改用 Path 描边直接复刻 glassBackArrowImage
                        // （NavigationButtonNode.swift:8-23），不再用 nav_back_arrow_glass.svg +
                        // Image.fillColor()——该 SVG 是 fill="none" 的描边路径，fillColor 会把
                        // 开口折线填成实心三角（round4 §3.3 归因），资源本身不改（他人 owner）。
                        Stack {
                            Path()
                                .width(44)
                                .height(44)
                                .commands(this.backArrowCommands())   // TC-0134-round5 §6.2：坐标按 vp→px 密度换算，见 backArrowCommands()
                                .fill(Color.Transparent)
                                .stroke(this.presentation.accentColor)
                                .strokeWidth(2)
                                .strokeLineCap(LineCapStyle.Round)
                                .strokeLineJoin(LineJoinStyle.Round)
                        }
                        .width(44)
                        .height(44)
                        .borderRadius(22)
                        .backgroundColor(this.presentation.cardColor)
                        .alignContent(Alignment.Center)
                        .onClick({ evt =>
                            routerPop()
                        })

                        Blank()

                        // TC-0134 §6.2 item10：右上 Edit 三态。装配条件 sessions.count>1
                        // （源 :995）；terminatingAllOther→spinner，editingSessions→完成图标，
                        // 否则→"Edit" 文案。编辑态行形态（红色减号/行尾按钮）归 TC-0135 D 组，
                        // 本轮只要求装配按钮与状态翻转。TC-0134-round3 Diff②：pill 容器已下沉
                        // 进 editButtonContent() 内层（见该函数注释），这里只留无属性挂载点。
                        Row {
                            this.editButtonContent()
                        }
                    }
                    // TC-0134-round4 §6.1 + TC-0541：.glass 导航栏无自身底（源
                    // NavigationBarImpl.swift:676-679），跟页底同一令牌，不能改回
                    // navBarColor（浅色会再盖出白带）。
                    .width(100.percent)
                    .height(56)
                    .padding(left: 8, right: 8)
                    .alignItems(VerticalAlign.Center)
                    }
                    .width(100.percent)
                    .height(56)
                    .backgroundColor(this.presentation.backgroundColor)

                    // TC-0134 §6.2 item12：header 三件套不随 loading 隐藏，进屏即在；
                    // 数据未到时 header 之下留白（源侧此屏无任何 loading 指示器形态），
                    // 不再画独立的全屏 "Loading devices..." 分支。
                    Scroll {
                        Column {
                            // 头部三件套（RecentSessionsHeaderItem.swift）：128x128 Lottie
                            // 动画 + 含两个链接的居中说明句 + 整宽蓝色 QR 按钮。
                            // TC-0134-round6 B1：rawfile/Devices.tgs 已转入资源树，通过
                            // AnimatedStickerComponent 播放（对位源侧 :146-151
                            // setup(source:...) + Queue.mainQueue().after(0.3){play(...)}，
                            // startDelayMs=300；playOnce 随 origin/main 的贴纸渲染重写移除，
                            // 该动画现循环播放——已登记为已知行为差异）。路径为空时（extractDevicesAnimation
                            // 尚未完成或失败）容器内渲染空，不回退 set2_ic_devices、不用
                            // emoji/字形/纯色块顶替（源侧此处无兜底内容）。
                            Column {
                                Stack(alignContent: Alignment.Center) {
                                    if (this.animLocalPath.size > 0) {
                                        AnimatedStickerComponent(
                                            documentId: DEVICES_HEADER_ANIM_DOC_ID,
                                            localPath: this.animLocalPath,
                                            displaySize: 128.0,
                                            startDelayMs: 300
                                        )
                                    }
                                }
                                .width(128)
                                .height(128)
                                .margin(top: 16, bottom: 12)

                                Text() {
                                    Span("Link ")
                                        .fontColor(this.presentation.textColor)
                                    Span("Telegram Desktop")
                                        .fontColor(0x0088CC)
                                        .onClick({ _ => this.openDesktopLink() })
                                    Span(trSource(" or "))
                                        .fontColor(this.presentation.textColor)
                                    Span("Telegram Web")
                                        .fontColor(0x0088CC)
                                        .onClick({ _ => this.openWebLink() })
                                    Span(" by scanning a QR code.")
                                        .fontColor(this.presentation.textColor)
                                }
                                .fontSize(14)
                                .textAlign(TextAlign.Center)
                                .margin(left: 32, right: 32, bottom: 16)

                                Row {
                                    // TC-0134-round7 Diff④：换成从源 qr_24.pdf 新转的专用件
                                    // （devices_ic_qr_button，非 settings_ic_qr 的拷贝，后者由
                                    // shell_chat_misc_components 拥有且被 3 个页面共用，不得碰）；
                                    // 节点尺寸对齐源 BundleIconComponent 的图像自然尺寸 24x24。
                                    Image(@r(app.media.devices_ic_qr_button))
                                        .width(24)
                                        .height(24)
                                        .fillColor(0xFFFFFFFF)
                                        .margin(right: 6)
                                    Text(trSource("Link Desktop Device"))
                                        .fontSize(17)
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0xFFFFFFFF)
                                }
                                .width(100.percent)
                                .height(52)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                // TC-0134-round7 Diff②：源 accent 真值是
                                // DefaultDayPresentationTheme.swift:56 defaultDayAccentColor =
                                // 0x0088ff；0x0088CC 在整个 iOS 源树 0 命中，是错常量（R-9 全局
                                // 常量登记项，本行是本 case 的 Diff②，只改这一处，同文件其余
                                // 0x0088CC 不动）。
                                .backgroundColor(0x0088FF)
                                // TC-0134-round7 Diff③：源侧走 ButtonComponent 的 .glass 覆盖分支
                                // （ButtonComponent.swift:703-706），真实圆角 = height * 0.5，不是
                                // 覆盖前的默认值 10。height 固定 52，故此处写死 26；height 若变更
                                // 须同步取 height/2。
                                .borderRadius(26)
                                .onClick({ evt => this.openAddDevice() })
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, bottom: 8)
                            .alignItems(HorizontalAlign.Center)

                            if (!this.isLoading) {
                                // 当前设备标题（TC-0134 §6.2 item11：外包容器承载 100% 宽度 +
                                // 左右 padding，Text 自身不再设 width，避免 margin(left) 与
                                // width(100.percent) 同时生效导致跨屏）
                                // TC-0134-round3 §3.7：源码值是 AuthSessions.CurrentSession =
                                // "CURRENT SESSION"（Localizable.strings:1470，渲染点
                                // RecentSessionsController.swift:519）；此前的 "THIS DEVICE" 是
                                // 照参照截图抄的，不是照源码值抄的（目标侧不存在生效的服务端
                                // 语言包覆盖能力，运行时不会被覆盖成正确值，见
                                // diag-language-pack-override-impact-audit.md §1.3）。改完后与
                                // 该账号 iOS 参照截图当前显示的 "THIS DEVICE" 不一致，是预期
                                // 结果，不是回归。
                                Row {
                                    Text(trSource("CURRENT SESSION"))
                                        .fontSize(13)
                                        .fontColor(this.presentation.secondaryTextColor)
                                }
                                .width(100.percent)
                                .padding(left: 31, right: 31)
                                .margin(top: 24, bottom: 8)

                                // CURRENT SESSION 卡：当前设备行 + terminate-all 行（TC-0134
                                // §6.2 item6：从独立卡片移入本卡，与当前设备行同一张白卡）
                                Column {
                                    ForEach(this.devices.toArray(), itemGenerator: { device: AuthorizationInfo, _idx: Int64 =>
                                        if (device.isCurrent) {
                                            Row {
                                                // TC-0134-round6 D5（diag-...-round6.md §6.3）：
                                                // 16 件品牌矢量已转入资源树，按 iconForSession
                                                // 分支表选形状（deviceIconAsset/deviceIconIsWhiteGlyph，
                                                // 分支顺序与 deviceIconTint 完全一致）。A 类
                                                // （8 件 30pt 白色字形）沿用品牌色铺底 + 内图铺满
                                                // 30vp（此前 round3 已定合成方向，本轮把内图从
                                                // 20vp 改为 30vp、图形从通用件换成按分支选出的
                                                // 真实矢量）；B 类（8 件 72pt 已合成整块）直接铺满
                                                // 30vp，不叠 backgroundColor/fillColor——PDF 自带
                                                // 品牌色背景路径，叠底色会盖住、叠 fillColor 会把
                                                // 整块涂白（组件级 if/else 是本工程已验证形态，
                                                // 不把 @r() 塞进值级表达式分支，见 D-133）。
                                                if (deviceIconIsWhiteGlyph(device.platform, device.deviceModel, device.systemVersion)) {
                                                    Column {
                                                        Image(deviceIconAsset(device.platform, device.deviceModel, device.systemVersion))
                                                            .width(30)
                                                            .height(30)
                                                            .fillColor(0xFFFFFFFF)
                                                    }
                                                    .width(30)
                                                    .height(30)
                                                    .justifyContent(FlexAlign.Center)
                                                    .alignItems(HorizontalAlign.Center)
                                                    .backgroundColor(deviceIconTint(device.platform, device.deviceModel, device.systemVersion))
                                                    .borderRadius(7)
                                                    .margin(right: 12)
                                                } else {
                                                    Image(deviceIconAsset(device.platform, device.deviceModel, device.systemVersion))
                                                        .width(30)
                                                        .height(30)
                                                        .borderRadius(7)
                                                        .margin(right: 12)
                                                }

                                                Column {
                                                    // TC-0134 §6.1 item3：第 1 段 = deviceModel
                                                    // （为空串时渲染空串，不回退 appName），
                                                    // 删除自造的 " (Current)" 后缀（源侧当前
                                                    // 设备行屏上无 Current 字样）。
                                                    Text(device.deviceModel)
                                                        .fontSize(17)
                                                        .fontWeight(FontWeight.Bold)
                                                        .fontColor(this.presentation.textColor)
                                                        .margin(right: 13)

                                                    // 第 2 段 = appName + 清洗后的 appVersion
                                                    Text(device.appName + " " + cleanAppVersion(device.appVersion))
                                                        .fontSize(15)
                                                        .fontColor(this.presentation.textColor)
                                                        .margin(top: 2)

                                                    // 第 3 段：整串灰色（源侧当前会话也是灰，
                                                    // 删除此前的绿色 0xFF34C759）。
                                                    // TC-0134-round3 Diff⑤：源侧三段全部
                                                    // maximumNumberOfLines:1 + truncationType:.end
                                                    // （ItemListRecentSessionItem.swift:341-343），
                                                    // 第 3 段（地点较长时）此前无截断策略会折成
                                                    // 两行、行高从 81pt 涨到 110.3vp，同列表行高
                                                    // 不一致；只补第 3 段单行截断。
                                                    Text() {
                                                        if (this.thirdLineKeepsSeparator(
                                                                trimmedLocation(device.country),
                                                                this.currentSessionTextBoxVp)) {
                                                            Span(trimmedLocation(device.country))
                                                            Span(trSource(" "))
                                                                .letterSpacing(SEP_TRACK_LEAD.vp)
                                                            Span("\u{2022}")
                                                                .letterSpacing(SEP_TRACK_DOT.vp)
                                                            Span(trSource(" "))
                                                                .letterSpacing(SEP_TRACK_TRAIL.vp)
                                                            Span(this.fitActivityLabel(
                                                                trimmedLocation(device.country), activityLabel(device),
                                                                this.currentSessionTextBoxVp))
                                                        } else {
                                                            Span(this.fitLocationOnly(
                                                                trimmedLocation(device.country),
                                                                this.currentSessionTextBoxVp))
                                                        }
                                                    }
                                                        .fontSize(15)
                                                        .fontColor(this.presentation.secondaryTextColor)
                                                        .margin(top: 2)
                                                        .maxLines(1)
                                                        .textOverflow(TextOverflow.Ellipsis)
                                                }
                                                .alignItems(HorizontalAlign.Start)
                                                .layoutWeight(1)
                                                .onAreaChange({ _: Area, newArea: Area =>
                                                    this.currentSessionTextBoxVp = newArea.width.value
                                                })
                                            }
                                            .width(100.percent)
                                            .padding(left: 16, right: 8, top: 12, bottom: 12)
                                            // TC-0135 A8（diag-...-round2.md §8.1 item3）：当前会话行也必须可点
                                            // ——源侧 .currentSession 与 .session 两个 case 的 action 完全相同，
                                            // 都是 push 详情屏（RecentSessionsController.swift:368-372/:400）。
                                            .onClick({ evt =>
                                                routerPush("RecentSessionScreen", this.sessionRouteParam(device))
                                            })
                                        }
                                    })

                                    // TC-0134-round9 F-1（diag-suite_settings_privacy-TC-0134-round9.md §6.1）：分隔线两端
                                    // 的水平内缩此前都没有源侧对位物——只给了一个 left: 76（round2 按"与同页既有分隔线
                                    // 同口径"自造的近似值），右端无参数于是一路顶到卡片右缘。改为两端各取一个源码常量：
                                    //   left  59 ← ItemListRecentSessionItem.swift:328 leftInset = 59.0 + params.leftInset，
                                    //              :494 bottomStripeInset = leftInset + editingOffset（非编辑态 offset=0）。
                                    //              其中 params.leftInset = 16（ItemListControllerNode.swift:658，402pt 屏
                                    //              max(16, floor((402-674)/2)) = 16）已由卡片自身 margin(left:16) 承担，
                                    //              所以写进 Divider 的只能是 59。
                                    //   right 16 ← 同文件 :348 separatorRightInset（item.systemStyle == .glass），经 :511
                                    //              width = layoutSize.width − bottomStripeInset − params.rightInset
                                    //                      − separatorRightInset 生效。
                                    // 绝对量 1pt → 1vp，不乘屏宽比。本页两条会话行分隔线在源侧是同一个 bottomStripeNode
                                    // 画的，参数完全相同，故 :937 与 :1071 必须同值（只改一处会在同屏造出两种内缩）。
                                    // 只改这两个 margin 参数：color/strokeWidth 与 Column{ Row; Divider } 结构不动。
                                    Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 59, right: 16)

                                    // TC-0134 §6.2 item6：terminate 行左对齐（去掉此前的
                                    // FlexAlign.Center），文案取源码值 "Terminate all other
                                    // sessions"（小写 all other）。
                                    // TC-0134-round6 Diff⑦（diag-...-round6.md §6.5）：行首补红色
                                    // 举手矢量（源 Item List/Block.imageset/Icon-2.pdf，不是名字
                                    // 相近的灰色 stop.pdf），文本随之从贴着 padding(left:16) 挪到
                                    // 图标右侧——与会话行图标同一左内缩公式（卡片
                                    // margin(left:16) + 行 padding(left:16) + 图标 30vp +
                                    // margin(right:12) = 74vp，同卡内当前会话行标题同一起点，
                                    // 已用 layouts/w1_loaded.json 核验：[259,1475] = 74vp）。
                                    // fillColor 上红是忠实源侧的运行时染色（generateTintedImage(
                                    // …, theme.list.itemDestructiveColor)），不依赖 PDF 自带红色。
                                    Row {
                                        Image(@r(app.media.devices_ic_terminate))
                                            .width(30)
                                            .height(30)
                                            .fillColor(0xFFFF3B30)
                                            .margin(right: 12)

                                        Text(trSource("Terminate all other sessions"))
                                            .fontSize(17)
                                            .fontColor(0xFF3B30)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 14, bottom: 14)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ evt =>
                                        this.showTerminateAllConfirm = true
                                    })
                                }
                                .backgroundColor(this.presentation.cardColor)
                                .borderRadius(12)
                                // TC-0134-round6（dev_pattern.md D-124）：本卡本轮改写了首行
                                // （D5 图标）与末行（Diff⑦ terminate 行，新增满宽 onClick 行）内容
                                // ——.borderRadius 只画圆角背景，不裁剪满宽子节点的默认按压高亮，
                                // 按住首/末行时四角会露方角，必须 .clip(true)。
                                .clip(true)
                                .margin(left: 16, right: 16)

                                // TC-0134-round3 Diff⑧：脚注被父 Column（无 alignItems 属性，
                                // ArkUI 默认 HorizontalAlign.Center）水平居中——Text 自身无
                                // width 时盒宽收缩到内容宽，故被居中；照分区头（如 :526-530）
                                // 已验证的写法外包一层 Row + width(100%) + padding 取代 margin，
                                // 使盒宽撑满、内容左对齐。
                                Row {
                                    Text(trSource("Logs out all devices except for this one."))
                                        .fontSize(13)
                                        .fontColor(this.presentation.secondaryTextColor)
                                }
                                .width(100.percent)
                                .padding(left: 31, right: 31)
                                .margin(top: 8)

                                // 其他设备标题
                                Row {
                                    Text(trSource("ACTIVE SESSIONS"))
                                        .fontSize(13)
                                        .fontColor(this.presentation.secondaryTextColor)
                                }
                                .width(100.percent)
                                .padding(left: 31, right: 31)
                                .margin(top: 24, bottom: 8)

                                // 其他设备列表（TC-0135 B1，diag-...-B1-swipe-reveal.md §6
                                // M-B1-a〜c）：Column{ForEach} 换成 List{ForEach{ListItem}}，
                                // 照抄 SettingsPage.cj:579-651 已验证的同族容器形态——不加
                                // layoutWeight/height，滚动职责留给外层 :513 的整页 Scroll。
                                // TC-0134-round7 D-165：List 显式 width(100%) 时不能再叠水平
                                // margin（父 Column 默认居中会把 margin 摞成一个更宽的盒，可
                                // 见左缘塌成 0）——内缩改由外层不裁剪的 Column.padding 承担，
                                // List 自身的 background/borderRadius/clip 原样留在卡片本体上。
                                Column {
                                    List {
                                        ForEach(this.otherDevices(), itemGenerator: { device: AuthorizationInfo, _idx: Int64 =>
                                            ListItem {
                                                Column {
                                                    Row {
                                                        // TC-0135 M6-b：编辑态下最前面插入红圆-镂空杠删除控件
                                                        // （源 ItemListEditableDeleteControlNode.swift）；点击直接
                                                        // 复用共享确认入口 showTerminateConfirm，不打开左滑面板
                                                        // ——M6-c 第3条硬约束：ListItem.swipeAction() 没有代码打开
                                                        // 面板的入口，逐字复刻会推翻本轮已 PASS 的 swipeAction reveal。
                                                        if (this.editingSessions) {
                                                            Stack(alignContent: Alignment.Center) {
                                                                Column().width(18).height(18).borderRadius(9).backgroundColor(0xFFFFFFFF)
                                                                Image(@r(app.media.itemlist_ic_remove)).width(22).height(22)
                                                            }
                                                            .width(38)
                                                            .height(22)
                                                            .onClick({ evt =>
                                                                this.terminateHash = device.hash
                                                                this.showTerminateConfirm = true
                                                            })
                                                        }

                                                        // TC-0134-round6 D5：与当前会话行同一合成方式
                                                        // （见上方 :830 一带注释）——源侧两类行图标合成
                                                        // 完全相同，不因 isCurrent 分叉。
                                                        if (deviceIconIsWhiteGlyph(device.platform, device.deviceModel, device.systemVersion)) {
                                                            Column {
                                                                Image(deviceIconAsset(device.platform, device.deviceModel, device.systemVersion))
                                                                    .width(30)
                                                                    .height(30)
                                                                    .fillColor(0xFFFFFFFF)
                                                            }
                                                            .width(30)
                                                            .height(30)
                                                            .justifyContent(FlexAlign.Center)
                                                            .alignItems(HorizontalAlign.Center)
                                                            .backgroundColor(deviceIconTint(device.platform, device.deviceModel, device.systemVersion))
                                                            .borderRadius(7)
                                                            .margin(right: 12)
                                                        } else {
                                                            Image(deviceIconAsset(device.platform, device.deviceModel, device.systemVersion))
                                                                .width(30)
                                                                .height(30)
                                                                .borderRadius(7)
                                                                .margin(right: 12)
                                                        }

                                                        Column {
                                                            Text(device.deviceModel)
                                                                .fontSize(17)
                                                                .fontWeight(FontWeight.Bold)
                                                                .fontColor(this.presentation.textColor)
                                                                .margin(right: 13)

                                                            Text(device.appName + " " + cleanAppVersion(device.appVersion))
                                                                .fontSize(15)
                                                                .fontColor(this.presentation.textColor)
                                                                .margin(top: 2)

                                                            Text() {
                                                                if (this.thirdLineKeepsSeparator(
                                                                        trimmedLocation(device.country),
                                                                        this.listSessionTextBoxVp)) {
                                                                    Span(trimmedLocation(device.country))
                                                                    Span(trSource(" "))
                                                                        .letterSpacing(SEP_TRACK_LEAD.vp)
                                                                    Span("\u{2022}")
                                                                        .letterSpacing(SEP_TRACK_DOT.vp)
                                                                    Span(trSource(" "))
                                                                        .letterSpacing(SEP_TRACK_TRAIL.vp)
                                                                    Span(this.fitActivityLabel(
                                                                        trimmedLocation(device.country), activityLabel(device),
                                                                        this.listSessionTextBoxVp))
                                                                } else {
                                                                    Span(this.fitLocationOnly(
                                                                        trimmedLocation(device.country),
                                                                        this.listSessionTextBoxVp))
                                                                }
                                                            }
                                                                .fontSize(15)
                                                                .fontColor(this.presentation.secondaryTextColor)
                                                                .margin(top: 2)
                                                                .maxLines(1)
                                                                .textOverflow(TextOverflow.Ellipsis)
                                                        }
                                                        .alignItems(HorizontalAlign.Start)
                                                        .layoutWeight(1)
                                                        .onAreaChange({ _: Area, newArea: Area =>
                                                            this.listSessionTextBoxVp = newArea.width.value
                                                        })
                                                    }
                                                    .width(100.percent)
                                                    .padding(left: 16, right: 8, top: 12, bottom: 12)
                                                    // TC-0135 A8（diag-...-round2.md §8.1 item3）：点行 push 详情屏
                                                    // ——原「点行→弹终止确认」语义（§8.1 item4）整体删除，终止
                                                    // 入口只留详情屏底部按钮与本行左滑 reveal（下方 swipeAction）。
                                                    .onClick({ evt =>
                                                        routerPush("RecentSessionScreen", this.sessionRouteParam(device))
                                                    })

                                                    // TC-0134-round9 F-1：与当前会话卡内那条分隔线同源同值（源侧同一个
                                                    // bottomStripeNode），取值出处见本文件当前会话卡内 Divider 上方的注释。
                                                    // TC-0135 M6-b：编辑态下左内缩随删除控件占位增加 38vp（59+38=97），
                                                    // 对位源 ItemListRecentSessionItem.swift:494 bottomStripeInset = leftInset + editingOffset。
                                                    Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: if (this.editingSessions) { 97 } else { 59 }, right: 16)
                                                }
                                            }
                                            // TC-0135 B1 M-B1-d（三条硬约束，逐字照抄）：end: 槽只能是
                                            // bind(this.buildTerminateSwipePanel, this)()；行身份镜像唯一
                                            // 写入点是 onOffsetChange（带 offset != 0.0 守卫），end: 闭包体
                                            // 内不做任何 this.xxx = 赋值——否则 ForEach 逐行预求值会把镜像
                                            // 覆盖成"最后构建的那一行"（TC-0085 round2 真机复现的数据安全
                                            // 缺陷同源，见 dev_pattern.md D-135 更正横幅）。
                                            .swipeAction(
                                                end: { =>
                                                    bind(this.buildTerminateSwipePanel, this)()
                                                },
                                                onOffsetChange: { offset: Float64 =>
                                                    if (offset != 0.0) {
                                                        this.swipeRowSessionHash = device.hash
                                                    }
                                                }
                                            )
                                        }, keyGeneratorFunc: { device: AuthorizationInfo, _idx: Int64 =>
                                            "sess_${device.hash}"
                                        })
                                    }
                                    .width(100.percent)
                                    .scrollBar(BarState.Off)
                                    .backgroundColor(this.presentation.cardColor)
                                    .borderRadius(12)
                                    // TC-0134-round6（dev_pattern.md D-124）：本轮改写了每行的 D5
                                    // 图标内容，行本身满宽 + onClick + swipeAction，缺 .clip(true)
                                    // 时按住首/末行四角会露方角。
                                    .clip(true)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16)

                                // TC-0134 §6.2 item9：底部 Learn More 脚注，源码值
                                // AuthSessions.OtherDevices 去 markdown 语法后的可见文本，
                                // "Learn More" 蓝色可点，调 openLearnMore()。
                                // TC-0134-round3 Diff⑧：同上一条脚注，外包 Row + width(100%) +
                                // padding 取代 margin(left/right)，避免被无属性父 Column 的
                                // 默认水平居中收缩盒宽；Span 的 onClick 原样留在 Span 上。
                                Row {
                                    Text() {
                                        Span("The official Telegram App is available for iPhone, iPad, Android, macOS, Windows and Linux. ")
                                            .fontColor(this.presentation.secondaryTextColor)
                                        Span(trSource("Learn More"))
                                            .fontColor(0x0088CC)
                                            .onClick({ _ => this.openLearnMore() })
                                    }
                                    .fontSize(13)
                                    .textAlign(TextAlign.Start)
                                }
                                .width(100.percent)
                                .padding(left: 31, right: 31)
                                .margin(top: 8)

                                // TC-0137 §8.3 item9：自动登出分区，追加在 Scroll > Column 末尾。
                                Row {
                                    Text("AUTOMATICALLY TERMINATE OLD SESSIONS")
                                        .fontSize(13)
                                        .fontColor(this.presentation.secondaryTextColor)
                                }
                                .width(100.percent)
                                .padding(left: 31, right: 31)
                                .margin(top: 24, bottom: 8)

                                Column {
                                    Row {
                                        Text(trSource("If Inactive For"))
                                            .fontSize(17)
                                            .fontColor(this.presentation.textColor)

                                        Blank()

                                        // TC-0134-round3 Diff⑨ + TC-0137-round3 A2/A4：右值是
                                        // ItemListDisclosureItem（源侧恒含 arrowNode，
                                        // ItemListDisclosureItem.swift:214/271/291/394）；菜单
                                        // 用 bindPopup 直接锚定在本节点上（对位源侧
                                        // .reference(sourceView: sourceNode.labelNode.view)，
                                        // 锚点是右值 label 不是整行）。菜单开合期间本节点与
                                        // 下方 chevron 一起 alpha 0.5（对位
                                        // ItemListDisclosureItem.swift:305-315
                                        // updateHasContextMenu，源侧只碰这两个节点，不加整行
                                        // 高亮、不加全屏压暗——§2.2 逐像素比对已证源侧 .reference
                                        // 呈现下页面零施加压暗/模糊）。
                                        Text(this.sessionTtlLabel(this.ttlDays))
                                            .fontSize(17)
                                            .fontColor(this.presentation.secondaryTextColor)
                                            .opacity(if (this.showTtlMenu) { 0.5 } else { 1.0 })
                                            .bindPopup(
                                                this.showTtlMenu,
                                                CustomPopupOptions(
                                                    builder: bind(this.ttlMenuContent, this),
                                                    placement: Placement.Bottom,
                                                    popupColor: Color.Transparent,
                                                    enableArrow: false,
                                                    autoCancel: true,
                                                    radius: 14.vp,
                                                    onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                                                        if (!evt.isVisible) { this.showTtlMenu = false }
                                                    })
                                                )
                                            )

                                        Image(@r(app.media.item_list_disclosure_arrow))
                                            .width(13)
                                            .height(13)
                                            .fillColor(this.presentation.secondaryTextColor)
                                            .margin(left: 6)
                                            .opacity(if (this.showTtlMenu) { 0.5 } else { 1.0 })
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 14, bottom: 14)
                                    .onClick({ evt => this.showTtlMenu = true })
                                }
                                .backgroundColor(this.presentation.cardColor)
                                .borderRadius(12)
                                .margin(left: 16, right: 16, bottom: 40)
                            }
                        }
                    }
                    .layoutWeight(1)
                    .backgroundColor(this.presentation.backgroundColor)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(this.presentation.backgroundColor)
                .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())

                // 单会话确认层（TC-0135 B8，§8.2 item6 第一条）：收敛到共享入口
                // ConfirmActionOverlay——无标题、正文不拼设备名、纵向按钮、
                // 文案取源码值 "Terminate session"（小写 s）。
                if (this.showTerminateConfirm) {
                    ConfirmActionOverlay(
                        hasTitle: false,
                        titleText: "",
                        bodyText: "Are you sure you want to terminate this session?",
                        destructiveText: "Terminate session",
                        cancelText: "Cancel",
                        onDestructive: { =>
                            this.terminateSession(this.terminateHash)
                        },
                        onCancel: { =>
                            this.showTerminateConfirm = false
                        }
                    )
                }

                // 终止全部其它会话的确认层（TC-0135 C1，已验证与源一致；§8.2 item6
                // 第二条改走共享入口，参数取现有值不变）。
                if (this.showTerminateAllConfirm) {
                    ConfirmActionOverlay(
                        hasTitle: false,
                        titleText: "",
                        bodyText: "Are you sure you want to terminate all other sessions?",
                        destructiveText: "Terminate all other sessions",
                        cancelText: "Cancel",
                        onDestructive: { =>
                            this.showTerminateAllConfirm = false
                            this.terminatingAllOther = true
                            this.terminateAllOther()
                        },
                        onCancel: { =>
                            this.showTerminateAllConfirm = false
                        }
                    )
                }
            }
            .onAppear({ => this.ensureLoaded() })
    }
}

/**
 * 共享破坏性动作确认层（TC-0135 §3.3/§8.2 item5：RC-D 硬约束——四处手写覆盖层
 * 必须收敛到单一入口，不得再各写一份）。渲染形状照已验证与源一致的
 * "终止全部其它会话" 确认层：无标题时不渲染标题节点、正文居中、按钮纵向排列、
 * 破坏性项在上（红）、Cancel 在下（蓝）、中间水平 Divider、外层压暗全屏遮罩。
 * 对位源侧 textAlertController(context:title:text:actions:actionLayout:.vertical)。
 *
 * 用普通 var（非 @Prop）承载闭包/字符串参数——同包内 components/ContextMenu.cj
 * ContextMenuView 的既有约定，`if (this.xxx) { ConfirmActionOverlay(...) }` 直接
 * 实例化的写法在本工程已有多处验证先例（PeerInfoPage.cj/ContactListPage.cj/
 * CallHistoryPage.cj 对 ContextMenuView 的用法）。
 *
 * DevicesPage.cj 与 WebSessionsPage.cj 同包（ohos_app_cangjie_entry.pages），
 * 后者直接复用本组件，做到真正的"同一个入口"而非两份形状相同的独立实现。
 */
@Component
public class ConfirmActionOverlay {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var hasTitle: Bool = false
    public var titleText: String = ""
    public var bodyText: String = ""
    public var destructiveText: String = ""
    public var cancelText: String = "Cancel"
    public var onDestructive: () -> Unit = { => }
    public var onCancel: () -> Unit = { => }

    func build() {
        Column {
            Column {
                if (this.hasTitle) {
                    Text(this.titleText)
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .margin(bottom: 8)
                }

                Text(this.bodyText)
                    .fontSize(15)
                    .fontColor(0x000000)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)

                Column {
                    Text(this.destructiveText)
                        .fontSize(17)
                        .fontColor(0xFF3B30)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .height(44)
                        .onClick({ evt => this.onDestructive() })

                    Divider().color(0xE5E5EA).strokeWidth(1)

                    Text(this.cancelText)
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .height(44)
                        .onClick({ evt => this.onCancel() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ evt => this.onCancel() })
    }
}
