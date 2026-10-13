package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings, PresentationSnapshot, currentPresentation}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.math.floor
import std.sort.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.TransportUsageCategory
import ohos_app_cangjie_entry.components.{
    SegmentedControl,
    ItemListSectionHeader,
    ItemListDisclosureRow
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.utils.{formatFullDate, formatClockHHMM}

/**
 * Immutable view projection of one network-usage category.
 */
class UsageDisplayRow {
    let category: TransportUsageCategory
    let title: String
    let color: UInt32
    let incoming: Int64
    let outgoing: Int64
    let total: Int64

    init(
        category: TransportUsageCategory,
        title: String,
        color: UInt32,
        incoming: Int64,
        outgoing: Int64
    ) {
        this.category = category
        this.title = title
        this.color = color
        this.incoming = incoming
        this.outgoing = outgoing
        this.total = incoming + outgoing
    }
}

/**
 * Data Usage screen matching the source category matrix:
 * 8 categories × wifi/cellular × incoming/outgoing.
 */
@HybridComponentEntry
@Component
public class DataUsagePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var loaded: Bool = false
    @State var selectedSegment: Int64 = 0 // 0 All, 1 Mobile, 2 Wifi
    @State var matrix: Array<Int64> = Array<Int64>(32, repeat: 0)
    // Ephemeral UI-only expansion state. It is intentionally never persisted.
    @State var expandedMask: Int64 = 0
    @State var isResetting: Bool = false
    @State var sectionTitleLabel: String = "TOTAL NETWORK USAGE"
    @State var selectedSentLabel: Int64 = 0
    @State var selectedReceivedLabel: Int64 = 0
    @State var wifiResetTimestamp: Int64 = 0
    @State var cellularResetTimestamp: Int64 = 0
    @State var usageSinceLabel: String = ""

    private var chartCtx: CanvasRenderingContext2D =
        CanvasRenderingContext2D(RenderingContextSettings(antialias: true))

    private func matrixIndex(category: TransportUsageCategory, connectionOffset: Int64, directionOffset: Int64): Int64 {
        return Int64(category.ordinal()) * 4 + connectionOffset + directionOffset
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        let svc = getNetworkUsageService()
        let _ = spawn {
            svc.ensureInit()
            let snap = svc.getUsage()
            let loadedMatrix = Array<Int64>(32, repeat: 0)
            for (entry in snap.categories) {
                let base = Int64(entry.category.ordinal()) * 4
                loadedMatrix[base] = entry.wifiIncoming
                loadedMatrix[base + 1] = entry.wifiOutgoing
                loadedMatrix[base + 2] = entry.cellularIncoming
                loadedMatrix[base + 3] = entry.cellularOutgoing
            }
            launch {
                this.matrix = loadedMatrix
                this.wifiResetTimestamp = snap.wifiResetTimestamp
                this.cellularResetTimestamp = snap.cellularResetTimestamp
                this.loaded = true
                this.refreshProjection()
                this.drawPieChart()
            }
        }
    }

    private func categoryTitle(category: TransportUsageCategory): String {
        match (category) {
            case Generic => "Messages"
            case Image => "Photos"
            case Video => "Videos"
            case Audio => "Music"
            case File => "Files"
            case Call => "Calls"
            case Stickers => "Stickers"
            case VoiceMessages => "Voice Messages"
        }
    }

    private func categoryColor(category: TransportUsageCategory): UInt32 {
        match (category) {
            case Generic => 0xFF5856D6
            case Image => 0xFF5AC8FA
            case Video => 0xFF0088FF
            case Audio => 0xFFFF2D55
            case File => 0xFF34C759
            case Call => 0xFFFF9500
            case Stickers => 0xFFFFB340
            case VoiceMessages => 0xFFAF52DE
        }
    }

    private func categoryIcon(category: TransportUsageCategory): AppResource {
        match (category) {
            case Image => @r(app.media.settings_ic_photo)
            case Video => @r(app.media.media_ic_attach_video)
            case File => @r(app.media.media_ic_attach_file)
            case Audio => @r(app.media.media_ic_play)
            case Stickers => @r(app.media.chatroom_ic_stickers)
            case VoiceMessages => @r(app.media.media_ic_mic)
            case Generic => @r(app.media.set2_ic_chatbubble)
            case Call => @r(app.media.callui_ic_phone)
        }
    }

    private func allCategories(): Array<TransportUsageCategory> {
        return [
            TransportUsageCategory.Image,
            TransportUsageCategory.Video,
            TransportUsageCategory.File,
            TransportUsageCategory.Audio,
            TransportUsageCategory.Stickers,
            TransportUsageCategory.VoiceMessages,
            TransportUsageCategory.Generic,
            TransportUsageCategory.Call
        ]
    }

    /**
     * Segment projection from the single matrix. All is exactly wifi+cellular.
     */
    private func projectedPair(category: TransportUsageCategory): (Int64, Int64) {
        let base = Int64(category.ordinal()) * 4
        if (this.selectedSegment == 1) {
            return (this.matrix[base + 2], this.matrix[base + 3])
        }
        if (this.selectedSegment == 2) {
            return (this.matrix[base], this.matrix[base + 1])
        }
        return (
            this.matrix[base] + this.matrix[base + 2],
            this.matrix[base + 1] + this.matrix[base + 3]
        )
    }

    /**
     * Full eight-row list sorted by size descending, then display title.
     * Zero rows stay in the result.
     */
    private func sortedRows(): ArrayList<UsageDisplayRow> {
        let rows = ArrayList<UsageDisplayRow>()
        for (category in this.allCategories()) {
            let (incoming, outgoing) = this.projectedPair(category)
            rows.add(UsageDisplayRow(
                category,
                this.categoryTitle(category),
                this.categoryColor(category),
                incoming,
                outgoing
            ))
        }
        sort<UsageDisplayRow>(
            rows,
            lessThan: { left: UsageDisplayRow, right: UsageDisplayRow =>
                if (left.total != right.total) {
                    return left.total > right.total
                }
                return left.title < right.title
            },
            stable: true
        )
        return rows
    }

    private func selectedIncoming(): Int64 {
        var result: Int64 = 0
        for (category in this.allCategories()) {
            let (incoming, _) = this.projectedPair(category)
            result += incoming
        }
        return result
    }

    private func selectedOutgoing(): Int64 {
        var result: Int64 = 0
        for (category in this.allCategories()) {
            let (_, outgoing) = this.projectedPair(category)
            result += outgoing
        }
        return result
    }

    private func selectedTotal(): Int64 {
        return this.selectedIncoming() + this.selectedOutgoing()
    }

    private func refreshProjection(): Unit {
        if (this.selectedSegment == 1) {
            this.sectionTitleLabel = "MOBILE NETWORK USAGE"
        } else if (this.selectedSegment == 2) {
            this.sectionTitleLabel = "WI-FI NETWORK USAGE"
        } else {
            this.sectionTitleLabel = "TOTAL NETWORK USAGE"
        }
        this.selectedSentLabel = this.selectedOutgoing()
        this.selectedReceivedLabel = this.selectedIncoming()
        var timestamp = this.cellularResetTimestamp
        if (this.selectedSegment == 2) {
            timestamp = this.wifiResetTimestamp
        } else if (this.selectedSegment == 0) {
            if (this.wifiResetTimestamp > 0 && this.cellularResetTimestamp > 0) {
                timestamp = if (this.wifiResetTimestamp < this.cellularResetTimestamp) {
                    this.wifiResetTimestamp
                } else {
                    this.cellularResetTimestamp
                }
            } else if (this.wifiResetTimestamp > 0) {
                timestamp = this.wifiResetTimestamp
            }
        }
        this.usageSinceLabel = if (timestamp > 0) {
            "Your data usage since ${formatFullDate(timestamp)} at ${formatClockHHMM(timestamp)}"
        } else {
            ""
        }
    }

    private func onSegmentChange(idx: Int64): Unit {
        this.selectedSegment = idx
        this.refreshProjection()
        this.drawPieChart()
    }

    private func isExpanded(category: TransportUsageCategory): Bool {
        let bit: Int64 = 1 << Int64(category.ordinal())
        return (this.expandedMask & bit) != 0
    }

    private func toggleExpanded(category: TransportUsageCategory, total: Int64): Unit {
        if (total <= 0) { return }
        let bit: Int64 = 1 << Int64(category.ordinal())
        if ((this.expandedMask & bit) != 0) {
            this.expandedMask = this.expandedMask ^ bit
        } else {
            this.expandedMask = this.expandedMask | bit
        }
    }

    private func formatBytes(bytes: Int64): String {
        if (bytes <= 0) { return "0 B" }
        if (bytes < 1024) { return "${bytes} B" }
        if (bytes < 1024 * 1024) { return "${bytes / 1024} KB" }
        if (bytes < 1024 * 1024 * 1024) { return "${bytes / (1024 * 1024)} MB" }
        return "${bytes / (1024 * 1024 * 1024)} GB"
    }

    private func percentage(bytes: Int64): String {
        let total = this.selectedTotal()
        if (bytes <= 0 || total <= 0) { return "" }
        let value = Float64(bytes) * 100.0 / Float64(total)
        if (value < 0.1) { return "<0.1%" }
        let tenths = Int64(floor(value * 10.0))
        let whole = tenths / 10
        let decimal = tenths % 10
        if (decimal == 0) { return "${whole}%" }
        return "${whole}.${decimal}%"
    }

    private func contentTitle(): String {
        if (this.selectedTotal() == 0) { return "No data used" }
        return "Data Usage"
    }

    private func resetLabel(): String {
        if (this.isResetting) { return "Resetting..." }
        return "Reset Statistics"
    }

    private func resetColor(): UInt32 {
        if (this.isResetting) { return this.presentation.secondaryTextColor }
        return 0xFFFF3B30
    }

    private func doReset(): Unit {
        if (this.isResetting) { return }
        this.isResetting = true
        let svc = getNetworkUsageService()
        let _ = spawn {
            svc.reset()
            launch {
                this.matrix = Array<Int64>(32, repeat: 0)
                this.expandedMask = 0
                this.isResetting = false
                this.refreshProjection()
                this.drawPieChart()
            }
        }
        Hilog.info(0, "CjTelegram", "[DataUsage] reset complete matrix requested")
    }

    private func confirmReset(): Unit {
        if (this.isResetting) { return }
        let resetSheet = SheetInfo(title: "Reset Statistics", action: { => this.doReset() })
        let cancelButton = ActionSheetButtonOptions(value: "Cancel", action: { => () })
        getUIContext().showActionSheet(ActionSheetOptions(
            title: None,
            message: None,
            confirm: cancelButton,
            sheets: [resetSheet],
            autoCancel: true
        ))
    }

    /**
     * Category pie; every slice and the centered total come from sortedRows().
     */
    private func drawPieChart(): Unit {
        let cx: Float64 = 110.0
        let cy: Float64 = 110.0
        let radius: Float64 = 50.4
        this.chartCtx.fillStyle = this.presentation.backgroundColor
        this.chartCtx.fillRect(0.0, 0.0, 220.0, 220.0)

        let total = this.selectedTotal()
        this.chartCtx.lineWidth = 38.5
        if (total <= 0) {
            this.chartCtx.strokeStyle = this.presentation.dividerColor
            this.chartCtx.beginPath()
            this.chartCtx.arc(cx, cy, radius, 0.0, 6.2832)
            this.chartCtx.stroke()
            return
        }

        var start: Float64 = -1.5708
        for (row in this.sortedRows()) {
            if (row.total > 0) {
                let finish = start + 6.2832 * Float64(row.total) / Float64(total)
                this.chartCtx.strokeStyle = row.color
                this.chartCtx.beginPath()
                this.chartCtx.arc(cx, cy, radius, start, finish)
                this.chartCtx.stroke()
                start = finish
            }
        }
    }

    private func autoDownloadSummaryLabel(isCellular: Bool): String {
        let netSettings = getFileDownloadService().getAutoDownloadNetworkSettings()
        let connection = if (isCellular) { netSettings.cellular } else { netSettings.wifi }
        if (!connection.enabled) { return "Disabled" }
        let categories = effectiveCategories(connection)
        let hasPhoto = categories.photo.contacts || categories.photo.otherPrivate ||
            categories.photo.groups || categories.photo.channels
        let hasVideo = categories.video.contacts || categories.video.otherPrivate ||
            categories.video.groups || categories.video.channels
        let hasFile = categories.file.contacts || categories.file.otherPrivate ||
            categories.file.groups || categories.file.channels
        var result = ""
        if (hasPhoto && !hasVideo) { result = "Photos" }
        if (hasVideo) {
            let label = if (hasPhoto) {
                "Media (${autodownloadDataSizeString(categories.video.sizeLimit)})"
            } else {
                "Videos (${autodownloadDataSizeString(categories.video.sizeLimit)})"
            }
            result = if (result.size > 0) { result + ", " + label } else { label }
        }
        if (hasFile) {
            let label = "Files (${autodownloadDataSizeString(categories.file.sizeLimit)})"
            result = if (result.size > 0) { result + ", " + label } else { label }
        }
        if (result.size == 0) { return "Disabled" }
        return result
    }

    @Builder func pieChartArea(): Unit {
        Stack {
            Canvas(this.chartCtx)
                .width(220)
                .height(220)
                .backgroundColor(this.presentation.backgroundColor)
                .onReady({ => this.drawPieChart() })
            Text(this.formatBytes(this.selectedTotal()))
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.presentation.textColor)
        }
        .width(100.percent)
        .height(220)
    }

    @Builder func categoryRow(row: UsageDisplayRow): Unit {
        Column {
            Row {
                Image(this.categoryIcon(row.category))
                    .width(30)
                    .height(30)
                    .fillColor(0xFFFFFFFF)
                    .borderRadius(7)
                    .backgroundColor(row.color)
                    .margin(right: 12)
                Row {
                    Text(row.title)
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                    Text(this.percentage(row.total))
                        .fontSize(17)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(left: 6)
                }
                .alignItems(VerticalAlign.Center)
                .layoutWeight(1)
                Text(this.formatBytes(row.total))
                    .fontSize(15)
                    .fontColor(this.presentation.secondaryTextColor)
                if (row.total > 0) {
                    Image(@r(app.media.item_list_disclosure_arrow))
                        .width(8).height(14)
                        .fillColor(this.presentation.disclosureArrowColor)
                        .rotate(angle: if (this.isExpanded(row.category)) { -90.0 } else { 90.0 })
                        .margin(left: 8)
                }
            }
            .width(100.percent)
            .height(58)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt => this.toggleExpanded(row.category, row.total) })

            if (row.total > 0 && this.isExpanded(row.category)) {
                Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 40)
                Row {
                    Image(@r(app.media.chatroom_ic_download))
                        .width(20)
                        .height(20)
                        .fillColor(this.presentation.secondaryTextColor)
                        .margin(right: 8)
                    Text(trSource("Incoming")).fontSize(14).fontColor(this.presentation.secondaryTextColor).layoutWeight(1)
                    Text(this.formatBytes(row.incoming)).fontSize(14).fontColor(this.presentation.secondaryTextColor)
                }
                .height(38)
                .padding(left: 40, right: 16)
                Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 40)
                Row {
                    Image(@r(app.media.settings_ic_upload))
                        .width(20)
                        .height(20)
                        .fillColor(this.presentation.secondaryTextColor)
                        .margin(right: 8)
                    Text(trSource("Outgoing")).fontSize(14).fontColor(this.presentation.secondaryTextColor).layoutWeight(1)
                    Text(this.formatBytes(row.outgoing)).fontSize(14).fontColor(this.presentation.secondaryTextColor)
                }
                .height(38)
                .padding(left: 40, right: 16)
            }
        }
    }

    @Builder func totalOutgoingRow(): Unit {
        Row {
            Image(@r(app.media.dataus_ic_upload)).width(30).height(30).margin(right: 12)
            Text(trSource("Data Sent")).fontSize(15).fontColor(this.presentation.textColor).layoutWeight(1)
            Text(this.formatBytes(this.selectedSentLabel)).fontSize(15).fontColor(this.presentation.secondaryTextColor)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 6, bottom: 6)
        .alignItems(VerticalAlign.Center)
    }

    @Builder func totalIncomingRow(): Unit {
        Row {
            Image(@r(app.media.dataus_ic_download)).width(30).height(30).margin(right: 12)
            Text(trSource("Data Received")).fontSize(15).fontColor(this.presentation.textColor).layoutWeight(1)
            Text(this.formatBytes(this.selectedReceivedLabel)).fontSize(15).fontColor(this.presentation.secondaryTextColor)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 6, bottom: 6)
        .alignItems(VerticalAlign.Center)
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {
                if (!this.loaded) {
                    Column {
                        LoadingProgress().width(36).height(36).color(this.presentation.accentColor)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    Scroll {
                        Column {
                        this.pieChartArea()

                        Text(this.contentTitle())
                            .fontSize(28)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(this.presentation.textColor)
                            .width(100.percent)
                            .textAlign(TextAlign.Center)
                            .margin(top: 12)

                        if (this.usageSinceLabel.size > 0) {
                            Text(this.usageSinceLabel)
                                .fontSize(15)
                                .fontColor(this.presentation.secondaryTextColor)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .margin(top: 4)
                        }

                        Row {
                            SegmentedControl(
                                segments: ["All", "Mobile", "Wi-Fi"],
                                selectedIndex: this.selectedSegment,
                                onChange: { idx: Int64 => this.onSegmentChange(idx) }
                            )
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16)
                        .margin(top: 8)

                        Column {
                            ForEach(
                                this.sortedRows(),
                                itemGeneratorFunc: { row: UsageDisplayRow, idx: Int64 =>
                                    if (idx > 0) {
                                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 40)
                                    }
                                    this.categoryRow(row)
                                },
                                keyGeneratorFunc: { row: UsageDisplayRow, _idx: Int64 =>
                                    "${this.selectedSegment}-${row.category.ordinal()}-${row.incoming}-${row.outgoing}"
                                }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .clip(true)
                        .margin(left: 16, right: 16, top: 16)

                        Text(trSource("Tap on each section for detailed view."))
                            .fontSize(13)
                            .fontColor(this.presentation.secondaryTextColor)
                            .width(100.percent)
                            .padding(left: 32, right: 32)
                            .margin(top: 10)

                        ItemListSectionHeader(title: this.sectionTitleLabel, topPad: 16)
                        Column {
                            this.totalOutgoingRow()
                            Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 38)
                            this.totalIncomingRow()
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .clip(true)
                        .margin(left: 16, right: 16, top: 16)

                        if (this.selectedSegment == 1) {
                            Column {
                                ItemListDisclosureRow(
                                    icon: @r(app.media.setroot_ds_cellular),
                                    title: "Auto-Download Settings",
                                    value: this.autoDownloadSummaryLabel(true),
                                    useDetailLabelStyle: true,
                                    showChevron: false,
                                    onClick: { => routerPush("AutodownloadConnectionTypePage", "cellular") }
                                )
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(26)
                            .clip(true)
                            .margin(left: 16, right: 16, top: 16)
                            Text("You can change your auto-download settings for media to reduce data usage when cellular.")
                                .fontSize(13)
                                .fontColor(this.presentation.secondaryTextColor)
                                .width(100.percent)
                                .padding(left: 32, right: 32)
                                .margin(top: 8)
                        } else if (this.selectedSegment == 2) {
                            Column {
                                ItemListDisclosureRow(
                                    icon: @r(app.media.setroot_ds_wifi),
                                    title: "Auto-Download Settings",
                                    value: this.autoDownloadSummaryLabel(false),
                                    useDetailLabelStyle: true,
                                    showChevron: false,
                                    onClick: { => routerPush("AutodownloadConnectionTypePage", "wifi") }
                                )
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(26)
                            .clip(true)
                            .margin(left: 16, right: 16, top: 16)
                            Text("You can change your auto-download settings for media to reduce data usage when on wifi.")
                                .fontSize(13)
                                .fontColor(this.presentation.secondaryTextColor)
                                .width(100.percent)
                                .padding(left: 32, right: 32)
                                .margin(top: 8)
                        }

                        if (this.selectedTotal() > 0) {
                            Row {
                                Text(this.resetLabel())
                                    .fontSize(17)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(this.resetColor())
                                    .textAlign(TextAlign.Center)
                                    .width(100.percent)
                            }
                            .height(56)
                            .justifyContent(FlexAlign.Center)
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(26)
                            .clip(true)
                            .margin(left: 16, right: 16, top: 24)
                            .onClick({ _evt => this.confirmReset() })
                        }
                        Text(trSource("")).height(32)
                        }
                        .padding(top: getSafeAreaTop())
                    }
                    .align(Alignment.Top)
                    .layoutWeight(1)
                    .backgroundColor(this.presentation.backgroundColor)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(this.presentation.backgroundColor)
            .padding(bottom: getSafeAreaBottom())

            Row {
                Image(@r(app.media.callui_v2_back))
                    .width(10)
                    .height(18)
                    .fillColor(this.presentation.accentColor)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0xCCFFFFFF })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .margin(left: 16, top: getSafeAreaTop() + 8.0)
            .zIndex(100)
            .onClick({ _ => routerPop() })
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .onAppear({ => this.ensureLoaded() })
    }
}
