import CoreGraphics

/// The top bar's responsive contract, expressed as a pure value type.
///
/// The bar is one semantic component at every width: there is no separate
/// "compact bar" to keep in sync. Density reduces progressively — labels give
/// way to glyphs, the five-item destination row gives way to a single
/// current-destination selector, and low-priority actions move into overflow —
/// but the component order and the single row never change.
///
/// Everything the shell needs to lay itself out is derived here so it can be
/// tested without instantiating a view or a store.
struct TopBarMetrics: Equatable {

    /// Width of the window the bar spans.
    let width: CGFloat

    init(width: CGFloat) {
        self.width = max(0, width)
    }

    // MARK: Density

    /// Progressive density tiers. Names describe available room, not devices —
    /// this app only ever runs in a desktop window.
    enum Density: Int, Comparable {
        /// ≥1440: every label, the full destination row.
        case spacious
        /// 1200–1439: full labels, tighter project and model caps.
        case standard
        /// 1024–1199: destinations collapse to one selector.
        case reduced
        /// 800–1023: wordmark hidden, view controls in overflow.
        case tight
        /// <800: shortest bar, status folded into the activity control.
        case minimal

        static func < (lhs: Density, rhs: Density) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var density: Density {
        if width >= 1440 { return .spacious }
        if width >= 1200 { return .standard }
        if width >= 1024 { return .reduced }
        if width >= 800 { return .tight }
        return .minimal
    }

    // MARK: Fixed chrome tokens

    /// The global application toolbar height. It does not grow by density.
    static let height: CGFloat = 56
    static let minimalHeight: CGFloat = 56
    static let paddingX: CGFloat = 16
    /// Gap between controls inside a zone.
    static let groupGap: CGFloat = 8
    /// Gap between the three zones.
    static let zoneGap: CGFloat = 12
    /// The left zone is slightly looser: brand lockups need air.
    static let leftZoneGap: CGFloat = 10

    static let controlHeight: CGFloat = 32
    static let smallControlSize: CGFloat = 28
    static let brandHeight: CGFloat = 32
    static let statusHeight: CGFloat = 20
    static let navigationContainerHeight: CGFloat = 32
    static let navigationItemHeight: CGFloat = 32
    static let viewGroupHeight: CGFloat = 32

    static let controlRadius: CGFloat = 8
    static let smallControlRadius: CGFloat = 7
    static let groupRadius: CGFloat = 8
    static let viewGroupRadius: CGFloat = 8
    static let popoverRadius: CGFloat = 16
    static let popoverRowRadius: CGFloat = 8

    static let dividerHeight: CGFloat = 16
    static let dividerMargin: CGFloat = 2
    /// A hairline divider's total horizontal footprint: 1pt rule plus its
    /// breathing room on each side.
    static let dividerWidth: CGFloat = 1 + dividerMargin * 2

    /// Gap between the brand mark and the wordmark beside it.
    static let brandGap: CGFloat = 8
    /// Horizontal padding inside the status control.
    static let statusPaddingX: CGFloat = 8

    /// The view-control group: one 32pt segment per view, plus container inset.
    static let viewControlGroupWidth: CGFloat = smallControlSize * 2 + 6

    static let iconSize: CGFloat = 16
    static let navigationIconSize: CGFloat = 13
    static let chevronSize: CGFloat = 12
    static let projectIconSize: CGFloat = 16
    static let brandMarkSize: CGFloat = 24
    static let statusDotSize: CGFloat = 6

    /// Leading room reserved for the window's traffic lights, which sit inside
    /// the bar now that the native titlebar is hidden.
    static let trafficLightInset: CGFloat = 78

    /// Popovers open this far below their trigger.
    static let popoverGap: CGFloat = 8
    /// Room left above and below a popover so it never runs off the window.
    static let popoverWindowMargin: CGFloat = 90

    var height: CGFloat {
        density == .minimal ? Self.minimalHeight : Self.height
    }

    // MARK: Left zone

    /// The wordmark is the first thing to go, and it goes early: the five-item
    /// destination row is worth more than the product name, and below 1440 the
    /// two cannot both have their width. The mark still carries the brand and the
    /// accessible name still reads "Website Commander".
    ///
    /// This threshold is not a guess — `minimumRowWidth` measures the row with
    /// the resolved typeface and the tests hold the bar to it.
    var showsWordmark: Bool { density == .spacious }

    var projectMinWidth: CGFloat {
        switch density {
        case .spacious, .standard: return 138
        case .reduced: return 120
        case .tight, .minimal: return 92
        }
    }

    var projectPreferredWidth: CGFloat {
        switch density {
        case .spacious: return 176
        case .standard: return 148
        case .reduced: return 132
        case .tight: return 112
        case .minimal: return 104
        }
    }

    var projectMaxWidth: CGFloat {
        switch density {
        case .spacious: return 236
        case .standard: return 196
        case .reduced: return 168
        case .tight: return 132
        case .minimal: return 120
        }
    }

    // MARK: Center zone

    enum NavigationStyle {
        /// All five destinations, laid out in one grouped container.
        case destinations
        /// A single current-destination selector that opens the same list.
        case selector
    }

    /// Five visible destinations need roughly 470pt of centre; below 1200 the
    /// bar would have to squeeze the project or model control to keep them.
    var navigationStyle: NavigationStyle {
        density <= .standard ? .destinations : .selector
    }

    // MARK: Right zone

    /// The status label always shows except at the narrowest tier, where the
    /// indicator alone stands in and the label moves into its popover.
    var showsStatusLabel: Bool { density <= .tight }

    var modelMinWidth: CGFloat {
        switch density {
        case .spacious, .standard: return 118
        case .reduced: return 108
        case .tight, .minimal: return 92
        }
    }

    var modelPreferredWidth: CGFloat {
        switch density {
        case .spacious: return 148
        case .standard: return 138
        case .reduced: return 124
        case .tight: return 108
        case .minimal: return 100
        }
    }

    var modelMaxWidth: CGFloat {
        switch density {
        case .spacious: return 196
        case .standard: return 176
        case .reduced: return 150
        case .tight: return 124
        case .minimal: return 112
        }
    }

    enum ViewControlPlacement {
        /// The whole group sits in the bar.
        case group
        /// Only the essential control stays; the rest move to overflow.
        case essential
        /// Everything moves to overflow.
        case overflow
    }

    var viewControlPlacement: ViewControlPlacement {
        switch density {
        case .spacious, .standard: return .group
        case .reduced: return .essential
        case .tight, .minimal: return .overflow
        }
    }

    /// The primary action keeps its text while there is room for it; below
    /// ~1320 it becomes a square icon button with the same outer height.
    var primaryActionShowsLabel: Bool { width >= 1320 }

    /// New and Stop are the same control, so its footprint is fixed rather than
    /// derived from whichever word is currently in it. Nothing beside it can
    /// move when the agent starts or stops.
    static let primaryActionLabelledWidth: CGFloat = 82

    var primaryActionWidth: CGFloat {
        primaryActionShowsLabel ? Self.primaryActionLabelledWidth : Theme.Height.prominent
    }

    /// The second divider only earns its place when view controls follow it.
    var showsViewControlDivider: Bool { viewControlPlacement != .overflow }

    // MARK: Popovers

    // MARK: Width budget
    //
    // The bar is one row that must never wrap, so the density ladder has to be
    // checkable rather than eyeballed. These measure the two variable-width
    // text runs with the face the app actually resolves, and sum the fixed
    // parts, giving the narrowest width each tier can be drawn in.

    static let navigationItemPaddingX: CGFloat = 10
    static let navigationItemGap: CGFloat = 2
    static let navigationContainerPadding: CGFloat = 0

    /// One destination cell's fixed width, measured at the *selected* weight —
    /// the widest the label can be. Cells are sized rather than padded so
    /// changing destination cannot resize the row or shift its neighbours.
    static func navigationItemWidth(for item: Destination) -> CGFloat {
        navigationIconSize + 6
            + Theme.Typography.width(item.barLabel, size: 13, weight: .semibold)
            + navigationItemPaddingX * 2
    }

    /// The five-item destination row at its true rendered width.
    static var destinationRowWidth: CGFloat {
        let items = Destination.allCases.reduce(CGFloat.zero) { total, item in
            total + navigationItemWidth(for: item)
        }
        let gaps = CGFloat(max(0, Destination.allCases.count - 1)) * navigationItemGap
        return items + gaps + navigationContainerPadding * 2
    }

    /// The compact selector that replaces the row below 1200pt, measured for the
    /// longest destination name so switching destinations never resizes it.
    static var destinationSelectorWidth: CGFloat {
        let longest = Destination.allCases
            .map { Theme.Typography.width($0.barLabel, size: 13, weight: .medium) }
            .max() ?? 0
        return navigationIconSize + 6 + longest + 6 + chevronSize + navigationItemPaddingX * 2
    }

    var centerZoneWidth: CGFloat {
        navigationStyle == .destinations ? Self.destinationRowWidth : Self.destinationSelectorWidth
    }

    /// Narrowest width this tier can draw in, using every control's minimum
    /// rather than its preferred width. Anything wider than this fits in one row
    /// — with no sidebar column subtracted from the window first.
    var minimumRowWidth: CGFloat {
        let brandWordmark = showsWordmark
            ? Self.brandGap + Theme.Typography.width("Website Commander", size: 13.5, weight: .semibold)
            : 0
        let left = Self.trafficLightInset
            + Self.brandMarkSize + brandWordmark
            + Self.leftZoneGap + Self.dividerWidth + Self.leftZoneGap
            + projectMinWidth
        let statusLabel = showsStatusLabel
            ? 6 + Theme.Typography.width("Reviewing", size: 12.5, weight: .medium)
            : 0
        let status = Self.statusPaddingX * 2 + Self.statusDotSize + statusLabel
        let viewControls: CGFloat
        switch viewControlPlacement {
        case .group:     viewControls = Self.dividerWidth + Self.groupGap + Self.viewControlGroupWidth
        case .essential: viewControls = Self.dividerWidth + Self.groupGap + Self.smallControlSize
        case .overflow:  viewControls = 0
        }
        let right = status
            + Self.groupGap + modelMinWidth
            + Self.groupGap + viewControls
            + Self.groupGap + primaryActionWidth
            + Self.groupGap + Self.smallControlSize
        return Self.paddingX * 2 + left + Self.zoneGap + centerZoneWidth + Self.zoneGap + right
    }

    /// Popover height cap: `min(preferred, window − margin)`.
    func popoverHeight(preferred: CGFloat, windowHeight: CGFloat) -> CGFloat {
        guard windowHeight > 0 else { return preferred }
        return min(preferred, max(160, windowHeight - Self.popoverWindowMargin))
    }

    /// Project search is a real affordance only once the list is long enough
    /// to need it.
    static func projectPopoverNeedsSearch(projectCount: Int) -> Bool {
        projectCount > 8
    }
}
