import XCTest
@testable import GitIsland

final class AppVersionTests: XCTestCase {
    func testUsesInstalledBundleMetadata() {
        let version = AppVersion(info: [
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "203001010001"
        ])
        XCTAssertEqual(version.version, "1.2")
        XCTAssertEqual(version.build, "203001010001")
    }

    func testUnbundledBuildDoesNotInventAReleaseVersion() {
        let version = AppVersion(info: [:])
        XCTAssertEqual(version.version, "Development")
        XCTAssertEqual(version.build, "Unbundled")
    }
}
