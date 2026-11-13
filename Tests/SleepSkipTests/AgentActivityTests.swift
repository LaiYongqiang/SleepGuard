#if canImport(XCTest)
import Foundation
import XCTest
@testable import SleepSkipCore

final class AgentActivityTests: XCTestCase {
    private var clock: Date = Date(timeIntervalSince1970: 1_700_000_000)
    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    private func makeTracker(
        policy: AgentActivityPolicy = AgentActivityPolicy(activityWindow: 30, gracePeriod: 300, maxAutoSessionDuration: 7200)
    ) -> AgentActivityTracker {
        AgentActivityTracker(policy: policy, nowProvider: { self.clock })
    }

    func testFreshTrackerIsInactive() {
        XCTAssertEqual(makeTracker().evaluate(), .inactive)
    }

    func testRecordedActivityIsActive() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        guard case .active(let agents, let lastActivity) = tracker.evaluate() else {
            return XCTFail("expected active")
        }
        XCTAssertEqual(agents, ["claude-code"])
        XCTAssertEqual(lastActivity, clock)
        XCTAssertTrue(tracker.shouldHoldAssertion(for: tracker.evaluate()))
    }

    func testQuietInsideWindowStaysActive() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(20)
        XCTAssertTrue(tracker.evaluate().isHolding)
    }

    func testQuietPastWindowEntersGrace() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(60)
        guard case .grace = tracker.evaluate() else {
            return XCTFail("expected grace")
        }
        XCTAssertTrue(tracker.shouldHoldAssertion(for: tracker.evaluate()))
    }

    func testQuietPastGraceReleases() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(30 + 300 + 1)
        XCTAssertEqual(tracker.evaluate(), .inactive)
        XCTAssertFalse(tracker.shouldHoldAssertion(for: tracker.evaluate()))
    }

    func testParallelSessionsHoldWhileAnyIsActive() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(10)
        tracker.recordActivity(sourceID: "codex")
        advance(25) // claude-code is quiet, codex still active
        guard case .active(let agents, _) = tracker.evaluate() else {
            return XCTFail("expected active")
        }
        XCTAssertEqual(agents, ["codex"])
    }

    func testHardCeilingReleasesEvenWhenActive() {
        let tracker = makeTracker(policy: AgentActivityPolicy(activityWindow: 30, gracePeriod: 300, maxAutoSessionDuration: 120))
        // Keep the agent writing past the ceiling.
        for _ in 0..<10 {
            tracker.recordActivity(sourceID: "claude-code")
            advance(20)
        }
        XCTAssertTrue(tracker.autoSessionExceeded())
        XCTAssertFalse(tracker.shouldHoldAssertion(for: tracker.evaluate()))

        // Hitting the ceiling must not disable auto-follow for the rest of the app's lifetime.
        tracker.restartSessionWindow()
        tracker.recordActivity(sourceID: "claude-code")
        XCTAssertFalse(tracker.autoSessionExceeded())
        XCTAssertTrue(tracker.shouldHoldAssertion(for: tracker.evaluate()))
    }

    func testResetClearsSession() {
        let tracker = makeTracker()
        tracker.recordActivity(sourceID: "claude-code")
        advance(200)
        tracker.reset()
        XCTAssertEqual(tracker.evaluate(), .inactive)
        XCTAssertFalse(tracker.autoSessionExceeded())
    }

    func testDefaultSourcesPointAtTranscriptDirectories() {
        let home = URL(fileURLWithPath: "/Users/example")
        let sources = AgentSource.defaults(homeDirectory: home)
        XCTAssertEqual(sources.map(\.id), ["claude-code", "codex", "dsh"])
        XCTAssertEqual(sources[0].path, "/Users/example/.claude/projects")
        XCTAssertEqual(sources[2].path, "/Users/example/.dsh/sessions")
    }

    func testTranscriptSuffixesArePerSource() {
        let home = URL(fileURLWithPath: "/Users/example")
        let sources = AgentSource.defaults(homeDirectory: home)
        let claude = sources[0]
        let dsh = sources[2]

        // DSH writes compressed transcripts, so a plain `.jsonl` check would miss it entirely.
        XCTAssertTrue(dsh.matches(filePath: "/Users/example/.dsh/sessions/p/session.v4.jsonl.zstd"))
        XCTAssertTrue(dsh.matches(filePath: "/Users/example/.dsh/sessions/p/s.jsonl"))
        XCTAssertFalse(claude.matches(filePath: "/Users/example/.claude/projects/p/s.jsonl.zstd"))
        XCTAssertTrue(claude.matches(filePath: "/Users/example/.claude/projects/p/s.jsonl"))

        // A sibling directory sharing the prefix must not be attributed to the source.
        XCTAssertFalse(dsh.matches(filePath: "/Users/example/.dsh/sessions-old/s.jsonl"))
    }
}
#endif
