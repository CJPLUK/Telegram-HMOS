/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog

/**
 * AgeVerificationSheet — 年龄验证确认层的共享 sheet 组件。
 *
 * iOS ref: submodules/TelegramUI/Components/FaceScanScreen/Sources/AgeVerificationScreen.swift:72-213
 *   `SheetContent.body`（圆角图标块 90×90 + 标题 + markdown 正文 + 主按钮 + 左上关闭 X）。
 * 源侧是「一个共享入口函数 presentAgeVerification() + 一块共享 sheet」的单一路径，被
 * DataAndStorageSettingsController.swift:899-900 等 4 个调用点共用（diag-suite_settings_
 * data_storage-round5-data_storage_root-batch.md §I-4「结构性判定」）——本文件即该共享 sheet
 * 内容，命名在 components/ 下而非任一页面私有，供其余三个调用点将来直接复用。
 *
 * 本轮交付边界（同报告 §I-4 通则）：只交付 sheet 本体与退出语义，不交付摄像头/CoreML 扫脸
 * （FaceScanScreen / AgeNet / AgeNetLegacy / FrameView，TC-0422 D1 维持
 * blocked(device_required)）。三条路径（关闭 X / 下滑关闭 / 点 Verify My Age）均不得写远端——
 * 写远端只发生在源侧 DataAndStorageSettingsController.swift 的 S8（"18+ Content" 确认 Alert）
 * 支里，与本 sheet 无关；本文件不得出现任何写敏感内容配置的远端调用。
 *
 * 资源缺口（review.issues 已登记）：源侧 `Settings/FaceVerification`（BundleIconComponent 名）
 * 在 resources/base/media/ 内无对应资源，改用仓内已有等义图标 `privacy_ic_faceid.png`
 * （@r(app.media.privacy_ic_faceid)，先例 pages/PrivacySettingsPage.cj:1031）承载；未新建资源、
 * 未引入转换管线。
 *
 * 本轮明确不做（review.issues 已登记）：正文 "**18**" 的 markdown 加粗（目标侧无 markdown 富
 * 文本通道）与 verify_age_country 国家变体（源侧 :156-161，Localizable.strings:14775
 * "AgeVerification.Text.GB" 等，取决于 app config 的 verify_age_country）——固定展示英文默认
 * 文案 AgeVerification.Text（:14774），不做国家判定。
 *
 * 主按钮点击行为（review.issues 已登记，已裁定边界，非 Worker 取舍）：本轮固定为「关闭 sheet +
 * 不写远端 + 打一条 Hilog.info」，对位源侧摄像头授权未通过时的兜底路径（:336-357 之后的
 * FaceScanScreen / mini-app 分支本轮不做）。
 */

/** 纯数据类：sheet 内容与宿主页之间唯一的耦合面——一个"关闭"回调，三条退出路径共用。 */
public class AgeVerificationSheetActions {
    public let onDismiss: () -> Unit

    public init(onDismiss: () -> Unit) {
        this.onDismiss = onDismiss
    }
}

/**
 * ageVerificationSheetContent — sheet 内容 @Builder，逐项自上而下对位源侧
 * AgeVerificationScreen.swift:72-213（关闭 X / 图标 / 标题 / 正文 / 主按钮 五项）。
 * 形状照抄同仓已验证的贴底 sheet 内容 builder 先例 pages/DataPrivacySettingsPage.cj
 * `buildPaymentsSheet` / `buildDraftsSheet`（Column 顶层容器 + 卡片式内容）；因需跨文件
 * 共享给宿主页调用，提升为顶层 @Builder 函数（先例 components/ContextMenu.cj:236-238
 * `buildContextMenuItems`）。
 *
 * 退出语义（对位源侧 :255-263 / :284-296）：关闭 X 与主按钮都只调用 `actions.onDismiss()`，
 * 不做任何远端写入、不做任何提示；下滑关闭走宿主 `.bindSheet` 的 `onDisappear`（该回调也只
 * 负责把宿主页 @State 置回 false，同样不写远端）——三条路径合起来对应源侧「未验证即静默保持
 * 关」的行为。
 */
@Builder
public func ageVerificationSheetContent(actions: AgeVerificationSheetActions): Unit {
    Column {
        // 左上 44×44 关闭 X（源侧 GlassBarButtonComponent + "Navigation/Close"，:109-130）。
        // 图标资源与先例 pages/CountrySelectionPage.cj:282-285 相同（nav_ic_close.svg，
        // 19.8×17.1vp，已用 PyMuPDF 从源 PDF 精确提取）。
        Row {
            Column {
                Image(@r(app.media.nav_ic_close))
                    .width(19.8)
                    .height(17.1)
                    .fillColor(0x000000)
            }
            .width(44)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .onClick({ _ => actions.onDismiss() })

            Blank()
        }
        .width(100.percent)
        .padding(left: 8, top: 8)

        // 90×90 圆角图标块（源侧 RoundedRectangle(cornerRadius: 45, size: 90×90) 填充
        // theme.list.itemCheckColors.fillColor + BundleIconComponent 白色前景，:88-104）。
        Column {
            Image(@r(app.media.privacy_ic_faceid))
                .width(40)
                .height(40)
                .fillColor(0xFFFFFF)
        }
        .width(90)
        .height(90)
        .borderRadius(45)
        .backgroundColor(ITEM_LIST_ACCENT)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .margin(top: 4)

        // 标题：Age Verification（Localizable.strings:14773），fontSize(24) + Bold，居中
        // （源侧 Font.bold(24.0)，:136-137）。
        Text(trSource("Age Verification"))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(0x000000)
            .textAlign(TextAlign.Center)
            .width(100.percent)
            .margin(top: 15)

        // 正文（Localizable.strings:14774），fontSize(15)、居中、maxLines 不限（源侧
        // BalancedTextComponent maximumNumberOfLines: 0，:163-172）。markdown "**18**" 加粗
        // 与国家变体本轮不做（见文件头 review.issues 说明）。
        Text("To access this content, you must confirm you are at least 18 years old.\n\nThis is a one-time process using your phone's camera. Your selfie will not be stored by Telegram.")
            .fontSize(15)
            .fontColor(0x000000)
            .textAlign(TextAlign.Center)
            .width(100.percent)
            .padding(left: 24, right: 24)
            .margin(top: 13)

        // 主按钮：Verify My Age（Localizable.strings:14776），height(52) + borderRadius(10)，
        // 填充 ITEM_LIST_ACCENT、前景白（源侧 ButtonComponent.Background style: .glass, color:
        // theme.list.itemCheckColors.fillColor, cornerRadius: 10, :185-206）。点击行为本轮固定
        // 为关闭 + 打日志，不做摄像头授权（见文件头说明）。
        // D-165：水平内缩必须由外包容器的 padding 承载，不能叠在按钮自身的 width(100%)+margin
        // 上——否则在默认居中的父 Column 下会摞出 父宽+24+24 的溢出盒，被居中对齐抵消成可见
        // 左右缘=0（贴边满宽），丢失源侧 sideInset: 30.0 的内缩语义。先例
        // pages/DevicesPage.cj:1174-1175（外包 Column + width(100%) + padding(left/right)）。
        // 纵向 top/bottom 分量继续留在按钮本体的 .margin(...) 上（D-165 明确两者可并存）。
        Column {
            Button(trSource("Verify My Age"))
                .width(100.percent)
                .height(52)
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(0xFFFFFF)
                .backgroundColor(ITEM_LIST_ACCENT)
                .borderRadius(10)
                .margin(top: 23, bottom: 24)
                .onClick({ _ =>
                    Hilog.info(0, "CjTelegram",
                        "[AgeVerificationSheet] Verify My Age tapped -- camera capture not implemented this round, dismissing")
                    actions.onDismiss()
                })
        }
        .width(100.percent)
        .padding(left: 24, right: 24)
    }
    .width(100.percent)
    .backgroundColor(0xFFFFFF)
}
