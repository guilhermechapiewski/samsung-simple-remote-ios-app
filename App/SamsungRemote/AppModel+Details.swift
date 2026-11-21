import Foundation
import os
import SamsungTVKit

extension AppModel {
    // MARK: - Managing TVs

    /// The TV's own name, ignoring any label.
    func reportedName(for id: TVID) -> String? { registry.tvs[id]?.reportedName }

    /// Sets the TV's label; nil, empty or whitespace-only clears it.
    func rename(_ id: TVID, to label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        env.labels.setLabel(trimmed.isEmpty ? nil : trimmed, for: id)
        rebuildTVs()
    }

    /// Removes the TV's registry entry, label and credentials, disconnecting it if selected.
    /// Never selects another TV; a later scan may, if exactly one TV remains.
    func forget(_ id: TVID) {
        // In-flight scan results must not record the TV again.
        if scanning { cancelScan() }
        forgottenThisScan.insert(id)
        if id == selectedID {
            repeater.end()
            closeSession()
            selectedID = nil
            resetMissingTVRescan()
            env.userDefaults.removeObject(forKey: Self.selectedTVKey)
            statusEvent = nil
        }
        registry.forget(id)
        saveRegistry()
        removeMissingTVRescanDate(for: id)
        seen[id] = nil
        turnedOffTVs.remove(id)
        env.labels.setLabel(nil, for: id)
        // After the disconnect, so a session mid-pairing cannot store credentials again, and before
        // any new session (which waits for `teardown`) could store fresh ones.
        let credentials = env.credentials
        afterTeardown { credentials.delete(id) }
        rebuildTVs()
    }

    /// Adds the TV at `host` (a private or link-local IPv4 address) and selects it.
    func addManually(host: String) async -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalAddress.isAllowed(host) else { return false }
        let info: TVDeviceInfo
        do {
            info = try await env.fetcher.fetchInfo(host: host)
        } catch {
            Self.log.info("No Samsung TV at manual address: \(String(describing: error), privacy: .public)")
            return false
        }
        // The user cancelled the sheet while the TV was being asked.
        guard !Task.isCancelled else { return false }
        forgottenThisScan.remove(info.id) // explicitly added again
        seen[info.id] = info
        registry.record(info, at: .now)
        saveRegistry()
        select(info.id)
        rebuildTVs()
        return true
    }

    /// Forgets the selected TV's pairing and connects again, so the TV asks to Allow once more.
    func repair() {
        guard let id = selectedID else { return }
        statusEvent = nil
        closeSession()
        let credentials = env.credentials
        afterTeardown { credentials.delete(id) }
        openSession(id)
        rebuildTVs()
    }

    // MARK: - TV details

    /// What is known about a TV without asking it; nil for a TV the app does not know.
    func details(for id: TVID) -> TVDetailsSnapshot? {
        snapshot(id, live: nil)
    }

    /// Asks the TV for its current details, falling back to `details(for:)` when it does not answer
    /// (or a different TV answers at its address). A live answer also updates the TV's status, as a
    /// scan would. Nil when the TV is not (or no longer) known.
    func liveDetails(for id: TVID) async -> TVDetailsSnapshot? {
        guard let known = registry.tvs[id] else { return nil }
        guard onWiFi, let info = try? await env.fetcher.fetchInfo(host: known.lastHost), info.id == id,
              registry.tvs[id] != nil else {
            return details(for: id)
        }
        seen[info.id] = info
        if info.powerState == .on { turnedOffTVs.remove(info.id) }
        registry.record(info, at: .now)
        saveRegistry()
        rebuildTVs()
        return snapshot(id, live: info)
    }

    private func snapshot(_ id: TVID, live: TVDeviceInfo?) -> TVDetailsSnapshot? {
        guard let known = registry.tvs[id] else { return nil }
        return TVDetailsSnapshot(
            id: id,
            title: env.labels.label(for: id) ?? known.reportedName,
            status: status(of: id),
            known: known,
            info: live ?? seen[id],
            isLive: live != nil,
            paired: env.credentials.load(id)?.token != nil
        )
    }

    func rebuildTVs() {
        let titled = registry.tvs.values.map { tv in (tv, env.labels.label(for: tv.id) ?? tv.reportedName) }
        // Identical TVs can report identical names (two 2019 models in testing); their addresses tell them apart.
        let key = { (title: String) in title.trimmingCharacters(in: .whitespaces).lowercased() }
        let counts = Dictionary(titled.map { (key($0.1), 1) }, uniquingKeysWith: +)
        tvs = titled
            .map { tv, title in
                let shared = counts[key(title), default: 0] > 1
                return TVListItem(id: tv.id, title: title,
                                  subtitle: shared ? "\(tv.modelName) · \(tv.lastHost)" : tv.modelName,
                                  status: status(of: tv.id))
            }
            .sorted { lhs, rhs in
                let (l, r) = (lhs.status.answers, rhs.status.answers)
                if l != r { return l }
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id.rawValue < rhs.id.rawValue : order == .orderedAscending
            }
    }

    private func status(of id: TVID) -> TVStatus {
        if id == selectedID, current != nil {
            switch sessionState {
            case .awaitingApproval: return .pairing
            case .connected: return turnedOffTVs.contains(id) ? .asleep : .on
            case .failed(.unreachable), .failed(.approvalTimedOut):
                return turnedOffTVs.contains(id) ? .asleep : notAnswering(id)
            case .idle, .connecting, .failed(.denied), .failed(.identityChanged): break
            }
        }
        // Cleared as soon as the TV is seen on again, so it outranks an older scan result.
        if turnedOffTVs.contains(id) { return .asleep }
        guard let info = seen[id] else { return notAnswering(id) }
        return info.powerState == .on ? .on : .asleep
    }

    /// A TV that isn't answering: off when the app can wake it, else unreachable.
    private func notAnswering(_ id: TVID) -> TVStatus {
        isWakeable(id) ? .off : .unreachable
    }

    /// Power could turn the TV on: its Wake-on-LAN MAC is known and the iPhone is on Wi-Fi.
    func isWakeable(_ id: TVID) -> Bool {
        onWiFi && registry.tvs[id]?.wifiMAC != nil
    }

    func saveRegistry() {
        do {
            try env.knownTVStore.save(registry)
        } catch {
            Self.log.error("Saving known TVs failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
