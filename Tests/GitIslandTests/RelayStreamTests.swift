import Foundation
import XCTest
@testable import GitIsland

final class RelayStreamTests: XCTestCase {
    func testBurstDuringReadProducesExactlyOneCatchUp() {
        var demand = RelayRefreshDemand()
        let now = Date()
        demand.request()
        XCTAssertTrue(demand.take(isLoading: false, now: now, notBefore: nil))
        for _ in 0..<100 {
            demand.request()
            XCTAssertFalse(demand.take(isLoading: true, now: now, notBefore: nil))
        }
        XCTAssertTrue(demand.take(isLoading: false, now: now, notBefore: nil))
        XCTAssertFalse(demand.take(isLoading: false, now: now, notBefore: nil))
    }

    func testDemandSurvivesRateLimitUntilDeadline() {
        var demand = RelayRefreshDemand()
        let now = Date()
        let deadline = now.addingTimeInterval(60)
        demand.request()
        XCTAssertFalse(demand.take(isLoading: false, now: now, notBefore: deadline))
        demand.request()
        XCTAssertFalse(demand.take(isLoading: false, now: now.addingTimeInterval(59), notBefore: deadline))
        XCTAssertTrue(demand.take(isLoading: false, now: deadline, notBefore: deadline))
        XCTAssertFalse(demand.take(isLoading: false, now: deadline, notBefore: deadline))
    }

    func testExpiredFrameIsNotAWakeAndNeedsNoData() {
        var parser = RelayEventParser()
        _ = parser.consume(": connected")
        XCTAssertNil(parser.consume("event: expired"))
        XCTAssertEqual(parser.consume(""), .expired)
        XCTAssertNil(parser.consume(""))
        XCTAssertNotNil(RelayConfiguration(origin: "https://relay.example", token: "v2.access"))
    }

    func testHandshakeAndPingsDoNotDispatchExtraReads() {
        var parser = RelayEventParser()
        XCTAssertEqual(parser.consume(": connected"), .connected)
        XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume(": ping"))
        XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume(": connected"))
    }

    func testWakeDispatchesOnlyAtFrameBoundaryAndResets() {
        var parser = RelayEventParser()
        _ = parser.consume(": connected")
        XCTAssertNil(parser.consume("event: wake"))
        XCTAssertNil(parser.consume("data: {\"app\":\"5332457\",\"type\":\"hook\"}"))
        XCTAssertEqual(parser.consume(""), .wake)
        XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume("event: other"))
        XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume("data: ignored"))
        XCTAssertNil(parser.consume(""))
    }

    func testWakeBeforeHandshakeDoesNotConnect() {
        var parser = RelayEventParser()
        _ = parser.consume("event: wake")
        XCTAssertNil(parser.consume(""))
    }

    func testHTTP200RequiresEventStreamMediaType() {
        let url = URL(string: "https://relay.example/stream")!
        for (status, type, accepted) in [(200, "text/event-stream", true),
                                        (200, "text/event-stream; charset=utf-8", true),
                                        (200, "text/html", false),
                                        (401, "text/event-stream", false),
                                        (302, "text/event-stream", false)] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": type])!
            XCTAssertEqual(RelayStream.accepts(response), accepted)
        }
    }

    func testConfigurationRejectsUnsafeOriginsAndUsesOnlyComputerToken() throws {
        for origin in ["http://relay.example", "https://user:pass@relay.example", "https://relay.example/path",
                       "https://relay.example?token=x", "https://relay.example#fragment", ""] {
            XCTAssertNil(RelayConfiguration(origin: origin, token: "v1.test"))
        }
        XCTAssertNil(RelayConfiguration(origin: "https://relay.example", token: nil))
        XCTAssertNil(RelayConfiguration(origin: "https://relay.example", token: "gho_oauth"))
        let config = try XCTUnwrap(RelayConfiguration(origin: "https://relay.example", token: "v1.test"))
        let request = config.request(path: "stream")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer v1.test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Last-Event-ID"))
    }

    func testHookRevocationPreservesPathSeparators() throws {
        for origin in ["https://relay.example", "https://relay.example/"] {
            let config = try XCTUnwrap(RelayConfiguration(origin: origin, token: "v1.test"))
            let hookURL = try XCTUnwrap(URL(string: "https://relay.example/hooks/example-id"))
            let request = config.request(path: String(hookURL.path.dropFirst()), method: "DELETE")
            XCTAssertEqual(request.url?.absoluteString, hookURL.absoluteString)
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer v1.test")
        }
    }

    func testImmediateRelayReadStillRespectsRateLimitAndInFlightRead() {
        let now = Date()
        func decision(loading: Bool, deadline: Date?) -> RefreshStartDecision {
            RefreshGate.startDecision(isAuthenticated: true, isLoading: loading, force: false,
                now: now, nextAllowedRefreshDate: deadline, lastRefreshAttemptDate: now, minimumSpacing: 0)
        }
        XCTAssertEqual(decision(loading: false, deadline: nil), .start)
        XCTAssertEqual(decision(loading: true, deadline: nil), .skipLoading)
        XCTAssertEqual(decision(loading: false, deadline: now.addingTimeInterval(60)), .skipRateLimited)
    }
}
