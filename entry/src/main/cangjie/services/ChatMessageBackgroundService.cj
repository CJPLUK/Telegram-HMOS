package ohos_app_cangjie_entry.services

/**
 * ChatMessageBackgroundService — 消息气泡背景数据层
 *
 * 对应 iOS ChatMessageBackground.swift 的数据逻辑部分。
 * 提供气泡合并类型、圆角半径、背景色、是否显示尾巴等数据接口，
 * 供 ChatMessageBackgroundComponent 渲染使用。
 *
 * iOS 原版依赖 PrincipalThemeEssentialGraphics（预烘焙图片 + CoreGraphics path），
 * 鸿蒙端改为通过 ArkUI borderRadius + Canvas 实现等价渲染，无 MTProto 依赖（标记 N/A）。
 */

/** 相邻消息合并类型（对应 iOS ChatMessageBackgroundMergeType）*/
public enum ChatMessageMergeType {
    /** 独立消息，无合并 */
    | MergeNone
    /** 分组中部（上方有同 sender，下方也有同 sender）*/
    | MergeBoth
    /** 分组顶部（下方有同 sender，上方无）*/
    | MergeTop
    /** 分组底部（上方有同 sender，下方无）*/
    | MergeBottom
    /** 仅侧边线（side by side 场景） */
    | MergeSide
}

/** 消息气泡背景类型（对应 iOS ChatMessageBackgroundType）*/
public enum ChatMessageBgType {
    /** 无背景（贴纸等透明消息） */
    | BgNone
    /** 接收的消息气泡（左侧，灰色系，含尾巴） */
    | BgIncoming(ChatMessageMergeType)
    /** 发送的消息气泡（右侧，蓝色系，含尾巴） */
    | BgOutgoing(ChatMessageMergeType)
}

/** 尾巴尺寸 */
public class TailSize {
    public var tailWidth: Int64 = 8
    public var tailHeight: Int64 = 12

    public init() {}
}

/** 气泡圆角半径集（四角独立） */
public class BubbleRadii {
    public var topLeft: Int64 = 16
    public var topRight: Int64 = 16
    public var bottomLeft: Int64 = 16
    public var bottomRight: Int64 = 16
    /** 是否显示尾巴（MergeNone / MergeBottom 时显示） */
    public var showTail: Bool = true

    public init() {}
}

/** 气泡颜色配置 */
public class BubbleColors {
    /** 背景填充色（0xAARRGGBB） */
    public var fillColor: UInt32 = 0xFFF0F0F0
    /** 描边色（壁纸模式下轮廓线，无壁纸时为 0x00000000）*/
    public var strokeColor: UInt32 = 0x00000000
    /** 尾巴填充色（与 fillColor 一致或略深）*/
    public var tailColor: UInt32 = 0xFFF0F0F0

    public init() {}
}

private var _chatMsgBgServiceInstance: Option<ChatMessageBackgroundService> = None

public func getChatMessageBackgroundService(): ChatMessageBackgroundService {
    match (_chatMsgBgServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatMessageBackgroundService()
            _chatMsgBgServiceInstance = Some(inst)
            return inst
    }
}

/**
 * ChatMessageBackgroundService — 主服务类
 *
 * 所有方法为纯函数（无 MTProto 调用），根据气泡类型和当前主题色计算数据。
 */
public class ChatMessageBackgroundService {

    // 圆角常量（对应 Telegram iOS bubbleCorners mainRadius=16 auxiliaryRadius=4）
    private let radiusMax: Int64 = 16  // 完全圆角（独立消息 / 分组端点）
    private let radiusMin: Int64 = 4   // 收缩圆角（合并态连接处）

    /**
     * 根据气泡类型获取四角圆角半径及是否显示尾巴。
     * 规则：
     * - MergeNone   → 四角 max，显示尾巴
     * - MergeTop    → 上角 max，发送侧下右 min，接收侧下左 min，显示尾巴
     * - MergeBottom → 下角 max，发送侧上右 min，接收侧上左 min，不显示尾巴
     * - MergeBoth   → 收发侧连接角 min，其余 max，不显示尾巴
     * - MergeSide   → 等同 MergeNone（side 气泡视为完整气泡）
     * - BgNone      → 全 0（无背景）
     */
    public func getBubbleRadii(bgType: ChatMessageBgType): BubbleRadii {
        let r = BubbleRadii()
        match (bgType) {
            case BgNone =>
                r.topLeft = 0
                r.topRight = 0
                r.bottomLeft = 0
                r.bottomRight = 0
                r.showTail = false
            case BgIncoming(mergeType) =>
                this.applyIncomingRadii(r, mergeType)
            case BgOutgoing(mergeType) =>
                this.applyOutgoingRadii(r, mergeType)
        }
        return r
    }

    /**
     * 根据气泡类型获取背景色（考虑深色模式）。
     * 颜色规则：
     * - outgoing：蓝色系 0xFF317AFF（与 MessageBubble.cj 保持一致）
     * - incoming：灰色系 0xFFF0F0F0
     * - highlighted：发送 0xFF2564CC，接收 0xFFD6D6D6
     */
    public func getBubbleColors(bgType: ChatMessageBgType, isHighlighted: Bool, hasWallpaper: Bool): BubbleColors {
        let c = BubbleColors()
        match (bgType) {
            case BgNone =>
                c.fillColor = 0x00000000
                c.strokeColor = 0x00000000
                c.tailColor = 0x00000000
            case BgIncoming(_) =>
                if (isHighlighted) {
                    c.fillColor = 0xFFD6D6D6
                    c.tailColor = 0xFFD6D6D6
                } else {
                    c.fillColor = 0xFFF0F0F0
                    c.tailColor = 0xFFF0F0F0
                }
                if (hasWallpaper) {
                    c.strokeColor = 0x33000000
                } else {
                    c.strokeColor = 0x00000000
                }
            case BgOutgoing(_) =>
                if (isHighlighted) {
                    c.fillColor = 0xFF2564CC
                    c.tailColor = 0xFF2564CC
                } else {
                    c.fillColor = 0xFF317AFF
                    c.tailColor = 0xFF317AFF
                }
                if (hasWallpaper) {
                    c.strokeColor = 0x22FFFFFF
                } else {
                    c.strokeColor = 0x00000000
                }
        }
        return c
    }

    /**
     * 是否应显示消息尾巴（气泡指向发送者的三角形）。
     * 只有 MergeNone 和 MergeBottom 显示尾巴（分组末尾 / 独立消息）。
     */
    public func shouldShowTail(bgType: ChatMessageBgType): Bool {
        match (bgType) {
            case BgNone => return false
            case BgIncoming(mergeType) =>
                return this.isTailVisible(mergeType)
            case BgOutgoing(mergeType) =>
                return this.isTailVisible(mergeType)
        }
    }

    /**
     * 获取尾巴的尺寸（宽 × 高，vp）。
     */
    public func getTailSize(): TailSize {
        let sz = TailSize()
        sz.tailWidth = 8
        sz.tailHeight = 12
        return sz
    }

    // ==================== 私有辅助方法 ====================

    private func isTailVisible(mergeType: ChatMessageMergeType): Bool {
        match (mergeType) {
            case MergeNone => return true
            case MergeBottom => return true
            case _ => return false
        }
    }

    /**
     * incoming 气泡（左侧）圆角分配：
     * - 尾巴在左下（or 左侧）
     * - 连接角在左侧
     */
    private func applyIncomingRadii(r: BubbleRadii, mergeType: ChatMessageMergeType): Unit {
        match (mergeType) {
            case MergeNone =>
                // 独立消息：左下角给尾巴留小圆角，其余全圆角
                r.topLeft = this.radiusMax
                r.topRight = this.radiusMax
                r.bottomLeft = this.radiusMin
                r.bottomRight = this.radiusMax
                r.showTail = true
            case MergeTop =>
                // 分组顶部（下方还有消息）：左下角接连
                r.topLeft = this.radiusMax
                r.topRight = this.radiusMax
                r.bottomLeft = this.radiusMin
                r.bottomRight = this.radiusMax
                r.showTail = false
            case MergeBottom =>
                // 分组底部（上方有消息，下方没有）：左上角接连，左下角尾巴
                r.topLeft = this.radiusMin
                r.topRight = this.radiusMax
                r.bottomLeft = this.radiusMin
                r.bottomRight = this.radiusMax
                r.showTail = true
            case MergeBoth =>
                // 分组中部：上下左角都接连
                r.topLeft = this.radiusMin
                r.topRight = this.radiusMax
                r.bottomLeft = this.radiusMin
                r.bottomRight = this.radiusMax
                r.showTail = false
            case MergeSide =>
                // 侧边：与 MergeNone 相同
                r.topLeft = this.radiusMax
                r.topRight = this.radiusMax
                r.bottomLeft = this.radiusMin
                r.bottomRight = this.radiusMax
                r.showTail = true
        }
    }

    /**
     * outgoing 气泡（右侧）圆角分配：
     * - 尾巴在右下（or 右侧）
     * - 连接角在右侧
     */
    private func applyOutgoingRadii(r: BubbleRadii, mergeType: ChatMessageMergeType): Unit {
        match (mergeType) {
            case MergeNone =>
                // 独立消息：右下角给尾巴留小圆角，其余全圆角
                r.topLeft = this.radiusMax
                r.topRight = this.radiusMax
                r.bottomLeft = this.radiusMax
                r.bottomRight = this.radiusMin
                r.showTail = true
            case MergeTop =>
                // 分组顶部（下方还有消息）：右下角接连
                r.topLeft = this.radiusMax
                r.topRight = this.radiusMax
                r.bottomLeft = this.radiusMax
                r.bottomRight = this.radiusMin
                r.showTail = false
            case MergeBottom =>
                // 分组底部（上方有消息）：右上角接连，右下角尾巴
                r.topLeft = this.radiusMax
                r.topRight = this.radiusMin
                r.bottomLeft = this.radiusMax
                r.bottomRight = this.radiusMin
                r.showTail = true
            case MergeBoth =>
                // 分组中部：上下右角都接连
                r.topLeft = this.radiusMax
                r.topRight = this.radiusMin
                r.bottomLeft = this.radiusMax
                r.bottomRight = this.radiusMin
                r.showTail = false
            case MergeSide =>
                // 侧边：与 MergeNone 相同
                r.topLeft = this.radiusMax
                r.topRight = this.radiusMax
                r.bottomLeft = this.radiusMax
                r.bottomRight = this.radiusMin
                r.showTail = true
        }
    }
}
