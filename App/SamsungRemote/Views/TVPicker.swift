import SamsungTVKit
import SwiftUI

extension TVStatus {
    var displayName: String {
        switch self {
        case .on: "On"
        case .asleep: "Asleep"
        case .off: "Off"
        case .unreachable: "Unreachable"
        case .pairing: "Pairing"
        }
    }

    var dotColor: Color {
        switch self {
        case .on: .green
        case .asleep: .orange
        case .off, .unreachable: .gray
        case .pairing: .blue
        }
    }
}

extension ScanFeedback {
    /// The line the TV card shows instead of the TV's details.
    var text: String {
        switch self {
        case .scanning: "Looking for TVs…"
        case .found(0): "No new TVs found"
        case .found(1): "Found 1 new TV"
        case .found(let count): "Found \(count) new TVs"
        }
    }
}

/// The card at the top: the selected TV with its status. Tapping it opens the TV menu (`TVMenuPanel`)
/// over the screen.
struct TVPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openTVMenu) private var openTVMenu
    @Environment(\.isTVMenuOpen) private var isTVMenuOpen
    @AccessibilityFocusState private var focused: Bool

    private var selected: TVListItem? { model.tvs.first { $0.id == model.selectedID } }

    var body: some View {
        Button { openTVMenu?() } label: {
            TVCardLabel(selected: selected, feedback: model.scanFeedback)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.remoteCard))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(RemoteKeyStyle())
        .tint(.primary)
        .anchorPreference(key: TVCardBoundsKey.self, value: .bounds) { $0 }
        .accessibilityLabel("TV picker")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows your TVs")
        .accessibilityFocused($focused)
        .onChange(of: isTVMenuOpen) { _, open in
            if !open { focused = true } // VoiceOver returns to the card the menu came from
        }
        .sensoryFeedback(trigger: model.scanFeedback) { _, new in
            switch new {
            case .scanning: .impact(weight: .light)
            case .found: .success
            case nil: nil
            }
        }
        .onChange(of: model.scanFeedback) { _, new in
            if let new, new != .scanning {
                AccessibilityNotification.Announcement(new.text).post()
            }
        }
    }

    private var accessibilityValue: String {
        let tv = selected.map { "\($0.title), \($0.status.displayName)" } ?? "No TV selected"
        if let feedback = model.scanFeedback { return "\(tv). \(feedback.text)" }
        return tv
    }
}

#Preview {
    @Previewable @State var model = AppModel(env: DemoEnvironment.make())
    TVPicker()
        .padding()
        .background(Color.remoteBackground)
        .environment(model)
        .task { model.onAppear() }
}
