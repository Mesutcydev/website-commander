import XCTest
import SwiftUI
@testable import WebsiteCommander

/// The application bar's contract.
///
/// The shell used to be a `NavigationSplitView` with a 212–240pt sidebar, so
/// these tests pin the rules that replaced it: one bar, one row, a fixed set of
/// dimensions, a component order driven by task priority, and a density ladder
/// that substitutes controls rather than wrapping or hiding essentials.
///
/// Everything here is a pure value type — no store, no engine, no view — so the
/// suite can never touch the user's real settings file.
final class TopBarLayoutTests: XCTestCase {

    // MARK: Dimensions

    func testBarDimensionsMatchTheSpecifiedScale() {
        XCTAssertEqual(TopBarMetrics.height, 58)
        XCTAssertEqual(TopBarMetrics.paddingX, 20)
        XCTAssertEqual(TopBarMetrics.controlHeight, 32)
        XCTAssertEqual(TopBarMetrics.smallControlSize, 28)
        XCTAssertEqual(TopBarMetrics.groupGap, 12)
        XCTAssertEqual(TopBarMetrics.zoneGap, 14)
        XCTAssertEqual(TopBarMetrics.leftZoneGap, 10)
        XCTAssertEqual(TopBarMetrics.brandHeight, 32)
        XCTAssertEqual(TopBarMetrics.statusHeight, 20)
        XCTAssertEqual(TopBarMetrics.navigationContainerHeight, 32)
        XCTAssertEqual(TopBarMetrics.navigationItemHeight, 32)
        XCTAssertEqual(TopBarMetrics.viewGroupHeight, 32)
    }

    func testRadiiFollowOneScale() {
        XCTAssertEqual(TopBarMetrics.smallControlRadius, 7, "28pt icon controls")
        XCTAssertEqual(TopBarMetrics.controlRadius, 8, "32pt controls")
        XCTAssertEqual(TopBarMetrics.groupRadius, 8, "grouped containers")
        XCTAssertEqual(TopBarMetrics.popoverRadius, 14, "popovers")
    }

    /// The bar is never taller than 72 on desktop, and only ever gets shorter at
    /// the narrowest tier.
    func testBarNeverExceedsTheDesktopCeiling() {
        for width in [800.0, 1024.0, 1200.0, 1280.0, 1440.0, 1600.0, 1728.0, 2560.0] as [CGFloat] {
            XCTAssertEqual(TopBarMetrics(width: width).height, 58,
                           "a \(Int(width))pt window keeps the compact bar")
        }
        XCTAssertEqual(TopBarMetrics(width: 799).height, 58)
        XCTAssertEqual(TopBarMetrics(width: 760).height, 58)
    }

    func testTrafficLightRoomIsReservedRatherThanGuessed() {
        // The native titlebar is hidden, so the window's buttons live inside the
        // bar. They occupy roughly the first 61pt; the reserve clears them.
        XCTAssertGreaterThanOrEqual(TopBarMetrics.trafficLightInset, 70)
        XCTAssertLessThanOrEqual(TopBarMetrics.trafficLightInset, 90)
    }

    // MARK: Density ladder

    func testDensityTiersMatchTheBreakpoints() {
        XCTAssertEqual(TopBarMetrics(width: 1728).density, .spacious)
        XCTAssertEqual(TopBarMetrics(width: 1440).density, .spacious)
        XCTAssertEqual(TopBarMetrics(width: 1439).density, .standard)
        XCTAssertEqual(TopBarMetrics(width: 1280).density, .standard)
        XCTAssertEqual(TopBarMetrics(width: 1200).density, .standard)
        XCTAssertEqual(TopBarMetrics(width: 1199).density, .reduced)
        XCTAssertEqual(TopBarMetrics(width: 1024).density, .reduced)
        XCTAssertEqual(TopBarMetrics(width: 1023).density, .tight)
        XCTAssertEqual(TopBarMetrics(width: 800).density, .tight)
        XCTAssertEqual(TopBarMetrics(width: 799).density, .minimal)
    }

    /// The five-item row survives to 1200 and is then replaced by a single
    /// current-destination selector — never by a hamburger and never by a
    /// horizontally scrolling row.
    func testDestinationRowBecomesOneSelectorBelow1200() {
        XCTAssertEqual(TopBarMetrics(width: 1600).navigationStyle, .destinations)
        XCTAssertEqual(TopBarMetrics(width: 1280).navigationStyle, .destinations)
        XCTAssertEqual(TopBarMetrics(width: 1200).navigationStyle, .destinations)
        XCTAssertEqual(TopBarMetrics(width: 1199).navigationStyle, .selector)
        XCTAssertEqual(TopBarMetrics(width: 1024).navigationStyle, .selector)
        XCTAssertEqual(TopBarMetrics(width: 820).navigationStyle, .selector)
        XCTAssertEqual(TopBarMetrics(width: 760).navigationStyle, .selector)
    }

    /// The wordmark goes before the destination row does: below 1440 the measured
    /// budget cannot hold both, and navigation is worth more than the name.
    func testWordmarkIsTheFirstThingToGo() {
        XCTAssertTrue(TopBarMetrics(width: 1600).showsWordmark)
        XCTAssertTrue(TopBarMetrics(width: 1440).showsWordmark)
        XCTAssertFalse(TopBarMetrics(width: 1439).showsWordmark)
        XCTAssertFalse(TopBarMetrics(width: 1280).showsWordmark)
        XCTAssertFalse(TopBarMetrics(width: 820).showsWordmark)
        // Dropping it is what keeps the five-item row alive at 1280.
        XCTAssertEqual(TopBarMetrics(width: 1280).navigationStyle, .destinations)
    }

    /// Status and model selection are never hidden on desktop; only the status
    /// *label* folds into the activity popover at the narrowest tier.
    func testStatusAndModelSurviveEveryTier() {
        for width in [760.0, 820.0, 1024.0, 1280.0, 1440.0] as [CGFloat] {
            let metrics = TopBarMetrics(width: width)
            XCTAssertGreaterThan(metrics.modelMinWidth, 0)
            XCTAssertGreaterThanOrEqual(metrics.modelMaxWidth, metrics.modelPreferredWidth)
            XCTAssertGreaterThanOrEqual(metrics.modelPreferredWidth, metrics.modelMinWidth)
        }
        XCTAssertTrue(TopBarMetrics(width: 1024).showsStatusLabel)
        XCTAssertTrue(TopBarMetrics(width: 820).showsStatusLabel)
        XCTAssertFalse(TopBarMetrics(width: 780).showsStatusLabel)
    }

    func testProjectWidthsNarrowMonotonicallyAndStayOrdered() {
        var previousMax = CGFloat.greatestFiniteMagnitude
        for width in [1440.0, 1280.0, 1100.0, 900.0, 780.0] as [CGFloat] {
            let metrics = TopBarMetrics(width: width)
            XCTAssertLessThanOrEqual(metrics.projectMinWidth, metrics.projectPreferredWidth)
            XCTAssertLessThanOrEqual(metrics.projectPreferredWidth, metrics.projectMaxWidth)
            XCTAssertLessThanOrEqual(metrics.projectMaxWidth, previousMax,
                                     "the project cap must not grow as the window shrinks")
            previousMax = metrics.projectMaxWidth
        }
        XCTAssertEqual(TopBarMetrics(width: 1440).projectPreferredWidth, 176)
        XCTAssertEqual(TopBarMetrics(width: 1280).projectPreferredWidth, 148)
        XCTAssertEqual(TopBarMetrics(width: 900).projectPreferredWidth, 112)
    }

    func testViewControlsDegradeIntoOverflowRatherThanDisappearing() {
        XCTAssertEqual(TopBarMetrics(width: 1440).viewControlPlacement, .group)
        XCTAssertEqual(TopBarMetrics(width: 1280).viewControlPlacement, .group)
        XCTAssertEqual(TopBarMetrics(width: 1100).viewControlPlacement, .essential)
        XCTAssertEqual(TopBarMetrics(width: 900).viewControlPlacement, .overflow)
        XCTAssertEqual(TopBarMetrics(width: 780).viewControlPlacement, .overflow)
    }

    /// The second divider only exists when view controls follow it, so the bar
    /// never shows a separator with nothing on the other side.
    func testSecondDividerOnlyAppearsWithViewControls() {
        XCTAssertTrue(TopBarMetrics(width: 1440).showsViewControlDivider)
        XCTAssertTrue(TopBarMetrics(width: 1100).showsViewControlDivider)
        XCTAssertFalse(TopBarMetrics(width: 900).showsViewControlDivider)
    }

    // MARK: No layout shift

    /// New and Stop are one control with one footprint, so starting or stopping
    /// the agent cannot move the overflow button beside it.
    func testPrimaryActionFootprintIsIndependentOfItsLabel() {
        let wide = TopBarMetrics(width: 1440)
        XCTAssertTrue(wide.primaryActionShowsLabel)
        XCTAssertEqual(wide.primaryActionWidth, TopBarMetrics.primaryActionLabelledWidth)

        let medium = TopBarMetrics(width: 1280)
        XCTAssertFalse(medium.primaryActionShowsLabel, "icon-only below ~1320")
        XCTAssertEqual(medium.primaryActionWidth, TopBarMetrics.controlHeight)
        XCTAssertEqual(medium.primaryActionWidth, 32,
                       "the compact action stays at the control height")
    }

    func testPrimaryActionBecomesIconOnlyAtTheDocumentedWidth() {
        XCTAssertTrue(TopBarMetrics(width: 1320).primaryActionShowsLabel)
        XCTAssertFalse(TopBarMetrics(width: 1319).primaryActionShowsLabel)
    }

    // MARK: Popovers

    func testPopoverWidthsMatchTheDesignSystem() {
        XCTAssertEqual(TopBarPopoverKind.project.width, 280)
        XCTAssertEqual(TopBarPopoverKind.model.width, 320)
    }

    func testPopoverHeightIsCappedByTheWindow() {
        let metrics = TopBarMetrics(width: 1440)
        // min(420, window − 90)
        XCTAssertEqual(metrics.popoverHeight(preferred: 420, windowHeight: 900), 420)
        XCTAssertEqual(metrics.popoverHeight(preferred: 420, windowHeight: 480), 390)
        XCTAssertEqual(metrics.popoverHeight(preferred: 480, windowHeight: 900), 480)
        XCTAssertEqual(metrics.popoverHeight(preferred: 480, windowHeight: 700), 480)
    }

    func testProjectSearchOnlyAppearsWhenTheListNeedsIt() {
        XCTAssertFalse(TopBarMetrics.projectPopoverNeedsSearch(projectCount: 0))
        XCTAssertFalse(TopBarMetrics.projectPopoverNeedsSearch(projectCount: 8))
        XCTAssertTrue(TopBarMetrics.projectPopoverNeedsSearch(projectCount: 9))
    }

    // MARK: Destinations

    /// Route names are persisted, so they must not drift; only the bar's short
    /// labels differ from them.
    func testRouteNamesArePreservedAndOnlyBarLabelsShorten() {
        XCTAssertEqual(Destination.primaryCases.map(\.rawValue),
                       ["Command Center", "Sites", "Agent", "Preview", "History"])
        XCTAssertEqual(Destination.primaryCases.map(\.barLabel),
                       ["Command", "Sites", "Agent", "Preview", "History"])
        XCTAssertEqual(Destination.allCases.last, .blog)
        XCTAssertEqual(Destination(rawValue: "Agent"), .agent)
    }

    /// One icon family, one stroke weight: no filled variants mixed in with
    /// outlined ones.
    func testDestinationIconsShareOneStyle() {
        for item in Destination.allCases {
            XCTAssertFalse(item.icon.hasSuffix(".fill"),
                           "\(item.rawValue) mixes a filled glyph into an outlined set")
        }
    }

    // MARK: Status vocabulary

    /// Every label the bar can show maps from a real engine state. There is no
    /// case that invents a status the app cannot be in.
    func testStatusVocabularyMapsOnlyFromRealEngineStates() {
        XCTAssertEqual(AgentStatusPresentation.from(state: .idle, pendingChanges: 0), .ready)
        XCTAssertEqual(AgentStatusPresentation.from(state: .done, pendingChanges: 0), .ready)
        XCTAssertEqual(AgentStatusPresentation.from(state: .thinking, pendingChanges: 0), .thinking)
        XCTAssertEqual(AgentStatusPresentation.from(state: .streaming, pendingChanges: 0), .working)
        XCTAssertEqual(AgentStatusPresentation.from(state: .runningTool, pendingChanges: 0), .working)
        XCTAssertEqual(AgentStatusPresentation.from(state: .committing, pendingChanges: 0), .working)
        XCTAssertEqual(AgentStatusPresentation.from(state: .awaitingApproval, pendingChanges: 0), .waiting)
        XCTAssertEqual(AgentStatusPresentation.from(state: .failed, pendingChanges: 1), .failed)
    }

    /// "Reviewing" is not decoration: it only appears when changes really are
    /// staged and the agent has stopped working.
    func testReviewingRequiresRealStagedChanges() {
        XCTAssertEqual(AgentStatusPresentation.from(state: .idle, pendingChanges: 2), .reviewing)
        XCTAssertEqual(AgentStatusPresentation.from(state: .done, pendingChanges: 1), .reviewing)
        XCTAssertEqual(AgentStatusPresentation.from(state: .idle, pendingChanges: 0), .ready)
    }

    /// A permanently pulsing "Ready" light is exactly what the bar must not do.
    func testOnlyRealWorkAnimates() {
        XCTAssertFalse(AgentStatusPresentation.ready.animates)
        XCTAssertFalse(AgentStatusPresentation.waiting.animates)
        XCTAssertFalse(AgentStatusPresentation.reviewing.animates)
        XCTAssertFalse(AgentStatusPresentation.failed.animates)
        XCTAssertTrue(AgentStatusPresentation.thinking.animates)
        XCTAssertTrue(AgentStatusPresentation.working.animates)
    }

    func testStatusLabelsStayInsideTheAgreedVocabulary()  {
        let allowed: Set<String> = ["Ready", "Thinking", "Working", "Waiting", "Reviewing", "Failed"]
        for status in AgentStatusPresentation.allCases {
            XCTAssertTrue(allowed.contains(status.label),
                          "\(status.label) is outside the bar's status vocabulary")
        }
    }

    // MARK: The sidebar is gone

    /// The bar's own width budget has to fit inside the window it is measured
    /// for — with no sidebar column subtracted from it — at every tier. This is
    /// the regression guard for phantom sidebar inset creeping back in.
    func testBarContentFitsTheWindowWithNoReservedSidebarColumn() {
        for width in [760.0, 800.0, 820.0, 1024.0, 1200.0, 1280.0, 1440.0, 1600.0] as [CGFloat] {
            let metrics = TopBarMetrics(width: width)
            XCTAssertLessThanOrEqual(
                metrics.minimumRowWidth, width,
                """
                the bar must fit a \(Int(width))pt window in one row \
                (\(metrics.density) needs \(Int(metrics.minimumRowWidth)))
                """
            )
        }
    }

    /// Each tier has to leave real slack, or the first longer project name would
    /// push the row over. Slack is measured against the tier's own floor.
    func testEachTierLeavesHeadroomAtItsNarrowestWindow() {
        let floors: [(CGFloat, TopBarMetrics.Density)] = [
            (1440, .spacious), (1200, .standard), (1024, .reduced), (800, .tight), (760, .minimal)
        ]
        for (floor, expected) in floors {
            let metrics = TopBarMetrics(width: floor)
            XCTAssertEqual(metrics.density, expected)
            XCTAssertLessThanOrEqual(metrics.minimumRowWidth, floor - 24,
                                     "\(expected) has no headroom at \(Int(floor))pt")
        }
    }

    /// The compact selector is sized for the longest destination name, so
    /// switching destinations can't resize the center zone.
    func testCompactSelectorDoesNotResizePerDestination() {
        let width = TopBarMetrics.destinationSelectorWidth
        for item in Destination.allCases {
            let label = Theme.Typography.width(item.barLabel, size: 13, weight: .medium)
            XCTAssertLessThanOrEqual(
                TopBarMetrics.navigationIconSize + 6 + label + 6
                    + TopBarMetrics.chevronSize + TopBarMetrics.navigationItemPaddingX * 2,
                width
            )
        }
    }

    /// The row is measured with the face the app resolves at runtime, not an
    /// assumed one — otherwise the budget would be fiction on a machine with the
    /// licensed family installed.
    func testDestinationRowIsMeasuredWithTheResolvedFace() {
        XCTAssertGreaterThan(TopBarMetrics.destinationRowWidth, 300)
        XCTAssertLessThan(TopBarMetrics.destinationRowWidth, 560)
        XCTAssertGreaterThan(Theme.Typography.width("History", size: 13, weight: .medium),
                             Theme.Typography.width("Sites", size: 13, weight: .medium))
    }
}
