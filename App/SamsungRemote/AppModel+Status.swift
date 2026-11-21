import Foundation
import SamsungTVKit

extension AppModel {
    // MARK: - Derived state

    /// The title of `status`.
    var statusText: String? { status?.title }

    /// The status line above the D-pad: power progress, else the last event, else what the selected TV's
    /// session is doing. Nil when connected with nothing to say.
    var status: StatusLine? {
        if let powerDirection { return powerDirection == .turningOn ? .turningOn : .turningOff }
        if let statusEvent { return statusEvent }
        guard screen == .ready else { return Self.screenStatusText(screen).map { StatusLine($0, tone: .info) } }
        if selectedTurnedOff, sessionState != .awaitingApproval { return .tvOff }
        if selectedAppearsOff { return .offPressPower }
        switch sessionState {
        case .connected:
            return showsConnected ? .connected(to: selectedTitle) : nil
        case .failed(.unreachable):
            return .unreachable
        case .failed(.approvalTimedOut):
            return .approvalTimedOut
        case .connecting where watchFoundNoAnswer:
            // Still retrying, but the TV isn't answering: say so rather than "Connecting…".
            return .unreachable
        case .idle, .connecting, .awaitingApproval, .failed(.denied), .failed(.identityChanged):
            return .connecting(to: selectedTitle)
        }
    }

    var selectedTitle: String? { tvs.first { $0.id == selectedID }?.title }

    /// The selected TV isn't answering and Power could turn it on: its session failed as unreachable, the watch
    /// found no answer while connecting, or (until it has connected since it was chosen) the last finished scan
    /// didn't see it. Then the status line says "Press Power to turn the TV on" instead of a failing
    /// "Connecting…" or "Can't reach the TV".
    var selectedAppearsOff: Bool {
        guard let id = selectedID, isWakeable(id) else { return false }
        switch sessionState {
        case .failed(.unreachable): return true
        case .idle, .connecting: return watchFoundNoAnswer || (!scanning && seen[id] == nil && !selectedHasConnected)
        case .connected, .awaitingApproval, .failed: return false
        }
    }

    /// The line for a session that failed as unreachable.
    var unreachableLine: StatusLine {
        selectedID.map(isWakeable) == true ? .offPressPower : .unreachable
    }

    func confirmConnected() {
        connectedConfirmationTask?.cancel()
        showsConnected = true
        let clock = env.clock
        connectedConfirmationTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.connectedConfirmationDuration)
            } catch {
                return // cancelled
            }
            self?.showsConnected = false
            self?.connectedConfirmationTask = nil
        }
    }

    func endConnectedConfirmation() {
        connectedConfirmationTask?.cancel()
        connectedConfirmationTask = nil
        showsConnected = false
    }

    var powerTipShown: [String] {
        env.userDefaults.stringArray(forKey: Self.powerTipShownKey) ?? []
    }

    /// The user acknowledged the power tip; it is not shown again for that TV.
    func dismissPowerTip() {
        guard let id = powerTipTV else { return }
        powerTipTV = nil
        var shown = powerTipShown
        if !shown.contains(id.rawValue) { shown.append(id.rawValue) }
        env.userDefaults.set(shown, forKey: Self.powerTipShownKey)
    }

    /// The status line's explanation of each screen state other than `.ready`.
    static func screenStatusText(_ screen: ScreenState) -> String? {
        switch screen {
        case .ready: nil
        case .noWiFi: "Not connected to Wi-Fi"
        case .localNetworkDenied: "Local Network access is turned off"
        case .searching: "Searching for TVs…"
        case .noTVs: "No TVs found"
        case .chooseTV: "Choose a TV"
        case .pairing: "Pairing with the TV…"
        case .pairingDenied: "The TV blocked this iPhone"
        case .identityChanged: "The TV's security identity changed"
        }
    }
}
