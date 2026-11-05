import ApplicationServices
import Foundation

/// `track.set_instrument` on Logic Pro 13, which replaced the Library with the Browser.
///
/// Measured on Logic 13.0 (en) on 2026-11-05 with Logic in the background, each step by
/// Accessibility alone: the control bar's `controlBar/libraryButton` toggles the Browser, a window
/// child `AXGroup` described Browser. Its search field filters only after `AXValue` and then
/// `AXConfirm`, and leaves the query behind as a button described with the query. Results rank by
/// relevance, so a row is picked by its exact name, which is the static text in its cells. With
/// Replace on selection on, setting a row's `AXSelected` loads that patch on the selected track,
/// and the track header showed the patch name within about 3 s. A selected User Content Location
/// narrows every search to its folder, so a patch search finds nothing while one is selected.
///
/// The route selects the track without activating Logic, opens the Browser if it was closed,
/// clears the filters, deselects every Location, turns the Instruments category and Replace on
/// selection on, searches the patch's leaf name and selects the one row with exactly that name. It
/// refuses when no row or more than one row has that name; rows carry no category, so a category
/// prefix in the path is not checked. The load is verified when the target track's name becomes
/// the patch name. Every exit after the Browser was found clears its filters and, if it was
/// closed, closes it again.
extension AccessibilityChannel {
    static let browserToggleIdentifier = "controlBar/libraryButton"
    static let browserReplaceOnSelectionIdentifier = "replaceOnSelectionButton"
    static let browserRemoveFiltersIdentifier = "xmark.circle.fill"

    static let browserPollNanoseconds: UInt64 = 100_000_000
    /// Reads, `browserPollNanoseconds` apart, for the Browser to show, hide or apply a toggle.
    static let browserSettlePolls = 20
    /// Wait after the search token appears before the results are read.
    static let browserResultsSettleNanoseconds: UInt64 = 1_000_000_000
    /// Reads, `browserPollNanoseconds` apart, for the track to take the patch name.
    static let browserLoadPolls = 50

    enum BrowserInstrumentOutcome {
        /// No Logic 13 Browser: no Browser toggle in the control bar, or the toggle shows no Browser.
        case noBrowser
        case result(ChannelResult)
    }

    /// The Browser toggle in the arrange window's control bar toolbar.
    static func browserToggle(
        in window: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        let ax = runtime.ax
        for toolbar in AXHelpers.getChildren(window, runtime: ax)
        where AXHelpers.getRole(toolbar, runtime: ax) == (kAXToolbarRole as String) {
            if let toggle = browserDescendant(in: toolbar, maxDepth: 4, runtime: ax, where: {
                AXHelpers.getIdentifier($0, runtime: ax) == browserToggleIdentifier
            }) {
                return toggle
            }
        }
        return nil
    }

    static func browserPanel(in window: AXUIElement, runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        AXHelpers.getChildren(window, runtime: runtime.ax).first {
            AXHelpers.isBrowserPanel($0, runtime: runtime.ax)
        }
    }

    /// Depth-first search that never descends into a table, outline or row: the Browser's results
    /// table vends thousands of rows, each costly to read.
    static func browserDescendant(
        in root: AXUIElement,
        maxDepth: Int = 10,
        runtime: AXHelpers.Runtime,
        where match: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }
        for child in AXHelpers.getChildren(root, runtime: runtime) {
            if match(child) { return child }
            let role = AXHelpers.getRole(child, runtime: runtime)
            if role == (kAXTableRole as String) || role == (kAXOutlineRole as String) || role == (kAXRowRole as String) {
                continue
            }
            if let found = browserDescendant(in: child, maxDepth: maxDepth - 1, runtime: runtime, where: match) {
                return found
            }
        }
        return nil
    }

    /// The patch name a results row shows: the first static text in its cells.
    static func browserRowName(_ row: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        for cell in AXHelpers.getChildren(row, runtime: runtime) {
            for item in AXHelpers.getChildren(cell, runtime: runtime)
            where AXHelpers.getRole(item, runtime: runtime) == (kAXStaticTextRole as String) {
                return (AXHelpers.getValue(item, runtime: runtime) as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func browserToggleIsOn(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        (AXHelpers.getValue(element, runtime: runtime) as? NSNumber)?.intValue == 1
    }

    static func setTrackInstrumentViaBrowser(
        requestedTrackIndex: Int?,
        requestedPath: String,
        category: String,
        preset: String,
        pathSegments: [String],
        runtime: AXLogicProElements.Runtime,
        pause: @escaping @Sendable (UInt64) async -> Void
    ) async -> BrowserInstrumentOutcome {
        let ax = runtime.ax
        guard let window = AXLogicProElements.mainWindow(runtime: runtime),
              let toggle = browserToggle(in: window, runtime: runtime) else {
            return .noBrowser
        }

        func settle(_ condition: () -> Bool) async -> Bool {
            if condition() { return true }
            for _ in 0..<browserSettlePolls {
                await pause(browserPollNanoseconds)
                if condition() { return true }
            }
            return false
        }

        let wasOpen = browserToggleIsOn(toggle, runtime: ax)
        var found = browserPanel(in: window, runtime: runtime)
        if found == nil, !wasOpen {
            AXHelpers.performAction(toggle, kAXPressAction as String, runtime: ax)
            _ = await settle { found = browserPanel(in: window, runtime: runtime); return found != nil }
            if found == nil {
                // A control bar whose Library toggle shows no Browser is Logic 12's Library.
                AXHelpers.performAction(toggle, kAXPressAction as String, runtime: ax)
                _ = await settle { !browserToggleIsOn(toggle, runtime: ax) }
                Log.info("set_instrument: the control bar's Library toggle showed no Browser; using the Library route", subsystem: "ax")
                return .noBrowser
            }
        }
        guard let panel = found else { return .noBrowser }

        func element(_ match: (AXUIElement) -> Bool) -> AXUIElement? {
            browserDescendant(in: panel, runtime: ax, where: match)
        }
        func removeFiltersButton() -> AXUIElement? {
            element { AXHelpers.getIdentifier($0, runtime: ax) == browserRemoveFiltersIdentifier }
        }
        func clearFilters() async -> Bool {
            guard let button = removeFiltersButton() else { return true }
            AXHelpers.performAction(button, kAXPressAction as String, runtime: ax)
            return await settle { removeFiltersButton() == nil }
        }
        func restore() async -> [String: Any] {
            let cleared = await clearFilters()
            var restored = true
            if !wasOpen {
                AXHelpers.performAction(toggle, kAXPressAction as String, runtime: ax)
                restored = await settle { browserPanel(in: window, runtime: runtime) == nil }
            }
            return [
                "browser_was_open": wasOpen,
                "browser_filters_cleared": cleared,
                "browser_restored": restored,
            ]
        }

        var extras = setInstrumentBaseExtras(
            requestedPath: requestedPath,
            category: category,
            preset: preset,
            targetTrackIndex: requestedTrackIndex as Any? ?? NSNull(),
            targetTrackName: NSNull()
        )
        extras["route"] = "logic13_browser"

        func refuse(
            _ error: HonestContract.FailureError,
            _ hint: String,
            _ more: [String: Any] = [:],
            writeAttempted: Bool = false
        ) async -> BrowserInstrumentOutcome {
            let cleanup = await restore()
            return .result(.error(HonestContract.encodeStateC(
                error: error,
                hint: hint,
                extras: extras
                    .merging(more) { _, new in new }
                    .merging(cleanup) { _, new in new }
                    .merging(["write_attempted": writeAttempted]) { _, new in new }
            )))
        }

        // The track first: with Link to selection on, selecting a track can move the Browser's view.
        let index: Int
        if let requested = requestedTrackIndex {
            guard AXLogicProElements.findTrackHeader(at: requested, runtime: runtime) != nil else {
                return await refuse(.elementNotFound, "Track at index \(requested) not found")
            }
            index = requested
            extras["target_track_name"] = AXLogicProElements.trackName(at: index, runtime: runtime) ?? NSNull()
            guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
                return await refuse(.axWriteFailed, "Failed to select track \(index) before instrument load")
            }
            let selectionFields: (String, Any) -> [String: Any] = { reason, observedIndex in
                [
                    "observed": NSNull(),
                    "observed_patch_name": NSNull(),
                    "target_track_selection_verified": false,
                    "target_track_selection_reason": reason,
                    "target_track_selection_observed_index": observedIndex,
                    "target_track_selection_verify_source": "ax_selected",
                ]
            }
            switch await verifyTrackSelection(index: index, runtime: runtime) {
            case .verified:
                break
            case .selectionMetadataUnavailable:
                return await refuse(
                    .trackSelectionFailed,
                    "Track \(index) selection could not be verified before instrument load",
                    selectionFields(HonestContract.UncertainReason.retryExhausted.rawValue, NSNull())
                )
            case .mismatch(let selectedIndex):
                return await refuse(
                    .trackSelectionFailed,
                    "Track \(index) selection settled on a different track before instrument load",
                    selectionFields(
                        HonestContract.UncertainReason.readbackMismatch.rawValue,
                        selectedIndex as Any? ?? NSNull()
                    )
                )
            case .trackDisappeared:
                return await refuse(
                    .elementNotFound,
                    "Track at index \(index) disappeared during selection verification",
                    selectionFields(HonestContract.UncertainReason.readbackUnavailable.rawValue, NSNull())
                )
            }
        } else if let selected = selectedTrackIdentity(runtime: runtime) {
            index = selected.index
            extras["target_track_index"] = index
            extras["target_track_name"] = selected.name ?? NSNull()
        } else {
            return await refuse(.trackSelectionFailed, "No track index was given and no track is selected")
        }

        if let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime) {
            let observedType = AXValueExtractors.extractTrackState(from: header, index: index, runtime: ax).type
            if observedType == .externalMIDI {
                return await refuse(
                    .unsupportedTrackType,
                    externalMIDITargetHint(index: index),
                    ["observed_track_type": observedType.rawValue, "precondition": "wrong_target_type"]
                )
            }
        }

        func observedNames() -> [String] {
            var names: [String] = []
            if let name = AXLogicProElements.trackName(at: index, runtime: runtime) { names.append(name) }
            for name in AXLogicProElements.renderedTrackNames(at: index, runtime: runtime) where !names.contains(name) {
                names.append(name)
            }
            return names
        }
        let alreadyNamed = observedNames().contains(preset)

        guard await clearFilters() else {
            return await refuse(.axWriteFailed, "The Browser's Remove All Active Filters did not clear its filters")
        }
        if let userContent = element({
            AXHelpers.getRole($0, runtime: ax) == (kAXScrollAreaRole as String)
                && AXLocalePolicy.browserUserContentSection.matches(AXHelpers.getDescription($0, runtime: ax))
        }) {
            let locations = AXHelpers.getChildren(userContent, runtime: ax).filter {
                AXHelpers.getRole($0, runtime: ax) == (kAXCheckBoxRole as String)
            }
            for location in locations where browserToggleIsOn(location, runtime: ax) {
                AXHelpers.performAction(location, kAXPressAction as String, runtime: ax)
            }
            guard await settle({ !locations.contains { browserToggleIsOn($0, runtime: ax) } }) else {
                let selected = locations.filter { browserToggleIsOn($0, runtime: ax) }
                    .map { AXHelpers.getDescription($0, runtime: ax) ?? "" }
                return await refuse(
                    .unsupportedState,
                    "A Browser Location stayed selected, which would limit the search to its folder",
                    ["selected_locations": selected]
                )
            }
        }
        guard let instruments = element({
            AXHelpers.getRole($0, runtime: ax) == (kAXCheckBoxRole as String)
                && AXLocalePolicy.browserInstrumentsCategory.matches(AXHelpers.getDescription($0, runtime: ax))
        }) else {
            return await refuse(.elementNotFound, "The Browser's Instruments category was not found")
        }
        if !browserToggleIsOn(instruments, runtime: ax) {
            AXHelpers.performAction(instruments, kAXPressAction as String, runtime: ax)
            guard await settle({ browserToggleIsOn(instruments, runtime: ax) }) else {
                return await refuse(.axWriteFailed, "The Browser's Instruments category did not turn on")
            }
        }
        guard let replace = element({
            AXHelpers.getIdentifier($0, runtime: ax) == browserReplaceOnSelectionIdentifier
        }) else {
            return await refuse(.elementNotFound, "The Browser's Replace on selection toggle was not found")
        }
        let replaceWasOn = browserToggleIsOn(replace, runtime: ax)
        extras["replace_on_selection_was_on"] = replaceWasOn
        if !replaceWasOn {
            AXHelpers.performAction(replace, kAXPressAction as String, runtime: ax)
            guard await settle({ browserToggleIsOn(replace, runtime: ax) }) else {
                return await refuse(.axWriteFailed, "The Browser's Replace on selection did not turn on")
            }
        }

        guard let field = element({
            (AXHelpers.getAttribute($0, kAXSubroleAttribute, runtime: ax) as String?) == (kAXSearchFieldSubrole as String)
        }) else {
            return await refuse(.elementNotFound, "The Browser's search field was not found")
        }
        guard AXHelpers.setAttribute(field, kAXValueAttribute as String, preset as CFString, runtime: ax),
              AXHelpers.performAction(field, kAXConfirmAction as String, runtime: ax) else {
            return await refuse(.axWriteFailed, "The Browser's search field did not accept '\(preset)'")
        }
        let searchApplied = await settle {
            element({
                AXHelpers.getRole($0, runtime: ax) == (kAXButtonRole as String)
                    && AXHelpers.getDescription($0, runtime: ax) == preset
            }) != nil
        }
        guard searchApplied else {
            return await refuse(.readbackUnavailable, "The Browser did not apply the search for '\(preset)'")
        }
        await pause(browserResultsSettleNanoseconds)

        guard let table = element({ AXHelpers.getRole($0, runtime: ax) == (kAXTableRole as String) }) else {
            return await refuse(.elementNotFound, "The Browser's results table was not found")
        }
        let rows = AXHelpers.getChildren(table, runtime: ax).filter {
            AXHelpers.getRole($0, runtime: ax) == (kAXRowRole as String)
        }
        let hits = rows.filter { browserRowName($0, runtime: ax) == preset }
        extras["browser_result_rows"] = rows.count
        extras["browser_exact_matches"] = hits.count
        // Rows show a name and nothing else, so the path's category prefix is not checked.
        extras["category_verified"] = pathSegments.count < 2
        guard hits.count == 1, let row = hits.first else {
            if hits.isEmpty {
                return await refuse(
                    .pathNotInLibrary,
                    "No Browser result in Instruments is named exactly '\(preset)'",
                    ["precondition": "browser_no_exact_match"]
                )
            }
            return await refuse(
                .ambiguousTargetName,
                "\(hits.count) Browser results are named '\(preset)' and rows show no category to tell them apart; nothing was loaded",
                ["precondition": "browser_ambiguous_match"]
            )
        }

        guard AXHelpers.setAttribute(row, kAXSelectedAttribute as String, kCFBooleanTrue, runtime: ax) else {
            return await refuse(
                .axWriteFailed,
                "Selecting the Browser row '\(preset)' was not accepted",
                writeAttempted: true
            )
        }

        var observed = observedNames()
        var polls = 0
        while !observed.contains(preset), polls < browserLoadPolls {
            await pause(browserPollNanoseconds)
            observed = observedNames()
            polls += 1
        }
        let loaded = observed.contains(preset)

        let cleanup = await restore()
        var final = extras.merging(cleanup) { _, new in new }
        let observedName: Any = loaded ? preset : (observed.first ?? NSNull())
        final["observed"] = observedName
        final["observed_patch_name"] = observedName
        final["verify_source"] = "track_name"
        final["write_attempted"] = true
        if requestedTrackIndex != nil {
            final["target_track_selection_verified"] = true
            final["target_track_selection_reason"] = "verified"
            final["target_track_selection_observed_index"] = index
            final["target_track_selection_verify_source"] = "ax_selected"
        }
        if loaded, !alreadyNamed {
            return .result(.success(HonestContract.encodeStateA(
                extras: final.merging(["readback_state": "verified"]) { _, new in new }
            )))
        }
        if loaded {
            // The track had the patch's name before the load, so the name proves nothing.
            return .result(.success(HonestContract.encodeStateB(
                reason: .noopUnobservable,
                extras: final.merging([
                    "readback_state": HonestContract.UncertainReason.noopUnobservable.rawValue,
                    "detail": "track_already_had_patch_name",
                ]) { _, new in new }
            )))
        }
        let reason: HonestContract.UncertainReason = observed.isEmpty ? .readbackUnavailable : .readbackMismatch
        return .result(.success(HonestContract.encodeStateB(
            reason: reason,
            extras: final.merging(["readback_state": reason.rawValue]) { _, new in new }
        )))
    }
}
