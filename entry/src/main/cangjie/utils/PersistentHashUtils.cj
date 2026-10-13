package ohos_app_cangjie_entry.utils

/**
 * 确定性字符串哈希（跨运行稳定，用于缓存键 / 索引主键派生）。
 *
 * 对应 iOS Telegram submodules/PersistentStringHash：
 *   iOS `String.persistentHashValue` 是 djb2 变体（result = 127 * (result & mask) + b，种子 5381）。
 *   本工程已在 services/ICloudResourcesService.simpleStringHash 与
 *   core/storage/postbox/MediaResourceIndexTable.hashResourceId 采用 djb2 XOR 变体
 *   `hash = (hash * 33) ^ code`（种子 5381）作为"对应 iOS enginePersistentHash32 的等效替代"。
 *
 * 设计要点：
 *   - 这里**复用工程内既有的 djb2 XOR 变体**（而非 iOS 原版 127*… 公式），与上述两处保持同一算法，
 *     避免同一工程出现两套不兼容的"持久哈希"口径。关键性质——确定性：相同输入恒得相同输出，
 *     不同输入大概率不同——两者一致。
 *   - 以 Rune（Unicode 码点）为单位累积，对 UTF-8 多字节字符也稳定。
 *   - 输出折叠到 Int32：内部以非负 Int64 计算后取低 32 位 reinterpret 成 Int32。
 */

/**
 * 确定性 32 位字符串哈希。相同字符串恒返回相同值。
 */
public func persistentHash32(s: String): Int32 {
    var hash: Int64 = 5381
    for (r in s.toRuneArray()) {
        let code = Int64(UInt32(r))
        // 与工程既有 simpleStringHash / hashResourceId 同算法（djb2 XOR 变体）。
        hash = ((hash * 33) ^ code) & 0x7FFFFFFFFFFFFFFF
    }
    // 取低 32 位并按位 reinterpret 成 Int32（经 UInt32 中转，保留全部 32 位信息）。
    let low32 = UInt32(hash & 0xFFFFFFFF)
    return Int32(low32)
}

/**
 * 自检：确定性（同串同值）+ 区分性（不同串不同值）。
 */
public func persistentHashSelfCheck(): Bool {
    // 确定性：同一字符串两次调用结果一致。
    let a1 = persistentHash32("telegram-cache-key")
    let a2 = persistentHash32("telegram-cache-key")
    if (a1 != a2) { return false }

    // 区分性：不同字符串得到不同值（对这组样例成立）。
    let b = persistentHash32("telegram-cache-keys")
    if (a1 == b) { return false }

    // 空串稳定（种子折叠后的固定值），且可重复。
    if (persistentHash32("") != persistentHash32("")) { return false }

    // 大小写敏感：不同输入应不同。
    if (persistentHash32("ABC") == persistentHash32("abc")) { return false }

    return true
}
