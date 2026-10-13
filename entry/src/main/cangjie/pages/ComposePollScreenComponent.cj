package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * ComposePollScreenComponent — 创建投票表单组件
 *
 * 对应 Telegram-iOS ComposePollScreen（问题 + 多选项录入 + 匿名/多选/测验开关）
 *
 * 功能:
 * - 问题输入栏（最多 255 字符）
 * - 最多 10 条选项（每条最多 100 字符），动态增减
 * - 匿名投票开关（Anonymous Voting）
 * - 多选开关（Multiple Answers）
 * - 测验模式开关（Quiz Mode）
 * - 确认发送 → ComposePollService.sendPoll → MTProto
 *
 * 禁用规则:
 * - 问题为空 / 选项 < 2 条时，发送按钮不可用
 *
 * S-64: aboutToAppear 必须 public override
 * R-69: spawn + launch 模式（网络调用在 spawn，@State 写在 launch）
 * 输入框：用 Stack overlay Text+.enabled(false) 代替占位提示，避免原生提示参数
 */
@Component
public class ComposePollScreenComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ==================== 对外回调 ====================
    /** 发送成功后由 ComposePollScreen 关闭页面 */
    public var onSendSuccess: () -> Unit = { => }
    /** 取消时回调 */
    public var onCancel: () -> Unit = { => }
    // 嵌入附件 sheet 时为 true：不加顶部/底部安全区内缩（sheet 自己处理）
    public var embedded: Bool = false

    // ==================== 表单状态 ====================
    @State var question: String = ""
    @State var options: ArrayList<String> = ArrayList<String>()
    @State var isAnonymous: Bool = true
    @State var isMultipleChoice: Bool = false
    @State var isQuiz: Bool = false
    @State var isSending: Bool = false
    @State var errorMessage: String = ""
    // Fix2: quiz 模式选定的正确答案下标（指向 this.options，-1 = 未选）。
    // quiz 单选，只允许一个正确答案。
    @State var correctOptionIndex: Int64 = -1

    // ==================== 生命周期 ====================
    public override func aboutToAppear(): Unit {
        Hilog.info(0, "CjTelegram", "[ComposePollScreenComponent] aboutToAppear")
        // 初始化两个空选项
        if (this.options.size == 0) {
            let initList = ArrayList<String>()
            initList.add("")
            initList.add("")
            this.options = initList
        }
    }

    // ==================== 辅助方法 ====================

    private func canSend(): Bool {
        if (this.question.size == 0) { return false }
        var filledOptions: Int32 = 0
        for (opt in this.options) {
            if (opt.size > 0) { filledOptions += 1 }
        }
        if (filledOptions < 2) { return false }
        // Fix2: quiz 模式必须选定一个正确答案，且该选项非空
        if (this.isQuiz) {
            if (this.correctOptionIndex < 0) { return false }
            if (this.correctOptionIndex >= Int64(this.options.size)) { return false }
            if (this.options[this.correctOptionIndex].size == 0) { return false }
        }
        return true
    }

    private func doSend(): Unit {
        if (!this.canSend()) { return }
        let filledOptions = ArrayList<String>()
        for (opt in this.options) {
            if (opt.size > 0) {
                filledOptions.add(opt)
            }
        }
        // Fix2: 将 correctOptionIndex（this.options 下标）映射为 filledOptions 下标（发送时的 option 索引）
        let correctAnswers = ArrayList<Int32>()
        if (this.isQuiz && this.correctOptionIndex >= 0) {
            var filledPos: Int32 = 0
            var oi: Int64 = 0
            for (opt in this.options) {
                if (opt.size > 0) {
                    if (oi == this.correctOptionIndex) {
                        correctAnswers.add(filledPos)
                    }
                    filledPos += 1
                }
                oi += 1
            }
        }
        let q = this.question
        let anon = this.isAnonymous
        let multi = this.isMultipleChoice
        let quiz = this.isQuiz
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()

        launch { this.isSending = true }

        let _ = spawn {
            try {
                let svc = getComposePollService()
                let result = svc.sendPoll(
                    peerType,
                    peerId,
                    q,
                    filledOptions,
                    anonymous: anon,
                    multipleChoice: multi,
                    quiz: quiz,
                    correctAnswers: correctAnswers
                )
                if (result.success) {
                    Hilog.info(0, "CjTelegram", "[ComposePollScreenComponent] Poll sent msgId=${result.messageId}")
                    launch {
                        this.isSending = false
                        this.onSendSuccess()
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ComposePollScreenComponent] Poll send failed: ${result.errorMessage}")
                    launch {
                        this.isSending = false
                        this.errorMessage = result.errorMessage
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ComposePollScreenComponent] Exception: ${e}")
                launch {
                    this.isSending = false
                    this.errorMessage = "Send failed"
                }
            }
        }
    }

    private func addOption(): Unit {
        if (this.options.size >= 10) { return }
        let newList = ArrayList<String>()
        for (opt in this.options) { newList.add(opt) }
        newList.add("")
        this.options = newList
    }

    private func removeOption(index: Int64): Unit {
        if (this.options.size <= 2) { return }
        let newList = ArrayList<String>()
        var idx: Int64 = 0
        for (opt in this.options) {
            if (idx != index) {
                newList.add(opt)
            }
            idx += 1
        }
        this.options = newList
        // Fix2: 删除选项后维护 quiz 正确答案下标
        if (index == this.correctOptionIndex) {
            this.correctOptionIndex = -1
        } else if (index < this.correctOptionIndex) {
            this.correctOptionIndex = this.correctOptionIndex - 1
        }
    }

    private func updateOption(index: Int64, value: String): Unit {
        let newList = ArrayList<String>()
        var idx: Int64 = 0
        for (opt in this.options) {
            if (idx == index) {
                newList.add(value)
            } else {
                newList.add(opt)
            }
            idx += 1
        }
        this.options = newList
    }

    // ==================== UI 构建 ====================

    public func build() {
        Column {
            // ──── 顶部导航栏 ────
            Row {
                Text(trSource("Cancel"))
                    .fontSize(17)
                    .fontColor(0x007AFF)
                    .onClick({ _e: ClickEvent =>
                        this.onCancel()
                    })
                Blank()
                Text(trSource("New Poll"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                Blank()
                Text(if (this.isSending) { "..." } else { "Create" })
                    .fontSize(17)
                    .fontColor(if (this.canSend() && !this.isSending) { 0x007AFF } else { 0xC7C7CC })
                    .onClick({ _e: ClickEvent =>
                        if (this.canSend() && !this.isSending) {
                            this.doSend()
                        }
                    })
            }
            .width(100.percent)
            .height(if (this.embedded) { 48.0 } else { 48.0 + getSafeAreaTop() })
            .padding(left: 16, right: 16, top: if (this.embedded) { 0.0 } else { getSafeAreaTop() })
            .alignItems(VerticalAlign.Center)
            .backgroundColor(0xF2F2F7)

            Divider().color(0xC8C8CD).strokeWidth(0.5)

            Scroll {
                Column {
                    // ──── QUESTION 区块 ────
                    Text(trSource("QUESTION"))
                        .fontSize(13)
                        .fontColor(0x6D6D72)
                        .margin(left: 16, top: 20, bottom: 6)
                        .width(100.percent)

                    Column {
                        // Stack overlay 模式：用 Stack 包裹 TextInput + 占位文本
                        Stack {
                            TextInput(text: this.question)
                                .height(88)
                                .fontSize(17)
                                .backgroundColor(Color.Transparent)
                                .padding(left: 16, right: 16, top: 12, bottom: 12)
                                .maxLength(255)
                                .onChange({ value: String =>
                                    this.question = value
                                })
                            if (this.question.size == 0) {
                                Text("Ask a question...")
                                    .fontSize(17)
                                    .fontColor(0xC7C7CC)
                                    .padding(left: 20, right: 16, top: 14)
                                    .width(100.percent)
                                    .enabled(false)
                            }
                        }
                        .width(100.percent)
                        .height(88)
                        .alignContent(Alignment.TopStart)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)

                    Text("${this.question.size}/255")
                        .fontSize(12)
                        .fontColor(0xC7C7CC)
                        .margin(left: 16, top: 4, bottom: 16)
                        .width(100.percent)

                    // ──── OPTIONS 区块 ────
                    Text(trSource("OPTIONS"))
                        .fontSize(13)
                        .fontColor(0x6D6D72)
                        .margin(left: 16, bottom: 6)
                        .width(100.percent)

                    Column {
                        ForEach(this.options.toArray(), itemGenerator: { opt: String, idx: Int64 =>
                            Column {
                                Row {
                                    // 选项输入 — Stack overlay 模式
                                    Stack {
                                        TextInput(text: opt)
                                            .layoutWeight(1)
                                            .height(44)
                                            .fontSize(17)
                                            .backgroundColor(Color.Transparent)
                                            .padding(left: 16, right: 8)
                                            .maxLength(100)
                                            .onChange({ value: String =>
                                                this.updateOption(idx, value)
                                            })
                                        if (opt.size == 0) {
                                            Text(if (idx < 2) { "Option ${idx + 1}" } else { "Add option (optional)" })
                                                .fontSize(17)
                                                .fontColor(0xC7C7CC)
                                                .padding(left: 20)
                                                .enabled(false)
                                        }
                                    }
                                    .layoutWeight(1)
                                    .height(44)
                                    .alignContent(Alignment.TopStart)

                                    // Fix2: quiz 模式下每行右侧显示单选圆圈，标记正确答案
                                    if (this.isQuiz) {
                                        Text(if (idx == this.correctOptionIndex) { "●" } else { "○" })
                                            .fontSize(20)
                                            .fontColor(if (idx == this.correctOptionIndex) { 0x34C759 } else { 0xC7C7CC })
                                            .width(32)
                                            .height(44)
                                            .textAlign(TextAlign.Center)
                                            .onClick({ _e: ClickEvent =>
                                                if (this.options[idx].size > 0) {
                                                    this.correctOptionIndex = idx
                                                }
                                            })
                                    }

                                    // 删除按钮（≥3 条时显示）
                                    if (this.options.size > 2) {
                                        Text("✕")
                                            .fontSize(16)
                                            .fontColor(0xC7C7CC)
                                            .width(32)
                                            .height(44)
                                            .textAlign(TextAlign.Center)
                                            .onClick({ _e: ClickEvent =>
                                                this.removeOption(idx)
                                            })
                                    }
                                }
                                .width(100.percent)
                                .alignItems(VerticalAlign.Center)

                                if (idx < this.options.size - 1) {
                                    Divider().color(0xE5E5EA).strokeWidth(0.5).margin(left: 16)
                                }
                            }
                        })

                        // 添加选项行（< 10 条时显示）
                        if (this.options.size < 10) {
                            Divider().color(0xE5E5EA).strokeWidth(0.5).margin(left: 16)
                            Row {
                                Text("+ Add Option")
                                    .fontSize(17)
                                    .fontColor(0x007AFF)
                                    .padding(left: 16)
                            }
                            .width(100.percent)
                            .height(44)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _e: ClickEvent =>
                                this.addOption()
                            })
                        }
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)

                    // ──── SETTINGS 区块 ────
                    Text(trSource("SETTINGS"))
                        .fontSize(13)
                        .fontColor(0x6D6D72)
                        .margin(left: 16, top: 24, bottom: 6)
                        .width(100.percent)

                    Column {
                        // 匿名投票
                        Row {
                            Column {
                                Text(trSource("Anonymous Voting"))
                                    .fontSize(17)
                                    .fontColor(0x000000)
                                Text("Hide the names of voters")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            Toggle(ToggleType.Switch, isOn: this.isAnonymous)
                                .onChange({ isOn: Bool =>
                                    this.isAnonymous = isOn
                                    if (isOn) {
                                        this.isQuiz = false
                                    }
                                })
                        }
                        .width(100.percent)
                        .height(60)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)

                        Divider().color(0xE5E5EA).strokeWidth(0.5).margin(left: 16)

                        // 多选
                        Row {
                            Column {
                                Text("Multiple Answers")
                                    .fontSize(17)
                                    .fontColor(0x000000)
                                Text("Allow voters to select multiple options")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            Toggle(ToggleType.Switch, isOn: this.isMultipleChoice)
                                .onChange({ isOn: Bool =>
                                    this.isMultipleChoice = isOn
                                    if (isOn) {
                                        this.isQuiz = false
                                    }
                                })
                        }
                        .width(100.percent)
                        .height(60)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)

                        Divider().color(0xE5E5EA).strokeWidth(0.5).margin(left: 16)

                        // 测验模式
                        Row {
                            Column {
                                Text(trSource("Quiz Mode"))
                                    .fontSize(17)
                                    .fontColor(0x000000)
                                Text("Only one answer is correct")
                                    .fontSize(13)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 2)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            Toggle(ToggleType.Switch, isOn: this.isQuiz)
                                .onChange({ isOn: Bool =>
                                    this.isQuiz = isOn
                                    if (isOn) {
                                        this.isAnonymous = false
                                        this.isMultipleChoice = false
                                    }
                                })
                        }
                        .width(100.percent)
                        .height(60)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 16, right: 16)

                    // ──── 错误消息 ────
                    if (this.errorMessage.size > 0) {
                        Text(this.errorMessage)
                            .fontSize(13)
                            .fontColor(0xFF3B30)
                            .margin(left: 16, top: 12)
                            .width(100.percent)
                    }

                    // ──── 底部间距 ────
                    Column {}
                        .height(40)
                }
                .width(100.percent)
            }
            .layoutWeight(1)
            .backgroundColor(0xF2F2F7)

            // ──── 发送中遮罩 ────
            if (this.isSending) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                        .color(0x007AFF)
                }
                .width(100.percent)
                .height(80)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0xF2F2F7)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: if (this.embedded) { 0.0 } else { getSafeAreaBottom() })
    }
}
