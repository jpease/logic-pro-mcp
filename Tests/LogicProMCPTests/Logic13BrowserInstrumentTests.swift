@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// `track.set_instrument` through Logic 13's Browser, and track delete's select without activation.
/// Every AX read and write goes through `FakeAXRuntimeBuilder`; every AppleScript executor fails and
/// records; the Library staging records any use as an issue.
struct Logic13BrowserInstrumentTests {
    /// Logic 13.0's arrange window as read on 2026-11-05: a control-bar toolbar holding the Browser
    /// toggle, the track headers, and, while the toggle is on, the Browser panel.
    final class BrowserFixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let lock = NSLock()
        var app: AXUIElement { builder.element(1100) }
        var window: AXUIElement { builder.element(1101) }
        var toolbar: AXUIElement { builder.element(1102) }
        var toggle: AXUIElement { builder.element(1105) }
        var trackList: AXUIElement { builder.element(1103) }
        var headers: [AXUIElement] { [builder.element(1110), builder.element(1111)] }
        var nameFields: [AXUIElement] { [builder.element(1112), builder.element(1113)] }
        var panel: AXUIElement { builder.element(1120) }
        var replace: AXUIElement { builder.element(1123) }
        var field: AXUIElement { builder.element(1124) }
        var instruments: AXUIElement { builder.element(1131) }
        var location: AXUIElement { builder.element(1134) }
        var resultsGroup: AXUIElement { builder.element(1126) }
        var tokens: AXUIElement { builder.element(1135) }
        var token: AXUIElement { builder.element(1138) }
        var removeFilters: AXUIElement { builder.element(1136) }
        var table: AXUIElement { builder.element(1137) }

        /// Search query → result row names, in relevance order.
        let results: [String: [String]]
        let unfilteredRows = ["Studio Grand", "Dusk", "Songwriter"]
        /// Whether pressing the toggle shows a Browser (false is Logic 12's Library toggle).
        let browserAppears: Bool
        /// Whether a selected row renames the selected track, as a load does.
        let loadsPatch: Bool
        let appleScripts = FocusFreeRenderPathTests.Strings()
        private var log: [String] = []
        private var rows: [Int: String] = [:]
        private var nextRowID = 1200
        private var selectedRows: [String] = []

        init(
            browserOpen: Bool,
            browserAppears: Bool = true,
            instrumentsOn: Bool = false,
            replaceOn: Bool = false,
            locationOn: Bool = false,
            leftoverSearch: String? = nil,
            results: [String: [String]],
            loadsPatch: Bool = true
        ) {
            self.results = results
            self.browserAppears = browserAppears
            self.loadsPatch = loadsPatch
            let toggleGroup = builder.element(1104)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setRole(window, kAXWindowRole as String)
            builder.setRole(toolbar, kAXToolbarRole as String)
            builder.setAttribute(toolbar, kAXDescriptionAttribute as String, "Control Bar")
            builder.setChildren(toolbar, [toggleGroup])
            builder.setRole(toggleGroup, kAXGroupRole as String)
            builder.setChildren(toggleGroup, [toggle])
            builder.setRole(toggle, kAXCheckBoxRole as String)
            builder.setAttribute(toggle, kAXIdentifierAttribute as String, AccessibilityChannel.browserToggleIdentifier)
            builder.setAttribute(toggle, kAXDescriptionAttribute as String, "Library")
            builder.setAttribute(toggle, kAXValueAttribute as String, browserOpen ? 1 : 0)

            builder.setRole(trackList, kAXListRole as String)
            builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
            builder.setChildren(trackList, headers)
            for (index, (header, name)) in zip(headers, ["Bass", "Old Piano"]).enumerated() {
                builder.setRole(header, kAXLayoutItemRole as String)
                builder.setAttribute(header, kAXSelectedAttribute as String, index == 0)
                builder.setChildren(header, [nameFields[index]])
                builder.setRole(nameFields[index], kAXTextFieldRole as String)
                builder.setAttribute(nameFields[index], kAXValueAttribute as String, "0")
                rename(index, to: name)
            }

            let hosting = builder.element(1121)
            let content = builder.element(1122)
            let sidebar = builder.element(1125)
            let all = builder.element(1130)
            let userContent = builder.element(1132)
            let disclosure = builder.element(1133)
            builder.setRole(panel, kAXGroupRole as String)
            builder.setAttribute(panel, kAXDescriptionAttribute as String, "Browser")
            builder.setChildren(panel, [hosting])
            builder.setRole(hosting, kAXGroupRole as String)
            builder.setChildren(hosting, [content])
            builder.setRole(content, kAXGroupRole as String)
            builder.setChildren(content, [replace, field, sidebar, resultsGroup])
            builder.setRole(replace, kAXCheckBoxRole as String)
            builder.setAttribute(
                replace, kAXIdentifierAttribute as String, AccessibilityChannel.browserReplaceOnSelectionIdentifier
            )
            builder.setAttribute(replace, kAXValueAttribute as String, replaceOn ? 1 : 0)
            builder.setRole(field, kAXTextFieldRole as String)
            builder.setAttribute(field, kAXSubroleAttribute as String, kAXSearchFieldSubrole as String)
            builder.setAttribute(field, kAXValueAttribute as String, "")
            builder.setRole(sidebar, kAXGroupRole as String)
            builder.setAttribute(sidebar, kAXDescriptionAttribute as String, "Sidebar")
            builder.setChildren(sidebar, [all, instruments, userContent])
            for (box, description, on) in [(all, "All", false), (instruments, "Instruments", instrumentsOn)] {
                builder.setRole(box, kAXCheckBoxRole as String)
                builder.setAttribute(box, kAXDescriptionAttribute as String, description)
                builder.setAttribute(box, kAXValueAttribute as String, on ? 1 : 0)
            }
            builder.setRole(userContent, kAXScrollAreaRole as String)
            builder.setAttribute(userContent, kAXDescriptionAttribute as String, "User Content")
            builder.setChildren(userContent, [disclosure, location])
            builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
            builder.setAttribute(disclosure, kAXDescriptionAttribute as String, "Locations")
            builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
            builder.setRole(location, kAXCheckBoxRole as String)
            builder.setAttribute(location, kAXDescriptionAttribute as String, "midi-location")
            builder.setAttribute(location, kAXValueAttribute as String, locationOn ? 1 : 0)
            builder.setRole(resultsGroup, kAXGroupRole as String)
            builder.setRole(tokens, kAXScrollAreaRole as String)
            builder.setChildren(tokens, [token])
            builder.setRole(token, kAXButtonRole as String)
            builder.setRole(removeFilters, kAXButtonRole as String)
            builder.setAttribute(
                removeFilters, kAXIdentifierAttribute as String, AccessibilityChannel.browserRemoveFiltersIdentifier
            )
            builder.setAttribute(removeFilters, kAXDescriptionAttribute as String, "Remove All Active Filters")
            builder.setRole(table, kAXTableRole as String)
            showResults(query: leftoverSearch)
            showBrowser(browserOpen)
        }

        func rename(_ index: Int, to name: String) {
            builder.setAttribute(headers[index], kAXDescriptionAttribute as String, "Track \(index + 1) “\(name)”")
            builder.setAttribute(nameFields[index], kAXDescriptionAttribute as String, name)
        }

        private func showBrowser(_ shown: Bool) {
            builder.setChildren(window, shown ? [toolbar, trackList, panel] : [toolbar, trackList])
        }

        private func showResults(query: String?) {
            let names: [String]
            if let query {
                builder.setAttribute(token, kAXDescriptionAttribute as String, query)
                builder.setChildren(resultsGroup, [tokens, removeFilters, table])
                names = results[query] ?? []
            } else {
                builder.setChildren(resultsGroup, [table])
                names = unfilteredRows
            }
            var made: [AXUIElement] = []
            for name in names {
                let row = builder.element(nextRowID)
                let cell0 = builder.element(nextRowID + 1)
                let cell1 = builder.element(nextRowID + 2)
                let text = builder.element(nextRowID + 3)
                nextRowID += 4
                builder.setRole(row, kAXRowRole as String)
                builder.setChildren(row, [cell0, cell1])
                builder.setRole(cell0, kAXCellRole as String)
                builder.setRole(cell1, kAXCellRole as String)
                builder.setChildren(cell1, [text])
                builder.setRole(text, kAXStaticTextRole as String)
                builder.setAttribute(text, kAXValueAttribute as String, name)
                rows[builder.elementID(row)] = name
                made.append(row)
            }
            builder.setChildren(table, made)
        }

        func isOn(_ element: AXUIElement) -> Bool {
            (builder.attributeValue(element, kAXValueAttribute as String) as? Int) == 1
        }

        var browserShown: Bool {
            AXHelpers.getChildren(window, runtime: runtime().ax).contains {
                builder.elementID($0) == builder.elementID(panel)
            }
        }

        var actions: [String] { lock.lock(); defer { lock.unlock() }; return log }
        var selectedRowNames: [String] { lock.lock(); defer { lock.unlock() }; return selectedRows }

        private func record(_ entry: String) { lock.lock(); log.append(entry); lock.unlock() }

        private func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
            builder.elementID(a) == builder.elementID(b)
        }

        func runtime() -> AXLogicProElements.Runtime {
            builder.makeLogicRuntime(
                appElement: app,
                setAttributeHandler: { [self] element, attribute, value in
                    if same(element, field), attribute == kAXValueAttribute as String {
                        record("search=\(value as? String ?? "?")")
                        builder.setAttribute(field, kAXValueAttribute as String, value as? String ?? "")
                        return true
                    }
                    if attribute == kAXSelectedAttribute as String, let name = rows[builder.elementID(element)] {
                        record("select-row=\(name)")
                        lock.lock(); selectedRows.append(name); lock.unlock()
                        if loadsPatch, isOn(replace),
                           let target = headers.firstIndex(where: {
                               builder.attributeValue($0, kAXSelectedAttribute as String) as? Bool == true
                           }) {
                            rename(target, to: name)
                        }
                        return true
                    }
                    return false
                },
                performActionHandler: { [self] element, action in
                    if same(element, toggle), action == kAXPressAction as String {
                        record("toggle")
                        let nowOn = !isOn(toggle)
                        builder.setAttribute(toggle, kAXValueAttribute as String, nowOn ? 1 : 0)
                        if browserAppears { showBrowser(nowOn) }
                        return true
                    }
                    if let index = headers.firstIndex(where: { same($0, element) }), action == kAXPressAction as String {
                        record("select-track=\(index)")
                        for (offset, header) in headers.enumerated() {
                            builder.setAttribute(header, kAXSelectedAttribute as String, offset == index)
                        }
                        return true
                    }
                    for (box, name) in [(replace, "replace"), (instruments, "instruments"), (location, "location")]
                    where same(element, box) && action == kAXPressAction as String {
                        record(name)
                        builder.setAttribute(box, kAXValueAttribute as String, isOn(box) ? 0 : 1)
                        return true
                    }
                    if same(element, removeFilters), action == kAXPressAction as String {
                        record("remove-filters")
                        builder.setAttribute(field, kAXValueAttribute as String, "")
                        showResults(query: nil)
                        return true
                    }
                    if same(element, field), action == kAXConfirmAction as String {
                        record("confirm")
                        let query = builder.attributeValue(field, kAXValueAttribute as String) as? String ?? ""
                        builder.setAttribute(field, kAXValueAttribute as String, "")
                        showResults(query: query)
                        return true
                    }
                    record("unexpected \(action)")
                    return false
                },
                executeAppleScript: FocusFreeRenderPathTests.failingAppleScript(appleScripts)
            )
        }
    }

    static let recordingStaging = AccessibilityChannel.LibraryPanelStaging(
        isPanelOpen: { _ in Issue.record("Library panel read"); return false },
        openPanel: { _ in Issue.record("Library panel open") },
        resolvePath: { _ in nil }
    )

    static func load(
        _ fixture: BrowserFixture,
        path: String = "Piano/Studio Grand",
        index: Int = 1
    ) async -> (ChannelResult, [String]) {
        await FocusFreeRenderPathTests.onRenderPath {
            await AccessibilityChannel.setTrackInstrument(
                params: ["path": path, "index": String(index)],
                runtime: fixture.runtime(),
                staging: recordingStaging,
                canPostEvents: { Issue.record("event-post preflight"); return false },
                browserPause: { _ in }
            )
        }
    }

    static func decode(_ message: String) -> [String: Any] {
        FocusFreeRenderPathTests.decode(message)
    }

    @Test func loadsThePatchOnTheSelectedTrackAndPutsTheBrowserBack() async throws {
        let fixture = BrowserFixture(
            browserOpen: false,
            locationOn: true,
            leftoverSearch: "Dusk",
            results: ["Studio Grand": ["Soft Cinematic", "Studio Grand", "Studio Grand Bright"]]
        )
        let (result, refusals) = await Self.load(fixture)
        #expect(refusals.isEmpty, "the Browser route needs no focus")
        #expect(fixture.appleScripts.current.isEmpty)
        try #require(result.isSuccess, "\(result.message)")
        let payload = Self.decode(result.message)
        #expect(payload["state"] as? String == "A")
        #expect(payload["verified"] as? Bool == true)
        #expect(payload["route"] as? String == "logic13_browser")
        #expect(payload["observed_patch_name"] as? String == "Studio Grand")
        #expect(payload["verify_source"] as? String == "track_name")
        #expect(payload["target_track_selection_verified"] as? Bool == true)
        #expect(payload["category_verified"] as? Bool == false)
        #expect(payload["browser_was_open"] as? Bool == false)
        #expect(payload["browser_restored"] as? Bool == true)
        #expect(payload["browser_filters_cleared"] as? Bool == true)
        #expect(fixture.selectedRowNames == ["Studio Grand"])
        #expect(AXLogicProElements.renderedTrackNames(at: 1, runtime: fixture.runtime()).contains("Studio Grand"))
        #expect(AXLogicProElements.renderedTrackNames(at: 0, runtime: fixture.runtime()).contains("Bass"))
        // Track first, then filters, Location, category and Replace on selection, then the search.
        #expect(fixture.actions == [
            "toggle", "select-track=1", "remove-filters", "location", "instruments", "replace",
            "search=Studio Grand", "confirm", "select-row=Studio Grand", "remove-filters", "toggle",
        ])
        #expect(!fixture.browserShown)
        #expect(!fixture.isOn(fixture.location))
        #expect(fixture.isOn(fixture.instruments) && fixture.isOn(fixture.replace))
    }

    @Test func twoRowsWithTheExactNameAreRefusedAndNothingLoads() async {
        let fixture = BrowserFixture(
            browserOpen: true,
            instrumentsOn: true,
            replaceOn: true,
            results: ["Studio Grand": ["Studio Grand", "Studio Grand"]]
        )
        let (result, _) = await Self.load(fixture, path: "Guitar/Studio Grand")
        #expect(!result.isSuccess)
        let payload = Self.decode(result.message)
        #expect(payload["error"] as? String == "ambiguous_target_name")
        #expect(payload["browser_exact_matches"] as? Int == 2)
        #expect(payload["write_attempted"] as? Bool == false)
        #expect(fixture.selectedRowNames.isEmpty)
        // It was open, so it stays open; the search it made is cleared.
        #expect(fixture.browserShown)
        #expect(fixture.actions.last == "remove-filters")
        #expect(!fixture.actions.contains("toggle"))
    }

    @Test func noRowWithTheExactNameIsRefused() async {
        let fixture = BrowserFixture(
            browserOpen: false,
            results: ["Studio Grand": ["Studio Grand Bright"]]
        )
        let (result, _) = await Self.load(fixture)
        let payload = Self.decode(result.message)
        #expect(payload["error"] as? String == "path_not_in_library")
        #expect(payload["precondition"] as? String == "browser_no_exact_match")
        #expect(fixture.selectedRowNames.isEmpty)
        #expect(!fixture.browserShown)
        #expect(payload["browser_restored"] as? Bool == true)
    }

    @Test func aLoadTheTrackNameNeverShowsIsStateB() async {
        let fixture = BrowserFixture(
            browserOpen: false,
            results: ["Studio Grand": ["Studio Grand"]],
            loadsPatch: false
        )
        let (result, _) = await Self.load(fixture)
        #expect(result.isSuccess)
        let payload = Self.decode(result.message)
        #expect(payload["state"] as? String == "B")
        #expect(payload["verified"] as? Bool == false)
        #expect(payload["write_attempted"] as? Bool == true)
        #expect(payload["observed_patch_name"] as? String == "Old Piano")
        #expect(!fixture.browserShown)
    }

    /// A control-bar Library toggle that shows no Browser is Logic 12's: the toggle is put back and
    /// the Library route runs, which the render path refuses before touching anything.
    @Test func aToggleThatShowsNoBrowserFallsBackToTheLibraryRoute() async {
        let fixture = BrowserFixture(
            browserOpen: false,
            browserAppears: false,
            results: [:]
        )
        let (result, refusals) = await Self.load(fixture)
        #expect(fixture.actions == ["toggle", "toggle"])
        #expect(!fixture.isOn(fixture.toggle))
        #expect(refusals == [AccessibilityChannel.setInstrumentFocusAction])
        #expect(Self.decode(result.message)["refused_by"] as? String == "focus_free_render_path")
    }

    // MARK: - track delete's select

    static func headersOnly() -> (FakeAXRuntimeBuilder, AXLogicProElements.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1300)
        let window = builder.element(1301)
        let list = builder.element(1302)
        let headers = [builder.element(1303), builder.element(1304)]
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [list])
        builder.setRole(list, kAXListRole as String)
        builder.setAttribute(list, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(list, headers)
        for header in headers {
            builder.setRole(header, kAXLayoutItemRole as String)
            builder.setAttribute(header, kAXSelectedAttribute as String, false)
        }
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { _, _, _ in false },
            performActionHandler: { element, action in
                guard action == kAXPressAction as String else { return false }
                for header in headers {
                    builder.setAttribute(
                        header, kAXSelectedAttribute as String,
                        builder.elementID(header) == builder.elementID(element)
                    )
                }
                return true
            },
            executeAppleScript: { _ in .error("AppleScript is not available in this fixture") }
        )
        return (builder, runtime)
    }

    @Test func aSelectAskedNotToActivateDoesNot() async {
        let (_, runtime) = Self.headersOnly()
        let activations = FocusFreeRenderPathTests.Count()
        let result = await AccessibilityChannel.defaultSelectTrack(
            params: ["index": "1", AccessibilityChannel.selectActivateParam: "false"],
            runtime: runtime,
            processRuntime: FocusFreeRenderPathTests.process(activations: activations)
        )
        #expect(activations.current == 0)
        #expect(Self.decode(result.message)["state"] as? String == "A")
    }

    @Test func anOrdinarySelectStillActivates() async {
        let (_, runtime) = Self.headersOnly()
        let activations = FocusFreeRenderPathTests.Count()
        _ = await AccessibilityChannel.defaultSelectTrack(
            params: ["index": "1"],
            runtime: runtime,
            processRuntime: FocusFreeRenderPathTests.process(activations: activations)
        )
        #expect(activations.current == 1)
    }
}
