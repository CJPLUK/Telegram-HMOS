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

/**
 * ArchiveInfoContent — 归档说明内容块。
 *
 * iOS ref: submodules/TelegramUI/Components/Settings/ArchiveInfoScreen/Sources/
 *   ArchiveInfoContentComponent.swift:12-333 `ArchiveInfoContentComponent.View.update(component:availableSize:)`
 * 排版常量对位同文件 :106-313：sideInset=16、渐变圆 90（顶 0x2a9ef1 → 底 0x72d5fd）、
 *   +15 → 标题(semibold 19 单行居中) → +16 → 正文(regular 15 居中) → +24 → 三条目，
 *   条目间距 24，图标 x=16、文字块 x=56，条目标题 semibold 15 + 正文 regular 15，标题正文间距 2。
 * 文案原文：Telegram/Telegram-iOS/en.lproj/Localizable.strings:9578-9589。
 *
 * 点击边界（对位 :203-208 `tapAction`）：`onOpenSettings` 挂在**整块正文段落**上，
 * 源侧 tapAction 无 URL 判定，正文任意字符命中即回调——不照抄 AccountFreezeInfoScreen 的
 * 带判定写法。
 *
 * 资源缺口自检（diag-suite_settings_root-TC-0091.md round-3 M-2 已把 archive_ic_large /
 * archive_ic_chats / archive_ic_hide / archive_ic_stories / settings_ic_text_arrow_right
 * 五项资源扩入 allowlist 并转换落地，本轮全部换回真实资源；此段仅保留一条本轮未修的
 * 已知版式偏差）：
 *   - `settings_ic_text_arrow_right`(正文内嵌箭头，源 TextArrowRight.imageset/chevron.right.svg)：
 *     本项目 ArkUI-Cangjie 绑定内未见 ImageSpan（行内图文混排）先例可依，放在正文段落尾部
 *     独立一行展示，而非严格行内嵌入——与源侧"箭头紧跟在文字后"存在轻微版式偏差（M-2 边界
 *     条件明确本轮不修，不使用 Unicode 字形 "›"/">" 代替）。
 *
 * FontWeight 缺口：本项目 FontWeight 枚举无 Semibold（只有 Regular/Medium/Bold/Lighter/Normal），
 *   标题与条目标题的 semibold 19/15 用 FontWeight.Medium 近似代替。
 */
@Component
public class ArchiveInfoContent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var keepArchivedUnmuted: Bool = true
    public var onOpenSettings: () -> Unit = { => }

    private func bodyText(): String {
        if (this.keepArchivedUnmuted) {
            return "Archived chats will remain in the Archive when you receive a new message."
        }
        return "When you receive a new message, muted chats will remain in the Archive, while unmuted chats will be moved to Chats."
    }

    public func build() {
        Column {
            // 90x90 渐变圆：顶 0x2a9ef1 → 底 0x72d5fd（ArchiveInfoContentComponent.swift:111-118
            // + DefaultDayPresentationTheme.swift:572 pinnedArchiveAvatarColor 反转 + GenerateImage
            // .vertical 从 (0,0) 到 (0,h)）
            Column {
                Image(@r(app.media.archive_ic_large))
                    .width(40)
                    .height(40)
                    .fillColor(0xFFFFFF)
            }
            .width(90)
            .height(90)
            .borderRadius(45)
            .linearGradient(angle: 180.0, colors: [(Color(0xFF2A9EF1), 0.0), (Color(0xFF72D5FD), 1.0)])
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            // 标题：This is Your Archive — semibold 19，居中，单行
            Text(trSource("This is Your Archive"))
                .fontSize(19)
                .fontWeight(FontWeight.Medium)
                .fontColor(0x000000)
                .textAlign(TextAlign.Center)
                .maxLines(1)
                .width(100.percent)
                .margin(top: 15)

            // 正文：二态文案，尾部 "Tap to change" 蓝色可点段（accent = 0x317AFF）
            Column {
                Text() {
                    Span("${this.bodyText()} ")
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                    Span("Tap to change")
                        .fontSize(15)
                        .fontColor(0x317AFF)
                }
                .textAlign(TextAlign.Center)
                .lineHeight(21)
                .width(100.percent)

                Image(@r(app.media.settings_ic_text_arrow_right))
                    .width(7)
                    .height(12)
                    .fillColor(0x317AFF)
                    .margin(top: 4)
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Center)
            .margin(top: 16)
            .onClick({ _evt => this.onOpenSettings() })

            // 三条目：Archived Chats / Hiding Archive / Stories（顺序固定）
            Column {
                Row {
                    Column {
                        Image(@r(app.media.archive_ic_chats))
                            .width(20)
                            .height(20)
                            .fillColor(0x317AFF)
                    }
                    .width(40)
                    .alignItems(HorizontalAlign.Start)

                    Column {
                        Text(trSource("Archived Chats"))
                            .fontSize(15)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                        Text(trSource("Move any chat into your Archive and back by swiping on it."))
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .margin(top: 2)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                }
                .width(100.percent)
                .alignItems(VerticalAlign.Top)

                Row {
                    Column {
                        Image(@r(app.media.archive_ic_hide))
                            .width(20)
                            .height(20)
                            .fillColor(0x317AFF)
                    }
                    .width(40)
                    .alignItems(HorizontalAlign.Start)

                    Column {
                        Text(trSource("Hiding Archive"))
                            .fontSize(15)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                        Text(trSource("Hide the Archive from your Main screen by swiping on it."))
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .margin(top: 2)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                }
                .width(100.percent)
                .alignItems(VerticalAlign.Top)
                .margin(top: 24)

                Row {
                    Column {
                        Image(@r(app.media.archive_ic_stories))
                            .width(20)
                            .height(20)
                            .fillColor(0x317AFF)
                    }
                    .width(40)
                    .alignItems(HorizontalAlign.Start)

                    Column {
                        Text(trSource("Stories"))
                            .fontSize(15)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                        Text(trSource("Archive Stories from your contacts separately from chats with them."))
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .margin(top: 2)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                }
                .width(100.percent)
                .alignItems(VerticalAlign.Top)
                .margin(top: 24)
            }
            .width(100.percent)
            .margin(top: 24)
        }
        .width(100.percent)
        .padding(left: 16, right: 16)
    }
}
