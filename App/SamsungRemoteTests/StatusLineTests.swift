import SwiftUI
import Testing
import UIKit
@testable import SamsungRemote

@MainActor
@Suite struct StatusLineTests {
    private static let catalog: [StatusLine] = [
        .turningOn, .turningOff, .reconnecting, .connecting(to: nil), .connected(to: nil), .tvOff, .unreachable,
        .notTurnedOn, .wakeAddressUnknown, .notOnWiFi, .approvalTimedOut, .chooseTVFirst, .chooseAllow,
        .blocked, .identityChanged, .offPressPower,
    ]

    @Test func titlesAreShortAndExplanationsLiveInDetail() {
        for line in Self.catalog {
            #expect(line.title.count <= 30, "\(line.title)")
            if let detail = line.detail { #expect(detail.count > line.title.count, "\(line.title)") }
        }
        #expect(StatusLine.notTurnedOn.detail?.contains("Power On with Mobile") == true)
        #expect(StatusLine.connecting(to: "Den") == StatusLine("Connecting to Den…", tone: .progress))
    }

    @Test func pathsAreExact() {
        #expect(TVSettingsPath.deviceList == "Settings → All Settings → Connection → External Device Manager → Device Connect Manager → Device List")
        #expect(TVSettingsPath.deviceListOlder == "Settings → General → External Device Manager → Device Connect Manager → Device List")
        #expect(TVSettingsPath.powerOnWithMobile
            == "Settings → All Settings → Connection → Network → Expert Settings → Power On with Mobile")
        #expect(TVSettingsPath.powerOnWithMobileOlder == "Settings → General → Network → Expert Settings → Power On with Mobile")
        #expect(TVSettingsPath.airPlay == "Settings → All Settings → Connection → Apple AirPlay Settings")
        #expect(TVSettingsPath.ipAddress
            == "Settings → All Settings → Connection → Network → Network Status → IP Settings")
        #expect(StatusLine.blocked.detail
            == "On the TV, open \(TVSettingsPath.deviceList) and allow TV Remote. On older TVs: \(TVSettingsPath.deviceListOlder).")
        #expect(StatusLine.powerOnWithMobilePath
            == "\(TVSettingsPath.powerOnWithMobile) (on older TVs: \(TVSettingsPath.powerOnWithMobileOlder))")
        #expect(StatusLine.approvalTimedOut.detail
            == "The TV didn't confirm the connection in time. Tap Try Again, then choose Allow when the TV asks.")
    }

    @Test func tryAgainActions() {
        #expect(StatusLine.approvalTimedOut.action == .tryAgain)
        #expect(StatusLine.unreachable.action == .tryAgain)
        #expect(StatusLine.tvOff.action == nil)
        #expect(StatusLine.offPressPower.action == .tryAgain)
    }

    @Test func offPressPowerCopy() {
        #expect(StatusLine.offPressPower.title == "Press Power to turn the TV on")
        // A TV that is on at a new address also looks off; Scan Again finds it there.
        #expect(StatusLine.offPressPower.detail == "The TV isn't answering, so it's probably off. If it's on, make sure "
            + "it's on the same Wi-Fi network as this iPhone, then tap Scan Again in the TV menu.")
        #expect(StatusLine.offPressPower.tone == .info)
    }

    @Test func onlyTappableStatusesLookTappable() {
        // ⓘ means "tap for more"; a decorative "i" on a status without a detail invites a tap that does
        // nothing (the owner tried to tap "The TV is off").
        for line in Self.catalog {
            #expect(!(line.symbol ?? "").contains("info"), "\(line.title)")
        }
        #expect(StatusLine.tvOff.symbol == "power")
        #expect(StatusLine.offPressPower.symbol == "power")
    }

    /// The point of the fixed-height line: the remote below must not move, whatever is (or isn't) shown.
    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func everyStatusTakesTheSameHeight(size: DynamicTypeSize) {
        let model = AppModel(env: DemoEnvironment.make())
        func height(_ line: StatusLine?) -> CGFloat {
            let host = UIHostingController(rootView: StatusView(line).environment(model).environment(\.dynamicTypeSize, size))
            return host.sizeThatFits(in: CGSize(width: 354, height: CGFloat.infinity)).height
        }
        let empty = height(nil)
        #expect(empty > 0)
        for line in Self.catalog + [.connecting(to: "A Very Long Living Room Television Name")] {
            #expect(abs(height(line) - empty) < 0.5, "\(line.title) at \(size)")
        }
    }
}
