package ohos_app_cangjie_entry.services

import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.ReentrantMutex
import std.time.DateTime
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * Explicit byte direction used by the category matrix recording API.
 */
public enum NetworkUsageDirection {
    | Incoming
    | Outgoing
}

/**
 * One category's complete wifi/cellular × incoming/outgoing projection.
 */
public class NetworkUsageCategorySnapshot {
    public let category: TransportUsageCategory
    public let wifiIncoming: Int64
    public let wifiOutgoing: Int64
    public let cellularIncoming: Int64
    public let cellularOutgoing: Int64

    public init(
        category: TransportUsageCategory,
        wifiIncoming: Int64,
        wifiOutgoing: Int64,
        cellularIncoming: Int64,
        cellularOutgoing: Int64
    ) {
        this.category = category
        this.wifiIncoming = wifiIncoming
        this.wifiOutgoing = wifiOutgoing
        this.cellularIncoming = cellularIncoming
        this.cellularOutgoing = cellularOutgoing
    }

    public func incoming(includeWifi: Bool, includeCellular: Bool): Int64 {
        return (if (includeWifi) { this.wifiIncoming } else { 0 }) +
            (if (includeCellular) { this.cellularIncoming } else { 0 })
    }

    public func outgoing(includeWifi: Bool, includeCellular: Bool): Int64 {
        return (if (includeWifi) { this.wifiOutgoing } else { 0 }) +
            (if (includeCellular) { this.cellularOutgoing } else { 0 })
    }
}

/**
 * Immutable complete usage snapshot. Legacy aggregate fields remain available
 * to settings summaries, but are derived exclusively from the same matrix.
 */
public class NetworkUsageSnapshot {
    public let categories: ArrayList<NetworkUsageCategorySnapshot>
    public let wifiResetTimestamp: Int64
    public let cellularResetTimestamp: Int64
    public let totalSent: Int64
    public let totalReceived: Int64
    public let wifiSent: Int64
    public let wifiReceived: Int64
    public let cellularSent: Int64
    public let cellularReceived: Int64

    public init(
        categories: ArrayList<NetworkUsageCategorySnapshot>,
        wifiResetTimestamp: Int64,
        cellularResetTimestamp: Int64
    ) {
        this.categories = categories
        this.wifiResetTimestamp = wifiResetTimestamp
        this.cellularResetTimestamp = cellularResetTimestamp

        var ws: Int64 = 0
        var wr: Int64 = 0
        var cs: Int64 = 0
        var cr: Int64 = 0
        for (entry in categories) {
            ws += entry.wifiOutgoing
            wr += entry.wifiIncoming
            cs += entry.cellularOutgoing
            cr += entry.cellularIncoming
        }
        this.wifiSent = ws
        this.wifiReceived = wr
        this.cellularSent = cs
        this.cellularReceived = cr
        this.totalSent = ws + cs
        this.totalReceived = wr + cr
    }
}

let PREF_STORE_NETWORK_USAGE: String = "network_usage"
let PREF_KEY_WIFI_SENT: String = "wifi_sent"
let PREF_KEY_WIFI_RECV: String = "wifi_received"
let PREF_KEY_CELL_SENT: String = "cellular_sent"
let PREF_KEY_CELL_RECV: String = "cellular_received"
let PREF_KEY_MATRIX_VERSION: String = "category_matrix_version"
let PREF_KEY_WIFI_RESET_TIMESTAMP: String = "category_matrix_wifi_reset_timestamp"
let PREF_KEY_CELLULAR_RESET_TIMESTAMP: String = "category_matrix_cellular_reset_timestamp"
let PREF_KEY_LEGACY_RESET_TIMESTAMP: String = "category_matrix_reset_timestamp"
let MATRIX_VERSION: Int64 = 1

private func usageCategories(): Array<TransportUsageCategory> {
    return [
        TransportUsageCategory.Generic,
        TransportUsageCategory.Image,
        TransportUsageCategory.Video,
        TransportUsageCategory.Audio,
        TransportUsageCategory.File,
        TransportUsageCategory.Call,
        TransportUsageCategory.Stickers,
        TransportUsageCategory.VoiceMessages
    ]
}

private func categoryStorageName(category: TransportUsageCategory): String {
    match (category) {
        case Generic => "generic"
        case Image => "image"
        case Video => "video"
        case Audio => "audio"
        case File => "file"
        case Call => "call"
        case Stickers => "stickers"
        case VoiceMessages => "voice_messages"
    }
}

private func usageIndex(
    category: TransportUsageCategory,
    isWifi: Bool,
    direction: NetworkUsageDirection
): Int64 {
    let connectionOffset: Int64 = if (isWifi) { 0 } else { 2 }
    let directionOffset: Int64 = match (direction) {
        case Incoming => 0
        case Outgoing => 1
    }
    return Int64(category.ordinal()) * 4 + connectionOffset + directionOffset
}

private func usagePrefKey(
    category: TransportUsageCategory,
    isWifi: Bool,
    direction: NetworkUsageDirection
): String {
    let connection = if (isWifi) { "wifi" } else { "cellular" }
    let directionName = match (direction) {
        case Incoming => "incoming"
        case Outgoing => "outgoing"
    }
    return "category_${categoryStorageName(category)}_${connection}_${directionName}"
}

private var _networkUsageServiceInstance: Option<NetworkUsageService> = None<NetworkUsageService>

public func getNetworkUsageService(): NetworkUsageService {
    match (_networkUsageServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = NetworkUsageService()
            _networkUsageServiceInstance = Some(svc)
            return svc
    }
}

/**
 * Category-aware network usage persistence and transport metering.
 */
public class NetworkUsageService {
    private let mutex = ReentrantMutex()
    private var values_: Array<Int64> = Array<Int64>(32, repeat: 0)
    private var wifiResetTimestamp_: Int64 = 0
    private var cellularResetTimestamp_: Int64 = 0
    private var prefs_: Option<Preferences> = None<Preferences>
    private var initialized_: Bool = false

    public func ensureInit(): Unit {
        synchronized(this.mutex) {
            if (this.initialized_) { return }
            this.initialized_ = true
        }

        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let p = Preferences.getPreferences(ctx, PREF_STORE_NETWORK_USAGE)
                    this.migrateLegacyOnce(p)
                    let loaded = Array<Int64>(32, repeat: 0)
                    for (category in usageCategories()) {
                        loaded[usageIndex(category, true, NetworkUsageDirection.Incoming)] =
                            this.readInt64Pref(p, usagePrefKey(category, true, NetworkUsageDirection.Incoming))
                        loaded[usageIndex(category, true, NetworkUsageDirection.Outgoing)] =
                            this.readInt64Pref(p, usagePrefKey(category, true, NetworkUsageDirection.Outgoing))
                        loaded[usageIndex(category, false, NetworkUsageDirection.Incoming)] =
                            this.readInt64Pref(p, usagePrefKey(category, false, NetworkUsageDirection.Incoming))
                        loaded[usageIndex(category, false, NetworkUsageDirection.Outgoing)] =
                            this.readInt64Pref(p, usagePrefKey(category, false, NetworkUsageDirection.Outgoing))
                    }
                    let legacyResetAt = this.readInt64Pref(p, PREF_KEY_LEGACY_RESET_TIMESTAMP)
                    let persistedWifiResetAt = this.readInt64Pref(p, PREF_KEY_WIFI_RESET_TIMESTAMP)
                    let persistedCellularResetAt = this.readInt64Pref(p, PREF_KEY_CELLULAR_RESET_TIMESTAMP)
                    var wifiResetAt = if (persistedWifiResetAt > 0) {
                        persistedWifiResetAt
                    } else {
                        legacyResetAt
                    }
                    var cellularResetAt = if (persistedCellularResetAt > 0) {
                        persistedCellularResetAt
                    } else {
                        legacyResetAt
                    }
                    // The source always has a stats collection start date, including
                    // before the user ever presses Reset.  Older target builds either
                    // left this at zero or wrote milliseconds while the presentation
                    // layer consumes Unix seconds; normalize both persisted forms once.
                    let nowSeconds = DateTime.now().toUnixTimeStamp().toSeconds()
                    if (wifiResetAt <= 0) {
                        wifiResetAt = nowSeconds
                    } else if (wifiResetAt > 100000000000) {
                        wifiResetAt = wifiResetAt / 1000
                    }
                    if (cellularResetAt <= 0) {
                        cellularResetAt = nowSeconds
                    } else if (cellularResetAt > 100000000000) {
                        cellularResetAt = cellularResetAt / 1000
                    }
                    p.put(PREF_KEY_WIFI_RESET_TIMESTAMP, PreferencesValueType.Integer(wifiResetAt))
                    p.put(PREF_KEY_CELLULAR_RESET_TIMESTAMP, PreferencesValueType.Integer(cellularResetAt))
                    p.flush()
                    synchronized(this.mutex) {
                        this.values_ = loaded
                        this.wifiResetTimestamp_ = wifiResetAt
                        this.cellularResetTimestamp_ = cellularResetAt
                        this.prefs_ = Some(p)
                    }
                    Hilog.info(0, "CjTelegram", "[NetworkUsage] category matrix initialized")
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[NetworkUsage] Preferences init failed, memory mode: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[NetworkUsage] Context not ready, memory mode")
        }
    }

    /**
     * Primary recording API. Category and direction are both mandatory; this
     * layer never infers a media class from filenames or byte sizes.
     */
    public func record(
        category: TransportUsageCategory,
        direction: NetworkUsageDirection,
        bytes: Int64
    ): Unit {
        if (bytes <= 0) { return }
        try {
            this.ensureInit()
            let isWifi = this.isCurrentlyWifi()
            var prefs: Option<Preferences> = None<Preferences>
            synchronized(this.mutex) {
                let idx = usageIndex(category, isWifi, direction)
                this.values_[idx] += bytes
                prefs = this.prefs_
            }
            this.persist(prefs)
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[NetworkUsage] record error swallowed: ${e}")
        }
    }

    public func recordSent(
        bytes: Int64,
        category!: TransportUsageCategory = TransportUsageCategory.Generic
    ): Unit {
        this.record(category, NetworkUsageDirection.Outgoing, bytes)
    }

    public func recordReceived(
        bytes: Int64,
        category!: TransportUsageCategory = TransportUsageCategory.Generic
    ): Unit {
        this.record(category, NetworkUsageDirection.Incoming, bytes)
    }

    public func getUsage(): NetworkUsageSnapshot {
        this.ensureInit()
        let result = ArrayList<NetworkUsageCategorySnapshot>()
        var wifiResetAt: Int64 = 0
        var cellularResetAt: Int64 = 0
        synchronized(this.mutex) {
            for (category in usageCategories()) {
                result.add(NetworkUsageCategorySnapshot(
                    category,
                    this.values_[usageIndex(category, true, NetworkUsageDirection.Incoming)],
                    this.values_[usageIndex(category, true, NetworkUsageDirection.Outgoing)],
                    this.values_[usageIndex(category, false, NetworkUsageDirection.Incoming)],
                    this.values_[usageIndex(category, false, NetworkUsageDirection.Outgoing)]
                ))
            }
            wifiResetAt = this.wifiResetTimestamp_
            cellularResetAt = this.cellularResetTimestamp_
        }
        return NetworkUsageSnapshot(result, wifiResetAt, cellularResetAt)
    }

    public func reset(): Unit {
        try {
            this.ensureInit()
            var prefs: Option<Preferences> = None<Preferences>
            synchronized(this.mutex) {
                this.values_ = Array<Int64>(32, repeat: 0)
                let resetAt = DateTime.now().toUnixTimeStamp().toSeconds()
                this.wifiResetTimestamp_ = resetAt
                this.cellularResetTimestamp_ = resetAt
                prefs = this.prefs_
            }
            this.persist(prefs)
            Hilog.info(0, "CjTelegram", "[NetworkUsage] reset all category buckets")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[NetworkUsage] reset error swallowed: ${e}")
        }
    }

    public func registerTransport(transport: TCPTransport): Unit {
        let svc = this
        transport.setMeteringHooks(
            { category: TransportUsageCategory, bytes: Int64 =>
                svc.record(category, NetworkUsageDirection.Outgoing, bytes)
            },
            { category: TransportUsageCategory, bytes: Int64 =>
                svc.record(category, NetworkUsageDirection.Incoming, bytes)
            }
        )
    }

    private func migrateLegacyOnce(p: Preferences): Unit {
        if (this.readInt64Pref(p, PREF_KEY_MATRIX_VERSION) >= MATRIX_VERSION) { return }

        // Legacy totals have no category metadata. Preserve them once in
        // Generic only; never fabricate media classes from filename or size.
        p.put(
            usagePrefKey(TransportUsageCategory.Generic, true, NetworkUsageDirection.Outgoing),
            PreferencesValueType.Integer(this.readInt64Pref(p, PREF_KEY_WIFI_SENT))
        )
        p.put(
            usagePrefKey(TransportUsageCategory.Generic, true, NetworkUsageDirection.Incoming),
            PreferencesValueType.Integer(this.readInt64Pref(p, PREF_KEY_WIFI_RECV))
        )
        p.put(
            usagePrefKey(TransportUsageCategory.Generic, false, NetworkUsageDirection.Outgoing),
            PreferencesValueType.Integer(this.readInt64Pref(p, PREF_KEY_CELL_SENT))
        )
        p.put(
            usagePrefKey(TransportUsageCategory.Generic, false, NetworkUsageDirection.Incoming),
            PreferencesValueType.Integer(this.readInt64Pref(p, PREF_KEY_CELL_RECV))
        )
        p.put(PREF_KEY_MATRIX_VERSION, PreferencesValueType.Integer(MATRIX_VERSION))
        p.flush()
        Hilog.info(0, "CjTelegram", "[NetworkUsage] migrated legacy totals to Generic once")
    }

    private func isCurrentlyWifi(): Bool {
        match (ReachabilityService.getInstance().currentStatus()) {
            case NetCellular => false
            case _ => true
        }
    }

    private func readInt64Pref(p: Preferences, key: String): Int64 {
        try {
            match (p.get(key, PreferencesValueType.Integer(0))) {
                case PreferencesValueType.Integer(n) => n
                case _ => 0
            }
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[NetworkUsage] read key=${key} failed: ${e}")
            return 0
        }
    }

    private func persist(prefs: Option<Preferences>): Unit {
        match (prefs) {
            case Some(p) =>
                let snapshot = Array<Int64>(32, repeat: 0)
                var wifiResetAt: Int64 = 0
                var cellularResetAt: Int64 = 0
                synchronized(this.mutex) {
                    for (i in 0..32) {
                        snapshot[i] = this.values_[i]
                    }
                    wifiResetAt = this.wifiResetTimestamp_
                    cellularResetAt = this.cellularResetTimestamp_
                }
                try {
                    for (category in usageCategories()) {
                        p.put(
                            usagePrefKey(category, true, NetworkUsageDirection.Incoming),
                            PreferencesValueType.Integer(snapshot[usageIndex(category, true, NetworkUsageDirection.Incoming)])
                        )
                        p.put(
                            usagePrefKey(category, true, NetworkUsageDirection.Outgoing),
                            PreferencesValueType.Integer(snapshot[usageIndex(category, true, NetworkUsageDirection.Outgoing)])
                        )
                        p.put(
                            usagePrefKey(category, false, NetworkUsageDirection.Incoming),
                            PreferencesValueType.Integer(snapshot[usageIndex(category, false, NetworkUsageDirection.Incoming)])
                        )
                        p.put(
                            usagePrefKey(category, false, NetworkUsageDirection.Outgoing),
                            PreferencesValueType.Integer(snapshot[usageIndex(category, false, NetworkUsageDirection.Outgoing)])
                        )
                    }
                    p.put(PREF_KEY_WIFI_RESET_TIMESTAMP, PreferencesValueType.Integer(wifiResetAt))
                    p.put(PREF_KEY_CELLULAR_RESET_TIMESTAMP, PreferencesValueType.Integer(cellularResetAt))
                    // Zero legacy keys as well so reset cannot resurrect data
                    // if an older binary is launched before this migration.
                    p.put(PREF_KEY_WIFI_SENT, PreferencesValueType.Integer(0))
                    p.put(PREF_KEY_WIFI_RECV, PreferencesValueType.Integer(0))
                    p.put(PREF_KEY_CELL_SENT, PreferencesValueType.Integer(0))
                    p.put(PREF_KEY_CELL_RECV, PreferencesValueType.Integer(0))
                    p.put(PREF_KEY_MATRIX_VERSION, PreferencesValueType.Integer(MATRIX_VERSION))
                    p.flush()
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[NetworkUsage] persist failed: ${e}")
                }
            case None => ()
        }
    }
}
