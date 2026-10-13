package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getPrivacyEngineService, PrivacyEngineService}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import std.collection.ArrayList

/**
 * BirthdayPrivacyPage — 生日可见性专属隐私控制面板（ic_birthday_privacy_destination）
 *
 * 对位源侧 interaction.openBirthdatePrivacy() 打开的 SelectivePrivacySettingsController
 * (kind=.birthday)。真实数据源：account.privacyRules，key=PrivacyEngineService.KEY_BIRTHDAY
 * （与 pages/SelectivePrivacySettingsPage.cj 的 kindParam=="birthday" 分支——本轮
 * ic_privacy_selective_kind_extension 落地——共用同一把 key，行为对齐）。
 *
 * Everyone/My Contacts/Nobody 三档，立即提交（本地 state 唯一权威，写入即发即忘，同
 * SelectivePrivacySettingsPage RC-2 范式，不回读覆盖）。不带例外名单/close friends 等
 * 扩展槽位——源侧该 kind 支持这些，但本页是"最小可行专属目的地"，与
 * SelectivePrivacySettingsPage 的 P1/P3/P12 结构化条目（同样标注为不在当前范围）保持
 * 同一克制边界，不重复造轮子。
 *
 * 已知接线缺口（本任务 target_files 仅含本文件，按 7b 结构化 emit，不在此臆造）：
 *   1. 路由不可达：本页 @HybridComponentEntry 需要 resources/base/profile/route_map.json
 *      新增条目 + 新建 entry/src/main/ets/pages/BirthdayPrivacyPage.ets 壳（D-148），两者
 *      均不在本文件内。
 *   2. pages/EditProfilePage.cj 的生日脚注 "Change ›" 链接当前指向通用 PrivacySettingsPage
 *      作为非占位实现、仅是过渡落点，需要该文件的 owner 改指向本页。
 */
@HybridComponentEntry
@Component
public class BirthdayPrivacyPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var isLoading: Bool = true
    @State var currentValue: String = "everybody"
    @State var allowIds: ArrayList<Int64> = ArrayList<Int64>()
    @State var disallowIds: ArrayList<Int64> = ArrayList<Int64>()

    public func aboutToAppear(): Unit {
        this.ensureLoaded()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.refresh()
    }

    private func refresh(): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let rules = svc.getPrivacyRules(PrivacyEngineService.KEY_BIRTHDAY)
            let parsed = rules.parsed
            let v = rules.primaryValue
            let allow = ArrayList<Int64>()
            for (id in rules.allowUsers) {
                allow.add(id)
            }
            let disallow = ArrayList<Int64>()
            for (id in rules.disallowUsers) {
                disallow.add(id)
            }
            launch {
                if (parsed) {
                    this.currentValue = v
                    this.allowIds = allow
                    this.disallowIds = disallow
                }
                this.isLoading = false
            }
        }
    }

    // RC-2 范式（同 SelectivePrivacySettingsPage.selectValue）：本地 state 是唯一权威，
    // 立即乐观置位，网络写入不回读覆盖。
    private func selectValue(newValue: String): Unit {
        if (this.currentValue == newValue) { return }
        this.currentValue = newValue
        let av = ArrayList<Int64>()
        for (id in this.allowIds) {
            av.add(id)
        }
        let dv = ArrayList<Int64>()
        for (id in this.disallowIds) {
            dv.add(id)
        }
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let _ = svc.setPrivacyWithUsers(PrivacyEngineService.KEY_BIRTHDAY, newValue, av, dv)
        }
    }

    @Builder
    func buildValueOption(label: String, value: String) {
        Row {
            Image(@r(app.media.media_ic_check))
                .width(20)
                .height(20)
                .fillColor(0x317AFF)
                .opacity(if (this.currentValue == value) { 1.0 } else { 0.0 })
                .margin(right: 12)
            Text(label)
                .fontSize(17)
                .fontColor(0x000000)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(44)
        .padding(left: 16, right: 16)
        .backgroundColor(0xFFFFFF)
        .onClick({ _ => this.selectValue(value) })
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Back"))
                    .fontSize(16)
                    .fontColor(0x317AFF)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text("Birthday")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                Blank().layoutWeight(1)
                Row { }.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0xFFFFFF)
            .alignItems(VerticalAlign.Center)

            Text(trSource("WHO CAN SEE MY DATE OF BIRTH"))
                .fontSize(13)
                .fontColor(0x8E8E93)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 16, bottom: 6)

            if (this.isLoading) {
                LoadingProgress()
                    .width(32)
                    .height(32)
                    .margin(top: 24)
            } else {
                Column {
                    this.buildValueOption("Everybody", "everybody")
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)
                    this.buildValueOption("My Contacts", "contacts")
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 48)
                    this.buildValueOption("Nobody", "nobody")
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16)
                .clip(true)

                Text(trSource("You can restrict who can see your date of birth with granular precision."))
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .width(100.percent)
                    .padding(left: 31, right: 31, top: 8)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }
}
