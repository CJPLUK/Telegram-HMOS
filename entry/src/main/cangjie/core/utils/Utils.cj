package ohos_app_cangjie_entry.core.utils

import std.collection.ArrayList
import std.sync.*

// ============================================================
// IntRange — a half-open integer interval [lo, hi)
// ============================================================

public struct IntRange {
    public var lo: Int64
    public var hi: Int64

    public init(lo!: Int64, hi!: Int64) {
        this.lo = lo
        this.hi = hi
    }
}

// ============================================================
// IntRangeSet
//
// A set of non-overlapping, non-adjacent, sorted half-open
// integer intervals [lo, hi).  Semantics mirror the Swift
// RangeSet<Int> from the Telegram-iOS Utils module.
// ============================================================

public class IntRangeSet {

    private var _ranges: ArrayList<IntRange> = ArrayList<IntRange>()

    public init() {}

    public prop isEmpty: Bool {
        get() {
            return _ranges.size == 0
        }
    }

    public prop count: Int64 {
        get() {
            return _ranges.size
        }
    }

    public func rangeAt(i: Int64): IntRange {
        return _ranges[i]
    }

    // Returns true if value is covered by any stored range.
    public func contains(value: Int64): Bool {
        var i: Int64 = 0
        while (i < _ranges.size) {
            let r = _ranges[i]
            if (value >= r.lo && value < r.hi) {
                return true
            }
            if (r.lo > value) {
                return false
            }
            i += 1
        }
        return false
    }

    // Returns true if [lo, hi) overlaps any stored range.
    public func intersects(lo!: Int64, hi!: Int64): Bool {
        if (lo >= hi) {
            return false
        }
        if (_ranges.size == 0) {
            return false
        }
        var i: Int64 = 0
        while (i < _ranges.size) {
            let r = _ranges[i]
            if (lo < r.hi && hi > r.lo) {
                return true
            }
            i += 1
        }
        return false
    }

    // Insert a half-open range [lo, hi).
    public func insert(lo!: Int64, hi!: Int64): Unit {
        if (lo >= hi) {
            return
        }
        if (_ranges.size == 0) {
            _ranges.add(IntRange(lo: lo, hi: hi))
            return
        }

        // startIdx: first range whose hi >= lo (could overlap or be adjacent)
        var startIdx: Int64 = 0
        while (startIdx < _ranges.size) {
            let r = _ranges[startIdx]
            if (r.hi >= lo) {
                break
            }
            startIdx += 1
        }

        // endIdx: first range whose lo > hi (no more overlap)
        var endIdx: Int64 = startIdx
        while (endIdx < _ranges.size) {
            let r = _ranges[endIdx]
            if (r.lo > hi) {
                break
            }
            endIdx += 1
        }

        if (startIdx == endIdx) {
            // No overlap — plain insertion
            _insertAt(startIdx, lo, hi)
            return
        }

        // Merge [startIdx, endIdx) into one range
        let firstLo = _ranges[startIdx].lo
        let newLo: Int64 = if (firstLo < lo) { firstLo } else { lo }
        let lastHi = _ranges[endIdx - 1].hi
        let newHi: Int64 = if (lastHi > hi) { lastHi } else { hi }

        _ranges[startIdx] = IntRange(lo: newLo, hi: newHi)

        // Shift remaining elements left over the merged span
        var writeIdx: Int64 = startIdx + 1
        var readIdx: Int64 = endIdx
        while (readIdx < _ranges.size) {
            _ranges[writeIdx] = _ranges[readIdx]
            writeIdx += 1
            readIdx += 1
        }
        // Trim tail
        while (_ranges.size > writeIdx) {
            _ranges.remove(at: _ranges.size - 1)
        }
    }

    // Remove a half-open range [lo, hi) from the set.
    public func remove(lo!: Int64, hi!: Int64): Unit {
        if (lo >= hi) {
            return
        }
        if (_ranges.size == 0) {
            return
        }

        var newRanges: ArrayList<IntRange> = ArrayList<IntRange>()
        var i: Int64 = 0
        while (i < _ranges.size) {
            let r = _ranges[i]
            if (r.hi <= lo || r.lo >= hi) {
                newRanges.add(r)
            } else {
                if (r.lo < lo) {
                    newRanges.add(IntRange(lo: r.lo, hi: lo))
                }
                if (r.hi > hi) {
                    newRanges.add(IntRange(lo: hi, hi: r.hi))
                }
            }
            i += 1
        }
        _ranges = newRanges
    }

    // Union: add all ranges from other into this set.
    public func formUnion(other: IntRangeSet): Unit {
        var i: Int64 = 0
        while (i < other._ranges.size) {
            let r = other._ranges[i]
            insert(lo: r.lo, hi: r.hi)
            i += 1
        }
    }

    // Returns union of self and other (new set).
    public func union(other: IntRangeSet): IntRangeSet {
        let result = IntRangeSet()
        var i: Int64 = 0
        while (i < _ranges.size) {
            let r = _ranges[i]
            result.insert(lo: r.lo, hi: r.hi)
            i += 1
        }
        result.formUnion(other)
        return result
    }

    // Subtract all ranges in other from this set.
    public func subtract(other: IntRangeSet): Unit {
        var i: Int64 = 0
        while (i < other._ranges.size) {
            let r = other._ranges[i]
            remove(lo: r.lo, hi: r.hi)
            i += 1
        }
    }

    // Returns self minus other (new set).
    public func subtracting(other: IntRangeSet): IntRangeSet {
        let result = IntRangeSet()
        var i: Int64 = 0
        while (i < _ranges.size) {
            let r = _ranges[i]
            result.insert(lo: r.lo, hi: r.hi)
            i += 1
        }
        result.subtract(other)
        return result
    }

    // Returns the intersection of self and other (new set).
    public func intersection(other: IntRangeSet): IntRangeSet {
        let result = IntRangeSet()
        var si: Int64 = 0
        var oi: Int64 = 0
        while (si < _ranges.size && oi < other._ranges.size) {
            let sr = _ranges[si]
            let or_ = other._ranges[oi]
            let lo: Int64 = if (sr.lo > or_.lo) { sr.lo } else { or_.lo }
            let hi: Int64 = if (sr.hi < or_.hi) { sr.hi } else { or_.hi }
            if (lo < hi) {
                result.insert(lo: lo, hi: hi)
            }
            if (sr.hi < or_.hi) {
                si += 1
            } else {
                oi += 1
            }
        }
        return result
    }

    // Returns all stored ranges.
    public func toArray(): Array<IntRange> {
        let sz = _ranges.size
        let immutable = _ranges
        return Array<IntRange>(sz, { i: Int64 => immutable[i] })
    }

    // Insert a new range at position idx, shifting existing ranges right.
    private func _insertAt(idx: Int64, lo: Int64, hi: Int64): Unit {
        _ranges.add(IntRange(lo: 0, hi: 0))
        var j: Int64 = _ranges.size - 2
        while (j >= idx) {
            _ranges[j + 1] = _ranges[j]
            j -= 1
        }
        _ranges[idx] = IntRange(lo: lo, hi: hi)
    }
}

// ============================================================
// CollectionUtils
//
// General-purpose collection helper functions analogous to
// the Swift CollectionExtensions in Telegram-iOS.
// ============================================================

// Returns the first element satisfying predicate, or None.
public func collectionFirst<T>(arr: Array<T>, predicate: (T) -> Bool): Option<T> {
    var i: Int64 = 0
    while (i < arr.size) {
        if (predicate(arr[i])) {
            return Some(arr[i])
        }
        i += 1
    }
    return None
}

// Returns the last element satisfying predicate, or None.
public func collectionLast<T>(arr: Array<T>, predicate: (T) -> Bool): Option<T> {
    var i: Int64 = arr.size - 1
    while (i >= 0) {
        if (predicate(arr[i])) {
            return Some(arr[i])
        }
        i -= 1
    }
    return None
}

// Returns true if any element satisfies predicate.
public func collectionAny<T>(arr: Array<T>, predicate: (T) -> Bool): Bool {
    var i: Int64 = 0
    while (i < arr.size) {
        if (predicate(arr[i])) {
            return true
        }
        i += 1
    }
    return false
}

// Returns true if all elements satisfy predicate (vacuously true for empty arrays).
public func collectionAll<T>(arr: Array<T>, predicate: (T) -> Bool): Bool {
    var i: Int64 = 0
    while (i < arr.size) {
        if (!predicate(arr[i])) {
            return false
        }
        i += 1
    }
    return true
}

// Returns a new array containing elements that satisfy predicate.
public func collectionFilter<T>(arr: Array<T>, predicate: (T) -> Bool): Array<T> {
    let result = ArrayList<T>()
    var i: Int64 = 0
    while (i < arr.size) {
        if (predicate(arr[i])) {
            result.add(arr[i])
        }
        i += 1
    }
    let sz = result.size
    let immutable = result
    return Array<T>(sz, { j: Int64 => immutable[j] })
}

// Returns a new array with each element transformed by transform.
public func collectionMap<T, U>(arr: Array<T>, transform: (T) -> U): Array<U> {
    return Array<U>(arr.size, { i: Int64 => transform(arr[i]) })
}

// Returns the first index where predicate returns true, or None.
public func collectionFirstIndex<T>(arr: Array<T>, predicate: (T) -> Bool): Option<Int64> {
    var i: Int64 = 0
    while (i < arr.size) {
        if (predicate(arr[i])) {
            return Some(i)
        }
        i += 1
    }
    return None
}

// Binary-search style: returns the first index where predicate is true.
// Requires that predicate(arr[i]) is false for all i < result.
// If no element satisfies predicate, returns arr.size.
public func partitioningIndex<T>(arr: Array<T>, predicate: (T) -> Bool): Int64 {
    var lo: Int64 = 0
    var hi: Int64 = arr.size
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2
        if (predicate(arr[mid])) {
            hi = mid
        } else {
            lo = mid + 1
        }
    }
    return lo
}

// ============================================================
// DeviceModelInfo — entry in the iOS hardware identifier table
// ============================================================

public struct DeviceModelInfo {
    public let identifier: String
    public let modelName: String

    public init(identifier!: String, modelName!: String) {
        this.identifier = identifier
        this.modelName = modelName
    }
}

// ============================================================
// DeviceModel
//
// HarmonyOS equivalent of the iOS DeviceModel utility.
// ============================================================

public class DeviceModel {

    // Returns a human-readable device model string for the current device.
    public static func currentModelName(): String {
        let brand = getDeviceBrand()
        let model = getDeviceProductModel()
        if (brand.size > 0 && model.size > 0) {
            return brand + " " + model
        }
        if (model.size > 0) {
            return model
        }
        return "HarmonyOS Device"
    }

    // Returns the OS version string.
    public static func osVersionString(): String {
        return getOsVersion()
    }

    // Returns true when running on a large-screen tablet form factor.
    public static func isTablet(): Bool {
        let t = getDeviceType()
        return t == "tablet" || t == "2in1"
    }

    // Looks up the marketing model name for a given iOS hardware identifier.
    public static func modelNameFromIdentifier(identifier: String): String {
        let table = buildModelTable()
        var i: Int64 = 0
        while (i < table.size) {
            let entry = table[i]
            if (entry.identifier == identifier) {
                return entry.modelName
            }
            i += 1
        }
        if (identifier.startsWith("iPhone")) {
            return "Unknown iPhone"
        }
        if (identifier.startsWith("iPod")) {
            return "Unknown iPod"
        }
        if (identifier.startsWith("iPad")) {
            return "Unknown iPad"
        }
        return "Unknown Device"
    }

    // Returns the complete iOS hardware identifier to model name mapping table.
    public static func buildModelTable(): Array<DeviceModelInfo> {
        return [
            DeviceModelInfo(identifier: "iPod1,1", modelName: "iPod touch 1G"),
            DeviceModelInfo(identifier: "iPod2,1", modelName: "iPod touch 2G"),
            DeviceModelInfo(identifier: "iPod3,1", modelName: "iPod touch 3G"),
            DeviceModelInfo(identifier: "iPod4,1", modelName: "iPod touch 4G"),
            DeviceModelInfo(identifier: "iPod5,1", modelName: "iPod touch 5G"),
            DeviceModelInfo(identifier: "iPod7,1", modelName: "iPod touch 6G"),
            DeviceModelInfo(identifier: "iPod9,1", modelName: "iPod touch 7G"),
            DeviceModelInfo(identifier: "iPhone1,1", modelName: "iPhone"),
            DeviceModelInfo(identifier: "iPhone1,2", modelName: "iPhone 3G"),
            DeviceModelInfo(identifier: "iPhone2,1", modelName: "iPhone 3GS"),
            DeviceModelInfo(identifier: "iPhone3,1", modelName: "iPhone 4"),
            DeviceModelInfo(identifier: "iPhone3,2", modelName: "iPhone 4"),
            DeviceModelInfo(identifier: "iPhone3,3", modelName: "iPhone 4"),
            DeviceModelInfo(identifier: "iPhone4,1", modelName: "iPhone 4S"),
            DeviceModelInfo(identifier: "iPhone4,2", modelName: "iPhone 4S"),
            DeviceModelInfo(identifier: "iPhone4,3", modelName: "iPhone 4S"),
            DeviceModelInfo(identifier: "iPhone5,1", modelName: "iPhone 5"),
            DeviceModelInfo(identifier: "iPhone5,2", modelName: "iPhone 5"),
            DeviceModelInfo(identifier: "iPhone5,3", modelName: "iPhone 5C"),
            DeviceModelInfo(identifier: "iPhone5,4", modelName: "iPhone 5C"),
            DeviceModelInfo(identifier: "iPhone6,1", modelName: "iPhone 5S"),
            DeviceModelInfo(identifier: "iPhone6,2", modelName: "iPhone 5S"),
            DeviceModelInfo(identifier: "iPhone7,2", modelName: "iPhone 6"),
            DeviceModelInfo(identifier: "iPhone7,1", modelName: "iPhone 6 Plus"),
            DeviceModelInfo(identifier: "iPhone8,1", modelName: "iPhone 6S"),
            DeviceModelInfo(identifier: "iPhone8,2", modelName: "iPhone 6S Plus"),
            DeviceModelInfo(identifier: "iPhone8,4", modelName: "iPhone SE"),
            DeviceModelInfo(identifier: "iPhone9,1", modelName: "iPhone 7"),
            DeviceModelInfo(identifier: "iPhone9,3", modelName: "iPhone 7"),
            DeviceModelInfo(identifier: "iPhone9,2", modelName: "iPhone 7 Plus"),
            DeviceModelInfo(identifier: "iPhone9,4", modelName: "iPhone 7 Plus"),
            DeviceModelInfo(identifier: "iPhone10,1", modelName: "iPhone 8"),
            DeviceModelInfo(identifier: "iPhone10,4", modelName: "iPhone 8"),
            DeviceModelInfo(identifier: "iPhone10,2", modelName: "iPhone 8 Plus"),
            DeviceModelInfo(identifier: "iPhone10,5", modelName: "iPhone 8 Plus"),
            DeviceModelInfo(identifier: "iPhone10,3", modelName: "iPhone X"),
            DeviceModelInfo(identifier: "iPhone10,6", modelName: "iPhone X"),
            DeviceModelInfo(identifier: "iPhone11,2", modelName: "iPhone XS"),
            DeviceModelInfo(identifier: "iPhone11,4", modelName: "iPhone XS Max"),
            DeviceModelInfo(identifier: "iPhone11,6", modelName: "iPhone XS Max"),
            DeviceModelInfo(identifier: "iPhone11,8", modelName: "iPhone XR"),
            DeviceModelInfo(identifier: "iPhone12,1", modelName: "iPhone 11"),
            DeviceModelInfo(identifier: "iPhone12,3", modelName: "iPhone 11 Pro"),
            DeviceModelInfo(identifier: "iPhone12,5", modelName: "iPhone 11 Pro Max"),
            DeviceModelInfo(identifier: "iPhone12,8", modelName: "iPhone SE (2nd gen)"),
            DeviceModelInfo(identifier: "iPhone13,2", modelName: "iPhone 12"),
            DeviceModelInfo(identifier: "iPhone13,1", modelName: "iPhone 12 mini"),
            DeviceModelInfo(identifier: "iPhone13,3", modelName: "iPhone 12 Pro"),
            DeviceModelInfo(identifier: "iPhone13,4", modelName: "iPhone 12 Pro Max"),
            DeviceModelInfo(identifier: "iPhone14,5", modelName: "iPhone 13"),
            DeviceModelInfo(identifier: "iPhone14,4", modelName: "iPhone 13 mini"),
            DeviceModelInfo(identifier: "iPhone14,2", modelName: "iPhone 13 Pro"),
            DeviceModelInfo(identifier: "iPhone14,3", modelName: "iPhone 13 Pro Max"),
            DeviceModelInfo(identifier: "iPhone14,6", modelName: "iPhone SE (3rd gen)"),
            DeviceModelInfo(identifier: "iPhone14,7", modelName: "iPhone 14"),
            DeviceModelInfo(identifier: "iPhone14,8", modelName: "iPhone 14 Plus"),
            DeviceModelInfo(identifier: "iPhone15,2", modelName: "iPhone 14 Pro"),
            DeviceModelInfo(identifier: "iPhone15,3", modelName: "iPhone 14 Pro Max"),
            DeviceModelInfo(identifier: "iPhone15,4", modelName: "iPhone 15"),
            DeviceModelInfo(identifier: "iPhone15,5", modelName: "iPhone 15 Plus"),
            DeviceModelInfo(identifier: "iPhone16,1", modelName: "iPhone 15 Pro"),
            DeviceModelInfo(identifier: "iPhone16,2", modelName: "iPhone 15 Pro Max"),
            DeviceModelInfo(identifier: "iPhone17,3", modelName: "iPhone 16"),
            DeviceModelInfo(identifier: "iPhone17,4", modelName: "iPhone 16 Plus"),
            DeviceModelInfo(identifier: "iPhone17,1", modelName: "iPhone 16 Pro"),
            DeviceModelInfo(identifier: "iPhone17,2", modelName: "iPhone 16 Pro Max"),
            DeviceModelInfo(identifier: "iPhone17,5", modelName: "iPhone 16e"),
            DeviceModelInfo(identifier: "iPhone18,3", modelName: "iPhone 17"),
            DeviceModelInfo(identifier: "iPhone18,1", modelName: "iPhone 17 Pro"),
            DeviceModelInfo(identifier: "iPhone18,2", modelName: "iPhone 17 Pro Max"),
            DeviceModelInfo(identifier: "iPhone18,4", modelName: "iPhone Air")
        ]
    }
}

// ============================================================
// Device info global state
//
// Injected at app startup from main_ability.cj via setDeviceInfo().
// ============================================================

private var _deviceBrand: String = ""
private var _deviceProductModel: String = ""
private var _osVersion: String = ""
private var _deviceType: String = "phone"

public func setDeviceInfo(brand: String, model: String, osVersion: String, deviceType: String): Unit {
    _deviceBrand = brand
    _deviceProductModel = model
    _osVersion = osVersion
    _deviceType = deviceType
}

public func getDeviceBrand(): String {
    return _deviceBrand
}

public func getDeviceProductModel(): String {
    return _deviceProductModel
}

public func getOsVersion(): String {
    return _osVersion
}

public func getDeviceType(): String {
    return _deviceType
}

// ============================================================
// VolumeButtonsListener / VolumeButtonsManager
//
// HarmonyOS equivalent of the iOS VolumeButtonsListener.
//
// Standard HarmonyOS key codes:
//   KEYCODE_VOLUME_UP   = 16
//   KEYCODE_VOLUME_DOWN = 17
// ============================================================

public let KEYCODE_VOLUME_UP: Int32 = 16
public let KEYCODE_VOLUME_DOWN: Int32 = 17

public let KEY_ACTION_DOWN: Int32 = 0
public let KEY_ACTION_UP: Int32 = 1

public class VolumeButtonsListener {

    private let _id: Int64
    private let _onUpPressed: () -> Unit
    private let _onUpReleased: () -> Unit
    private let _onDownPressed: () -> Unit
    private let _onDownReleased: () -> Unit
    private var _isActive: Bool

    public init(
        id!: Int64,
        onUpPressed!: () -> Unit,
        onUpReleased!: () -> Unit,
        onDownPressed!: () -> Unit,
        onDownReleased!: () -> Unit,
        isActive!: Bool
    ) {
        _id = id
        _onUpPressed = onUpPressed
        _onUpReleased = onUpReleased
        _onDownPressed = onDownPressed
        _onDownReleased = onDownReleased
        _isActive = isActive
    }

    public prop id: Int64 {
        get() { return _id }
    }

    public prop isActive: Bool {
        get() { return _isActive }
    }

    public func setActive(active: Bool): Unit {
        _isActive = active
    }

    public func notifyUpPressed(): Unit {
        _onUpPressed()
    }

    public func notifyUpReleased(): Unit {
        _onUpReleased()
    }

    public func notifyDownPressed(): Unit {
        _onDownPressed()
    }

    public func notifyDownReleased(): Unit {
        _onDownReleased()
    }
}

public class VolumeButtonsManager {

    private static let _instance: VolumeButtonsManager = VolumeButtonsManager()
    private let _mutex: Mutex = Mutex()
    private var _listeners: ArrayList<VolumeButtonsListener> = ArrayList<VolumeButtonsListener>()
    private var _nextId: Int64 = 0

    private init() {}

    public static func shared(): VolumeButtonsManager {
        return _instance
    }

    // Register a new volume button listener.
    public func register(
        onUpPressed!: () -> Unit,
        onUpReleased!: () -> Unit,
        onDownPressed!: () -> Unit,
        onDownReleased!: () -> Unit,
        isActive!: Bool
    ): VolumeButtonsListener {
        _mutex.lock()
        let id = _nextId
        _nextId += 1
        let listener = VolumeButtonsListener(
            id: id,
            onUpPressed: onUpPressed,
            onUpReleased: onUpReleased,
            onDownPressed: onDownPressed,
            onDownReleased: onDownReleased,
            isActive: isActive
        )
        _listeners.add(listener)
        _mutex.unlock()
        return listener
    }

    // Remove the listener with the given id.
    public func unregister(id: Int64): Unit {
        _mutex.lock()
        var i: Int64 = 0
        while (i < _listeners.size) {
            if (_listeners[i].id == id) {
                _listeners.remove(at: i)
                break
            }
            i += 1
        }
        _mutex.unlock()
    }

    // Change the active state of the listener with the given id.
    public func setActive(id: Int64, active: Bool): Unit {
        _mutex.lock()
        var i: Int64 = 0
        while (i < _listeners.size) {
            if (_listeners[i].id == id) {
                _listeners[i].setActive(active)
                break
            }
            i += 1
        }
        _mutex.unlock()
    }

    // Route a HarmonyOS key event to the topmost active listener.
    // Returns true if handled.
    public func onKeyEvent(keyCode: Int32, action: Int32): Bool {
        if (keyCode != KEYCODE_VOLUME_UP && keyCode != KEYCODE_VOLUME_DOWN) {
            return false
        }
        _mutex.lock()
        let sz = _listeners.size
        let snapshot = Array<VolumeButtonsListener>(sz, { i: Int64 => _listeners[i] })
        _mutex.unlock()

        var i: Int64 = snapshot.size - 1
        while (i >= 0) {
            let listener = snapshot[i]
            if (listener.isActive) {
                if (keyCode == KEYCODE_VOLUME_UP) {
                    if (action == KEY_ACTION_DOWN) {
                        listener.notifyUpPressed()
                    } else {
                        listener.notifyUpReleased()
                    }
                } else {
                    if (action == KEY_ACTION_DOWN) {
                        listener.notifyDownPressed()
                    } else {
                        listener.notifyDownReleased()
                    }
                }
                return true
            }
            i -= 1
        }
        return false
    }
}
