import Foundation

/// Watches the data folder for changes Postfrau did not make.
///
/// Two mechanisms, because neither alone covers the folders people actually use:
///
/// - `NSFilePresenter` is what iCloud Drive and any other `NSFileCoordinator` client announce
///   through. It is the only way to hear about a coordinated write before it lands.
/// - A `DispatchSource` on the directory catches everything else — Dropbox and Google Drive write
///   through plain POSIX calls, and so does `git checkout` or a text editor.
///
/// Both are noisy: one sync of a folder can produce dozens of events. They are coalesced for
/// `settleInterval` and then answered with a single diff, so a burst costs one scan.
public final class FolderWatcher: NSObject, @unchecked Sendable {
    // `NSFilePresenter` conformance is required by AppKit on an object it calls from its own
    // queue, so this cannot be an actor. Everything mutable below is guarded by `lock`.

    /// How long events are gathered before the folder is diffed.
    public static let settleInterval = Duration.milliseconds(500)

    private let lock = NSLock()
    private var folder: DataFolder
    /// One per watched directory. Each source closes its own descriptor when cancelled.
    private var sources: [DispatchSourceFileSystemObject] = []
    private var settleTask: Task<Void, Never>?
    private var isRegistered = false

    private let queue = DispatchQueue(label: "com.postfrau.folder-watcher")
    private let presenterQueue = OperationQueue()

    /// Called on the main actor once a burst of events has settled.
    private let onChange: @MainActor @Sendable () -> Void

    public init(folder: DataFolder, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.folder = folder
        self.onChange = onChange
        presenterQueue.maxConcurrentOperationCount = 1
        presenterQueue.name = "com.postfrau.folder-presenter"
        super.init()
    }

    deinit {
        settleTask?.cancel()
        for source in sources { source.cancel() }
        if isRegistered { NSFileCoordinator.removeFilePresenter(self) }
    }

    // MARK: - Lifecycle

    public func start() {
        stop()
        lock.withLock {
            NSFileCoordinator.addFilePresenter(self)
            isRegistered = true
        }
        startDispatchSource()
    }

    public func stop() {
        let (task, existing, registered) = lock.withLock {
            let values = (settleTask, sources, isRegistered)
            settleTask = nil
            sources = []
            isRegistered = false
            return values
        }
        task?.cancel()
        for source in existing { source.cancel() }
        if registered { NSFileCoordinator.removeFilePresenter(self) }
    }

    /// Points the watcher at a different folder, restarting it.
    public func retarget(to folder: DataFolder) {
        stop()
        lock.withLock { self.folder = folder }
        start()
    }

    private func startDispatchSource() {
        let root = lock.withLock { folder.root }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Watching the two subfolders as well: a write inside `collections/` does not change the
        // root directory, so a source on the root alone would never fire for the common case.
        for directory in [root, root.appending(path: "collections"), root.appending(path: "environments")] {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: queue)
            source.setEventHandler { [weak self] in self?.scheduleSettle() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            lock.withLock { sources.append(source) }
        }
    }

    // MARK: - Coalescing

    /// Restarts the settle timer. A burst of fifty events therefore costs one diff, not fifty.
    private func scheduleSettle() {
        let previous = lock.withLock { settleTask }
        previous?.cancel()

        let task = Task { [weak self] in
            try? await Task.sleep(for: FolderWatcher.settleInterval)
            guard !Task.isCancelled, let self else { return }
            await self.onChange()
        }
        lock.withLock { settleTask = task }
    }
}

// MARK: - NSFilePresenter

extension FolderWatcher: NSFilePresenter {
    public var presentedItemURL: URL? { lock.withLock { folder.root } }
    public var presentedItemOperationQueue: OperationQueue { presenterQueue }

    public func presentedSubitemDidChange(at url: URL) {
        guard url.pathExtension == "json" else { return }
        scheduleSettle()
    }

    public func presentedItemDidChange() {
        scheduleSettle()
    }

    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        scheduleSettle()
    }

    public func accommodatePresentedSubitemDeletion(
        at url: URL, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        scheduleSettle()
        completionHandler(nil)
    }
}
