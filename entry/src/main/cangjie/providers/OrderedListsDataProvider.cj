package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getOrderedListsService, OrderedListsService}
import ohos_app_cangjie_entry.services.{OrderedListEntry, OrderedListResult, OrderedListEntriesResult}
import std.collection.ArrayList

// ==================== UI ViewModel Types ====================

/**
 * OrderedListEntryViewModel — 单个有序列表条目的 UI 展示模型
 */
public class OrderedListEntryViewModel {
    public var id: String = ""
    public var contents: String = ""
    public var addedAt: Int64 = 0

    public init() {}

    /** 从 OrderedListEntry 构建 ViewModel */
    public static func fromEntry(entry: OrderedListEntry): OrderedListEntryViewModel {
        let vm = OrderedListEntryViewModel()
        vm.id = entry.id
        vm.contents = entry.contents
        vm.addedAt = entry.addedAt
        return vm
    }
}

/**
 * OrderedListViewModel — 有序列表查询结果 ViewModel（含条目列表）
 */
public class OrderedListViewModel {
    public var entries: ArrayList<OrderedListEntryViewModel> = ArrayList<OrderedListEntryViewModel>()
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * OrderedListActionViewModel — 增删改操作结果 ViewModel
 */
public class OrderedListActionViewModel {
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}

    /** 从 OrderedListResult 构建 ViewModel */
    public static func fromResult(r: OrderedListResult): OrderedListActionViewModel {
        let vm = OrderedListActionViewModel()
        vm.success = r.success
        vm.errorMessage = r.errorMessage
        return vm
    }
}

// ==================== DataProvider Singleton ====================

private var _orderedListsDataProviderInstance: Option<OrderedListsDataProvider> = None

public func getOrderedListsDataProvider(): OrderedListsDataProvider {
    match (_orderedListsDataProviderInstance) {
        case Some(inst) => inst
        case None =>
            let inst = OrderedListsDataProvider()
            _orderedListsDataProviderInstance = Some(inst)
            inst
    }
}

// ==================== OrderedListsDataProvider ====================

/**
 * OrderedListsDataProvider — 有序列表引擎数据接口层
 *
 * 将 OrderedListsService 的 API 数据转为 UI 可用的 ViewModel。
 * 封装最近 GIF / 贴纸 / inline bot 等带顺序的本地列表的增删改查操作。
 *
 * 调用链: UI → OrderedListsDataProvider → OrderedListsService → Preferences (persistent storage)
 *
 * collectionId 语义（与 iOS TelegramEngine.OrderedLists 保持一致）:
 *   0 = recentGifs
 *   1 = recentStickers
 *   2 = inlineBots
 *   其他 = 业务自定义
 */
public class OrderedListsDataProvider {

    /**
     * 获取指定集合的所有条目（最近优先顺序）
     *
     * @param collectionId 集合 ID（0=recentGifs, 1=recentStickers, 2=inlineBots, 其他=自定义）
     */
    public func getItems(collectionId: Int32): OrderedListViewModel {
        Hilog.info(0, "CjTelegram", "[OrderedListsDP] getItems colId=${collectionId}")
        let service = getOrderedListsService()
        let result = service.getItems(collectionId)
        let vm = OrderedListViewModel()
        if (!result.success) {
            vm.errorMessage = if (result.errorMessage.size > 0) { result.errorMessage } else { "获取列表失败" }
            return vm
        }
        for (entry in result.entries) {
            vm.entries.add(OrderedListEntryViewModel.fromEntry(entry))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[OrderedListsDP] getItems OK count=${vm.entries.size}")
        return vm
    }

    /**
     * 添加或移动条目到列表首位（最近优先）
     *
     * 对应 iOS: addOrMoveToFirstPosition(collectionId:id:item:removeTailIfCountExceeds:)
     * 若 id 已存在则移到首位；maxCount > 0 时裁剪末尾超出条目。
     *
     * @param collectionId 集合 ID
     * @param id           条目唯一 ID（MemoryBuffer 的字符串形式）
     * @param contents     条目序列化内容（JSON 字符串）
     * @param maxCount     超出此数量时删除末尾条目，-1 表示使用默认值（200）
     */
    public func addOrMoveToFirstPosition(
        collectionId: Int32,
        id: String,
        contents: String,
        maxCount!: Int32 = -1
    ): OrderedListActionViewModel {
        Hilog.info(0, "CjTelegram", "[OrderedListsDP] addOrMoveToFirst colId=${collectionId} id=${id}")
        let service = getOrderedListsService()
        let result = service.addOrMoveToFirstPosition(collectionId, id, contents, maxCount: maxCount)
        let vm = OrderedListActionViewModel.fromResult(result)
        if (vm.success) {
            Hilog.info(0, "CjTelegram", "[OrderedListsDP] addOrMoveToFirst OK")
        } else {
            Hilog.info(0, "CjTelegram", "[OrderedListsDP] addOrMoveToFirst failed: ${vm.errorMessage}")
        }
        return vm
    }

    /**
     * 移除指定条目
     *
     * 对应 iOS: removeItem(collectionId:id:)
     */
    public func removeItem(collectionId: Int32, id: String): OrderedListActionViewModel {
        Hilog.info(0, "CjTelegram", "[OrderedListsDP] removeItem colId=${collectionId} id=${id}")
        let service = getOrderedListsService()
        let result = service.removeItem(collectionId, id)
        let vm = OrderedListActionViewModel.fromResult(result)
        if (vm.success) {
            Hilog.info(0, "CjTelegram", "[OrderedListsDP] removeItem OK")
        } else {
            Hilog.info(0, "CjTelegram", "[OrderedListsDP] removeItem failed: ${vm.errorMessage}")
        }
        return vm
    }

    /**
     * 清空指定集合的所有条目
     *
     * 对应 iOS: clear(collectionId:)
     */
    public func clear(collectionId: Int32): OrderedListActionViewModel {
        Hilog.info(0, "CjTelegram", "[OrderedListsDP] clear colId=${collectionId}")
        let service = getOrderedListsService()
        let result = service.clear(collectionId)
        let vm = OrderedListActionViewModel.fromResult(result)
        if (vm.success) {
            Hilog.info(0, "CjTelegram", "[OrderedListsDP] clear OK")
        } else {
            Hilog.info(0, "CjTelegram", "[OrderedListsDP] clear failed: ${vm.errorMessage}")
        }
        return vm
    }

    /**
     * 检查条目是否存在于集合中
     */
    public func contains(collectionId: Int32, id: String): Bool {
        let service = getOrderedListsService()
        return service.contains(collectionId, id)
    }

    /**
     * 获取集合当前条目数量
     */
    public func count(collectionId: Int32): Int32 {
        let service = getOrderedListsService()
        return service.count(collectionId)
    }
}
