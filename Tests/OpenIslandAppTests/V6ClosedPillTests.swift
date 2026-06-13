import CoreGraphics
import Testing
@testable import OpenIslandApp

@MainActor
struct V6ClosedPillTests {
    @Test
    func macbookWidthWrapsPhysicalNotchReserve() {
        let width = V6ClosedPill.width(
            label: "ignored",
            rightSlot: .count(3),
            layout: .macbook,
            height: 34,
            physicalNotchWidth: 224,
            minWidth: 70
        )

        #expect(width == CGFloat(224 + 88))
    }

    @Test
    func externalWidthHonorsMinimumForGlyphOnlyPill() {
        let width = V6ClosedPill.width(
            label: nil,
            rightSlot: nil,
            layout: .external,
            height: 24,
            physicalNotchWidth: 0,
            minWidth: 70
        )

        #expect(width == 70)
    }

    @Test
    func externalWidthIncludesLabelAndRightSlot() {
        let label = "repo"
        let rightSlot = IslandRightSlotContent.count(12)
        let width = V6ClosedPill.width(
            label: label,
            rightSlot: rightSlot,
            layout: .external,
            height: 34,
            physicalNotchWidth: 0,
            minWidth: 70
        )
        let expected = max(
            CGFloat(70),
            CGFloat(34 + 24 + 6 + 6)
                + V6CenterLabelView.intrinsicWidth(of: label)
                + V6RightSlotView.intrinsicWidth(of: rightSlot)
        )

        #expect(width == expected)
    }
}
