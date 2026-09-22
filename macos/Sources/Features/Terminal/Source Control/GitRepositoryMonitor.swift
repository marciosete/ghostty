import Combine
import CoreServices
import Foundation

/// Keeps the status of one repository up to date by watching its files.
///
/// Any change in the working tree, or to the index, HEAD or refs in the git directory,
/// triggers a new `git status`. Changes are coalesced so at most one `git status` runs
/// at a time. Monitors are shared: every panel showing the same repository uses the
/// same monitor, which stops watching when the last one lets go of it.
final class GitRepositoryMonitor {
    let repository: Git.Repository

    /// The latest status, or nil until the first `git status` finishes.
    @Published private(set) var status: GitStatus?

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.git-monitor", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private var stream: FSEventStreamRef?
    private let eventSink = EventSink()

    private let lock = NSLock()
    private var refreshScheduled = false

    // MARK: Shared Monitors

    private static var monitors: [Git.Repository: WeakMonitor] = [:]

    /// Returns the monitor for a repository, creating it if needed. Must be called on
    /// the main thread. The caller keeps the monitor alive by holding on to it.
    static func monitor(for repository: Git.Repository) -> GitRepositoryMonitor {
        if let existing = monitors[repository]?.value {
            return existing
        }

        monitors = monitors.filter { $0.value.value != nil }
        let monitor = GitRepositoryMonitor(repository: repository)
        monitors[repository] = WeakMonitor(value: monitor)
        return monitor
    }

    private init(repository: Git.Repository) {
        self.repository = repository
        queue.setSpecific(key: queueKey, value: ())
        eventSink.monitor = self
        startWatching()
        setNeedsRefresh()
    }

    deinit {
        guard let stream else { return }
        let teardown = {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        // Tear down on our queue so no event callback is running at the same time. The
        // last reference can be dropped on our queue itself, and syncing to it from
        // there would deadlock.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync(execute: teardown)
        }
    }

    // MARK: Refresh

    /// Schedules a `git status`. Calls made while one is already scheduled are merged.
    func setNeedsRefresh() {
        lock.lock()
        defer { lock.unlock() }
        guard !refreshScheduled else { return }
        refreshScheduled = true

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.refreshScheduled = false
            self.lock.unlock()

            guard let status = Git.status(of: self.repository) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.status != status else { return }
                self.status = status
            }
        }
    }

    // MARK: File Events

    private func startWatching() {
        var paths = [repository.root.path]
        if !repository.gitDir.path.hasPrefix(repository.root.path + "/") {
            // Worktrees and submodules keep their git directory elsewhere.
            paths.append(repository.gitDir.path)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(eventSink).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            sink.monitor?.handleEvents(paths.prefix(count))
        }

        let flags = kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(flags)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handleEvents<S: Sequence>(_ paths: S) where S.Element == String {
        let gitDir = repository.gitDir.path
        let relevant = paths.contains { path in
            // Anything in the working tree may change the status.
            guard path == gitDir || path.hasPrefix(gitDir + "/") else { return true }

            // Inside the git directory, only the index (staging), HEAD and refs
            // (commits, branch switches) matter. Ignoring the rest (objects, logs,
            // lock files) avoids needless refreshes.
            let name = path.dropFirst(gitDir.count + 1)
            return name == "index" ||
                name == "HEAD" ||
                name == "packed-refs" ||
                name == "MERGE_HEAD" ||
                name == "info/exclude" ||
                name.hasPrefix("refs/")
        }

        if relevant { setNeedsRefresh() }
    }

    /// The FSEvents callback holds this instead of the monitor so a callback can never
    /// reach a monitor that is being deallocated.
    private final class EventSink {
        weak var monitor: GitRepositoryMonitor?
    }

    private struct WeakMonitor {
        weak var value: GitRepositoryMonitor?
    }
}
