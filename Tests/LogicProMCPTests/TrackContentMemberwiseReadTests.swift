@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Logic 13's Track Content group: one lane per track, and an `AXChildren` read that fails as a
/// whole (-25200) when one member cannot be vended.
///
/// Measured on Logic 13.0, 2026-11-05: 9 children by count, `AXChildren` -> -25200, and read index
/// by index 7 members (AXLayoutArea lanes holding the AXLayoutItem regions, and AXButton
/// automation lanes) with 2 indices failing. Read as a whole, a project with three regions
/// reported none, and `record_sequence` refused an import whose region was there.
struct TrackContentMemberwiseReadTests {
    static let failure = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)

    struct Fixture {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let content: AXUIElement
        let regions: [AXUIElement]
        /// Index of the content member that does not read on its own, if any.
        let unreadableIndex: Int?

        init(unreadableIndex: Int?) {
            self.unreadableIndex = unreadableIndex
            app = builder.element(1)
            window = builder.element(2)
            let headerRail = builder.element(3)
            content = builder.element(4)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXPositionAttribute as String, axPoint(0, 0))
            builder.setAttribute(window, kAXSizeAttribute as String, axSize(1_200, 800))
            builder.setChildren(window, [headerRail, content])

            builder.setRole(headerRail, kAXGroupRole as String)
            builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "Tracks header")
            builder.setRole(content, kAXGroupRole as String)
            builder.setAttribute(content, kAXDescriptionAttribute as String, "Tracks contents")

            var headers: [AXUIElement] = []
            var members: [AXUIElement] = []
            var regions: [AXUIElement] = []
            for track in 0..<3 {
                let y = CGFloat(100 + track * 60)
                let header = builder.element(10 + track)
                builder.setRole(header, kAXLayoutItemRole as String)
                builder.setAttribute(header, kAXPositionAttribute as String, axPoint(0, y))
                builder.setAttribute(header, kAXSizeAttribute as String, axSize(200, 40))
                headers.append(header)

                let lane = builder.element(20 + track)
                let region = builder.element(30 + track)
                builder.setRole(lane, "AXLayoutArea")
                builder.setRole(region, kAXLayoutItemRole as String)
                builder.setAttribute(region, kAXDescriptionAttribute as String, "MIDI Region")
                builder.setAttribute(
                    region, kAXHelpAttribute as String,
                    "Region starts at \(track + 1) bars and ends at \(track + 2) bars, MIDI region."
                )
                builder.setAttribute(region, kAXPositionAttribute as String, axPoint(240, y + 8))
                builder.setAttribute(region, kAXSizeAttribute as String, axSize(120, 24))
                builder.setChildren(lane, [region])
                regions.append(region)

                let automation = builder.element(40 + track)
                builder.setRole(automation, kAXButtonRole as String)
                members += [lane, automation]
            }
            builder.setChildren(headerRail, headers)
            builder.setChildren(content, members)
            self.regions = regions
        }

        func runtime() -> AXLogicProElements.Runtime {
            let content = content
            let unreadableIndex = unreadableIndex
            return builder.makeLogicRuntime(
                appElement: app,
                childrenHandler: { element in element == content ? [] : nil },
                childrenResultHandler: { element in element == content ? .failure(Self.failureStatus) : nil },
                setAttributeHandler: nil,
                performActionHandler: nil,
                childAtIndexResultHandler: { element, index in
                    element == content && index == unreadableIndex ? .failure(Self.failureStatus) : nil
                }
            )
        }

        static let failureStatus = TrackContentMemberwiseReadTests.failure
    }

    @Test func regionsAreReadFromTheLanesWhenTheWholeListFails() throws {
        let fixture = Fixture(unreadableIndex: nil)
        let result = try AccessibilityChannel.enumerateRegionItems(runtime: fixture.runtime()).get()

        #expect(result.regions.map(\.item) == fixture.regions)
        #expect(result.regions.map(\.info.trackIndex) == [0, 1, 2])
        #expect(result.regions.map(\.info.startBar) == [1, 2, 3])
        #expect(result.unreadableContentMembers == 0)
        #expect(result.coversWholeArrangement)
    }

    /// A member that does not read may be a lane with a region in it, so the read is not complete,
    /// and the inventory says how many members were missing.
    @Test func anUnreadableMemberMakesTheReadIncomplete() throws {
        let fixture = Fixture(unreadableIndex: 3)
        let result = try AccessibilityChannel.enumerateRegionItems(runtime: fixture.runtime()).get()

        #expect(result.regions.map(\.item) == fixture.regions)
        #expect(result.unreadableContentMembers == 1)
        #expect(!result.coversWholeArrangement)

        let message = AccessibilityChannel.defaultGetRegions(runtime: fixture.runtime()).message
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        #expect(payload["complete"] as? Bool == false)
        #expect(payload["returned_count"] as? Int == 3)
        let debug = try #require(payload["_debug"] as? [String: Any])
        #expect(debug["unreadable_content_members"] as? Int == 1)
    }

    @Test func aReadableListIsTakenAsItIs() throws {
        let builder = FakeAXRuntimeBuilder()
        let parent = builder.element(1)
        let members = [builder.element(2), builder.element(3)]
        builder.setChildren(parent, members)
        let read = try AXHelpers.childrenMemberwise(parent, runtime: builder.makeAXRuntime()).get()
        #expect(read.members == members)
        #expect(read.unreadable == 0)
    }

    /// Only -25200 is read member by member. An absence is an empty list; any other failure is the
    /// caller's to handle.
    @Test(arguments: [
        (AXError.noValue, true),
        (AXError.attributeUnsupported, true),
        (AXError.cannotComplete, false),
        (AXError.invalidUIElement, false),
    ])
    func otherStatusesAreNotReadMemberByMember(_ status: AXError, _ readsAsEmpty: Bool) {
        let builder = FakeAXRuntimeBuilder()
        let parent = builder.element(1)
        builder.setChildren(parent, [builder.element(2)])
        let error = AXHelpers.AXStatusError(raw: status.rawValue)
        let runtime = builder.makeAXRuntime(
            childrenResultHandler: { _ in .failure(error) },
            setAttributeHandler: nil,
            performActionHandler: nil,
            childAtIndexResultHandler: { _, _ in
                Issue.record("a \(status.rawValue) read must not be retried member by member")
                return nil
            }
        )
        switch AXHelpers.childrenMemberwise(parent, runtime: runtime) {
        case let .success(read):
            #expect(readsAsEmpty)
            #expect(read.members.isEmpty)
            #expect(read.unreadable == 0)
        case let .failure(returned):
            #expect(!readsAsEmpty)
            #expect(returned == error)
        }
    }
}
