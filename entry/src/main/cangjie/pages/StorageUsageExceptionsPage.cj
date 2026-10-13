package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.ArkData.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.getRealChatListService
import ohos_app_cangjie_entry.services.getUserPhotoService
import ohos_app_cangjie_entry.services.getCurrentUserId
import ohos_app_cangjie_entry.services.JsonParser
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSeparator,
    ContextMenuItem,
    ContextMenuView,
    Avatar,
    AvatarSpecialPeer,
    SearchBar,
    ITEM_LIST_ACCENT
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.utils.safeAnimateTo
import std.collection.ArrayList

/**
 * StorageUsageExceptionsPage — source `StorageUsageExceptionsScreen.swift` counterpart.
 *
 * diag-suite_settings_data_storage-TC-0430-round2.md 修法方向 M-2: allowlist grant is
 * `pages/StorageUsageExceptionsPage.cj` + `ets/pages/StorageUsageExceptionsPage.ets` + one
 * `route_map.json` entry (`set_storage_and_energy` feature.json commit 019274cbc, source-
 * ownership rationale — `owned_source_files` for `.../StorageUsageExceptionsScreen.swift`
 * is this feature itself, so the earlier round1/round2 "integration contract" framing was a
 * degenerate case: the source owner and the only possible target owner are the same
 * feature). This round builds ONLY this screen (M-2). The menu trailing item that reaches
 * it (M-1c, on `pages/StorageUsagePage.cj`) is a **separate file not in this feature's
 * allowlist** (owned by `shell_storage_usage`) and was **not claimed this round** — see this
 * feature's `.md` Hand-off for why "page + route, no entry yet" is the intended safe half of
 * a two-part fix rather than a defect.
 *
 * Route param contract (this round defines it; M-1c must copy it verbatim per round2's own
 * instruction "paramJson 的键名与形状照抄本页已有的 routerPush 调用点"):
 *   routerPush("StorageUsageExceptionsPage", "{\"category\":\"privateChats\"}")
 *   category ∈ {"privateChats","groups","channels"} — `.stories` never reaches this screen
 *   (source `if mappedCategory != .stories` hard gate on the menu trailing item itself,
 *   TC-0430 case §B3) so this screen never needs to special-case it.
 *
 * Persistence: self-contained Preferences store (same pattern as
 * `AutosaveExceptionPeerSelectionPage.cj`'s own store, not shared with any other feature's
 * file — none of those files are in this feature's allowlist). Store name
 * `telegram_storage_usage_exceptions`, key `"${category}_exceptions"`, value a JSON array
 * (via `services/JsonParser.cj`, already in the entry package) of
 * `{"peerId":<Int64>,"value":<Int64 seconds, Int64.Max sentinel = Forever>}`. This is this
 * screen's own account-specific-cache-storage-settings surrogate — source persists via
 * `updateAccountSpecificCacheStorageSettingsInteractively` into a shared Postbox-backed
 * settings blob that no target-side service in this feature's allowlist exposes; a
 * dedicated local store (matching TC-0430/TC-0431's "purely local, no network request"
 * observation, case §4/§ E9/C5) reproduces the same observable behavior without requiring a
 * new shared-service file.
 *
 * Scope actually built this round (see `.md` Hand-off for the deferred M-1c half):
 *   - Nav bar: `Exceptions` title, back control, no right button, no close/modal chrome
 *     (`isModal` is always false — source's 10 call sites never pass true, TC-0430 C1/D4).
 *   - No-exception state (C2/ST1): a single card with only the `Add an Exception` row — no
 *     `EXCEPTIONS` header, no empty-state illustration/copy (source's `entries()` only
 *     appends `.exceptionsHeader`/`.peer` when `peerExceptions` is non-empty,
 *     `StorageUsageExceptionsScreen.swift:195-203`).
 *   - Add flow (C4/C5): tapping `Add an Exception` flips this same screen into an inline
 *     picker phase (title becomes `Add Exception`, category-filtered candidate list, no
 *     contacts-vs-chats split — mirrors `AutosaveExceptionPeerSelectionPage.cj`'s existing
 *     single-file two-phase pattern rather than pushing a second route, since this
 *     feature's allowlist has exactly one new page file). Selecting a candidate persists
 *     immediately with default value = Forever and returns to the list phase (source:
 *     `openAddException` → `peerSelected` writes `Int32.max` and dismisses the picker
 *     synchronously, `:317-337`).
 *   - Exception rows (C6/C6-b/C7): real avatar (Saved Messages special-cased when the
 *     exception peer is the account's own id, matching source's
 *     `peer.peer.id == context.account.peerId` check, `:170-171`), participant-count
 *     subtitle for groups/channels when cached (`:158-161`, singular `participant`), value
 *     label on the right, up/down `ContextDisclosureArrow` chevron (TC-0430-round5 C6-b fix —
 *     see `contextDisclosureArrowCommands()` doc comment for the render-path rationale).
 *   - Per-exception menu (TC-0431): tapping a row opens the same `components/ContextMenu.cj`
 *     overlay this feature already uses on `StorageUsagePage.cj` (4 period items in source's
 *     fixed order Forever/1 month/1 week/1 day, unsorted — source's per-peer menu has no
 *     "insert current value" step unlike the Keep-Media menu, `:372-396`) + a destructive
 *     `Remove` item (`:398-405`). Selecting a period rewrites the entry in place and the
 *     list re-sorts by value ascending (Forever sorts last, source `:283-288`); Remove
 *     deletes it — deleting the last entry drops both the card and the `EXCEPTIONS` header
 *     back to the C2 no-exception state.
 *
 * Known limitations (disclosed, not silently simplified):
 *   - `ContextMenuView`'s existing click order is "run the item's onClick, then onDismiss"
 *     (`components/ContextMenu.cj`), i.e. Remove's delete runs before the menu closes.
 *     TC-0431 C2 wants the opposite order but explicitly says the reversed order is a
 *     recorded Diff, not a FAIL — not worth forking the shared component (out of this
 *     feature's allowlist) for.
 *   - "≥2 candidates in the category" (TC-0431 P2) and multi-exception sort-reordering are
 *     both exercised by this same read/sort/persist path — no separate code path exists for
 *     them, so nothing extra was built or skipped there.
 */

private let EXC_FOREVER_SECONDS: Int64 = 9223372036854775807
private let EXC_SECONDS_1_MONTH: Int64 = 2678400  // 31 days
private let EXC_SECONDS_1_WEEK: Int64 = 604800    // 7 days
private let EXC_SECONDS_1_DAY: Int64 = 86400      // 1 day

public class ExceptionEntry {
    public var peerId: Int64
    public var value: Int64
    public var displayName: String
    public var avatarPath: String
    public var isSelf: Bool
    public var participantsCount: Int64  // -1 = not applicable / not cached

    public init(
        peerId!: Int64,
        value!: Int64,
        displayName!: String,
        avatarPath!: String,
        isSelf!: Bool,
        participantsCount!: Int64
    ) {
        this.peerId = peerId
        this.value = value
        this.displayName = displayName
        this.avatarPath = avatarPath
        this.isSelf = isSelf
        this.participantsCount = participantsCount
    }
}

private func containsPeerId(list: ArrayList<Int64>, id: Int64): Bool {
    for (v in list) {
        if (v == id) { return true }
    }
    return false
}

@HybridComponentEntry
@Component
public class StorageUsageExceptionsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var category: String = "privateChats"
    @State var paramParsed: Bool = false
    @State var loaded: Bool = false

    @State var exceptions: ArrayList<ExceptionEntry> = ArrayList<ExceptionEntry>()

    // true = the inline "Add Exception" picker phase (see class header — single-file
    // two-phase pattern, this feature's allowlist has exactly one new page file).
    @State var pickerPhase: Bool = false
    @State var pickerCandidates: ArrayList<Chat> = ArrayList<Chat>()
    @State var pickerLoading: Bool = false
    @State var pickerQuery: String = ""

    // Drives the per-exception ContextMenu overlay; -1 = hidden.
    @State var menuForPeerId: Int64 = -1

    // C3 local recreation of ItemListButtonRow's press three-piece (D-184 below) — the shared
    // component's own @State isPressed (components/ItemListComponents.cj:984) can't be reused
    // from outside the component.
    @State var isPressedAdd: Bool = false
    // C3 tint source — same field/import shape as pages/StorageUsagePage.cj:146.
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    private func storeName(): String { "telegram_storage_usage_exceptions" }
    private func exceptionsKey(): String { "${this.category}_exceptions" }

    private func parseRouteParamOnce(): Unit {
        if (this.paramParsed) { return }
        this.paramParsed = true
        let raw = takePending("StorageUsageExceptionsPage")
        if (raw.size > 0 && raw != "{}") {
            let obj = JsonParser.parseObject(raw)
            if (obj.has("category")) {
                let cat = obj.getString("category")
                if (cat == "groups" || cat == "channels") {
                    this.category = cat
                } else {
                    this.category = "privateChats"
                }
            }
        }
    }

    private func labelForSeconds(sec: Int64): String {
        if (sec == EXC_FOREVER_SECONDS) { return "Forever" }
        if (sec == EXC_SECONDS_1_MONTH) { return "1 month" }
        if (sec == EXC_SECONDS_1_WEEK) { return "1 week" }
        if (sec == EXC_SECONDS_1_DAY) { return "1 day" }
        return "${sec / 86400} days"
    }

    // ── raw (peerId, value) pairs on disk ──
    private func readRawExceptions(): ArrayList<(Int64, Int64)> {
        let out = ArrayList<(Int64, Int64)>()
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, this.storeName())
                    match (prefs.get(this.exceptionsKey(), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) =>
                            if (s.size > 0) {
                                let arr = JsonParser.parseArray(s)
                                for (obj in arr.getObjects()) {
                                    out.add((obj.getInt("peerId"), obj.getInt("value")))
                                }
                            }
                        case _ => ()
                    }
                } catch (_e: Exception) {}
            case None => ()
        }
        return out
    }

    private func writeRawExceptions(list: ArrayList<(Int64, Int64)>): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, this.storeName())
                    let arr = JsonParser.parseArray("[]")
                    for ((peerId, value) in list) {
                        let obj = JsonParser.parseObject("{}")
                        obj.setInt("peerId", peerId)
                        obj.setInt("value", value)
                        arr.addObject(obj)
                    }
                    prefs.put(this.exceptionsKey(), PreferencesValueType.StringData(arr.toJsonString()))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    // ── resolve peer display info + sort by value asc, tie by name asc (source
    // StorageUsageExceptionsScreen.swift:283-288) — Forever == EXC_FOREVER_SECONDS sorts last. ──
    private func loadExceptions(): Unit {
        let cat = this.category
        let _ = spawn {
            let raw = this.readRawExceptions()
            let svc = getRealChatListService()
            let photoSvc = getUserPhotoService()
            let selfId = getCurrentUserId()
            let resolved = ArrayList<ExceptionEntry>()
            for ((peerId, value) in raw) {
                var name = "Chat ${peerId}"
                var avatarPath = ""
                var isSelf = false
                var participants: Int64 = -1
                if (cat == "privateChats") {
                    isSelf = (peerId == selfId)
                    if (isSelf) {
                        name = "Saved Messages"
                    } else {
                        match (svc.getCachedUser(peerId)) {
                            case Some(u) =>
                                var n = u.firstName
                                if (u.lastName.size > 0) { n = "${u.firstName} ${u.lastName}" }
                                if (n.size > 0) { name = n }
                            case None => ()
                        }
                    }
                    avatarPath = photoSvc.getUserPhotoPath(peerId)
                } else {
                    match (svc.getCachedChat(peerId)) {
                        case Some(c) =>
                            if (c.title.size > 0) { name = c.title }
                            if (c.participantsCount > 0) { participants = Int64(c.participantsCount) }
                        case None => ()
                    }
                    avatarPath = photoSvc.getChatPhotoPath(peerId)
                }
                resolved.add(ExceptionEntry(
                    peerId: peerId, value: value, displayName: name,
                    avatarPath: avatarPath, isSelf: isSelf, participantsCount: participants
                ))
            }
            // insertion sort by (value asc, name asc) — lists here are small (exceptions,
            // not the full chat list), so O(n^2) is fine and keeps this self-contained.
            let sorted = ArrayList<ExceptionEntry>()
            for (entry in resolved) {
                var idx: Int64 = 0
                while (idx < sorted.size) {
                    let other = sorted[idx]
                    let goesBefore = if (entry.value != other.value) {
                        entry.value < other.value
                    } else {
                        entry.displayName < other.displayName
                    }
                    if (goesBefore) { break }
                    idx += 1
                }
                sorted.add(entry, at: idx)
            }
            spawn(UIThread) { =>
                this.exceptions = sorted
                this.loaded = true
            }
        }
    }

    // ── candidate list for the inline picker phase (mirrors
    // AutosaveExceptionPeerSelectionPage.cj's peerType filter shape) ──
    private func loadPickerCandidates(): Unit {
        this.pickerLoading = true
        let existingIds = ArrayList<Int64>()
        for (e in this.exceptions) { existingIds.add(e.peerId) }
        let cat = this.category
        let _ = spawn {
            let chats = getRealChatListService().getDialogsLocalFirst(limit: 200)
            let out = ArrayList<Chat>()
            for (chat in chats) {
                var match_ = false
                if (cat == "privateChats") {
                    match_ = chat.peerType == "user" && !chat.isSecretChat
                } else if (cat == "groups") {
                    match_ = chat.isGroup
                } else {
                    match_ = chat.isChannel && !chat.isGroup
                }
                if (match_ && !containsPeerId(existingIds, chat.id)) {
                    out.add(chat)
                }
            }
            let result = out
            spawn(UIThread) { =>
                this.pickerCandidates = result
                this.pickerLoading = false
            }
        }
    }

    private func filteredPickerCandidates(): ArrayList<Chat> {
        if (this.pickerQuery.size == 0) { return this.pickerCandidates }
        let q = this.pickerQuery.toAsciiLower()
        let out = ArrayList<Chat>()
        for (c in this.pickerCandidates) {
            if (c.name.toAsciiLower().contains(q)) { out.add(c) }
        }
        return out
    }

    private func openAddException(): Unit {
        this.pickerPhase = true
        this.pickerQuery = ""
        this.loadPickerCandidates()
    }

    // ── source `openAddException.peerSelected` (:317-337): write Int32.max (Forever),
    // dismiss picker synchronously. ──
    private func selectCandidate(chat: Chat): Unit {
        let raw = this.readRawExceptions()
        let filtered = ArrayList<(Int64, Int64)>()
        for ((peerId, value) in raw) {
            if (peerId != chat.id) { filtered.add((peerId, value)) }
        }
        filtered.add((chat.id, EXC_FOREVER_SECONDS))
        this.writeRawExceptions(filtered)
        this.pickerPhase = false
        Hilog.info(0, "CjTelegram", "[StorageUsageExceptions] added peerId=${chat.id} category=${this.category}")
        this.loadExceptions()
    }

    private func openExceptionMenu(peerId: Int64): Unit {
        this.menuForPeerId = peerId
    }

    private func currentValueFor(peerId: Int64): Int64 {
        for (e in this.exceptions) {
            if (e.peerId == peerId) { return e.value }
        }
        return EXC_FOREVER_SECONDS
    }

    // TC-0431 A5: source dims the row's label/arrow instantly on present but restores them with
    // a 0.3s easeInOut on dismiss (`ItemListDisclosureItem.swift:updateHasContextMenu`), so the
    // open path (`openExceptionMenu`) stays a plain synchronous assignment and only this one is
    // animated. `safeAnimateTo` per D-120 / utils/UiSafety.cj — a dismiss can arrive after the
    // page detaches, and the fallback still lands `-1` so the menu can never stick open.
    private func closeExceptionMenu(): Unit {
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseInOut), { =>
            this.menuForPeerId = -1
        })
    }

    private func applyExceptionValue(peerId: Int64, value: Int64): Unit {
        let raw = this.readRawExceptions()
        let out = ArrayList<(Int64, Int64)>()
        for ((pid, v) in raw) {
            if (pid == peerId) {
                out.add((pid, value))
            } else {
                out.add((pid, v))
            }
        }
        this.writeRawExceptions(out)
        Hilog.info(0, "CjTelegram", "[StorageUsageExceptions] setValue peerId=${peerId} value=${value}")
        this.loadExceptions()
    }

    private func removeException(peerId: Int64): Unit {
        let raw = this.readRawExceptions()
        let out = ArrayList<(Int64, Int64)>()
        for ((pid, v) in raw) {
            if (pid != peerId) { out.add((pid, v)) }
        }
        this.writeRawExceptions(out)
        Hilog.info(0, "CjTelegram", "[StorageUsageExceptions] removed peerId=${peerId}")
        this.loadExceptions()
    }

    // source :372-396 — fixed order, no "insert current value" step (unlike the Keep-Media
    // menu on StorageUsagePage.cj which does have that step for its own preset list).
    private func menuItemsFor(peerId: Int64, currentValue: Int64): Array<ContextMenuItem> {
        let items = ArrayList<ContextMenuItem>()
        let presets = [EXC_FOREVER_SECONDS, EXC_SECONDS_1_MONTH, EXC_SECONDS_1_WEEK, EXC_SECONDS_1_DAY]
        for (v in presets) {
            var icon: ?ResourceStr = None
            if (v == currentValue) { icon = Some(@r(app.media.media_ic_check)) }
            let capturedValue = v
            items.add(ContextMenuItem(
                title: this.labelForSeconds(v),
                iconRes: icon,
                onClick: { => this.applyExceptionValue(peerId, capturedValue) }
            ))
        }
        items.add(ContextMenuItem.separator())
        items.add(ContextMenuItem(
            title: "Remove",
            iconRes: Some(@r(app.media.clist_ic_delete)),
            destructive: true,
            onClick: { => this.removeException(peerId) }
        ))
        return items.toArray()
    }

    private func participantsLabel(count: Int64): String {
        if (count == 1) { return "1 participant" }
        return "${count} participants"
    }

    private func exceptionsHeaderText(): String {
        let n = this.exceptions.size
        if (n == 1) { return "1 EXCEPTION" }
        return "${n} EXCEPTIONS"
    }

    @Builder
    func buildCandidateRow(entry: Chat) {
        Row {
            Avatar(
                avatarUrl: entry.avatarLocalPath,
                displayName: entry.name,
                avatarSize: 40,
                peerId: entry.id,
                specialPeer: if (entry.isSavedMessages) { AvatarSpecialPeer.SavedMessages } else { AvatarSpecialPeer.Normal }
            )
            Text(entry.name)
                .fontSize(17).fontColor(this.presentation.textColor)
                .layoutWeight(1).margin(left: 12)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
        }
        .width(100.percent)
        .height(56)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.selectCandidate(entry) })
    }

    @Builder
    func buildExceptionRow(entry: ExceptionEntry) {
        Row {
            Avatar(
                avatarUrl: entry.avatarPath,
                displayName: entry.displayName,
                avatarSize: 40,
                peerId: entry.peerId,
                specialPeer: if (entry.isSelf) { AvatarSpecialPeer.SavedMessages } else { AvatarSpecialPeer.Normal }
            )
            Column {
                Text(entry.displayName)
                    .fontSize(17)
                    .fontColor(this.presentation.textColor)
                    .fontWeight(FontWeight.Bold)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                // C7: participant-count subtitle for groups/channels when cached; never for
                // private chats (source :158-161 only threads subscriberCount through for
                // non-private categories).
                if (entry.participantsCount >= 0) {
                    Text(this.participantsLabel(entry.participantsCount))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 2)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin(left: 12)
            // TC-0431 A5: source's per-row menu feedback is `ItemListDisclosureItemNode`'s
            // `updateHasContextMenu` (`ItemListDisclosureItem.swift`), called from
            // `StorageUsageExceptionsScreen.swift:407-420` on present/dismiss — it dims only
            // `labelNode` + `arrowNode` to alpha 0.5 while the menu is up. Title, avatar and the
            // row background never take part, so the opacity lives on these two nodes and not on
            // the Row / card / scrim. Same shape as `pages/AppLockPage.cj:1410,1415`.
            Text(this.labelForSeconds(entry.value))
                .fontSize(15)
                .fontColor(this.presentation.secondaryTextColor)
                .margin(right: 6)
                .opacity(if (this.menuForPeerId == entry.peerId) { 0.5 } else { 1.0 })
            // C6-b: converted resource is `resources/base/media/item_list_context_disclosure_arrow.svg`
            // (verbatim copy of source `Item List/ContextDisclosureArrow.imageset/ContextDisclosureArrow.svg`,
            // `fill="none"` open double-chevron). Rendered as an open-stroke `Path`, NOT
            // `Image(@r(...)).fillColor(...)` — D-175 (dev_pattern.md) documents that
            // `Image.fillColor()` recolors a `fill="none"` SVG as a *filled* shape, turning an
            // open chevron into a solid wedge (same bug already fixed on
            // `app/TelegramNavBar.cj:navBackArrowGlassCommands()` / `pages/DevicesPage.cj:728-739
            // backArrowCommands()` for the identical asset shape). The `.svg` resource itself is
            // still the authoritative converted asset (kept for catalog/consumers that don't hit
            // this bug, e.g. `shell_storage_usage`'s S-3 reuse) — only this render call routes
            // around `fillColor`.
            Stack {
                Path()
                    .width(12)
                    .height(16)
                    .commands(this.contextDisclosureArrowCommands())
                    .fill(Color.Transparent)
                    .stroke(0xC7C7CC)
                    .strokeWidth(2)
                    .strokeLineCap(LineCapStyle.Round)
                    .strokeLineJoin(LineJoinStyle.Round)
            }
            .width(12)
            .height(16)
            // TC-0431 A5, arrow half of source's `updateHasContextMenu` (see the value label
            // above). Applied to the wrapper Stack rather than the inner `Path` so the whole
            // arrow node dims as one, matching source's node-level `arrowNode.alpha`.
            .opacity(if (this.menuForPeerId == entry.peerId) { 0.5 } else { 1.0 })
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.openExceptionMenu(entry.peerId) })
    }

    // Path.commands() coordinates are device px, not vp (same as
    // app/TelegramNavBar.cj:navBackArrowGlassCommands() / DevicesPage.cj:backArrowCommands()) —
    // scale by vp2px(1.0) before building the command string. Geometry is the exact source SVG
    // path data (two open 3-point polylines, `M2 5.5L6 2L10 5.5` / `M10 10.5L6 14L2 10.5` in a
    // 12x16 viewBox), not re-derived or approximated.
    private func contextDisclosureArrowCommands(): String {
        let scale: Float64 = match (this.getUIContext().vp2px(1.0.vp)) {
            case Some(len) => len.value
            case None => Float64(getDefaultDisplaySync().densityPixels)
        }
        let x2: Float64 = 2.0 * scale
        let x6: Float64 = 6.0 * scale
        let x10: Float64 = 10.0 * scale
        let y2: Float64 = 2.0 * scale
        let y55: Float64 = 5.5 * scale
        let y105: Float64 = 10.5 * scale
        let y14: Float64 = 14.0 * scale
        return "M${x2} ${y55}L${x6} ${y2}L${x10} ${y55} M${x10} ${y105}L${x6} ${y14}L${x2} ${y105}"
    }

    // C3: local recreation of `ItemListButtonRow.build()`
    // (components/ItemListComponents.cj:993-1034) — logic bug fix, not a formatting change.
    // The shared component never applies `.fillColor` to its optional leading `icon`
    // (components/ItemListComponents.cj:995-1000), so any consumer's icon renders at the SVG's
    // baked-in fill (black here) regardless of theme/accent. Per D-184 (dev_pattern.md), a
    // shared-row bug outside this feature's allowlist (`components/ItemListComponents.cj` is not
    // in `tasks[].target_files`, and adding a tint parameter would touch 36+ other call sites) is
    // fixed by locally reproducing the row body, not by patching the shared component. Every
    // other element of the row (width/height/padding/alignItems, the centered=false Text branch,
    // the isPressed press-state three-piece) is copied verbatim from the source lines above; the
    // only two intentional deltas are (1) the icon resource
    // (`@r(app.media.location_ic_creategroup)`, see class header for its own C3 grant/conversion
    // note) and (2) adding `.fillColor(this.presentation.accentColor)` on that icon, matching
    // source `PresentationResourcesItemList.swift:181-185`
    // `generateTintedImage(..., color: theme.list.itemAccentColor)`.
    @Builder
    func buildAddExceptionRow() {
        Row {
            Image(@r(app.media.location_ic_creategroup))
                .width(29)
                .height(29)
                .margin(right: 16)
                .fillColor(this.presentation.accentColor)
            Text(trSource("Add an Exception"))
                .fontSize(17)
                .fontColor(ITEM_LIST_ACCENT)
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
        }
        .width(100.percent)
        .height(52)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(if (!this.isPressedAdd) { Color.Transparent } else { this.presentation.itemHighlightedBackgroundColor })
        .onClick({ _ => this.openAddException() })
        .onTouch({ evt =>
            match (evt.eventType) {
                case TouchType.Down => this.isPressedAdd = true
                case TouchType.Up =>
                    safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                        this.isPressedAdd = false
                    })
                case _ => this.isPressedAdd = false
            }
        })
    }

    @Builder
    func buildPickerPhase() {
        Column {
            SearchBar(
                loading: false,
                backArrow: false,
                text: this.pickerQuery,
                hint: trSource("Search"),
                onChange: { s: String => this.pickerQuery = s }
            )
            if (this.pickerLoading) {
                Column {
                    LoadingProgress().width(32).height(32)
                }
                .width(100.percent).layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                List {
                    ForEach(this.filteredPickerCandidates(), itemGenerator: { entry: Chat, _idx: Int64 =>
                        ListItem {
                            this.buildCandidateRow(entry)
                        }
                    }, keyGeneratorFunc: { entry: Chat, _idx: Int64 => "candidate_${entry.id}" })
                }
                .layoutWeight(1)
            }
        }
        .width(100.percent)
        .layoutWeight(1)
    }

    @Builder
    func buildListPhase() {
        Scroll {
            Column {
                Column {
                    this.buildAddExceptionRow()
                }
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(12)
                .clip(true)
                .margin(left: 16, right: 16, top: 20)

                // C2/ST1: no `EXCEPTIONS` header, no card, no empty-state copy when empty.
                if (!this.exceptions.isEmpty()) {
                    ItemListSectionHeader(title: this.exceptionsHeaderText(), topPad: 20)

                    Column {
                        // TC-0431 s4: `ExceptionEntry` is not `@Observed` (see its declaration —
                        // deliberately plain, same reason as `models/Chat.cj:12-14`), so per D-127
                        // direction B the `ForEach` key is this row's ONLY content-update channel:
                        // `applyExceptionValue()` persists then `loadExceptions()` rebuilds the
                        // array, but with no explicit key the framework reused the old row node and
                        // `itemGeneratorFunc` never re-ran, freezing
                        // `Text(labelForSeconds(entry.value))` at its first-built value (new value
                        // only appeared after leaving and re-entering the page). The key is the
                        // full content fingerprint — `peerId` prefix for stable identity, then all
                        // six of `ExceptionEntry`'s fields, i.e. every field `buildExceptionRow()`
                        // renders, so no field's change is invisible — and contains no `idx`, so
                        // the (value asc, name asc) re-sort is still recognised as a reorder.
                        // Same shape as the shipped precedent
                        // `pages/SaveIncomingMediaPage.cj:706-708`.
                        ForEach(this.exceptions, itemGeneratorFunc: { entry: ExceptionEntry, idx: Int64 =>
                            this.buildExceptionRow(entry)
                            if (idx < this.exceptions.size - 1) {
                                ItemListSeparator(leftInset: 68)
                            }
                        }, keyGeneratorFunc: { entry: ExceptionEntry, _idx: Int64 =>
                            "exception_${entry.peerId}_${entry.value}_${entry.displayName}_${entry.avatarPath}_${entry.isSelf}_${entry.participantsCount}"
                        })
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(12)
                    .clip(true)
                    .margin(left: 16, right: 16)
                }

                Column {}.height(40)
            }
        }
        .layoutWeight(1)
        .backgroundColor(this.presentation.backgroundColor)
    }

    private func navTitle(): String {
        if (this.pickerPhase) { return "Add Exception" }
        return "Exceptions"
    }

    private func handleBack(): Unit {
        if (this.pickerPhase) {
            this.pickerPhase = false
        } else {
            routerPop()
        }
    }

    public func build() {
        Stack {
            Column {
                Row {
                    Row { Image(@r(app.media.callui_v2_back)).width(10).height(18).fillColor(this.presentation.accentColor) }
                    .width(44).height(44).borderRadius(22)
                    .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                    .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.handleBack() })
                    Blank().layoutWeight(1)
                    Text(this.navTitle())
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)
                    Blank().layoutWeight(1)
                    // C1: no right-side button, isModal is always false — no close icon either.
                    Row {}.width(60)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(this.presentation.navBarColor)
                .alignItems(VerticalAlign.Center)

                if (this.pickerPhase) {
                    this.buildPickerPhase()
                } else {
                    this.buildListPhase()
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(this.presentation.backgroundColor)
            .padding(bottom: getSafeAreaBottom())
            .onAppear({ =>
                this.parseRouteParamOnce()
                if (!this.loaded) {
                    this.loaded = true
                    this.loadExceptions()
                }
            })

            if (this.menuForPeerId >= 0) {
                ContextMenuView(
                    items: this.menuItemsFor(this.menuForPeerId, this.currentValueFor(this.menuForPeerId)),
                    onDismiss: { => this.closeExceptionMenu() }
                )
            }
        }
        .width(100.percent)
        .height(100.percent)
    }
}
