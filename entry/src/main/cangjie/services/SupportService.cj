package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

private var _supportServiceInstance: Option<SupportService> = None

public func getSupportService(): SupportService {
    match (_supportServiceInstance) {
        case Some(instance) => instance
        case None =>
            let instance = SupportService()
            _supportServiceInstance = Some(instance)
            instance
    }
}

/** Resolves Telegram's account-specific support peer through help.getSupport. */
public class SupportService {
    public func getSupportPeer(): Option<ResolvedPeer> {
        try {
            let responseData = getMTProtoClient().sendRequest(HelpGetSupport().toBytes())
            if (responseData.size < 4) {
                return None
            }

            let d = TLDeserializer(responseData)
            let constructor = d.readUInt32()
            if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                let errorCode = d.readInt32()
                let errorMessage = d.readString()
                Hilog.info(0, "CjTelegram", "[SupportService] help.getSupport RPC error ${errorCode}: ${errorMessage}")
                return None
            }
            if (constructor != 0x17c6b5f6) {
                Hilog.info(0, "CjTelegram", "[SupportService] unexpected help.Support constructor ${constructor}")
                return None
            }

            let _ = d.readString()
            let user = UserResponse.deserializeBoxed(d)
            getRealChatListService().cacheUserResponse(user)

            let peer = ResolvedPeer()
            peer.peerType = "user"
            peer.peerId = user.id
            peer.accessHash = user.accessHash
            peer.displayName = "${user.firstName} ${user.lastName}".trimAscii()
            if (peer.displayName.size == 0) {
                peer.displayName = "Telegram Support"
            }
            peer.username = user.username
            return Some(peer)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SupportService] help.getSupport failed: ${e}")
            return None
        }
    }
}
