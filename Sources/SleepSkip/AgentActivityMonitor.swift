import CoreServices
import Foundation
import SleepSkipCore

/// Watches agent transcript directories with FSEvents and reports activity transitions.
///
/// Deliberately event-driven: no polling and no file reads. Only the fact that a `.jsonl` file
/// under a watched directory changed is observed — never its contents.
///
/// One-shot timers are scheduled *relative to the last write* so the state machine is re-evaluated
/// when an agent goes quiet. Without them a silent agent would hold the assertion forever, since
/// no further FSEvents callback would arrive to notice the silence.
final class AgentActivityMonitor {
    private let tracker: AgentActivityTracker
    private let onStateChange: (AgentActivityState) -> Void
    private let onSessionLimitReached: () -> Void

    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var lastReported: AgentActivityState = .inactive
    private var didReportLimit = false
    /// One-shot timer armed after each write, fired once to evaluate the post-activity state.
    private var quietTimer: DispatchWorkItem?

    /// Serial queue for FSEvents callbacks. Events mutate tracker state, which is lock-protected;
    /// UI-facing callbacks are hopped to the main queue by the owner.
    private let eventQueue = DispatchQueue(label: "io.github.laiyongqiang.SleepSkip.fsevents")

    /// Path suffix → source id, so an event can be attributed without inspecting content.
    private var suffixToSource: [(suffix: String, sourceID: String)] = []

    var isRunning: Bool { stream != nil }

    init(
        tracker: AgentActivityTracker,
        onStateChange: @escaping (AgentActivityState) -> Void,
        onSessionLimitReached: @escaping () -> Void = {}
    ) {
        self.tracker = tracker
        self.onStateChange = onStateChange
        self.onSessionLimitReached = onSessionLimitReached
    }

    deinit {
        stop()
    }

    /// Starts watching every source whose directory exists. Missing directories are skipped,
    /// so a machine without Codex installed simply watches Claude Code.
    func start(sources: [AgentSource] = AgentSource.defaults()) {
        stop()

        let fileManager = FileManager.default
        let existing = sources.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }

        watchedPaths = existing.map(\.path)
        // Match on the full watched path: two different sources can share a last component.
        suffixToSource = existing.map { (suffix: $0.path, sourceID: $0.id) }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<AgentActivityMonitor>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes makes eventPaths a CFArray of CFString.
            guard let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else {
                return
            }
            monitor.handleEvents(paths: array, count: Int(eventCount))
        }

        // File-level events so new session files are noticed as they appear. UseCFTypes is
        // required for the callback above; NoDefer keeps latency low without a coalescing delay.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(created, eventQueue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPaths = []
        suffixToSource = []
        quietTimer?.cancel()
        quietTimer = nil
        lastReported = .inactive
        didReportLimit = false
        tracker.reset()
    }

    private func handleEvents(paths: [String], count: Int) {
        var matched = false
        for path in paths.prefix(count) where path.hasSuffix(".jsonl") {
            if let source = suffixToSource.first(where: { path.contains($0.suffix) }) {
                tracker.recordActivity(sourceID: source.sourceID)
                matched = true
            }
        }
        guard matched else { return }
        scheduleQuietEvaluation()
        reportCurrentState()
    }

    /// Re-evaluates once the activity window lapses, and once more after the grace period ends.
    /// Both are one-shot: nothing runs while the agent is quiet and already released.
    private func scheduleQuietEvaluation() {
        quietTimer?.cancel()
        let policy = tracker.currentPolicy
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reportCurrentState()
            if case .grace = self.tracker.evaluate() {
                self.scheduleGraceExpiry(after: policy.gracePeriod)
            }
        }
        quietTimer = work
        eventQueue.asyncAfter(deadline: .now() + policy.activityWindow, execute: work)
    }

    private func scheduleGraceExpiry(after delay: TimeInterval) {
        quietTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reportCurrentState()
        }
        quietTimer = work
        eventQueue.asyncAfter(deadline: .now() + delay + 0.5, execute: work)
    }

    private func reportCurrentState() {
        if tracker.autoSessionExceeded() {
            if !didReportLimit {
                didReportLimit = true
                onSessionLimitReached()
            }
            // Start a new window so a still-busy agent can be followed again after the release.
            // Without this the tracker stays past its ceiling forever and auto-follow dies
            // until the app restarts.
            tracker.restartSessionWindow()
            didReportLimit = false
            lastReported = .inactive
            quietTimer?.cancel()
            quietTimer = nil
            return
        }

        let state = tracker.evaluate()
        // Only report transitions the UI would actually render differently.
        guard state.displayEquivalent != lastReported.displayEquivalent else { return }
        lastReported = state
        onStateChange(state)
    }
}
