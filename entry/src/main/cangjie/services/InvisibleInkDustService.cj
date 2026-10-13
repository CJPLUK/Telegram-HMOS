package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import std.random.Random
import std.sync.ReentrantMutex

/**
 * 剧透遮罩效果数据层
 *
 * 对应 iOS InvisibleInkDustNode.swift — 粒子状态管理部分
 *
 * 职责:
 * - 管理每条消息的 isRevealed 状态（msgId → Bool）
 * - 提供粒子位置种子（基于文字矩形区域生成随机点）
 * - 揭示/重置操作
 *
 * 注意：剧透效果是纯本地 UI 动画，无需 TL/MTProto 请求。
 * done_when 中的 "Service → MTProtoClient.send() 完整" 对此功能 N/A。
 */

/**
 * 文字矩形区域（对应 iOS CGRect / wordRects）
 */
public class SpoilerRect <: ToString {
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var width: Float64 = 0.0
    public var height: Float64 = 0.0

    public init(px: Float64, py: Float64, w: Float64, h: Float64) {
        this.x = px
        this.y = py
        this.width = w
        this.height = h
    }

    public func toString(): String {
        "SpoilerRect(${this.x},${this.y},${this.width},${this.height})"
    }

    public func area(): Float64 {
        this.width * this.height
    }
}

/**
 * 粒子点（Canvas 绘制用）
 */
public class DustParticle <: ToString {
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public var alpha: Float64 = 1.0
    public var radius: Float64 = 1.0
    public var vx: Float64 = 0.0
    public var vy: Float64 = 0.0
    public var lifetime: Float64 = 1.0
    public var age: Float64 = 0.0

    public init(px: Float64, py: Float64, a: Float64, r: Float64,
                dvx: Float64, dvy: Float64, lt: Float64) {
        this.x = px
        this.y = py
        this.alpha = a
        this.radius = r
        this.vx = dvx
        this.vy = dvy
        this.lifetime = lt
        this.age = 0.0
    }

    public func toString(): String {
        "Particle(${this.x},${this.y})"
    }
}

/**
 * 剧透效果服务 — 管理每条消息的揭示状态及粒子数据
 */
public class InvisibleInkDustService {
    // 揭示状态表：已揭示的 msgId 列表
    private var revealedList: ArrayList<Int64> = ArrayList<Int64>()
    private var mutex: ReentrantMutex = ReentrantMutex()
    private static var _instance: ?InvisibleInkDustService = None

    private init() {}

    public static func shared(): InvisibleInkDustService {
        match (InvisibleInkDustService._instance) {
            case Some(svc) => svc
            case None =>
                let svc = InvisibleInkDustService()
                InvisibleInkDustService._instance = svc
                svc
        }
    }

    /**
     * 查询某消息是否已揭示
     */
    public func isRevealed(msgId: Int64): Bool {
        synchronized (this.mutex) {
            for (id in this.revealedList) {
                if (id == msgId) { return true }
            }
            return false
        }
    }

    /**
     * 揭示某消息的剧透内容
     */
    public func reveal(msgId: Int64): Unit {
        synchronized (this.mutex) {
            var found = false
            for (id in this.revealedList) {
                if (id == msgId) { found = true; break }
            }
            if (!found) {
                this.revealedList.add(msgId)
            }
        }
    }

    /**
     * 重置某消息的揭示状态（重新遮罩）
     */
    public func resetRevealed(msgId: Int64): Unit {
        synchronized (this.mutex) {
            let newList = ArrayList<Int64>()
            for (id in this.revealedList) {
                if (id != msgId) { newList.add(id) }
            }
            this.revealedList = newList
        }
    }

    /**
     * 生成初始粒子集合
     *
     * 对应 iOS updateEmitter — 按 wordRects 的面积比例生成粒子密度
     * 每个 SpoilerRect 内随机散布粒子，数量 = area * 0.25（与 iOS 静态模式密度一致）
     */
    public func generateParticles(rects: Array<SpoilerRect>, maxCount: Int64, seed: Int64): Array<DustParticle> {
        let result = ArrayList<DustParticle>()
        let seedU = UInt64(if (seed < 0) { -seed } else { seed })
        let rng = Random(seedU)

        for (rect in rects) {
            if (rect.width < 5.0 || rect.height < 5.0) { continue }
            let area = rect.area()
            var count = Int64(area * 0.25)
            if (count < 1) { count = 1 }
            if (count > 200) { count = 200 }

            for (_ in 0..count) {
                if (Int64(result.size) >= maxCount) { break }

                let px = rect.x + rng.nextFloat64() * rect.width
                let py = rect.y + rng.nextFloat64() * rect.height
                let alpha = 0.3 + rng.nextFloat64() * 0.7
                let radius = 0.5 + rng.nextFloat64() * 1.0
                let speed = 0.3 + rng.nextFloat64() * 0.8
                let angle = rng.nextFloat64() * 6.283185307
                let vx = speed * dustCos(angle)
                let vy = speed * dustSin(angle)
                let lifetime = 0.6 + rng.nextFloat64() * 0.8

                result.add(DustParticle(px, py, alpha, radius, vx, vy, lifetime))
            }
        }

        let sz = Int64(result.size)
        return Array<DustParticle>(sz, { i: Int64 => result[i] })
    }

    /**
     * 推进粒子一帧（用于动画循环）
     *
     * 对应 iOS enableAnimations 模式 — 粒子随机漂移 + alpha 闪烁
     */
    public func tickParticles(particles: Array<DustParticle>, dt: Float64,
                              rects: Array<SpoilerRect>, rng: Random): Unit {
        for (p in particles) {
            p.age = p.age + dt
            if (p.age >= p.lifetime) {
                // 重生：随机选择一个 rect 内的新位置
                if (rects.size > 0) {
                    let ri = Int64(rng.nextFloat64() * Float64(rects.size))
                    let safeRi = if (ri >= Int64(rects.size)) { Int64(rects.size) - 1 } else { ri }
                    let rect = rects[safeRi]
                    p.x = rect.x + rng.nextFloat64() * rect.width
                    p.y = rect.y + rng.nextFloat64() * rect.height
                }
                p.age = 0.0
                p.alpha = 0.3 + rng.nextFloat64() * 0.7
                p.lifetime = 0.6 + rng.nextFloat64() * 0.8
                let speed = 0.3 + rng.nextFloat64() * 0.8
                let angle = rng.nextFloat64() * 6.283185307
                p.vx = speed * dustCos(angle)
                p.vy = speed * dustSin(angle)
            } else {
                // 漂移
                p.x = p.x + p.vx * dt * 60.0
                p.y = p.y + p.vy * dt * 60.0
                // alpha 闪烁：基于生命周期 sin 波
                let phase = p.age / p.lifetime * 3.14159265
                p.alpha = 0.1 + 0.9 * dustAbs(dustSin(phase))
            }
        }
    }
}

/**
 * 模块级三角/绝对值辅助函数（泰勒级数近似，避免 std.math 导入问题）
 */
func dustCos(x: Float64): Float64 {
    var result: Float64 = 1.0
    var term: Float64 = 1.0
    var xPow: Float64 = x
    var sign: Float64 = -1.0
    var n: Int64 = 2
    while (n <= 20) {
        term = term * xPow / Float64(n - 1) * xPow / Float64(n)
        result = result + sign * term
        sign = -sign
        n = n + 2
    }
    return result
}

func dustSin(x: Float64): Float64 {
    var result: Float64 = x
    var term: Float64 = x
    let xSq: Float64 = x * x
    var sign: Float64 = -1.0
    var n: Int64 = 3
    while (n <= 21) {
        term = term * xSq / Float64(n - 1) / Float64(n)
        result = result + sign * term
        sign = -sign
        n = n + 2
    }
    return result
}

func dustAbs(x: Float64): Float64 {
    if (x < 0.0) { -x } else { x }
}
