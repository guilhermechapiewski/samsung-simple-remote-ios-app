import Foundation
import os
import SamsungTVKit

extension AppModel {
    // MARK: - Keys

    func press(_ key: RemoteKey) {
        send(key, .click)
    }

    /// One KEY_PLAY_BACK click, which toggles play and pause on the TV.
    func playPause() {
        send(.playPause, .click)
    }

    func beginHold(_ key: RemoteKey) {
        guard isConnected else {
            statusEvent = notConnectedReason
            return
        }
        repeater.begin(key)
    }

    func endHold() {
        repeater.end()
    }

    func sendText(_ text: String) {
        enqueueIfConnected { session throws(SessionError) in try await session.sendText(text) }
    }

    /// Tells the TV text entry is done.
    func endText() {
        // The TV is no longer asked for text, so a later request from it shows the sheet again.
        keyboardRequested = false
        enqueueIfConnected { session throws(SessionError) in try await session.sendTextEnd() }
    }

    @discardableResult
    private func send(_ key: RemoteKey, _ action: KeyAction) -> Task<Void, Never>? {
        enqueueIfConnected { session throws(SessionError) in try await session.send(key, action) }
    }

    func sendFromHold(_ key: RemoteKey, _ action: KeyAction) async {
        // A release after the session closed (e.g. on background) has nothing to release.
        if action == .release, !isConnected { return }
        await send(key, action)?.value
    }

    /// Runs `operation` on the selected session after its earlier work, or explains why it cannot.
    @discardableResult
    private func enqueueIfConnected(
        _ operation: @escaping @MainActor (any RemoteSessionProtocol) async throws(SessionError) -> Void
    ) -> Task<Void, Never>? {
        guard let handle = current, isConnected else {
            statusEvent = notConnectedReason
            return nil
        }
        return handle.enqueue { [weak self] session in
            do {
                try await operation(session)
            } catch {
                guard let self, handle === self.current else { return }
                Self.log.error("Send failed: \(String(describing: error), privacy: .public)")
                self.statusEvent = .reconnecting
            }
        }
    }

    /// Why a key press did nothing.
    private var notConnectedReason: StatusLine {
        if !onWiFi { return .notOnWiFi }
        guard selectedID != nil, current != nil else { return .chooseTVFirst }
        switch sessionState {
        case .awaitingApproval: return .chooseAllow
        case .failed(.denied): return .blocked
        case .failed(.identityChanged): return .identityChanged
        case .failed(.unreachable) where selectedTurnedOff, .failed(.approvalTimedOut) where selectedTurnedOff:
            return .tvOff
        case .failed(.unreachable): return unreachableLine
        case .failed(.approvalTimedOut): return .approvalTimedOut
        case .idle where selectedAppearsOff, .connecting where selectedAppearsOff: return .offPressPower
        case .idle, .connecting, .connected: return .connecting(to: selectedTitle)
        }
    }
}
