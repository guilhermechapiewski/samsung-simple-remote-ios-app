import Foundation
import SamsungTVKit

struct TVListItem: Identifiable, Equatable {
    let id: TVID
    /// The user's label, else the name the TV reports.
    var title: String
    /// The model name, followed by the TV's address when another TV has the same title.
    var subtitle: String
    var status: TVStatus
}

/// What the TV Details screen shows about one TV.
struct TVDetailsSnapshot: Equatable {
    let id: TVID
    let title: String
    let status: TVStatus
    /// The app's own record of the TV.
    let known: KnownTV
    /// The TV's latest answer: just now when `isLive`, else from the last scan; nil when the TV has
    /// not answered since the app started.
    let info: TVDeviceInfo?
    let isLive: Bool
    /// This iPhone holds a pairing token for the TV.
    let paired: Bool
}

enum TVStatus: Equatable {
    /// `off`: not answering, but the app can wake it (its MAC is known). Every TV tested leaves the network when
    /// off, so that is the likely reason. `unreachable`: not answering, and Power couldn't turn it on.
    case on, asleep, off, unreachable, pairing

    /// The TV answered the app recently.
    var answers: Bool { self != .off && self != .unreachable }
}

enum ScreenState: Equatable {
    case noWiFi, localNetworkDenied, searching, noTVs, chooseTV, ready, pairing, pairingDenied, identityChanged
}

/// Feedback for a scan the user started with Scan Again. Automatic scans show none.
enum ScanFeedback: Equatable {
    case scanning
    /// The scan finished; `newTVs` is how many TVs it found that the app did not know before.
    case found(newTVs: Int)
}

/// What a running power toggle is doing, as decided by the power planner.
enum PowerDirection: Equatable {
    case turningOn, turningOff
}
