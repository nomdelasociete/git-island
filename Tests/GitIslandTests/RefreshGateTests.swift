import Foundation
import XCTest
@testable import GitIsland

final class RefreshGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testForcedRefreshRestartsInFlightRefresh() {
        let decision = RefreshGate.startDecision(
            isAuthenticated: true,
            isLoading: true,
            force: true,
            now: now,
            nextAllowedRefreshDate: nil,
            lastRefreshAttemptDate: now,
            minimumSpacing: 15
        )

        XCTAssertEqual(decision, .cancelInFlightAndStart)
    }

    func testAutomaticRefreshDoesNotRestartInFlightRefresh() {
        let decision = RefreshGate.startDecision(
            isAuthenticated: true,
            isLoading: true,
            force: false,
            now: now,
            nextAllowedRefreshDate: nil,
            lastRefreshAttemptDate: now,
            minimumSpacing: 15
        )

        XCTAssertEqual(decision, .skipLoading)
    }

    func testForcedRefreshBypassesMinimumSpacing() {
        let decision = RefreshGate.startDecision(
            isAuthenticated: true,
            isLoading: false,
            force: true,
            now: now,
            nextAllowedRefreshDate: nil,
            lastRefreshAttemptDate: now.addingTimeInterval(-2),
            minimumSpacing: 15
        )

        XCTAssertEqual(decision, .start)
    }

    func testAutomaticRefreshRespectsMinimumSpacing() {
        let decision = RefreshGate.startDecision(
            isAuthenticated: true,
            isLoading: false,
            force: false,
            now: now,
            nextAllowedRefreshDate: nil,
            lastRefreshAttemptDate: now.addingTimeInterval(-2),
            minimumSpacing: 15
        )

        XCTAssertEqual(decision, .skipMinimumSpacing)
    }

    func testRateLimitBlocksForcedRefresh() {
        let decision = RefreshGate.startDecision(
            isAuthenticated: true,
            isLoading: false,
            force: true,
            now: now,
            nextAllowedRefreshDate: now.addingTimeInterval(60),
            lastRefreshAttemptDate: nil,
            minimumSpacing: 15
        )

        XCTAssertEqual(decision, .skipRateLimited)
    }

    func testDiagnosticsRecordStartedAndFinishedRefresh() {
        let startedAt = now
        let finishedAt = now.addingTimeInterval(1.25)

        let diagnostics = RefreshDiagnostics()
            .started(at: startedAt, reason: .manual)
            .finished(at: finishedAt, startedAt: startedAt, message: "Loaded 2 PRs")

        XCTAssertEqual(diagnostics.lastStartedAt, startedAt)
        XCTAssertEqual(diagnostics.lastFinishedAt, finishedAt)
        XCTAssertEqual(diagnostics.lastDuration ?? -1, 1.25, accuracy: 0.001)
        XCTAssertEqual(diagnostics.reason, .manual)
        XCTAssertFalse(diagnostics.isInFlight)
        XCTAssertEqual(diagnostics.lastMessage, "Loaded 2 PRs")
    }

    func testDiagnosticsPreserveNextScheduledRefresh() {
        let scheduledAt = now.addingTimeInterval(30)

        let diagnostics = RefreshDiagnostics()
            .withNextScheduledRefresh(scheduledAt)
            .started(at: now, reason: .timer)

        XCTAssertEqual(diagnostics.nextScheduledAt, scheduledAt)
        XCTAssertEqual(diagnostics.reason, .timer)
        XCTAssertTrue(diagnostics.isInFlight)
    }

    func testDiagnosticsStopClearsInFlightAndNextSchedule() {
        let diagnostics = RefreshDiagnostics()
            .withNextScheduledRefresh(now.addingTimeInterval(30))
            .started(at: now, reason: .userInteraction)
            .stopped()

        XCTAssertFalse(diagnostics.isInFlight)
        XCTAssertNil(diagnostics.nextScheduledAt)
        XCTAssertEqual(diagnostics.lastMessage, "Refresh stopped")
    }
}
