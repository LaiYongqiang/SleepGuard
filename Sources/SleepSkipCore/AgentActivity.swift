import Foundation

/// One place worth watching for agent activity.
public struct AgentSource: Equatable, Sendable {
    /// Stable identifier used in state payloads, e.g. `"claude-code"`.
    public let id: String
    /// Name shown in the UI, e.g. `"Claude Code"`.
    public let displayName: String
    /// Directory that receives transcript writes while the agent works.
    public let path: String
    /// Filename suffixes that count as a transcript write. Agents differ: Claude Code and Codex
    /// append plain `.jsonl`, while DSH writes compressed `session.v4.jsonl.zstd`.
    public let fileSuffixes: [String]

    public init(id: String, displayName: String, path: String, fileSuffixes: [String] = [".jsonl"]) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.fileSuffixes = fileSuffixes
    }

    /// True when `path` looks like one of this source's transcript files.
    public func matches(filePath: String) -> Bool {
        guard filePath.hasPrefix(path + "/") else { return false }
        return fileSuffixes.contains { filePath.hasSuffix($0) }
    }

    /// Sources discovered on this machine. Missing directories are skipped by the monitor.
    public static func defaults(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentSource] {
        [
            AgentSource(
                id: "claude-code",
                displayName: "Claude Code",
                path: homeDirectory.appendingPathComponent(".claude/projects").path
            ),
            AgentSource(
                id: "codex",
                displayName: "Codex",
                path: homeDirectory.appendingPathComponent(".codex/sessions").path
            ),
            AgentSource(
                id: "dsh",
                displayName: "DeepSeek Harness",
                path: homeDirectory.appendingPathComponent(".dsh/sessions").path,
                // DSH compresses its transcripts, so the extension is not `.jsonl`.
                fileSuffixes: [".jsonl.zstd", ".jsonl"]
            ),
        ]
    }
}

public enum AgentActivityState: Equatable, Sendable {
    case inactive
    case active(agents: [String], lastActivity: Date)
    /// Quiet for longer than the activity window, but still inside the grace period.
    case grace(since: Date)

    public var isHolding: Bool {
        switch self {
        case .active, .grace: return true
        case .inactive: return false
        }
    }

    /// Two `active` states with different timestamps describe the same observable situation;
    /// comparing only the agent set keeps the UI from re-rendering on every transcript write.
    public var displayEquivalent: AgentActivityState {
        switch self {
        case .active(let agents, _): return .active(agents: agents, lastActivity: .distantPast)
        case .grace(let since): return .grace(since: since)
        case .inactive: return .inactive
        }
    }
}

public struct AgentActivityPolicy: Equatable, Sendable {
    /// How long a single write keeps an agent "active".
    public let activityWindow: TimeInterval
    /// Extra time to hold after the window lapses, covering tool calls that produce no output.
    public let gracePeriod: TimeInterval
    /// Hard ceiling for one automatic session, so a chatty background process cannot pin the Mac awake all night.
    public let maxAutoSessionDuration: TimeInterval

    public init(
        activityWindow: TimeInterval = 30,
        gracePeriod: TimeInterval = 300,
        maxAutoSessionDuration: TimeInterval = 2 * 3600
    ) {
        self.activityWindow = activityWindow
        self.gracePeriod = gracePeriod
        self.maxAutoSessionDuration = maxAutoSessionDuration
    }

    public static let `default` = AgentActivityPolicy()
}

/// Pure state machine deciding whether detected agent activity should hold a wake assertion.
/// Deliberately free of timers, file I/O and AppKit so it can be exercised in tests.
public final class AgentActivityTracker: @unchecked Sendable {
    private let policy: AgentActivityPolicy
    private let nowProvider: () -> Date
    private let lock = NSLock()

    private var lastActivityBySource: [String: Date] = [:]
    private var sessionStart: Date?

    public init(policy: AgentActivityPolicy = .default, nowProvider: @escaping () -> Date = { Date() }) {
        self.policy = policy
        self.nowProvider = nowProvider
    }

    public var currentPolicy: AgentActivityPolicy { policy }

    public func recordActivity(sourceID: String) {
        let now = nowProvider()
        lock.lock()
        lastActivityBySource[sourceID] = now
        if sessionStart == nil {
            sessionStart = now
        }
        lock.unlock()
    }

    public func evaluate() -> AgentActivityState {
        evaluate(at: nowProvider())
    }

    public func evaluate(at now: Date) -> AgentActivityState {
        lock.lock()
        let lastActivity = lastActivityBySource
        lock.unlock()

        let active = lastActivity
            .filter { now.timeIntervalSince($0.value) < policy.activityWindow }
            .keys
            .sorted()

        if !active.isEmpty {
            let newest = active.compactMap { lastActivity[$0] }.max() ?? now
            return .active(agents: active, lastActivity: newest)
        }

        guard let mostRecent = lastActivity.values.max() else { return .inactive }
        let quietSince = mostRecent.addingTimeInterval(policy.activityWindow)
        if now.timeIntervalSince(quietSince) < policy.gracePeriod {
            return .grace(since: quietSince)
        }
        return .inactive
    }

    /// True once a single automatic session has run longer than the hard ceiling.
    public func autoSessionExceeded(at now: Date? = nil) -> Bool {
        let reference = now ?? nowProvider()
        lock.lock()
        let start = sessionStart
        lock.unlock()
        guard let start else { return false }
        return reference.timeIntervalSince(start) >= policy.maxAutoSessionDuration
    }

    /// Ends the current automatic session window but keeps recent activity, so a still-busy
    /// agent can be followed again immediately instead of waiting for a brand-new write.
    public func restartSessionWindow() {
        lock.lock()
        sessionStart = nowProvider()
        lock.unlock()
    }

    /// Drops all activity and ends the current automatic session.
    public func reset() {
        lock.lock()
        lastActivityBySource.removeAll()
        sessionStart = nil
        lock.unlock()
    }

    /// Whether the assertion should be held, given the state just computed.
    /// The ceiling wins over everything else so an unbounded session cannot pin the machine awake.
    public func shouldHoldAssertion(for state: AgentActivityState) -> Bool {
        guard state.isHolding else { return false }
        return !autoSessionExceeded()
    }
}
