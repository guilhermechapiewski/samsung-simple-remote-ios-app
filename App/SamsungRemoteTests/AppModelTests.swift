import Foundation
import Synchronization
import Testing
import SamsungTVKit
import SwiftUI
@testable import SamsungRemote

// MARK: - Fakes

private func info(_ id: String, host: String, name: String, model: String = "Model", power: TVPowerState = .on,
                  mac: String? = "02:00:00:00:00:01") -> TVDeviceInfo {
    TVDeviceInfo(id: TVID(rawValue: id), host: host, name: name, modelName: model, modelCode: "M",
                 wifiMAC: mac.flatMap(MACAddress.init), networkType: "wireless", powerState: power,
                 tokenAuthSupported: true)
}

private func knownTV(_ i: TVDeviceInfo) -> KnownTV {
    KnownTV(id: i.id, lastHost: i.host, wifiMAC: i.wifiMAC, modelName: i.modelName, reportedName: i.name,
            lastSeen: Date(timeIntervalSince1970: 0))
}

/// Whether the fake device is on Wi-Fi, and its interface address there.
private final class WiFiSwitch: Sendable {
    private let state: Mutex<Bool>
    private let addressState = Mutex<UInt32>(0xC0A8_0102)
    init(_ on: Bool) { state = Mutex(on) }
    var isOn: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
    var address: UInt32 {
        get { addressState.withLock { $0 } }
        set { addressState.withLock { $0 = newValue } }
    }
    var interface: IPv4Interface? {
        isOn ? IPv4Interface(name: "en0", address: address, netmask: 0xFFFF_FF00) : nil
    }
}

/// The model's wall clock, advanced by hand.
private final class TestNow: Sendable {
    private let state = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))
    var date: Date { state.withLock { $0 } }
    func advance(by interval: TimeInterval) { state.withLock { $0 += interval } }
}

/// Lets a test hold async work until it opens the gate (open by default).
private final class Gate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((true, []))

    var waiting: Int { state.withLock { $0.waiters.count } }

    func close() { state.withLock { $0.isOpen = false } }

    func open() {
        let waiters = state.withLock { s in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s in
                if s.isOpen { return true }
                s.waiters.append(c)
                return false
            }
            if now { c.resume() }
        }
    }
}

private final class FakeSession: RemoteSessionProtocol {
    struct Log {
        var connects = 0
        var disconnects = 0
        /// Keys sent with `sendEnsuringConnection` (the power controller's path).
        var ensured: [String] = []
        var sent: [String] = []
        var texts: [String] = []
        var current: SessionState = .idle
    }

    let id: TVID
    let host: String
    let states: AsyncStream<SessionState>
    let keyboardEvents: AsyncStream<Bool>
    private let stateContinuation: AsyncStream<SessionState>.Continuation
    let keyboardContinuation: AsyncStream<Bool>.Continuation
    private let log = Mutex(Log())
    private let disconnectGate: Gate

    init(id: TVID, host: String, disconnectGate: Gate) {
        self.id = id
        self.host = host
        self.disconnectGate = disconnectGate
        (states, stateContinuation) = AsyncStream.makeStream()
        (keyboardEvents, keyboardContinuation) = AsyncStream.makeStream()
    }

    var snapshot: Log { log.withLock { $0 } }

    /// Simulates the session reaching `state`.
    func emit(_ state: SessionState) {
        log.withLock { $0.current = state }
        stateContinuation.yield(state)
    }

    var currentState: SessionState { log.withLock { $0.current } }
    func connect() async { log.withLock { $0.connects += 1 } }
    func disconnect() async {
        await disconnectGate.wait()
        log.withLock {
            $0.disconnects += 1
            $0.current = .idle
        }
    }

    func send(_ key: RemoteKey, _ action: KeyAction) async throws(SessionError) {
        try log.withLock { (l: inout Log) throws(SessionError) in
            guard l.current == .connected else { throw .unreachable }
            l.sent.append(action == .click ? key.rawValue : "\(key.rawValue) \(action.rawValue)")
        }
    }

    /// Like the real session: connects first when not connected (this fake then fails the send).
    func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError) {
        let connected = log.withLock { l in
            l.ensured.append(key.rawValue)
            if l.current != .connected { l.connects += 1 }
            return l.current == .connected
        }
        guard connected else { throw .unreachable }
        try await send(key, .click)
    }

    func sendText(_ s: String) async throws(SessionError) { log.withLock { $0.texts.append(s) } }
    func sendTextEnd() async throws(SessionError) { log.withLock { $0.texts.append("<end>") } }
}

private final class FakeDiscovery: Sendable {
    private let state = Mutex<(scans: [[String]], sweeps: [Bool],
                               continuations: [AsyncStream<DiscoveryEvent>.Continuation])>(([], [], []))

    var scans: [[String]] { state.withLock { $0.scans } }
    /// Whether each scan included the subnet sweep, in order.
    var sweeps: [Bool] { state.withLock { $0.sweeps } }

    func make(_ hosts: [String], sweep: Bool) -> AsyncStream<DiscoveryEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveryEvent.self)
        state.withLock {
            $0.scans.append(hosts)
            $0.sweeps.append(sweep)
            $0.continuations.append(continuation)
        }
        return stream
    }

    func yield(_ event: DiscoveryEvent) { state.withLock { $0.continuations.last }?.yield(event) }
    func finish() { state.withLock { $0.continuations.last }?.finish() }
}

private final class FakeSessions: Sendable {
    private let all = Mutex<[FakeSession]>([])
    /// Holds every session's `disconnect()` while closed.
    let disconnectGate = Gate()
    var list: [FakeSession] { all.withLock { $0 } }
    var last: FakeSession? { list.last }

    func make(_ id: TVID, _ host: String) -> FakeSession {
        let session = FakeSession(id: id, host: host, disconnectGate: disconnectGate)
        all.withLock { $0.append(session) }
        return session
    }
}

private final class FakeCredentials: CredentialStore {
    let deleted = Mutex<[TVID]>([])
    /// TVs that have a pairing token.
    let paired = Mutex<Set<TVID>>([])
    func load(_ id: TVID) -> TVCredentials? {
        paired.withLock { $0.contains(id) } ? TVCredentials(token: "t", pin: CertificatePin(sha256: Data())) : nil
    }
    func save(_ c: TVCredentials, for id: TVID) throws {}
    func delete(_ id: TVID) { deleted.withLock { $0.append(id) } }
}

private final class FakeLabels: LabelStore {
    private let labels = Mutex<[TVID: String]>([:])
    let changes: AsyncStream<Void>
    let changesContinuation: AsyncStream<Void>.Continuation

    init() { (changes, changesContinuation) = AsyncStream.makeStream() }

    func label(for id: TVID) -> String? { labels.withLock { $0[id] } }
    func setLabel(_ s: String?, for id: TVID) { labels.withLock { $0[id] = s } }
}

private final class FakeKnownTVStore: KnownTVPersisting {
    let registry: Mutex<KnownTVRegistry>
    init(_ tvs: [KnownTV] = []) {
        var r = KnownTVRegistry()
        for tv in tvs {
            r.record(TVDeviceInfo(id: tv.id, host: tv.lastHost, name: tv.reportedName, modelName: tv.modelName,
                                  modelCode: "", wifiMAC: tv.wifiMAC, networkType: "", powerState: .on,
                                  tokenAuthSupported: true), at: tv.lastSeen)
        }
        registry = Mutex(r)
    }
    func load() -> KnownTVRegistry { registry.withLock { $0 } }
    func save(_ r: KnownTVRegistry) throws { registry.withLock { $0 = r } }
}

private final class FakePower: PowerToggling {
    let outcome: PowerOutcome?
    /// Reported to `onPlan` before the gate, when set.
    let plan: PowerAction?
    let calls = Mutex<[TVID]>([])
    /// Holds every toggle while closed.
    let gate = Gate()
    init(_ outcome: PowerOutcome?, plan: PowerAction? = nil) {
        self.outcome = outcome
        self.plan = plan
    }
    func togglePower(
        tv: KnownTV, sender: any PowerKeySending, onPlan: @Sendable (PowerAction) async -> Void
    ) async -> PowerOutcome? {
        calls.withLock { $0.append(tv.id) }
        if let plan { await onPlan(plan) }
        await gate.wait()
        return outcome
    }
}

private final class FakeFetcher: TVInfoFetching {
    private let answers: Mutex<[String: TVDeviceInfo]>
    /// What the fetcher answers now (by host); change it to simulate a TV coming on or going away.
    var infos: [String: TVDeviceInfo] {
        get { answers.withLock { $0 } }
        set { answers.withLock { $0 = newValue } }
    }
    let requested = Mutex<[String]>([])
    /// Answers counted once each fetch returns.
    let answered = Mutex(0)
    /// Holds every fetch while closed.
    let gate = Gate()
    init(_ infos: [TVDeviceInfo] = []) {
        answers = Mutex(Dictionary(uniqueKeysWithValues: infos.map { ($0.host, $0) }))
    }
    func answer(_ info: TVDeviceInfo) { infos[info.host] = info }
    func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo {
        requested.withLock { $0.append(host) }
        await gate.wait()
        defer { answered.withLock { $0 += 1 } }
        guard let i = infos[host] else { throw .unreachable }
        return i
    }
}

/// One model wired to fakes, with handles on every fake.
@MainActor
private struct Harness {
    let discovery = FakeDiscovery()
    let sessions = FakeSessions()
    let credentials = FakeCredentials()
    let labels = FakeLabels()
    let store: FakeKnownTVStore
    let power: FakePower
    let fetcher: FakeFetcher
    /// What a real `PowerController` fetches, when the harness uses one.
    let powerFetcher: FakeFetcher
    let clock = TestClock()
    let now = TestNow()
    let wifi: WiFiSwitch
    /// Emits the model's Wi-Fi change events.
    let wifiChanges: AsyncStream<Void>.Continuation
    let defaults: UserDefaults
    let model: AppModel

    /// `realPower` uses a real `PowerController` (fetching from `powerFetcher`, answering for
    /// `powerFetchable`) instead of `FakePower`.
    init(known: [TVDeviceInfo] = [], selected: TVID? = nil, wifi: Bool = true,
         power: PowerOutcome? = .turnedOn, powerPlan: PowerAction? = nil, fetchable: [TVDeviceInfo] = [],
         realPower: Bool = false, powerFetchable: [TVDeviceInfo] = [], multicast: Bool = true) {
        store = FakeKnownTVStore(known.map(knownTV))
        self.wifi = WiFiSwitch(wifi)
        self.power = FakePower(power, plan: powerPlan)
        fetcher = FakeFetcher(fetchable)
        powerFetcher = FakeFetcher(powerFetchable)
        defaults = UserDefaults(suiteName: "AppModelTests.\(UUID().uuidString)")!
        if let selected { defaults.set(selected.rawValue, forKey: "selectedTV") }
        let discovery = discovery, sessions = sessions, powerFake = self.power
        let powerFetcher = powerFetcher, clock = clock, now = now
        let (wifiStream, wifiChanges) = AsyncStream.makeStream(of: Void.self)
        self.wifiChanges = wifiChanges
        let env = AppEnvironment(
            makeDiscovery: { discovery.make($0, sweep: $1) },
            makeSession: { sessions.make($0, $1) },
            makePowerController: {
                guard realPower else { return powerFake }
                return PowerController(fetcher: powerFetcher, wake: { _, _, _ in }, interface: { nil }, clock: clock)
            },
            fetcher: fetcher,
            credentials: credentials,
            labels: labels,
            knownTVStore: store,
            wifiInterface: { [wifi = self.wifi] in wifi.interface },
            wifiChanges: { wifiStream },
            clock: clock,
            now: { now.date },
            userDefaults: defaults,
            multicastEnabled: multicast
        )
        model = AppModel(env: env)
    }

    /// Launches the model and waits for the first scan to start.
    func appear() async {
        model.onAppear()
        await settle { !discovery.scans.isEmpty }
    }

    /// Selects nothing new; connects the current session and waits until the model sees it. Unless
    /// `keepConfirmation`, lets the brief "Connected to …" confirmation run out, so the clock has no
    /// sleepers left from it.
    func connectCurrent(keepConfirmation: Bool = false) async {
        await settle { sessions.last?.snapshot.connects == 1 }
        sessions.last?.emit(.connected)
        await settle { model.screen == .ready && model.isConnected }
        guard !keepConfirmation else { return }
        await settle { clock.sleeperCount > 0 }
        clock.advance(by: AppModel.connectedConfirmationDuration)
        await settle { model.status?.tone != .success }
    }
}

/// Yields until `condition` holds (bounded, no real sleeps).
@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
}

/// Lets any queued work run (used to show something does NOT happen).
@MainActor
private func drain() async {
    for _ in 0..<200 { await Task.yield() }
}

private let tvA = info("uuid:a", host: "192.168.1.10", name: "Bravo", model: "QE55")
private let tvB = info("uuid:b", host: "192.168.1.11", name: "Zed", model: "UE43", power: .standby)
private let tvC = info("uuid:c", host: "192.168.1.12", name: "Alpha", model: "QE65")

// MARK: - Tests

@MainActor
@Suite struct AppModelTests {
    @Test func powerTipShownOnceAfterFirstConnection() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        #expect(h.model.powerTipTV == nil)
        await h.connectCurrent()
        #expect(h.model.powerTipTV == tvA.id)
        h.model.dismissPowerTip()
        #expect(h.model.powerTipTV == nil)
        #expect(h.defaults.stringArray(forKey: AppModel.powerTipShownKey) == [tvA.id.rawValue])
        // Reconnecting the same TV does not show it again.
        h.sessions.last?.emit(.connecting)
        h.sessions.last?.emit(.connected)
        await drain()
        #expect(h.model.powerTipTV == nil)
    }

    @Test func powerTipSkippedForTVsAlreadyShown() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        h.defaults.set([tvA.id.rawValue], forKey: AppModel.powerTipShownKey)
        await h.appear()
        await h.connectCurrent()
        #expect(h.model.powerTipTV == nil)
    }

    @Test func powerTipMessageNamesTheSettingAndPath() {
        #expect(AppModel.powerTipMessage
            == "To turn this TV on from your iPhone, the TV's “Power On with Mobile” setting must be on: "
            + "\(TVSettingsPath.powerOnWithMobile) (on older TVs: \(TVSettingsPath.powerOnWithMobileOlder)).")
    }

    @Test func noWiFiShowsWiFiState() async {
        let h = Harness(known: [tvA], selected: tvA.id, wifi: false)
        h.model.onAppear()
        await drain()
        #expect(h.model.screen == .noWiFi)
        #expect(h.discovery.scans.isEmpty)
        #expect(h.sessions.list.isEmpty)
    }

    @Test func discoveredTVsListedOnlineFirst() async {
        let h = Harness(known: [tvC])
        await h.appear()
        #expect(h.model.screen == .chooseTV) // a known TV exists, none selected
        h.discovery.yield(.found(tvB))
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await settle { h.model.tvs.count == 3 && h.model.tvs.first?.title == "Bravo" }
        await drain()
        // Several TVs: the user chooses.
        #expect(h.model.selectedID == nil)
        #expect(h.sessions.list.isEmpty)
        #expect(h.model.screen == .chooseTV)
        #expect(h.model.tvs.map(\.title) == ["Bravo", "Zed", "Alpha"])
        #expect(h.model.tvs.map(\.subtitle) == ["QE55", "UE43", "QE65"])
        #expect(h.model.tvs.map(\.status) == [.on, .asleep, .off])
        #expect(h.discovery.scans == [[tvC.host]])
        // Found TVs are remembered.
        #expect(Set(h.store.load().tvs.keys) == [tvA.id, tvB.id, tvC.id])
    }

    @Test func aWakeableTVThatIsntFoundShowsAsOff() async {
        // Every TV tested leaves the network when off; one the app can wake is shown as Off.
        let noMAC = info("uuid:n", host: "192.168.1.13", name: "Nomac", model: "QE50", mac: nil)
        let h = Harness(known: [tvC, noMAC])
        await h.appear()
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await settle { h.model.tvs.count == 3 }
        await drain()
        #expect(h.model.tvs.first?.id == tvA.id) // TVs that answer come first
        #expect(h.model.tvs.first { $0.id == tvC.id }?.status == .off)
        #expect(h.model.tvs.first { $0.id == noMAC.id }?.status == .unreachable) // Power couldn't wake it
    }

    @Test func sameNamedTVsAreToldApartByAddress() async {
        // Two 2019 TVs of the same model report the same name; only their addresses differ.
        let one = info("twin-1", host: "10.0.0.31", name: "Q50 Series (32)", model: "QN32")
        let two = info("twin-2", host: "10.0.0.32", name: "q50 series (32) ", model: "QN32")
        let h = Harness()
        await h.appear()
        h.discovery.yield(.found(one))
        h.discovery.yield(.found(two))
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await settle { h.model.tvs.count == 3 }
        await drain()
        let subtitles = Dictionary(uniqueKeysWithValues: h.model.tvs.map { ($0.id, $0.subtitle) })
        #expect(subtitles[one.id] == "QN32 · 10.0.0.31")
        #expect(subtitles[two.id] == "QN32 · 10.0.0.32")
        #expect(subtitles[tvA.id] == "QE55") // unique names keep the model alone
        // Renaming one makes both unique again.
        h.model.rename(two.id, to: "Guest Room")
        #expect(h.model.tvs.first { $0.id == one.id }?.subtitle == "QN32")
    }

    @Test func searchingThenNoTVs() async {
        let h = Harness()
        await h.appear()
        #expect(h.model.screen == .searching)
        h.discovery.finish()
        await settle { h.model.screen == .noTVs }
        #expect(h.model.screen == .noTVs)
    }

    @Test func localNetworkDeniedShowsState() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        await settle { h.model.screen == .localNetworkDenied }
        #expect(h.model.screen == .localNetworkDenied)
    }

    @Test func reportedNameIgnoresLabel() async {
        let h = Harness(known: [tvA])
        h.labels.setLabel("Den", for: tvA.id)
        await h.appear()
        #expect(h.model.reportedName(for: tvA.id) == "Bravo")
        #expect(h.model.tvs.map(\.title) == ["Den"])
    }

    @Test func labelOverridesReportedName() async {
        let h = Harness(known: [tvA])
        h.labels.setLabel("Den", for: tvA.id)
        await h.appear()
        #expect(h.model.tvs.map(\.title) == ["Den"])

        h.model.rename(tvA.id, to: "  Kitchen ")
        #expect(h.labels.label(for: tvA.id) == "Kitchen")
        #expect(h.model.tvs.map(\.title) == ["Kitchen"])

        h.model.rename(tvA.id, to: "   ")
        #expect(h.labels.label(for: tvA.id) == nil)
        #expect(h.model.tvs.map(\.title) == ["Bravo"])
        h.model.rename(tvA.id, to: "Kitchen")

        // A change synced from another device refreshes titles.
        h.labels.setLabel(nil, for: tvA.id)
        h.labels.changesContinuation.yield()
        await settle { h.model.tvs.first?.title == "Bravo" }
        #expect(h.model.tvs.map(\.title) == ["Bravo"])
    }

    @Test func reconnectsAfterIPChange() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let first = try #require(h.sessions.last)
        #expect(first.host == tvA.host)

        var moved = tvA
        moved.host = "192.168.1.99"
        h.discovery.yield(.found(moved))
        await settle { h.sessions.list.count == 2 && first.snapshot.disconnects == 1 }
        let second = try #require(h.sessions.last)
        #expect(second.id == tvA.id)
        #expect(second.host == "192.168.1.99")
        await settle { second.snapshot.connects == 1 }
        #expect(second.snapshot.connects == 1)
        #expect(first.snapshot.disconnects == 1)
        #expect(h.store.load().tvs[tvA.id]?.lastHost == "192.168.1.99")
    }

    @Test func selectionRestoredOnLaunch() async {
        let h = Harness(known: [tvA, tvB], selected: tvB.id)
        await h.appear()
        #expect(h.model.selectedID == tvB.id)
        await settle { h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.map(\.id) == [tvB.id])
        #expect(h.sessions.last?.host == tvB.host)

        h.model.select(tvA.id)
        #expect(h.defaults.string(forKey: "selectedTV") == tvA.id.rawValue)
    }

    @Test func backgroundDisconnectsForegroundReconnects() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let first = try #require(h.sessions.last)

        h.model.scenePhaseChanged(.background)
        await settle { first.snapshot.disconnects == 1 }
        #expect(first.snapshot.disconnects == 1)
        #expect(!h.model.isConnected)

        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await settle { h.sessions.list.count == 2 && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.count == 2)
        #expect(h.sessions.last?.snapshot.connects == 1)
        #expect(h.model.selectedID == tvA.id)
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.scans.count == 2) // rescanned on return
    }

    @Test func pressWhileDisconnectedShowsReason() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.connecting)
        await drain()

        h.model.press(.up)
        await drain()
        #expect(h.model.statusEvent != nil)
        #expect(try #require(h.sessions.last).snapshot.sent.isEmpty)

        // Once connected, presses go through and the message clears.
        h.sessions.last?.emit(.connected)
        await settle { h.model.isConnected }
        h.model.press(.up)
        await settle { h.sessions.last?.snapshot.sent == ["KEY_UP"] }
        #expect(h.sessions.last?.snapshot.sent == ["KEY_UP"])
        #expect(h.model.statusEvent == nil)
    }

    @Test func pressWithNoTVSelectedShowsReason() {
        let h = Harness()
        h.model.press(.enter)
        #expect(h.model.statusEvent != nil)
    }

    @Test func forgetRemovesEverything() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        h.labels.setLabel("Den", for: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)

        h.model.forget(tvA.id)
        #expect(h.store.load().tvs[tvA.id] == nil)
        #expect(h.store.load().tvs[tvB.id] != nil)
        #expect(h.labels.label(for: tvA.id) == nil)
        #expect(h.model.selectedID == nil)
        #expect(h.defaults.string(forKey: "selectedTV") == nil)
        #expect(h.model.tvs.map(\.id) == [tvB.id])
        // Credentials go once the session has disconnected.
        await settle { h.credentials.deleted.withLock { $0 } == [tvA.id] }
        #expect(session.snapshot.disconnects == 1)
        #expect(h.credentials.deleted.withLock { $0 } == [tvA.id])
    }

    @Test func addManuallyRejectsPublicIP() async {
        let h = Harness(fetchable: [tvA])
        #expect(await h.model.addManually(host: "8.8.8.8") == false)
        #expect(await h.model.addManually(host: "127.0.0.1") == false)
        #expect(await h.model.addManually(host: "not an ip") == false)
        #expect(h.fetcher.requested.withLock { $0 }.isEmpty)
        #expect(h.model.tvs.isEmpty)

        #expect(await h.model.addManually(host: " 192.168.1.10 ") == true)
        #expect(h.model.selectedID == tvA.id)
        #expect(h.store.load().tvs[tvA.id]?.lastHost == tvA.host)
        #expect(h.model.tvs.map(\.title) == ["Bravo"])
    }

    @Test func backgroundEndsHold() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)

        h.model.beginHold(.volumeUp)
        await h.clock.waitForSleepers(2) // the hold's repeat and the watch of the connected TV
        await settle { session.snapshot.sent == ["KEY_VOLUP"] }
        #expect(session.snapshot.sent == ["KEY_VOLUP"])

        h.model.scenePhaseChanged(.background)
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(1))
        await drain()
        #expect(session.snapshot.sent == ["KEY_VOLUP"])
    }

    @Test func holdRepeatsUntilEnd() async throws {
        let h = Harness(known: [tvA], selected: tvA.id, fetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        await h.clock.waitForSleepers(1) // the connected TV's presence watch

        h.model.beginHold(.down)
        await h.clock.waitForSleepers(2) // plus the repeat timer
        #expect(h.model.holdRepeats == 0)
        h.clock.advance(by: .milliseconds(400))
        await settle { session.snapshot.sent.count == 2 }
        await h.clock.waitForSleepers(2)
        h.clock.advance(by: .milliseconds(100))
        await settle { session.snapshot.sent.count == 3 }
        h.model.endHold()
        await h.clock.waitForSleepers(1)
        h.clock.advance(by: .seconds(1))
        await drain()
        #expect(session.snapshot.sent == ["KEY_DOWN", "KEY_DOWN", "KEY_DOWN"])
        #expect(h.model.holdRepeats == 2)
    }

    @Test func pairingStateShowsPairingScreen() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.awaitingApproval)
        await settle { h.model.screen == .pairing }
        #expect(h.model.screen == .pairing)
        #expect(h.model.tvs.first?.status == .pairing)

        h.sessions.last?.emit(.connected)
        await settle { h.model.screen == .ready }
        #expect(h.model.screen == .ready)
        #expect(h.model.tvs.first?.status == .on)
    }

    @Test func deniedShowsPairingDenied() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.failed(.denied))
        await settle { h.model.screen == .pairingDenied }
        #expect(h.model.screen == .pairingDenied)
    }

    @Test func identityChangedShowsStateAndRepairForgetsCredentials() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let first = try #require(h.sessions.last)
        first.emit(.failed(.identityChanged))
        await settle { h.model.screen == .identityChanged }
        #expect(h.model.screen == .identityChanged)

        h.model.repair()
        await settle { h.sessions.list.count == 2 && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.credentials.deleted.withLock { $0 } == [tvA.id])
        #expect(first.snapshot.disconnects == 1)
        #expect(h.sessions.last?.snapshot.connects == 1)
        #expect(h.model.screen == .ready)
    }

    @Test func unreachableSessionMarksTVAndExplains() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.failed(.unreachable))
        await settle { h.model.statusEvent != nil }
        #expect(h.model.screen == .ready)
        #expect(h.model.tvs.first?.status == .off) // the app can wake it
        #expect(h.model.statusEvent != nil)
    }

    @Test func rescanRetriesFailedSession() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let first = try #require(h.sessions.last)
        first.emit(.failed(.denied))
        await settle { h.model.screen == .pairingDenied }

        h.model.rescan() // "Try Again"
        await settle { h.sessions.list.count == 2 && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.count == 2)
        #expect(first.snapshot.disconnects == 1)
        #expect(h.model.screen == .ready)
    }

    @Test func powerFailureShowsMessage() async {
        let h = Harness(known: [tvA], selected: tvA.id, power: .failedToWake)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.model.togglePower()
        #expect(h.model.powerBusy)
        await settle { !h.model.powerBusy }
        #expect(h.power.calls.withLock { $0 } == [tvA.id])
        #expect(h.model.statusEvent == .notTurnedOn)
    }

    @Test func powerFailureMessageIsTheSameWithoutMulticast() async {
        // The 2026-11-20 overnight test: broadcast wake packets fail after hours off just like unicast ones.
        let h = Harness(known: [tvA], selected: tvA.id, power: .failedToWake, multicast: false)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.model.togglePower()
        await settle { !h.model.powerBusy }
        #expect(h.model.statusEvent == StatusLine.notTurnedOn)
    }

    @Test func infoPlistMulticastFlagIsExpanded() {
        // SRMulticastEnabled must be the expanded SAMSUNG_REMOTE_MULTICAST build setting (YES or NO);
        // whether it matches the entitlements is enforced by the "Check entitlements" build phase.
        let raw = Bundle.main.object(forInfoDictionaryKey: "SRMulticastEnabled") as? String
        #expect(raw == "YES" || raw == "NO")
        #expect(AppEnvironment.buildHasMulticastEntitlement == (raw == "YES"))
    }

    @Test func powerIdentityChangedShowsIdentityStateAndEndsHold() async {
        let h = Harness(known: [tvA], selected: tvA.id, power: .failed(.identityChanged))
        await h.appear()
        await h.connectCurrent()
        h.model.beginHold(.volumeUp)
        await h.clock.waitForSleepers(2) // the hold's repeat and the watch of the connected TV
        h.model.togglePower()
        await settle { !h.model.powerBusy && h.model.screen == .identityChanged }
        #expect(h.model.screen == .identityChanged)
        await h.clock.waitForSleepers(0)
    }

    @Test func powerBusyIsPerTVAndSilencesUnreachable() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id, power: .turnedOn)
        await h.appear()
        await h.connectCurrent()
        h.power.gate.close()
        h.model.togglePower()
        #expect(h.model.powerBusy)
        await settle { h.power.gate.waiting == 1 }

        // The session giving up while power is in flight does not post its own message.
        h.sessions.last?.emit(.failed(.unreachable))
        await settle { h.model.tvs.first { $0.id == tvA.id }?.status == .off }
        #expect(h.model.statusEvent == nil)

        h.model.select(tvB.id)
        #expect(!h.model.powerBusy)
        h.model.select(tvA.id)
        #expect(h.model.powerBusy)

        h.power.gate.open()
        await settle { !h.model.powerBusy }
        #expect(!h.model.powerBusy)
    }

    @Test func selectingAnotherTVDisconnectsPrevious() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let first = try #require(h.sessions.last)

        h.model.select(tvB.id)
        #expect(h.model.selectedID == tvB.id)
        #expect(!h.model.isConnected)
        await settle { first.snapshot.disconnects == 1 && h.sessions.last?.snapshot.connects == 1 }
        #expect(first.snapshot.disconnects == 1)
        #expect(h.sessions.list.map(\.id) == [tvA.id, tvB.id])
        #expect(h.sessions.last?.host == tvB.host)
        #expect(h.sessions.last?.snapshot.connects == 1)

        // Late events from the old session are ignored.
        first.emit(.failed(.denied))
        await drain()
        #expect(h.model.screen == .ready)
    }

    // MARK: Watching an unreachable TV

    /// The selected TV's session failed as unreachable (the TV is off or slow to boot).
    private func unreachableSelected(_ h: Harness) async {
        await h.appear()
        h.discovery.finish()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.failed(.unreachable))
        // The TV already shows as unreachable before the event (no scan saw it), so wait for the message.
        await settle { h.model.statusEvent == StatusLine.unreachable }
    }

    @Test func reconnectsWhenAnUnreachableTVComesOn() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await unreachableSelected(h)
        await settle { h.clock.sleeperCount > 0 }
        h.clock.advance(by: AppModel.watchInterval)
        await settle { h.fetcher.requested.withLock { $0 }.contains(tvA.host) }
        #expect(h.sessions.list.count == 1) // still off: nothing to do

        h.fetcher.answer(tvA) // the TV finished booting
        await settle { h.clock.sleeperCount > 0 }
        h.clock.advance(by: AppModel.watchInterval)
        await settle { h.sessions.list.count == 2 }
        #expect(h.sessions.list.count == 2)
        #expect(h.model.tvs.first?.status == .on)
    }

    @Test func watchingIgnoresAStandbyAnswer() async {
        var standby = tvA
        standby.powerState = .standby
        let h = Harness(known: [tvA], selected: tvA.id, fetchable: [standby])
        await unreachableSelected(h)
        for _ in 0..<3 {
            await settle { h.clock.sleeperCount > 0 }
            h.clock.advance(by: AppModel.watchInterval)
            await drain()
        }
        #expect(h.sessions.list.count == 1) // asleep is not on; Power is the way to wake it
    }

    @Test func watchingStopsInTheBackground() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await unreachableSelected(h)
        h.model.scenePhaseChanged(.background)
        await drain()
        let before = h.fetcher.requested.withLock { $0.count }
        h.clock.advance(by: AppModel.watchInterval * 3)
        await drain()
        #expect(h.fetcher.requested.withLock { $0.count } == before)
    }

    @Test func aConnectedTVThatStaysOnIsLeftAlone() async {
        let h = Harness(known: [tvA], selected: tvA.id, fetchable: [tvA])
        await h.appear()
        h.discovery.finish()
        await h.connectCurrent()
        for _ in 0..<3 {
            await settle { h.clock.sleeperCount > 0 }
            h.clock.advance(by: AppModel.watchInterval)
            await drain()
        }
        #expect(h.sessions.list.count == 1)
        #expect(h.model.status == nil)
        #expect(h.model.controlsAvailable)
    }

    @Test func failedWakeKeepsWatchingAndClearsItsMessage() async {
        let h = Harness(known: [tvA], selected: tvA.id, power: .failedToWake)
        await unreachableSelected(h)
        h.model.togglePower()
        await settle { !h.model.powerBusy && h.model.statusEvent != nil }

        h.fetcher.answer(tvA) // it came on after the power controller gave up
        await settle { h.clock.sleeperCount > 0 }
        h.clock.advance(by: AppModel.watchInterval)
        await settle { h.sessions.list.count == 2 }
        h.sessions.last?.emit(.connecting)
        await settle { h.model.statusEvent == nil }
        #expect(h.model.statusEvent == nil)
    }

    /// Connected, then the connection dropped and the session is retrying (it reports `.connecting`
    /// while it waits between attempts).
    private func reconnecting(_ h: Harness) async {
        await h.appear()
        h.discovery.finish()
        await h.connectCurrent()
        h.sessions.last?.emit(.connecting)
        await settle { h.model.status?.tone == .progress }
    }

    private func tick(_ h: Harness, times: Int = 1) async {
        for _ in 0..<times {
            await settle { h.clock.sleeperCount > 0 }
            h.clock.advance(by: AppModel.watchInterval)
            await drain()
        }
    }

    @Test func watchesEveryTwoSeconds() {
        #expect(AppModel.watchInterval == .seconds(2))
    }

    @Test func aStalledReconnectStartsOverAsSoonAsTheTVIsOn() async {
        let h = Harness(known: [tvA], selected: tvA.id, fetchable: [tvA])
        await reconnecting(h)
        await tick(h, times: AppModel.stalledConnectTicks)
        await settle { h.sessions.list.count == 2 }
        #expect(h.sessions.list.count == 2) // a fresh attempt now, not after the session's backoff
        #expect(h.sessions.list.first?.snapshot.disconnects == 1)
    }

    @Test func aNormalConnectAttemptIsNotInterrupted() async {
        let h = Harness(known: [tvA], selected: tvA.id, fetchable: [tvA])
        await reconnecting(h)
        await tick(h, times: AppModel.stalledConnectTicks - 1)
        #expect(h.sessions.list.count == 1)
    }

    @Test func reconnectingToATVThatIsOffSaysSo() async {
        let h = Harness(known: [tvA], selected: tvA.id) // the TV doesn't answer
        await reconnecting(h)
        await tick(h)
        await settle { h.model.status == StatusLine.offPressPower }
        #expect(h.model.status == StatusLine.offPressPower) // the app can wake it
        // And once it answers again, the line goes back to the attempt in progress.
        h.fetcher.answer(tvA)
        await tick(h)
        await settle { h.model.status?.tone == .progress }
        #expect(h.model.status?.tone == .progress)
    }

    @Test func aStandbyAnswerShowsTheTVAsleep() async {
        var standby = tvA
        standby.powerState = .standby
        let h = Harness(known: [tvA], selected: tvA.id, fetchable: [standby])
        await reconnecting(h)
        await tick(h)
        await settle { h.model.tvs.first?.status == .asleep }
        #expect(h.model.tvs.first?.status == .asleep)
        #expect(h.sessions.list.count == 1) // asleep: Power wakes it, the app doesn't
    }

    /// Connected, with the fetcher answering `answer` (nil: no answer).
    private func connected(_ h: Harness) async {
        await h.appear()
        h.discovery.finish()
        await h.connectCurrent()
    }

    @Test func aTVTurnedOffWithItsOwnRemoteIntoStandbyIsNoticed() async {
        var standby = tvA
        standby.powerState = .standby
        let h = Harness(known: [tvA], selected: tvA.id, fetchable: [tvA])
        await connected(h)
        h.fetcher.answer(standby) // the socket may stay open in network standby; only the info tells
        await tick(h)
        await settle { h.model.tvs.first?.status == .asleep }
        #expect(h.model.status == StatusLine.tvOff)
        #expect(!h.model.controlsAvailable) // only Power does anything now
        #expect(h.sessions.list.count == 1) // the open connection is kept: Power can use it

        h.fetcher.answer(tvA) // turned back on with its own remote
        await tick(h)
        await settle { h.model.controlsAvailable }
        #expect(h.model.status == nil)
        #expect(h.model.tvs.first?.status == .on)
    }

    @Test func aConnectedTVThatStopsAnsweringIsNoticedWithinTwoChecks() async {
        let h = Harness(known: [tvA], selected: tvA.id, fetchable: [tvA])
        await connected(h)
        h.fetcher.infos = [:] // gone (unplugged, or off without network standby)
        // Count checks answered from now on (one may already be in flight; it counts too, as it answers
        // after this point). The connection is replaced only after two misses in a row.
        let answeredBefore = h.fetcher.answered.withLock { $0 }
        var missesWhenReplaced: Int?
        for _ in 0..<4 where missesWhenReplaced == nil {
            await tick(h)
            if h.sessions.list.count == 2 {
                missesWhenReplaced = h.fetcher.answered.withLock { $0 } - answeredBefore
            }
        }
        #expect(missesWhenReplaced.map { $0 >= AppModel.missedChecksBeforeReconnect } == true)
        #expect(h.sessions.list.first?.snapshot.disconnects == 1)
    }

    @Test func turningOffWithTheAppNeverShowsConnecting() async {
        let h = Harness(known: [tvA], selected: tvA.id, power: .turnedOff, powerPlan: .turnOff)
        await connected(h)
        h.model.togglePower()
        await settle { !h.model.powerBusy }
        h.sessions.last?.emit(.connecting) // the connection drops as the TV goes off
        await settle { h.model.status?.title != nil }
        #expect(h.model.status == StatusLine.tvOff)
        // Still "The TV is off" (not "Press Power…") once it stops answering.
        h.sessions.last?.emit(.failed(.unreachable))
        await tick(h)
        #expect(h.model.status == StatusLine.tvOff)
    }

    // MARK: A TV that is off

    /// Two known TVs, neither found by the finished scan; `tvA` chosen from the menu.
    private func choseATVTheScanDidntFind(_ h: Harness) async {
        await h.appear()
        h.discovery.finish()
        await drain()
        h.model.select(tvA.id)
        await drain()
    }

    @Test func choosingATVTheScanDidntFindSaysPressPower() async {
        let h = Harness(known: [tvA, tvC])
        await choseATVTheScanDidntFind(h)
        #expect(h.model.status == StatusLine.offPressPower) // no "Connecting…" first
        #expect(h.sessions.list.count == 1) // still tries in the background
        // It answers after all: the line moves on.
        h.sessions.last?.emit(.connected)
        await settle { h.model.isConnected }
        #expect(h.model.status == StatusLine.connected(to: "Bravo"))
    }

    @Test func firstFrameNeverSaysPressPower() {
        // Before onAppear (the first frame), no scan has run yet: nothing says the TV is off.
        let h = Harness(known: [tvA], selected: tvA.id)
        #expect(h.model.status == StatusLine.connecting(to: "Bravo"))
    }

    @Test func backFromBackgroundATVThatIsOffSaysPressPower() async {
        // The owner's morning: the TV connected last night, the app stayed suspended, the TV is off now.
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == 2 }
        h.discovery.finish() // the scan on return doesn't find it
        await drain()
        #expect(h.model.status == StatusLine.offPressPower) // no "Connecting…" first
    }

    @Test func aTVThatIsOnConnectsWithoutPressPowerFlash() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear() // the launch scan is still running
        await settle { h.sessions.last?.snapshot.connects == 1 }
        #expect(h.model.status == StatusLine.connecting(to: "Bravo"))
    }

    @Test func aFailedSessionToAWakeableTVSaysPressPower() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.failed(.unreachable))
        await settle { h.model.statusEvent != nil }
        #expect(h.model.status == StatusLine.offPressPower)
    }

    @Test func withoutAMACItStillSaysCantReach() async {
        let noMAC = info("uuid:n", host: "192.168.1.13", name: "Nomac", model: "QE50", mac: nil)
        let h = Harness(known: [noMAC, tvC])
        await h.appear()
        h.discovery.finish()
        await drain()
        h.model.select(noMAC.id)
        await drain()
        #expect(h.model.status == StatusLine.connecting(to: "Nomac"))
        h.sessions.last?.emit(.failed(.unreachable))
        await settle { h.model.statusEvent != nil }
        #expect(h.model.status == StatusLine.unreachable)
    }

    @Test func pressingPowerReplacesPressPower() async {
        let h = Harness(known: [tvA, tvC], power: .failedToWake)
        await choseATVTheScanDidntFind(h)
        h.power.gate.close()
        h.model.togglePower()
        #expect(h.model.status == StatusLine.turningOn)
        h.power.gate.open()
        await settle { !h.model.powerBusy }
        #expect(h.model.status == StatusLine.notTurnedOn)
    }

    // MARK: Launch

    @Test func firstFrameShowsRememberedTVs() {
        // Before onAppear (the first frame), the remembered TVs and selection are already loaded, so the
        // screen never flashes "No TVs found".
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        #expect(h.model.selectedID == tvA.id)
        #expect(h.model.tvs.map(\.id).sorted { $0.rawValue < $1.rawValue } == [tvA.id, tvB.id])
        #expect(h.model.screen == .ready)
        #expect(h.discovery.scans.isEmpty) // no network work until onAppear
        #expect(h.sessions.list.isEmpty)
    }

    @Test func firstFrameWithoutSelectionShowsChooseTV() {
        let h = Harness(known: [tvA, tvB])
        #expect(h.model.screen == .chooseTV)
    }

    // MARK: TV details

    @Test func detailsUnknownTVIsNil() async {
        let h = Harness(known: [tvA])
        await h.appear()
        #expect(h.model.details(for: tvB.id) == nil)
        #expect(await h.model.liveDetails(for: tvB.id) == nil)
    }

    @Test func detailsFromRecordsBeforeTheTVAnswers() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        let details = try #require(h.model.details(for: tvA.id))
        #expect(details.known.lastHost == tvA.host)
        #expect(details.info == nil) // not seen by a scan yet
        #expect(!details.isLive)
        #expect(!details.paired)
    }

    @Test func liveDetailsAskTheTV() async throws {
        var fresh = tvA
        fresh.details.resolution = "3840x2160"
        let h = Harness(known: [tvA], fetchable: [fresh])
        h.credentials.paired.withLock { _ = $0.insert(tvA.id) }
        await h.appear()
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(details.isLive)
        #expect(details.info?.details.resolution == "3840x2160")
        #expect(details.paired)
        #expect(h.fetcher.requested.withLock { $0 }.contains(tvA.host))
    }

    @Test func liveDetailsFallBackWhenTheTVDoesNotAnswer() async throws {
        let h = Harness(known: [tvA])
        await h.appear()
        h.discovery.yield(.found(tvA))
        await settle { h.model.tvs.first?.status == .on }
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(!details.isLive)
        #expect(details.info == tvA) // from the scan
    }

    @Test func liveDetailsIgnoreADifferentTVAtTheAddress() async throws {
        let impostor = info("uuid:other", host: tvA.host, name: "Other")
        let h = Harness(known: [tvA], fetchable: [impostor])
        await h.appear()
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(!details.isLive)
        #expect(details.info == nil)
    }

    @Test func liveDetailsUpdateTheTVsStatus() async throws {
        let h = Harness(known: [tvA], fetchable: [tvA])
        await h.appear()
        h.discovery.finish() // the scan missed the TV
        await drain()
        #expect(h.model.tvs.first?.status == .off)
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(details.status == .on)
        #expect(h.model.tvs.first?.status == .on)
    }

    @Test func liveDetailsOffWiFiDoNotAskTheTV() async throws {
        let h = Harness(known: [tvA], fetchable: [tvA])
        await h.appear()
        h.discovery.finish()
        await drain()
        let before = h.fetcher.requested.withLock { $0.count }
        h.wifi.isOn = false
        h.model.rescan()
        let details = try #require(await h.model.liveDetails(for: tvA.id))
        #expect(!details.isLive)
        #expect(h.fetcher.requested.withLock { $0.count } == before)
    }

    @Test func liveDetailsForATVForgottenMeanwhileIsNil() async {
        let h = Harness(known: [tvA], fetchable: [tvA])
        await h.appear()
        h.discovery.finish()
        await drain()
        h.fetcher.gate.close()
        let task = Task { await h.model.liveDetails(for: tvA.id) }
        await settle { h.fetcher.gate.waiting == 1 }
        h.model.forget(tvA.id)
        h.fetcher.gate.open()
        #expect(await task.value == nil)
        #expect(h.model.tvs.isEmpty) // not resurrected by the late answer
    }

    // MARK: Scan Again feedback

    @Test func automaticScansShowNoFeedback() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        #expect(h.model.scanFeedback == nil)
        h.discovery.finish()
        await drain()
        #expect(h.model.scanFeedback == nil)
    }

    @Test func scanAgainShowsProgressThenNewTVCount() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()

        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        await settle { h.discovery.scans.count == 2 }
        h.discovery.yield(.found(tvA)) // already known: not new
        h.discovery.yield(.found(tvB))
        h.discovery.yield(.found(tvC))
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 2))

        await settle { h.clock.sleeperCount > 0 }
        h.clock.advance(by: AppModel.scanResultDuration)
        await settle { h.model.scanFeedback == nil }
        #expect(h.model.scanFeedback == nil)
    }

    @Test func scanAgainReportsNoNewTVs() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()

        h.model.scanAgain()
        await settle { h.discovery.scans.count == 2 }
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 0))
    }

    @Test func scanAgainJoinsScanAlreadyRunning() async {
        let h = Harness()
        await h.appear() // the launch scan is still running, with the sweep (no TV is known)
        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        h.model.scanAgain() // a second tap does nothing more
        await drain()
        #expect(h.discovery.scans.count == 1)
        h.discovery.yield(.found(tvB))
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 1))
    }

    @Test func scanAgainDuringResultStartsFreshScan() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()
        h.model.scanAgain()
        await settle { h.discovery.scans.count == 2 }
        h.discovery.finish()
        await settle { h.model.scanFeedback == .found(newTVs: 0) }

        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        await settle { h.discovery.scans.count == 3 }
        // The first result's timer must not clear the new scan's spinner.
        h.clock.advance(by: AppModel.scanResultDuration)
        await drain()
        #expect(h.model.scanFeedback == .scanning)
    }

    @Test func scanAgainOffWiFiShowsNoSpinner() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()
        h.wifi.isOn = false
        h.model.scanAgain()
        #expect(h.model.scanFeedback == nil)
        #expect(h.model.screen == .noWiFi)
    }

    @Test func backgroundCancelsScanFeedback() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await drain()
        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        h.model.scenePhaseChanged(.background)
        #expect(h.model.scanFeedback == nil)
    }

    @Test func multipleTVsRequireChoice() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.found(tvA))
        h.discovery.yield(.found(tvB))
        h.discovery.finish()
        await settle { h.model.tvs.count == 2 }
        await drain()
        #expect(h.model.screen == .chooseTV)
        #expect(h.model.selectedID == nil)
        #expect(h.sessions.list.isEmpty)

        h.model.select(tvB.id)
        #expect(h.model.screen == .ready)
    }

    @Test func singleTVAutoSelected() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.found(tvA))
        await settle { h.model.tvs.count == 1 }
        // Not before the scan has finished: another TV may still answer.
        #expect(h.model.selectedID == nil)
        #expect(h.model.screen == .chooseTV)

        h.discovery.finish()
        await settle { h.model.selectedID == tvA.id && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.model.selectedID == tvA.id)
        #expect(h.sessions.list.map(\.host) == [tvA.host])
        #expect(h.model.screen == .ready)
    }

    @Test func restoredSelectionMissingFromRegistryShowsChooseTV() async {
        let h = Harness(known: [tvA, tvB], selected: TVID(rawValue: "uuid:gone"))
        await h.appear()
        #expect(h.model.selectedID == nil)
        #expect(h.defaults.string(forKey: "selectedTV") == nil)
        #expect(h.model.screen == .chooseTV)
        h.discovery.finish()
        await drain()
        #expect(h.model.selectedID == nil)
        #expect(h.sessions.list.isEmpty)
        #expect(h.model.screen == .chooseTV)
    }

    @Test func forgetDuringScanDoesNotResurrect() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id, fetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        h.sessions.disconnectGate.close()

        h.model.forget(tvA.id)
        // A result for the forgotten TV still in flight from the scan.
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await drain()
        #expect(h.store.load().tvs[tvA.id] == nil)
        #expect(h.model.tvs.map(\.id) == [tvB.id])
        #expect(h.model.selectedID == nil) // forget never selects another TV
        // Credentials go only after the disconnect…
        #expect(h.credentials.deleted.withLock { $0 }.isEmpty)

        // …and a session for the same TV, added back at once, waits for both.
        #expect(await h.model.addManually(host: tvA.host))
        await drain()
        #expect(h.sessions.list.count == 2)
        #expect(h.sessions.last?.snapshot.connects == 0)
        h.sessions.disconnectGate.open()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        #expect(h.credentials.deleted.withLock { $0 } == [tvA.id])
        #expect(h.sessions.last?.snapshot.connects == 1)
    }

    @Test func foregroundWaitsForPreviousDisconnect() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        h.sessions.disconnectGate.close()
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.sessions.list.count == 2 }
        await drain()
        #expect(h.sessions.last?.snapshot.connects == 0)

        h.sessions.disconnectGate.open()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.first?.snapshot.disconnects == 1)
        #expect(h.sessions.last?.snapshot.connects == 1)
    }

    @Test func losingWiFiEndsHoldAndClosesSession() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        h.model.beginHold(.up)
        await h.clock.waitForSleepers(2) // the hold's repeat and the watch of the connected TV

        h.wifi.isOn = false
        h.model.rescan()
        #expect(h.model.screen == .noWiFi)
        await h.clock.waitForSleepers(0)
        await settle { session.snapshot.disconnects == 1 }
        #expect(session.snapshot.disconnects == 1)
        #expect(h.discovery.scans.count == 1)
    }

    @Test func localNetworkDeniedPersistsUntilFound() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        h.discovery.finish()
        await settle { h.model.screen == .localNetworkDenied }

        h.model.rescan()
        await settle { h.discovery.scans.count == 2 }
        #expect(h.model.screen == .localNetworkDenied)

        h.discovery.yield(.found(tvA))
        await settle { h.model.screen != .localNetworkDenied }
        #expect(h.model.screen == .chooseTV)
    }

    @Test func statusEventFollowsSessionProgress() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let session = h.sessions.last
        session?.emit(.failed(.unreachable))
        await settle { h.model.statusEvent == StatusLine.unreachable }
        session?.emit(.connecting)
        await settle { h.model.statusEvent == nil }
        #expect(h.model.statusEvent == nil)

        session?.emit(.failed(.approvalTimedOut))
        await settle { h.model.statusEvent == StatusLine.approvalTimedOut }
        session?.emit(.failed(.denied))
        await settle { h.model.screen == .pairingDenied }
        #expect(h.model.statusEvent == nil)
    }

    @Test func playPauseSendsTheToggleKeyEveryTime() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        h.model.playPause()
        h.model.playPause()
        let session = try #require(h.sessions.last)
        await settle { session.snapshot.sent.count == 2 }
        #expect(session.snapshot.sent == ["KEY_PLAY_BACK", "KEY_PLAY_BACK"])
    }

    @Test func playPauseDoesNothingWhenNotConnected() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.model.playPause()
        for _ in 0..<100 { await Task.yield() }
        #expect(h.sessions.last?.snapshot.sent.isEmpty ?? true)
        #expect(h.model.statusEvent != nil)
    }

    @Test func keyboardEventsAndText() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        session.keyboardContinuation.yield(true)
        await settle { h.model.keyboardRequested }
        #expect(h.model.keyboardRequested)
        h.model.sendText("hello")
        h.model.endText()
        await settle { session.snapshot.texts.count == 2 }
        #expect(session.snapshot.texts == ["hello", "<end>"])
        session.keyboardContinuation.yield(false)
        await settle { !h.model.keyboardRequested }
        #expect(!h.model.keyboardRequested)
    }

    @Test func endTextClearsKeyboardRequestSoALaterRequestPresentsAgain() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        session.keyboardContinuation.yield(true)
        await settle { h.model.keyboardRequested }
        h.model.endText()
        #expect(!h.model.keyboardRequested)
        session.keyboardContinuation.yield(true)
        await settle { h.model.keyboardRequested }
        #expect(h.model.keyboardRequested)
    }

    @Test func turningOffSilencesUnreachableAndShowsAsleep() async throws {
        let h = Harness(known: [tvA], selected: tvA.id, power: .turnedOff)
        await h.appear()
        await h.connectCurrent()
        let session = try #require(h.sessions.last)
        h.model.togglePower()
        await settle { !h.model.powerBusy && h.discovery.scans.count == 2 }

        // The TV was turned off on purpose: its session giving up is not an error, and the status
        // line says the TV is off rather than "Connecting…".
        // Shown as asleep as soon as it was turned off, before the session even notices.
        #expect(h.model.tvs.first?.status == .asleep)
        session.emit(.failed(.unreachable))
        await settle { h.model.statusEvent != nil }
        #expect(h.model.statusEvent == StatusLine.tvOff)
        #expect(h.model.status == StatusLine.tvOff)
        #expect(h.model.tvs.first { $0.id == tvA.id }?.status == .asleep)
        session.emit(.failed(.approvalTimedOut))
        await drain()
        #expect(h.model.statusEvent == StatusLine.tvOff)
        h.model.statusEvent = nil
        #expect(h.model.status == StatusLine.tvOff)
        // The scan after turning off does not find it; it is still shown as asleep.
        h.discovery.finish()
        await settle { !h.model.tvs.isEmpty && h.discovery.scans.count == 2 }
        await drain()
        #expect(h.model.tvs.first { $0.id == tvA.id }?.status == .asleep)

        // Once the TV is back, failures are reported again.
        session.emit(.connected)
        await settle { h.model.isConnected }
        session.emit(.failed(.unreachable))
        await settle { h.model.statusEvent == StatusLine.offPressPower }
        #expect(h.model.statusEvent == StatusLine.offPressPower)
        #expect(h.model.tvs.first { $0.id == tvA.id }?.status == .off)
    }

    @Test func powerWithoutSessionExplainsWiFiOrTurnsOn() async {
        let h = Harness(known: [tvA], selected: tvA.id, wifi: false, power: .turnedOn)
        h.model.onAppear()
        #expect(h.model.screen == .noWiFi)
        h.model.togglePower()
        #expect(h.model.statusEvent == StatusLine.notOnWiFi)
        #expect(h.power.calls.withLock { $0 }.isEmpty)

        // Wi-Fi came back but nothing has refreshed yet: Power still works.
        h.wifi.isOn = true
        h.model.togglePower()
        #expect(h.model.statusEvent != .chooseTVFirst)
        await settle { h.power.calls.withLock { $0 } == [tvA.id] }
        #expect(h.power.calls.withLock { $0 } == [tvA.id])
        #expect(h.model.screen != .noWiFi)
    }

    // MARK: - Power never revives a closed session

    @Test func powerAfterSwitchingTVDoesNotReviveOldSession() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id, realPower: true, powerFetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        let old = try #require(h.sessions.last)
        h.powerFetcher.gate.close()
        h.model.togglePower()
        await settle { h.powerFetcher.gate.waiting == 1 }

        h.model.select(tvB.id)
        await settle { old.snapshot.disconnects == 1 }
        h.powerFetcher.gate.open() // the TV reports on: the controller sends KEY_POWER
        await settle { h.powerFetcher.answered.withLock { $0 } == 1 }
        await drain()
        #expect(old.snapshot.connects == 1)
        #expect(old.snapshot.ensured.isEmpty)
        #expect(old.snapshot.sent.isEmpty)
        #expect(h.sessions.last?.snapshot.ensured.isEmpty == true)
    }

    @Test func powerAfterForgettingTVDoesNotReviveOldSession() async throws {
        let h = Harness(known: [tvA, tvB], selected: tvA.id, realPower: true, powerFetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        let old = try #require(h.sessions.last)
        h.powerFetcher.gate.close()
        h.model.togglePower()
        await settle { h.powerFetcher.gate.waiting == 1 }

        h.model.forget(tvA.id)
        await settle { old.snapshot.disconnects == 1 && h.credentials.deleted.withLock { $0 } == [tvA.id] }
        h.powerFetcher.gate.open()
        await settle { h.powerFetcher.answered.withLock { $0 } == 1 }
        await drain()
        #expect(old.snapshot.connects == 1)
        #expect(old.snapshot.ensured.isEmpty)
        #expect(old.snapshot.sent.isEmpty)
        #expect(h.sessions.list.count == 1)
    }

    @Test func powerKeyWaitsForEarlierTeardown() async throws {
        let h = Harness(known: [tvA], selected: tvA.id, realPower: true, powerFetchable: [tvA])
        await h.appear()
        await h.connectCurrent()
        h.sessions.disconnectGate.close()
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.sessions.list.count == 2 }
        let second = try #require(h.sessions.last)

        h.model.togglePower()
        await settle { h.powerFetcher.answered.withLock { $0 } == 1 }
        await drain()
        #expect(second.snapshot.ensured.isEmpty) // still queued behind the old disconnect
        h.sessions.disconnectGate.open()
        await settle { second.snapshot.ensured == ["KEY_POWER"] }
        #expect(second.snapshot.connects >= 1)
        #expect(second.snapshot.ensured == ["KEY_POWER"])
    }

    // MARK: - Status line

    @Test func statusTextDescribesTheSelectedSession() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let session = try #require(h.sessions.last)

        session.emit(.connecting)
        await settle { h.model.statusText == "Connecting to Bravo…" }
        #expect(h.model.status == StatusLine("Connecting to Bravo…", tone: .progress))

        session.emit(.awaitingApproval)
        await settle { h.model.screen == .pairing }
        #expect(h.model.statusText == "Pairing with the TV…")

        session.emit(.failed(.unreachable))
        await settle { h.model.statusEvent != nil }
        #expect(h.model.status == StatusLine.offPressPower)
        // Even with the message gone, a session that gave up is never shown as connecting.
        h.model.statusEvent = nil
        #expect(h.model.status == StatusLine.offPressPower)
        session.emit(.failed(.approvalTimedOut))
        await settle { h.model.statusEvent != nil }
        h.model.statusEvent = nil
        #expect(h.model.status == StatusLine.approvalTimedOut)

        session.emit(.connected)
        await settle { h.model.isConnected }
        // A brief confirmation, then nothing.
        #expect(h.model.status == StatusLine("Connected to Bravo", tone: .success))
        await settle { h.clock.sleeperCount > 0 }
        h.clock.advance(by: AppModel.connectedConfirmationDuration)
        await settle { h.model.statusText == nil }
        #expect(h.model.statusText == nil)
    }

    @Test func connectedConfirmationEndsWhenTheSessionDrops() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await h.connectCurrent(keepConfirmation: true)
        #expect(h.model.status?.tone == .success)
        h.sessions.last?.emit(.failed(.unreachable))
        await settle { h.model.status?.tone == .info }
        #expect(h.model.status == StatusLine.offPressPower)
    }

    @Test func pressingPowerShowsTheDirectionAtOnce() async {
        // No plan reported yet (the TV is still being checked): the line must not fall back to an older
        // message in the meantime.
        let h = Harness(known: [tvA], selected: tvA.id, power: .turnedOn)
        await unreachableSelected(h)
        #expect(h.model.status == .offPressPower)
        h.power.gate.close()
        h.model.togglePower()
        #expect(h.model.status == .turningOn) // synchronously, before any await
        await settle { h.power.gate.waiting == 1 }
        #expect(h.model.status == .turningOn)
        h.power.gate.open()
        await settle { !h.model.powerBusy }

        let on = Harness(known: [tvA], selected: tvA.id, power: .turnedOff)
        await on.appear()
        await on.connectCurrent()
        on.power.gate.close()
        on.model.togglePower()
        #expect(on.model.status == .turningOff)
        on.power.gate.open()
        await settle { !on.model.powerBusy }
    }

    @Test func statusShowsPowerDirectionWhileRunning() async {
        let off = Harness(known: [tvA], selected: tvA.id, power: .turnedOff, powerPlan: .turnOff)
        await off.appear()
        await off.connectCurrent()
        off.power.gate.close()
        off.model.togglePower()
        await settle { off.power.gate.waiting == 1 }
        #expect(off.model.powerDirection == .turningOff)
        #expect(off.model.status == StatusLine("Turning off…", tone: .progress))
        off.power.gate.open()
        await settle { !off.model.powerBusy }
        #expect(off.model.powerDirection == nil)
        #expect(off.model.statusText != "Turning off…")

        let on = Harness(known: [tvA], selected: tvA.id, power: .turnedOn, powerPlan: .wakeOnLAN)
        await on.appear()
        await settle { on.sessions.last?.snapshot.connects == 1 }
        on.power.gate.close()
        on.model.togglePower()
        await settle { on.power.gate.waiting == 1 }
        #expect(on.model.statusText == "Turning on…")
        on.power.gate.open()
        await settle { !on.model.powerBusy }
        #expect(on.model.powerDirection == nil)
    }

    // MARK: - Local Network prompt

    @Test func returningFromPromptRescansWhenNothingWasFound() async {
        let h = Harness()
        await h.appear()
        h.discovery.finish()
        await settle { h.model.screen == .noTVs }

        // The Local Network prompt was answered after the scan gave up.
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.scans.count == 2)

        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await settle { h.model.selectedID == tvA.id }
        // With a TV found, coming back from an alert does not scan again.
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await drain()
        #expect(h.discovery.scans.count == 2)
    }

    @Test func returningFromPromptRescansAfterDenial() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        await settle { h.model.screen == .localNetworkDenied }
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.scans.count == 2)
        h.discovery.yield(.found(tvA))
        await settle { h.model.screen != .localNetworkDenied }
        #expect(h.model.screen == .chooseTV)
    }

    @Test func deniedRetriesScanEveryThreeSecondsUntilFound() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        await h.clock.waitForSleepers(1)
        #expect(h.clock.requestedSleeps == [AppModel.deniedRetryInterval])
        #expect(AppModel.deniedRetryInterval == .seconds(3))

        // A scan still running is not interrupted.
        h.clock.advance(by: .seconds(3))
        await h.clock.waitForSleepers(1)
        #expect(h.discovery.scans.count == 1)

        h.discovery.finish()
        await drain()
        h.clock.advance(by: .seconds(3))
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.scans.count == 2)

        h.discovery.yield(.found(tvA))
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(30))
        await drain()
        #expect(h.discovery.scans.count == 2)
        #expect(h.model.screen == .chooseTV)
    }

    @Test func deniedRetriesAreBoundedAndStopInBackground() async {
        let h = Harness()
        await h.appear()
        h.discovery.yield(.localNetworkDenied)
        h.discovery.finish()
        await drain() // the scan has ended, so a retry may start one
        for retry in 1...AppModel.deniedRetryLimit {
            await h.clock.waitForSleepers(1)
            h.clock.advance(by: .seconds(3))
            await settle { h.discovery.scans.count == retry + 1 }
            #expect(h.discovery.scans.count == retry + 1)
            h.discovery.finish()
            await drain()
        }
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(30))
        await drain()
        #expect(h.discovery.scans.count == AppModel.deniedRetryLimit + 1)

        // Retries start again with the next denial, and background cancels them.
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == AppModel.deniedRetryLimit + 2 }
        h.discovery.yield(.localNetworkDenied)
        await h.clock.waitForSleepers(1)
        h.model.scenePhaseChanged(.background)
        await h.clock.waitForSleepers(0)
        h.clock.advance(by: .seconds(30))
        await drain()
        #expect(h.discovery.scans.count == AppModel.deniedRetryLimit + 2)
    }

    // MARK: - Recovery and manual add

    @Test func scanRecoversApprovalTimedOutSession() async throws {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        let first = try #require(h.sessions.last)
        first.emit(.failed(.approvalTimedOut))
        await settle { h.model.statusEvent == StatusLine.approvalTimedOut }

        h.discovery.yield(.found(tvA))
        await settle { h.sessions.list.count == 2 && h.sessions.last?.snapshot.connects == 1 }
        #expect(h.sessions.list.count == 2)
        #expect(first.snapshot.disconnects == 1)
        #expect(h.sessions.last?.snapshot.connects == 1)
    }

    @Test func cancelledManualAddSelectsNothing() async {
        let h = Harness(fetchable: [tvA])
        h.fetcher.gate.close()
        let add = Task { await h.model.addManually(host: tvA.host) }
        await settle { h.fetcher.gate.waiting == 1 }
        add.cancel()
        h.fetcher.gate.open()
        #expect(await add.value == false)
        #expect(h.model.selectedID == nil)
        #expect(h.model.tvs.isEmpty)
        #expect(h.store.load().tvs.isEmpty)
        #expect(h.sessions.list.isEmpty)
    }

    // MARK: - Sweep policy

    @Test func firstScanWithNoKnownTVSweeps() async {
        let h = Harness()
        await h.appear()
        #expect(h.discovery.sweeps == [true])
    }

    /// Completes the launch scan with `found` answering, then returns to the foreground.
    private func foregroundAfterScan(_ h: Harness, found: [TVDeviceInfo]) async {
        await h.appear()
        for tv in found { h.discovery.yield(.found(tv)) }
        h.discovery.finish()
        await drain()
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == 2 }
    }

    @Test func automaticScanSkipsTheSweepWhenEveryKnownTVAnswered() async {
        let h = Harness(known: [tvA, tvB])
        await foregroundAfterScan(h, found: [tvA, tvB])
        #expect(h.discovery.sweeps == [false, false])
    }

    @Test func automaticScanSkipsTheSweepEvenAfterAScanMissedAKnownTV() async {
        let h = Harness(known: [tvA, tvB])
        await foregroundAfterScan(h, found: [tvA]) // tvB did not answer (e.g. it is off)
        #expect(h.discovery.sweeps == [false, false])
    }

    @Test func userStartedScansSweep() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.yield(.found(tvA))
        h.discovery.finish()
        await drain()
        h.model.scanAgain()
        await settle { h.discovery.scans.count == 2 }
        h.discovery.finish()
        await drain()
        h.model.rescan() // Try Again
        await settle { h.discovery.scans.count == 3 }
        #expect(h.discovery.sweeps == [false, true, true])
    }

    @Test func noTVsCardScanAgainSweeps() async {
        let h = Harness()
        await h.appear()
        h.discovery.finish()
        await settle { h.model.screen == .noTVs }
        h.model.rescan()
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.sweeps.last == true)
    }

    @Test func scanAgainDuringAnAutomaticScanRestartsItWithTheSweep() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear() // the launch scan is running, without the sweep
        h.model.scanAgain()
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.sweeps == [false, true])
        h.discovery.yield(.found(tvB))
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 1))
    }

    // MARK: - Wi-Fi changes

    @Test func wiFiComingBackLeavesNoWiFiAndScans() async {
        let h = Harness(known: [tvA], selected: tvA.id, wifi: false)
        h.model.onAppear()
        await drain()
        #expect(h.model.screen == .noWiFi)
        h.wifi.isOn = true // e.g. turned on from Control Center
        h.wifiChanges.yield()
        await settle { !h.discovery.scans.isEmpty }
        #expect(h.model.screen != .noWiFi)
        #expect(h.discovery.scans.count == 1)
        #expect(h.sessions.list.count == 1)
    }

    @Test func wiFiGoingAwayShowsNoWiFi() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.wifi.isOn = false
        h.wifiChanges.yield()
        await settle { h.model.screen == .noWiFi }
        #expect(h.model.screen == .noWiFi)
        await settle { h.sessions.last?.snapshot.disconnects == 1 }
        #expect(h.sessions.last?.snapshot.disconnects == 1)
    }

    @Test func repeatedWiFiUpdatesDoNotStackScans() async {
        let h = Harness(known: [tvA], selected: tvA.id, wifi: false)
        h.model.onAppear()
        await drain()
        h.wifi.isOn = true
        for _ in 0..<3 { h.wifiChanges.yield() }
        await settle { !h.discovery.scans.isEmpty }
        await drain()
        #expect(h.discovery.scans.count == 1)
        #expect(h.sessions.list.count == 1)
    }

    @Test func aNewWiFiAddressRefreshes() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await h.appear()
        h.discovery.finish()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.wifiChanges.yield() // still on the same Wi-Fi: nothing to do
        await drain()
        #expect(h.discovery.scans.count == 1)
        h.wifi.address = 0x0A00_0005 // still on Wi-Fi, but another network
        for _ in 0..<3 { h.wifiChanges.yield() }
        await settle { h.discovery.scans.count == 2 }
        await drain()
        #expect(h.discovery.scans.count == 2)
    }

    @Test func wiFiChangesAreIgnoredInTheBackground() async {
        let h = Harness(known: [tvA], selected: tvA.id, wifi: false)
        h.model.onAppear()
        await drain()
        h.model.scenePhaseChanged(.background)
        h.wifi.isOn = true
        h.wifiChanges.yield()
        await drain()
        #expect(h.discovery.scans.isEmpty)
        #expect(h.sessions.list.isEmpty)
        // Back in front, the foreground refresh notices Wi-Fi.
        h.model.scenePhaseChanged(.active)
        await settle { !h.discovery.scans.isEmpty }
        #expect(h.model.screen != .noWiFi)
        #expect(h.discovery.scans.count == 1)
        #expect(h.sessions.list.count == 1)
    }

    // MARK: - Rescanning for a missing TV

    /// `misses` more unanswered watch checks; expects `scansAfter` scans, the last one sweeping.
    private func miss(_ h: Harness, _ misses: Int, scansAfter: Int) async {
        await tick(h, times: misses)
        await settle { h.discovery.scans.count == scansAfter }
        #expect(h.discovery.scans.count == scansAfter)
        #expect(h.discovery.sweeps.last == true)
    }

    @Test func aSelectedTVMissingForFiveChecksRescansWithTheSweepOncePerForegroundPeriod() async {
        var standby = tvA
        standby.powerState = .standby
        let h = Harness(known: [tvA], selected: tvA.id) // the TV doesn't answer
        await unreachableSelected(h)
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        #expect(h.discovery.scans.count == 1)
        await miss(h, 1, scansAfter: 2)
        #expect(h.model.scanFeedback == nil) // not the user's Scan Again
        h.discovery.finish() // it did not find the TV either
        await drain()
        await tick(h, times: 10) // still missing: no further sweep
        #expect(h.discovery.scans.count == 2)

        // Back from the background a day later: one more rescan after 5 misses.
        h.now.advance(by: AppModel.missingTVRescanCooldown + 1)
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == 3 && h.sessions.list.count == 2 }
        #expect(h.discovery.sweeps.last == false) // the foreground scan is automatic
        h.discovery.finish()
        await settle { h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.failed(.unreachable))
        await drain()
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        #expect(h.discovery.scans.count == 3)
        await miss(h, 1, scansAfter: 4)
        h.discovery.finish()
        await drain()

        // It answers once (asleep: nothing reconnects), then goes missing again a day later: one more rescan.
        h.now.advance(by: AppModel.missingTVRescanCooldown + 1)
        h.fetcher.answer(standby)
        await tick(h)
        h.fetcher.infos = [:]
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        #expect(h.discovery.scans.count == 4)
        await miss(h, 1, scansAfter: 5)
    }

    /// The newest session fails as unreachable once it has connected, so the watch runs on it.
    private func failNewSession(_ h: Harness, sessions: Int) async {
        await settle { h.sessions.list.count == sessions && h.sessions.last?.snapshot.connects == 1 }
        h.sessions.last?.emit(.failed(.unreachable))
        await drain()
    }

    /// From an unreachable selected TV, runs the first missing-TV rescan (scan 2) and finishes it.
    private func firstMissingTVRescan(_ h: Harness) async {
        await unreachableSelected(h)
        await miss(h, AppModel.missedChecksBeforeRescan, scansAfter: 2)
        h.discovery.finish()
        await drain()
    }

    @Test func selectingAnotherTVResetsTheMissingTVRescan() async {
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        await firstMissingTVRescan(h)
        h.model.select(tvB.id)
        await failNewSession(h, sessions: 2)
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        #expect(h.discovery.scans.count == 2)
        await miss(h, 1, scansAfter: 3)
    }

    @Test func forgettingTheSelectedTVResetsTheMissingTVRescan() async {
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        await firstMissingTVRescan(h)
        h.model.forget(tvA.id)
        h.model.select(tvB.id)
        await failNewSession(h, sessions: 2)
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        #expect(h.discovery.scans.count == 2)
        await miss(h, 1, scansAfter: 3)
    }

    @Test func wiFiReturningResetsTheMissingTVRescan() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await firstMissingTVRescan(h)
        h.now.advance(by: AppModel.missingTVRescanCooldown + 1)
        h.wifi.isOn = false // e.g. the router restarts, and may give the TV another address
        h.wifiChanges.yield()
        await settle { h.model.screen == .noWiFi }
        h.wifi.isOn = true
        h.wifiChanges.yield()
        await settle { h.discovery.scans.count == 3 }
        #expect(h.discovery.sweeps.last == false) // automatic
        h.discovery.finish()
        await failNewSession(h, sessions: 2)
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        #expect(h.discovery.scans.count == 3)
        await miss(h, 1, scansAfter: 4)
    }

    @Test func aTVThisAppTurnedOffIsNotRescannedFor() async {
        let h = Harness(known: [tvA], selected: tvA.id, power: .turnedOff, powerPlan: .turnOff)
        await connected(h)
        h.model.togglePower()
        await settle { !h.model.powerBusy && h.discovery.scans.count == 2 }
        h.discovery.finish() // the scan after turning off
        h.sessions.last?.emit(.failed(.unreachable)) // the TV went off
        await settle { h.model.status == StatusLine.tvOff }
        await tick(h, times: AppModel.missedChecksBeforeRescan + 2)
        #expect(h.discovery.scans.count == 2)
    }

    @Test func scanAgainJoinsARunningMissingTVSweep() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await unreachableSelected(h)
        await miss(h, AppModel.missedChecksBeforeRescan, scansAfter: 2) // still running
        h.model.scanAgain()
        #expect(h.model.scanFeedback == .scanning)
        await drain()
        #expect(h.discovery.scans.count == 2)
        h.discovery.yield(.found(tvB))
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 1))
    }

    @Test func anAutomaticRefreshDuringScanAgainKeepsTheSweep() async {
        let h = Harness(known: [tvA], selected: tvA.id) // power turns the TV on
        await connected(h)
        h.model.scanAgain()
        await settle { h.discovery.scans.count == 2 }
        #expect(h.discovery.sweeps == [false, true])
        h.model.togglePower() // its outcome refreshes, replacing the running scan
        await settle { h.discovery.scans.count == 3 }
        #expect(h.discovery.sweeps.last == true)
        #expect(h.model.scanFeedback == .scanning)
        h.discovery.finish()
        await settle { h.model.scanFeedback != .scanning }
        #expect(h.model.scanFeedback == .found(newTVs: 0))
    }

    @Test func anAnswerResetsTheMissedChecksBeforeARescan() async {
        var standby = tvA
        standby.powerState = .standby
        let h = Harness(known: [tvA], selected: tvA.id)
        await unreachableSelected(h)
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        h.fetcher.answer(standby) // it answers once (asleep: nothing reconnects)
        await tick(h)
        h.fetcher.infos = [:]
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        #expect(h.discovery.scans.count == 1)
        #expect(h.sessions.list.count == 1)
    }

    @Test func rescanConstants() {
        #expect(AppModel.missedChecksBeforeRescan == 5)
        #expect(AppModel.missingTVRescanCooldown == 24 * 60 * 60)
    }

    /// The stored missing-TV rescan time of `id`, if any.
    private func rescanDate(_ h: Harness, _ id: TVID) -> Double? {
        let dates = h.defaults.dictionary(forKey: AppModel.missingTVRescanDatesKey) as? [String: Double]
        return dates?[id.rawValue]
    }

    /// Goes to the background and back, then fails the new session (number `sessions`) so the watch runs.
    private func backgroundAndBack(_ h: Harness, scansAfter: Int, sessions: Int) async {
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.active)
        await settle { h.discovery.scans.count == scansAfter && h.sessions.list.count == sessions }
        h.discovery.finish()
        await failNewSession(h, sessions: sessions)
    }

    @Test func theMissingTVRescanRunsAtMostOnceADayPerTV() async {
        let h = Harness(known: [tvA], selected: tvA.id)
        await unreachableSelected(h)
        #expect(rescanDate(h, tvA.id) == nil)
        await miss(h, AppModel.missedChecksBeforeRescan, scansAfter: 2)
        #expect(rescanDate(h, tvA.id) == h.now.date.timeIntervalSinceReferenceDate)
        h.discovery.finish()
        await drain()

        // Within the day, a new foreground period does not sweep again.
        h.now.advance(by: AppModel.missingTVRescanCooldown - 60)
        await backgroundAndBack(h, scansAfter: 3, sessions: 2)
        await tick(h, times: AppModel.missedChecksBeforeRescan + 2)
        #expect(h.discovery.scans.count == 3)

        // A day after the last one: one more.
        h.now.advance(by: 61)
        await backgroundAndBack(h, scansAfter: 4, sessions: 3)
        await tick(h, times: AppModel.missedChecksBeforeRescan - 1)
        #expect(h.discovery.scans.count == 4)
        await miss(h, 1, scansAfter: 5)
        #expect(rescanDate(h, tvA.id) == h.now.date.timeIntervalSinceReferenceDate)
    }

    @Test func eachTVHasItsOwnMissingTVRescanCooldown() async {
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        await firstMissingTVRescan(h)
        h.model.select(tvB.id)
        await failNewSession(h, sessions: 2)
        await miss(h, AppModel.missedChecksBeforeRescan, scansAfter: 3)
        h.discovery.finish()
        await drain()
        #expect(rescanDate(h, tvB.id) != nil)
        // Back to the first TV: it already had its rescan today.
        h.model.select(tvA.id)
        await failNewSession(h, sessions: 3)
        await tick(h, times: AppModel.missedChecksBeforeRescan + 2)
        #expect(h.discovery.scans.count == 3)
    }

    @Test func forgettingATVRemovesItsMissingTVRescanDate() async {
        let h = Harness(known: [tvA, tvB], selected: tvA.id)
        await firstMissingTVRescan(h)
        #expect(rescanDate(h, tvA.id) != nil)
        h.model.forget(tvA.id)
        #expect(rescanDate(h, tvA.id) == nil)
    }
}
