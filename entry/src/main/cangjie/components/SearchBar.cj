/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * SearchBar — 统一可复用搜索栏 (Phase P2-411)
 *
 * 对应 Telegram-iOS submodules/SearchBarNode + SearchUI：
 *   列表顶部统一搜索栏（放大镜图标 + 输入框 + 清除按钮 + 激活时"Cancel"按钮 + loading 态）。
 *   工程现状各页内联裸 TextInput（ChatListPage / HashtagSearchPage /
 *   SearchPeerMembersComponent 等），行为/视觉不统一；本组件做统一封装。
 *
 * 视觉对齐工程现有搜索栏（HashtagSearchPage 搜索框 + ChatListPage 🔍 / ✕ 约定）：
 *   - 圆角胶囊输入区：height 36、borderRadius 18、背景灰 0xF0F0F0
 *   - 左侧 🔍 放大镜（loading 时替换为 LoadingProgress 转圈，参考 SolidRoundedButton）
 *   - 输入非空时右侧 ✕ 清除按钮（与 ChatListPage / SavedMessagesPage 一致）
 *   - 激活态（获焦或 showCancel）整条右侧显示 "Cancel" 文字按钮（蓝 0x317AFF）
 *
 * 实现说明（坑规避，承接 SolidRoundedButton 经验）：
 *   - @Component 函数参数（onChange/onSubmit/onCancel）用普通 var + 默认值。
 *   - text 用 @Prop（String 受支持）而非普通 var：调用方在自己的 onCancel/onChange
 *     回调里重置 @State 搜索字段后，需要这个变化被动同步回显到本组件内部
 *     TextInput（例如 Cancel 后清空回显）；HI-AUTH-0006 修复：普通 var 只在组件首次
 *     构造时接收调用点初值，父组件后续把 @State 字段改回不同值不会重新推入子组件，
 *     导致 TextInput 显示的文本和父组件真实搜索状态不同步（同源 D-125）。
 *   - custom @Component 实例化后不能直接链内置属性（.margin/.width 等）；
 *     调用方若需外边距请外包 Column/Row。
 *   - TextInput / 文字按钮放在同一 Row；放大镜与清除用 Text 字形（🔍 / ✕），
 *     与工程现有搜索栏一致（无 search media 资源）。
 *   - 顶层名 SearchBar 避免与包级已有符号冲突（components 包内无同名）。
 *
 * Props:
 *   text:        当前文本（调用方维护，回显进输入框）
 *   placeholder: 占位文案（默认 "Search"）
 *   onChange:    文本实时变化回调 (String) -> Unit
 *   onSubmit:    回车提交回调 (String) -> Unit（默认空操作）
 *   onCancel:    取消回调 () -> Unit（清空文本 + 收起激活态由调用方决定）
 *   showCancel:  是否强制显示 "Cancel"（默认 false；获焦时也会显示）
 *   loading:     是否加载中（@Prop，无默认值，调用点必须显式传）；true → 左侧 🔍 替换为转圈
 *   inputId:     TC-0018 返修（§C）：非空时对内部 TextInput 施加 .id(this.inputId)，
 *                供调用方 FocusControl.requestFocus(inputId) 外部定位聚焦（默认空，
 *                不改变任何既有视觉与默认行为）。
 *   inlineNavigation: TC-0075 返修（diag-suite_settings_root-TC-0075.md 修法 M3）：源侧
 *                SearchBarNode 自己的 fieldStyle == .inlineNavigation 形态（56 高、
 *                0xF2F2F7 底、radius 28、放大镜恒常渲染、左对齐、无 Cancel、透明宿主行），
 *                对位 TabBarComponent.swift:135-172 的 tab bar 搜索胶囊。默认 false，
 *                8 处既有调用点逐像素不变。
 */
// 每个 SearchBar 实例的默认输入框 id：静息态提示层点击后要把焦点交给输入框，
// 调用方未传 inputId 时也需要一个可寻址的 id。
private var _searchBarIdSeq: Int64 = 0
private func nextSearchBarInputId(): String {
    _searchBarIdSeq += 1
    return "searchbar_auto_${_searchBarIdSeq}"
}

@Component
public class SearchBar {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Prop var text: String
    @Prop var hint: String
    /** Canonical source lang-pack key for a search hint retained across tab switches. */
    public var localizedHintKey: String = ""
    public var onChange: (String) -> Unit = { _s => }
    public var onSubmit: (String) -> Unit = { _s => }
    public var onCancel: () -> Unit = { => }
    // Expose activation so host pages can coordinate navigation chrome.
    public var onFocus: () -> Unit = { => }
    public var showCancel: Bool = false
    // @Prop 而非普通 var：普通 var 只在组件首次构造时接收调用点初值
    // （本文件头 HI-AUTH-0006 那条），所以 loading 从来就没生效过——7 个调用点
    // 传了它，一个转圈都没出现过。@Prop 不能有默认值，调用点必须显式传。
    @Prop var loading: Bool
    public var inputId: String = ""
    public var inlineNavigation: Bool = false
    /**
     * 左侧图标切成「返回箭头」。对位 iOS EmojiSearchStatusComponent 的第三态
     * `.results`（`EmojiSearchStatusComponent.swift:522` 的 emoji_search_to_arrow）：
     * 搜索出结果后放大镜变成箭头，点它退出搜索。
     * 默认 false，既有 8 处调用点行为不变。
     */
    @Prop var backArrow: Bool
    public var onBackArrow: () -> Unit = { => }

    // 内部聚焦态：获焦时显示 Cancel 按钮（与 showCancel 取或）
    @State var isFocused: Bool = false
    // Cancel 时通过控制器 stopEditing() 让 TextInput 真正失焦，IME 随之收起。
    private let inputController: TextInputController = TextInputController()
    private let autoInputId: String = nextSearchBarInputId()

    private func effectiveInputId(): String {
        return if (this.inputId.size > 0) { this.inputId } else { this.autoInputId }
    }

    private func displayedHint(): String {
        if (this.localizedHintKey.size > 0) {
            return this.sourceLocalizationPresentation.getOr(this.localizedHintKey, this.hint)
        }
        return this.hint
    }
    // CTL-CONTACTS-005: Cancel 自右弹入进度(0→1;iOS 玻璃 X scale0.001+offset84 弹入的近似)
    @State var cancelIn: Float64 = 0.0

    // 是否展示 Cancel 按钮：显式要求或当前获焦
    private func shouldShowCancel(): Bool {
        // TC-0075 返修（修法 M3b）：inlineNavigation 形态对位源侧 cancelText: nil——
        // 无论聚焦与否都没有取消按钮，必须早于 showCancel||isFocused 判断早退。
        if (this.inlineNavigation) { return false }
        return this.showCancel || this.isFocused
    }

    // G-11 返修（diag-suite_settings_privacy-E12-batch.md）：静息态提示层（放大镜+占位符
    // 整体居中）与「TextInput 自身占位符改空串以免双绘」共用同一门控。较原静息态覆盖层
    // 判据多出 !backArrow 一项——backArrow 是本轮 BASE 合并的新第三态（loading/inlineNavigation
    // 同级），原判据未覆盖它会导致 backArrow=true 且文本为空时新提示层与返回箭头图标重叠。
    private func isRestingHint(): Bool {
        return !this.inlineNavigation && !this.isFocused && this.text.size == 0 && !this.loading && !this.backArrow
    }

    // R-3 归因返修（diag-fixture-reset-searchbar-focus.md）：可见性(shouldShowCancel/showCancel)
    // 与入场动画(cancelIn)此前被耦合成同一态，导致 showCancel=true 但未获焦时 Cancel 挂载却
    // opacity=0+位移错位（对位 SearchBarNode.swift:996 hasCancelButton 只控可见性、
    // :1344-1345 滑入只是一次性瞬态，不改真实 frame/alpha）。这里让 cancelIn 的稳态与
    // showCancel 对齐，onFocus 的弹入动画不变。
    public override func aboutToAppear(): Unit {
        this.cancelIn = if (this.showCancel) { 1.0 } else { 0.0 }
    }

    public func build() {
        Row {
            // CTL-CONTACTS-004: iOS navigationSearchBar 规格——field 44pt、radius h/2=22、
            // 静息态放大镜+占位符整体居中（间距 4）；激活/有文字后左对齐（x=8，间距 2）。
            // 实现：底层居中提示 + 顶层透明 TextInput（点击即聚焦，聚焦后提示隐藏）
            Stack {
                // 激活态：左对齐 放大镜/转圈 + 输入框 + 清除
                Row {
                    if (this.loading) {
                        LoadingProgress()
                            .width(18)
                            .height(18)
                            .color(0x8E8E93)
                            .margin(left: 8, right: 2)
                    } else if (this.backArrow) {
                        Text("\u{2039}")
                            .fontSize(26)
                            .fontColor(0x8E8E93)
                            .width(15)
                            .textAlign(TextAlign.Center)
                            .margin(left: 8, right: 2)
                            .onClick({ _evt => this.onBackArrow() })
                    } else if (this.inlineNavigation) {
                        // TC-0075 返修（修法 M3e）：inlineNavigation 形态放大镜恒常渲染，对位
                        // TabBarComponent.swift:117-133（图标两态共用，仅位置/缩放不同，
                        // 不因聚焦/文本增减）。
                        Image(@r(app.media.clist_ic_search))
                            .width(22)
                            .height(22)
                            .fillColor(0x8E8E93)
                            .margin(left: 12, right: 8)
                    } else if (this.isFocused || this.text.size > 0) {
                        // 资源保真修复：真实矢量图标 clist_ic_search 替代 emoji 字形
                        Image(@r(app.media.clist_ic_search))
                            .width(15)
                            .height(15)
                            .fillColor(0x8E8E93)
                            .margin(left: 8, right: 2)
                    }

                    // 输入框（静息态占位符由居中提示层显示，此处仅激活态出占位）
                    // 注意：TextInput 自带不透明白底（backgroundColor(0x00FFFFFF) 无效，
                    // 真机实证盖住胶囊灰），直接涂胶囊同色 0xF0F0F0 融入背景
                    // rework1 顺手改：`.id()` 按原规格仅在 inputId 非空时调用（与官方文档
                    // "初始值为空字符串"的语义保持字面一致；功能上 `.id("")` 本就等价于不调用，
                    // 此处只是对齐规格字面表述，不改变行为）。
                    if (this.effectiveInputId().size > 0) {
                        // G-11：静息态占位符改由下方独立提示层承载，此处置空免双绘；
                        // 其余状态（激活/inlineNavigation/loading/backArrow）占位符不变。
                        TextInput(text: this.text, placeholder: if (this.isRestingHint()) { "" } else { this.displayedHint() }, controller: this.inputController)
                            .id(this.effectiveInputId())
                            .fontSize(17)
                            .fontColor(0x000000)
                            .placeholderColor(0x99000000)
                            .caretColor(0x317AFF)
                            .height(if (this.inlineNavigation) { 56 } else { 44 })
                            .layoutWeight(1)
                            // 静息态占位符居中（iOS navigationSearchBar），激活后左对齐；
                            // inlineNavigation 恒取左对齐（TC-0075 修法 M3e）。
                            .textAlign(if (this.inlineNavigation || this.isFocused || this.text.size > 0) { TextAlign.Start } else { TextAlign.Center })
                            .backgroundColor(if (this.inlineNavigation) { 0xF2F2F7 } else { 0xF0F0F0 })
                            .padding(left: if (this.inlineNavigation || this.isFocused || this.text.size > 0) { 0 } else { 8 }, right: 4)
                            .onChange({ value: String =>
                                this.text = value
                                this.onChange(value)
                            })
                            .onSubmit({ _key: EnterKeyType =>
                                this.onSubmit(this.text)
                            })
                            .onFocus({ =>
                                this.isFocused = true
                                // CTL-CONTACTS-005: Cancel 0.5s 弹入
                                this.cancelIn = 0.0
                                safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 500, curve: Curve.EaseOut), { =>
                                    this.cancelIn = 1.0
                                })
                                this.onFocus()
                            })
                            .onBlur({ =>
                                this.isFocused = false
                                // R-3: 失焦不再把 cancelIn 强制归零；Cancel 的稳态可见性
                                // 只跟随 showCancel（对位源侧 hasCancelButton），与焦点解耦。
                                this.cancelIn = if (this.showCancel) { 1.0 } else { 0.0 }
                            })
                    } else {
                        // G-11：静息态占位符改由下方独立提示层承载，此处置空免双绘；
                        // 其余状态（激活/inlineNavigation/loading/backArrow）占位符不变。
                        TextInput(text: this.text, placeholder: if (this.isRestingHint()) { "" } else { this.displayedHint() }, controller: this.inputController)
                            .fontSize(17)
                            .fontColor(0x000000)
                            .placeholderColor(0x99000000)
                            .caretColor(0x317AFF)
                            .height(if (this.inlineNavigation) { 56 } else { 44 })
                            .layoutWeight(1)
                            // 静息态占位符居中（iOS navigationSearchBar），激活后左对齐；
                            // inlineNavigation 恒取左对齐（TC-0075 修法 M3e）。
                            .textAlign(if (this.inlineNavigation || this.isFocused || this.text.size > 0) { TextAlign.Start } else { TextAlign.Center })
                            .backgroundColor(if (this.inlineNavigation) { 0xF2F2F7 } else { 0xF0F0F0 })
                            .padding(left: if (this.inlineNavigation || this.isFocused || this.text.size > 0) { 0 } else { 8 }, right: 4)
                            .onChange({ value: String =>
                                this.text = value
                                this.onChange(value)
                            })
                            .onSubmit({ _key: EnterKeyType =>
                                this.onSubmit(this.text)
                            })
                            .onFocus({ =>
                                this.isFocused = true
                                // CTL-CONTACTS-005: Cancel 0.5s 弹入
                                this.cancelIn = 0.0
                                safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 500, curve: Curve.EaseOut), { =>
                                    this.cancelIn = 1.0
                                })
                                this.onFocus()
                            })
                            .onBlur({ =>
                                this.isFocused = false
                                // R-3: 失焦不再把 cancelIn 强制归零；Cancel 的稳态可见性
                                // 只跟随 showCancel（对位源侧 hasCancelButton），与焦点解耦。
                                this.cancelIn = if (this.showCancel) { 1.0 } else { 0.0 }
                            })
                    }

                    // 清除按钮（输入非空时显示）
                    if (this.text.size > 0) {
                        Text("✕")
                            .fontSize(13)
                            .fontColor(0xFFFFFF)
                            .textAlign(TextAlign.Center)
                            .width(18)
                            .height(18)
                            .borderRadius(9)
                            .backgroundColor(0xBFC4CC)
                            .margin(right: 10)
                            .onClick({ _evt =>
                                this.text = ""
                                this.onChange("")
                            })
                    }
                }
                .width(100.percent)
                .alignItems(VerticalAlign.Center)

                // G-11 返修（RC-E12-10）：放大镜与占位文案作为一个整体在 Stack 内居中
                // （.alignContent(Alignment.Center) 已在下方 :width/height 修饰链上），
                // 对位源侧 SearchBarPlaceholderNode.swift:221-248 的度量成对布局——
                // totalWidth = labelWidth + iconWidth + spacing，iconX 由整体居中反推，
                // 不再依赖按字面量 "Search" 宽度标定的常量 translate（换任意占位文案
                // 都不再错位）。
                //
                // 历史约束仍然有效（此前用裸 Image + translate 绕开它，见上一版注释）：
                // 静息态提示层不能用一个占满宽度的 Row 吞掉胶囊中心的点击，TextInput
                // 会收不到焦点（b10 实测）。这里的 Row 本身不撑满宽度（无
                // .width(100.percent)，仅按 icon+space+text 的内容宽度居中），并且显式
                // 把自身响应区置零面积——本工程 cangjie ArkUI 绑定当前未暴露
                // hitTestBehavior/HitTestMode（dev_pattern.md D-149，components/UndoToast.cj
                // 已实测确认该 API 缺口），改用 D-149 记录的已验证替代 API
                // `responseRegion(Rectangle(...))`：零面积响应区下点击永远落不进该节点
                // 自身热区，会直接回传给父 Stack 继续命中测试、落到下方 TextInput 上
                // （先例 components/ItemListComponents.cj:558-571，同一模式）。
                if (this.isRestingHint()) {
                    Row(space: 4.0) {
                        Image(@r(app.media.clist_ic_search))
                            .width(15)
                            .height(15)
                            .fillColor(0x8E8E93)
                        Text(this.displayedHint())
                            .fontSize(17)
                            .fontColor(0x99000000)
                    }
                    .alignItems(VerticalAlign.Center)
                    // 提示层自己响应点击并把焦点交给输入框（子节点会截获命中，无法穿透）。
                    .onClick({ _evt =>
                        FocusControl.requestFocus(this.effectiveInputId())
                    })
                }
            }
            .layoutWeight(1)
            .height(if (this.inlineNavigation) { 56 } else { 44 })
            .backgroundColor(if (this.inlineNavigation) { 0xF2F2F7 } else { 0xF0F0F0 })
            .borderRadius(if (this.inlineNavigation) { 28 } else { 22 })
            .clip(true)
            .alignContent(Alignment.Center)

            // 激活态右侧 Cancel 文字按钮(CTL-CONTACTS-005: 自右弹入)
            if (this.shouldShowCancel()) {
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x317AFF)
                    .margin(left: 10)
                    .opacity(this.cancelIn)
                    .translate(x: (1.0 - this.cancelIn) * 60.0)
                    .onClick({ _evt =>
                        this.text = ""
                        this.isFocused = false
                        this.cancelIn = 0.0
                        // 真正失焦 → IME 随之收起
                        this.inputController.stopEditing()
                        this.onCancel()
                    })
            }
        }
        .width(100.percent)
        .height(if (this.inlineNavigation) { 56 } else { 60 })
        .padding(left: if (this.inlineNavigation) { 0 } else { 16 }, right: if (this.inlineNavigation) { 0 } else { 16 })
        .backgroundColor(if (this.inlineNavigation) { Color.Transparent } else { 0xFFFFFF })
        .alignItems(VerticalAlign.Center)
    }
}
