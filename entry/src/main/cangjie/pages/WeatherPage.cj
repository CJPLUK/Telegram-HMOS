package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.WeatherData
import ohos_app_cangjie_entry.services.{getWeatherBotService, ensureLocationPermission, getCurrentDeviceLocation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * WeatherPage — 天气数据展示页 (P2-404)（混合工程迁移版）
 *
 * iOS 对应: Telegram iOS 内置 weather bot inline query 结果展示。
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（含 .title/.hideTitleBar），只留内容 + 末尾 .onAppear
 *  - aboutToAppear 有实逻辑（loadWeather）→ ensureLoaded()（.onAppear 触发）
 */
@HybridComponentEntry
@Component
public class WeatherPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = true
    @State var errorMessage: String = ""
    @State var weather: WeatherData = WeatherData()

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadWeather()
    }

    private func loadWeather(): Unit {
        this.isLoading = true
        this.errorMessage = ""
        ensureLocationPermission({ granted: Bool =>
            if (!granted) {
                launch {
                    this.isLoading = false
                    this.errorMessage = "Location permission required for weather"
                }
                return
            }
            spawn {
                let locResult = getCurrentDeviceLocation()
                if (!locResult.success) {
                    launch {
                        this.isLoading = false
                        this.errorMessage = "Could not get location: " + locResult.errorMessage
                    }
                    return
                }
                let lat = locResult.latitude
                let lng = locResult.longitude
                Hilog.info(0, "CjTelegram", "[WeatherPage] GPS lat=${lat} lng=${lng}")
                let svc = getWeatherBotService()
                let data = svc.queryWeather(lat, lng)
                launch {
                    this.isLoading = false
                    if (data.isValid) {
                        this.weather = data
                    } else {
                        this.errorMessage = "Weather data unavailable"
                    }
                }
            }
        })
    }

    private func tempDisplay(): String {
        if (this.weather.tempString.size > 0) {
            return this.weather.tempString
        }
        return "--"
    }

    private func emojiDisplay(): String {
        if (this.weather.weatherEmoji.size > 0) {
            return this.weather.weatherEmoji
        }
        return "🌤"
    }

    public func build() {
        Column {
            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(48)
                        .height(48)
                        .color(0x317AFF)
                    Text("Getting weather...")
                        .fontSize(16)
                        .fontColor(0x8E8E93)
                        .margin(top: 12)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.errorMessage.size > 0) {
                Column {
                    Text("⚠")
                        .fontSize(48)
                    Text(this.errorMessage)
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .padding(left: 32, right: 32, top: 12)
                    Button(trSource("Retry"))
                        .width(120)
                        .height(40)
                        .margin(top: 24)
                        .backgroundColor(0x317AFF)
                        .fontColor(0xFFFFFF)
                        .borderRadius(8)
                        .onClick({ _ =>
                            this.loadWeather()
                        })
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll {
                    Column {
                        Text(this.emojiDisplay())
                            .fontSize(72)
                            .margin(top: 32, bottom: 8)

                        Text(this.tempDisplay())
                            .fontSize(56)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0x000000)

                        if (this.weather.description_.size > 0) {
                            Text(this.weather.description_)
                                .fontSize(20)
                                .fontColor(0x8E8E93)
                                .margin(top: 4)
                        }

                        if (this.weather.location.size > 0) {
                            Text(this.weather.location)
                                .fontSize(16)
                                .fontColor(0x8E8E93)
                                .margin(top: 8, bottom: 24)
                        }

                        Column {
                            if (this.weather.humidity.size > 0) {
                                Row {
                                    Text("💧")
                                        .fontSize(18)
                                        .width(32)
                                    Text(this.weather.humidity)
                                        .fontSize(15)
                                        .fontColor(0x333333)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16)
                                .alignItems(VerticalAlign.Center)
                            }
                            if (this.weather.wind.size > 0) {
                                Row {
                                    Text("💨")
                                        .fontSize(18)
                                        .width(32)
                                    Text(this.weather.wind)
                                        .fontSize(15)
                                        .fontColor(0x333333)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16)
                                .alignItems(VerticalAlign.Center)
                            }
                            if (this.weather.sunrise.size > 0) {
                                Row {
                                    Text("🌅")
                                        .fontSize(18)
                                        .width(32)
                                    Text(this.weather.sunrise)
                                        .fontSize(15)
                                        .fontColor(0x333333)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16)
                                .alignItems(VerticalAlign.Center)
                            }
                            if (this.weather.sunset.size > 0) {
                                Row {
                                    Text("🌇")
                                        .fontSize(18)
                                        .width(32)
                                    Text(this.weather.sunset)
                                        .fontSize(15)
                                        .fontColor(0x333333)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16)
                                .alignItems(VerticalAlign.Center)
                            }
                            if (this.weather.moonPhase.size > 0) {
                                Row {
                                    Text("🌙")
                                        .fontSize(18)
                                        .width(32)
                                    Text(this.weather.moonPhase)
                                        .fontSize(15)
                                        .fontColor(0x333333)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16)
                                .alignItems(VerticalAlign.Center)
                            }
                        }
                        .width(100.percent)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 8)

                        Button("Refresh")
                            .width(120)
                            .height(40)
                            .margin(top: 24, bottom: 32)
                            .backgroundColor(0x317AFF)
                            .fontColor(0xFFFFFF)
                            .borderRadius(8)
                            .onClick({ _ =>
                                this.loadWeather()
                            })
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                }
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
