import Foundation
import Synchronization
@testable import PostfrauCore

/// Whether this machine's keychain can actually be written to, decided without hanging.
///
/// `SecItemAdd` does not fail when the login keychain needs an authorization nobody is there to
/// give — it blocks, forever, on a dialog. A probe that calls it directly therefore takes the
/// whole test run down with it, which is how a locked keychain turned a six-second suite into an
/// indefinite hang. The call is made on its own thread and given a deadline; if it does not come
/// back, the keychain is treated as unusable and the tests that need it skip.
///
/// The stranded thread is deliberate. It is blocked in the Security framework and cannot be
/// interrupted; it costs one thread for the rest of a test process that is about to exit anyway,
/// which is a far better trade than never finishing.
enum KeychainProbe {
    static let deadline: DispatchTimeInterval = .seconds(3)

    /// Cached: the answer cannot change during a run, and each probe costs up to `deadline`.
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
