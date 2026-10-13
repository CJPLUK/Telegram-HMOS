package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.*

/**
 * Legacy UI 兼容层服务 (LEGUI-API-1)
 *
 * iOS 参考：submodules/LegacyUI/Sources/LegacyController.swift
 *           submodules/LegacyUI/Sources/LegacyEmptyController.swift
 *
 * 职责：
 *   - 管理 Legacy UI 容器的呈现模式（custom / modal / navigation）
 *   - 生命周期状态跟踪（onAppear / onDisappear / onLayout）
 *   - 提供容器初始化与重置 API
 *   - loadContainerContext(): 拉取会话列表为容器提供上下文
 *     调用链: LegacyService.loadContainerContext()
 *             → getRealChatListService().getDialogs()
 *             → getMTProtoClient().sendRequest()
 */

public enum LegacyPresentationMode {
    | Custom
    | Modal
    | Navigation
}

private var _legacyServiceInstance: Option<LegacyService> = None

public func getLegacyService(): LegacyService {
    match (_legacyServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = LegacyService()
            _legacyServiceInstance = Some(inst)
            return inst
    }
}

public class LegacyService {
    private var _mode: LegacyPresentationMode = LegacyPresentationMode.Custom
    private var _isAppeared: Bool = false
    private var _isLayoutValid: Bool = false
    private var _containerTitle: String = ""
    private var _dialogCount: Int32 = 0

    public func initialize(mode!: LegacyPresentationMode, title!: String): Unit {
        this._mode = mode
        this._containerTitle = title
        this._isAppeared = false
        this._isLayoutValid = false
        Hilog.info(0, "CjTelegram", "[LegacyService] initialize mode=${this.modeLabel()} title=${title}")
    }

    /**
     * 加载容器上下文：拉取会话列表，为 legacy 容器提供真实数据上下文。
     *
     * 调用链:
     *   LegacyService.loadContainerContext()
     *     -> getRealChatListService().getDialogs(limit: 5, folderId: 0)
     *     -> getMTProtoClient().sendRequest(MessagesGetDialogs.toBytes())
     *
     * 返回已加载的对话数量（0 表示未登录或网络错误）。
     */
    public func loadContainerContext(): Int32 {
        Hilog.info(0, "CjTelegram", "[LegacyService] loadContainerContext: fetching dialogs for container context")
        let chatService = getRealChatListService()
        let dialogs: ArrayList<Chat> = chatService.getDialogs(limit: 5, offsetDate: 0, folderId: 0)
        let count = Int32(dialogs.size)
        this._dialogCount = count
        Hilog.info(0, "CjTelegram", "[LegacyService] loadContainerContext: loaded ${count} dialogs")
        return count
    }

    public func onContainerAppear(): Unit {
        this._isAppeared = true
        Hilog.info(0, "CjTelegram", "[LegacyService] onContainerAppear")
    }

    public func onContainerDisappear(): Unit {
        this._isAppeared = false
        Hilog.info(0, "CjTelegram", "[LegacyService] onContainerDisappear")
    }

    public func onLayoutReady(): Unit {
        this._isLayoutValid = true
        Hilog.info(0, "CjTelegram", "[LegacyService] onLayoutReady")
    }

    public func reset(): Unit {
        this._isAppeared = false
        this._isLayoutValid = false
        this._containerTitle = ""
        this._mode = LegacyPresentationMode.Custom
        this._dialogCount = 0
        Hilog.info(0, "CjTelegram", "[LegacyService] reset")
    }

    public func isAppeared(): Bool {
        return this._isAppeared
    }

    public func isLayoutValid(): Bool {
        return this._isLayoutValid
    }

    public func getMode(): LegacyPresentationMode {
        return this._mode
    }

    public func getContainerTitle(): String {
        return this._containerTitle
    }

    public func getDialogCount(): Int32 {
        return this._dialogCount
    }

    private func modeLabel(): String {
        match (this._mode) {
            case Custom => return "custom"
            case Modal => return "modal"
            case Navigation => return "navigation"
        }
    }
}
