@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// The render path never activates Logic and never posts input that lands wherever keyboard focus
/// is. Each test drives one input primitive under the policy and fails if that primitive reaches its
/// runtime.
struct FocusFreeRenderPathTests {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        var current: Bool? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static let renderPath: [(String, String)] = [
        ("logic_tracks", "record_sequence"),
        ("logic_tracks", "set_instrument"),
        ("logic_tracks", "delete"),
        ("logic_project", "get_regions"),
        ("logic_project", "export_run"),
        ("logic_transport", "goto_position"),
    ]

    @Test(arguments: renderPath)
    func aRenderPathCommandRunsUnderThePolicy(_ tool: String, _ command: String) async {
        let seen = Seen()
        _ = await LogicProServer.runWithDeadline(tool: tool, command: command) {
            seen.set(FocusFreeRenderPath.isActive)
            return toolTextResult("ok")
        }
        #expect(seen.current == true)
    }

    @Test func aCommandOutsideTheRenderPathDoesNot() async {
        let seen = Seen()
        _ = await LogicProServer.runWithDeadline(tool: "logic_tracks", command: "rename") {
            seen.set(FocusFreeRenderPath.isActive)
            return toolTextResult("ok")
        }
        #expect(seen.current == false)
    }

    @Test func activationIsRefused() async {
        let activations = Count()
        let runtime = ProcessUtils.Runtime(
            logicProPID: { 4242 },
            fallbackLogicProPID: { 4242 },
            logicProRunning: { true },
            activateLogicPro: { activations.bump(); return true },
            logicIsFrontmost: { false },
            logicProBundleURL: { nil }
        )
        let activated = FocusFreeRenderPath.$isActive.withValue(true) {
            ProcessUtils.activateLogicPro(runtime: runtime)
        }
        #expect(!activated)
        #expect(activations.current == 0)
        // Outside the render path the same call activates.
        #expect(ProcessUtils.activateLogicPro(runtime: runtime))
        #expect(activations.current == 1)
    }

    @Test func theFrontmostGateDoesNotActivate() {
        let activations = Count()
        let preparation = FocusFreeRenderPath.$isActive.withValue(true) {
            FrontmostGate.prepare(
                isFrontmost: { false },
                activate: { activations.bump(); return true },
                sleepMicros: { _ in }
            )
        }
        #expect(preparation == .activationRefused)
        #expect(activations.current == 0)
    }

    /// The script below is harmless if it runs: the word that makes it need focus is in a comment.
    @Test func anAppleScriptThatTypesIsRefusedWithoutRunning() async throws {
        let script = "-- keystroke\nreturn \"ran\""
        let result = await FocusFreeRenderPath.$isActive.withValue(true) {
            await AppleScriptChannel.executeAppleScript(script)
        }
        #expect(!result.isSuccess)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        #expect(payload["refused_by"] as? String == "focus_free_render_path")
        #expect(payload["write_attempted"] as? Bool == false)
    }

    @Test(arguments: [
        ("tell application \"System Events\" to keystroke \"r\"", true),
        ("tell application \"System Events\" to key code 53", true),
        ("tell process \"Logic Pro\" to set frontmost to true", true),
        ("tell application id \"com.apple.logic10\" to activate", true),
        ("tell application \"System Events\" to click menu item \"Position…\" of menu 1", false),
        ("return value of attribute \"AXRole\" of window 1", false),
    ])
    func scriptsThatNeedFocusAreRecognised(_ script: String, _ needsFocus: Bool) {
        #expect(FocusFreeRenderPath.scriptNeedsFocus(script) == needsFocus)
    }

    @Test func theRouterDoesNotReachTheCGEventChannel() async {
        let router = ChannelRouter()
        let cgEvent = MockChannel(id: .cgEvent)
        await router.register(cgEvent)
        let result = await FocusFreeRenderPath.$isActive.withValue(true) {
            await router.route(operation: "transport.goto_position", params: ["position": "1.1.1.1"])
        }
        #expect(!result.isSuccess)
        #expect(await cgEvent.executedOps.isEmpty)
    }

    @Test func syntheticMouseAndKeyInputIsRefused() {
        let posts = Count()
        let runtime = AXMouseHelper.Runtime(
            postMouseEvent: { _, _, _ in posts.bump(); return true },
            postKeyEvent: { _ in posts.bump(); return true },
            postUnicodeScalar: { _ in posts.bump(); return true },
            sleepMicros: { _ in },
            postFlaggedKeyEvent: { _, _ in posts.bump(); return true }
        )
        FocusFreeRenderPath.$isActive.withValue(true) {
            #expect(!AXMouseHelper.click(at: .zero, runtime: runtime))
            #expect(!AXMouseHelper.doubleClick(at: .zero, runtime: runtime))
            #expect(!AXMouseHelper.typeText("r", runtime: runtime))
            AXMouseHelper.typeNumericString("120", runtime: runtime)
            AXMouseHelper.pressReturn(runtime: runtime)
            AXMouseHelper.pressEscape(runtime: runtime)
        }
        #expect(posts.current == 0)
    }
}
