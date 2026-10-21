import AppKit
import XCTest
@testable import GitIsland

final class IslandPanelMouseRoutingTests: XCTestCase {
    @MainActor
    func testCompactPanelPassesThroughEvenOverNotch() {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.updateMouseRouting(isExpanded: false, pointerInsideSurface: false)
        XCTAssertTrue(panel.ignoresMouseEvents, "Transparent wings must not consume menu-bar clicks")
        panel.updateMouseRouting(isExpanded: false, pointerInsideSurface: true)
        XCTAssertTrue(panel.ignoresMouseEvents, "Compact hover must be detected independently of click capture")
    }

    @MainActor
    func testExpandedPanelReleasesClicksBeforeCollapseDelay() {
        let panel = IslandPanel(contentRect: NSRect(x: 400, y: 600, width: 420, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let frame = panel.frame
        panel.updateMouseRouting(isExpanded: true, pointerInsideSurface: true)
        XCTAssertFalse(panel.ignoresMouseEvents, "PR controls must remain clickable")
        panel.updateMouseRouting(isExpanded: true, pointerInsideSurface: false)
        XCTAssertTrue(panel.ignoresMouseEvents, "Menu items and retained transparent host space must receive clicks immediately")
        XCTAssertEqual(panel.frame, frame, "Input routing must not move or shrink the expanded host")
        panel.updateMouseRouting(isExpanded: true, pointerInsideSurface: true)
        XCTAssertFalse(panel.ignoresMouseEvents)
        panel.updateMouseRouting(isExpanded: false, pointerInsideSurface: true)
        XCTAssertTrue(panel.ignoresMouseEvents, "Collapse animation must not retain click capture")
    }
}
