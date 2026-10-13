package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.time.*
import std.convert.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.viewmodels.getLiveLocationManagerViewModel
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.{callArk, subscribe, LOCATION_VIEW_UPDATE, EVT_LOCATION_VIEW_ACTION}
import ohos_app_cangjie_entry.models.Message

/**
 * LocationViewPage — 位置 / 实时位置查看页的数据层（对位 iOS LocationViewController）。
 *
 * 界面整块由 ArkTS 渲染（ets/pages/LocationViewPage.ets：HMS 地图 + 玻璃按钮 + 可折叠列表），
 * 本组件只负责：读入口参数、拉当前定位、从本地历史筛出该会话的活跃实时位置、
 * 汇总自己的分享状态，按 5s 节奏推送状态 JSON；并接收 ArkTS 回传的动作
 * （关闭 / 停止分享 / 开始分享 / 用系统地图打开）。
 */

// dispatchEvent 订阅只增不删：只订一次，转给当前存活实例。
var _locationViewActionSink: Option<(String) -> Unit> = None
var _locationViewSubscribed: Bool = false

@HybridComponentEntry
@Component
public class LocationViewPage {
    @State var loaded: Bool = false
    private var alive: Bool = false

    private var peerType: String = ""
    private var peerId: Int64 = 0
    private var msgId: Int64 = 0
    private var subjLat: Float64 = 0.0
    private var subjLng: Float64 = 0.0
    private var isLive: Bool = false
    private var period: Int64 = 0
    private var timestamp: Int64 = 0
    private var editDate: Int64 = 0
    private var isSent: Bool = false
    private var senderId: Int64 = 0
    private var senderName: String = ""
    private var title: String = ""
    private var venueTitle: String = ""
    private var venueAddress: String = ""

    private var userOk: Bool = false
    private var userLat: Float64 = 0.0
    private var userLng: Float64 = 0.0
    private var lastUserFixMs: Int64 = 0
    private var participants: ArrayList<Message> = ArrayList<Message>()
    private var ownLiveMsgId: Int64 = 0

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.alive = true
        let obj = JsonParser.parseObject(takePending("LocationViewPage"))
        this.peerType = obj.getString("peerType")
        this.peerId = obj.getInt("peerId")
        this.msgId = obj.getInt("msgId")
        this.subjLat = parseCoord(obj.getString("lat"))
        this.subjLng = parseCoord(obj.getString("lng"))
        this.isLive = obj.getBool("isLive")
        this.period = obj.getInt("period")
        this.timestamp = obj.getInt("timestamp")
        this.editDate = obj.getInt("editDate")
        this.isSent = obj.getBool("isSent")
        this.senderId = obj.getInt("senderId")
        this.senderName = obj.getString("senderName")
        this.title = obj.getString("title")
        this.venueTitle = obj.getString("venueTitle")
        this.venueAddress = obj.getString("venueAddress")
        Hilog.info(0, "CjTelegram", "[LocationViewPage] open peer=${this.peerType}/${this.peerId} msg=${this.msgId} live=${this.isLive} lat=${this.subjLat} lng=${this.subjLng}")

        if (!_locationViewSubscribed) {
            _locationViewSubscribed = true
            subscribe(EVT_LOCATION_VIEW_ACTION, { json: String =>
                match (_locationViewActionSink) {
                    case Some(sink) => sink(json)
                    case None => ()
                }
            })
        }
        _locationViewActionSink = Some({ json: String => this.handleAction(json) })
        this.startRefreshLoop()
    }

    protected override func aboutToDisappear(): Unit {
        this.alive = false
        _locationViewActionSink = None
    }

    /** iOS：ETA 60s / 标注间距 1s / 文案 30s；这里统一 5s 重算参与者与自己的状态，定位 15s 一次。 */
    private func startRefreshLoop(): Unit {
        let _ = spawn {
            while (this.alive) {
                try {
                    this.refreshData()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[LocationViewPage] refresh failed: ${e}")
                }
                sleep(Duration.second * 5)
            }
        }
    }

    private func nowSeconds(): Int64 {
        return DateTime.now().toUnixTimeStamp().toSeconds()
    }

    private func refreshData(): Unit {
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        if (nowMs - this.lastUserFixMs > 15000) {
            let r = getCurrentDeviceLocation()
            if (r.success) {
                this.userOk = true
                this.userLat = r.latitude
                this.userLng = r.longitude
            }
            this.lastUserFixMs = nowMs
        }
        // 该会话里仍在进行中的实时位置（iOS topPeerActiveLiveLocationMessages）
        let list = ArrayList<Message>()
        let now = this.nowSeconds()
        let local = getMessageHistoryStore().loadRecentLocalMessages(this.peerId, 200, peerType: this.peerType)
        for (m in local) {
            if (!m.isLiveLocation) { continue }
            let active = m.liveLocationPeriod == LIVE_LOCATION_INDEFINITE_PERIOD ||
                (m.liveLocationPeriod > 0 && m.rawTimestamp + Int64(m.liveLocationPeriod) > now)
            if (active) {
                Hilog.info(0, "CjTelegram", "[LocationViewPage] live id=${m.id} sent=${m.isSent} sender=${m.senderId} period=${m.liveLocationPeriod} ts=${m.rawTimestamp} edit=${m.editDate}")
                list.add(m)
            }
        }
        let sessionId = match (getLiveLocationManagerService().getActiveMessageId(this.peerId)) {
            case Some(id) => Int64(id)
            case None => 0
        }
        Hilog.info(0, "CjTelegram", "[LocationViewPage] refresh local=${local.size} live=${list.size} session=${sessionId} userOk=${this.userOk}")
        let snapshot = list
        launch { this.pushState(snapshot) }
    }

    private func pushState(live: ArrayList<Message>): Unit {
        if (!this.alive) { return }
        let obj = JsonObject()
        obj.setString("peerType", this.peerType)
        obj.setInt("peerId", this.peerId)
        let subject = JsonObject()
        subject.setInt("msgId", this.msgId)
        subject.setString("lat", this.subjLat.toString())
        subject.setString("lng", this.subjLng.toString())
        subject.setBool("isLive", this.isLive)
        subject.setInt("period", this.period)
        subject.setInt("timestamp", this.timestamp)
        subject.setInt("editDate", this.editDate)
        subject.setBool("isSent", this.isSent)
        subject.setInt("senderId", this.senderId)
        subject.setString("senderName", this.senderName)
        subject.setString("title", this.title)
        subject.setString("venueTitle", this.venueTitle)
        subject.setString("venueAddress", this.venueAddress)
        obj.setObject("subject", subject)
        let user = JsonObject()
        user.setBool("ok", this.userOk)
        user.setString("lat", this.userLat.toString())
        user.setString("lng", this.userLng.toString())
        obj.setObject("user", user)
        // iOS 从该会话里自己的活跃实时消息推导“正在分享”；内存广播会话只是补充
        //（App 重启后会话丢失，但消息还在）。
        let own = JsonObject()
        var ownMsgId: Int64 = 0
        var ownBegin: Int64 = 0
        var ownPeriod: Int64 = 0
        match (getLiveLocationManagerService().getActiveMessageId(this.peerId)) {
            case Some(id) => ownMsgId = Int64(id)
            case None => ()
        }
        for (m in live) {
            if (m.isSent) {
                if (ownMsgId == 0) { ownMsgId = m.id }
                if (m.id == ownMsgId) {
                    ownBegin = m.rawTimestamp
                    ownPeriod = Int64(m.liveLocationPeriod)
                }
            }
        }
        this.ownLiveMsgId = ownMsgId
        own.setBool("active", ownMsgId > 0)
        own.setInt("msgId", ownMsgId)
        own.setInt("begin", ownBegin)
        own.setInt("period", ownPeriod)
        obj.setObject("own", own)
        let arr = JsonArray()
        let photos = getUserPhotoService()
        let chatList = getRealChatListService()
        let myId = getCurrentUserId()
        for (m in live) {
            let p = JsonObject()
            // 私聊里 TL from_id 常缺省（双向都可能为 0）：方向以 out 位为准——
            // 自己发的归自己；对方发的归会话对端。之前把 0 一律当自己，导致对方的
            // 实时位置被当成"自己"（不进列表、头像取错、底部不显示对方）。
            var uid = m.senderId
            if (m.isSent) {
                uid = myId
            } else if (uid <= 0 && this.peerType == "user") {
                uid = this.peerId
            }
            p.setInt("msgId", m.id)
            p.setInt("peerId", uid)
            p.setBool("isSelf", m.isSent || uid == myId)
            var name = m.senderName
            if (name.size == 0) {
                match (chatList.getCachedUser(uid)) {
                    case Some(u) => name = if (u.lastName.size > 0) { "${u.firstName} ${u.lastName}" } else { u.firstName }
                    case None => ()
                }
            }
            p.setString("name", name)
            p.setString("avatar", if (uid > 0) { photos.getUserPhotoPath(uid) } else { "" })
            p.setString("lat", m.locationLat.toString())
            p.setString("lng", m.locationLng.toString())
            p.setInt("heading", Int64(m.locationHeading))
            p.setInt("updated", if (m.editDate > 0) { m.editDate } else { m.rawTimestamp })
            p.setInt("begin", m.rawTimestamp)
            p.setInt("period", Int64(m.liveLocationPeriod))
            arr.addObject(p)
        }
        obj.setArray("participants", arr)
        obj.setInt("now", this.nowSeconds())
        callArk(LOCATION_VIEW_UPDATE, obj.toJsonString())
    }

    /** ArkTS 覆盖层动作（UI 线程投递）。 */
    private func handleAction(json: String): Unit {
        let obj = JsonParser.parseObject(json)
        let action = obj.getString("action")
        Hilog.info(0, "CjTelegram", "[LocationViewPage] action=${action}")
        if (action == "close") {
            routerPop()
        } else if (action == "stop") {
            // iOS interaction.stopLiveLocation → cancelLiveLocation(peerId) 然后 dismiss，无二次确认。
            // 无内存会话（重启后）时直接对自己的那条消息发 stop（messages.editMessage stopped）。
            let hasSession = getLiveLocationManagerService().getActiveMessageId(this.peerId).isSome()
            if (hasSession) {
                getLiveLocationManagerViewModel().cancelLiveLocation(this.peerId)
            } else if (this.ownLiveMsgId > 0) {
                let pt = this.peerType
                let pid = this.peerId
                let mid = this.ownLiveMsgId
                let _ = spawn {
                    try {
                        let _ = getRealMessageService().stopLiveLocation(pt, pid, Int32(mid))
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[LocationViewPage] stopLiveLocation failed: ${e}")
                    }
                }
            }
            routerPop()
        } else if (action == "startLive") {
            let seconds = obj.getInt("seconds")
            if (seconds > 0) {
                getLiveLocationManagerViewModel().startSharing(this.peerType, this.peerId, period: Int32(seconds))
                let _ = spawn {
                    sleep(Duration.second * 2)
                    try { this.refreshData() } catch (_: Exception) {}
                }
            }
        } else if (action == "openIn" || action == "share") {
            // iOS Open In…（Apple/Google Maps 等）→ 本机系统地图（Petal Maps）
            let lat = parseCoord(obj.getString("lat"))
            let lng = parseCoord(obj.getString("lng"))
            let t = obj.getString("title")
            let useLat = if (lat != 0.0 || lng != 0.0) { lat } else { this.subjLat }
            let useLng = if (lat != 0.0 || lng != 0.0) { lng } else { this.subjLng }
            getMapKitBridgeService().openSystemLocation(useLat, useLng, if (t.size > 0) { t } else { this.title }, { _ok: Bool => () })
        } else if (action == "refresh") {
            let _ = spawn { try { this.refreshData() } catch (_: Exception) {} }
        }
    }

    public func build() {
        // 界面在 ArkTS 层；本组件只是透明底，承担数据生命周期。
        Column {}
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(Color.Transparent)
            .onAppear({ => this.ensureLoaded() })
    }
}

func parseCoord(s: String): Float64 {
    if (s.size == 0) { return 0.0 }
    return try { Float64.parse(s) } catch (_: Exception) { 0.0 }
}
