import Foundation

/// The render path never activates Logic or sends input that lands wherever keyboard focus is.
///
/// Renders run while the owner types in other apps. A synthetic keystroke (CGEvent, or AppleScript
/// `keystroke` / `key code`) goes to whichever app owns the keyboard, and an activation takes the
/// keyboard away from the owner. On 2026-11-05 a render-path session on Logic 13 ended with Logic
/// recording on its own; `R` is Logic's Record key.
///
/// While a render-path command runs, `isActive` is true for its task and every task it starts, and
/// the input primitives refuse instead of acting: `ProcessUtils` activation, `FrontmostGate`
/// activation, AppleScript that types or brings an app forward, the CGEvent channel, and the
/// direct CGEvent posts on those paths. A refused step is a State C `not_supported` with
/// `refused_by: "focus_free_render_path"`, never a silent skip.
enum FocusFreeRenderPath {
    @TaskLocal static var isActive = false

    /// Told every refused action in the current task. A route that replaced a focus-dependent step
    /// is proven focus-free by running it with this bound and seeing it called zero times.
    @TaskLocal static var refusalObserver: (@Sendable (String) -> Void)?

    /// `tool.command` pairs that run under the policy.
    static let commands: Set<String> = [
        "logic_tracks.record_sequence",
        "logic_tracks.set_instrument",
        "logic_tracks.delete",
        "logic_project.get_regions",
        "logic_project.export_run",
        "logic_transport.goto_position",
    ]

    static func covers(tool: String, command: String) -> Bool {
        commands.contains("\(tool).\(command)")
    }

    /// True, and logged, when the current task runs under the policy and must not do `action`.
    static func refuses(_ action: String) -> Bool {
        guard isActive else { return false }
        refusalObserver?(action)
        Log.warn(
            "render path refused \(action): it would take keyboard focus or send keystrokes to the focused app",
            subsystem: "ax"
        )
        return true
    }

    /// AppleScript that types into the focused app or brings an app forward.
    static func scriptNeedsFocus(_ source: String) -> Bool {
        source.range(
            of: #"\b(keystroke|key code|set frontmost|activate)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// The State C answer for a refused step.
    static func refusal(_ action: String) -> String {
        HonestContract.encodeStateC(
            error: .notSupported,
            hint: "The render path does not take keyboard focus or send keystrokes; \(action) needs one, so it was not attempted.",
            extras: [
                "refused_by": "focus_free_render_path",
                "refused_action": action,
                "write_attempted": false,
            ]
        )
    }
}
