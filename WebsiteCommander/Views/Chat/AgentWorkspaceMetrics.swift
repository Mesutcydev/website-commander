import SwiftUI

/// One grid for the whole Agent workspace.
///
/// Every region that needs to line up — the scroll region, the idle command
/// center, the conversation column, the execution rail, and the docked composer
/// — derives its gutters and widths from a single instance of this type. That is
/// what stops the screen behaving like a narrow centered page: there is no
/// per-component `maxWidth` left to disagree with its neighbours.
///
/// Everything is a function of the pane's own width, so the same components
/// serve the full-window workspace and the narrow split pane. There is no
/// separate "compact" copy of the layout to keep in sync.
struct AgentWorkspaceMetrics: Equatable {
    /// Width of the pane the chat owns — not the window.
    let width: CGFloat

    init(width: CGFloat) {
        self.width = max(0, width)
    }

    /// True when the pane is too narrow for the roomy desktop treatment.
    var isNarrow: Bool { width < 720 }

    // MARK: Gutters

    /// The shell's one horizontal gutter rule: `clamp(20, 2.4vw, 36)`.
    ///
    /// Everything that has to line up horizontally — the workspace scroll
    /// region, the docked composer, the task grid, the Sites and History command
    /// rows, the Preview surface — resolves its gutter through this function, so
    /// there is exactly one grid in the app rather than a per-screen guess.
    static func gutter(for width: CGFloat) -> CGFloat {
        min(36, max(20, max(0, width) * 0.024))
    }

    var paddingX: CGFloat { Self.gutter(for: width) }

    /// Distance from the toolbar to the first row of content. Deliberately
    /// small: the toolbar already names the section, so no decorative band.
    var paddingTop: CGFloat { 20 }
    var paddingBottom: CGFloat { 20 }

    /// Gap between major sections inside a column.
    var sectionGap: CGFloat { 24 }
    /// Gap between cards in a grid.
    var cardGap: CGFloat { 12 }

    /// Content width once the gutters are removed.
    var contentWidth: CGFloat { max(0, width - paddingX * 2) }

    // MARK: Execution rail

    /// Mirrors `clamp(300px, 23vw, 340px)`.
    var railWidth: CGFloat { min(340, max(300, width * 0.23)) }

    /// The rail may only appear when the primary column stays comfortable
    /// beside it. Below this the activity panel moves back inline.
    static let railBreakpoint: CGFloat = 1180

    var allowsRail: Bool { width >= Self.railBreakpoint }

    // MARK: Smart tasks

    /// Deliberate column counts rather than letting cards drift to odd widths.
    /// The 620pt step exists for the narrow split pane, which would otherwise
    /// drop to a single column while still having room for two.
    var taskColumns: Int {
        if width >= 1360 { return 4 }
        if width >= 1100 { return 3 }
        if width >= 620 { return 2 }
        return 1
    }

    var taskCardMinHeight: CGFloat { isNarrow ? 100 : 112 }

    // MARK: Readability caps

    /// An ultra-wide readability cap only. It must stay above a 1600pt window
    /// with the sidebar collapsed, otherwise the workspace leaves the blank
    /// right-hand strip this layout exists to remove. Long prose is already
    /// held to `proseWidth`, so the column itself can safely be this wide.
    var maxColumnWidth: CGFloat { 1680 }

    /// Long assistant prose is held to a comfortable measure (~80 characters)
    /// even though cards, code, diffs, and tool output use the full column.
    var proseWidth: CGFloat { 720 }

    /// User messages hug their content but never dominate the column.
    var userBubbleWidth: CGFloat {
        let column = contentWidth > 0 ? contentWidth : 820
        return min(column * 0.72, 820)
    }
}

extension View {
    /// Applies the workspace column grid: a leading-aligned column that fills
    /// the pane up to the ultra-wide readability cap. Used by the scroll region
    /// and the composer so their edges align exactly.
    func workspaceColumn(_ metrics: AgentWorkspaceMetrics) -> some View {
        self
            .frame(maxWidth: metrics.maxColumnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
