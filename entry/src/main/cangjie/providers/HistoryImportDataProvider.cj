package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*

/**
 * HistoryImport 数据接口层 — 将 HistoryImportService API 结果转换为 UI ViewModel 可用的数据结构
 *
 * 对应 iOS 源：
 *   submodules/TelegramCore/Sources/TelegramEngine/HistoryImport/TelegramEngineHistoryImport.swift
 *
 * 职责：
 *   - 封装 HistoryImportService 调用，提供同步且 ViewModel 友好的结果对象
 *   - 把 TL 层的 Option<T> / Bool 转换成带错误描述的 ViewModel 结果枚举
 *   - 供 UI 层（页面 / ViewModel）直接使用，无需感知 MTProto 细节
 */

private var _historyImportDataProviderInstance: Option<HistoryImportDataProvider> = None

public func getHistoryImportDataProvider(): HistoryImportDataProvider {
    match (_historyImportDataProviderInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = HistoryImportDataProvider()
            _historyImportDataProviderInstance = Some(inst)
            return inst
    }
}

// ============================================================
// ViewModel 数据结构
// ============================================================

/**
 * 文件头解析的 ViewModel 结果，用于展示导入前的预览信息
 */
public class HistoryImportInfoViewModel {
    public var success: Bool = false
    public var chatKind: String = "unknown"
    public var chatTitle: String = ""
    public var errorMessage: String = ""

    public init(
        success!: Bool,
        chatKind!: String,
        chatTitle!: String,
        errorMessage!: String
    ) {
        this.success = success
        this.chatKind = chatKind
        this.chatTitle = chatTitle
        this.errorMessage = errorMessage
    }
}

/**
 * 对话导入可行性检查的 ViewModel 结果
 */
public class HistoryImportPeerViewModel {
    public var canImport: Bool = false
    public var requiresConfirmation: Bool = false
    public var confirmationText: String = ""
    public var errorMessage: String = ""

    public init(
        canImport!: Bool,
        requiresConfirmation!: Bool,
        confirmationText!: String,
        errorMessage!: String
    ) {
        this.canImport = canImport
        this.requiresConfirmation = requiresConfirmation
        this.confirmationText = confirmationText
        this.errorMessage = errorMessage
    }
}

/**
 * 完整导入操作的 ViewModel 结果
 */
public class HistoryImportResultViewModel {
    public var isSuccess: Bool = false
    public var phase: String = "idle"
    public var uploadedParts: Int32 = 0
    public var totalParts: Int32 = 0
    public var errorMessage: String = ""
    public var importId: Int64 = 0

    public init() {}
}

// ============================================================
// HistoryImportDataProvider
// ============================================================

public class HistoryImportDataProvider {

    /**
     * 解析导入文件头，返回 ViewModel 供 UI 展示预览信息。
     * 调用 HistoryImportService.checkImportInfo。
     */
    public func fetchImportInfo(importHead!: String): HistoryImportInfoViewModel {
        Hilog.info(0, "CjTelegram", "[HistoryImportDP] fetchImportInfo")

        let svc = getHistoryImportService()
        let resultOpt = svc.checkImportInfo(importHead: importHead)

        match (resultOpt) {
            case None =>
                return HistoryImportInfoViewModel(
                    success: false,
                    chatKind: "unknown",
                    chatTitle: "",
                    errorMessage: "Failed to parse import file"
                )
            case Some(info) =>
                return HistoryImportInfoViewModel(
                    success: true,
                    chatKind: info.kind,
                    chatTitle: info.title,
                    errorMessage: ""
                )
        }
    }

    /**
     * 检查目标对话是否允许导入，返回 ViewModel 供 UI 决策展示确认对话框。
     * 调用 HistoryImportService.checkPeerImport。
     */
    public func fetchPeerImportCheck(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String
    ): HistoryImportPeerViewModel {
        Hilog.info(0, "CjTelegram", "[HistoryImportDP] fetchPeerImportCheck")

        let svc = getHistoryImportService()
        let resultOpt = svc.checkPeerImport(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType
        )

        match (resultOpt) {
            case None =>
                return HistoryImportPeerViewModel(
                    canImport: false,
                    requiresConfirmation: false,
                    confirmationText: "",
                    errorMessage: "Import not allowed for this peer"
                )
            case Some(result) =>
                return HistoryImportPeerViewModel(
                    canImport: true,
                    requiresConfirmation: !result.isAllowed,
                    confirmationText: result.confirmText,
                    errorMessage: ""
                )
        }
    }

    /**
     * 执行完整导入流程，通过 onProgress 回调汇报 HistoryImportResultViewModel。
     * 调用链：HistoryImportService.checkPeerImport → initSession → uploadMedia* → startImport
     */
    public func runImport(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        fileData!: Array<Byte>,
        fileName!: String,
        mediaEntries!: Array<ChatImportMediaEntry>,
        onProgress!: (HistoryImportResultViewModel) -> Unit
    ): Unit {
        Hilog.info(0, "CjTelegram", "[HistoryImportDP] runImport start")

        let svc = getHistoryImportService()
        let vm = HistoryImportResultViewModel()

        let ok = svc.runFullImport(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType,
            fileData: fileData,
            fileName: fileName,
            mediaEntries: mediaEntries,
            onProgress: { progress: ImportProgress =>
                vm.phase = progress.phase
                vm.uploadedParts = progress.uploadedParts
                vm.totalParts = progress.totalParts
                vm.errorMessage = progress.errorMessage
                vm.importId = progress.importId
                vm.isSuccess = progress.success
                onProgress(vm)
            }
        )

        if (!ok && vm.errorMessage.isEmpty()) {
            vm.phase = "failed"
            vm.errorMessage = "Import failed"
            vm.isSuccess = false
            onProgress(vm)
        }

        Hilog.info(0, "CjTelegram", "[HistoryImportDP] runImport done")
    }
}
