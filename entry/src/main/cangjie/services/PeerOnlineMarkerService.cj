package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

/**
 * 在线标记数据服务 (Phase PONMN)
 *
 * 对应 Telegram-iOS PeerOnlineMarkerNode
 * 维护一个已知在线 peer ID 集合（由 ViewModel 在收到 updateUserStatus 推送时写入）
 * 本 feature 为纯渲染层，无 MTProto 直接调用——在线状态通过现有
 * ChatRoomViewModel / 消息轮询的 updateUserStatus 更新流获取。
 */
private var _peerOnlineMarkerServiceInstance: Option<PeerOnlineMarkerService> = None

public func getPeerOnlineMarkerService(): PeerOnlineMarkerService {
    match (_peerOnlineMarkerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PeerOnlineMarkerService()
            _peerOnlineMarkerServiceInstance = Some(inst)
            return inst
    }
}

public class PeerOnlineMarkerService {
    private var _onlinePeerIds: Array<Int64> = Array<Int64>(0, { _i: Int64 => Int64(0) })
    private var _onlineCount: Int64 = 0

    /**
     * 将 peer 标记为在线
     * 由 ViewModel 在收到 updateUserStatus(online=true) 推送时调用
     */
    public func setOnline(peerId: Int64): Unit {
        if (!this.isOnline(peerId)) {
            let newArr = Array<Int64>(this._onlineCount + 1, { i: Int64 =>
                if (i < this._onlineCount) {
                    this._onlinePeerIds[i]
                } else {
                    peerId
                }
            })
            this._onlinePeerIds = newArr
            this._onlineCount = this._onlineCount + 1
            Hilog.info(0, "CjTelegram", "[PeerOnlineMarkerService] setOnline", [])
        }
    }

    /**
     * 将 peer 标记为离线
     * 由 ViewModel 在收到 updateUserStatus(online=false) 推送时调用
     */
    public func setOffline(peerId: Int64): Unit {
        var newCount: Int64 = 0
        for (i in 0..this._onlineCount) {
            if (this._onlinePeerIds[i] != peerId) {
                newCount = newCount + 1
            }
        }
        if (newCount == this._onlineCount) {
            return
        }
        let newArr = Array<Int64>(newCount, { _i: Int64 => Int64(0) })
        var writeIdx: Int64 = 0
        for (i in 0..this._onlineCount) {
            if (this._onlinePeerIds[i] != peerId) {
                newArr[writeIdx] = this._onlinePeerIds[i]
                writeIdx = writeIdx + 1
            }
        }
        this._onlinePeerIds = newArr
        this._onlineCount = newCount
        Hilog.info(0, "CjTelegram", "[PeerOnlineMarkerService] setOffline", [])
    }

    /**
     * 查询指定 peer 是否在线
     *
     * @param peerId Telegram 用户 ID
     * @return true 表示在线，false 表示离线或未知
     */
    public func isOnline(peerId: Int64): Bool {
        for (i in 0..this._onlineCount) {
            if (this._onlinePeerIds[i] == peerId) {
                return true
            }
        }
        return false
    }

    /**
     * 清空所有在线记录（登出或重连时调用）
     */
    public func clearAll(): Unit {
        this._onlinePeerIds = Array<Int64>(0, { _i: Int64 => Int64(0) })
        this._onlineCount = 0
    }
}
