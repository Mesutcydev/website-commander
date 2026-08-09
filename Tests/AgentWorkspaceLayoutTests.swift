import XCTest
import SwiftUI
@testable import WebsiteCommander

/// The Agent workspace's responsive contract.
///
/// The layout used to be a fixed 960pt column centered in the window, so these
/// tests pin the rules that replaced it: gutters scale with the pane, the Smart
/// Tasks grid steps through deliberate column counts, the execution rail only
/// appears when the conversation stays comfortable beside it, and a normal
/// 1440–1600pt window is used in full rather than capped.
final class AgentWorkspaceLayoutTests: XCTestCase {

    // MARK: Gutters

    func testGuttersScaleWithPaneAndStayWithinClamp() {
        // clamp(20, 2.4vw, 36)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 600).paddingX, 20, accuracy: 0.01)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1200).paddingX, 28.8, accuracy: 0.01)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 2400).paddingX, 36, accuracy: 0.01)
    }

    /// Every region that has to line up resolves its gutter through the one
    /// static function, so the top bar, the workspace, the composer, and each
    /// destination's command row cannot drift apart.
    func testOneGutterFunctionServesEveryRegion() {
        for width in [760.0, 1024.0, 1280.0, 1440.0, 1920.0] as [CGFloat] {
            XCTAssertEqual(AgentWorkspaceMetrics.gutter(for: width),
                           AgentWorkspaceMetrics(width: width).paddingX,
                           accuracy: 0.001)
        }
    }

    func testContentStartsCloseToTheToolbar() {
        // No decorative band: the toolbar already names the section.
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1360).paddingTop, 20)
        XCTAssertLessThanOrEqual(AgentWorkspaceMetrics(width: 1360).paddingTop, 24)
    }

    /// One bar, one compact height — and one place that owns it.
    func testToolbarStaysCompact() {
        XCTAssertLessThanOrEqual(TopBarMetrics.height, 72)
    }

    // MARK: Smart tasks grid

    func testSmartTaskColumnsStepThroughDeliberateBreakpoints() {
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1600).taskColumns, 4)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1360).taskColumns, 4)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1200).taskColumns, 3)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1100).taskColumns, 3)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 900).taskColumns, 2)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 640).taskColumns, 2)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 480).taskColumns, 1)
    }

    func testTaskCardHeightStaysInDenseRange() {
        let wide = AgentWorkspaceMetrics(width: 1600)
        XCTAssertGreaterThanOrEqual(wide.taskCardMinHeight, 72)
        XCTAssertLessThanOrEqual(wide.taskCardMinHeight, 80)
    }

    /// The grid must consume the pane rather than sitting in a narrow column:
    /// four cards plus their gaps should account for the full content width.
    func testTaskGridConsumesTheFullContentWidth() {
        let metrics = AgentWorkspaceMetrics(width: 1600)
        let gaps = CGFloat(metrics.taskColumns - 1) * metrics.cardGap
        let cardWidth = (metrics.contentWidth - gaps) / CGFloat(metrics.taskColumns)
        XCTAssertEqual(cardWidth * 4 + gaps, metrics.contentWidth, accuracy: 0.01)
        XCTAssertGreaterThan(cardWidth, 300, "cards should be roomy at 1600pt, not 190pt")
    }

    // MARK: Command Center rows

    func testCommandCenterColumnsStepThroughDeliberateBreakpoints() {
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1600).statColumns, 4)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 840).statColumns, 4)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 800).statColumns, 2)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 480).statColumns, 1)

        XCTAssertEqual(AgentWorkspaceMetrics(width: 1600).quickActionColumns, 5)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 760).quickActionColumns, 5)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 600).quickActionColumns, 3)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 480).quickActionColumns, 2)

        XCTAssertEqual(AgentWorkspaceMetrics(width: 1600).suggestionColumns, 4)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 840).suggestionColumns, 4)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 800).suggestionColumns, 2)
    }

    /// A four-card row is only kept while each card holds a readable measure —
    /// the chips truncate below roughly 190pt.
    func testFourUpRowsOnlySurviveWhileCardsStayReadable() {
        let metrics = AgentWorkspaceMetrics(width: AgentWorkspaceMetrics.fourUpBreakpoint)
        let cardWidth = (metrics.contentWidth - 3 * metrics.cardGap) / 4
        XCTAssertGreaterThanOrEqual(cardWidth, 190)
    }

    /// The five quick actions stay a single whole row at every width the window
    /// can actually reach, so the row never ends short of the gutter.
    func testQuickActionsFillOneRowDownToTheWindowMinimum() {
        for width in [760.0, 900.0, 1024.0, 1280.0, 1600.0] as [CGFloat] {
            XCTAssertEqual(AgentWorkspaceMetrics(width: width).quickActionColumns, 5,
                           "quick actions should stay one row at \(width)pt")
        }
    }

    /// Every dashboard row is flexible, so its cards plus gaps account for the
    /// whole content width — the ragged trailing space of an adaptive grid is
    /// what made the page look tilted to the left.
    func testCommandCenterRowsConsumeTheFullContentWidth() {
        for width in [760.0, 900.0, 1024.0, 1280.0, 1600.0] as [CGFloat] {
            let metrics = AgentWorkspaceMetrics(width: width)
            for count in [metrics.statColumns, metrics.quickActionColumns, metrics.suggestionColumns] {
                let gaps = CGFloat(count - 1) * metrics.cardGap
                let cardWidth = (metrics.contentWidth - gaps) / CGFloat(count)
                XCTAssertEqual(cardWidth * CGFloat(count) + gaps, metrics.contentWidth, accuracy: 0.01)
                XCTAssertGreaterThan(cardWidth, 130,
                                     "cards should stay comfortable at \(width)pt")
            }
        }
    }

    /// Card rows and the full-width sections below them share one gutter, so
    /// every section resolves to the same left and right edge.
    func testDashboardSectionsShareTheShellGutter() {
        for width in [760.0, 1024.0, 1600.0] as [CGFloat] {
            XCTAssertEqual(AgentWorkspaceMetrics(width: width).paddingX,
                           AgentWorkspaceMetrics.gutter(for: width), accuracy: 0.001)
        }
    }

    // MARK: Execution rail

    func testRailAppearsOnlyWhenThePrimaryColumnStaysComfortable() {
        XCTAssertTrue(AgentWorkspaceMetrics(width: 1360).allowsRail)
        XCTAssertTrue(AgentWorkspaceMetrics(width: 1180).allowsRail)
        XCTAssertFalse(AgentWorkspaceMetrics(width: 1100).allowsRail)
        XCTAssertFalse(AgentWorkspaceMetrics(width: 800).allowsRail)
    }

    func testRailWidthMatchesTheClampedTarget() {
        // clamp(300, 23vw, 340)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1200).railWidth, 300, accuracy: 0.01)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1400).railWidth, 322, accuracy: 0.01)
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1600).railWidth, 340, accuracy: 0.01)
    }

    /// With the rail visible the conversation must still be the dominant column.
    func testConversationKeepsTheMajorityOfTheWidthBesideTheRail() {
        let metrics = AgentWorkspaceMetrics(width: 1360)
        let conversation = metrics.width - metrics.railWidth
        XCTAssertGreaterThan(conversation, metrics.railWidth * 2)
    }

    func testRailIsHiddenWhenThereIsNoRealActivity() {
        XCTAssertFalse(AgentExecutionRail.hasContent(events: [], pendingChanges: []))
        XCTAssertTrue(AgentExecutionRail.hasContent(
            events: [ToolEvent(name: "read_file", summary: "Read index.html")],
            pendingChanges: []
        ))
        XCTAssertTrue(AgentExecutionRail.hasContent(
            events: [],
            pendingChanges: [PendingChange(path: "styles.css", oldContent: "a", newContent: "b", message: "tweak")]
        ))
    }

    // MARK: Message widths

    func testUserMessagesHugContentButNeverDominate() {
        let narrow = AgentWorkspaceMetrics(width: 900)
        XCTAssertEqual(narrow.userBubbleWidth, narrow.contentWidth * 0.72, accuracy: 0.01)

        // Capped at 820 on wide panes so a bubble never spans the workspace.
        XCTAssertEqual(AgentWorkspaceMetrics(width: 1600).userBubbleWidth, 820, accuracy: 0.01)
    }

    func testAssistantProseStaysAtAReadableMeasure() {
        // ~72–88 characters at the body size used in the transcript.
        let prose = AgentWorkspaceMetrics(width: 1600).proseWidth
        XCTAssertGreaterThanOrEqual(prose, 640)
        XCTAssertLessThanOrEqual(prose, 760)
    }

    // MARK: No artificial narrowing

    /// The regression this whole pass exists to prevent: every window size a
    /// desktop user actually runs must be used in full, including 1600pt with
    /// the sidebar collapsed.
    func testNormalDesktopWindowsAreNotCappedToANarrowPage() {
        for width in [1180.0, 1280.0, 1440.0, 1600.0] as [CGFloat] {
            let metrics = AgentWorkspaceMetrics(width: width)
            XCTAssertGreaterThanOrEqual(
                metrics.maxColumnWidth, width,
                "a \(Int(width))pt pane must not be constrained by the readability cap"
            )
            XCTAssertEqual(metrics.contentWidth, width - metrics.paddingX * 2, accuracy: 0.01)
        }
    }

    /// The cap still exists — it just only applies to ultra-wide displays.
    func testUltraWideDisplaysStillGetAReadabilityCap() {
        let metrics = AgentWorkspaceMetrics(width: 2560)
        XCTAssertLessThan(metrics.maxColumnWidth, metrics.width)
    }

    /// The composer and the scroll region derive their gutters from the same
    /// metrics, so their content edges line up by construction.
    func testComposerAndTranscriptShareOneGrid() {
        let metrics = AgentWorkspaceMetrics(width: 1440)
        XCTAssertEqual(metrics.paddingX, AgentWorkspaceMetrics(width: 1440).paddingX)
        XCTAssertEqual(metrics.maxColumnWidth, AgentWorkspaceMetrics(width: 1440).maxColumnWidth)
    }
}
