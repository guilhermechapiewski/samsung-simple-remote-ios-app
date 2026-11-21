import Foundation
import Testing
import SamsungTVKit
@testable import SamsungRemote

@MainActor
@Suite struct RemoteViewLogicTests {
    @Test func controlsNeedAReadyConnectedTV() {
        #expect(RemoteAvailability(screen: .ready, isConnected: true, hasSelection: true).controls)
        #expect(!RemoteAvailability(screen: .ready, isConnected: false, hasSelection: true).controls)
        #expect(!RemoteAvailability(screen: .pairing, isConnected: true, hasSelection: true).controls)
        #expect(!RemoteAvailability(screen: .chooseTV, isConnected: false, hasSelection: false).controls)
    }

    @Test func addressFieldNormalizesCommasAndWhitespace() {
        #expect(AddTVSheet.normalized("192,168,0,20") == "192.168.0.20")
        #expect(AddTVSheet.normalized(" 10.0.0.5 ") == "10.0.0.5")
    }

    @Test func powerOnlyNeedsASelectedTV() {
        // Power can wake a TV the app cannot reach.
        #expect(RemoteAvailability(screen: .ready, isConnected: false, hasSelection: true).power)
        #expect(RemoteAvailability(screen: .pairingDenied, isConnected: false, hasSelection: true).power)
        #expect(!RemoteAvailability(screen: .chooseTV, isConnected: false, hasSelection: false).power)
    }

    @Test func everyScreenStateOtherThanReadyIsExplained() {
        #expect(AppModel.screenStatusText(.ready) == nil)
        let states: [ScreenState] = [
            .noWiFi, .localNetworkDenied, .searching, .noTVs, .chooseTV, .pairing, .pairingDenied, .identityChanged,
        ]
        let texts = states.map(AppModel.screenStatusText)
        #expect(texts.allSatisfy { !($0 ?? "").isEmpty })
        #expect(Set(texts).count == states.count)
    }

    @Test func tvStatusNames() {
        #expect(TVStatus.on.displayName == "On")
        #expect(TVStatus.asleep.displayName == "Asleep")
        #expect(TVStatus.unreachable.displayName == "Unreachable")
        #expect(TVStatus.off.displayName == "Off")
        #expect(TVStatus.off.dotColor == .gray)
        #expect(TVStatus.pairing.displayName == "Pairing")
    }

    @Test func demoEnvironmentStartsConnectedToLivingRoom() async {
        let model = AppModel(env: DemoEnvironment.make(.remote))
        model.onAppear()
        for _ in 0..<10_000 where !(model.isConnected && model.tvs.count == 3) { await Task.yield() }
        #expect(model.screen == .ready)
        #expect(model.isConnected)
        #expect(model.tvs.map(\.title).sorted() == ["Bedroom", "Living Room", "Patio"])
        #expect(model.tvs.first { $0.id == model.selectedID }?.title == "Living Room")
        #expect(model.tvs.first { $0.title == "Living Room" }?.status == .on)
    }

    @Test func holdKeyActivationWithoutTouchPressesOnce() {
        var gate = HoldActivationGate()
        let now = ContinuousClock.now
        let pressed1 = gate.shouldPress(onActionAt: now)
        #expect(pressed1)
    }

    @Test func holdKeyTouchIsNotSentTwice() {
        var gate = HoldActivationGate()
        let now = ContinuousClock.now
        gate.pressChanged(true, at: now)
        // The action may arrive before or after the release is observed.
        let pressed2 = gate.shouldPress(onActionAt: now + .milliseconds(80))
        #expect(!pressed2)
        gate.pressChanged(false, at: now + .milliseconds(90))

        gate.pressChanged(true, at: now + .seconds(1))
        gate.pressChanged(false, at: now + .seconds(1) + .milliseconds(80))
        let pressed3 = gate.shouldPress(onActionAt: now + .seconds(1) + .milliseconds(90))
        #expect(!pressed3)
    }

    @Test func holdKeyActivationLongAfterACancelledTouchPresses() {
        var gate = HoldActivationGate()
        let now = ContinuousClock.now
        gate.pressChanged(true, at: now)
        gate.pressChanged(false, at: now + .milliseconds(50)) // dragged off: no action
        let pressed4 = gate.shouldPress(onActionAt: now + .seconds(3))
        #expect(pressed4)
    }

    @Test func discoveryHintsSayTheTVMustBeOn() {
        let found = "A TV can only be found while it's on. After that, the app remembers it, even when it's off."
        #expect(StateCard.hint(for: .searching) == found)
        #expect(StateCard.hint(for: .noTVs) == found)
        #expect(StateCard.hint(for: .chooseTV) == "Don't see your TV? Turn it on, then tap Scan Again.")
        for screen in [ScreenState.ready, .noWiFi, .localNetworkDenied, .pairing, .pairingDenied, .identityChanged] {
            #expect(StateCard.hint(for: screen) == nil)
        }
    }

    @Test func findTVHelpCopyIsExact() {
        #expect(FindTVHelp.title == "Can't Find Your TV?")
        #expect(FindTVHelp.steps.map(\.title) == ["Turn the TV on.", "Use the same Wi-Fi.", "Turn on AirPlay on the TV.",
                                                  "Restart the TV.", "Add it by IP address."])
        #expect(FindTVHelp.steps.map(\.detail) == [
            "A TV can only be found while it's on.",
            "Your iPhone and TV must be on the same network. Guest networks and networks that keep devices apart don't work.",
            "On most models: \(TVSettingsPath.airPlay) → AirPlay: On.",
            "Turning it off and on with the remote isn't enough. Point the remote at the TV and hold the power button until the TV turns off and the Samsung logo appears, then let go. Wait about a minute after the TV is back, then tap Scan Again.",
            "On most models, the TV shows its IP address under \(TVSettingsPath.ipAddress). Then tap Add TV by IP Address.",
        ])
    }

    @Test func stateCardCopyIsExact() {
        #expect(StateCard.message(for: .noWiFi) == "Connect to Wi-Fi to control your TV.")
        #expect(StateCard.message(for: .localNetworkDenied)
            == "Simple TV Remote for Samsung needs Local Network access to find your TV.")
        #expect(StateCard.message(for: .searching) == "Looking for TVs…")
        #expect(StateCard.message(for: .noTVs)
            == "No TVs found. Turn your TV on and make sure your iPhone and TV are on the same Wi-Fi network.")
        #expect(StateCard.message(for: .chooseTV) == "Choose your TV")
        #expect(StateCard.message(for: .pairing) == "Look at your TV and choose Allow.")
        #expect(StateCard.message(for: .pairingDenied)
            == "Your TV blocked this iPhone. On the TV, open \(TVSettingsPath.deviceList), allow TV Remote, then tap Try Again.")
        #expect(AddTVSheet.footerNote
            == "Turn the TV on first. On most models, it shows its IP address under \(TVSettingsPath.ipAddress).")
        #expect(StateCard.message(for: .identityChanged)
            == "This TV's security identity changed (this can happen after a software update). "
            + "Pair again to continue.")
        #expect(RenameSheet.note
            == "This name is only on your devices. Leave it empty to use the TV's own name. To change the name "
            + "everyone sees, change Device Name in the TV's own settings (where it is depends on the model).")
        #expect(AddTVSheet.invalidAddressMessage == "Enter a local IP address like 192.168.0.20.")
    }

    @Test func appVersionText() {
        #expect(AppVersion.text(short: "1.0.1", build: "3") == "Version 1.0.1 (3)")
        #expect(AppVersion.text(short: nil, build: "3") == nil)
        #expect(AppVersion.text(short: "1.0.1", build: nil) == nil)
    }

    @Test func appVersionAccessibilityText() {
        #expect(AppVersion.accessibilityText(short: "1.0.1", build: "3") == "Version 1.0.1, build 3")
        #expect(AppVersion.accessibilityText(short: nil, build: "3") == nil)
        #expect(AppVersion.accessibilityText(short: "1.0.1", build: nil) == nil)
    }

    @Test func renamePlaceholderFallsBackForAMissingOrEmptyName() {
        #expect(RenameSheet.placeholder(reportedName: "Living Room") == "Living Room")
        #expect(RenameSheet.placeholder(reportedName: nil) == "TV name")
        #expect(RenameSheet.placeholder(reportedName: "") == "TV name")
    }

    @Test func renameLimitKeepsFirst40Characters() {
        let long = String(repeating: "a", count: 40) + "bcd"
        #expect(RenameSheet.limited(long) == String(repeating: "a", count: 40))
        #expect(RenameSheet.limited("Den") == "Den")
    }

    @Test func demoKeyLogRecordsLastKey() async {
        let log = DemoKeyLog()
        let model = AppModel(env: DemoEnvironment.make(.remote, keyLog: log))
        model.onAppear()
        for _ in 0..<10_000 where !model.isConnected { await Task.yield() }
        model.press(.digit5)
        for _ in 0..<10_000 where log.lastKey == nil { await Task.yield() }
        #expect(log.lastKey == "KEY_5")
        #expect(log.count == 1)
    }

    @Test func demoScenarioParsingIsExplicit() {
        #expect(DemoEnvironment.scenario(for: ["-demo"]) == .remote)
        #expect(DemoEnvironment.scenario(for: ["-demo", "-demo-empty"]) == .empty)
        #expect(DemoEnvironment.scenario(for: ["-demo", "-demo-choose"]) == .chooseTV)
        #expect(DemoEnvironment.scenario(for: ["-demo", "-demo-pairing"]) == .pairing)
        #expect(DemoEnvironment.scenario(for: ["-demo", "-demo-keyboard"]) == .keyboard)
    }

    @Test func textRequestDuringAnotherSheetIsQueued() {
        let rename = RootView.Sheet.rename(TVID(rawValue: "x"))
        // Free screen: present at once.
        #expect(RootView.sheetUpdate(keyboardRequested: true, current: nil, queued: false) == (.text, false))
        // Another sheet open: keep it, queue the text sheet.
        let busy = RootView.sheetUpdate(keyboardRequested: true, current: rename, queued: false)
        #expect(busy.sheet == rename && busy.queued)
        // Once it closes, the text sheet appears.
        #expect(RootView.queuedTextAfterSheetChange(keyboardRequested: true, current: nil, queued: true)
            == (.text, false))
        // The TV gave up meanwhile: nothing is shown and the queue is cleared.
        let gone = RootView.sheetUpdate(keyboardRequested: false, current: rename, queued: true)
        #expect(gone.sheet == rename && !gone.queued)
        #expect(RootView.queuedTextAfterSheetChange(keyboardRequested: false, current: nil, queued: false).sheet == nil)
    }

    @Test func scanFeedbackText() {
        #expect(ScanFeedback.scanning.text == "Looking for TVs…")
        #expect(ScanFeedback.found(newTVs: 0).text == "No new TVs found")
        #expect(ScanFeedback.found(newTVs: 1).text == "Found 1 new TV")
        #expect(ScanFeedback.found(newTVs: 3).text == "Found 3 new TVs")
    }
}
