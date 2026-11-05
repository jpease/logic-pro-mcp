import ApplicationServices
import Foundation

/// `transport.goto_position` on the render path (`FocusFreeRenderPath`): move the playhead by
/// stepping the control bar's Playhead Position sliders one unit at a time, writing `AXValue` =
/// current ± 1, and reading every component back after every step.
///
/// The Go To Position dialog route needs Logic frontmost and types the position, so the render
/// path cannot use it. Each slider's range is its own value ± 1 (Logic 13.0, read 2026-11-05: bar
/// 106 reports `AXMinValue` 105 and `AXMaxValue` 107) and a write outside it clamps, so a step is
/// one write of the neighbouring value; a write of 3 to bar 106 landed on 105, and on Logic 12.3 a
/// write of 37 moved the playhead one bar (ed3d9c4d). `AXIncrement` is not used: on Logic 13.0 one
/// increment moved the bar slider ten bars. A step is accepted only when the stepped component
/// moved by exactly one in the requested direction and every other visible component stayed put;
/// anything else stops the walk and reports where the playhead is.
///
/// Components the display mode does not show (subdivision and tick in Beats & Project) are not
/// moved and not claimed: the result is State B with them listed as unobserved, and a request
/// that needs one of them moved is refused before any step.
extension AccessibilityChannel {
    /// Upper bound on steps for one request, checked before the first step. Each step is one AX
    /// write plus a readback, so this keeps a request inside the 25 s goto deadline.
    static let controlBarLocateMaxSteps = 400

    static func gotoPositionViaControlBarSteps(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        maxSteps: Int = controlBarLocateMaxSteps,
        settleMicros: UInt32 = 30_000,
        readbackPolls: Int = 5,
        sleepMicros: @Sendable (UInt32) -> Void = { usleep($0) }
    ) -> ChannelResult {
        let requested: String
        switch gotoPositionRequest(from: params) {
        case .position(let position):
            requested = position
        case .timecode:
            return .error(gotoPositionTimecodeRefusal)
        case .invalid:
            return .error(gotoPositionInvalidParams)
        }
        let order = TransportPositionComponent.allCases
        let targetValues = requested.split(separator: ".").compactMap { Int($0) }
        let target = Dictionary(uniqueKeysWithValues: zip(order, targetValues))
        var extras: [String: Any] = [
            "operation": "transport.goto_position",
            "method": "control_bar_steps",
            "requested": requested,
        ]

        func refuse(_ error: HonestContract.FailureError, _ hint: String, _ more: [String: Any] = [:]) -> ChannelResult {
            .error(HonestContract.encodeStateC(
                error: error,
                hint: hint,
                extras: extras.merging(more) { _, new in new }.merging([
                    "write_attempted": false,
                    "safe_to_retry": true,
                ]) { _, new in new }
            ))
        }

        guard let sliders = AXLogicProElements.playheadPositionSliders(runtime: runtime) else {
            return refuse(
                .elementNotFound,
                "The control bar's Playhead Position bar and beat sliders were not found; nothing was touched."
            )
        }
        let driven = order.filter { sliders[$0] != nil }
        let hidden = order.filter { sliders[$0] == nil }
        let hiddenNeedingMove = hidden.filter { target[$0] != 1 }
        guard hiddenNeedingMove.isEmpty else {
            return refuse(
                .notSupported,
                "The control bar's display mode does not show \(hiddenNeedingMove.map(\.rawValue).joined(separator: ", ")), "
                    + "so that part of the position cannot be stepped or read back; nothing was touched.",
                ["hidden_position_components": hidden.map(\.rawValue)]
            )
        }

        // A moving playhead changes the sliders between our reads; every step would look wrong.
        let playing = AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportPlayControl, runtime: runtime
        )
        let recording = AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportRecordControl, runtime: runtime
        )
        guard playing != true, recording != true else {
            return refuse(
                .unsupportedState,
                "Logic is playing or recording, so the playhead cannot be stepped and read back; nothing was touched.",
                ["observed_playing": playing as Any? ?? NSNull(), "observed_recording": recording as Any? ?? NSNull()]
            )
        }

        func read() -> [TransportPositionComponent: Int]? {
            var values: [TransportPositionComponent: Int] = [:]
            for component in driven {
                guard let slider = sliders[component],
                      let value = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax),
                      value == value.rounded()
                else { return nil }
                values[component] = Int(value)
            }
            return values
        }
        func render(_ values: [TransportPositionComponent: Int]) -> String {
            driven.compactMap { values[$0].map(String.init) }.joined(separator: ".")
        }

        guard let before = read() else {
            return refuse(
                .readbackUnavailable,
                "The Playhead Position sliders did not read as whole numbers; nothing was touched."
            )
        }
        extras["observed_before"] = render(before)
        extras["observed_position_components"] = driven.map(\.rawValue)
        extras["unobserved_position_components"] = hidden.map(\.rawValue)

        let plannedSteps = driven.reduce(0) { $0 + abs((target[$1] ?? 0) - (before[$1] ?? 0)) }
        guard plannedSteps <= maxSteps else {
            return refuse(
                .notSupported,
                "Reaching \(requested) from \(render(before)) takes \(plannedSteps) control-bar steps, more than the "
                    + "\(maxSteps) this route takes in one request; nothing was touched.",
                ["planned_steps": plannedSteps]
            )
        }
        for component in driven {
            guard let slider = sliders[component], let goal = target[component], let now = before[component],
                  goal != now else { continue }
            guard AXHelpers.isAttributeSettable(slider, kAXValueAttribute as String, runtime: runtime.ax) == true else {
                return refuse(
                    .notSupported,
                    "The \(component.rawValue) slider's value is not settable; nothing was touched.",
                    ["value_settable": false, "component": component.rawValue]
                )
            }
        }

        var current = before
        var steps = 0
        for component in driven {
            guard let slider = sliders[component], let goal = target[component] else { continue }
            while let now = current[component], now != goal {
                let up = goal > now
                var expected = current
                expected[component] = now + (up ? 1 : -1)
                let accepted = AXHelpers.setAttribute(
                    slider, kAXValueAttribute as String, NSNumber(value: now + (up ? 1 : -1)), runtime: runtime.ax
                )
                steps += 1
                var observed: [TransportPositionComponent: Int]?
                for _ in 0..<max(1, readbackPolls) {
                    sleepMicros(settleMicros)
                    observed = read()
                    if let observed, observed != current { break }
                }
                guard let observed, observed == expected else {
                    // The walk stops at the first step that did not do exactly one unit. The
                    // playhead may have moved, so no later position route may run.
                    return .error(HonestContract.encodeStateC(
                        error: .axWriteFailed,
                        hint: "Control-bar step \(steps) on \(component.rawValue) did not move it by exactly one; "
                            + "the walk stopped. Read the position before retrying.",
                        extras: extras.merging([
                            "steps": steps,
                            "failed_component": component.rawValue,
                            "write_accepted": accepted,
                            "expected": render(expected),
                            "observed": observed.map(render) ?? NSNull(),
                            "write_attempted": true,
                            "safe_to_retry": observed == before,
                            "fallback_unsafe": true,
                        ]) { _, new in new }
                    ))
                }
                current = observed
            }
        }

        extras["observed"] = render(current)
        extras["steps"] = steps
        extras["write_attempted"] = steps > 0
        if steps == 0 { extras["unchanged"] = true }
        // State A needs all four components read; with fewer, what was not shown stays unclaimed.
        if hidden.isEmpty {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
    }
}
