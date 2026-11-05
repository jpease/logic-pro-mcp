@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// What a descendant walk from the arrange window leaves out.
///
/// Logic Pro 13's Browser is a direct child of the arrange window, and its results table vends every
/// result as a row: 6,219 children, 53 of them on screen, measured on 13.0 with the Instruments
/// filter. Reading those rows took longer than any tool deadline, so a walk from the window skips the
/// Browser panel, and no walk descends into a table or outline longer than
/// `AXHelpers.walkRowContainerLimit` that it merely passes through.
struct WalkThroughRowContainerTests {
    /// Every element whose attributes, or whose children, a walk read, by builder id.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var attributes: Set<Int> = []
        private var children: Set<Int> = []

        func recordAttribute(_ id: Int) {
            lock.lock(); defer { lock.unlock() }
            attributes.insert(id)
        }

        func recordChildren(_ id: Int) {
            lock.lock(); defer { lock.unlock() }
            children.insert(id)
        }

        func readAttributes(ofAny ids: [Int]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !attributes.isDisjoint(with: ids)
        }

        func readChildren(ofAny ids: [Int]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !children.isDisjoint(with: ids)
        }
    }

    final class Tree {
        let builder = FakeAXRuntimeBuilder()
        let reads = Reads()
        let app: AXUIElement
        let window: AXUIElement

        init() {
            app = builder.element(1)
            window = builder.element(2)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setRole(window, kAXWindowRole as String)
        }

        func ids(_ elements: [AXUIElement]) -> [Int] { elements.map(builder.elementID) }

        /// `container` holding `count` rows, each row -> cell -> button. Returns the rows' subtree
        /// elements and the buttons, in row order.
        func fill(
            _ container: AXUIElement,
            role: String,
            rows count: Int,
            baseID: Int
        ) -> (subtree: [AXUIElement], buttons: [AXUIElement]) {
            builder.setRole(container, role)
            var subtree: [AXUIElement] = []
            var rows: [AXUIElement] = []
            var buttons: [AXUIElement] = []
            for index in 0..<count {
                let row = builder.element(baseID + index)
                let cell = builder.element(baseID + 10_000 + index)
                let button = builder.element(baseID + 20_000 + index)
                builder.setRole(row, kAXRowRole as String)
                builder.setRole(cell, kAXCellRole as String)
                builder.setRole(button, kAXButtonRole as String)
                builder.setAttribute(button, kAXTitleAttribute as String, "Result \(index)")
                builder.setChildren(row, [cell])
                builder.setChildren(cell, [button])
                rows.append(row)
                subtree += [row, cell, button]
                buttons.append(button)
            }
            builder.setChildren(container, rows)
            return (subtree, buttons)
        }

        func logicRuntime(
            attributeResult: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?)? = nil
        ) -> AXLogicProElements.Runtime {
            let reads = reads
            let builder = builder
            return builder.makeLogicRuntime(
                appElement: app,
                attributeValueHandler: { element, _ in
                    reads.recordAttribute(builder.elementID(element))
                    return nil
                },
                attributeValueResultHandler: { element, attribute in
                    reads.recordAttribute(builder.elementID(element))
                    return attributeResult?(element, attribute)
                },
                childrenHandler: { element in
                    reads.recordChildren(builder.elementID(element))
                    return nil
                },
                childrenResultHandler: { element in
                    reads.recordChildren(builder.elementID(element))
                    return nil
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            )
        }

        func runtime() -> AXHelpers.Runtime { logicRuntime().ax }
    }

    /// window -> group -> container(rows) -> row -> cell -> button.
    static func tableTree(
        rows count: Int,
        role: String = kAXTableRole as String
    ) -> (tree: Tree, container: AXUIElement, subtree: [AXUIElement], buttons: [AXUIElement]) {
        let tree = Tree()
        let group = tree.builder.element(3)
        let container = tree.builder.element(4)
        tree.builder.setRole(group, kAXGroupRole as String)
        tree.builder.setChildren(tree.window, [group])
        tree.builder.setChildren(group, [container])
        let filled = tree.fill(container, role: role, rows: count, baseID: 1_000)
        return (tree, container, filled.subtree, filled.buttons)
    }

    /// The walkers a lookup from the arrange window goes through, each answering the buttons it found.
    enum Walker: String, CaseIterable, CustomStringConvertible {
        case findAllDescendants, censusDescendant, censusDescendantResult, findDescendant

        var description: String { rawValue }

        func buttons(under root: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement] {
            let role = kAXButtonRole as String
            switch self {
            case .findAllDescendants:
                return AXHelpers.findAllDescendants(of: root, role: role, maxDepth: 8, runtime: runtime)
            case .censusDescendant:
                return AXHelpers.censusDescendant(of: root, role: role, maxDepth: 8, runtime: runtime).matches
            case .censusDescendantResult:
                let census = try? AXHelpers.censusDescendantResult(
                    of: root, role: role, maxDepth: 8, runtime: runtime
                ).get()
                return census?.matches ?? []
            case .findDescendant:
                return AXHelpers.findDescendant(of: root, role: role, maxDepth: 8, runtime: runtime).map { [$0] } ?? []
            }
        }

        /// What this walker answers when `all` are the matches in traversal order.
        func expected(_ all: [AXUIElement]) -> [AXUIElement] {
            self == .findDescendant ? Array(all.prefix(1)) : all
        }
    }

    // MARK: - Long tables and outlines

    @Test(arguments: Walker.allCases)
    func aWalkThroughALongTableDoesNotReadItsRows(_ walker: Walker) {
        let (tree, _, subtree, _) = Self.tableTree(rows: AXHelpers.walkRowContainerLimit + 1)
        #expect(walker.buttons(under: tree.window, runtime: tree.runtime()).isEmpty)
        #expect(!tree.reads.readAttributes(ofAny: tree.ids(subtree)))
        #expect(!tree.reads.readChildren(ofAny: tree.ids(subtree)))
    }

    @Test func aLongOutlineIsALeafLikeATable() {
        let (tree, _, subtree, _) = Self.tableTree(
            rows: AXHelpers.walkRowContainerLimit + 1, role: kAXOutlineRole as String
        )
        #expect(Walker.findAllDescendants.buttons(under: tree.window, runtime: tree.runtime()).isEmpty)
        #expect(!tree.reads.readAttributes(ofAny: tree.ids(subtree)))
    }

    /// A caller that asks for a table's contents gets all of them; only a table the walk passes
    /// through is left out.
    @Test(arguments: Walker.allCases)
    func aWalkRootedAtALongTableReadsEveryRow(_ walker: Walker) {
        let (tree, table, _, buttons) = Self.tableTree(rows: AXHelpers.walkRowContainerLimit + 1)
        #expect(walker.buttons(under: table, runtime: tree.runtime()) == walker.expected(buttons))
    }

    @Test(arguments: Walker.allCases)
    func aTableAtTheLimitIsWalkedInFull(_ walker: Walker) {
        let (tree, _, _, buttons) = Self.tableTree(rows: AXHelpers.walkRowContainerLimit)
        #expect(walker.buttons(under: tree.window, runtime: tree.runtime()) == walker.expected(buttons))
    }

    /// Track headers and Mixer strips sit in groups and layout areas, not row containers: a project
    /// with more tracks than the limit is still read in full.
    @Test func aLongGroupIsWalkedInFull() {
        let (tree, _, _, buttons) = Self.tableTree(
            rows: AXHelpers.walkRowContainerLimit + 1, role: kAXGroupRole as String
        )
        #expect(Walker.findAllDescendants.buttons(under: tree.window, runtime: tree.runtime()) == buttons)
    }

    /// The status-preserving census reports a failed role read on a long container instead of
    /// guessing whether it is a table. Matching by title alone, so the prune is the only reader of
    /// the container's role.
    @Test func theStatusPreservingCensusReportsAnUnreadableRoleOnALongContainer() {
        let (tree, table, _, _) = Self.tableTree(rows: AXHelpers.walkRowContainerLimit + 1)
        let failure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let result = AXHelpers.censusDescendantResult(
            of: tree.window,
            title: "Result 0",
            maxDepth: 8,
            runtime: tree.logicRuntime(attributeResult: { element, attribute in
                element == table && attribute == kAXRoleAttribute as String ? .failure(failure) : nil
            }).ax
        )
        guard case let .failure(error) = result else {
            Issue.record("expected the census to fail, got \(result)")
            return
        }
        #expect(error == failure)
    }

    // MARK: - The Browser panel

    /// window -> [Browser panel -> short table -> rows, Tracks group -> button].
    static func browserTree(
        browserDescription: String
    ) -> (tree: Tree, browser: AXUIElement, browserSubtree: [AXUIElement], tracksButton: AXUIElement) {
        let tree = Tree()
        let builder = tree.builder
        let browser = builder.element(3)
        let results = builder.element(4)
        let tracks = builder.element(5)
        let tracksButton = builder.element(6)
        builder.setRole(browser, kAXGroupRole as String)
        builder.setAttribute(browser, kAXDescriptionAttribute as String, browserDescription)
        builder.setChildren(browser, [results])
        let filled = tree.fill(results, role: kAXTableRole as String, rows: 3, baseID: 1_000)
        builder.setRole(tracks, kAXGroupRole as String)
        builder.setAttribute(tracks, kAXDescriptionAttribute as String, "Tracks")
        builder.setRole(tracksButton, kAXButtonRole as String)
        builder.setChildren(tracks, [tracksButton])
        builder.setChildren(tree.window, [browser, tracks])
        return (tree, browser, [results] + filled.subtree, tracksButton)
    }

    static let browserCases: [(Walker, String)] = Walker.allCases.flatMap { walker in
        ["Browser", "브라우저", "Navigateur"].map { (walker, $0) }
    }

    @Test(arguments: browserCases)
    func aWalkFromTheWindowSkipsTheBrowserPanel(_ walker: Walker, _ description: String) {
        let (tree, browser, browserSubtree, tracksButton) = Self.browserTree(browserDescription: description)
        #expect(walker.buttons(under: tree.window, runtime: tree.runtime()) == [tracksButton])
        #expect(!tree.reads.readChildren(ofAny: tree.ids([browser] + browserSubtree)))
        #expect(!tree.reads.readAttributes(ofAny: tree.ids(browserSubtree)))
    }

    /// Only the window's own Browser panel is skipped. A walk that starts inside the Browser, or a
    /// group with that name further down, is walked like anything else.
    @Test func aWalkRootedAtTheBrowserPanelReadsIt() {
        let (tree, browser, _, _) = Self.browserTree(browserDescription: "Browser")
        #expect(Walker.findAllDescendants.buttons(under: browser, runtime: tree.runtime()).count == 3)
    }

    @Test func aBrowserNamedGroupBelowTheWindowIsWalked() {
        let (tree, browser, _, tracksButton) = Self.browserTree(browserDescription: "Browser")
        let outer = tree.builder.element(7)
        tree.builder.setRole(outer, kAXGroupRole as String)
        tree.builder.setChildren(outer, [browser])
        tree.builder.setChildren(tree.window, [outer, tree.builder.element(5)])
        let found = Walker.findAllDescendants.buttons(under: tree.window, runtime: tree.runtime())
        #expect(found.count == 4)
        #expect(found.last == tracksButton)
    }

    // MARK: - The Mixer search

    /// The poller's Mixer search walks the whole arrange window. On Logic 13 it held the
    /// Accessibility actor for minutes reading the Browser's rows.
    @Test func theMixerLookupReadsNeitherTheBrowserNorALongTable() throws {
        let (tree, browser, browserSubtree, _) = Self.browserTree(browserDescription: "Browser")
        let builder = tree.builder
        let listHolder = builder.element(8)
        let longTable = builder.element(9)
        builder.setRole(listHolder, kAXGroupRole as String)
        builder.setChildren(listHolder, [longTable])
        let long = tree.fill(
            longTable, role: kAXTableRole as String, rows: AXHelpers.walkRowContainerLimit + 1, baseID: 50_000
        )
        let mixer = builder.element(10)
        let layoutArea = builder.element(11)
        let strips = [builder.element(12), builder.element(13)]
        builder.setRole(mixer, kAXGroupRole as String)
        builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        builder.setRole(layoutArea, "AXLayoutArea")
        builder.setAttribute(layoutArea, kAXDescriptionAttribute as String, "Mixer")
        for strip in strips { builder.setRole(strip, kAXLayoutItemRole as String) }
        builder.setChildren(layoutArea, strips)
        builder.setChildren(mixer, [layoutArea])
        builder.setChildren(tree.window, [browser, listHolder, mixer])

        let lookup = AXLogicProElements.mixerAreaLookup(runtime: tree.logicRuntime())

        #expect(try #require(lookup.mixer) == layoutArea)
        #expect(!tree.reads.readChildren(ofAny: tree.ids([browser] + browserSubtree)))
        #expect(!tree.reads.readAttributes(ofAny: tree.ids(browserSubtree + long.subtree)))
    }
}
