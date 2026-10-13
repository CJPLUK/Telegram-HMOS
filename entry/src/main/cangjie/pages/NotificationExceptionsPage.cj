package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getNotificationMuteSettingsService, JsonParser}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * NotificationExceptionsPage — 逐对端通知例外创建/编辑屏（ic_nsnd_add_exception_flow）
 *
 * 对应源侧 NotificationExceptionsScreen.swift / NotificationPeerExceptionController.swift
 * （owned_source_files 归 shell_peer_management）。本页承接分类子屏
 * pages/NotificationsPeerCategoryPage.cj「Add an Exception」流程选中 peer 之后的
 * 真正例外创建/编辑步骤：为指定 peer 在指定通知分类下设置静音时长（Enable/1 Hour/
 * 8 Hours/2 Days/Mute Forever），并写入 services/NotificationMuteSettingsService.cj
 * 既有的本地 Preferences 例外列表（P2-334 `PeerNotifyException`/`setException`/
 * `removeException`/`getExceptionForPeer`，已核实全部存在且行为匹配，直接复用不重复
 * 实现——本文件的 `NotificationPeerException` 是本页接收路由入参的 DTO，与该服务类
 * 持久化用的 `PeerNotifyException`是两个不同用途的类型，命名故意区分)。
 *
 * 入参协议（`setPending("NotificationExceptionsPage", json)` 后 `routerPush`）：
 *   {"peerId": <Int64>, "peerName": <String>, "category": <String>}
 * 三者均可选缺省（peerId 缺省或为 0 时页面直接允许 Cancel 退出，不做任何写入）。
 *
 * 已知接线缺口（本任务 target_files 仅含本文件，以下均已按 7b 结构化 emit，不在此臆造）：
 *   1. pages/ContactListPage.cj 当前没有"选人转发到本页"的模式——本轮
 *      NotificationsPeerCategoryPage.openAddException() 仍是占位
 *      routerPush("ContactListPage")（无参、无完成回调），选中联系人后不会走到本页。
 *   2. 本页是 @HybridComponentEntry（D-148），完整路由可达还需要
 *      resources/base/profile/route_map.json 新增条目 + 新建
 *      entry/src/main/ets/pages/NotificationExceptionsPage.ets 壳，两者不在本文件内。
 */
public class NotificationPeerException {
    public var peerId: Int64 = 0
    public var peerName: String = ""
    public var category: String = ""

    public init(peerId: Int64, peerName: String, category: String) {
        this.peerId = peerId
        this.peerName = peerName
        this.category = category
    }
}

@HybridComponentEntry
@Component
public class NotificationExceptionsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false
    @State var peerId: Int64 = 0
    @State var peerName: String = ""
    @State var category: String = ""
    @State var isApplying: Bool = false
    // -1 = 尚未拉到本地例外记录；0 = Enable（未静音）；2147483647 = 永久静音；
    // 其余 = 静音至该 Unix 时间戳。语义同 NotificationMuteSettingsService 文件头注释。
    @State var currentMuteUntil: Int32 = -1

    public func aboutToAppear(): Unit {
        this.ensureLoaded()
    }

    private func parsePendingPayload(raw: String): NotificationPeerException {
        var pid: Int64 = 0
        var pname: String = ""
        var cat: String = ""
        if (raw.size > 0 && raw != "{}") {
            let obj = JsonParser.parseObject(raw)
            if (obj.has("peerId")) {
                pid = obj.getInt("peerId")
            }
            if (obj.has("peerName")) {
                pname = obj.getString("peerName")
            }
            if (obj.has("category")) {
                cat = obj.getString("category")
            }
        }
        return NotificationPeerException(pid, pname, cat)
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("NotificationExceptionsPage")
        let payload = this.parsePendingPayload(raw)
        this.peerId = payload.peerId
        this.peerName = payload.peerName
        this.category = payload.category
        this.loadCurrentException()
    }

    private func loadCurrentException(): Unit {
        if (this.peerId == 0) { return }
        let pid = this.peerId
        let _ = spawn {
            let svc = getNotificationMuteSettingsService()
            let opt = svc.getExceptionForPeer(pid)
            let muteVal: Int32 = match (opt) {
                case Some(v) => v
                case None => -1
            }
            launch {
                this.currentMuteUntil = muteVal
            }
        }
    }

    /** R-107: @Builder/build() 内禁止 let/var，判断逻辑外移。 */
    private func isOptionSelected(durationSeconds: Int64): Bool {
        if (this.currentMuteUntil < 0) { return false }
        if (durationSeconds == 0) { return this.currentMuteUntil == 0 }
        if (durationSeconds >= 2147483647) { return this.currentMuteUntil == 2147483647 }
        return this.currentMuteUntil > 0 && this.currentMuteUntil < 2147483647
    }

    private func applyDuration(durationSeconds: Int64): Unit {
        if (this.peerId == 0) {
            routerPop()
            return
        }
        this.isApplying = true
        let pid = this.peerId
        let pname = this.peerName
        let svc = getNotificationMuteSettingsService()
        let muteVal: Int32 = if (durationSeconds <= 0) {
            0
        } else if (durationSeconds >= 2147483647) {
            2147483647
        } else {
            svc.muteUntilForDuration(durationSeconds)
        }
        let _ = spawn {
            svc.setException(pid, pname, muteVal)
            launch {
                this.isApplying = false
                routerPop()
            }
        }
    }

    private func removeExceptionAndBack(): Unit {
        if (this.peerId == 0) {
            routerPop()
            return
        }
        this.isApplying = true
        let pid = this.peerId
        let svc = getNotificationMuteSettingsService()
        let _ = spawn {
            svc.removeException(pid)
            launch {
                this.isApplying = false
                routerPop()
            }
        }
    }

    @Builder
    func buildDurationOption(label: String, durationSeconds: Int64) {
        Row {
            Text(label)
                .fontSize(17)
                .fontColor(if (this.isOptionSelected(durationSeconds)) { 0x317AFF } else { 0x000000 })
                .layoutWeight(1)
            if (this.isOptionSelected(durationSeconds)) {
                Text("✓")
                    .fontSize(17)
                    .fontColor(0x317AFF)
            }
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(if (this.isOptionSelected(durationSeconds)) { 0xF0F8FF } else { 0xFFFFFF })
        .onClick({ _ => this.applyDuration(durationSeconds) })
    }

    public func build() {
        Column {
            Row {
                Text(trSource("Cancel"))
                    .fontSize(16)
                    .fontColor(0x317AFF)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text("Notification Exception")
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

            if (this.peerName.size > 0) {
                Text(this.peerName)
                    .fontSize(15)
                    .fontColor(0x8E8E93)
                    .width(100.percent)
                    .textAlign(TextAlign.Center)
                    .margin(top: 4, bottom: 8)
            }

            if (this.isApplying) {
                LoadingProgress()
                    .width(32)
                    .height(32)
                    .margin(top: 24)
            } else {
                Column {
                    this.buildDurationOption("Enable", 0)
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                    this.buildDurationOption("1 Hour", 3600)
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                    this.buildDurationOption("8 Hours", 28800)
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                    this.buildDurationOption("2 Days", 172800)
                    Divider().color(0xE5E5EA).strokeWidth(1).margin(left: 16)
                    this.buildDurationOption("Mute Forever", 2147483647)
                }
                .backgroundColor(0xFFFFFF)
                .borderRadius(12)
                .margin(left: 16, right: 16, top: 8)

                if (this.currentMuteUntil >= 0 && this.currentMuteUntil != 0) {
                    Text("Remove Exception")
                        .fontSize(17)
                        .fontColor(0xFF3B30)
                        .width(100.percent)
                        .height(56)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 16)
                        .onClick({ _ => this.removeExceptionAndBack() })
                }
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
    }
}
