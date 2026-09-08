import Foundation
import Synchronization
import PostfrauCore

/// Whether this machine's keychain can be written to, decided without hanging.
///
/// The same guard the Core tests use, and for the same reason: `SecItemAdd` does not fail when
/// the login keychain needs an authorization nobody is there to give — it blocks on a dialog,
/// forever. The probe runs on its own thread with a deadline; a keychain that does not answer in
/// time is treated as unusable and the tests that need it skip.
enum AppKeychainProbe {
    static let deadline: DispatchTimeInterval = .seconds(3)

    private static let usable: Bool = {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex(false)

        Thread.detachNewThread {
            let store = Keychain(service: "com.postfrau.tests.probe.\(UUID().uuidString)")
            do {
                try store.set("probe", for: "probe")
                let read = try store.get("probe")
                try store.delete("probe")
                result.withLock { $0 = read == "probe" }
            } catch {
                result.withLock { $0 = false }
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + deadline) == .success else { return false }
        return result.withLock { $0 }
    }()

    static var isKeychainUsable: Bool { usable }
}
