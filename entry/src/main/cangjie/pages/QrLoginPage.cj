/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.router.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * QR 码登录页面（混合工程迁移版）
 *
 * 显示 QR 码供另一设备扫描登录（auth.exportLoginToken）
 * - 自动刷新 token（expires_in 前）
 * - 轮询检测扫码成功
 * - 成功后设置 AuthViewModel.isLoggedIn = true（原 @Consume isLoggedIn 的语义）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（pageStack.pop() → routerPop()）
 *  - 去掉 @Consume isLoggedIn（LIVE consume → getAuthViewModel().isLoggedIn = true）
 *  - aboutToAppear(startQrFlow) → ensureLoaded() + .onAppear
 *  - aboutToDisappear(停止轮询) → cleanup() + .onDisAppear
 */
@HybridComponentEntry
@Component
public class QrLoginPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var qrContent: String = ""
    @State var isLoading: Bool = true
    @State var errorMessage: String = ""
    @State var loaded: Bool = false

    private var refreshTimerId: Int64 = 0
    private var pollSpawnRunning: Bool = true

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.startQrFlow()
    }

    private func cleanup(): Unit {
        this.pollSpawnRunning = false
    }

    private func startQrFlow(): Unit {
        // 门禁（诊断报告 diag-session-loss-investigation.md R-1）：登录转移导出
        // （auth.exportLoginToken）只允许在未授权态发起。若已授权（当前设备已登录），
        // 服务端会对该请求回 401，被全局拦截器当作"会话失效"抹除本机全部登录凭据
        // （AuthStorage.clearAll()）。源侧 AuthTransfer.swift 用 UnauthorizedAccount
        // 类型把这条不变式钉死在编译期；仓颉侧无等价类型约束，这里用运行期前置判定
        // 复刻同一不变式：已授权时不发任何网络请求，直接退出该页。
        let alreadyAuthorized = match (getRealAuthService().getState()) {
            case RealAuthState.Authorized => true
            case _ => false
        }
        if (alreadyAuthorized) {
            Hilog.warn(0, "CjTelegram", "[QrLoginPage] blocked exportLoginToken: session already authorized, exiting QR login transfer page")
            this.isLoading = false
            routerPop()
            return
        }
        this.isLoading = true
        this.errorMessage = ""
        this.qrContent = ""
        this.pollSpawnRunning = true
        getAuthViewModel().ensureCallbackRegistered()
        spawn {
            this.doExportAndPoll()
        }
    }

    private func doExportAndPoll(): Unit {
        let authService = getRealAuthService()
        let exceptIds = ArrayList<Int64>()
        var resp = authService.exportLoginToken(exceptIds)

        while (this.pollSpawnRunning) {
            match (resp.kind) {
                case "token" =>
                    let content = "tg://login?token=" + Base64.encodeBase64Url(resp.token)
                    let expires = resp.expires
                    launch {
                        this.qrContent = content
                        this.isLoading = false
                        this.errorMessage = ""
                    }
                    if (expires > 10) {
                        sleep(Duration.second * Int64(expires - 10))
                        if (!this.pollSpawnRunning) { break }
                        resp = authService.exportLoginToken(exceptIds)
                    } else {
                        sleep(Duration.second * 2)
                        if (!this.pollSpawnRunning) { break }
                        resp = authService.exportLoginToken(exceptIds)
                    }
                case "migrateTo" =>
                    let _ = authService.importLoginToken(resp.token)
                    sleep(Duration.millisecond * 500)
                    if (!this.pollSpawnRunning) { break }
                    resp = authService.exportLoginToken(exceptIds)
                case "success" =>
                    match (resp.authorization) {
                        case Some(user) =>
                            authService.completeQrLogin(user)
                            launch {
                                getAuthViewModel().isLoggedIn = true
                                routerReplace("MainTabPage", "{}")
                            }
                            return
                        case None => ()
                    }
                    sleep(Duration.second * 2)
                    if (!this.pollSpawnRunning) { break }
                    resp = authService.exportLoginToken(exceptIds)
                case _ =>
                    launch {
                        this.errorMessage = "无法获取登录二维码"
                        this.isLoading = false
                    }
                    return
            }
        }
    }

    func build() {
        Column {
            Text(trSource("Log in by QR Code"))
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .margin(top: 40, bottom: 16)

            Text("Open Telegram on your phone → Settings → Devices → Scan QR")
                .fontSize(14)
                .fontColor(0x666666)
                .margin(bottom: 32)
                .padding(left: 24, right: 24)
                .textAlign(TextAlign.Center)

            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(48)
                        .height(48)
                        .color(0x317AFF)
                    Text("Generating QR code...")
                        .fontSize(14)
                        .fontColor(0x999999)
                        .margin(top: 16)
                }
                .width(200)
                .height(120)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .margin(bottom: 24)
            } else if (this.qrContent.size > 0) {
                Column {
                    QrCodeView(content: this.qrContent, size: 200, showCenterLogo: true)
                }
                .margin(bottom: 24)
            }

            if (this.errorMessage.size > 0) {
                Text(this.errorMessage)
                    .fontSize(14)
                    .fontColor(0xFF3B30)
                    .margin(bottom: 16)
                    .padding(left: 24, right: 24)
            }

            Button(trSource("Back"))
                .width(200)
                .height(44)
                .margin(top: 24)
                .borderRadius(22)
                .backgroundColor(0xF0F0F0)
                .fontColor(0x333333)
                .fontSize(15)
                .onClick({ evt =>
                    this.pollSpawnRunning = false
                    routerPop()
                })
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFFFFF)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .alignItems(HorizontalAlign.Center)
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })
    }
}
