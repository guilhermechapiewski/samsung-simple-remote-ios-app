import Foundation
import Synchronization
import Testing
@testable import SamsungTVKit

private enum StubResult: Sendable {
    case response(status: Int, body: Data)
    case failure(URLError.Code)
    case redirect(to: URL)
    /// A 200 with headers, then one byte every `interval`; it gives up after `limit` bytes so a broken
    /// deadline fails the test instead of hanging it.
    case drip(interval: TimeInterval, limit: Int)
    /// The first `count` requests never answer (a TV that accepts the connection, then stalls); later ones get
    /// a 200 with `body`.
    case stallFirst(count: Int, body: Data)
}

/// Answers `open` for every probe and counts them.
private final class StallProber: PortProbing {
    let open: Bool
    private let count = Mutex(0)
    init(open: Bool) { self.open = open }
    var probes: Int { count.withLock { $0 } }
    func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
        count.withLock { $0 += 1 }
        return open
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    // Safety: all shared state lives in Mutex-protected statics; instances only touch their own URLProtocol state
    // and the Mutex-protected `stopped` flag.
    private static let state = Mutex<(result: StubResult, requests: [URL], timeouts: [TimeInterval],
                                      cachePolicies: [URLRequest.CachePolicy])>((.failure(.unknown), [], [], []))

    static func configure(_ result: StubResult) {
        state.withLock { $0 = (result, [], [], []) }
    }
    static var timeouts: [TimeInterval] { state.withLock { $0.timeouts } }
    static var requests: [URL] { state.withLock { $0.requests } }
    static var cachePolicies: [URLRequest.CachePolicy] { state.withLock { $0.cachePolicies } }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let stopped = Mutex(false)

    override func stopLoading() { stopped.withLock { $0 = true } }

    override func startLoading() {
        let url = request.url!
        let (result, index) = Self.state.withLock { s -> (StubResult, Int) in
            s.requests.append(url)
            s.timeouts.append(request.timeoutInterval)
            s.cachePolicies.append(request.cachePolicy)
            return (s.result, s.requests.count - 1)
        }
        switch result {
        case .stallFirst(let count, _) where index < count:
            return // never answers; the fetcher's deadline or URLSession's timeout ends it
        case .stallFirst(_, let body):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .response(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .drip(let interval, let limit):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            drip(every: interval, remaining: limit)
        }
    }

    private func drip(every interval: TimeInterval, remaining: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            guard remaining > 0 else { client?.urlProtocolDidFinishLoading(self); return }
            client?.urlProtocol(self, didLoad: Data(" ".utf8))
            drip(every: interval, remaining: remaining - 1)
        }
    }
}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func makeFetcher(maxBytes: Int = 64 * 1024, timeout: Duration = .seconds(2), stallBudget: Duration = .zero,
                         prober: any PortProbing = StallProber(open: false)) -> HTTPTVInfoFetcher {
    HTTPTVInfoFetcher(session: StubProtocol.makeSession(), timeout: timeout, maxBytes: maxBytes,
                      stallBudget: stallBudget, prober: prober, allowLoopback: false)
}

@Suite(.serialized)
struct HTTPTVInfoFetcherTests {
    @Test func fetchRejectsPublicHost() async throws {
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        await #expect(throws: TVInfoError.notLocalAddress) {
            try await makeFetcher().fetchInfo(host: "8.8.8.8")
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func rejectsLoopbackByDefault() async {
        StubProtocol.configure(.response(status: 200, body: Data()))
        await #expect(throws: TVInfoError.notLocalAddress) {
            try await makeFetcher().fetchInfo(host: "127.0.0.1")
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func rejectsOversizedBody() async {
        StubProtocol.configure(.response(status: 200, body: Data(repeating: 0x20, count: 70 * 1024)))
        await #expect(throws: TVInfoError.tooLarge) {
            try await makeFetcher().fetchInfo(host: "10.0.0.5")
        }
    }

    @Test func timeoutMapsToUnreachable() async {
        StubProtocol.configure(.failure(.timedOut))
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher(timeout: .milliseconds(100)).fetchInfo(host: "10.0.0.5")
        }
    }

    @Test func slowDripHitsOverallDeadline() async {
        // Each byte arrives well within the per-packet timeout, so only an overall deadline ends this.
        StubProtocol.configure(.drip(interval: 0.5, limit: 20))
        let start = ContinuousClock.now
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher(timeout: .seconds(1)).fetchInfo(host: "10.0.0.5")
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func nonOKStatusMapsToUnreachable() async {
        StubProtocol.configure(.response(status: 500, body: Data()))
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher().fetchInfo(host: "10.0.0.5")
        }
    }

    @Test func success() async throws {
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        let info = try await makeFetcher().fetchInfo(host: "10.0.0.5")
        #expect(info.host == "10.0.0.5")
        #expect(info.powerState == .on)
        #expect(StubProtocol.requests.map(\.absoluteString) == ["http://10.0.0.5:8001/api/v2/"])
    }

    @Test func redirectIsNotFollowed() async {
        StubProtocol.configure(.redirect(to: URL(string: "http://8.8.8.8/")!))
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher().fetchInfo(host: "10.0.0.5")
        }
        #expect(StubProtocol.requests.map(\.absoluteString) == ["http://10.0.0.5:8001/api/v2/"])
    }

    @Test func timeoutIsAppliedToRequest() async throws {
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        _ = try await makeFetcher(timeout: .milliseconds(100)).fetchInfo(host: "10.0.0.5")
        #expect(abs(StubProtocol.timeouts[0] - 0.1) < 0.001)
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        let defaults = HTTPTVInfoFetcher(session: StubProtocol.makeSession())
        _ = try await defaults.fetchInfo(host: "10.0.0.5")
        #expect(StubProtocol.timeouts[0] == 2.0)
    }

    // MARK: Stalls (a 2024 TV accepted the connection on 8001, then sent nothing for up to ~13 s)

    @Test func stalledTVIsAskedAgainUntilItAnswers() async throws {
        StubProtocol.configure(.stallFirst(count: 2, body: try fixture("info-on")))
        let prober = StallProber(open: true)
        let info = try await makeFetcher(timeout: .milliseconds(200), stallBudget: .seconds(3), prober: prober)
            .fetchInfo(host: "10.0.0.5")
        #expect(info.powerState == .on)
        #expect(StubProtocol.requests.count == 3)
        #expect(prober.probes == 2)
    }

    @Test func timeoutWithNoConnectionIsNotRetried() async {
        // A TV that is off the network times out too, but never accepts a connection: fail as fast as before.
        StubProtocol.configure(.stallFirst(count: 100, body: Data()))
        let prober = StallProber(open: false)
        let start = ContinuousClock.now
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher(timeout: .milliseconds(200), stallBudget: .seconds(3), prober: prober)
                .fetchInfo(host: "10.0.0.5")
        }
        #expect(StubProtocol.requests.count == 1)
        #expect(prober.probes == 1)
        #expect(ContinuousClock.now - start < .milliseconds(800))
    }

    @Test func stallGivesUpWhenTheBudgetRunsOut() async {
        StubProtocol.configure(.stallFirst(count: 100, body: Data()))
        let start = ContinuousClock.now
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher(timeout: .milliseconds(200), stallBudget: .milliseconds(700),
                                  prober: StallProber(open: true)).fetchInfo(host: "10.0.0.5")
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(600))
        #expect(elapsed < .milliseconds(1300))
        #expect(StubProtocol.requests.count >= 3)
    }

    @Test func definiteAnswersAreNotRetried() async {
        // A refused connection or a non-TV answer is final: no probe, no second request.
        let prober = StallProber(open: true)
        StubProtocol.configure(.response(status: 500, body: Data()))
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher(stallBudget: .seconds(3), prober: prober).fetchInfo(host: "10.0.0.5")
        }
        StubProtocol.configure(.failure(.cannotConnectToHost))
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher(stallBudget: .seconds(3), prober: prober).fetchInfo(host: "10.0.0.5")
        }
        #expect(StubProtocol.requests.count == 1)
        #expect(prober.probes == 0)
    }

    @Test func noStallBudgetMeansOneAttempt() async {
        StubProtocol.configure(.stallFirst(count: 1, body: Data()))
        let prober = StallProber(open: true)
        await #expect(throws: TVInfoError.unreachable) {
            try await makeFetcher(timeout: .milliseconds(200), prober: prober).fetchInfo(host: "10.0.0.5")
        }
        #expect(StubProtocol.requests.count == 1)
        #expect(prober.probes == 0)
    }

    @Test func requestIgnoresLocalCache() async throws {
        // A cached "on" answer would make Power turn off a TV that is already off.
        StubProtocol.configure(.response(status: 200, body: try fixture("info-on")))
        _ = try await makeFetcher().fetchInfo(host: "10.0.0.5")
        #expect(StubProtocol.cachePolicies == [.reloadIgnoringLocalCacheData])
    }
}
