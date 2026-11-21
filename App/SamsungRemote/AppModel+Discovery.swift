import Foundation
import SamsungTVKit

extension AppModel {
    // MARK: - Discovery

    /// Starts a scan. It includes the subnet sweep (up to 1,024 probes) only when `sweepAnyway` or when
    /// no TV is known; otherwise Bonjour (and SSDP) and probing the known addresses look for the TVs.
    /// (A known TV that is off misses every scan, so a missed TV is no reason to sweep.) A scan that
    /// replaces a sweeping one, or the user's Scan Again, keeps the sweep.
    func startScan(sweepAnyway: Bool = false) {
        let sweep = sweepAnyway || registry.tvs.isEmpty || (scanning && scanSweeps) || scanAgainBaseline != nil
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        scanning = true
        scanSweeps = sweep
        foundThisScan = []
        forgottenThisScan = []
        let hosts = registry.tvs.values.map(\.lastHost).sorted()
        let makeDiscovery = env.makeDiscovery
        scanTask = Task { [weak self] in
            let events = await makeDiscovery(hosts, sweep)
            for await event in events {
                guard let self, generation == self.scanGeneration else { return }
                self.handle(event)
            }
            guard let self, !Task.isCancelled, generation == self.scanGeneration else { return }
            self.finishScan()
        }
    }

    /// Stops the current scan; results still in flight are dropped.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        scanning = false
        clearScanFeedback()
    }

    func handle(_ event: DiscoveryEvent) {
        switch event {
        case .localNetworkDenied:
            localNetworkDenied = true
            startDeniedRetries()
        case .found(let info):
            guard !forgottenThisScan.contains(info.id) else { return }
            localNetworkDenied = false // evidently granted
            cancelDeniedRetries()
            foundThisScan.insert(info.id)
            seen[info.id] = info
            if info.powerState == .on { turnedOffTVs.remove(info.id) }
            registry.record(info, at: .now)
            saveRegistry()
            if info.id == selectedID, needsNewSession(for: info) {
                openSession(info.id)
            }
            rebuildTVs()
        }
    }

    /// The selected TV moved to another address, is now on after the session gave up on it, or
    /// answers again after its approval timed out (unless this app just turned it off).
    private func needsNewSession(for info: TVDeviceInfo) -> Bool {
        guard let current else { return true }
        if current.host != info.host { return true }
        switch sessionState {
        case .failed(.unreachable): return info.powerState == .on
        case .failed(.approvalTimedOut): return !turnedOffTVs.contains(info.id)
        default: return false
        }
    }

    /// While Local Network access looks denied and the app is active, scans again every
    /// `deniedRetryInterval` (bounded) until a TV is found.
    private func startDeniedRetries() {
        guard deniedRetryTask == nil, !inBackground else { return }
        let clock = env.clock
        deniedRetryTask = Task { [weak self] in
            for _ in 0..<Self.deniedRetryLimit {
                do {
                    try await clock.sleep(for: Self.deniedRetryInterval)
                } catch {
                    return // cancelled
                }
                if Task.isCancelled { return }
                guard let self, self.localNetworkDenied, !self.inBackground, self.onWiFi else { break }
                if !self.scanning { self.startScan() }
            }
            self?.deniedRetryTask = nil
        }
    }

    func cancelDeniedRetries() {
        deniedRetryTask?.cancel()
        deniedRetryTask = nil
    }

    private func finishScan() {
        scanning = false
        aScanHasFinished = true
        lastScanFoundNothing = foundThisScan.isEmpty
        seen = seen.filter { foundThisScan.contains($0.key) }
        if let baseline = scanAgainBaseline { finishScanAgain(baseline: baseline) }
        // With no selection, pick the TV only when there is no choice to make.
        if selectedID == nil, registry.tvs.count == 1, let only = registry.tvs.keys.first {
            select(only)
        }
        rebuildTVs()
    }
}
