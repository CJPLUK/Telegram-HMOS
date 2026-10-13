package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.HashMap
import std.collection.HashSet
import std.collection.ArrayList
import std.sync.ReentrantMutex
import ohos_app_cangjie_entry.services.{getProxyService, getShareControllerService, ProxyConfig, ProxyType, ProxyProbeStatus, canParseAsInteger, parseProxySecret}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * ProxySettingsPage — Proxy Settings (SOCKS5 / MTProto)（混合工程迁移版）
 *
 * iOS references:
 *   SettingsUI/Sources/Data and Storage/ProxyListSettingsController.swift
 *   SettingsUI/Sources/Data and Storage/ProxyServerSettingsController.swift
 *   SettingsUI/Sources/Data and Storage/ProxySettingsServerItem.swift
 *   SettingsUI/Sources/Data and Storage/ProxySettingsActionItem.swift
 *
 * TC-0432/TC-0433/TC-0434 返修（diag-suite_settings_data_storage-{TC-0432,TC-0433,TC-0434}.md）：
 * UI-DS-2/UI-DS-3 判 `reconstruct`——本文件按 ui-page-reconstruct 流程整页重建（列表 + 表单
 * 是同一组件的两个分支，同一轮承接）。旧视图整体注释保留在文件末尾历史区（本文件较小，
 * 直接推倒重画，无需分段注释旧代码），逻辑层（ProxyService）不变、只重新接线。
 *
 * round2 返修（diag-suite_settings_data_storage-{TC-0432,TC-0433,TC-0434}-round2.md）：
 *   - M1（TC-0434 blocking）：ListItem 单子节点约束被违反导致非编辑态列表塌成 4px
 *     分隔线——buildProxyItemRow/buildProxyItemRowEditing 的分隔线现收进单一 Column。
 *   - N1（TC-0432+TC-0433 共因）：本轮起 `entry/src/main/ets/pages/ProxySettingsPage.ets`
 *     与 `router/router.cj` 的 `isModalRoute()` 已授权本 feature（见两文件各自的
 *     target_files_notes / 本轮头部注释），按 `set_account_identity` 对
 *     `UsernameSettingsPage.ets` 的既有修法（commit 22f08d3e8）逐字照做三处 DIALOG 属性，
 *     真正模态呈现已接入（不再是"push + 页内假 X"的近似）。
 *   - N2+N3（TC-0432）/ N4（TC-0433）：两处 inset 不符是独立成因，分别修——`buildMainList`
 *     按 section 建分组卡（enabled/servers/share/calls，白底+圆角26+左右 margin16），
 *     `buildAddEditForm` 三个节头改用 padding 内缩（16→32，规避 margin+width(100%) 溢出）。
 *
 * round3 返修（diag-suite_settings_data_storage-{TC-0432,TC-0433,TC-0434}-round3.md）：
 *   - 描边型 SVG（`chatroom_ic_check.svg` / `username_nav_ic_done.svg`）被 `.fillColor()`
 *     强行闭合填色（fillColor 只替换 fill、不动 stroke，`fill="none"` 的开放路径因此被填成
 *     实心楔形、黑描边仍在）——四处活跃行/类型单选勾 + 表单/编辑态 Done 改成
 *     `buildCheckVector()` 代码绘制（几何取自源侧 `generateItemListCheckIcon`，见该函数
 *     doc 注释），彻底离开这条着色链路。两个资源、四个消费点分属不同 case（TC-0432 N2 /
 *     TC-0433 N2+N3），机制相同但资源不同，缺一不可、不能只改一处。
 *   - TC-0433 N2：Done 图标补齐 chip 容器（32vp 圆 + 状态色 backgroundColor，对齐左上 X 的
 *     chip 范式），勾本身改为恒定白色代码矢量（不再承载状态色）。
 *   - TC-0433 N3：类型单选的勾从「跟随文字浮动在最右、未选中整个不挂载」改成「固定 30vp
 *     左侧带，`Visibility.Hidden` 隐藏但占位」，对齐源侧 `isHidden` 语义（隐藏不移除）。
 *   - TC-0433 N5：5 个 `TextInput` 追加 `.padding(left: 0, right: 0)`，抵消组件自带的默认
 *     横向内边距（该内边距与外层 Row/卡的两层 padding/margin 叠加，导致输入文字比节头多
 *     缩进 16vp）。
 *   - TC-0434 B2：删除控件从「PNG 位图 + fillColor（对 png 无效，SDK Image 无 colorFilter）」
 *     改成代码绘制的红色实心圆 + 白色横杠。
 *   - TC-0434 M3：重排手柄从盲文字符 `⠿` 改成三条圆角横杠的代码矢量，对齐源侧
 *     `itemListReorderIndicatorIcon` 的纯代码绘制实现。
 *
 * 与源侧的已知结构性差异（架构边界内可行的最大保真度，详见 featureX.md 已知限制）：
 *   - 密码遮罩：本工程 ArkUI TextInput 无 InputType.Password（SDK 6.1 未暴露该 API），用
 *     "透明文字层 TextInput + 底层遮罩 Text" 的 Stack 组合近似遮罩效果（保留真实光标交互）。
 *   - 端口数字键盘：同一 SDK 限制，TextInput 无数字键盘类型可设；完整性判据仍按源侧
 *     `Int(port) != nil` 语义校验（canParseAsInteger），不影响验收行为，只影响键盘外观。
 *   - 表单 `Share` 行：`invite_qr_code` 已落地 `ProxyQrSharePage`，本 feature 负责把
 *     当前未保存的表单快照按该页参数契约传入并执行应用内跳转。
 *
 * Anti-dead-state: @State values are fully back-filled from ProxyService in ensureLoaded().
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（pageStack.pop() → routerPop()）
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - aboutToAppear(加载 proxy 状态) → ensureLoaded() + .onAppear
 *  - aboutToDisappear(停探测轮询) → cleanup() + .onDisAppear（同 QrLoginPage/ChatListPage 范式）
 *
 * S-001: async loads → state updates via launch{}.
 * S-007: @State arrays use explicit Array<T> type.
 * R-111: spawn/launch 闭包不能捕获 var；探测轮询用 let 绑定后再传入 launch{}。
 */
@HybridComponentEntry
@Component
public class ProxySettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- theme snapshot（同 pages/SettingsPage.cj:11,25 范式）----
    // 源侧类型卡的勾色是 theme token（ItemListCheckboxItem.swift:271-273 `.accent` →
    // itemCheckColors.fillColor ← DefaultDayPresentationTheme.swift:56 defaultDayAccentColor），
    // 不是页面字面量。接快照后勾随用户在 Appearance 选定的 accent 走。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // ---- proxy list state (back-filled from ProxyService in ensureLoaded) ----
    @State var proxyEnabled: Bool = false
    @State var useForCalls: Bool = false
    @State var activeIdx: Int32 = -1
    @State var proxies: Array<ProxyConfig> = Array<ProxyConfig>()

    // ---- list edit mode (TC-0434 F1/C1/C2/D 组) ----
    @State var editing: Bool = false
    @State var swipeRowIdx: Int32 = -1
    @State var dragFromIdx: Int32 = -1

    // ---- 可达性探测状态（TC-0432 round10 F-B / RC-3），按服务器身份（key）归档 ----
    // kind: 0=checking 1=notAvailable 2=available
    @State var proxyStatusByKey: HashMap<String, Int32> = HashMap<String, Int32>()
    @State var proxyRttByKey: HashMap<String, Int64> = HashMap<String, Int64>()

    // ---- add/edit form visibility ----
    @State var showAddForm: Bool = false
    @State var editingIdx: Int32 = -1

    // ---- form input fields ----
    @State var formHost: String = ""
    @State var formPort: String = ""
    @State var formTypeSocks5: Bool = true
    @State var formUsername: String = ""
    @State var formPassword: String = ""
    @State var formSecret: String = ""

    // ---- loading state ----
    @State var isLoading: Bool = true
    @State var loaded: Bool = false

    // 探测监督循环的"请求停止"信号（同 QrLoginPage.pollSpawnRunning 范式：普通 Bool 字段，
    // spawn 内可读；单个 Bool 不存在字撕裂，stale 读至多晚一拍观察到，不构成正确性问题）。
    private var pollSpawnRunning: Bool = true

    // D-157 round2 返修新增：探测监督循环的"确已退出"信号。pollSpawnRunning 只是请求，
    // 旧一代 spawn 观察到并真正跑完 while 循环、即将 return 前才把这个置回 false——
    // startProbeSupervisor() 的重入守卫靠它判定"旧一代已彻底让出、可以安全复用
    // probeStarted 了"。同 pollSpawnRunning 一样是普通 Bool，不需要加锁。
    private var supervisorAlive: Bool = false

    // D-157 round2 返修新增：startProbeSupervisor() 的单飞守卫。同一实例快速
    // onDisAppear→onAppear 时，防止在旧一代 supervisorAlive 还没归零之前就又起一个
    // 等待者/新一代 supervisor spawn（见 startProbeSupervisor() 内的等待逻辑）。
    private var supervisorStartPending: Bool = false

    // D-157 round2 返修新增：最近一次生命周期意图（true=应运行，false=应停止），
    // 由 startProbeSupervisor()/cleanup() 各自更新。等待者在等旧一代退出期间，若期间
    // 又发生了 onDisAppear（desiredRunning 被翻回 false），醒来后不应再无条件把
    // pollSpawnRunning 拉回 true 起新一代——否则会"追上"一个已经过期的启动意图，
    // 让探测在页面已不可见时继续跑。
    //
    // D-210 round4 返修：desiredRunning 在等待者的放弃分支里是"每一代恰好读一次、不会
    // 重读"的决策点——不同于 pollSpawnRunning/supervisorAlive 那种被 while 循环反复轮询、
    // 陈旧值只晚一拍生效的字段，这里读到陈旧值会被永久错过（要等下一次外部 onAppear
    // 才会重新触发检查）。因此"读 desiredRunning 判断是否放弃"与
    // startProbeSupervisor() 里"写 desiredRunning=true 后检查 supervisorStartPending
    // 守卫"必须收进同一把锁的临界区，否则两者可以在放弃分支的读与清 pending 之间插入
    // 交错，产生与 D-209 同构、只是窗口更窄的重入丢失（见 desiredRunningMutex 声明处
    // 与 startProbeSupervisor() 内注释的完整推理）。
    private var desiredRunning: Bool = false

    // D-210 round4 返修新增：guarding desiredRunning 的决策原子性——覆盖 desiredRunning
    // 的全部写者：(a) startProbeSupervisor() 的"写 desiredRunning=true + 检查/置位
    //     supervisorStartPending 守卫"，(b) 等待者放弃分支的"读 desiredRunning +
    //     （放弃时）清 supervisorStartPending"，(c) cleanup() 对 desiredRunning 的写入。
    //     D-211 更正：本条原文曾以"该写入是简单 Bool 赋值，视野保证与
    //     pollSpawnRunning/supervisorAlive 同级"为由豁免 (c) 不加锁——该类比不成立。
    //     那两个字段安全，是因为其读者在循环里重复轮询，读到陈旧值下一轮自愈；
    //     desiredRunning 的读者是等待者放弃分支里的一次性决策（每代只读一次、永不
    //     重读），读到陈旧值就永久错判，没有"下一轮"补救。加锁只在同一把锁的各获取点
    //     之间建立 happens-before；绕开锁的写入与另一线程后续的加锁读之间没有同步边，
    //     不保证被看见。因此 cleanup() 的写入必须与其余写者共享同一把锁，不能豁免。
    //     三处写者用同一把锁互斥后：无论谁先拿到锁，放弃分支都能在锁内看到"最新"的
    //     desiredRunning（要么是自己判定前就发生的写入、要么是判定之后才会发生因而
    //     被守卫正常拦下的写入），不会再出现"意图已被记录但没有任何存活/等待中的
    //     执行体会去看它"的中间态。
    private let desiredRunningMutex: ReentrantMutex = ReentrantMutex()

    // 已起过一次性探测的 key 集合（TC-0432 round10 F-B / RC-2）。
    // D-157 round2 返修（原注释"只被单一监督 spawn 自己的线程读写，无并发访问"不成立）：
    // cleanup() 只翻 pollSpawnRunning，旧一代监督 spawn 仍有约 200ms 观察窗才真正退出；
    // 若 onDisAppear→onAppear 在窗内发生（这正是本函数文档所述要支持的重入场景），
    // 新一代 startProbeSupervisor() 会在旧一代仍活跃时被调用。现在两重防护都做：
    // (a) 下方 startProbeSupervisor() 的重入守卫，保证新一代的 clear()/循环体在旧一代
    //     确认退出（supervisorAlive==false）之前不会起跑，两代循环体在时间上不重叠；
    // (b) 仍额外把 probeStarted 的每一处跨协程读/写/删收进 probeStartedMutex——
    //     HashSet 不是线程安全容器，lock/unlock 提供的内存可见性保证不能只靠(a)的
    //     时序推理替代。形状同本 feature 既有的 ProxyProbeContext
    //     （services/ProxyService.cj:261-306，ReentrantMutex + lock/unlock 包每次访问），
    //     而不用 proxyStatusByKey/proxyRttByKey 的 launch{} 收敛范式——因为这里的读
    //     （contains 判据）需要同步返回值参与本轮循环体的控制流，不适合改成异步。
    private var probeStarted: HashSet<String> = HashSet<String>()
    private let probeStartedMutex: ReentrantMutex = ReentrantMutex()

    private func probeStartedContains(key: String): Bool {
        this.probeStartedMutex.lock()
        let v = this.probeStarted.contains(key)
        this.probeStartedMutex.unlock()
        return v
    }

    private func probeStartedAdd(key: String): Unit {
        this.probeStartedMutex.lock()
        let _ = this.probeStarted.add(key)
        this.probeStartedMutex.unlock()
    }

    private func probeStartedRemove(key: String): Unit {
        this.probeStartedMutex.lock()
        let _ = this.probeStarted.remove(key)
        this.probeStartedMutex.unlock()
    }

    private func probeStartedClear(): Unit {
        this.probeStartedMutex.lock()
        this.probeStarted.clear()
        this.probeStartedMutex.unlock()
    }

    // 迭代 HashSet 本身要收在锁内（迭代器直接遍历内部结构，不是快照读），
    // 因此把"锁内迭代 + 拷出普通 ArrayList"包成一个函数，调用方在锁外消费拷贝。
    private func probeStartedSnapshotKeys(): ArrayList<String> {
        this.probeStartedMutex.lock()
        let out = ArrayList<String>()
        for (key in this.probeStarted) { out.add(key) }
        this.probeStartedMutex.unlock()
        return out
    }

    // ==================== Lifecycle ====================

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = spawn {
            let svc = getProxyService()
            let enabled = svc.isEnabled()
            let calls = svc.isUseForCalls()
            let idx = svc.getActiveIdx()
            let list = svc.getProxies()
            launch {
                this.proxyEnabled = enabled
                this.useForCalls = calls
                this.activeIdx = idx
                this.proxies = list
                this.isLoading = false
                Hilog.info(0, "CjTelegram", "[ProxySettingsPage] Loaded: enabled=${enabled} count=${list.size}")
            }
        }
    }

    private func cleanup(): Unit {
        // D-211 修复：desiredRunning 的写入收进 desiredRunningMutex 临界区（与
        // startProbeSupervisor() 的写者/放弃分支的读者共享同一把锁，见字段声明处）。
        this.desiredRunningMutex.lock()
        this.desiredRunning = false
        this.desiredRunningMutex.unlock()
        this.pollSpawnRunning = false
    }

    /**
     * probeKeyFor — 服务器身份 key（对位源侧 `ProxyServerSettings` 的 `Hashable` 身份：
     * host+port+connection），用于探测状态的按 key 归档/查询（TC-0432 round10 F-B / RC-3）。
     */
    private func probeKeyFor(cfg: ProxyConfig): String {
        var typeTag = "s5"
        match (cfg.proxyType) {
            case ProxyType.SOCKS5 => typeTag = "s5"
            case ProxyType.MTProto => typeTag = "mtp"
        }
        return "${cfg.host}:${cfg.port}|${typeTag}|${cfg.username}|${cfg.password}|${cfg.secret}"
    }

    /**
     * startProbeSupervisor — TC-0432 round10 F-B / RC-2+RC-3：每服务器独立、一次性、
     * 按 key 归档的探测编排，复刻源侧 `ProxyServersStatuses.swift:53-86` 的集合差分模型
     * （集合每次变化，为每个新出现的 key 建一个独立、各自异步发布的探测；消失的 key 移除），
     * 取代旧的"一条线程串行跑完全部服务器、整趟结束才发布一次数组"（旧实现的一条卡住的
     * 连接会钉住全屏其余行，且下标随拖拽重排/删除错位）。
     *
     * 可重入（round10 F-B 原修法）：从 ensureLoaded() 拆出，由 build() 的 .onAppear 在
     * ensureLoaded() 之后单独调用。ensureLoaded() 的 `if (this.loaded) { return }` 只应挡
     * 数据重载，不该连带挡住探测监督循环的重新起停——否则 cleanup() 停过一次之后，第二次
     * 进屏永远重新探测不了。源侧是每次建控制器都新建一次 `ProxyServersStatuses`
     * （`ProxyListSettingsController.swift:424`），即每次进屏重探一次；这里用
     * `probeStarted.clear()` 复刻同样的"重进重探"语义。
     *
     * 重入守卫（D-157 round2 返修新增）：cleanup() 只翻 pollSpawnRunning 这个"请求"标志，
     * 旧一代监督 spawn 要等到自己下一次 while 条件判定才会真正退出——期间最多约 200ms
     * （循环体末尾 200ms 睡眠子循环节拍）观察窗。若在这窗口内又发生一次 onAppear（这正是
     * 上面这段要支持的重入场景本身），必须先等旧一代确认退出（`supervisorAlive == false`），
     * 才能安全 clear()/复用 probeStarted 并起新一代循环体——否则旧一代残余的循环体和新
     * 一代会在同一个非线程安全的 HashSet 上并发读写。`supervisorStartPending` 保证同一时刻
     * 只有一个"等待者/起跑者"在飞行中，见字段声明处的完整推理。等待期间若又发生一次
     * onDisAppear（`desiredRunning` 被翻回 false），醒来后直接放弃本次起跑，不追起一个
     * 已过期的意图。
     *
     * D-209 round3 返修：`this.desiredRunning = true` 必须在单飞守卫判断之前、无条件对
     * 每次调用执行——守卫只应门控"要不要真正起跑一个新执行体"，不应门控"这次调用的
     * 意图有没有被看见"。round2 曾把这行写在守卫之后，导致被守卫拦下的 onAppear 完全
     * 无副作用：若 gen0 排空窗口内发生 appear→disappear→appear→disappear→appear，最后
     * 那次 appear 会被挡在 `supervisorStartPending` 仍为 true 的守卫处、且不写
     * `desiredRunning`，等待中的 gen1 醒来时读到的是中间那次 disappear 留下的
     * `desiredRunning=false`，于是放弃启动——页面明明可见，探测却永久停摆。现在无条件
     * 先写意图，守卫只决定要不要真正 spawn 等待者/起跑者本身。
     *
     * D-210 round4 返修：仅把写移到守卫之前（D-209）还不够——等待者放弃分支自身的
     * "读 desiredRunning → 决定放弃 → 清 supervisorStartPending" 是两条不同步的独立
     * 语句，中间没有锁保护。另一个线程可以恰好落在这两条语句之间：等待者在 :read 处
     * 读到 desiredRunning=false（决定放弃），此时一次新的 onAppear 调用本函数，写
     * desiredRunning=true（D-209 修复后的无条件写）、检查 supervisorStartPending——
     * 但该标志还是 true（等待者还没执行到清标志那一步）——于是被守卫拦下返回；随后
     * 等待者才清掉 supervisorStartPending 并退出。终态：新意图已被正确记录，但没有
     * 任何存活或等待中的执行体会再去看它——与 D-209 描述的回归完全同构，只是窗口从
     * "整段排空时间"收窄成"放弃分支两条相邻语句之间"的真并发竞态窗口，仍然可达。
     *
     * 现在把"写 desiredRunning=true + 检查/置位 supervisorStartPending"（守卫本身）
     * 与放弃分支的"读 desiredRunning + （放弃时）清 supervisorStartPending"收进同一把
     * `desiredRunningMutex` 临界区。这样任一方必然完整地发生在另一方之前或之后
     * （见 desiredRunningMutex 声明处的双向推理）：若新调用的守卫临界区先发生，放弃
     * 分支之后在锁内重新读到的就是 true，转入正常起跑路径而不是放弃退出——不再是
     * "只字面记录意图、无人再看"的中间态。
     *
     * 不能照搬 pollSpawnRunning/supervisorAlive 的无锁读理由：那两个字段被 while 循环
     * 反复轮询，读到陈旧值只让决策晚一个节拍；`desiredRunning` 在放弃分支是"每一代
     * 决策点恰好读一次、不会重读"，陈旧读会被永久错过，直到下一次外部 onAppear 才重新
     * 触发检查——那条免锁理由在这里不成立。
     */
    private func startProbeSupervisor(): Unit {
        this.desiredRunningMutex.lock()
        this.desiredRunning = true
        if (this.supervisorStartPending) {
            this.desiredRunningMutex.unlock()
            return
        }
        this.supervisorStartPending = true
        this.desiredRunningMutex.unlock()
        this.pollSpawnRunning = false
        let _ = spawn {
            // 等旧一代（若存在）真正退出。首次调用时 supervisorAlive 本就是 false，
            // 不等待，直接进入。
            while (this.supervisorAlive) {
                sleep(Duration.millisecond * 50)
            }
            // D-210 round4：读 desiredRunning + （放弃时）清 supervisorStartPending
            // 收进同一把 desiredRunningMutex 临界区，与 startProbeSupervisor() 顶部的
            // 守卫临界区互斥——保证这里读到的是"最新"的 desiredRunning：要么是本次判定
            // 之前就已完成的写入，要么是判定之后才会发生、因而会被 supervisorStartPending
            // 仍为 true 正常拦下的写入。若在锁内重新确认时发现意图已变回 true，不再放弃，
            // 转入下面的正常起跑路径。
            this.desiredRunningMutex.lock()
            let shouldAbandon = !this.desiredRunning
            if (shouldAbandon) {
                // 等待窗口内页面已再次消失，起跑意图确已过期——不动 probeStarted，
                // 也不进入循环体，只清掉单飞守卫，让位给未来真正的下一次 onAppear。
                this.supervisorStartPending = false
            }
            this.desiredRunningMutex.unlock()
            if (shouldAbandon) {
                return
            }
            this.probeStartedClear()
            this.pollSpawnRunning = true
            // 顺序不可换：supervisorAlive 先置 true，supervisorStartPending 才置 false——
            // 这样在 pending 变回 false（允许新一代排队等待者）之前，alive 必已是 true，
            // 新等待者的 `while (this.supervisorAlive)` 不会提前误判"已空闲"而抢跑。
            this.supervisorAlive = true
            this.supervisorStartPending = false
            let svc = getProxyService()
            while (this.pollSpawnRunning) {
                let currentProxies = svc.getProxies()
                let currentKeys = HashSet<String>()
                for (cfg in currentProxies) {
                    let _ = currentKeys.add(this.probeKeyFor(cfg))
                }

                // 新出现的 key：各自单独 spawn 一次性探测（只调一次 probeProxyStatus），
                // 结果 launch 只并入这一个 key，不重复重探已出结果的 key。
                for (cfg in currentProxies) {
                    if (!this.pollSpawnRunning) { break }
                    let key = this.probeKeyFor(cfg)
                    if (!this.probeStartedContains(key)) {
                        this.probeStartedAdd(key)
                        let probeCfg = cfg
                        let probeKey = key
                        let _ = spawn {
                            let status = svc.probeProxyStatus(probeCfg)
                            var kindVal: Int32 = 0
                            var rttVal: Int64 = 0
                            match (status) {
                                case ProxyProbeStatus.Checking => kindVal = 0
                                case ProxyProbeStatus.NotAvailable => kindVal = 1
                                case ProxyProbeStatus.Available(rtt) =>
                                    kindVal = 2
                                    rttVal = rtt
                            }
                            let finalKind = kindVal
                            let finalRtt = rttVal
                            launch {
                                // 发布时整体重建并赋新 HashMap（不就地 put 后依赖 @State
                                // 观测到内部变更），与既有代码整体赋新 Array 的写法同源。
                                let nextKinds = HashMap<String, Int32>()
                                for ((k, v) in this.proxyStatusByKey) { nextKinds[k] = v }
                                nextKinds[probeKey] = finalKind
                                this.proxyStatusByKey = nextKinds

                                let nextRtts = HashMap<String, Int64>()
                                for ((k, v) in this.proxyRttByKey) { nextRtts[k] = v }
                                nextRtts[probeKey] = finalRtt
                                this.proxyRttByKey = nextRtts
                            }
                        }
                    }
                }

                // 已消失的 key：从 probeStarted 与两张表移除（对位 validKeys 增删记账）。
                let goneKeys = ArrayList<String>()
                let startedSnapshot = this.probeStartedSnapshotKeys()
                for (key in startedSnapshot) {
                    if (!currentKeys.contains(key)) {
                        goneKeys.add(key)
                    }
                }
                if (goneKeys.size > 0) {
                    for (key in goneKeys) {
                        this.probeStartedRemove(key)
                    }
                    let removedKeys = goneKeys
                    launch {
                        let nextKinds = HashMap<String, Int32>()
                        for ((k, v) in this.proxyStatusByKey) {
                            var removed = false
                            for (rk in removedKeys) { if (rk == k) { removed = true; break } }
                            if (!removed) { nextKinds[k] = v }
                        }
                        this.proxyStatusByKey = nextKinds

                        let nextRtts = HashMap<String, Int64>()
                        for ((k, v) in this.proxyRttByKey) {
                            var removed = false
                            for (rk in removedKeys) { if (rk == k) { removed = true; break } }
                            if (!removed) { nextRtts[k] = v }
                        }
                        this.proxyRttByKey = nextRtts
                    }
                }

                // 监督循环本身不做阻塞 I/O（每次探测都在各自独立 spawn 里），只做集合差分，
                // 因此 onDisAppear 的 pollSpawnRunning=false 能立刻在下一次 1s 节拍内生效。
                var waited: Int64 = 0
                while (waited < 1000 && this.pollSpawnRunning) {
                    sleep(Duration.millisecond * 200)
                    waited += 200
                }
            }
            // 本代循环体已彻底结束（不会再触碰 probeStarted）——现在才让出，允许下一次
            // startProbeSupervisor() 的等待者继续（见字段声明处 + 函数头部的重入守卫说明）。
            this.supervisorAlive = false
        }
    }

    // ==================== Helpers ====================

    private func createsNewProxy(): Bool {
        return this.proxies.size == 0
    }

    private func shouldShowCallsSection(): Bool {
        if (this.activeIdx < 0 || Int64(this.activeIdx) >= this.proxies.size) { return false }
        let active = this.proxies[Int64(this.activeIdx)]
        var isSocks5 = false
        match (active.proxyType) {
            case ProxyType.SOCKS5 => isSocks5 = true
            case ProxyType.MTProto => isSocks5 = false
        }
        return isSocks5
    }

    private func probeKindFor(cfg: ProxyConfig): Int32 {
        let key = this.probeKeyFor(cfg)
        match (this.proxyStatusByKey.get(key)) {
            case Some(v) => return v
            case None => return 0
        }
    }

    private func probeSuffixFor(cfg: ProxyConfig): String {
        let kind = this.probeKindFor(cfg)
        if (kind == 2) {
            let key = this.probeKeyFor(cfg)
            match (this.proxyRttByKey.get(key)) {
                case Some(rtt) => return "${rtt} ms ping"
                case None => return "checking..."
            }
        }
        if (kind == 1) {
            return "unavailable"
        }
        return "checking..."
    }

    /** isActiveConnectedLine — 该行是否走"活跃 + 总开关开"的连接态显示分支。 */
    private func isActiveConnectedLine(rawIdx: Int64): Bool {
        return this.activeIdx == Int32(rawIdx) && this.proxyEnabled
    }

    /**
     * activeCheckColor — 活跃行 ✓ 的描边色，按总开关二选一（源侧
     * ProxyListSettingsController.swift:232 `enabled ? .accent : .secondary`）。
     * 提成 private func（而非 @Builder 内联 if）以显式声明返回类型 UInt32，规避
     * `buildCheckVector` 经 @Component 宏包装为 `ObservedProperty<Generics-T>` 后，
     * if/else 两个整数字面量分支在跨约束（`Int64 <: T` 与 `T <: UInt32`）下无法推断
     * 出唯一泛型实参的编译错误。
     */
    private func activeCheckColor(): UInt32 {
        if (this.proxyEnabled) {
            return this.presentation.accentColor
        }
        return this.presentation.secondaryTextColor
    }

    /**
     * statusLineFor — 复刻源侧 `proxySettingsControllerEntries` 的第二行装配逻辑：
     * 活跃且总开关开 ⇒ 按连接状态显示；否则 ⇒ `<TYPE>, <ping 态>`。
     * 已知简化：源侧的 waitingForNetwork/connecting/updating/online 四态依赖
     * `network.connectionStatus`（连通性信号）——目标侧 ProxyService 暂无该信号面，
     * 用探测结果近似三态（connecting.../connected/unavailable），不影响 C3/F3 覆盖的
     * 非活跃行场景（这正是两个 case 实测断言的分支）。
     */
    private func statusLineFor(cfg: ProxyConfig, rawIdx: Int64): String {
        let typeLabel = cfg.proxyType.displayName()
        if (this.isActiveConnectedLine(rawIdx)) {
            let kind = this.probeKindFor(cfg)
            if (kind == 2) { return "connected" }
            if (kind == 1) { return "unavailable" }
            return "connecting..."
        }
        return "${typeLabel}, ${this.probeSuffixFor(cfg)}"
    }

    /** formIsComplete — 复刻源侧 `ProxyServerSettingsControllerState.isComplete` 单一判据。 */
    private func formIsComplete(): Bool {
        if (this.formHost.isEmpty() || this.formPort.isEmpty() || !canParseAsInteger(this.formPort)) {
            return false
        }
        if (this.formTypeSocks5) {
            return true
        }
        return parseProxySecret(this.formSecret).isSome()
    }

    private func openAddForm(): Unit {
        this.editingIdx = -1
        this.formHost = ""
        this.formPort = ""
        this.formTypeSocks5 = true
        this.formUsername = ""
        this.formPassword = ""
        this.formSecret = ""
        this.showAddForm = true
    }

    private func openEditForm(idx: Int32): Unit {
        if (idx < 0 || Int64(idx) >= this.proxies.size) { return }
        let cfg = this.proxies[Int64(idx)]
        this.editingIdx = idx
        this.formHost = cfg.host
        this.formPort = cfg.port
        this.formTypeSocks5 = match (cfg.proxyType) {
            case ProxyType.SOCKS5 => true
            case ProxyType.MTProto => false
        }
        this.formUsername = cfg.username
        this.formPassword = cfg.password
        this.formSecret = cfg.secret
        this.showAddForm = true
    }

    private func saveForm(): Unit {
        if (!this.formIsComplete()) { return }
        let host = this.formHost
        let port = this.formPort
        let proxyType = if (this.formTypeSocks5) { ProxyType.SOCKS5 } else { ProxyType.MTProto }
        // 只取当前类型需要的字段，避免隐藏字段残值写进持久化配置（TC-0433 修法 3 边界）。
        let username = if (this.formTypeSocks5) { this.formUsername } else { "" }
        let password = if (this.formTypeSocks5) { this.formPassword } else { "" }
        let secret = if (this.formTypeSocks5) { "" } else { this.formSecret }
        let cfg = ProxyConfig(host, port: port, proxyType: proxyType, username: username, password: password, secret: secret)
        let editIdx = this.editingIdx
        let _ = spawn {
            let svc = getProxyService()
            if (editIdx >= 0) {
                svc.updateProxy(editIdx, cfg)
            } else {
                let _ = svc.addProxy(cfg)
            }
            let list = svc.getProxies()
            let newActiveIdx = svc.getActiveIdx()
            let newEnabled = svc.isEnabled()
            launch {
                this.proxies = list
                this.activeIdx = newActiveIdx
                this.proxyEnabled = newEnabled
                this.showAddForm = false
                Hilog.info(0, "CjTelegram", "[ProxySettingsPage] Proxy saved")
            }
        }
    }

    private func deleteProxy(idx: Int32): Unit {
        if (idx < 0) { return }
        let _ = spawn {
            let svc = getProxyService()
            svc.removeProxy(idx)
            let list = svc.getProxies()
            let newActiveIdx = svc.getActiveIdx()
            let newEnabled = svc.isEnabled()
            launch {
                this.proxies = list
                this.activeIdx = newActiveIdx
                this.proxyEnabled = newEnabled
                Hilog.info(0, "CjTelegram", "[ProxySettingsPage] Proxy removed at ${idx}")
            }
        }
    }

    private func activateProxy(idx: Int32): Unit {
        let _ = spawn {
            let svc = getProxyService()
            svc.setActiveProxy(idx)
            let newActiveIdx = svc.getActiveIdx()
            let newEnabled = svc.isEnabled()
            launch {
                this.activeIdx = newActiveIdx
                this.proxyEnabled = newEnabled
            }
        }
    }

    private func doReorder(fromIdx: Int32, toIdx: Int32): Unit {
        let _ = spawn {
            let svc = getProxyService()
            svc.reorderProxy(fromIdx, toIdx)
            let list = svc.getProxies()
            let newActiveIdx = svc.getActiveIdx()
            launch {
                this.proxies = list
                this.activeIdx = newActiveIdx
            }
        }
    }

    private func toggleEnabled(enabled: Bool): Unit {
        let _ = spawn {
            let svc = getProxyService()
            svc.setEnabled(enabled)
            launch {
                this.proxyEnabled = enabled
            }
        }
    }

    private func toggleUseForCalls(enabled: Bool): Unit {
        let _ = spawn {
            let svc = getProxyService()
            svc.setUseForCalls(enabled)
            launch {
                this.useForCalls = enabled
            }
        }
    }

    /** shareProxyList — TC-0432 修法 4：Share Proxy List 行，走已存在的系统分享原语。 */
    private func shareProxyList(): Unit {
        let svc = getProxyService()
        let text = svc.buildProxyListShareText()
        let _ = getShareControllerService().shareInviteLinkViaSystem(text)
    }

    /**
     * shareFormProxy — 表单 `Share` 行（TC-0433 S7_share_and_save）。
     * 按 ProxyQrSharePage 的路由参数契约传递当前未保存的表单快照，并明确使用内部二维码
     * （external=0）；列表页 Share Proxy List 仍由 shareProxyList() 走系统分享。
     */
    private func shareFormProxy(): Unit {
        if (!this.formIsComplete()) { return }
        let mtp = if (this.formTypeSocks5) { "0" } else { "1" }
        let username = if (this.formTypeSocks5) { this.formUsername } else { "" }
        let password = if (this.formTypeSocks5) { this.formPassword } else { "" }
        let secret = if (this.formTypeSocks5) { "" } else { this.formSecret }
        let payload = "${this.formHost}|${this.formPort}|${mtp}|${secret}|${username}|${password}|0"
        routerPush("ProxyQrSharePage", payload)
    }

    // ==================== UI ====================

    public func build() {
        Column {
            this.buildNavBar()

            if (this.isLoading) {
                Column {
                    LoadingProgress().width(32).height(32)
                    Text("Loading proxy settings...")
                        .fontSize(14)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 8)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.showAddForm) {
                this.buildAddEditForm()
            } else {
                this.buildMainList()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded(); this.startProbeSupervisor() })
        .onDisAppear({ => this.cleanup() })
    }

    // ---- Nav bar ----
    // 源侧列表屏呈现为模态 sheet（圆角 + 上一屏透见 + 左上圆形 X 关闭）；表单屏同样是
    // 模态、右上是提交（Navigation/Done）而非丢弃。真正的呈现模式（push vs sheet）由
    // 承载导航壳层决定，不在本 feature 的文件 scope 内（见文件头注释）——这里在
    // scope 内做到：左上换成圆形关闭控件（视觉近似 X close，功能上仍是返回/丢弃）；
    // 右上按 3 态切换（空列表无按钮 / 非空非编辑 Edit 文本 / 编辑中 Done 图标），
    // 表单态右上换成真实 Done 图标提交（不再是底部 `Save Proxy` 诱饵按钮）。

    @Builder
    func buildNavBar() {
        Row {
            this.buildLeftNavControl()
            Blank().layoutWeight(1)
            Text(trSource("Proxy"))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.presentation.textColor)
            Blank().layoutWeight(1)
            this.buildRightNavControl()
        }
        .width(100.percent)
        .height(56.0 + getSafeAreaTop())
        .padding(left: 16, right: 16, top: getSafeAreaTop())
        .backgroundColor(this.presentation.navBarColor)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildLeftNavControl() {
        Stack(alignContent: Alignment.Center) {
            Image(@r(app.media.nav_ic_close))
                .width(16)
                .height(16)
                .fillColor(this.presentation.textColor)
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
        .onClick({ _ =>
            if (this.showAddForm) {
                this.showAddForm = false
            } else {
                routerPop()
            }
        })
    }

    @Builder
    func buildRightNavControl() {
        if (this.showAddForm) {
            Stack(alignContent: Alignment.Center) {
                this.buildCheckVector(20.0, 0xFFFFFF, 0.0)
            }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor(if (this.formIsComplete()) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
            .onClick({ _ =>
                if (this.formIsComplete()) {
                    this.saveForm()
                }
            })
        } else if (this.proxies.size == 0) {
            // 空列表：不渲染任何右上控件（对齐源侧），保留同尺寸占位保持标题居中。
            Stack {}.width(32).height(32)
        } else if (this.editing) {
            Stack(alignContent: Alignment.Center) {
                this.buildCheckVector(20.0, 0xFFFFFF, 0.0)
            }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor(this.presentation.accentColor)
            .onClick({ _ =>
                this.editing = false
                this.dragFromIdx = -1
            })
        } else {
            Stack(alignContent: Alignment.Center) {
                Text(trSource("Edit"))
                    .fontSize(16)
                    .fontColor(this.presentation.textColor)
            }
            .height(32)
            .borderRadius(16)
            .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
            .padding(left: 9, right: 9)
            .onClick({ _ =>
                this.editing = true
            })
        }
    }

    // ---- Main list ----
    // 复刻源侧 proxySettingsControllerEntries 的条目序列（ProxyListSettingsController.swift
    // :255-317）：enabled（无节头）→ serversHeader（无条件）→ addServer → 各 server →
    // shareProxyList（非空时）→ useForCalls + useForCallsInfo（活跃且 SOCKS5 时）。
    // 用 List 作为整页唯一滚动容器（而非 Scroll+Column 嵌套 List，避免可滚动区域嵌套
    // 可滚动区域的已知 ArkUI 布局陷阱），服务器行按 editing 状态二选一分支——非编辑走
    // ListItem.swipeAction 左滑删除（D-135 已验证形态），编辑态走"红减号 tap 删除 +
    // 敲两下 tap-to-pick 重排"（HarmonyOS ListItem 无 onDragStart/onDrop，同
    // StickersSettingsPage/ChatFoldersPage 已验证方案），两者互斥、不同时挂载。
    // diag-suite_settings_data_storage-TC-0432-round2.md §N2+N3 修法 2：每个
    // ProxySettingsControllerSection（enabled/servers/share/calls）收进一张分组卡
    // （0xFFFFFF、borderRadius 26、左右 margin 16、clip 裁掉行自身方形背景在卡角处的溢出）。
    // 卡本身不设 .width(100.percent)（只设 margin），避免 D-165/N4 记录过的
    // width(100%)+margin 叠加溢出再被居中的陷阱；卡内各行沿用自身既有 .padding(left:16,...)
    // 与 .backgroundColor(0xFFFFFF) 不变（服务器行的具体单子节点修法见 §M1）。
    @Builder
    func buildMainList() {
        List {
            ListItem {
                Column {
                    this.buildUseProxyRow()
                }
                .borderRadius(26)
                .backgroundColor(this.presentation.cardColor)
                .clip(true)
                .margin(left: 16, right: 16, top: 16)
            }

            ListItem {
                Text(trSource("SAVED PROXIES"))
                    .fontSize(13)
                    .fontColor(this.presentation.secondaryTextColor)
                    .padding(left: 32, top: 24, bottom: 8)
                    .width(100.percent)
            }

            // servers 卡：Add Proxy 行 + 各服务器行是各自独立的 ListItem（服务器行需要保留
            // 逐行 swipeAction 左滑删除），用 ListItemGroup 把它们收成一张视觉卡片
            // （ListItemGroup 支持 borderRadius/backgroundColor 等通用属性，组内 ListItem
            // 各自独立、swipeAction 不受影响）。
            ListItemGroup {
                ListItem {
                    this.buildAddProxyRow()
                }

                if (this.editing) {
                    ForEach(this.proxies, itemGenerator: { cfg: ProxyConfig, rawIdx: Int64 =>
                        ListItem {
                            this.buildProxyItemRowEditing(cfg, rawIdx)
                        }
                    }, keyGeneratorFunc: { cfg: ProxyConfig, rawIdx: Int64 =>
                        "proxy_${rawIdx}_${cfg.displayAddress()}_${cfg.proxyType.toInt()}"
                    })
                } else {
                    ForEach(this.proxies, itemGenerator: { cfg: ProxyConfig, rawIdx: Int64 =>
                        ListItem {
                            this.buildProxyItemRow(cfg, rawIdx)
                        }
                        .swipeAction(
                            end: { => bind(this.buildProxySwipeEndPanel, this)() },
                            onOffsetChange: { offset: Float64 =>
                                if (offset != 0.0) {
                                    this.swipeRowIdx = Int32(rawIdx)
                                }
                            }
                        )
                    }, keyGeneratorFunc: { cfg: ProxyConfig, rawIdx: Int64 =>
                        "proxy_${rawIdx}_${cfg.displayAddress()}_${cfg.proxyType.toInt()}"
                    })
                }
            }
            .borderRadius(26)
            .backgroundColor(this.presentation.cardColor)
            .clip(true)
            .margin(left: 16, right: 16)

            if (this.proxies.size > 0) {
                ListItem {
                    Column {
                        this.buildShareProxyListRow()
                    }
                    .borderRadius(26)
                    .backgroundColor(this.presentation.cardColor)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)
                }
            }

            if (this.shouldShowCallsSection()) {
                ListItem {
                    Column {
                        this.buildUseForCallsRow()
                    }
                    .borderRadius(26)
                    .backgroundColor(this.presentation.cardColor)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 24)
                }
                ListItem {
                    Text(trSource("Proxy servers may degrade the quality of your calls."))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .padding(left: 32, right: 16, top: 8, bottom: 32)
                        .width(100.percent)
                }
            } else {
                ListItem {
                    Row {}.height(32)
                }
            }
        }
        .width(100.percent)
        .layoutWeight(1)
        .backgroundColor(this.presentation.backgroundColor)
    }

    @Builder
    func buildUseProxyRow() {
        // B2/F2 修法：空列表时开关不可翻转、点击等价于"新增"（对齐源侧
        // `enableInteractiveChanges: !createsNew` + updated 回调里的 `createsNew` 分支）。
        Row {
            Text(trSource("Use Proxy"))
                .fontSize(17)
                .fontColor(this.presentation.textColor)
                .layoutWeight(1)
            Toggle(ToggleType.Switch, isOn: this.proxyEnabled)
                .selectedColor(this.presentation.accentColor)
                .enabled(!this.createsNewProxy())
                .onChange({ isOn: Bool =>
                    if (!this.createsNewProxy()) {
                        this.toggleEnabled(isOn)
                    }
                })
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(this.presentation.cardColor)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ =>
            if (this.createsNewProxy()) {
                this.openAddForm()
            }
        })
    }

    /**
     * Add Proxy 行自己画与首条服务器行之间的底边线（diag-suite_settings_data_storage-
     * TC-0432-round5.md §N1/§R1-b）：卡内第一个行间交界的所有者是上方行（这里），不是下方
     * 服务器行的 rawIdx==0 特判——round 2 起 Add Proxy 与服务器行被收进同一张卡后，这条线
     * 从未有人画过。门控 `this.proxies.size > 0` 复刻源侧 `neighbors.bottom ==
     * .sameSection(false)`：空列表时 Add Proxy 是卡内唯一行，不画底边线。
     * `.onClick`/`.backgroundColor`/`.height`/`.padding`/`.alignItems` 全部留在 Row 上，
     * 不上移到 Column，否则分隔线区域会变成可点区。
     */
    @Builder
    func buildAddProxyRow() {
        Column {
            Row {
                // 代码画的矢量 "+"（十字交叉的两条 Divider），不是 Unicode Text 字形
                // （对齐 Diff #11：源侧是 code-drawn vector plus）。
                Stack(alignContent: Alignment.Center) {
                    Divider().vertical(true).strokeWidth(2).color(this.presentation.accentColor).height(14)
                    Divider().vertical(false).strokeWidth(2).color(this.presentation.accentColor).width(14)
                }
                .width(22)
                .height(22)
                .margin(right: 12)
                Text(trSource("Add Proxy"))
                    .fontSize(17)
                    .fontColor(this.presentation.accentColor)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(this.presentation.cardColor)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ => this.openAddForm() })

            if (this.proxies.size > 0) {
                this.buildProxyCardDivider(50.0)
            }
        }
        .width(100.percent)
    }

    /**
     * buildCheckVector — 代码绘制的两笔勾，替代描边型 SVG（`chatroom_ic_check.svg` /
     * `username_nav_ic_done.svg`）被 `.fillColor()` 强行闭合填色的问题
     * （diag-suite_settings_data_storage-TC-0432-round3.md §N2 / …TC-0433-round3.md §N2）。
     * 几何取自源侧 `generateItemListCheckIcon`（PresentationResourcesItemList.swift:6-17）的
     * 描边路径——12x10 画布，`M0.215,4.361 L3.316,7.705 L9.892,0`（短笔 P0→P1、长笔 P1→P2，
     * 两笔在 P1 相交）——按画布宽度等比缩放（`scale = size/12`）后垂直居中嵌入 `size×size`
     * 盒，推导出两段线段各自的角度（与 size 无关，只由源路径形状决定）、长度与中心偏移
     * （均正比于 size）。用两条各自绕自身中心旋转、再整体平移到线段中点的 `Divider` 拼接
     * ——与 `buildAddProxyRow`（`:655` 起）的十字 "+" 是同一范式，只是由轴对齐旋转改成
     * 任意角度旋转。笔宽恒 2vp（源侧 `setLineWidth(1.98)` 四舍五入，不随 size 缩放）。
     *
     * @param size 勾的外接正方形边长（vp）。
     * @param strokeColor 笔画颜色，由调用方决定：表单 Done chip 传恒定白（状态画在 chip
     *   底色上，如 buildRightNavControl）；服务器行的活跃勾按总开关二选一传强调色/次要色
     *   （源侧 ProxyListSettingsController.swift:232 `enabled ? .accent : .secondary`）。
     * @param marginRight 勾自身的右外边距（vp），不需要时传 0.0。
     */
    @Builder
    func buildCheckVector(size: Float64, strokeColor: UInt32, marginRight: Float64) {
        Stack(alignContent: Alignment.Center) {
            // 短笔 P0(0.215,4.361)→P1(3.316,7.705)：顺时针 47.16°，长度 0.380045*size，
            // 中心偏移 (-0.352875, 0.086083)*size（相对 size×size 盒中心）。
            Divider()
                .vertical(false)
                .strokeWidth(2)
                .color(strokeColor)
                .width(size * 0.380045)
                .rotate(angle: 47.16)
                .offset(x: size * -0.352875, y: size * 0.086083)
            // 长笔 P1(3.316,7.705)→P2(9.892,0)：逆时针 49.51°，长度 0.844141*size，
            // 中心偏移 (0.050333, -0.095625)*size。
            Divider()
                .vertical(false)
                .strokeWidth(2)
                .color(strokeColor)
                .width(size * 0.844141)
                .rotate(angle: -49.51)
                .offset(x: size * 0.050333, y: size * -0.095625)
        }
        .width(size)
        .height(size)
        .margin(right: marginRight)
    }

    /**
     * 卡内分隔线的共享形状：源侧是"上方 item 画自己的底边线"（ProxySettingsActionItem.swift:
     * 241-246 / ProxySettingsServerItem.swift:402-412 的 bottomStripeNode 邻居规则），本函数
     * 承载该形状本身，调用方各自决定内缩与是否画（buildAddProxyRow 的 R1-b、
     * buildProxyItemDivider 的 R1-c）。颜色/内缩取自源侧 itemBlocksSeparatorColor
     * （DefaultDayPresentationTheme.swift:487，实测 (200,199,204)）与卡内右内缩常量
     * （diag-suite_settings_data_storage-TC-0432-round5.md §R1-a）。
     */
    @Builder
    func buildProxyCardDivider(leftInset: Float64) {
        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: leftInset, right: 16.0)
    }

    /**
     * 服务器行之间的分隔线：`rawIdx > 0` 表示"我上面还有同卡邻居服务器行"。卡内第一个交界
     * （Add Proxy ↔ 首条服务器行）由 buildAddProxyRow 自己的底边线负责（R1-b），不在这里画，
     * 二者不重不漏。
     */
    @Builder
    func buildProxyItemDivider(rawIdx: Int64, leftInset: Float64) {
        if (rawIdx > 0) {
            this.buildProxyCardDivider(leftInset)
        }
    }

    /**
     * 非编辑态服务器行：单个真实 ⓘ 图标（callui_ic_info，对齐源侧 Call List/InfoButton 资源）+
     * 左滑删除。diag-suite_settings_data_storage-TC-0434-round2.md §M1 修法 1：ListItem 只允许
     * 一个子组件，分隔线与 Row 必须收进同一个 Column（原顶层的 divider+Row 两个兄弟节点在
     * swipeAction 分支下会被 SDK 丢弃掉除第一个之外的子节点）。
     */
    @Builder
    func buildProxyItemRow(cfg: ProxyConfig, rawIdx: Int64) {
        Column {
            this.buildProxyItemDivider(rawIdx, 50.0)
            Row {
                if (this.activeIdx == Int32(rawIdx)) {
                    this.buildCheckVector(18.0, this.activeCheckColor(), 12.0)
                } else {
                    Row { }.width(30)
                }

                Column {
                    Text() {
                        Span(cfg.host)
                            .fontColor(this.presentation.textColor)
                        Span(":${cfg.port}")
                            .fontColor(this.presentation.secondaryTextColor)
                    }
                    .fontSize(17)
                    Text(this.statusLineFor(cfg, rawIdx))
                        .fontSize(13)
                        .fontColor(if (this.isActiveConnectedLine(rawIdx)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.callui_ic_info))
                        .width(20)
                        .height(20)
                        .fillColor(this.presentation.accentColor)
                }
                .width(30)
                .height(30)
                .onClick({ _ => this.openEditForm(Int32(rawIdx)) })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 12)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(this.presentation.cardColor)
            .onClick({ _ => this.activateProxy(Int32(rawIdx)) })
        }
        .width(100.percent)
    }

    /**
     * 编辑态服务器行：红减号（点击直接删除）+ 重排手柄（tap-to-pick-and-place），ⓘ 隐藏、整行
     * 不可再激活。同 §M1 修法 1：分隔线收进 Column，ListItem 只保留单一子节点（编辑态此前无
     * swipeAction，分隔线被摆在行正中间，同一处改动一并修正）。
     */
    @Builder
    func buildProxyItemRowEditing(cfg: ProxyConfig, rawIdx: Int64) {
        Column {
            this.buildProxyItemDivider(rawIdx, 80.0)
            Row {
                Stack(alignContent: Alignment.Center) {
                    Divider().vertical(false).strokeWidth(2).color(0xFFFFFF).width(11)
                }
                .width(22)
                .height(22)
                .borderRadius(11)
                .backgroundColor(0xFF3B30)
                .margin(right: 8)
                .onClick({ _ => this.deleteProxy(Int32(rawIdx)) })

                if (this.activeIdx == Int32(rawIdx)) {
                    this.buildCheckVector(18.0, this.activeCheckColor(), 12.0)
                } else {
                    Row { }.width(30)
                }

                Column {
                    Text() {
                        Span(cfg.host)
                            .fontColor(this.presentation.textColor)
                        Span(":${cfg.port}")
                            .fontColor(this.presentation.secondaryTextColor)
                    }
                    .fontSize(17)
                    Text(cfg.proxyType.displayName())
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 重排手柄（tap-to-pick-and-place — HarmonyOS ListItem 无 onDragStart，
                // 同 StickersSettingsPage.buildInstalledPackRow 已验证方案）。
                Stack(alignContent: Alignment.Center) {
                    Column {
                        Divider().vertical(false).strokeWidth(1).width(17)
                            .color(if (this.dragFromIdx == Int32(rawIdx)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                        Divider().vertical(false).strokeWidth(1).width(17).margin(top: 5)
                            .color(if (this.dragFromIdx == Int32(rawIdx)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                        Divider().vertical(false).strokeWidth(1).width(17).margin(top: 5)
                            .color(if (this.dragFromIdx == Int32(rawIdx)) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
                    }
                    .width(17)
                }
                .width(30)
                .height(44)
                .onClick({ _ =>
                    if (this.dragFromIdx < 0) {
                        this.dragFromIdx = Int32(rawIdx)
                    } else if (this.dragFromIdx == Int32(rawIdx)) {
                        this.dragFromIdx = -1
                    } else {
                        let from = this.dragFromIdx
                        this.dragFromIdx = -1
                        this.doReorder(from, Int32(rawIdx))
                    }
                })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 12)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(if (this.dragFromIdx == Int32(rawIdx)) { this.presentation.itemSelectedBackgroundColor } else { this.presentation.cardColor })
        }
        .width(100.percent)
    }

    /**
     * buildProxySwipeEndPanel — swipeAction end 侧单按钮面板（D-135 合规：@Builder 无参
     * 成员函数 + bind(this.fn, this)() 调用，不在内联闭包里直接写多子节点容器字面量）。
     * 读取镜像 @State 字段 swipeRowIdx（由 onOffsetChange 写入），不接受参数。
     */
    @Builder
    func buildProxySwipeEndPanel() {
        Column {
            Text(trSource("Delete"))
                .fontSize(15)
                .fontColor(0xFFFFFF)
        }
        .width(74)
        .height(100.percent)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(0xFF3824)
        .onClick({ evt =>
            this.deleteProxy(this.swipeRowIdx)
        })
    }

    // diag-suite_settings_data_storage-TC-0432-round2.md §N2+N3 边界条件：Share Proxy List
    // 现在是独立分组卡，与相邻卡之间靠 buildMainList 里卡级 margin(top: 24) 的灰色间隙分隔，
    // 不再需要一条紧贴在行顶部的 Divider（原 Divider 是服务器列表未成卡时的行间分隔线遗留）。
    @Builder
    func buildShareProxyListRow() {
        Row {
            Text(trSource("Share Proxy List"))
                .fontSize(17)
                .fontColor(this.presentation.accentColor)
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(this.presentation.cardColor)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.shareProxyList() })
    }

    @Builder
    func buildUseForCallsRow() {
        Row {
            Text(trSource("Use for calls"))
                .fontSize(17)
                .fontColor(this.presentation.textColor)
                .layoutWeight(1)
            Toggle(ToggleType.Switch, isOn: this.useForCalls)
                .selectedColor(this.presentation.accentColor)
                .onChange({ isOn: Bool =>
                    this.toggleUseForCalls(isOn)
                })
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .backgroundColor(this.presentation.cardColor)
        .alignItems(VerticalAlign.Center)
    }

    // ---- Add/Edit form ----
    // 复刻源侧 proxyServerSettingsControllerEntries（ProxyServerSettingsController.swift
    // :208-236）：type 卡（无节头）→ CONNECTION（Server/Port，placeholder 即字段名，
    // 无左侧 label）→ CREDENTIALS(OPTIONAL)/CREDENTIALS（按类型切换字段）→ Share 行。
    // 提交挪回导航栏 Done 图标（buildRightNavControl），不再是底部 `Save Proxy` 诱饵按钮。
    @Builder
    func buildAddEditForm() {
        Scroll {
            Column {
                // ---- Proxy type selector（无节头，源侧 type 卡是表单首元素）----
                Column {
                    Row {
                        // TC-0433 修法 2：勾移到固定 30vp 左侧带，用 Visibility.Hidden
                        // 隐藏但占位（对齐源侧 `iconNode.isHidden = !item.checked`），不再用
                        // `if` 分支——`if` 会让未选中行整个不挂载、标签左移，切类型时抖动。
                        Stack(alignContent: Alignment.Center) {
                            this.buildCheckVector(18.0, this.presentation.accentColor, 0.0)
                        }
                        .width(62)
                        .visibility(if (this.formTypeSocks5) { Visibility.Visible } else { Visibility.Hidden })

                        Text(trSource("SOCKS5"))
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                            .layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 0, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ =>
                        // TC-0433 修法 3：切换类型不清空已输入凭据，只切可见性。
                        this.formTypeSocks5 = true
                    })

                    Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 62, right: 16)

                    Row {
                        Stack(alignContent: Alignment.Center) {
                            this.buildCheckVector(18.0, this.presentation.accentColor, 0.0)
                        }
                        .width(62)
                        .visibility(if (!this.formTypeSocks5) { Visibility.Visible } else { Visibility.Hidden })

                        Text(trSource("MTProto"))
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                            .layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 0, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ =>
                        this.formTypeSocks5 = false
                    })
                }
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(26)
                .margin(left: 16, right: 16, top: 16)

                // ---- Connection section ----
                // diag-suite_settings_data_storage-TC-0433-round2.md §N4：margin(left)+
                // width(100%) 叠加会溢出父 Column 再被居中拉回 8vp（父 Column 未设
                // alignItems，默认居中）；改用 padding（盒内，不受父对齐影响）且把内缩数值
                // 从 16 提到 32（卡外边距 16 + 卡内 padding 16 两层叠加的目标值）。
                Text(trSource("CONNECTION"))
                    .fontSize(13)
                    .fontColor(this.presentation.secondaryTextColor)
                    .padding(left: 32)
                    .margin(top: 24, bottom: 8)
                    .width(100.percent)

                Column {
                    // Server / Host（placeholder 即字段名，无左侧 label，对齐 Diff #6）
                    Row {
                        TextInput(placeholder: trSource("Server"), text: this.formHost)
                            .fontSize(17)
                            .placeholderColor(0xC8C8CE)
                            .layoutWeight(1)
                            .padding(left: 0, right: 0)
                            .backgroundColor(Color.Transparent)
                            .onChange({ val: String =>
                                this.formHost = val
                            })
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)

                    Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 16, right: 16)

                    // Port（空白，非预填 "1080" —— 对齐 Diff #7；预填会掩盖 B2 完整性门 bug）
                    Row {
                        TextInput(placeholder: trSource("Port"), text: this.formPort)
                            .fontSize(17)
                            .placeholderColor(0xC8C8CE)
                            .layoutWeight(1)
                            .padding(left: 0, right: 0)
                            .backgroundColor(Color.Transparent)
                            .onChange({ val: String =>
                                this.formPort = val
                            })
                    }
                    .width(100.percent)
                    .height(56)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                }
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(26)
                .margin(left: 16, right: 16)

                // ---- Credentials section ----
                if (this.formTypeSocks5) {
                    // §N4 同一处修法：padding 替 margin，16→32。
                    Text(trSource("CREDENTIALS (OPTIONAL)"))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .padding(left: 32)
                        .margin(top: 24, bottom: 8)
                        .width(100.percent)

                    Column {
                        Row {
                            TextInput(placeholder: trSource("Username"), text: this.formUsername)
                                .fontSize(17)
                                .placeholderColor(0xC8C8CE)
                                .layoutWeight(1)
                                .padding(left: 0, right: 0)
                                .backgroundColor(Color.Transparent)
                                .onChange({ val: String =>
                                    this.formUsername = val
                                })
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)

                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 16, right: 16)

                        // 密码遮罩（Diff #10）：本 SDK TextInput 无 InputType.Password，
                        // 用"底层遮罩 Text（先绘）+ 顶层透明 TextInput（后绘，接管点击/光标/
                        // 输入）"的 Stack 组合近似遮罩——Stack 子节点后绘制的在上层，故
                        // TextInput 必须是第二个子节点才能接住点击进入编辑态。
                        Stack(alignContent: Alignment.Start) {
                            if (!this.formPassword.isEmpty()) {
                                Text(this.maskedPasswordDisplay())
                                    .fontSize(17)
                                    .fontColor(this.presentation.textColor)
                            }
                            TextInput(placeholder: trSource("Password"), text: this.formPassword)
                                .fontSize(17)
                                .placeholderColor(0xC8C8CE)
                                .fontColor(Color.Transparent)
                                .caretColor(this.presentation.textColor)
                                .padding(left: 0, right: 0)
                                .backgroundColor(Color.Transparent)
                                .onChange({ val: String =>
                                    this.formPassword = val
                                })
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16)
                } else {
                    // MTProto：header 文案是 "CREDENTIALS"（不是 "MTPROTO SECRET" —— 对齐
                    // Diff #8：源侧该分支的 header 字面量就是 CREDENTIALS）。§N4 同一处修法：
                    // padding 替 margin，16→32。
                    Text(trSource("CREDENTIALS"))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .padding(left: 32)
                        .margin(top: 24, bottom: 8)
                        .width(100.percent)

                    Column {
                        Row {
                            TextInput(placeholder: trSource("Secret"), text: this.formSecret)
                                .fontSize(17)
                                .placeholderColor(0xC8C8CE)
                                .layoutWeight(1)
                                .padding(left: 0, right: 0)
                                .backgroundColor(Color.Transparent)
                                .onChange({ val: String =>
                                    this.formSecret = val
                                })
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16)
                }

                // ---- Share row（TC-0433 D 组；见本文件头注释的接线依赖说明）----
                Column {
                    this.buildFormShareRow()
                }
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(26)
                .margin(left: 16, right: 16, top: 24)

                Row { }.height(32)
            }
        }
        // I-6：同 `pages/SaveIncomingMediaPage.cj` / `pages/IntentsSettingsPage.cj` —— `Scroll` 的通用
        // `align` 默认 `Alignment.Center`（wrapper `common/common_component.cj:642-662`），内容短于
        // 视口时内容被垂直居中，导航栏下留空带（实测 337px）；源侧 `ItemListController` 的 `ListView`
        // 短内容永远顶对齐。写在 `Scroll` 自身链上，不是内部 `Column` 上。
        .align(Alignment.Top)
        .layoutWeight(1)
        .backgroundColor(this.presentation.backgroundColor)
    }

    @Builder
    func buildFormShareRow() {
        Row {
            Text(trSource("Share"))
                .fontSize(17)
                .fontColor(if (this.formIsComplete()) { this.presentation.accentColor } else { this.presentation.secondaryTextColor })
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.shareFormProxy() })
    }

    /** maskedPasswordDisplay — 按已输入密码的字符数生成等长遮罩串（• 字符）。 */
    private func maskedPasswordDisplay(): String {
        var result = ""
        var i: Int64 = 0
        let count = this.formPassword.toRuneArray().size
        while (i < count) {
            result += "•"
            i += 1
        }
        return result
    }
}
