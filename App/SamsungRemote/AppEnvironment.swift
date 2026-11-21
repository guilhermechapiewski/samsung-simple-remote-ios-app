import Foundation
import SamsungTVKit

/// The part of `RemoteSession` the app uses, so tests and demo mode can substitute a fake.
protocol RemoteSessionProtocol: PowerKeySending {
    /// State changes (single consumer).
    var states: AsyncStream<SessionState> { get }
    /// `true` when the TV shows its on-screen keyboard, `false` when it hides it (single consumer).
    var keyboardEvents: AsyncStream<Bool> { get }
    var currentState: SessionState { get async }
    func connect() async
    func disconnect() async
    func send(_ key: RemoteKey, _ action: KeyAction) async throws(SessionError)
    func sendText(_ s: String) async throws(SessionError)
    func sendTextEnd() async throws(SessionError)
}

extension RemoteSession: RemoteSessionProtocol {}

/// The state-aware power toggle (`PowerController` conforms). `onPlan` is told what the toggle
/// will do once the TV's power state is known.
protocol PowerToggling: Sendable {
    func togglePower(
        tv: KnownTV, sender: any PowerKeySending, onPlan: @Sendable (PowerAction) async -> Void
    ) async -> PowerOutcome?
}

extension PowerController: PowerToggling {}

/// Where the known-TV registry is persisted (`FileKnownTVStore` conforms).
protocol KnownTVPersisting: Sendable {
    func load() -> KnownTVRegistry
    func save(_ r: KnownTVRegistry) throws
}

extension FileKnownTVStore: KnownTVPersisting {}

/// Every dependency of `AppModel`: real objects in the app, fakes in tests and demo mode.
struct AppEnvironment {
    /// Starts one scan that also probes `knownHosts`, and sweeps the Wi-Fi subnet when `sweep` is true;
    /// the stream ends when the scan is complete.
    var makeDiscovery: @Sendable (_ knownHosts: [String], _ sweep: Bool) async -> AsyncStream<DiscoveryEvent>
    var makeSession: @Sendable (_ id: TVID, _ host: String) -> any RemoteSessionProtocol
    var makePowerController: @Sendable () -> any PowerToggling
    /// Used by "Add TV by IP address".
    var fetcher: any TVInfoFetching
    var credentials: any CredentialStore
    var labels: any LabelStore
    var knownTVStore: any KnownTVPersisting
    /// The current Wi-Fi interface, or nil when not on Wi-Fi.
    var wifiInterface: @Sendable () -> IPv4Interface?
    /// Emits when Wi-Fi may have become available or unavailable (single consumer); `wifiInterface`
    /// still decides whether the device is on Wi-Fi.
    var wifiChanges: @Sendable () -> AsyncStream<Void>
    var clock: any Clock<Duration>
    /// The current wall-clock time (for limits that span launches, such as the missing-TV rescan's).
    var now: @Sendable () -> Date
    var userDefaults: UserDefaults
    /// Whether this build has the multicast networking entitlement (SSDP discovery and broadcast
    /// Wake-on-LAN). Without it, discovery uses Bonjour plus a subnet sweep (when the user scans, no TV is
    /// known, or the selected TV stops answering), and waking sends a unicast packet only.
    var multicastEnabled = false
}

extension AppEnvironment {
    /// The real network, Keychain, iCloud and file-backed dependencies.
    static func live() -> AppEnvironment {
        let credentials = KeychainCredentialStore()
        // A TV that stalls (accepts the connection, then answers nothing for seconds) is asked again; one
        // that is off accepts no connection and fails as fast as without a budget.
        let discoveryFetcher = HTTPTVInfoFetcher(stallBudget: .seconds(12))
        let multicast = Self.buildHasMulticastEntitlement
        let wifiInterface: @Sendable () -> IPv4Interface? = {
            NetworkInterfaces.wifiIPv4(from: NetworkInterfaces.current())
        }
        return AppEnvironment(
            makeDiscovery: { knownHosts, sweep in
                var sources: [any CandidateSource] = [BonjourSamsungBrowser()]
                if multicast { sources.append(SSDPSearcher()) }
                if sweep { sources.append(SubnetSweep(interface: wifiInterface)) }
                return await DiscoveryCoordinator(
                    sources: sources,
                    fetcher: discoveryFetcher,
                    knownHosts: knownHosts
                ).scan()
            },
            makeSession: { id, host in
                RemoteSession(id: id, host: host, credentials: credentials, transport: { URLSessionWebSocketTransport() })
            },
            makePowerController: {
                PowerController(
                    // Shorter: the user is waiting on the button. A stall mistaken for "off" only sends a
                    // harmless wake packet, and the app then connects once the TV answers.
                    fetcher: HTTPTVInfoFetcher(timeout: .seconds(1), stallBudget: .seconds(5)),
                    wake: { mac, interface, host in
                        await WakeOnLAN.send(to: mac, via: interface, host: host, broadcast: multicast)
                    },
                    interface: wifiInterface
                )
            },
            fetcher: discoveryFetcher,
            credentials: credentials,
            labels: ICloudLabelStore(),
            knownTVStore: FileKnownTVStore(),
            wifiInterface: wifiInterface,
            wifiChanges: { WiFiPathMonitor().changes() },
            clock: ContinuousClock(),
            now: { Date() },
            userDefaults: .standard,
            multicastEnabled: multicast
        )
    }

    /// `SRMulticastEnabled` in Info.plist, set from the `SAMSUNG_REMOTE_MULTICAST` build setting, which
    /// also picks the entitlements file (see Config/Base.xcconfig); the "Check entitlements" build
    /// phase fails the build if the two disagree.
    static var buildHasMulticastEntitlement: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SRMulticastEnabled") as? String == "YES"
    }
}
