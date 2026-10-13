package ohos_app_cangjie_entry.utils

/**
 * 固定容量泛型环形缓冲区。
 *
 * 对应 iOS Telegram submodules/RingBuffer（TPCircularBuffer：定长循环缓冲，生产者/消费者 FIFO）。
 *   iOS 版借页镜像实现连续地址的字节环；这里以元素级 FIFO 抽象提供等价语义。
 *
 * 满时策略：**覆盖最旧元素（overwrite-oldest）**。
 *   选择理由：环形缓冲最常见用途是保留"最近 N 条"（日志 / 帧 / 事件历史），满时丢弃最旧、push 恒成功，
 *   语义与 TPCircularBuffer 在写满后由消费者驱动消费、用作滚动窗口的定位一致；调用方无需处理 push 失败分支。
 *
 * 行为：
 *   - 容量 capacity 必须 > 0。
 *   - push：写入队尾；若已满则同时前移队头（丢弃最旧）。
 *   - pop：取出并移除队头（最旧）；空时 None。
 *   - peek：查看队头（最旧）但不移除；空时 None。
 *   - toArray：按 FIFO 顺序（旧→新）导出当前元素快照。
 */
public class RingBuffer<T> {
    private let storage: Array<Option<T>>
    private let cap: Int64
    private var head: Int64        // 最旧元素下标
    private var count: Int64       // 当前元素个数

    public init(capacity: Int64) {
        if (capacity <= 0) {
            throw IllegalArgumentException("RingBuffer capacity must be > 0")
        }
        this.cap = capacity
        this.storage = Array<Option<T>>(capacity, { _ => Option<T>.None })
        this.head = 0
        this.count = 0
    }

    /**
     * 写入队尾。满时覆盖最旧元素（push 恒成功）。
     */
    public func push(item: T): Unit {
        let tail = (head + count) % cap
        storage[tail] = Some(item)
        if (count == cap) {
            // 已满：刚才覆盖的就是旧队头，队头前移。
            head = (head + 1) % cap
        } else {
            count += 1
        }
    }

    /**
     * 取出并移除最旧元素；空时 None。
     */
    public func pop(): Option<T> {
        if (count == 0) {
            return None
        }
        let v = storage[head]
        storage[head] = Option<T>.None
        head = (head + 1) % cap
        count -= 1
        return v
    }

    /**
     * 查看最旧元素但不移除；空时 None。
     */
    public func peek(): Option<T> {
        if (count == 0) {
            return None
        }
        return storage[head]
    }

    /**
     * 当前元素个数。
     */
    public func size(): Int64 {
        return count
    }

    /**
     * 容量。
     */
    public func capacity(): Int64 {
        return cap
    }

    /**
     * 是否已满。
     */
    public func isFull(): Bool {
        return count == cap
    }

    /**
     * 是否为空。
     */
    public func isEmpty(): Bool {
        return count == 0
    }

    /**
     * 清空所有元素。
     */
    public func clear(): Unit {
        for (i in 0..cap) {
            storage[i] = Option<T>.None
        }
        head = 0
        count = 0
    }

    /**
     * 按 FIFO 顺序（旧→新）导出当前元素快照。
     */
    public func toArray(): Array<T> {
        // 直接按 count 构造定长数组，元素按 FIFO 顺序（旧→新）从环形存储取出。
        return Array<T>(count, {
            i: Int64 =>
            let idx = (head + i) % cap
            match (storage[idx]) {
                case Some(v) => v
                case None => throw Exception("RingBuffer internal inconsistency at index ${idx}")
            }
        })
    }
}

/**
 * 自检：push/pop/peek、wrap-around 覆盖、容量边界。
 */
public func ringBufferSelfCheck(): Bool {
    let rb = RingBuffer<Int64>(3)
    if (!rb.isEmpty()) { return false }
    if (rb.size() != 0) { return false }

    // peek/pop 空时 None。
    match (rb.peek()) { case Some(_) => return false; case None => () }
    match (rb.pop()) { case Some(_) => return false; case None => () }

    rb.push(1)
    rb.push(2)
    rb.push(3)
    if (!rb.isFull()) { return false }
    if (rb.size() != 3) { return false }

    // peek 最旧 = 1（不移除）。
    match (rb.peek()) { case Some(v) => if (v != 1) { return false }; case None => return false }
    if (rb.size() != 3) { return false }

    // wrap-around：push 4 覆盖最旧 1 → 队列变 [2,3,4]。
    rb.push(4)
    if (rb.size() != 3) { return false }
    let snap = rb.toArray()
    if (snap.size != 3 || snap[0] != 2 || snap[1] != 3 || snap[2] != 4) { return false }

    // 依次 pop：2,3,4。
    match (rb.pop()) { case Some(v) => if (v != 2) { return false }; case None => return false }
    match (rb.pop()) { case Some(v) => if (v != 3) { return false }; case None => return false }
    match (rb.pop()) { case Some(v) => if (v != 4) { return false }; case None => return false }
    if (!rb.isEmpty()) { return false }

    // clear。
    rb.push(9)
    rb.clear()
    if (!rb.isEmpty() || rb.size() != 0) { return false }

    return true
}
