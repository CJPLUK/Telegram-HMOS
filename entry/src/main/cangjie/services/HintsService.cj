/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.services

import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog

/**
 * HintsService — 首次使用引导提示的持久化标志管理。
 *
 * 对应 iOS Telegram-iOS submodules/TooltipUI TooltipScreen（显示一次后不再显示）。
 * 使用 HarmonyOS Preferences API (telegram_hints store) 存储"已展示"布尔标志。
 *
 * 懒初始化：首次调用 ensureInit() 时从 getGlobalAbilityContext() 拿 context 并
 * 打开 Preferences；若 context 尚未就绪（启动极早期），降级为内存模式（本次运行有效）。
 *
 * 当前管理的 hint key：
 *   KEY_COMPOSE_TOOLTIP_SHOWN  —— "telegram_hints/compose_tooltip_shown"
 *     对应 ChatListPage 顶栏 ✏️ Compose 按钮的首次引导气泡（告知用户可通过此按钮
 *     发起新消息/群组/频道，对照 iOS TooltipUI 的"功能引导指向性气泡"场景）。
 */

// Hint key 常量
let KEY_COMPOSE_TOOLTIP_SHOWN: String = "compose_tooltip_shown"

private var _hintsServiceInstance: Option<HintsService> = None

public func getHintsService(): HintsService {
    match (_hintsServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = HintsService()
            _hintsServiceInstance = Some(svc)
            return svc
    }
}

public class HintsService {
    private var preferences: Option<Preferences> = None
    private var initialized: Bool = false

    // 内存降级缓存（Preferences 初始化失败时使用）
    private var memComposeTooltipShown: Bool = false

    /**
     * 懒初始化 Preferences（从 getGlobalAbilityContext()）。
     * 在第一次读写前调用；若 context 未就绪则静默降级为内存模式。
     */
    public func ensureInit(): Unit {
        if (this.initialized) {
            return
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, "telegram_hints")
                    this.preferences = Some(prefs)
                    Hilog.info(0, "CjTelegram", "[HintsService] Initialized with Preferences")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[HintsService] Preferences init failed, memory mode: ${e}")
                }
                this.initialized = true
            case None =>
                Hilog.info(0, "CjTelegram", "[HintsService] Context not ready yet, memory mode")
                this.initialized = true
        }
    }

    /**
     * 检查 Compose 引导 Tooltip 是否已展示过（F2 首次使用引导）。
     * 未展示过返回 false，调用方应弹出 tooltip 并随后调用 markComposeTooltipShown()。
     */
    public func hasShownComposeTooltip(): Bool {
        this.ensureInit()
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(KEY_COMPOSE_TOOLTIP_SHOWN, PreferencesValueType.BoolData(false))
                    match (val) {
                        case PreferencesValueType.BoolData(b) => return b
                        case _ => return false
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[HintsService] hasShownComposeTooltip error: ${e}")
                    return false
                }
            case None => return this.memComposeTooltipShown
        }
    }

    /**
     * 标记 Compose 引导 Tooltip 已展示（持久化写入，重启后不再弹出）。
     */
    public func markComposeTooltipShown(): Unit {
        this.ensureInit()
        this.memComposeTooltipShown = true
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(KEY_COMPOSE_TOOLTIP_SHOWN, PreferencesValueType.BoolData(true))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[HintsService] markComposeTooltipShown persisted")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[HintsService] markComposeTooltipShown error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[HintsService] Preferences not ready, mark in memory only")
        }
    }
}
