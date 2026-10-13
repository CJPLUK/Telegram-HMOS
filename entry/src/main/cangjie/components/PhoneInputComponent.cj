package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.utils.*
import std.unicode.*

/**
 * 可复用的电话输入组件
 *
 * 对应 iOS PhoneAndCountryNode（AuthorizationSequencePhoneEntryControllerNode.swift）
 * 内嵌的 PhoneInputNode（submodules/PhoneInputNode/Sources/PhoneInputNode.swift）：
 * país 按钮行（国旗+国家名+右侧 chevron） + 分隔线 + 国家代码|手机号 行 + 底部分隔线，
 * 表格行+分隔线样式（非灰色圆角卡片）。
 *
 * - 国家按钮点击 → onCountryTap() 由父页面处理导航
 * - 手机号输入时自动格式化（如 +86 138 0000 0000）
 *
 * test_failed 返修（diag-suite_auth_login-TC-0007.md 第 4 轮，D4.4 结构性移植 M3）：
 * 上一轮（F1/F2/F3）把区号段/号码段做成两条互不通信的 `onChange`（`handleCountryCodeChange`/
 * `handleNumberChange`），国家识别关在自造的 `isPasteLike` 启发式后面，分组用自造的
 * `matchCountryByDigits`（最长前缀匹配 + `utils/CountryData` 自编表），字符合法性靠源侧不存在的
 * `inputFilter`——这是 D4.4 结构级差异，不是可以局部打补丁的问题。
 *
 * 本轮把 `PhoneInputNode.updateNumber`/`updateNumberFromTextFields` 整条搬过来：两个输入框的
 * `onChange` 现在只做一件事——把各自的最新文本缓存下来，再统一调用 `updateNumberFromTextFields()`
 * → `updateNumber()`。国家识别、分组、回写、占位符全部是这一条引擎的结果，不再有任何按表现反推的
 * 分支。`isPasteLike`/`inputFilter`/`matchCountryByDigits` 已全部删除（`utils/PhoneNumberFormatter.cj`
 * 的 `getFormatPattern` 同批删除，属另一 feature `phonenumberformat` 的 M2）。
 *
 * round 2 返修（同一份诊断报告第 4 轮，M3 第 5 条）：补齐粘贴分支 `handlePastedText()`，接入
 * ArkUI TextInput 真实的 `onPaste` 事件（非 `onChange` 长度/位数启发式）。round 1 曾以「ArkUI
 * 无法区分粘贴与逐字符输入」为由跳过该分支，Reviewer 核实 Cangjie SDK 声明文件后确认该前提不
 * 成立——`onPaste` 是独立于 `onChange` 的真实剪贴板事件回调。
 *
 * round 3/4 返修（同一份诊断报告，先后两轮）：round 2 引入的 `onPaste` 与 `onChange` 会对
 * 同一次粘贴动作『都』触发，round 3 尝试用逐字段一次性 `Bool` 抑制标志压制伴随 onChange，
 * 因『onChange 先于 onPaste』时标志无消费者、误吞下一次真实按键而被 round 4 推翻；round 4
 * 把标志改成 200ms 限时窗口收窄泄漏范围，round 5 判定该窗口是『按表现反推出的经验阈值表』
 * （`.agent/agents/diagnoser.md` D4.4 第 4 条明文禁止的形态），予以推翻。
 *
 * round 5 返修（收口轮，Supervisor 推翻前四轮方向）：前四轮的问题框架本身错了——
 * 源侧根本没有「`onPaste` 与 `onChange` 双路径互斥」这个问题，因为源侧压根只有一个入口。
 * `PhoneInputNode.swift:247-261` 的 `textField(_:shouldChangeCharactersIn:replacementString:)`
 * 是唯一的编辑拦截点，内部一个 if/else：`range.length == 0 && string.count > 1`（未选中任何
 * 区间、一次插入超过一个字符）时走粘贴分支并 `return false`（阻止默认编辑，也就不会触发
 * `.editingChanged`，即 `onChange` 的对应物）；否则 `return true`，走正常编辑 + `.editingChanged`。
 * 两个分支天然互斥，因为它们是同一次调用的同一个返回值决出的两条路径分支，不是两个各自独立
 * 触发的事件——round 1-4 引入的 `onPaste` 才是自己额外造出的第二条真实事件路径，之后三轮一直
 * 在消解「自造路径与 onChange 各触发一次、谁后触发谁赢」的问题，方向本身就是在解一个不存在的
 * 源侧问题。
 *
 * round 5 删除 `onPaste`/`handlePastedText` 与全部抑制机制（`pasteCompanionChangeWindow`、
 * 两个 `?MonoTime` 截止时间字段及其过期判断），改为在 `onChange` 内部重建源侧那个 if/else
 * 判据本身——`handleCountryCodeChange`/`handleNumberChange` 是「一个入口、两个分支」，与源侧
 * 同构。判据从「变更前/变更后两次全量文本快照」用最长公共前缀+后缀反推 `range.length`/
 * `replacementString`（`extractPureInsertion()`）。
 *
 * round 6 返修（本轮，Reviewer 用构造样例证伪 round 5 的「确定性重建」自我定性）：
 * `extractPureInsertion` 纯靠前后两份全量文本快照反推 `range.length`/`replacementString`，
 * 这个反演问题本身欠定——数学证明见 `extractPureInsertion()` 处注释「Case 2」：对任意非空
 * `oldText` 和任意 `newText`，「全选 `oldText` 整体替换为 `newText`」永远是一个与该快照吻合
 * 的合法解释，因此仅凭前后两份快照永远无法排除「这次编辑删除过内容」这一可能——不是本轮算法
 * 不够聪明，是纯文本 diff 在原理上不能唯一重建一次编辑操作的 `(range, replacementString)`。
 * Reviewer 的构造样例（号码框已有 `"1"`，全选后粘贴一个同样以 `1` 开头的号码）正是这个欠定性
 * 的真实体现：贪心最长前缀匹配把被选中/被替换的 `"1"` 错误地并入「未变化前缀」，导致算法把
 * 一次有删除的替换误判成零删除的纯插入，静默丢弃了被替换内容里与新内容前缀重合的部分。
 *
 * 本轮曾尝试不再从快照本身猜答案，而是重新引入 `onPaste`——角色与 round 1-4 不同：只读记录，
 * 不调用 `updateNumber`，不写 `displayNumber`/`countryCode`，唯一动作是把「ArkUI 独立报告的、
 * 确实被粘贴的字符串」记进一个内部只读缓存字段，供随后那次 `onChange` 在计算判据时参考；有了
 * 这个「确实粘贴了字符串 R」的独立信号后，判据据称不再靠内容猜测，而是用纯算术
 * `deletionLen = oldLen + |R| - newLen` 把「这次编辑删除了多少字符」锁死，再用位置存在性核验
 * 防御记录错配，round 6 报告据此自称「Option A：消歧成立」。
 *
 * round 6 被证伪（本轮，round 7，Supervisor 裁决）：Reviewer 用构造反例推翻了这个自我定性。
 * ArkUI 不保证 `onPaste`/`onChange` 的相对触发顺序（SDK 声明文件与官方文档均未记载，round
 * 3/4/6 三轮复核一致），当 `onChange` 先于其对应的 `onPaste` 触发时，消费型缓存里可能残留一条
 * **陈旧**记录（属于上一次编辑、未被消费）；若紧邻的下一次**真实、非剪贴板来源**的编辑恰好与
 * 该陈旧记录发生结构性重合（电话号码常见的重复数字模式下并不罕见），长度方程与位置存在性核验
 * 只能证明「存在某个 k 使 newText = oldText 在 k 处拼接陈旧记录」这一纯结构性事实，无法证明
 * 该记录确实对应「这一次」编辑——于是会静默丢弃用户真实输入。反例：`oldText="11"`，陈旧记录
 * `R="22"`，真实编辑（选中首位 `"1"`，输入 `"122"`）产生 `newText="1221"`；长度等式
 * `2+2-4=0` 与位置核验 `"1"+"22"+"1"=="1221"` 均通过，函数误返回 `Some("22")`，
 * `updateNumber(cleanPhoneNumber("22"))` 把真实输入与另一字段内容一起丢弃。round 6 报告中
 * 「不依赖内容巧合匹配」的表述只在记录新鲜（未过期）时成立，而 ArkUI 未提供任何形式的事件
 * 关联标识（无 sequence/generation id）使新鲜性可被验证——该表述是无限定条件的过度断言，
 * 已在本轮撤回。
 *
 * round 7（本轮，收口）：不再尝试任何新的消歧机制（无更聪明的算法、无时间窗、无序列号/
 * generation id、无概率判断——ArkUI 压根不提供 `onPaste` 与 `onChange` 之间任何形式的事件
 * 关联信号，也不保证二者触发顺序，`ohos.arkui.component.text_input.cj.d` 无相关声明）。删除
 * round 6 引入的全部消歧机械——两处 `onPaste` 挂载、`lastPastedCountryCodeText`/
 * `lastPastedNumberText` 缓存字段及其 consume-once 逻辑、长度方程、位置存在性核验
 * `runeRangeEquals`——把判据收紧到**唯一可证不歧义的子集**：`oldText` 为空。这个子集下任何
 * 多字符插入都不可能来自「替换选中内容」（空文本没有可删除的字符），与源侧
 * `range.length == 0 && string.count > 1` 恰好等价，不需要任何额外信号即可证明——覆盖主
 * 用例「往空号码框粘贴一个带区号的完整号码」。**其余一切情形**（`oldText` 非空的多字符插入，
 * 无论是否真的来自剪贴板）一律走两框拼串的正常路径 `updateNumberFromTextFields()`，不做任何
 * 猜测。
 *
 * 已证实的平台能力缺口（如实声明，非「限制」「抖动」或「边界情形」，也不与源侧等价）：源侧
 * `textField(_:shouldChangeCharactersIn:replacementString:)`（`PhoneInputNode.swift:247-261`）
 * 由 UIKit 直接提供 `range: NSRange` 与 `replacementString: String`，编辑操作的位置与内容是
 * 系统在调用时**主动传入**的确定性信息；ArkUI 的 `TextInput.onChange` 只提供变更后的全量
 * 文本，不提供变更操作本身（无 `range`/`replacementString` 等价物），组件也没有任何选区读取
 * 能力——`TextInputController` 的 `setTextSelection`/`caretPosition` 均为**设置器**（返回
 * `Unit`），无 getter；不存在 `onTextSelectionChange` 或任何等价的选区变化回调
 * （`ohos.arkui.component.text_input.cj.d:18-71`/`:247-322`，round 5/6/7 三轮复核一致）。因此
 * `oldText` 非空时，一次编辑的 `range.length`（是否有删除、删了多长）在原理上**不可从 ArkUI
 * 提供的信息中唯一重建**。已排除的候选方案：
 * (1) 纯文本 diff（round 5/6 前半）——对非空 `oldText`，「全选替换」与「插入」是同一份快照的
 *     两个合法解释，数学上欠定，无法排除；
 * (2) `onPaste` 侧信道关联（round 6）——ArkUI 不提供 `onPaste` 与 `onChange` 之间任何形式的
 *     事件关联标识，也不保证二者触发顺序，陈旧记录可与后续无关编辑发生结构性巧合、通过全部
 *     核验（见上方反例），已被 Reviewer 证伪；
 * (3) 时间窗/阈值（round 3/4）——本质是把「多久算相关」变成经验阈值，属于按表现反推的近似
 *     判断（`.agent/agents/diagnoser.md` D4.4 明文禁止的形态），已被 round 5 推翻。
 * 没有第四条候选路径。这是本组件范围内、当前 Cangjie ArkUI SDK 版本下**无法消解**的平台能力
 * 缺口，未覆盖行为差异见 `extractPureInsertion()` 处注释与 `auth_phone_input_node.md`「已知
 * 限制」。
 *
 * D1 返修（`diag-suite_auth_login-TC-0006.md` round 2，独立于上面 round 1-7 的粘贴分支）：
 * `resolveCountryName` 此前恒经 `CountryData.lookupCountryIdByNumber`（「后写覆盖」表，服务号码
 * 前缀识别 / mask 查询）取展示国名，对 `+1` 这类多国共用拨号代码恒返回文件序更靠后的国家
 * （`Canada`），en-US 设备首帧因此显示错误默认国家；locale 反查链路本身（`AuthViewModel.
 * resolveDefaultCountryFromLocale` → `CountryData.getCountryByLocaleTag`/`getCountryByIso2`）
 * 是正确的，问题出在拿到正确初值后，`updateNumber` 首次同步触发的 `onChange` 回声路径
 * 又用错误的表重新反查把它覆盖掉。对照源侧 `PhoneInputNode.countryNameForCode: (Int32, String)?`
 * （`PhoneInputNode.swift:127`）+ 宿主 `AuthorizationSequencePhoneEntryControllerNode` 的
 * `countryCodeUpdated` 闭包（`:147-172`）「身份随行」双支结构：新增 `countryIso2ForCode`
 * 缓存「最近一次外部显式给定的 (拨号代码, ISO2) 身份」，`resolveCountryName` 身份命中时走
 * `CountryData.lookupCountryNameByCodeAndIso2`（对照 `:154` `countryCodeAndIdToName` 分支），
 * 否则落回 `CountryData.lookupCanonicalCountryByCode` 的「先写胜」规范国家（对照 `:166`
 * `countryCodeToIdAndName` 分支）——两张新表由另一 feature `auth_country_selection_screen`
 * 在 `utils/CountryData.cj` 补齐（同一份诊断报告「修法 2」）。
 *
 * 身份捕获时机：源侧身份只在宿主显式下发 `(code, id)` 时写入，用户手敲区号不写。本组件的公开
 * 接口不含独立的 iso2 输入通道（`onCountryCodeChanged` 仍是两参 `(dialDigits, name)`，`@Prop
 * countryCode`/`countryName` 均无 iso2 维度——`auth_phone_entry_screen` M4 宿主接线并行进行中，
 * 本轮刻意不改公开签名以免冲掉其正在进行的接线），改为借助 `@Watch` 观察 `countryName` 这个
 * 「本组件从不自己写」的只读 `@Prop`：它的任何变化只能来自宿主显式下发新的
 * `(countryCode, countryName)` 对（初始 locale 默认值 / 国家选择屏回填），与用户编辑区号框触发
 * 的 `this.countryCode` 本地写回（`updateNumber` 第 e 步）完全隔离，天然对应源侧「显式给定」
 * 这一判据。`aboutToAppear()` 额外补一次同源捕获，覆盖 `@Watch` 按文档语义不会在首次初始化时
 * 触发这一情形。
 *
 * `lookupCountryIdByNumber`（「后写覆盖」）保留在它源侧对位的两处不动：`customFormatter`
 * 默认实现（`:153-158`，对照 `…ControllerNode.swift:196-202`）与 `updateNumber` 第 d 步 /
 * `placeholderText()` 的 mask 查询（对照 `processNumberChange` 的 mask 分支）——源侧本就是
 * `countryCodeToIdAndName`（先写胜）与 `countryCodesByPrefix`（后写覆盖）两张表各服务各的
 * 调用点，这不是整表替换。
 */
@Component
public class PhoneInputComponent {
    // @Prop 单向同步父侧状态到子组件，父组件 @Consume/@State 更新时子组件自动重渲染
    // D-125: 调用点（PhoneInputPage.build()）必须传裸 @State 字段（this.displayCountryCode/
    // this.displayCountryName），不能是函数调用返回值/嵌套字段访问，否则子组件不会重新 build()
    // F3 修复：countryCode 现在也被本组件通过区号输入框 onChange 本地改写（@Prop 允许本地修改，
    // 修改不会同步回父组件；父组件数据源更新时会覆盖本地修改——这正是「手输区号」与「国家选择屏
    // 回填」两条路径都需要的语义：本地编辑实时生效，外部权威来源变化时以外部为准）。
    @Prop var countryCode: String
    // D1 返修：`@Watch` 侦测宿主显式下发的新 countryName（本组件从不自己写这个 @Prop，见 class
    // 级注释「D1 返修」段），驱动下面 `captureCountryIdentityFromProps()` 更新「国家身份随行」
    // 缓存。不改变 `@Prop` 本身的父子单向同步语义，公开签名（宿主调用点仍传裸 @State 字段）不变。
    @Prop @Watch[onCountryNamePropUpdated] var countryName: String
    // 构造时一次性初始值（对齐 SinglePhoneInputComponent.cj 已验证先例），真正驱动 UI 显示与
    // 实时回写的是下面的 @State var displayNumber。
    var phoneNumber: String = ""

    // F2 修复：签名从 (String) -> Unit 扩为 (String, String) -> Unit，识别成功时同时回传
    // 拨号代码与国家名（与 SinglePhoneInputComponent.cj 已有的 onCountryDetected 签名对齐），
    // 供父页面把两者一起写回 AuthViewModel，避免 flag/dialCode/name 三者失配。
    public var onCountryCodeChanged: (String, String) -> Unit = { _: String, _: String => }
    public var onPhoneNumberChanged: (String) -> Unit = { _: String => }
    public var onCountryTap: () -> Unit = { => }

    // M3：对照源侧 `public var customFormatter: ((String) -> String?)?`
    // （PhoneInputNode.swift:169），由宿主控制器注入「输入串 → 拨号代码」的权威识别能力
    // （…ControllerNode.swift:196-202 `customFormatter = { number in
    // AuthorizationSequenceCountrySelectionController.lookupCountryIdByNumber(number, ...)?.0.code }`）。
    // 宿主接线属 M4（feature `auth_phone_entry_screen`，另案返修中，本轮不改 auth/PhoneInputPage.cj）；
    // 默认实现直接委托 `utils/CountryData.lookupCountryIdByNumber`（M1 权威表，源侧
    // `PhoneCountries.txt` 的忠实转录），与 M4 计划注入的实现语义完全相同，M4 落地前不影响任何
    // 可观察行为，也不是自造的近似替代。
    public var customFormatter: (String) -> ?String = { number =>
        match (lookupCountryIdByNumber(number)) {
            case Some((code, _iso2, _pattern, _name)) => Some(code)
            case None => None
        }
    }

    // QA #6-fix: 号码输入框控制器，供父页面在弹出确认弹窗前主动收起软键盘调用
    // （对应 iOS PhoneConfirmationController 弹出时 numberField 主动 resignFirstResponder）。
    // 父组件不传时使用组件内部默认实例，行为与之前完全一致（回归安全）。
    public var controller: TextInputController = TextInputController()

    // F3 新增：区号输入框自己的控制器（跨段焦点跳转场景下预留，收键盘等命令式操作走这个句柄）。
    public var codeController: TextInputController = TextInputController()

    // F1 修复：号码框自持有的可回写状态。原先 `var phoneNumber` 未装饰，onChange 算出的
    // formatted 结果只经回调交给父页，从未写回本输入框——输入框永远显示 IME 原样敲入的字符串。
    // 改为组件自己的 @State，构造入参 phoneNumber 做一次性初始化，此后 onChange 内显式回写。
    @State var displayNumber: String = ""

    // M3：对照源侧 PhoneInputNode.previousCountryCodeText/previousNumberText
    // （PhoneInputNode.swift:84-85），用于 updateNumber 第 f/h 步的「是否真的变化」检测，
    // 初值与源侧常量一致。
    private var previousCountryCodeText: String = "+"
    private var previousNumberText: String = ""

    // round 8 返修（diag-suite_auth_login-TC-0504.md 第 2 轮，B3 修法 R1）：删除 T8 引入的
    // `lastCountryCodeFieldText`/`lastNumberFieldText` 镜像字段——它们只关掉了读侧的分叉
    // （判据改读缓存），写侧仍落在 `@Prop countryCode`/`@State displayNumber` 这两个独立影子
    // 上，导致同帧内「回写目标」与「判据基准」不同址：当父页回路已把 `countryCode` 提前同步成
    // 与本次重算结果相同的值时，ArkUI 见同值写入不重建 `TextInput`，控件残留用户敲入的溢出
    // 字符（诊断报告 §3.3/§5.2）。round 8 把「控件文本的当前值」这一份逻辑值从三份收敛成一份：
    // `this.countryCode`/`this.displayNumber` 本身即是唯一权威副本，判据与写入同址，与源侧
    // `textField.text` 单一存储结构对齐（诊断报告 §6.1/§6.3）。

    // D1 返修：对照源侧 `PhoneInputNode.countryNameForCode: (Int32, String)?`
    // （`PhoneInputNode.swift:127`）——「国家身份」随行缓存 (dialDigits, iso2)，只在国家身份被
    // 外部显式确定时写入（`aboutToAppear()` 首次构造 + `onCountryNamePropUpdated()` 侦测到宿主
    // 显式下发新 countryName 时），用户手敲区号引发的 onChange 不写。`resolveCountryName()`
    // 用它做 (dialDigits, iso2) 精确取名，dialDigits 不匹配或未捕获过身份时回落「先写胜」表。
    private var countryIso2ForCode: ?(String, String) = None

    // M3：对照源侧 `private let phoneFormatter = InteractivePhoneFormatter()`。本工程未移植
    // libphonenumber，`updateText` 恒返回 (None, text)（见 utils/PhoneNumberFormatter.cj 文件头
    // 「未复刻的残余」声明），保留字段只为逐段对照源侧结构、避免每次 updateNumber 重新分配实例。
    private let phoneFormatter: InteractivePhoneFormatter = InteractivePhoneFormatter()

    // D-136: @Component 类内禁止 static 字段（宏展开限制），改用普通实例 let 常量。
    // ic_phone_number_field_id_export: 导出为 public，供宿主页（auth/PhoneInputPage.cj
    // activateInput()）寻址同一个 FocusControl id，不必另抄一份同值字面量。
    public let numberFieldId: String = "phone-input-number-field"
    private let countryCodeFieldId: String = "phone-input-country-code-field"

    public func aboutToAppear(): Unit {
        this.displayNumber = this.phoneNumber
        // D1 返修：`@Watch` 按文档语义不在首次初始化时触发（"在第一次初始化的时候，@Watch装饰的
        // 方法不会被调用"），构造时的初始 (countryCode, countryName) 对（对照源侧
        // `AuthorizationSequencePhoneEntryController.updateData()` 首次下发的 locale 默认值）
        // 需要在这里单独补一次同源捕获。
        this.captureCountryIdentityFromProps()
    }

    // D1 返修：`@Watch[onCountryNamePropUpdated]` 的回调方法（见 `countryName` 声明处注释）。
    private func onCountryNamePropUpdated(): Unit {
        this.captureCountryIdentityFromProps()
    }

    // D1 返修：从当前 `@Prop (countryCode, countryName)` 精确匹配 `utils/CountryData.
    // getCountryList()` 反查 iso2——与既有 `getCountryFlag()`（下方）用的同一张表、同一种
    // (name, code) 精确匹配技巧，不是本组件自建的查表。查不到（异常/未初始化态，如国家名尚为
    // 空串）时清空为 `None`，`resolveCountryName()` 据此回落「先写胜」兜底分支，不保留可能
    // 不匹配的陈旧身份。
    private func captureCountryIdentityFromProps(): Unit {
        let dialDigits = removePlus(this.countryCode).trim()
        let countries = getCountryList()
        for (i in 0..countries.size) {
            if (countries[i][0] == this.countryName && countries[i][1] == this.countryCode) {
                this.countryIso2ForCode = (dialDigits, countries[i][3])
                return
            }
        }
        this.countryIso2ForCode = None
    }

    // T5 修复（M3 第 6 步）：mask 有值 ⇒ 把 X 换成 0（对照
    // PhoneInputNode.swift:178-195 updatePlaceholder 的骨架生成）；mask 为空（源侧
    // mask == nil）⇒ 回落纯文案 "Your phone number"（源 key Login.PhonePlaceholder，
    // 对照 …ControllerNode.swift:176-181/230 未识别国家时的 else 分支）。mask 的有无由
    // M1 的 lookupPatternByNumber 直接判定，不再调用 PhoneNumberFormatter.getExampleNumber
    // 间接造骨架（M3 边界约束）——与 updateNumber 第 d 步共用同一张权威表。
    private func placeholderText(): String {
        let dialDigits = removePlus(this.countryCode).trim()
        match (lookupPatternByNumber(dialDigits)) {
            case Some(mask) =>
                var out = ""
                for (r in mask.toRuneArray()) {
                    if (r == r'X') {
                        out = out + "0"
                    } else {
                        out = out + r.toString()
                    }
                }
                return out
            case None => return "Your phone number"
        }
    }

    func build() {
        Column {
            // 顶部分隔线（对应 iOS countryButtonBackground 上边框线，theme.list.itemPlainSeparatorColor）
            Divider().color(0xC6C6C8).strokeWidth(1)

            // 国家行：国旗 + 国家名，右侧 chevron（对应 iOS countryButton 20pt + countryButtonArrow）
            Row {
                Text(this.getCountryFlag())
                    .fontSize(22)
                    .margin(right: 8)
                Text(this.countryName)
                    .fontSize(20)
                    .fontColor(0x317AFF)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .layoutWeight(1)
                // 资源保真修复（C1）：真实矢量图标（Item List/DisclosureArrow.imageset 转 SVG）
                // 替代 Unicode 字形 "›"，染色对应源侧 theme.list.disclosureArrowColor
                Image(@r(app.media.item_list_disclosure_arrow))
                    .width(7)
                    .height(12)
                    .fillColor(0xC7C7CC)
            }
            .width(100.percent)
            .height(67)
            .padding(left: 24, right: 24)
            .alignItems(VerticalAlign.Center)
            .onClick({ evt =>
                this.onCountryTap()
            })

            // 中间分隔线（对应 iOS countryButtonBackground 下边框线，与 phoneInputBackground 上边框线共用一条）
            Divider().color(0xC6C6C8).strokeWidth(1)

            // 国家代码 | 手机号 行（对应 iOS phoneInputNode: countryCodeField 20pt + numberField 20pt）
            //
            // M3：两框都不再有 inputFilter——源侧本来就没有输入侧字符过滤（keyboardType 只影响
            // 软键盘形态），非法字符靠 cleanPhoneNumber 在 updateNumber 里于「解析时」丢弃，再由
            // 整体回写把两框刷成合法值（第 e 步）。首位 "+" 由 realRegionPrefix 直接携带并显示，
            // 不再靠过滤器人为剥掉。
            //
            // M1/M2 返修（diag-suite_auth_login-TC-0506.md，与 diag-suite_auth_login-TC-0006.md
            // round 3 A1 合并同轮落地，两份报告要求叠加在同一条属性链上）：
            // - M1（B1）：区号段容器由 `.width(60)` 改 `.width(71)`（逐字对位源侧 countryCodeFrame
            //   `width: 71.0`，…ControllerNode.swift:255），并把 TextInput 自身内边距四边清零
            //   （对位源侧 TextFieldNodeView.textRect(forBounds:) = bounds.integral，
            //   TextFieldNode.swift:10-20）——ArkUI TextInput 默认水平内边距 16vp×2 会把 71vp 的
            //   可用文本宽压到 39vp，不清零则 `+380` 仍会被裁，等于没修。
            // - M2（C2）：区号段从「一个可编辑 TextInput（含 +）」拆成「静态 `Text("+")` 前缀 +
            //   只含数字的 TextInput」。源侧 `updateNumber` 的两个分支都无条件保证
            //   `realRegionPrefix` 以 `+` 开头（`realRegionPrefix.hasPrefix("+")` 不变式，
            //   PhoneInputNode.swift:288-301），即「区号段文本恒以 + 开头」在源侧是不可达为假的
            //   不变式；仓颉 ArkUI 的 `TextInput.onChange` 只提供变更后全量文本、无编辑前否决通道
            //   （`onWillDelete` 系列在 `.cj.d` 中未声明），无法像源侧 `shouldChangeCharactersIn`
            //   那样在退格改动 `text` 之前否决，导致「先落地空串、下一帧才补回 +」必然产生至少
            //   一帧无 + 画面（C2 闪烁）。把这个恒真不变式的字形从可编辑缓冲区里提出来渲染成不可
            //   编辑的静态 `Text`，是对源侧不变式的直接编码，不改变任何一个可达状态：`+` 从此没有
            //   任何代码路径能让它消失，C2 在结构上恒真，不再依赖任何重绘时序。
            Row {
                // M1/M2：区号段容器（71vp，对位源侧 countryCodeFrame），内部 `Text("+")` 静态前缀
                // + 纯数字 TextInput，整体居中（对位源侧 countryCodeField.textField.textAlignment
                // = .center，PhoneInputNode.swift:206）。
                Row {
                    Text("+")
                        .fontSize(20)
                        .fontColor(0x000000)
                    TextInput(text: removePlus(this.countryCode), controller: this.codeController)
                        .fontSize(20)
                        .fontColor(0x000000)
                        .backgroundColor(Color.Transparent)
                        .inputFilter("[0-9]*")
                        .padding(left: 0, right: 0, top: 0, bottom: 0)
                        .textAlign(TextAlign.Start)
                        // 48vp：20fp 数字字形步进实测 ≈10.3vp、最长 4 位区号 ⇒ 41.2vp，留 6.8vp
                        // 余量覆盖栅格化差异与光标宽度（diag-suite_auth_login-TC-0506.md M2 边界
                        // 条件）；与 `Text("+")` 合计 ≈57.4vp < 71vp 容器，由外层 Row 的
                        // justifyContent(Center) 整组居中。
                        .width(48)
                        .onChange({ value: String =>
                            this.handleCountryCodeChange(value)
                        })
                        // C 组跨段退格：区号段已聚焦时，退格由 TextInput 原生编辑直接删掉最后一位
                        // （onChange 会带着删除后的新值触发 handleCountryCodeChange，走同一条统一引擎），
                        // 无需额外处理。
                        .id(this.countryCodeFieldId)
                }
                .width(71)
                .height(57)
                .margin(right: 12)
                .alignItems(VerticalAlign.Center)
                .justifyContent(FlexAlign.Center)
                Divider()
                    .vertical(true)
                    .color(0xC6C6C8)
                    .strokeWidth(1)
                    .height(28)
                    .margin(right: 12)
                TextInput(text: this.displayNumber, placeholder: this.placeholderText(), controller: this.controller)
                    .fontSize(20)
                    .backgroundColor(Color.Transparent)
                    // Keep paste-compatible phone punctuation while rejecting
                    // alphabetic input. Formatting still flows through updateNumber.
                    .inputFilter("[0-9 +()-]*")
                    // M3（D1）返修：占位骨架此前走 ArkUI 默认 16fp，与已输入文本的 20fp 不一致
                    // （diag-suite_auth_login-TC-0506.md D1，对位源侧 maskFont /
                    // PhoneInputNode.init 默认 fontSize 同为 20.0，…ControllerNode.swift:224 /
                    // PhoneInputNode.swift:201——本屏是源工程六个 PhoneInputNode 宿主里唯一未传
                    // fontSize、走默认 20.0 的一个，其余五个传 17.0 不适用本屏）。
                    .placeholderFont(size: 20)
                    .layoutWeight(1)
                    .onChange({ value: String =>
                        this.handleNumberChange(value)
                    })
                    // C 组跨段退格：号码段已空时再按一次退格，onChange 不会触发（内容没变），
                    // 用 onKeyEvent 独立捕获这次按键，把焦点还给区号段（对应源侧
                    // numberField.textField.didDeleteBackwardWhileEmpty）。
                    .onKeyEvent({ event =>
                        this.handleNumberFieldKeyEvent(event)
                    })
                    .id(this.numberFieldId)
            }
            .width(100.percent)
            .height(57)
            .padding(left: 24, right: 24)
            .alignItems(VerticalAlign.Center)

            // 底部分隔线（对应 iOS phoneInputBackground 下边框线）
            Divider().color(0xC6C6C8).strokeWidth(1)
        }
        .width(100.percent)
    }

    // D1 修复：不再按拨号代码（区号）反查国旗——+1（US/CA）、+7（RU/KZ）等区号在国家表内
    // 被多国共用，区号首匹配会恒定命中表中排序更靠前的国家（如 🇨🇦 而非 🇺🇸），与实际
    // 显示的 countryName/countryCode 不同源。改为按 (countryName, countryCode) 二元组
    // 精确匹配同一行，恢复「整行取用」语义，使旗/名/码三者恒同源；未命中时保留原有的
    // 空串降级（不回退到首匹配）。
    private func getCountryFlag(): String {
        let countries = getCountryList()
        for (i in 0..countries.size) {
            if (countries[i][0] == this.countryName && countries[i][1] == this.countryCode) {
                return countries[i][2]
            }
        }
        return ""
    }

    // D1 返修（diag-suite_auth_login-TC-0006.md round 2「归因分析·D1」+「修法方向·修法3」）：
    // 原实现恒走 `lookupCountryIdByNumber`（`utils/CountryData.cj` 的「后写覆盖」表，服务号码
    // 前缀识别 / mask 查询），对 `+1`/`+7` 这类多国共用拨号代码恒返回文件序更靠后的国家
    // （`Canada`/`Kazakhstan`），与源侧手机号屏「国家行取名」用的 `CountryList.swift:95-102`
    // `countryCodeToIdAndName`（先写胜）不同源。改为逐支对照源侧 `countryCodeUpdated` 闭包
    // （`AuthorizationSequencePhoneEntryControllerNode.swift:147-172`）的 if/else 两支：
    // - 身份命中（`countryIso2ForCode` 的 dialDigits 与当前一致）→ `lookupCountryNameByCodeAndIso2`
    //   （对照 `:154` `countryCodeAndIdToName[CountryCodeAndId(code, id: name)]` 分支）；
    // - 身份未命中，或命中了但精确 (code, iso2) 查不到名字（数据不一致的兜底）→
    //   `lookupCanonicalCountryByCode` 取「先写胜」的规范国家（对照 `:166` `countryCodeToIdAndName`
    //   分支）；两者都查不到时回落空串——宿主页现有的「name 为空不覆盖已显示国家名」前向兼容处理
    //   （auth/PhoneInputPage.cj，M4 范围）据此保持不变。
    // `customFormatter` 默认实现（`:153-158`）与 mask 查询（`updateNumber` 第 d 步 /
    // `placeholderText()` 的 `lookupPatternByNumber`）仍然使用 `lookupCountryIdByNumber`——
    // 源侧那两处对位的是 `countryCodesByPrefix`（「后写覆盖」），与本函数刻意使用两套不同定序表，
    // 不是整表替换。
    private func resolveCountryName(dialDigits: String): String {
        match (this.countryIso2ForCode) {
            case Some((identityDial, iso2)) =>
                if (identityDial == dialDigits) {
                    match (lookupCountryNameByCodeAndIso2(dialDigits, iso2)) {
                        case Some(name) => return name
                        case None => ()
                    }
                }
            case None => ()
        }
        match (lookupCanonicalCountryByCode(dialDigits)) {
            case Some((_iso2, name)) => name
            case None => ""
        }
    }

    // M3 第 2 步 / round 7 改写：区号段 onChange 入口。对照源侧
    // `textField(_:shouldChangeCharactersIn:replacementString:)` 的 if/else——但源侧该判据由
    // UIKit 直接提供的 `range`/`replacementString` 决出，本组件只能从 ArkUI `onChange` 给出的
    // 变更后全量文本重建；round 7 把重建判据收紧到唯一可证不歧义的子集（`oldText` 为空），这是
    // 已证实的平台能力缺口，非近似（完整推导、已排除的候选方案见 class 级注释「已证实的平台
    // 能力缺口」段）：
    // - 命中（`extractPureInsertion` 判定 `oldText` 为空且插入长度 > 1，等价源侧
    //   `range.length == 0 && string.count > 1`）→ 对照源侧 `self.updateNumber(
    //   cleanPhoneNumber(string), tryRestoringInputPosition: false)`：丢弃两框现有内容，只用
    //   插入的那一段文本重新走一次引擎（不经过 updateNumberFromTextFields 的两框拼串）。
    // - 未命中（`oldText` 非空的一切情形，含真实来自剪贴板粘贴的多字符插入）→ 走两框拼串的
    //   正常路径 `updateNumberFromTextFields()`——与源侧走粘贴分支的行为不同，见
    //   `auth_phone_input_node.md`「已知限制」。
    //
    // M2 返修（diag-suite_auth_login-TC-0506.md，C2）：`+` 已从区号段可编辑缓冲区里提到独立的
    // 静态 `Text("+")`（见 build()），ArkUI 回调的 `digits` 因此只含纯数字，不再自带 "+"。判据
    // 本体（`extractPureInsertion`）与下游引擎（`updateNumber`/`updateNumberFromTextFields`）
    // 全部继续按「带 + 的完整区号串」语义运作，不改一行——本函数在入口/出口各做一次形态转换，
    // 把纯数字读数还原成引擎期望的完整串：
    // - `previousText`/`newText` 两个参与 `extractPureInsertion` 判据的快照必须仍是带 "+" 形态
    //   （`this.countryCode` 本身、以及 `removeDuplicatedPlus("+" + digits)`），不得改传纯数字
    //   ——`this.countryCode` 恒非空（至少含 "+"），`extractPureInsertion` 的 `oldLen == 0` 粘贴
    //   分支在区号段上因此恒不命中、是死分支；若改传纯数字，`digits` 会在未输入时为空，
    //   会让这个死分支突然变活，引入本轮未取证的行为变更。
    // - 用 `removeDuplicatedPlus("+" + digits)` 合成而非裸拼接：用户仍可能在数字键盘上敲出
    //   `+`（源侧 keyboardType 含 `+`），`removeDuplicatedPlus` 只保留最靠前的一个 `+`，是源侧
    //   同款去重工具函数（`utils/PhoneNumberFormatter.cj`，逐字对照 PhoneInputNode.swift:7-21）。
    private func handleCountryCodeChange(digits: String): Unit {
        let previousText = this.countryCode
        let newText = removeDuplicatedPlus("+" + digits)
        this.countryCode = newText
        match (this.extractPureInsertion(previousText, newText)) {
            case Some(insertedText) =>
                this.updateNumber(cleanPhoneNumber(insertedText), tryRestoringInputPosition: false)
            case None =>
                this.updateNumberFromTextFields()
        }
    }

    // M3 第 2 步 / round 7 改写：号码段 onChange 入口，语义同上。对照源侧
    // numberTextChanged(_:) + 同一个 shouldChangeCharactersIn（两框共用同一个 delegate 方法，
    // PhoneInputNode.swift:235-236）。
    private func handleNumberChange(value: String): Unit {
        let previousText = this.displayNumber
        this.displayNumber = value
        match (this.extractPureInsertion(previousText, value)) {
            case Some(insertedText) =>
                this.updateNumber(cleanPhoneNumber(insertedText), tryRestoringInputPosition: false)
            case None =>
                this.updateNumberFromTextFields()
        }
    }

    // round 7 修法本体：判据收紧到唯一可证不歧义的子集——`oldText` 为空。
    //
    // 数学事实（round 5/6 已证明，本轮沿用）：对任意**非空** `oldText` 和任意 `newText`，
    // "全选 `oldText` 整体替换为 `newText`"（`range=[0,oldLen)`，`replacementString=newText`）
    // 永远是一个与该 (oldText, newText) 快照吻合的合法解释（`oldText[0:0] + newText +
    // oldText[oldLen:oldLen] == newText` 对任意 newText 恒成立）。因此非空原文的重建在原理上
    // **必然歧义**，不存在任何后处理算法能从两份全量文本快照本身排除「这次编辑删除过内容」
    // 这一可能。round 6 曾尝试引入 ArkUI `onPaste` 侧信道作为快照之外的独立信号打破这个欠定性
    // （长度方程 `deletionLen = oldLen + |R| - newLen` + 位置存在性核验），但该信道本身不提供
    // 任何形式的事件关联标识（无 sequence/generation id），也不保证与 `onChange` 的相对触发
    // 顺序，导致陈旧的粘贴记录可能与后续一次无关的真实编辑发生结构性巧合、骗过全部核验——已被
    // Reviewer 用构造反例证伪（详见 class 级注释「round 6 被证伪」段），本轮不再保留。
    //
    // 可证不歧义的子集只有一个：`oldText` 为空。空文本没有任何字符可供选中/删除，"全选替换"
    // 在 `oldText` 为空时退化为 `"" + newText + "" == newText`——这与"纯插入"是同一个解释，
    // 不构成另一种可能，因此 `oldText` 为空时任何多字符变化都只能是纯插入，等价于源侧
    // `range.length == 0 && string.count > 1`，不需要任何额外信号即可证明。
    //
    // `oldText` 非空的一切情形（无论这次多字符插入是否真的来自剪贴板粘贴）：无法仅凭 ArkUI
    // `onChange` 提供的信息唯一重建这次编辑的 `range.length`——这是已证实的平台能力缺口（见
    // class 级注释），一律返回 `None`，走两框拼串的正常路径，不做任何猜测。这与源侧非空原文
    // 情形下走粘贴分支的行为不同：源侧会丢弃两框现有内容、仅用粘贴串重新识别；本组件会保留
    // 两框现有内容参与拼串重算，可能导致区号解析结果与源侧不一致（未覆盖行为差异，详见
    // `auth_phone_input_node.md`「已知限制」）。
    //
    // 已知边界（round 8 更新，diag-suite_auth_login-TC-0504.md B3 修法 R1）：round 7 这里曾
    // 披露的风险——`lastCountryCodeFieldText` 镜像缓存可能落后于宿主绕过本文件直接写入
    // `@Prop countryCode` 的情形，导致 `oldText` 基线落后于框架已同步的真实显示值——已随本轮
    // 改动消失。`handleCountryCodeChange`/`handleNumberChange` 现在直接读写 `this.countryCode`/
    // `this.displayNumber` 本身（不再有独立镜像缓存），`previousText` 与 ArkUI 框架同步进来的
    // `@Prop`/`@State` 新值天然同址、不可能落后，`oldText` 基线恒等于框架当前已知的真实值。
    // 该失步风险随缓存被删除一并消失。
    private func extractPureInsertion(oldText: String, newText: String): ?String {
        let oldLen = Int64(oldText.toRuneArray().size)
        let newLen = Int64(newText.toRuneArray().size)
        if (oldLen == 0 && newLen > 1) {
            return Some(newText)
        }
        return None
    }

    // M3 第 3 步：对照源侧 PhoneInputNode.swift:270-273 updateNumberFromTextFields。
    // 把两框各自缓存的最新文本拼成一整串（去掉重复的 "+"），交给统一入口 updateNumber
    // 重新识别 + 格式化——源侧「单串单引擎」的核心。
    private func updateNumberFromTextFields(): Unit {
        let inputText = removeDuplicatedPlus(
            cleanPhoneNumber(this.countryCode) + cleanPhoneNumber(this.displayNumber))
        this.updateNumber(inputText)
    }

    // M3 第 4 步：逐段对照源侧 PhoneInputNode.swift:275-365 updateNumber。
    //
    // round 5/6/7：粘贴分支（源侧第 5 步）不是独立事件路径，由调用方
    // `handleCountryCodeChange`/`handleNumberChange` 判据命中时直接传入
    // `cleanPhoneNumber(插入的那一段文本)` 调用本函数（`tryRestoringInputPosition: false`），
    // 绕过 `updateNumberFromTextFields()` 的两框拼串——与源侧 `updateNumber(cleanPhoneNumber(
    // string), tryRestoringInputPosition: false)` 逐字对照。判据本身（round 7 收紧为已证不
    // 歧义子集）见 `extractPureInsertion()` 处注释。
    private func updateNumber(inputText: String, tryRestoringInputPosition!: Bool = true,
        forceNotifyCountryCodeUpdated!: Bool = false): Unit {
        // a. 兜底识别：本工程未移植 libphonenumber，恒返回 (None, inputText)
        //    （见 utils/PhoneNumberFormatter.cj InteractivePhoneFormatter 文件头声明的
        //    「未复刻的残余」）。
        let (formatterPrefix, formatterText) = this.phoneFormatter.updateText(inputText)
        var regionPrefix: ?String = formatterPrefix
        var text: String = formatterText

        // b. customFormatter 命中时整体覆盖：region 来自权威表查询，text 直接用原始
        //    inputText（不用兜底路径给出的 text）——这一步是本屏分组结果的真正来源。
        match (this.customFormatter(inputText)) {
            case Some(customCode) =>
                regionPrefix = Some("+" + customCode)
                text = inputText
            case None => ()
        }

        // c. 有识别结果 ⇒ 从 text 里切出 realRegionPrefix + numberText；否则整串留在
        //    区号段、号码段清空（+999、99999 等未识别输入的源侧语义，非法区号也走这里）。
        var hasRegion = false
        match (regionPrefix) {
            case Some(rp) => hasRegion = rp.size > 0 && rp != "+"
            case None => ()
        }
        var realRegionPrefix: String = ""
        var numberText: String = ""
        if (hasRegion) {
            var rp = ""
            match (regionPrefix) {
                case Some(v) => rp = v
                case None => ()
            }
            var rrp = cleanSuffix(rp)
            if (!rrp.startsWith("+")) {
                rrp = "+" + rrp
            }
            var t = text
            if (!t.startsWith("+")) {
                t = "+" + t
            }
            realRegionPrefix = rrp
            numberText = cleanPrefix(t[realRegionPrefix.size..t.size])
        } else {
            var rrp = text
            if (!rrp.startsWith("+")) {
                rrp = "+" + rrp
            }
            realRegionPrefix = rrp
            numberText = ""
        }

        // d. mask 分组：与 placeholderText() 共用同一张 M1 权威表查询
        //    （utils/CountryData.lookupPatternByNumber + utils/PhoneNumberFormatter.
        //    formatPhoneNumberToMask），非自建掩码表。
        let dialDigits = removePlus(realRegionPrefix).trim()
        match (lookupPatternByNumber(dialDigits)) {
            case Some(mask) => numberText = formatPhoneNumberToMask(numberText, mask)
            case None => ()
        }

        // e. 回写判据（round 8 修法本体，diag-suite_auth_login-TC-0504.md B3 §8 R1）：判据与
        //    写入同址——直接比对 `this.countryCode` 自身，不再经过已删除的镜像缓存。
        //    `this.countryCode` 现在就是控件文本的唯一权威副本，同值不写、异值写入即纠正控件
        //    （与源侧 `if realRegionPrefix != textField.text { textField.text = realRegionPrefix }`
        //    结构对齐，判据失效时不再有后果——写入天然幂等）。
        if (realRegionPrefix != this.countryCode) {
            this.countryCode = realRegionPrefix
        }

        // f. 国家识别变化通知（对照源侧 countryCodeUpdated 回调，:310-318）。
        if (this.previousCountryCodeText != realRegionPrefix || forceNotifyCountryCodeUpdated) {
            this.previousCountryCodeText = realRegionPrefix
            let name = this.resolveCountryName(dialDigits)
            this.onCountryCodeChanged(dialDigits, name)
        }

        // round 8 修法本体（同上 e 步，对称应用于号码段）：判据与写入同址，直接比对
        //    `this.displayNumber` 自身，不再经过已删除的镜像缓存。`handleNumberChange` 在调用
        //    本函数前已把 `this.displayNumber` 同步成控件最新的完整显示文本，因此这里的比较
        //    对象恒是控件真值，不是任何滞后镜像——这一支同时收敛了诊断报告 §5.2 记录的第二个
        //    投影（号码段末位为非数字时字符残留，如先输 `9` 再输字母 `a`）：控件变成 `9a` 后
        //    `this.displayNumber` 已被 `handleNumberChange` 同步为 `"9a"`，引擎重算出
        //    `numberText=="9"`（字母被 `cleanPhoneNumber` 丢弃），`"9" != "9a"` 恒判真，
        //    触发重建纠正控件，字母不会永久残留。
        if (numberText != this.displayNumber) {
            this.displayNumber = numberText
        }

        // g. 无条件回调（对照源侧 numberTextUpdated，:353，不受上面写回 guard 影响）。
        this.onPhoneNumberChanged(numberText)

        // h. 号码段从空变为非空时把焦点交给号码段（对照源侧 :355-362
        //    previousNumberText.isEmpty && !numberText.isEmpty → becomeFirstResponder）。
        if (this.previousNumberText.size == 0 && numberText.size > 0) {
            FocusControl.requestFocus(this.numberFieldId)
        }
        this.previousNumberText = numberText

        // i. 源侧在此显式调用 updatePlaceholder()；仓颉侧 placeholderText() 由 build()
        //    声明式引用 this.countryCode 现算，country/mask 更新后框架自动重渲染，
        //    无需显式调用。
    }

    // TC-0504 C 组跨段退格（号码段一侧）：号码段已空时再按一次退格，TextInput 内容不变
    // （没有可删的字符），onChange 不会触发，只能靠 onKeyEvent 独立捕获这次按键。
    // keyCode 2055 为 HarmonyOS multimodalInput 标准 KEYCODE_DEL（退格）数值常量
    // （ArkUI KeyEvent.keyCode 是同一套系统 keyCode 数值，非 Cangjie 独有枚举）。
    private func handleNumberFieldKeyEvent(event: KeyEvent): Unit {
        if (event.keyType == KeyType.Down && event.keyCode == 2055 && this.displayNumber.size == 0) {
            FocusControl.requestFocus(this.countryCodeFieldId)
        }
    }
}
