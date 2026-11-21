import Foundation

public protocol TVInfoFetching: Sendable {
    func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo
}

public struct HTTPTVInfoFetcher: TVInfoFetching {
    static let port: UInt16 = 8001
    /// The longest a stall check waits for the TCP connection.
    static let connectCheckTimeout: Duration = .seconds(1)

    private let session: URLSession
    private let timeout: Duration
    private let maxBytes: Int
    private let stallBudget: Duration
    private let prober: any PortProbing
    private let allowLoopback: Bool

    /// Each attempt gets `timeout`. Some TVs (a 2024 model in testing) accept the connection and then send
    /// nothing for several seconds while they are on: with a non-zero `stallBudget`, an attempt that times
    /// out while the TV still accepts a TCP connection is made again, until `stallBudget` has passed since the
    /// first attempt began. A TV that is off the network accepts no connection, so it fails after one
    /// attempt, as without a budget; refusals and non-TV answers are never retried.
    public init(session: URLSession = .shared, timeout: Duration = .seconds(2), maxBytes: Int = 64 * 1024,
                stallBudget: Duration = .zero) {
        self.init(session: session, timeout: timeout, maxBytes: maxBytes, stallBudget: stallBudget,
                  prober: NWPortProber(), allowLoopback: false)
    }

    init(session: URLSession, timeout: Duration, maxBytes: Int, stallBudget: Duration = .zero,
         prober: any PortProbing = NWPortProber(), allowLoopback: Bool) {
        self.session = session
        self.timeout = timeout
        self.maxBytes = maxBytes
        self.stallBudget = stallBudget
        self.prober = prober
        self.allowLoopback = allowLoopback
    }

    public func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo {
        guard LocalAddress.isAllowed(host, allowLoopback: allowLoopback),
              let url = URL(string: "http://\(host):\(Self.port)/api/v2/") else { throw .notLocalAddress }
        let clock = ContinuousClock()
        let deadline = clock.now + stallBudget
        var attemptTimeout = timeout
        while true {
            switch await attempt(url, timeout: attemptTimeout) {
            case .success(let body):
                return try TVDeviceInfo.decode(body, host: host)
            case .failure(let error):
                throw error
            case .timedOut:
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero, !Task.isCancelled else { throw .unreachable }
                let connectTimeout = min(Self.connectCheckTimeout, timeout, remaining)
                guard await prober.isOpen(host: host, port: Self.port, timeout: connectTimeout) else {
                    throw .unreachable // nothing accepts the connection: off, or gone from this address
                }
                let left = clock.now.duration(to: deadline)
                guard left > .zero, !Task.isCancelled else { throw .unreachable }
                attemptTimeout = min(timeout, left)
            }
        }
    }

    private enum AttemptResult {
        case success(Data)
        /// No answer in time (or the connection dropped mid-answer): worth asking again if the TV is there.
        case timedOut
        case failure(TVInfoError)
    }

    private func attempt(_ url: URL, timeout: Duration) async -> AttemptResult {
        var request = URLRequest(url: url)
        // Power decisions depend on the TV's current state, never a cached answer.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (seconds, attoseconds) = timeout.components
        request.timeoutInterval = Double(seconds) + Double(attoseconds) / 1e18

        // `timeoutInterval` only bounds the gap between packets; a body dripping in slowly would never
        // trip it, so the whole fetch also races an overall deadline of `timeout`.
        let finalRequest = request
        do {
            return .success(try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await download(finalRequest) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw TVInfoError.unreachable }
                return first
            })
        } catch let error as TVInfoError {
            return .failure(error)
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            return .timedOut
        } catch {
            return .failure(.unreachable)
        }
    }

    private func download(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirectDelegate())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw TVInfoError.unreachable }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > maxBytes { throw TVInfoError.tooLarge }
        }
        return body
    }
}

/// Redirects could lead off the LAN; refuse them so a 3xx surfaces as a non-200 response.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
