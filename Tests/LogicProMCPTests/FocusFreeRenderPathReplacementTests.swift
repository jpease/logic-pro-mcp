@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// The focus-free replacements for the render path's focus-dependent steps. Every route runs under
/// the policy with `refusalObserver` bound: a route that reached a refused poster (activation,
/// typing AppleScript, the CGEvent channel, a synthetic event) would be told to the observer, so
/// an empty observer is the proof that the route needs no focus. No fixture here can reach live
/// Logic: every AX read goes through `FakeAXRuntimeBuilder`, and every AppleScript executor is a
/// recorder that fails.
extension FocusFreeRenderPathTests {
    final class Strings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var current: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// Runs `body` on the render path and returns what it refused along the way.
    static func onRenderPath<T>(_ body: () async -> T) async -> (T, [String]) {
        let refusals = Strings()
        let value = await FocusFreeRenderPath.$isActive.withValue(true) {
            await FocusFreeRenderPath.$refusalObserver.withValue({ refusals.append($0) }) {
                await body()
            }
        }
        return (value, refusals.current)
    }

    static func decode(_ message: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] ?? [:]
    }

    static func failingAppleScript(_ seen: Strings) -> @Sendable (String) async -> ChannelResult {
        { script in
            seen.append(script)
            return .error("AppleScript is not available in this fixture")
        }
    }

    // MARK: - goto_position: control-bar steps

    /// Logic 13.0's arrange window as measured on 2026-11-05: the transport and the Transport
    /// Display live in an `AXToolbar` described `Control Bar`; an `AXGroup` with the same
    /// description holds only the view toggles.
    final class ControlBarFixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        var app: AXUIElement { builder.element(900) }
        var window: AXUIElement { builder.element(901) }
        var toolbar: AXUIElement { builder.element(902) }
        var viewToggles: AXUIElement { builder.element(903) }
        var play: AXUIElement { builder.element(906) }
        var sliders: [TransportPositionComponent: AXUIElement] = [:]
        private let lock = NSLock()
        private var actions: [String] = []
        /// How far one step moves each component; 1 is Logic's behaviour, anything else a fault.
        var stepSize: [TransportPositionComponent: Int] = [:]
        let appleScripts = Strings()

        init(
            values: [TransportPositionComponent: Int],
            playing: Bool = false,
            advertisedActions: [String] = [kAXIncrementAction as String, kAXDecrementAction as String]
        ) {
            let browserToggle = builder.element(904)
            let playGroup = builder.element(905)
            let stop = builder.element(907)
            let displayGroup = builder.element(908)
            let transportDisplay = builder.element(909)
            let playheadPosition = builder.element(910)

            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setChildren(window, [toolbar, viewToggles])
            builder.setRole(toolbar, kAXToolbarRole as String)
            builder.setAttribute(toolbar, kAXDescriptionAttribute as String, "Control Bar")
            builder.setChildren(toolbar, [playGroup, stop, displayGroup])
            builder.setRole(playGroup, kAXGroupRole as String)
            builder.setChildren(playGroup, [play])
            builder.setRole(play, kAXCheckBoxRole as String)
            builder.setAttribute(play, kAXDescriptionAttribute as String, "Play")
            builder.setAttribute(play, kAXValueAttribute as String, playing ? 1 : 0)
            builder.setRole(stop, kAXButtonRole as String)
            builder.setAttribute(stop, kAXDescriptionAttribute as String, "Stop   0")
            builder.setRole(displayGroup, kAXGroupRole as String)
            builder.setChildren(displayGroup, [transportDisplay])
            builder.setRole(transportDisplay, kAXGroupRole as String)
            builder.setAttribute(transportDisplay, kAXDescriptionAttribute as String, "Transport Display")
            builder.setChildren(transportDisplay, [playheadPosition])
            builder.setRole(playheadPosition, kAXGroupRole as String)
            builder.setAttribute(playheadPosition, kAXDescriptionAttribute as String, "Playhead Position")

            builder.setRole(viewToggles, kAXGroupRole as String)
            builder.setAttribute(viewToggles, kAXDescriptionAttribute as String, "Control Bar")
            builder.setChildren(viewToggles, [browserToggle])
            builder.setRole(browserToggle, kAXCheckBoxRole as String)
            builder.setAttribute(browserToggle, kAXDescriptionAttribute as String, "Browser")

            let labels: [TransportPositionComponent: String] = [
                .bar: "bar", .beat: "beat", .subdivision: "division", .tick: "tick",
            ]
            var ordered: [AXUIElement] = []
            for (offset, component) in TransportPositionComponent.allCases.enumerated() {
                guard let value = values[component] else { continue }
                let slider = builder.element(920 + offset)
                builder.setRole(slider, kAXSliderRole as String)
                builder.setAttribute(slider, kAXDescriptionAttribute as String, labels[component]!)
                builder.setAttribute(slider, kAXValueAttribute as String, value)
                builder.setActionNames(slider, advertisedActions)
                sliders[component] = slider
                ordered.append(slider)
            }
            builder.setChildren(playheadPosition, ordered)
        }

        var performedActions: [String] { lock.lock(); defer { lock.unlock() }; return actions }

        func value(_ component: TransportPositionComponent) -> Int? {
            guard let slider = sliders[component] else { return nil }
            return (builder.attributeValue(slider, kAXValueAttribute as String) as? Int)
        }

        func runtime() -> AXLogicProElements.Runtime {
            builder.makeLogicRuntime(
                appElement: app,
                setAttributeHandler: nil,
                performActionHandler: { [self] element, action in
                    guard let component = sliders.first(where: {
                        builder.elementID($0.value) == builder.elementID(element)
                    })?.key, let now = value(component) else { return false }
                    lock.lock(); actions.append("\(component.rawValue):\(action)"); lock.unlock()
                    let step = stepSize[component] ?? 1
                    if action == kAXIncrementAction as String {
                        builder.setAttribute(element, kAXValueAttribute as String, now + step)
                    } else if action == kAXDecrementAction as String {
                        builder.setAttribute(element, kAXValueAttribute as String, now - step)
                    }
                    return true
                },
                executeAppleScript: FocusFreeRenderPathTests.failingAppleScript(appleScripts)
            )
        }
    }

    @Test func logic13ControlBarIsTheToolbarThatHoldsTheTransport() {
        let fixture = ControlBarFixture(values: [.bar: 3, .beat: 2])
        let runtime = fixture.runtime()
        let found = AXLogicProElements.getControlBar(runtime: runtime)
        #expect(found.map { fixture.builder.elementID($0) } == fixture.builder.elementID(fixture.toolbar))
        // The transport read now reaches the Playhead Position sliders; before, it read the view
        // toggles and every goto came back with no observed component.
        let state = AccessibilityChannel.defaultGetTransportState(runtime: runtime)
        let readback = Self.decode(state.message)["positionReadback"] as? [String: Any]
        #expect(readback?["value"] as? String == "3.2")
    }

    @Test func gotoStepsBarAndBeatWithoutFocus() async throws {
        let fixture = ControlBarFixture(values: [.bar: 3, .beat: 2])
        let (result, refusals) = await Self.onRenderPath {
            AccessibilityChannel.gotoPositionViaControlBarSteps(
                params: ["bar": "1"], runtime: fixture.runtime(), sleepMicros: { _ in }
            )
        }
        #expect(refusals.isEmpty)
        #expect(fixture.appleScripts.current.isEmpty)
        #expect(result.isSuccess)
        let payload = Self.decode(result.message)
        // Subdivision and tick are not shown in Beats & Project, so they are not claimed.
        #expect(payload["state"] as? String == "B")
        #expect(payload["observed"] as? String == "1.1")
        #expect(payload["observed_before"] as? String == "3.2")
        #expect(payload["unobserved_position_components"] as? [String] == ["subdivision", "tick"])
        #expect(payload["steps"] as? Int == 3)
        #expect(fixture.performedActions == [
            "bar:AXDecrement", "bar:AXDecrement", "beat:AXDecrement",
        ])
        #expect(fixture.builder.setCalls.isEmpty, "no slider AXValue may be written")
    }

    @Test func gotoWithAllFourComponentsShownIsStateA() async {
        let fixture = ControlBarFixture(values: [.bar: 1, .beat: 1, .subdivision: 3, .tick: 2])
        let (result, refusals) = await Self.onRenderPath {
            AccessibilityChannel.gotoPositionViaControlBarSteps(
                params: ["position": "2.3.1.1"], runtime: fixture.runtime(), sleepMicros: { _ in }
            )
        }
        #expect(refusals.isEmpty)
        let payload = Self.decode(result.message)
        #expect(payload["state"] as? String == "A")
        #expect(payload["observed"] as? String == "2.3.1.1")
        #expect(fixture.value(.bar) == 2 && fixture.value(.beat) == 3)
        #expect(fixture.value(.subdivision) == 1 && fixture.value(.tick) == 1)
    }

    @Test func aStepThatMovesTwoStopsTheWalkAndForbidsFallback() async {
        let fixture = ControlBarFixture(values: [.bar: 5, .beat: 1])
        fixture.stepSize[.bar] = 2
        let (result, _) = await Self.onRenderPath {
            AccessibilityChannel.gotoPositionViaControlBarSteps(
                params: ["bar": "1"], runtime: fixture.runtime(), sleepMicros: { _ in }
            )
        }
        #expect(!result.isSuccess)
        let payload = Self.decode(result.message)
        #expect(payload["error"] as? String == "ax_write_failed")
        #expect(payload["write_attempted"] as? Bool == true)
        #expect(payload["observed"] as? String == "3.1")
        #expect(HonestContract.isFallbackUnsafeStateC(result.message))
        #expect(fixture.performedActions == ["bar:AXDecrement"])
    }

    @Test func aHiddenComponentThatMustMoveIsRefusedBeforeAnyStep() async {
        let fixture = ControlBarFixture(values: [.bar: 3, .beat: 2])
        let (result, _) = await Self.onRenderPath {
            AccessibilityChannel.gotoPositionViaControlBarSteps(
                params: ["position": "1.1.2.1"], runtime: fixture.runtime(), sleepMicros: { _ in }
            )
        }
        let payload = Self.decode(result.message)
        #expect(payload["error"] as? String == "not_supported")
        #expect(payload["write_attempted"] as? Bool == false)
        #expect(fixture.performedActions.isEmpty)
    }

    @Test func gotoIsRefusedWhilePlaying() async {
        let fixture = ControlBarFixture(values: [.bar: 3, .beat: 2], playing: true)
        let (result, _) = await Self.onRenderPath {
            AccessibilityChannel.gotoPositionViaControlBarSteps(
                params: ["bar": "1"], runtime: fixture.runtime(), sleepMicros: { _ in }
            )
        }
        #expect(Self.decode(result.message)["error"] as? String == "unsupported_state")
        #expect(fixture.performedActions.isEmpty)
    }

    @Test func aSliderWithoutStepActionsIsRefusedBeforeAnyStep() async {
        let fixture = ControlBarFixture(values: [.bar: 3, .beat: 2], advertisedActions: [])
        let (result, _) = await Self.onRenderPath {
            AccessibilityChannel.gotoPositionViaControlBarSteps(
                params: ["bar": "1"], runtime: fixture.runtime(), sleepMicros: { _ in }
            )
        }
        let payload = Self.decode(result.message)
        #expect(payload["error"] as? String == "not_supported")
        #expect(payload["missing_action"] as? String == kAXDecrementAction as String)
        #expect(fixture.performedActions.isEmpty)
    }

    @Test func tooManyStepsAreRefusedBeforeAnyStep() async {
        let fixture = ControlBarFixture(values: [.bar: 900, .beat: 1])
        let (result, _) = await Self.onRenderPath {
            AccessibilityChannel.gotoPositionViaControlBarSteps(
                params: ["bar": "1"], runtime: fixture.runtime(), sleepMicros: { _ in }
            )
        }
        #expect(Self.decode(result.message)["planned_steps"] as? Int == 899)
        #expect(fixture.performedActions.isEmpty)
    }

    /// The Accessibility channel takes the stepper on the render path, never the dialog route.
    @Test func theChannelRoutesRenderPathGotoToTheStepper() async {
        let fixture = ControlBarFixture(values: [.bar: 2, .beat: 1])
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true },
            isLogicProRunning: { true },
            hasVisibleWindow: { true },
            logicRuntime: fixture.runtime(),
            controlBarMouseRuntime: Self.refusingMouse,
            trackRenameMouseRuntime: Self.refusingMouse,
            trackToggleKeyRuntime: Self.refusingMouse,
            processRuntime: Self.process(activations: Count()),
            confirmNewTrackDialog: {},
            canPostEvents: { false },
            runTempoFallback: { _ in false }
        ))
        let (result, refusals) = await Self.onRenderPath {
            await channel.execute(operation: "transport.goto_position", params: ["position": "1.1.1.1"])
        }
        #expect(refusals.isEmpty)
        #expect(fixture.appleScripts.current.isEmpty, "the dialog route must not run")
        #expect(Self.decode(result.message)["method"] as? String == "control_bar_steps")
        #expect(fixture.value(.bar) == 1)
    }

    static let refusingMouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in Issue.record("synthetic mouse event"); return false },
        postKeyEvent: { _ in Issue.record("synthetic key event"); return false },
        postUnicodeScalar: { _ in Issue.record("synthetic typing"); return false },
        sleepMicros: { _ in }
    )

    static func process(activations: Count) -> ProcessUtils.Runtime {
        ProcessUtils.Runtime(
            logicProPID: { 4242 },
            fallbackLogicProPID: { 4242 },
            logicProRunning: { true },
            activateLogicPro: { activations.bump(); return true },
            logicIsFrontmost: { false },
            logicProBundleURL: { nil }
        )
    }

    /// One parser for both goto routes; the dialog route's answers are unchanged.
    @Test(arguments: [
        (["bar": "7"], AccessibilityChannel.GotoPositionRequest.position("7.1.1.1")),
        (["bar": "0"], .invalid),
        (["bar": "x", "position": "2.3.4.5"], .position("2.3.4.5")),
        (["position": "01:00:00:00"], .timecode),
        (["position": "2.17.1.1"], .invalid),
        ([:], .invalid),
    ])
    func gotoRequestsParseOnce(_ params: [String: String], _ expected: AccessibilityChannel.GotoPositionRequest) {
        #expect(AccessibilityChannel.gotoPositionRequest(from: params) == expected)
    }

    // MARK: - track delete

    @Test func trackDeletePressesTheMenuItemWithoutFocus() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(940)
        let window = builder.element(941)
        let menuBar = builder.element(942)
        let trackMenu = builder.element(943)
        let deleteItem = builder.element(944)
        let trackList = builder.element(945)
        let first = builder.element(946)
        let second = builder.element(947)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [trackList])
        builder.setRole(trackList, kAXListRole as String)
        builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(trackList, [first, second])
        builder.setRole(first, kAXLayoutItemRole as String)
        builder.setRole(second, kAXLayoutItemRole as String)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [deleteItem])
        builder.setAttribute(deleteItem, kAXTitleAttribute as String, "Delete Track")
        let presses = Count()
        let scripts = Strings()
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                if builder.elementID(element) == builder.elementID(deleteItem), action == kAXPressAction as String {
                    presses.bump()
                    builder.setChildren(trackList, [first])
                }
                return true
            },
            executeAppleScript: Self.failingAppleScript(scripts)
        )
        let (result, refusals) = await Self.onRenderPath {
            await AccessibilityChannel.defaultDeleteTrack(runtime: runtime)
        }
        #expect(refusals.isEmpty)
        #expect(scripts.current.isEmpty)
        #expect(presses.current == 1)
        try #require(result.isSuccess, "\(result.message)")
        #expect(Self.decode(result.message)["verified"] as? Bool == true)
    }

    // MARK: - export_run

    @Test func theBounceHelperIsNotStartedOnTheRenderPath() async {
        let launches = Count()
        let (result, refusals) = await Self.onRenderPath {
            await ProjectExportExecutor.runBounceHelper(
                artifactPath: "/tmp/never/mix.wav",
                executablePath: "/tmp/never/LogicProMCP",
                fileExists: { _ in true },
                runProcess: { _, _, _ in
                    launches.bump()
                    return .spawnFailed("must not launch")
                }
            )
        }
        #expect(launches.current == 0)
        #expect(refusals == [ProjectExportExecutor.bounceHelperFocusAction])
        #expect(result.bounceFired == false)
        #expect(result.error?.hasPrefix(ProjectExportExecutor.focusFreeRenderPathRefusalPrefix) == true)
    }

    @Test func projectsOpenInTheBackgroundOnTheRenderPath() async {
        let url = URL(fileURLWithPath: "/tmp/song.logicx")
        let (background, _) = await Self.onRenderPath {
            AppleScriptSafety.openArguments(for: url, bundleID: "com.apple.logic10")
        }
        #expect(background == ["-g", "-b", "com.apple.logic10", "/tmp/song.logicx"])
        #expect(AppleScriptSafety.openArguments(for: url, bundleID: "com.apple.logic10")
            == ["-b", "com.apple.logic10", "/tmp/song.logicx"])
    }

    // MARK: - set_instrument and record_sequence: refused before anything is touched

    @Test func setInstrumentIsRefusedBeforeTouchingLogic() async {
        let builder = FakeAXRuntimeBuilder()
        let scripts = Strings()
        let runtime = builder.makeLogicRuntime(
            appElement: builder.element(950),
            setAttributeHandler: { _, _, _ in Issue.record("AX write"); return false },
            performActionHandler: { _, _ in Issue.record("AX action"); return false },
            executeAppleScript: Self.failingAppleScript(scripts)
        )
        let staging = AccessibilityChannel.LibraryPanelStaging(
            isPanelOpen: { _ in Issue.record("panel read"); return false },
            openPanel: { _ in Issue.record("panel open") },
            resolvePath: { _ in nil }
        )
        let (result, refusals) = await Self.onRenderPath {
            await AccessibilityChannel.setTrackInstrument(
                params: ["path": "Bass/Sub Bass", "index": "0"],
                runtime: runtime,
                staging: staging,
                canPostEvents: { true }
            )
        }
        #expect(refusals == [AccessibilityChannel.setInstrumentFocusAction])
        #expect(scripts.current.isEmpty)
        let payload = Self.decode(result.message)
        #expect(payload["refused_by"] as? String == "focus_free_render_path")
        #expect(payload["write_attempted"] as? Bool == false)
    }

    @Test func recordSequenceIsRefusedBeforeThePlayheadMoves() async {
        let router = ChannelRouter()
        let ax = MockChannel(id: .accessibility)
        await router.register(ax)
        let cache = StateCache()
        await cache.updateDocumentState(true)
        let (result, refusals) = await Self.onRenderPath {
            await TrackDispatcher.handleRecordSequenceSMF(
                params: ["bar": .int(1), "notes": .string("60,0,480")],
                router: router,
                cache: cache,
                trackHeaderCount: { Issue.record("track read"); return 0 },
                trackNameAt: { _ in nil },
                readRegions: { Issue.record("region read"); return .success([]) },
                settleReadback: {}
            )
        }
        #expect(refusals == [TrackDispatcher.recordSequenceImportFocusAction])
        #expect(await ax.executedOps.isEmpty, "neither goto_position nor the import may be routed")
        #expect(result.isError == true)
    }

    // MARK: - rename readback (Logic 13: the name field's AXValue is "0")

    @Test func renameIsVerifiedByTheHeaderDescriptionOnLogic13() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(960)
        let window = builder.element(961)
        let trackList = builder.element(962)
        let header = builder.element(963)
        let field = builder.element(964)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [trackList])
        builder.setRole(trackList, kAXListRole as String)
        builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(trackList, [header])
        builder.setRole(header, kAXLayoutItemRole as String)
        builder.setAttribute(header, kAXDescriptionAttribute as String, "Track 1 “Studio Grand”")
        builder.setChildren(header, [field])
        builder.setRole(field, kAXTextFieldRole as String)
        builder.setAttribute(field, kAXDescriptionAttribute as String, "Studio Grand")
        builder.setAttribute(field, kAXValueAttribute as String, "0")
        let scripts = Strings()
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { _, _, _ in true },
            performActionHandler: { element, action in
                // Logic commits on confirm and renders the name in the header's description; the
                // field's own description has not caught up yet.
                if builder.elementID(element) == builder.elementID(field), action == kAXConfirmAction as String {
                    builder.setAttribute(header, kAXDescriptionAttribute as String, "Track 1 “Lead”")
                }
                return true
            },
            executeAppleScript: Self.failingAppleScript(scripts)
        )
        let activations = Count()
        let result = AccessibilityChannel.defaultRenameTrack(
            params: ["index": "0", "name": "Lead"],
            runtime: runtime,
            mouseRuntime: Self.refusingMouse,
            processRuntime: Self.process(activations: activations)
        )
        let payload = Self.decode(result.message)
        #expect(payload["state"] as? String == "A")
        #expect(payload["via"] as? String == "ax_set_value")
        #expect(activations.current == 0, "a verified AX rename must not reach the menu route")
        #expect(AXLogicProElements.renderedTrackNames(at: 0, runtime: runtime) == ["Studio Grand", "Lead"])
    }
}
