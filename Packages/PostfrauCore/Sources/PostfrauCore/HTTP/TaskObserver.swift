import Foundation
import Synchronization

/// Per-send `URLSession` task delegate.
///
/// One instance is created for each send and passed to `bytes(for:delegate:)`, so redirect hops,
/// metrics and the TLS decision are scoped to that request rather than shared across a session.
/// `URLSession` invokes these callbacks on its own queue, so all mutable state lives behind a
/// `Mutex`; the object itself holds only immutable references and is therefore `Sendable`.
final class TaskObserver: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, Sendable {
    struct Options: Sendable {
        var verifyTLS: Bool
        var followRedirects: Bool
        var maxRedirects: Int
        /// Bytes past which the transfer is abandoned rather than downloaded to the end.
        var byteCap: Int
    }

    private struct State {
        var redirects: [RedirectHop] = []
        var metrics: URLSessionTaskMetrics?
        var hitRedirectLimit = false
        var exceededByteCap = false
    }

    private let options: Options
    private let state = Mutex(State())

    init(options: Options) {
        self.options = options
    }

    var redirects: [RedirectHop] { state.withLock { $0.redirects } }
    var hitRedirectLimit: Bool { state.withLock { $0.hitRedirectLimit } }
    /// True when *we* cancelled the transfer because it grew past the cap, which lets the
    /// executor report "too large" instead of the `URLError.cancelled` the cancel produces.
    var exceededByteCap: Bool { state.withLock { $0.exceededByteCap } }

    /// The timing breakdown, derived from the last transaction's metrics.
    func timing(fallbackTotal: TimeInterval) -> Timing {
        guard let metrics = state.withLock({ $0.metrics }),
              let transaction = metrics.transactionMetrics.last
        else {
            return Timing(total: fallbackTotal)
        }

        func span(_ start: Date?, _ end: Date?) -> TimeInterval? {
            guard let start, let end else { return nil }
            let interval = end.timeIntervalSince(start)
            return interval >= 0 ? interval : nil
        }

        return Timing(
            total: metrics.taskInterval.duration,
            dns: span(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connect: span(transaction.connectStartDate, transaction.connectEndDate),
            tls: span(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            request: span(transaction.requestStartDate, transaction.requestEndDate),
            ttfb: span(transaction.requestEndDate, transaction.responseStartDate),
            download: span(transaction.responseStartDate, transaction.responseEndDate))
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let hop = RedirectHop(
            statusCode: response.statusCode,
            url: response.url?.absoluteString ?? "",
            location: request.url?.absoluteString ?? "")

        let shouldFollow = state.withLock { state -> Bool in
            state.redirects.append(hop)
            guard self.options.followRedirects else { return false }
            if state.redirects.count > self.options.maxRedirects {
                state.hitRedirectLimit = true
                return false
            }
            return true
        }
        // Handing back nil stops the redirect and delivers the 3xx response as-is, which is
        // exactly what "don't follow redirects" should show the user.
        completionHandler(shouldFollow ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            return completionHandler(.performDefaultHandling, nil)
        }
        // Only bypass validation when the user explicitly turned "Verify TLS certificates" off
        // for this request.
        guard !options.verifyTLS else { return completionHandler(.performDefaultHandling, nil) }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        state.withLock { $0.metrics = metrics }
    }

    // MARK: - URLSessionDownloadDelegate

    /// Stops a runaway download as it happens rather than after 200 MB have hit the disk.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let overCap = totalBytesWritten > Int64(options.byteCap)
            || totalBytesExpectedToWrite > Int64(options.byteCap)
        guard overCap else { return }
        state.withLock { $0.exceededByteCap = true }
        downloadTask.cancel()
    }

    /// Required by `URLSessionDownloadDelegate`, but `download(for:delegate:)` owns the file and
    /// hands it to the caller, so there is nothing for us to do here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
