import Foundation
import MCP
import Testing
@testable import LogicProMCP

// `midi.import_file` is the irreversible step of `record_sequence`: once the
// import script clicks File > Import > MIDI File, Logic creates a track and a
// region. `LogicProServer.runWithDeadline` answers a timed-out request with
// `operation_timeout` and cancels the work task, but cancellation is
// cooperative. Before this suite, nothing on the import path read it, so a
// request whose deadline fired during the slow pre-import AX reads still went
// on to run the import after the caller had been told the request was over.

@Suite("midi.import_file stops at cancellation before the import script")
struct MIDIImportCancellationTests {
    private final class ScriptSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func run() -> ChannelResult {
            lock.lock()
            count += 1
            lock.unlock()
            return .success("OK")
        }
    }

    private final class CompletionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ChannelResult?

        var result: ChannelResult? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func store(_ result: ChannelResult) {
            lock.lock()
            stored = result
            lock.unlock()
        }
    }

    private func fixture() throws -> SMFWriter.TemporaryMIDIFile {
        let tempFile = try SMFWriter.temporaryMIDIFile()
        try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile.fileURL)
        return tempFile
    }

    private func json(_ message: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] ?? [:]
    }

    @Test("cancellation during the pre-import reads stops the import script from running")
    func cancelledDuringPreImportReadsDoesNotRunScript() async throws {
        let file = try fixture()
        defer { SMFWriter.cleanupTemporaryMIDIFile(file) }
        let spy = ScriptSpy()
        let path = file.fileURL.path

        let result = await Task {
            await AccessibilityChannel.defaultImportMIDIFile(
                systemEventsAuthorized: { true },
                path: path,
                executeScript: { _ in spy.run() },
                // The before-count read is where the request's deadline lands on
                // a slow session; cancel the running task from inside it.
                trackCount: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 4
                },
                trackNames: { [] },
                regionInfos: { .success([], complete: false) },
                deltaPoll: {}
            )
        }.value

        #expect(spy.calls == 0)
        #expect(!result.isSuccess)
        let body = json(result.message)
        #expect(body["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
        #expect(body["failure_stage"] as? String == "before_import_script")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(body["track_count_before"] as? Int == 4)
    }

    @Test("an uncancelled import still runs the script exactly once")
    func uncancelledImportRunsScript() async throws {
        let file = try fixture()
        defer { SMFWriter.cleanupTemporaryMIDIFile(file) }
        let spy = ScriptSpy()

        _ = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: file.fileURL.path,
            executeScript: { _ in spy.run() },
            trackCount: { 4 },
            trackNames: { [] },
            regionInfos: { .success([], complete: false) },
            deltaPoll: {}
        )

        #expect(spy.calls == 1)
    }

    @Test("a record_sequence request abandoned at its deadline does not import afterwards")
    func abandonedRequestDoesNotImportAfterDeadline() async throws {
        let file = try fixture()
        defer { SMFWriter.cleanupTemporaryMIDIFile(file) }
        let spy = ScriptSpy()
        let probe = CompletionProbe()
        let path = file.fileURL.path

        let reply = await LogicProServer.runWithDeadline(
            tool: ToolID.logicTracks.rawValue,
            command: "record_sequence",
            deadlineOverride: 0.05
        ) {
            let result = await AccessibilityChannel.defaultImportMIDIFile(
                systemEventsAuthorized: { true },
                path: path,
                executeScript: { _ in spy.run() },
                trackCount: { 4 },
                trackNames: { [] },
                // A pre-import region read that outlives the deadline, as a
                // large arrangement does on a busy Logic session.
                regionInfos: {
                    Thread.sleep(forTimeInterval: 0.4)
                    return .success([], complete: false)
                },
                deltaPoll: {}
            )
            probe.store(result)
            return toolTextResult(result.message, isError: !result.isSuccess)
        }

        #expect(json(sharedToolText(reply))["error"] as? String == "operation_timeout")

        let deadline = ContinuousClock.now + .seconds(5)
        while probe.result == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let abandoned = try #require(probe.result)
        #expect(spy.calls == 0)
        #expect(json(abandoned.message)["failure_stage"] as? String == "before_import_script")
    }
}
