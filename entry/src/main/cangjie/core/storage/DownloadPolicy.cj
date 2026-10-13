package ohos_app_cangjie_entry.core.storage

import kit.PerformanceAnalysisKit.Hilog

/**
 * Global download policy singleton — checked by FileDownloadService before auto-downloading.
 *
 * Initialized at app launch from AuthStorage, then updated live when the user
 * changes settings in DataStorageSettingsPage.
 */
public class DownloadPolicy {
    public var autoPhotos: Bool = true
    public var autoVideos: Bool = false
    public var autoFiles: Bool = false
    public var dataSaving: Bool = false
}

var _downloadPolicy: DownloadPolicy = DownloadPolicy()

public func getDownloadPolicy(): DownloadPolicy {
    return _downloadPolicy
}

/**
 * Called once at app startup to restore persisted download settings.
 */
public func initDownloadPolicy(): Unit {
    let storage = getAuthStorage()
    _downloadPolicy.autoPhotos = storage.getDownloadPhotos()
    _downloadPolicy.autoVideos = storage.getDownloadVideos()
    _downloadPolicy.autoFiles = storage.getDownloadFiles()
    _downloadPolicy.dataSaving = storage.getDataSaving()
    Hilog.info(0, "CjTelegram", "[DownloadPolicy] Initialized: photos=${_downloadPolicy.autoPhotos}, videos=${_downloadPolicy.autoVideos}, files=${_downloadPolicy.autoFiles}")
}

/**
 * Check if auto-download is allowed for a given media type.
 * Returns true if auto-download should proceed.
 */
public func canAutoDownload(mediaType: String): Bool {
    if (_downloadPolicy.dataSaving) {
        return false
    }
    match (mediaType) {
        case "photo" => return _downloadPolicy.autoPhotos
        case "video" => return _downloadPolicy.autoVideos
        case "gif" => return _downloadPolicy.autoVideos  // GIFs follow video auto-download setting (iOS parity)
        case "document" => return _downloadPolicy.autoFiles
        case "sticker" => return true
        case "voice" => return true
        case _ => return false
    }
}
