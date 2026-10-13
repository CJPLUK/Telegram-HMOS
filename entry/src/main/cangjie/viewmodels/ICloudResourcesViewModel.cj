package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*

/**
 * ICloudResourcesViewModel — iCloud 文件资源视图模型
 *
 * iOS 对应：ICloudResources.swift（结合 iCloudFileDescription / fetchICloudFileResource 信号层）
 *
 * 平台说明：
 *   iOS 的 SwiftSignalKit Signal 异步流在 HarmonyOS 上以 spawn + launch 替代，
 *   保持与其他 ViewModel（LocalMediaResourcesViewModel、MediaResourcesViewModel）
 *   一致的 @Observed / @Publish / spawn / launch 架构模式。
 *
 * 职责：
 *   - 异步加载本地文件描述（ICloudFileDescription 列表）
 *   - 异步读取文件数据字节（对应 iOS fetchICloudFileResource 的全文件模式）
 *   - 异步读取缩略图字节（对应 iOS fetchICloudFileResource 的 thumbnail=true 模式）
 *   - 向 UI 层暴露加载状态（isLoading）、文件描述列表（fileDescriptions）
 *
 * 调用链（完整）：
 *   UI 触发 loadFileDescription(localPath)
 *     → spawn 后台
 *       → ICloudResourcesService.describeLocalFile(localPath)
 *         → FileIo.stat(localPath) → ICloudFileDescription
 *     → launch 主线程 → 更新 @Publish fileDescriptions / isLoading
 *
 *   UI 触发 loadFileDescriptions(paths)
 *     → spawn 后台
 *       → ICloudResourcesService.describeLocalFiles(paths)
 *         → 批量 FileIo.stat → ArrayList<ICloudFileDescription>
 *     → launch 主线程 → 更新 @Publish fileDescriptions / isLoading
 *
 *   UI 触发 fetchFileData(urlData, onLoaded)
 *     → spawn 后台
 *       → ICloudResourcesService.fetchFileData(urlData)
 *         → decodeUrlDataToLocalPath(urlData) → FileIo.open → read → Array<Byte>
 *     → launch 主线程 → 回调 onLoaded(data)
 *
 *   UI 触发 fetchThumbnail(urlData, onLoaded)
 *     → spawn 后台
 *       → ICloudResourcesService.fetchThumbnailData(urlData)
 *         → 图片类型 → readLocalFile → Array<Byte>；音频/PDF → 空数组
 *     → launch 主线程 → 回调 onLoaded(data)
 *
 * 线程安全：
 *   所有 @Publish 变量赋值均在 launch {} 主线程执行（遵循修复 #64/S-64 规范）。
 *   spawn 返回值用 let _ = spawn { ... } 丢弃（遵循 R-69 规范）。
 */
@Observed
public class ICloudResourcesViewModel {

    /** 是否正在异步加载 */
    @Publish public var isLoading: Bool = false

    /** 已加载的文件描述列表 */
    @Publish public var fileDescriptions: ArrayList<ICloudFileDescription> = ArrayList<ICloudFileDescription>()

    /** 是否已完成首次加载 */
    @Publish public var hasLoaded: Bool = false

    /** 最近一次错误描述（空字符串 = 无错误）*/
    @Publish public var lastError: String = ""

    // ── 单文件描述加载 ────────────────────────────────────────────────────────

    /**
     * 异步加载单个本地文件的描述信息
     *
     * 对应 iOS iCloudFileDescription(_ url: URL) Signal 订阅入口：
     *   Signal 发出 ICloudFileDescription? 等效为 callback onLoaded(Option<ICloudFileDescription>)
     *
     * @param localPath 本地文件绝对路径
     * @param onLoaded  主线程回调，参数为 ICloudFileDescription Option（加载失败为 None）
     */
    public func loadFileDescription(
        localPath: String,
        onLoaded!: (Option<ICloudFileDescription>) -> Unit = { _desc: Option<ICloudFileDescription> => }
    ): Unit {
        if (localPath.size == 0) {
            onLoaded(None)
            return
        }
        Hilog.info(0, "CjTelegram", "[ICloudResVM] loadFileDescription: path=${localPath}")
        let pathCopy = localPath
        let _ = spawn {
            let svc = getICloudResourcesService()
            let descOpt = svc.describeLocalFile(pathCopy)
            launch {
                onLoaded(descOpt)
            }
        }
    }

    // ── 批量文件描述加载 ──────────────────────────────────────────────────────

    /**
     * 异步批量加载多个本地文件的描述信息，结果写入 @Publish fileDescriptions
     *
     * 对应 iOS 批量调用 iCloudFileDescription() Signal 并收集结果：
     *   多个 Signal 合并 → 等效为 describeLocalFiles 批量同步 + 单次 launch 更新
     *
     * @param localPaths 本地文件路径列表
     */
    public func loadFileDescriptions(localPaths: ArrayList<String>): Unit {
        if (this.isLoading) {
            Hilog.info(0, "CjTelegram", "[ICloudResVM] loadFileDescriptions: already loading")
            return
        }
        this.isLoading = true
        this.lastError = ""
        Hilog.info(0, "CjTelegram", "[ICloudResVM] loadFileDescriptions: count=${localPaths.size}")
        let pathsCopy = localPaths
        let _ = spawn {
            let svc = getICloudResourcesService()
            let descriptions = svc.describeLocalFiles(pathsCopy)
            launch {
                this.fileDescriptions = descriptions
                this.isLoading = false
                this.hasLoaded = true
                Hilog.info(0, "CjTelegram", "[ICloudResVM] loadFileDescriptions: loaded ${descriptions.size}")
            }
        }
    }

    // ── 文件数据获取 ──────────────────────────────────────────────────────────

    /**
     * 异步读取文件原始字节数据
     *
     * 对应 iOS fetchICloudFileResource(resource: ICloudFileResource) Signal（thumbnail=false 分支）：
     *   Signal<EngineMediaResourceDataFetchResult> → 等效为 onLoaded(Array<Byte>) 回调
     *
     * 调用链：
     *   fetchFileData(urlData, onLoaded)
     *     → ICloudResourcesService.fetchFileData(urlData)
     *       → decodeUrlDataToLocalPath(urlData) → FileIo.open → read → Array<Byte>
     *     → launch { onLoaded(data) }
     *
     * @param urlData  base64 编码的本地文件路径（由 ICloudFileDescription.urlData 提供）
     * @param onLoaded 主线程回调，参数为文件字节数组（读取失败时为空数组）
     */
    public func fetchFileData(
        urlData: String,
        onLoaded!: (Array<Byte>) -> Unit = { _data: Array<Byte> => }
    ): Unit {
        if (urlData.size == 0) {
            onLoaded(Array<Byte>(0, repeat: 0))
            return
        }
        Hilog.info(0, "CjTelegram", "[ICloudResVM] fetchFileData: urlData len=${urlData.size}")
        let urlDataCopy = urlData
        let _ = spawn {
            let svc = getICloudResourcesService()
            let data = svc.fetchFileData(urlDataCopy)
            launch {
                onLoaded(data)
            }
        }
    }

    // ── 缩略图获取 ────────────────────────────────────────────────────────────

    /**
     * 异步读取文件缩略图字节数据
     *
     * 对应 iOS fetchICloudFileResource(resource: ICloudFileResource) Signal（thumbnail=true 分支）：
     *   - 图片文件：读取原图数据（HarmonyOS 降级：不做 256x256 缩放）
     *   - 音频文件：HarmonyOS 平台缺口，返回空数组（iOS 使用 AVFoundation 提取专辑封面）
     *   - PDF 文件：HarmonyOS 平台缺口，返回空数组（iOS 使用 generatePdfPreviewImage）
     *
     * 调用链：
     *   fetchThumbnail(urlData, onLoaded)
     *     → ICloudResourcesService.fetchThumbnailData(urlData)
     *       → 图片类型 → readLocalFile → Array<Byte>；音频/PDF → 空数组
     *     → launch { onLoaded(data) }
     *
     * @param urlData  base64 编码的本地文件路径
     * @param onLoaded 主线程回调，参数为缩略图字节数组（空数组表示不支持或读取失败）
     */
    public func fetchThumbnail(
        urlData: String,
        onLoaded!: (Array<Byte>) -> Unit = { _data: Array<Byte> => }
    ): Unit {
        if (urlData.size == 0) {
            onLoaded(Array<Byte>(0, repeat: 0))
            return
        }
        Hilog.info(0, "CjTelegram", "[ICloudResVM] fetchThumbnail: urlData len=${urlData.size}")
        let urlDataCopy = urlData
        let _ = spawn {
            let svc = getICloudResourcesService()
            let data = svc.fetchThumbnailData(urlDataCopy)
            launch {
                onLoaded(data)
            }
        }
    }

    // ── 通过 urlData 获取文件描述 ─────────────────────────────────────────────

    /**
     * 通过 urlData 异步获取文件描述
     *
     * 对应 iOS iCloudFileDescription(_ url: URL) 中先解析书签、再描述文件的完整流程：
     *   Data(base64Encoded:) + URL(resolvingBookmarkData:) + descriptionWithUrl(_:)
     *   → 等效：decodeUrlDataToLocalPath + describeLocalFile
     *
     * @param urlData  base64 编码的本地文件路径
     * @param onLoaded 主线程回调（成功为 Some(desc)，失败为 None）
     */
    public func loadDescriptionByUrlData(
        urlData: String,
        onLoaded!: (Option<ICloudFileDescription>) -> Unit = { _desc: Option<ICloudFileDescription> => }
    ): Unit {
        if (urlData.size == 0) {
            onLoaded(None)
            return
        }
        Hilog.info(0, "CjTelegram", "[ICloudResVM] loadDescriptionByUrlData: urlData len=${urlData.size}")
        let urlDataCopy = urlData
        let _ = spawn {
            let svc = getICloudResourcesService()
            let descOpt = svc.getFileDescription(urlDataCopy)
            launch {
                onLoaded(descOpt)
            }
        }
    }
}
