import Foundation
import Observation
import os
import SamsungTVKit
import SwiftUI

/// The app's state and actions: discovery, the known TVs, the selected TV's session, power and
/// hold-to-repeat. Every dependency comes from the `AppEnvironment`.
@MainActor
@Observable
final class AppModel {
    static let selectedTVKey = "selectedTV"

    /// Shown once per TV, after its first successful connection.
    static let powerTipTitle = "Turn On “Power On with Mobile”"
    static let powerTipMessage =
        "To turn this TV on from your iPhone, the TV's “Power On with Mobile” setting must be on: "
        + "\(StatusLine.powerOnWithMobilePath)."
    /// TV ids that have already been shown the power tip.
    static let powerTipShownKey = "powerTipShownTVs"
    /// How long "Connected to …" stays up after a connection.
    static let connectedConfirmationDuration: Duration = .seconds(2)
    /// While Local Network access looks denied, scan again this often (e.g. the user is still
    /// answering the permission prompt), up to `deniedRetryLimit` times.
    static let deniedRetryInterval: Duration = .seconds(3)
    static let deniedRetryLimit = 20
    /// While the selected TV is not connected (unreachable, or its session retrying after a drop) and the
    /// app is in front, its info is checked this often, so a TV that finishes booting late, or is turned
    /// on with its own remote, connects within seconds.
    static let watchInterval: Duration = .seconds(2)
    /// A connection attempt still running after this many watch ticks while the TV answers as on is
    /// stalled (the session is waiting out its reconnect backoff), so a fresh attempt starts at once.
    /// Longer than one connect attempt (5 s), so a normal attempt is never interrupted.
    static let stalledConnectTicks = 4
    /// How long a Scan Again result stays on screen.
    static let scanResultDuration: Duration = .seconds(3)

    static let log = Logger(subsystem: "SamsungRemote", category: "AppModel")

    // `tvs`, `selectedID` and `keyboardRequested` are mutated only from `AppModel`'s extensions.
    var tvs: [TVListItem] = []
    var selectedID: TVID?
    /// A power toggle is in flight for the selected TV.
    var powerBusy: Bool { selectedID.map(powerBusyTVs.contains) ?? false }
    /// What the selected TV's power toggle is doing, once the TV's state has been checked.
    var powerDirection: PowerDirection? { selectedID.flatMap { powerDirections[$0] } }
    /// The TV is showing its on-screen keyboard and wants text.
    var keyboardRequested = false
    /// The last event worth telling the user about (a failure, a key that didn't arrive); cleared when the
    /// session makes progress or another TV is chosen.
    var statusEvent: StatusLine?
    /// The TV to show the one-time "Power On with Mobile" tip for, or nil.
    var powerTipTV: TVID?
    /// "Connected to …" is showing (briefly, after a connection).
    var showsConnected = false
    @ObservationIgnored var connectedConfirmationTask: Task<Void, Never>?
    /// Progress and result of a user-started scan, or nil.
    private(set) var scanFeedback: ScanFeedback?

    var onWiFi = true
    /// The Wi-Fi interface the last `refresh()` saw (nil when off Wi-Fi).
    @ObservationIgnored private var lastWiFiInterface: IPv4Interface?
    var localNetworkDenied = false
    var scanning = false
    /// State of the selected TV's session (`.idle` when there is none).
    var sessionState: SessionState = .idle
    var registry = KnownTVRegistry()
    /// Latest info per TV found in the current or last completed scan.
    var seen: [TVID: TVDeviceInfo] = [:]
    /// TVs with a power toggle in flight.
    var powerBusyTVs: Set<TVID> = []
    /// Direction of each in-flight power toggle whose plan is known.
    var powerDirections: [TVID: PowerDirection] = [:]
    /// TVs this app just turned off: their sessions failing is expected, so it is not reported, and
    /// they show as asleep until seen on again.
    var turnedOffTVs: Set<TVID> = []

    /// Counts the repeated clicks of holds (not the first click of each), to drive the repeat haptic.
    private(set) var holdRepeats = 0

    @ObservationIgnored let env: AppEnvironment
    /// One power controller per TV, so each TV has its own in-flight guard.
    @ObservationIgnored var powerControllers: [TVID: any PowerToggling] = [:]
    @ObservationIgnored var repeater: RepeatController!
    @ObservationIgnored var current: SessionHandle?
    /// Disconnects of closed sessions (and credential deletes after them), chained in order; every
    /// new session waits for this before its first operation.
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored var foundThisScan: Set<TVID> = []
    /// TVs forgotten during the current scan; its in-flight results for them are ignored.
    @ObservationIgnored var forgottenThisScan: Set<TVID> = []
    @ObservationIgnored var scanTask: Task<Void, Never>?
    @ObservationIgnored var scanGeneration = 0
    /// The last completed scan found no TV (e.g. it ran while the Local Network prompt was up).
    @ObservationIgnored var lastScanFoundNothing = false
    /// The running scan includes the subnet sweep.
    @ObservationIgnored var scanSweeps = false
    @ObservationIgnored var deniedRetryTask: Task<Void, Never>?
    /// The TVs known when the user started a scan; nil while no user-started scan is running.
    @ObservationIgnored var scanAgainBaseline: Set<TVID>?
    @ObservationIgnored private var scanResultTask: Task<Void, Never>?
    @ObservationIgnored var watchTask: Task<Void, Never>?
    /// Watch ticks since the session last changed state while it is connecting.
    @ObservationIgnored var connectingTicks = 0
    /// Consecutive watch checks the connected TV did not answer.
    @ObservationIgnored var missedWhileConnected = 0
    /// Consecutive watch checks the selected TV did not answer, in any watched session state.
    @ObservationIgnored var missedChecks = 0
    /// The missing-TV rescan already ran for the selected TV in this foreground period (and the TV has
    /// not answered since).
    @ObservationIgnored var missingTVRescanDone = false
    /// A connected TV that misses this many checks in a row is treated as gone (an open connection to a TV
    /// that lost power can take the transport's 15-30 s ping cycle to notice).
    static let missedChecksBeforeReconnect = 2
    /// When the selected TV misses this many watch checks in a row (it may have moved to another address),
    /// a scan with the subnet sweep runs, once per foreground period for that TV until it answers again.
    static let missedChecksBeforeRescan = 5
    /// The missing-TV rescan runs at most once per TV in this long, across launches: a TV that is simply
    /// off would otherwise be swept for soon after almost every app open.
    static let missingTVRescanCooldown: TimeInterval = 24 * 60 * 60
    /// When each TV last had a missing-TV rescan: TV id → seconds since the reference date.
    static let missingTVRescanDatesKey = "missingTVRescanDates"
    /// The last watch check found the selected TV not answering while its session was retrying.
    var watchFoundNoAnswer = false
    /// The selected TV has connected since it was chosen (so it was answering, whatever the last scan saw).
    var selectedHasConnected = false
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var wifiTask: Task<Void, Never>?
    @ObservationIgnored var appeared = false
    @ObservationIgnored var inBackground = false

    init(env: AppEnvironment) {
        self.env = env
        repeater = RepeatController(clock: env.clock, strategy: .default) { [weak self] key, action in
            await self?.sendFromHold(key, action)
        }
        repeater.onRepeat = { [weak self] in self?.holdRepeats += 1 }
        loadRemembered()
    }

    /// Loads the remembered TVs and selection (a small local file and defaults), so the very first frame
    /// shows them instead of an empty "No TVs found" state. Network work waits for `onAppear()`.
    private func loadRemembered() {
        registry = env.knownTVStore.load()
        if let raw = env.userDefaults.string(forKey: Self.selectedTVKey) {
            let id = TVID(rawValue: raw)
            if registry.tvs[id] != nil {
                selectedID = id
            } else {
                env.userDefaults.removeObject(forKey: Self.selectedTVKey)
            }
        }
        rebuildTVs()
    }

    var screen: ScreenState {
        if !onWiFi { return .noWiFi }
        if localNetworkDenied { return .localNetworkDenied }
        if selectedID != nil {
            switch sessionState {
            case .awaitingApproval: return .pairing
            case .failed(.denied): return .pairingDenied
            case .failed(.identityChanged): return .identityChanged
            case .idle, .connecting, .connected, .failed(.unreachable), .failed(.approvalTimedOut): return .ready
            }
        }
        if tvs.isEmpty { return scanning ? .searching : .noTVs }
        return .chooseTV
    }

    /// The selected TV's session is connected, so keys can be sent.
    var isConnected: Bool { current != nil && sessionState == .connected }

    /// The remote's keys (other than Power) can be used: connected, and the TV isn't off. A TV in network
    /// standby can keep its connection open, so being connected is not enough.
    var controlsAvailable: Bool { isConnected && !selectedTurnedOff }

    var selectedTurnedOff: Bool { selectedID.map(turnedOffTVs.contains) ?? false }

    private var sessionFailed: Bool {
        if case .failed = sessionState { return true }
        return false
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard !appeared else { return }
        appeared = true
        let changes = env.labels.changes
        labelTask = Task { [weak self] in
            for await _ in changes { self?.rebuildTVs() }
        }
        let wifiChanges = env.wifiChanges()
        wifiTask = Task { [weak self] in
            for await _ in wifiChanges { self?.wifiMayHaveChanged() }
        }
        rebuildTVs()
        refresh()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            inBackground = true
            repeater.end()
            cancelScan()
            cancelDeniedRetries()
            closeSession()
            rebuildTVs()
            updateWatch()
        case .active:
            if inBackground {
                inBackground = false
                resetMissingTVRescan()
                refresh()
            } else if appeared, localNetworkDenied || (!scanning && lastScanFoundNothing) {
                // Back from a system alert (such as the Local Network prompt, answered after the
                // scan gave up): look again.
                refresh()
            }
        default:
            break
        }
    }

    /// Wi-Fi may have come back, gone away (e.g. from Control Center) or moved to another network or
    /// address: refreshes only when the Wi-Fi interface actually changed since the last one seen, so
    /// repeated path updates never stack scans or sessions.
    private func wifiMayHaveChanged() {
        guard !inBackground, env.wifiInterface() != lastWiFiInterface else { return }
        refresh()
    }

    /// Re-checks Wi-Fi, reconnects the selected TV if it has no session or its session failed
    /// (this is also "Try Again"), and scans again, with the subnet sweep (the user asked).
    func rescan() {
        refresh(userStarted: true)
    }

    /// The user's Scan Again: like `rescan()`, but shows progress and then how many new TVs were
    /// found. Joins a scan that is already running instead of restarting it, unless that scan skips the
    /// subnet sweep: the user's scan always sweeps.
    func scanAgain() {
        guard scanFeedback != .scanning else { return }
        guard env.wifiInterface() != nil else {
            refresh() // shows the no-Wi-Fi state; no progress to show
            return
        }
        clearScanFeedback()
        scanAgainBaseline = Set(registry.tvs.keys)
        scanFeedback = .scanning
        refresh(restartScan: !scanning || !scanSweeps, userStarted: true)
    }

    /// `userStarted` scans always include the subnet sweep.
    func refresh(restartScan: Bool = true, userStarted: Bool = false) {
        let wasOnWiFi = onWiFi
        lastWiFiInterface = env.wifiInterface()
        onWiFi = lastWiFiInterface != nil
        // Back on Wi-Fi (e.g. after a router restart, which may move the TV): a fresh missing-TV rescan.
        if onWiFi, !wasOnWiFi { resetMissingTVRescan() }
        guard onWiFi else {
            repeater.end()
            cancelScan()
            closeSession()
            rebuildTVs()
            return
        }
        if let id = selectedID, current == nil || sessionFailed { openSession(id) }
        if restartScan { startScan(sweepAnyway: userStarted) }
    }

    func clearScanFeedback() {
        scanResultTask?.cancel()
        scanResultTask = nil
        scanAgainBaseline = nil
        scanFeedback = nil
    }

    /// Shows the result of a user-started scan for `scanResultDuration`.
    func finishScanAgain(baseline: Set<TVID>) {
        scanAgainBaseline = nil
        scanFeedback = .found(newTVs: foundThisScan.subtracting(baseline).count)
        let clock = env.clock
        scanResultTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.scanResultDuration)
            } catch {
                return // cancelled: a newer scan or the background took over
            }
            self?.scanResultTask = nil
            self?.scanFeedback = nil
        }
    }

    // MARK: - Selection and sessions

    func select(_ id: TVID) {
        guard registry.tvs[id] != nil else { return }
        if id == selectedID, let current, current.host == registry.tvs[id]?.lastHost, !sessionFailed { return }
        repeater.end()
        if id != selectedID {
            resetMissingTVRescan()
            selectedHasConnected = false
        }
        selectedID = id
        env.userDefaults.set(id.rawValue, forKey: Self.selectedTVKey)
        statusEvent = nil
        if onWiFi {
            openSession(id)
        } else {
            closeSession()
        }
        rebuildTVs()
    }

    /// Replaces the current session with a new one for `id` at its last known host and connects it
    /// once every earlier teardown has finished.
    func openSession(_ id: TVID) {
        guard let tv = registry.tvs[id] else { return }
        closeSession()
        let handle = SessionHandle(host: tv.lastHost, session: env.makeSession(id, tv.lastHost), after: teardown)
        current = handle
        let session = handle.session
        handle.observers = [
            Task { [weak self] in
                for await state in session.states { self?.sessionStateChanged(state, on: handle) }
            },
            Task { [weak self] in
                for await shown in session.keyboardEvents { self?.keyboardChanged(shown, on: handle) }
            },
        ]
        handle.enqueue { await $0.connect() }
    }

    /// Stops observing and disconnects the current session, chaining the disconnect onto `teardown`.
    func closeSession() {
        guard let handle = current else { return }
        current = nil
        sessionState = .idle
        endConnectedConfirmation()
        updateWatch()
        keyboardRequested = false
        let disconnect = handle.close()
        afterTeardown { await disconnect.value }
    }

    /// Appends `work` to `teardown`, after every earlier disconnect.
    func afterTeardown(_ work: @escaping @MainActor () async -> Void) {
        let previous = teardown
        teardown = Task {
            await previous?.value
            await work()
        }
    }

    func sessionStateChanged(_ state: SessionState, on handle: SessionHandle) {
        guard handle === current else { return }
        connectingTicks = 0
        missedWhileConnected = 0
        watchFoundNoAnswer = false
        let wasConnected = sessionState == .connected
        sessionState = state
        if state == .connected, !wasConnected {
            confirmConnected()
        } else if state != .connected {
            endConnectedConfirmation()
        }
        if state == .connected, let id = selectedID {
            selectedHasConnected = true
            turnedOffTVs.remove(id)
            if !powerTipShown.contains(id.rawValue) { powerTipTV = id }
        }
        switch state {
        case .connecting, .awaitingApproval, .connected, .failed(.denied), .failed(.identityChanged):
            // Progress makes older explanations stale; failure screens explain themselves.
            statusEvent = nil
        case .failed(.unreachable), .failed(.approvalTimedOut):
            // While a power toggle runs, its outcome explains what happened; a TV just turned off
            // is expected to go away.
            if powerBusy {
                break
            } else if selectedTurnedOff {
                statusEvent = .tvOff
            } else {
                statusEvent = state == .failed(.unreachable) ? unreachableLine : .approvalTimedOut
            }
        case .idle:
            break
        }
        if state != .connected { repeater.end() }
        rebuildTVs()
        updateWatch()
    }

    private func keyboardChanged(_ shown: Bool, on handle: SessionHandle) {
        guard handle === current else { return }
        keyboardRequested = shown
    }
}
