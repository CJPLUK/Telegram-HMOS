package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.components.{ImageViewer, ImageItem, VideoPlayer, VideoData, getVoicePlayerManager}
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.utils.{isWhitelistedUrl, decodeTinyThumbnailToDataUrl}
import std.convert.*
import ohos.resource.__GenerateResource__
import kit.CoreFileKit.*
import kit.AbilityKit.{Want, Flags}
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

// SharedMediaPage — 共享媒体分类浏览页（混合工程迁移版）
//
// iOS 对应: PeerInfoScreen 的 PeerInfoPaneContainerNode（PeerInfo.PaneMedia / PaneFiles / PaneLinks /
//   PaneVoiceAndVideo / PaneAudio / PaneGifs），过滤器分别为 InputMessagesFilterPhotos+Video / Document /
//   Url / Voice / Music / Gif。
//
// S4-35..40 / S4-39：
//   - 每个 tab 的条目都可点：Media 打开查看器（图片 ImageViewer / 视频 VideoPlayer）；Files 下载后交系统打开；
//     Links 打开链接；Voice / Audio 用 VoicePlayerManager 播放；GIF 下载后全屏循环播放。
//   - 网格显示真实缩略图：先用 TL 内嵌的 stripped 缩略图垫底，再按 iOS 的 "m" 尺寸拉取真实缩略图。
//
// 线程规则(S-001): spawn { ... } 包异步调用; launch { ... } 回到 UI 线程写 @State

// ─── Tab 索引常量 ─────────────────────────────────────────────────────────────

private let TAB_MEDIA: Int32 = 0
private let TAB_FILES: Int32 = 1
private let TAB_LINKS: Int32 = 2
private let TAB_VOICE: Int32 = 3
private let TAB_AUDIO: Int32 = 4
private let TAB_GIFS:  Int32 = 5

private let SHARED_MEDIA_FILE_URI_BUNDLE: String = "com.hmcangjie.telegram"

// ─── SharedMediaPage ─────────────────────────────────────────────────────────

@HybridComponentEntry
@Component
public class SharedMediaPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 当前活跃 tab 索引 (对应 Tabs onChange index: Int32)
    @State var currentTabIndex: Int32 = TAB_MEDIA
    @State var initialTabIndex: Int32 = TAB_MEDIA

    // 各 tab 的数据列表（messages.search 结果经 RealMessageService.parseMessages 转成 Message）
    @State var mediaItems: ArrayList<Message> = ArrayList<Message>()
    @State var fileItems: ArrayList<Message> = ArrayList<Message>()
    @State var linkItems: ArrayList<Message> = ArrayList<Message>()
    @State var voiceItems: ArrayList<Message> = ArrayList<Message>()
    @State var audioItems: ArrayList<Message> = ArrayList<Message>()
    @State var gifItems: ArrayList<Message> = ArrayList<Message>()

    // 各 tab 加载状态
    @State var mediaLoading: Bool = false
    @State var fileLoading: Bool = false
    @State var linkLoading: Bool = false
    @State var voiceLoading: Bool = false
    @State var audioLoading: Bool = false
    @State var gifLoading: Bool = false

    // 缩略图路径（messageId → file:// 或 data: URL）；下载完成后重新赋值触发重绘
    @State var thumbPaths: HashMap<Int64, String> = HashMap<Int64, String>()
    // 正在下载真身 / 正在播放的条目
    @State var busyMessageId: Int64 = 0
    @State var playingMessageId: Int64 = 0

    // 查看器覆盖层
    @State var showImageViewer: Bool = false
    @State var imageViewerImages: ArrayList<ImageItem> = ArrayList<ImageItem>()
    @State var imageViewerIndex: Int64 = 0
    @State var showVideoPlayer: Bool = false
    @State var videoPlayerData: VideoData = VideoData()
    @State var showGifOverlay: Bool = false
    @State var gifOverlayPath: String = ""
    @State var gifOverlayIsVideo: Bool = true

    @State var toastMessage: String = ""
    @State var showToast: Bool = false
    private var toastGeneration: Int64 = 0
    @State var pageHeightVp: Float64 = 0.0

    @State var loaded: Bool = false

    // ─── 生命周期 ────────────────────────────────────────────────────────────

    // 目标 peer：显式参数 "{peerType}:{peerId}[:{tab}]" 优先，否则为当前选中会话。
    private var peerType: String = ""
    private var peerId: Int64 = 0
    private var loadedTabs: HashMap<Int32, Bool> = HashMap<Int32, Bool>()

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("SharedMediaPage")
        let parts = raw.split(":")
        if (parts.size >= 2) {
            this.peerType = parts[0]
            this.peerId = try { Int64.parse(parts[1]) } catch (_: Exception) { 0 }
        }
        if (parts.size >= 3) {
            let tab = try { Int32.parse(parts[2]) } catch (_: Exception) { Int32(0) }
            if (tab >= TAB_MEDIA && tab <= TAB_GIFS) {
                this.initialTabIndex = tab
                this.currentTabIndex = tab
            }
        }
        if (this.peerId == 0) {
            this.peerType = getSelectedChatPeerType()
            this.peerId = getSelectedChatId()
        }
        getVoicePlayerManager().setOnFinished({ finishedId: Int64 =>
            launch {
                if (this.playingMessageId == finishedId) { this.playingMessageId = 0 }
            }
        })
        this.loadTabData(this.currentTabIndex)
    }

    // ─── 数据加载 ────────────────────────────────────────────────────────────

    private func loadTabData(tabIndex: Int32): Unit {
        if (this.loadedTabs.contains(tabIndex)) { return }
        this.loadedTabs[tabIndex] = true
        let peerType = this.peerType
        let peerId = this.peerId

        if (tabIndex == TAB_MEDIA) {
            this.mediaLoading = true
            let _ = spawn {
                let combined = this.fetchItems(peerType, peerId, InputMessagesFilterPhotoVideo(), "media")
                launch {
                    this.mediaItems = combined
                    this.mediaLoading = false
                }
                this.downloadThumbnails(combined)
            }
        } else if (tabIndex == TAB_FILES) {
            this.fileLoading = true
            let _ = spawn {
                let items = this.fetchItems(peerType, peerId, InputMessagesFilterDocument(), "document")
                launch {
                    this.fileItems = items
                    this.fileLoading = false
                }
            }
        } else if (tabIndex == TAB_LINKS) {
            this.linkLoading = true
            let _ = spawn {
                let items = this.fetchItems(peerType, peerId, InputMessagesFilterUrl(), "link")
                launch {
                    this.linkItems = items
                    this.linkLoading = false
                }
            }
        } else if (tabIndex == TAB_VOICE) {
            this.voiceLoading = true
            let _ = spawn {
                let items = this.fetchItems(peerType, peerId, InputMessagesFilterVoice(), "voice")
                launch {
                    this.voiceItems = items
                    this.voiceLoading = false
                }
            }
        } else if (tabIndex == TAB_AUDIO) {
            this.audioLoading = true
            let _ = spawn {
                let items = this.fetchItems(peerType, peerId, InputMessagesFilterMusic(), "audio")
                launch {
                    this.audioItems = items
                    this.audioLoading = false
                }
            }
        } else if (tabIndex == TAB_GIFS) {
            this.gifLoading = true
            let _ = spawn {
                let items = this.fetchItems(peerType, peerId, InputMessagesFilterGif(), "gif")
                launch {
                    this.gifItems = items
                    this.gifLoading = false
                }
                this.downloadThumbnails(items)
            }
        }
    }

    // 按过滤器拉取媒体历史并转换为 Message 列表（最新在前）
    private func fetchItems(peerType: String, peerId: Int64, filter: TLObject, kind: String): ArrayList<Message> {
        let result = ArrayList<Message>()
        try {
            let msgSvc = getRealMessageService()
            let response = msgSvc.searchMessages(peerType, peerId, "", filter, Int32(60))
            let parsed = msgSvc.parseMessages(response, getCurrentUserId(), HashMap<Int64, String>(),
                conversationPeerType: peerType, conversationPeerId: peerId)
            var i = parsed.size - 1
            while (i >= 0) {
                let m = parsed[i]
                if (kind == "media") {
                    if (m.photoId != 0 || m.documentId != 0) { result.add(m) }
                } else if (kind == "link") {
                    result.add(m)
                } else if (m.documentId != 0) {
                    result.add(m)
                }
                i -= 1
            }
            Hilog.info(0, "CjTelegram", "[SharedMediaPage] fetchItems(${kind}) → ${result.size} items")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SharedMediaPage] fetchItems(${kind}) error: ${e}")
        }
        return result
    }

    // ─── 缩略图 ──────────────────────────────────────────────────────────────

    private func isPhoto(m: Message): Bool { return m.photoId != 0 }

    private func strippedThumbFor(m: Message): String {
        if (m.documentThumbnailPath.size > 0) { return m.documentThumbnailPath }
        if (m.strippedThumb.size > 0) { return decodeTinyThumbnailToDataUrl(m.strippedThumb) }
        return ""
    }

    /** 网格格子当前可用的缩略图：已下载的 "m" 尺寸 → 内嵌 stripped 缩略图 → 空 */
    private func thumbFor(m: Message): String {
        match (this.thumbPaths.get(m.id)) {
            case Some(p) => return p
            case None => return this.strippedThumbFor(m)
        }
    }

    /** 与 ChatRoomViewModel 相同的落盘位置（photos/photo_<id>_m.jpg、thumbs/thumb_<docId>.jpg），缓存共享。 */
    private func downloadThumbnails(items: ArrayList<Message>): Unit {
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return }
        let photoDir = filesDir + "/photos"
        let thumbDir = filesDir + "/thumbs"
        try { FileIo.mkdir(photoDir) } catch (_e: Exception) {}
        try { FileIo.mkdir(thumbDir) } catch (_e: Exception) {}
        let downloadService = getFileDownloadService()
        var count = 0
        for (m in items) {
            if (count >= 45) { break }
            count += 1
            var path = ""
            try {
                if (m.photoId != 0) {
                    path = photoDir + "/photo_${m.photoId}_m.jpg"
                    if (!fileExists(path)) {
                        let bytes = downloadService.downloadPhoto(m.photoId, m.photoAccessHash, m.photoFileReference, thumbSize: "m")
                        if (bytes.size > 0) { writeFile(path, bytes) } else { path = "" }
                    }
                } else if (m.documentId != 0) {
                    path = thumbDir + "/thumb_${m.documentId}.jpg"
                    if (!fileExists(path)) {
                        let bytes = downloadService.downloadDocumentThumb(m.documentId, m.documentAccessHash,
                            m.documentFileReference, thumbSize: "m", dcId: m.documentDcId)
                        if (bytes.size > 0) { writeFile(path, bytes) } else { path = "" }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SharedMediaPage] thumb download failed for msg ${m.id}: ${e}")
                path = ""
            }
            if (path.size > 0) {
                let uri = "file://" + path
                let msgId = m.id
                launch {
                    let updated = HashMap<Int64, String>()
                    for ((k, v) in this.thumbPaths) { updated[k] = v }
                    updated[msgId] = uri
                    this.thumbPaths = updated
                }
            }
        }
    }

    // ─── 打开条目 ────────────────────────────────────────────────────────────

    /** Media 格子：图片 → ImageViewer（先用缩略图打开，后台换全分辨率）；视频 → 下载后 VideoPlayer */
    private func openMediaItem(m: Message): Unit {
        if (this.isPhoto(m)) {
            let images = ArrayList<ImageItem>()
            var targetIndex: Int64 = 0
            var idx: Int64 = 0
            for (it in this.mediaItems) {
                if (!this.isPhoto(it)) { continue }
                let cached = this.cachedFullResPhotoPath(it)
                let url = if (cached.size > 0) { cached } else { this.thumbFor(it) }
                if (url.size == 0) { continue }
                images.add(ImageItem(url: url, photoId: it.photoId, caption: it.content, senderName: it.senderName,
                    timeText: it.time, msgId: it.id))
                if (it.id == m.id) { targetIndex = idx }
                idx += 1
            }
            if (images.isEmpty()) { return }
            this.imageViewerImages = images
            this.imageViewerIndex = targetIndex
            this.showImageViewer = true
            Hilog.info(0, "CjTelegram", "[SharedMediaPage] ImageViewer: ${images.size} photos, index=${targetIndex}")
            let target = m
            let _ = spawn {
                let fullUri = this.downloadFullResPhoto(target)
                if (fullUri.size > 0) {
                    let photoId = target.photoId
                    launch {
                        for (img in this.imageViewerImages) {
                            if (img.photoId == photoId) { img.url = fullUri }
                        }
                    }
                }
            }
            return
        }
        if (m.documentId == 0) { return }
        if (this.busyMessageId == m.id) { return }
        this.busyMessageId = m.id
        let thumb = this.thumbFor(m)
        let duration = m.videoDuration
        let caption = m.content
        let target = m
        let _ = spawn {
            let uri = this.downloadVideoForPlayback(target)
            launch {
                this.busyMessageId = 0
                if (uri.size == 0) {
                    this.showToastMsg("Could not download video")
                    return
                }
                this.videoPlayerData = VideoData(url: uri, duration: duration, thumbnailUrl: thumb, caption: caption)
                this.showVideoPlayer = true
                Hilog.info(0, "CjTelegram", "[SharedMediaPage] VideoPlayer opened with: ${uri}")
            }
        }
    }

    private func cachedFullResPhotoPath(m: Message): String {
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty() || m.photoId == 0) { return "" }
        let photoDir = filesDir + "/photos"
        let sizeType = if (m.photoLargestType.size > 0) { m.photoLargestType } else { "y" }
        for (t in [sizeType, "y", "x"]) {
            let p = photoDir + "/photo_${m.photoId}_${t}.jpg"
            if (fileExists(p)) { return "file://" + p }
        }
        return ""
    }

    /** 同 ChatRoomViewModel.downloadFullResPhoto：最大尺寸变体落到 photos/photo_<id>_<type>.jpg */
    private func downloadFullResPhoto(m: Message): String {
        let cached = this.cachedFullResPhotoPath(m)
        if (cached.size > 0) { return cached }
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return "" }
        let photoDir = filesDir + "/photos"
        try { FileIo.mkdir(photoDir) } catch (_e: Exception) {}
        let sizeType = if (m.photoLargestType.size > 0) { m.photoLargestType } else { "y" }
        let path = photoDir + "/photo_${m.photoId}_${sizeType}.jpg"
        try {
            let bytes = getFileDownloadService().downloadPhoto(m.photoId, m.photoAccessHash, m.photoFileReference, thumbSize: sizeType)
            if (bytes.size > 0) {
                writeFile(path, bytes)
                return "file://" + path
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SharedMediaPage] full-res photo download failed: ${e}")
        }
        return ""
    }

    /** 同 ChatRoomViewModel.downloadVideoForPlayback：videos/video_<docId>.mp4 */
    private func downloadVideoForPlayback(m: Message): String {
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return "" }
        let videoDir = filesDir + "/videos"
        try { FileIo.mkdir(videoDir) } catch (_e: Exception) {}
        let path = videoDir + "/video_${m.documentId}.mp4"
        if (fileExists(path) && fileSizeOf(path) >= m.documentSize) { return "file://" + path }
        return this.downloadDocumentTo(m, path)
    }

    private func downloadDocumentTo(m: Message, path: String): String {
        try {
            Hilog.info(0, "CjTelegram", "[SharedMediaPage] Downloading document id=${m.documentId} size=${m.documentSize} → ${path}")
            let bytes = getFileDownloadService().downloadDocument(m.documentId, m.documentAccessHash, m.documentFileReference,
                m.documentDcId, fileSize: m.documentSize)
            if (bytes.size > 0) {
                writeFile(path, bytes)
                return "file://" + path
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SharedMediaPage] document download failed: ${e}")
        }
        return ""
    }

    private func documentExtension(m: Message, fallback: String): String {
        if (m.documentFileName.size > 0) {
            let parts = m.documentFileName.split(".")
            if (parts.size > 1) { return "." + parts[parts.size - 1] }
        }
        return fallback
    }

    /** Files 行：下载到 documents/ 后交系统打开（iOS：fetched file → document preview） */
    private func openFileItem(m: Message): Unit {
        if (m.documentId == 0 || this.busyMessageId == m.id) { return }
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return }
        let docDir = filesDir + "/documents"
        try { FileIo.mkdir(docDir) } catch (_e: Exception) {}
        let safeName = if (m.documentFileName.size > 0) { m.documentFileName.replace("/", "_") } else { "file_${m.documentId}" }
        let path = docDir + "/${m.documentId}_${safeName}"
        let mime = m.documentMimeType
        if (fileExists(path) && fileSizeOf(path) >= m.documentSize) {
            this.openFileWithSystem("file://" + path, mime)
            return
        }
        this.busyMessageId = m.id
        let target = m
        let _ = spawn {
            let uri = this.downloadDocumentTo(target, path)
            launch {
                this.busyMessageId = 0
                if (uri.size == 0) {
                    this.showToastMsg("Could not download file")
                    return
                }
                this.openFileWithSystem(uri, mime)
            }
        }
    }

    /** 使用系统应用打开文件（同 ChatRoomPage.openFileWithSystem：bundle-authority file URI + viewData） */
    private func openFileWithSystem(fileUri: String, mimeType: String): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let utdType = this.mimeToUtdType(mimeType)
                let path = if (fileUri.startsWith("file://")) { fileUri[7..fileUri.size] } else { fileUri }
                let shareUri = if (path.startsWith("/")) { "file://" + SHARED_MEDIA_FILE_URI_BUNDLE + path } else { fileUri }
                let want = Want(
                    flags: Flags.FLAG_AUTH_READ_URI_PERMISSION,
                    uri: shareUri,
                    action: "ohos.want.action.viewData",
                    dataType: utdType
                )
                try {
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[SharedMediaPage] startAbility: ${shareUri} (${utdType})")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[SharedMediaPage] openFile failed: ${e}")
                    this.showToastMsg("No app can open this file")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[SharedMediaPage] No context for openFile")
        }
    }

    private func mimeToUtdType(mime: String): String {
        if (mime.contains("pdf")) { return "general.pdf" }
        if (mime.contains("image")) { return "general.image" }
        if (mime.contains("video")) { return "general.video" }
        if (mime.contains("audio")) { return "general.audio" }
        if (mime.contains("text")) { return "general.plain-text" }
        if (mime.contains("zip") || mime.contains("rar") || mime.contains("7z")) { return "general.archive" }
        if (mime.contains("word") || mime.contains("doc")) { return "general.composite-content" }
        if (mime.contains("sheet") || mime.contains("xls")) { return "general.composite-content" }
        if (mime.contains("presentation") || mime.contains("ppt")) { return "general.composite-content" }
        return "general.object"
    }

    /** Links 行：同 ChatRoomPage.openWebUrl —— 应用内浏览器或系统浏览器 */
    private func openLinkItem(m: Message): Unit {
        let url = this.linkUrl(m)
        if (url.size == 0) { return }
        if (!isWhitelistedUrl(url)) {
            Hilog.info(0, "CjTelegram", "[SharedMediaPage] openWebUrl blocked unsafe scheme: ${url}")
            return
        }
        if (getBrowserService().isBotWebAppUrl(url)) {
            routerPush("WebAppPage", url)
            return
        }
        let (norm, mode) = getBrowserService().resolveUrl(url)
        match (mode) {
            case BrowserMode.InApp =>
                Hilog.info(0, "CjTelegram", "[SharedMediaPage] openWebUrl InApp → BrowserScreen: ${norm}")
                getBrowserTabRegistry().updateActiveTab(norm, "")
                routerPush("BrowserScreen", norm)
            case BrowserMode.External =>
                match (getGlobalAbilityContext()) {
                    case Some(ctx) =>
                        let want = Want(action: "ohos.want.action.viewData", uri: norm)
                        try {
                            ctx.startAbility(want)
                            Hilog.info(0, "CjTelegram", "[SharedMediaPage] openWebUrl External: ${norm}")
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[SharedMediaPage] openWebUrl failed: ${e}")
                        }
                    case None =>
                        Hilog.info(0, "CjTelegram", "[SharedMediaPage] No context for openWebUrl")
                }
        }
    }

    /** 链接行的网址：网页预览 url，否则从消息正文里取第一个 http(s):// 片段 */
    private func linkUrl(m: Message): String {
        if (m.webPageUrl.size > 0) { return m.webPageUrl }
        return firstUrlInText(m.content)
    }

    /** Voice / Audio 行：下载后交 VoicePlayerManager（与会话页语音气泡同一播放器）；再点切换暂停 */
    private func playAudioItem(m: Message, isVoice: Bool): Unit {
        if (m.documentId == 0) { return }
        let player = getVoicePlayerManager()
        if (player.currentMessageId == m.id) {
            player.play(m.id, "", m.audioDuration)
            this.playingMessageId = if (player.isPlaying(m.id)) { m.id } else { 0 }
            return
        }
        if (this.busyMessageId == m.id) { return }
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return }
        let dir = if (isVoice) { filesDir + "/voices" } else { filesDir + "/documents" }
        try { FileIo.mkdir(dir) } catch (_e: Exception) {}
        let path = if (isVoice) {
            dir + "/voice_${m.documentId}" + this.documentExtension(m, ".ogg")
        } else {
            dir + "/audio_${m.documentId}" + this.documentExtension(m, ".mp3")
        }
        let msgId = m.id
        let duration = m.audioDuration
        if (fileExists(path) && fileSizeOf(path) > 0) {
            player.play(msgId, "file://" + path, duration)
            this.playingMessageId = msgId
            return
        }
        this.busyMessageId = msgId
        let target = m
        let _ = spawn {
            let uri = this.downloadDocumentTo(target, path)
            launch {
                this.busyMessageId = 0
                if (uri.size == 0) {
                    this.showToastMsg("Could not download audio")
                    return
                }
                getVoicePlayerManager().play(msgId, uri, duration)
                this.playingMessageId = msgId
            }
        }
    }

    /** GIF 格子：下载真身（Telegram 的 GIF 是无声 mp4）后全屏循环播放 */
    private func openGifItem(m: Message): Unit {
        if (m.documentId == 0 || this.busyMessageId == m.id) { return }
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return }
        let gifDir = filesDir + "/documents"
        try { FileIo.mkdir(gifDir) } catch (_e: Exception) {}
        let isVideo = m.documentMimeType.contains("mp4") || m.documentMimeType.contains("video")
        let path = gifDir + "/gif_${m.documentId}" + (if (isVideo) { ".mp4" } else { this.documentExtension(m, ".gif") })
        if (fileExists(path) && fileSizeOf(path) >= m.documentSize) {
            this.gifOverlayPath = "file://" + path
            this.gifOverlayIsVideo = isVideo
            this.showGifOverlay = true
            return
        }
        this.busyMessageId = m.id
        let target = m
        let _ = spawn {
            let uri = this.downloadDocumentTo(target, path)
            launch {
                this.busyMessageId = 0
                if (uri.size == 0) {
                    this.showToastMsg("Could not download GIF")
                    return
                }
                this.gifOverlayPath = uri
                this.gifOverlayIsVideo = isVideo
                this.showGifOverlay = true
                Hilog.info(0, "CjTelegram", "[SharedMediaPage] GIF playing: ${uri}")
            }
        }
    }

    // ─── 辅助函数 (不在 build 体内使用 let) ──────────────────────────────────

    private func showToastMsg(msg: String): Unit {
        this.toastMessage = msg
        this.showToast = true
        this.toastGeneration += 1
        let generation = this.toastGeneration
        spawn {
            sleep(Duration.second * 3)
            launch {
                if (this.toastGeneration == generation) { this.showToast = false }
            }
        }
    }

    private func overlayActive(): Bool {
        return this.showImageViewer || this.showVideoPlayer || this.showGifOverlay
    }

    private func formatFileSize(bytes: Int64): String {
        if (bytes <= 0) { return "" }
        if (bytes < 1024) { return "${bytes} B" }
        if (bytes < 1048576) { return "${bytes / 1024} KB" }
        let mb10 = bytes * 10 / 1048576
        return "${mb10 / 10}.${mb10 % 10} MB"
    }

    private func formatDuration(sec: Int32): String {
        if (sec <= 0) { return "0:00" }
        let m = sec / 60
        let s = sec % 60
        if (s < 10) { return "${m}:0${s}" }
        return "${m}:${s}"
    }

    private func fileSubtitle(m: Message): String {
        let size = this.formatFileSize(m.documentSize)
        if (size.size > 0 && m.time.size > 0) { return size + "  " + m.time }
        if (size.size > 0) { return size }
        return m.time
    }

    private func fileBadge(m: Message): String {
        let name = m.documentFileName
        let parts = name.split(".")
        if (parts.size > 1) {
            let ext = parts[parts.size - 1].toAsciiUpper()
            if (ext.size <= 4) { return ext }
        }
        return "FILE"
    }

    private func linkTitle(m: Message): String {
        if (m.webPageTitle.size > 0) { return m.webPageTitle }
        if (m.webPageSiteName.size > 0) { return m.webPageSiteName }
        return this.linkUrl(m)
    }

    private func audioTitle(m: Message): String {
        if (m.audioTitle.size > 0) { return m.audioTitle }
        if (m.documentFileName.size > 0) { return m.documentFileName }
        return "Audio"
    }

    private func audioSubtitle(m: Message): String {
        let dur = this.formatDuration(m.audioDuration)
        if (m.audioPerformer.size > 0) { return m.audioPerformer + "  " + dur }
        return dur + "  " + m.time
    }

    private func mediaCount(): Int64 { return Int64(this.mediaItems.size) }
    private func fileCount(): Int64 { return Int64(this.fileItems.size) }
    private func linkCount(): Int64 { return Int64(this.linkItems.size) }
    private func voiceCount(): Int64 { return Int64(this.voiceItems.size) }
    private func audioCount(): Int64 { return Int64(this.audioItems.size) }
    private func gifCount(): Int64 { return Int64(this.gifItems.size) }

    // tab 标签颜色(选中/未选中)
    private func tabFontColor(idx: Int32): Int64 {
        if (this.currentTabIndex == idx) { return 0xFF0088CC }
        return 0xFF555555
    }
    private func tabFontWeight(idx: Int32): FontWeight {
        if (this.currentTabIndex == idx) { return FontWeight.Bold }
        return FontWeight.Normal
    }
    private func tabUnderlineOpacity(idx: Int32): Float64 {
        if (this.currentTabIndex == idx) { return 1.0 }
        return 0.0
    }

    private func mediaKey(m: Message): String {
        return "media_${m.id}_${this.thumbFor(m).size}_${this.busyMessageId == m.id}"
    }

    // ─── build ───────────────────────────────────────────────────────────────

    public func build() {
        // 沉浸式窗口：页面自己避让状态栏 / 底部导航条；系统 NavDestination 标题栏已隐藏，
        // 导航栏（返回 + 标题）由本页绘制。查看器打开时是覆盖层，标题隐藏（iOS 的 GalleryController 盖在资料页上）。
        Stack(alignContent: Alignment.TopStart) {
            Column {
                Row {
                    Column {
                        Image(@r(app.media.nav_back_arrow_legacy))
                            .width(12)
                            .height(20)
                            .fillColor(0xFF007AFF)
                    }
                        .width(44)
                        .height(44)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ _ => routerPop() })
                    Blank().layoutWeight(1)
                    if (!this.overlayActive()) {
                        Text(trSource("Shared Media"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0xFF000000)
                    }
                    Blank().layoutWeight(1)
                    Column {}.width(44).height(44)
                }
                .width(100.percent)
                .height(44)
                .padding(left: 4, right: 4)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(0xFFF2F2F7)

                Tabs(barPosition: BarPosition.Start, index: this.initialTabIndex) {
                    // Tab 0 — Media (Photos + Videos, 3-col grid)
                    TabContent() {
                        this.buildMediaGrid()
                    }
                    .tabBar(bind(this.mediaTabBar, this))

                    // Tab 1 — Files
                    TabContent() {
                        this.buildFileList()
                    }
                    .tabBar(bind(this.filesTabBar, this))

                    // Tab 2 — Links
                    TabContent() {
                        this.buildLinkList()
                    }
                    .tabBar(bind(this.linksTabBar, this))

                    // Tab 3 — Voice
                    TabContent() {
                        this.buildVoiceList()
                    }
                    .tabBar(bind(this.voiceTabBar, this))

                    // Tab 4 — Audio（iOS PeerInfo.PaneAudio，InputMessagesFilterMusic）
                    TabContent() {
                        this.buildAudioList()
                    }
                    .tabBar(bind(this.audioTabBar, this))

                    // Tab 5 — GIFs
                    TabContent() {
                        this.buildGifGrid()
                    }
                    .tabBar(bind(this.gifsTabBar, this))
                }
                .barMode(BarMode.Fixed)
                .barWidth(100.percent)
                .barHeight(44)
                .animationDuration(200.0)
                .backgroundColor(0xFFF2F2F7)
                .layoutWeight(1)
                .onChange({ index: Int32 =>
                    this.currentTabIndex = index
                    this.loadTabData(index)
                })
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFF2F2F7)
            .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())

            if (this.showImageViewer) {
                ImageViewer(
                    images: this.imageViewerImages,
                    initialIndex: this.imageViewerIndex,
                    onClose: { => this.showImageViewer = false }
                )
            }
            if (this.showVideoPlayer) {
                VideoPlayer(
                    video: this.videoPlayerData,
                    onClose: { => this.showVideoPlayer = false }
                )
            }
            if (this.showGifOverlay) {
                this.gifOverlay()
            }
            if (this.showToast) { this.toastOverlay() }
        }
        .width(100.percent)
        .height(100.percent)
        .onAreaChange({ _: Area, newArea: Area => this.pageHeightVp = newArea.height.value })
        .onAppear({ => this.ensureLoaded() })
    }

    // ─── Tab 标签 Builders ────────────────────────────────────────────────────

    @Builder
    func tabBarLabel(label: String, idx: Int32) {
        Column() {
            Text(label)
                .fontSize(13)
                .fontColor(this.tabFontColor(idx))
                .fontWeight(this.tabFontWeight(idx))
                .maxLines(1)
                .padding(left: 2, right: 2, top: 8, bottom: 6)
            Divider()
                .height(2)
                .color(0xFF0088CC)
                .opacity(this.tabUnderlineOpacity(idx))
        }
        .alignItems(HorizontalAlign.Center)
        .width(100.percent)
    }

    @Builder
    func mediaTabBar() { this.tabBarLabel(trSource("Media"), TAB_MEDIA) }

    @Builder
    func filesTabBar() { this.tabBarLabel(trSource("Files"), TAB_FILES) }

    @Builder
    func linksTabBar() { this.tabBarLabel(trSource("Links"), TAB_LINKS) }

    @Builder
    func voiceTabBar() { this.tabBarLabel(trSource("Voice"), TAB_VOICE) }

    @Builder
    func audioTabBar() { this.tabBarLabel(trSource("Audio"), TAB_AUDIO) }

    @Builder
    func gifsTabBar() { this.tabBarLabel(trSource("GIFs"), TAB_GIFS) }

    // ─── Tab 内容 Builders ────────────────────────────────────────────────────

    // Tab 0: Media — 3 列 Grid 缩略图 (Photos + Videos)
    @Builder
    func buildMediaGrid() {
        if (this.mediaLoading) {
            this.buildLoadingView()
        } else if (this.mediaCount() == 0) {
            this.buildEmptyView("No photos or videos shared yet")
        } else {
            Grid() {
                ForEach(this.mediaItems.toArray(), itemGeneratorFunc: { m: Message, _i: Int64 =>
                    GridItem() {
                        this.buildMediaCell(m)
                    }
                }, keyGeneratorFunc: { m: Message, _i: Int64 => this.mediaKey(m) })
            }
            .columnsTemplate("1fr 1fr 1fr")
            .columnsGap(2)
            .rowsGap(2)
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFF000000)
        }
    }

    @Builder
    func buildMediaCell(m: Message) {
        Stack(alignContent: Alignment.BottomEnd) {
            if (this.thumbFor(m).size > 0) {
                Image(this.thumbFor(m))
                    .width(100.percent)
                    .height(120)
                    .objectFit(ImageFit.Cover)
            } else {
                Column() {
                    Text(if (this.isPhoto(m)) { "PHOTO" } else { "VIDEO" })
                        .fontSize(11)
                        .fontColor(0xFFFFFFFF)
                        .fontWeight(FontWeight.Medium)
                }
                .width(100.percent)
                .height(120)
                .backgroundColor(0xFF3A3A3C)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
            if (!this.isPhoto(m)) {
                Row() {
                    Text("▶")
                        .fontSize(11)
                        .fontColor(0xFFFFFFFF)
                    Text(this.formatDuration(m.videoDuration))
                        .fontSize(11)
                        .fontColor(0xFFFFFFFF)
                        .margin(left: 3)
                }
                .padding(left: 5, right: 5, top: 2, bottom: 2)
                .backgroundColor(0x80000000)
                .borderRadius(4)
                .margin(right: 4, bottom: 4)
            }
            if (this.busyMessageId == m.id) {
                Column() {
                    LoadingProgress().width(28).height(28).color(0xFFFFFFFF)
                }
                .width(100.percent)
                .height(120)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(100.percent)
        .height(120)
        .onClick({ _ => this.openMediaItem(m) })
    }

    // Tab 1: Files — 文件名/大小/日期 列表
    @Builder
    func buildFileList() {
        if (this.fileLoading) {
            this.buildLoadingView()
        } else if (this.fileCount() == 0) {
            this.buildEmptyView("No files shared yet")
        } else {
            List() {
                ForEach(this.fileItems.toArray(), itemGeneratorFunc: { m: Message, _i: Int64 =>
                    ListItem() {
                        this.buildFileRow(m)
                    }
                }, keyGeneratorFunc: { m: Message, _i: Int64 => "file_${m.id}_${this.busyMessageId == m.id}" })
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFFFF)
            .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFD0D0D0, startMargin: 60, endMargin: 0))
        }
    }

    @Builder
    func buildFileRow(m: Message) {
        Row() {
            Column() {
                if (this.busyMessageId == m.id) {
                    LoadingProgress().width(24).height(24).color(0xFFFFFFFF)
                } else {
                    Text(this.fileBadge(m))
                        .fontSize(11)
                        .fontColor(0xFFFFFFFF)
                        .fontWeight(FontWeight.Bold)
                }
            }
            .width(44)
            .height(44)
            .backgroundColor(0xFF5AC8FA)
            .borderRadius(8)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(right: 12)

            Column() {
                Text(if (m.documentFileName.size > 0) { m.documentFileName } else { "File" })
                    .fontSize(15)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(this.fileSubtitle(m))
                    .fontSize(12)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .backgroundColor(0xFFFFFFFF)
        .onClick({ _ => this.openFileItem(m) })
    }

    // Tab 2: Links — 链接卡片列表（标题 / 网址）
    @Builder
    func buildLinkList() {
        if (this.linkLoading) {
            this.buildLoadingView()
        } else if (this.linkCount() == 0) {
            this.buildEmptyView("No links shared yet")
        } else {
            List() {
                ForEach(this.linkItems.toArray(), itemGeneratorFunc: { m: Message, _i: Int64 =>
                    ListItem() {
                        this.buildLinkRow(m)
                    }
                }, keyGeneratorFunc: { m: Message, _i: Int64 => "link_${m.id}" })
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFFFF)
            .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFD0D0D0, startMargin: 16, endMargin: 0))
        }
    }

    @Builder
    func buildLinkRow(m: Message) {
        Row() {
            Column() {
                Text(trSource("URL"))
                    .fontSize(10)
                    .fontColor(0xFFFFFFFF)
                    .fontWeight(FontWeight.Bold)
            }
            .width(44)
            .height(44)
            .backgroundColor(0xFF007AFF)
            .borderRadius(8)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(right: 12)

            Column() {
                Text(this.linkTitle(m))
                    .fontSize(15)
                    .fontColor(0xFF000000)
                    .maxLines(2)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(this.linkUrl(m))
                    .fontSize(13)
                    .fontColor(0xFF007AFF)
                    .margin(top: 2)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .backgroundColor(0xFFFFFFFF)
        .onClick({ _ => this.openLinkItem(m) })
    }

    // Tab 3: Voice — 语音消息列表
    @Builder
    func buildVoiceList() {
        if (this.voiceLoading) {
            this.buildLoadingView()
        } else if (this.voiceCount() == 0) {
            this.buildEmptyView("No voice messages shared yet")
        } else {
            List() {
                ForEach(this.voiceItems.toArray(), itemGeneratorFunc: { m: Message, _i: Int64 =>
                    ListItem() {
                        this.buildAudioRow(m, true)
                    }
                }, keyGeneratorFunc: { m: Message, _i: Int64 => "voice_${m.id}_${this.playingMessageId == m.id}_${this.busyMessageId == m.id}" })
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFFFF)
            .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFD0D0D0, startMargin: 60, endMargin: 0))
        }
    }

    // Tab 4: Audio — 音乐文件列表（曲名 / 演唱者）
    @Builder
    func buildAudioList() {
        if (this.audioLoading) {
            this.buildLoadingView()
        } else if (this.audioCount() == 0) {
            this.buildEmptyView("No audio files shared yet")
        } else {
            List() {
                ForEach(this.audioItems.toArray(), itemGeneratorFunc: { m: Message, _i: Int64 =>
                    ListItem() {
                        this.buildAudioRow(m, false)
                    }
                }, keyGeneratorFunc: { m: Message, _i: Int64 => "audio_${m.id}_${this.playingMessageId == m.id}_${this.busyMessageId == m.id}" })
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFFFF)
            .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFD0D0D0, startMargin: 60, endMargin: 0))
        }
    }

    @Builder
    func buildAudioRow(m: Message, isVoice: Bool) {
        Row() {
            Column() {
                if (this.busyMessageId == m.id) {
                    LoadingProgress().width(24).height(24).color(0xFFFFFFFF)
                } else if (this.playingMessageId == m.id) {
                    Text("❚❚")
                        .fontSize(13)
                        .fontColor(0xFFFFFFFF)
                        .fontWeight(FontWeight.Bold)
                } else {
                    Text("▶")
                        .fontSize(16)
                        .fontColor(0xFFFFFFFF)
                }
            }
            .width(44)
            .height(44)
            .backgroundColor(if (isVoice) { 0xFF34C759 } else { 0xFF007AFF })
            .borderRadius(22)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(right: 12)

            Column() {
                Text(if (isVoice) { "Voice message" } else { this.audioTitle(m) })
                    .fontSize(15)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(if (isVoice) { this.formatDuration(m.audioDuration) + "  " + m.time } else { this.audioSubtitle(m) })
                    .fontSize(12)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
                    .maxLines(1)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .backgroundColor(0xFFFFFFFF)
        .onClick({ _ => this.playAudioItem(m, isVoice) })
    }

    // Tab 5: GIFs — 3 列 Grid
    @Builder
    func buildGifGrid() {
        if (this.gifLoading) {
            this.buildLoadingView()
        } else if (this.gifCount() == 0) {
            this.buildEmptyView("No GIFs shared yet")
        } else {
            Grid() {
                ForEach(this.gifItems.toArray(), itemGeneratorFunc: { m: Message, _i: Int64 =>
                    GridItem() {
                        this.buildGifCell(m)
                    }
                }, keyGeneratorFunc: { m: Message, _i: Int64 => "gif_" + this.mediaKey(m) })
            }
            .columnsTemplate("1fr 1fr 1fr")
            .columnsGap(2)
            .rowsGap(2)
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFF000000)
        }
    }

    @Builder
    func buildGifCell(m: Message) {
        Stack(alignContent: Alignment.BottomStart) {
            if (this.thumbFor(m).size > 0) {
                Image(this.thumbFor(m))
                    .width(100.percent)
                    .height(120)
                    .objectFit(ImageFit.Cover)
            } else {
                Column() {}
                    .width(100.percent)
                    .height(120)
                    .backgroundColor(0xFF2C2C2E)
            }
            Text(trSource("GIF"))
                .fontSize(11)
                .fontColor(0xFFFFFFFF)
                .fontWeight(FontWeight.Bold)
                .padding(left: 5, right: 5, top: 2, bottom: 2)
                .backgroundColor(0x80000000)
                .borderRadius(4)
                .margin(left: 4, bottom: 4)
            if (this.busyMessageId == m.id) {
                Column() {
                    LoadingProgress().width(28).height(28).color(0xFFFFFFFF)
                }
                .width(100.percent)
                .height(120)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
        }
        .width(100.percent)
        .height(120)
        .onClick({ _ => this.openGifItem(m) })
    }

    /** GIF 全屏播放：Telegram 的 GIF 是无声 mp4 → Video 循环；真 .gif → Image 自带动图 */
    @Builder
    func gifOverlay() {
        Column() {
            if (this.gifOverlayIsVideo) {
                Video(src: this.gifOverlayPath)
                    .width(100.percent)
                    .height(100.percent)
                    .autoPlay(true)
                    .loop(true)
                    .muted(true)
                    .controls(false)
                    .objectFit(ImageFit.Contain)
            } else {
                Image(this.gifOverlayPath)
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Contain)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF000000)
        .justifyContent(FlexAlign.Center)
        .onClick({ _ => this.showGifOverlay = false })
    }

    // ==================== Toast（iOS UndoOverlayController：3 秒自动消失，不挡页面点击） ====================

    /**
     * 只占底部一条的高度（Stack 内用 margin 顶到底部），其余区域的点击照常落到页面上；
     * 3 秒后自动隐藏（UndoOverlayControllerNode.swift:272 timeout ?? 3）。
     */
    @Builder
    func toastOverlay() {
        Column {
            Text(this.toastMessage)
                .fontSize(14)
                .fontColor(0xFFFFFFFF)
                .padding(left: 20, right: 20, top: 10, bottom: 10)
                .backgroundColor(0xCC333333)
                .borderRadius(20)
        }
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
        .margin(top: this.toastTopVp())
        .onClick({ _ => this.showToast = false })
    }

    private func toastTopVp(): Float64 {
        if (this.pageHeightVp <= 0.0) { return 560.0 }
        return this.pageHeightVp - 110.0
    }

    // 通用 Loading 占位
    @Builder
    func buildLoadingView() {
        Column() {
            Text(trSource("Loading..."))
                .fontSize(15)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xFFF2F2F7)
    }

    // 通用 Empty 占位
    @Builder
    func buildEmptyView(message: String) {
        Column() {
            Text(message)
                .fontSize(15)
                .fontColor(0xFF8E8E93)
                .textAlign(TextAlign.Center)
                .padding(left: 32, right: 32)
        }
        .width(100.percent)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xFFF2F2F7)
    }
}

// ─── 文件辅助 ─────────────────────────────────────────────────────────────────

private func fileExists(path: String): Bool {
    try { return FileIo.access(path) } catch (_e: Exception) { return false }
}

private func fileSizeOf(path: String): Int64 {
    try { return FileIo.stat(path).size } catch (_e: Exception) { return 0 }
}

private func writeFile(path: String, bytes: Array<Byte>): Unit {
    let file = FileIo.open(path, mode: 0o1101)
    FileIo.write(file.fd, bytes)
    FileIo.close(file)
}

/** 消息正文里的第一个 http(s):// 片段（到空白为止） */
private func firstUrlInText(text: String): String {
    let lower = text.toAsciiLower()
    var start: Int64 = -1
    match (lower.indexOf("https://")) {
        case Some(i) => start = i
        case None =>
            match (lower.indexOf("http://")) {
                case Some(i) => start = i
                case None => ()
            }
    }
    if (start < 0) { return "" }
    let bytes = text.toArray()
    var end = start
    while (end < bytes.size) {
        let c = bytes[end]
        if (c == 32 || c == 10 || c == 13 || c == 9) { break }
        end += 1
    }
    return String.fromUtf8(bytes[start..end])
}
