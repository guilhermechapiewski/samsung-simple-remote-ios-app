# Simple TV Remote for Samsung

A free, open-source iPhone app that finds Samsung Smart TVs (Tizen) on your Wi-Fi network and controls them
like the physical remote. No ads, no accounts, no tracking: the app only talks to TVs on your local network.

The app is published on the App Store, and this source is open so that anyone can see how it
works, reuse the code under the [MIT license](LICENSE), report problems, and contribute improvements.

<img src="docs/images/remote.png" alt="The remote screen" width="300">

## Features

- Automatic discovery of Samsung TVs on the local network, and "Add TV by IP address"
- Also finds TVs that are not advertising AirPlay, by checking the Wi-Fi subnet directly (on the first scan and
  when you tap Scan Again)
- In-app help when a TV can't be found
- Power on/off (state-aware; wakes TVs from network standby), volume, mute, channel up/down
- Circular D-pad with OK, Back, Home, Play/Pause
- Source, with a long press for HDMI 1–4
- Number pad, and text entry when the TV shows an on-screen keyboard
- Hold-to-repeat for volume, channel and arrows
- Remembers TVs between launches, including while they are asleep
- Your own names for TVs, synced across your devices with iCloud
- TV Details: model, model year, IP and MAC addresses, connection, resolution, supported features and more;
  every value can be copied
- Send feedback or report a bug from the TV menu (opens this project's GitHub issues)
- A TV menu in the card's own style: switch TVs, TV Details, Rename, Forget, Add TV, Scan Again
- A Control Center control (also for the Lock Screen and the Action button) that opens the remote
- One-time pairing per TV (choose "Allow" on the TV); haptics, VoiceOver labels, Dynamic Type, dark mode

## Requirements

- Works with Samsung Smart TVs running Tizen, 2022 and newer. Many 2018–2021 models also work. Tested on 2019, 2022, 2024 and 2026 models.
- iPhone and TV on the same Wi-Fi/local network. Guest or isolated (client-isolation) networks are not
  supported.
- Choose "Allow" on the TV the first time the app connects.
- To turn the TV on from the app, enable the TV's "Power On with Mobile" (network standby) setting. A TV that
  has been off for a long time may need its own remote to turn on.
- If the TV isn't found, tap Scan Again or add it by its IP address. Keeping AirPlay on in the TV's settings (on
  by default) helps on some networks.
- Local Network permission granted on the iPhone (Settings > Privacy & Security > Local Network).
- iPhone with iOS 27 or later.

## Privacy

The app collects no data. There is no analytics, advertising, tracking or crash reporting, and no third-party
code. It only contacts private (RFC 1918) or link-local addresses on your network. Control traffic uses TLS
with the TV's certificate pinned on first use; trust checks are never disabled. Pairing tokens live in the
Keychain on the device; TV names you choose sync through your own iCloud. See the
[privacy policy](docs/privacy/index.md).

## Building

You need macOS with **Xcode 27.2 or later** and the iOS 27.0 simulator runtime.

1. Clone the repository.
2. Open `SamsungRemote.xcodeproj` and run the `SamsungRemote` scheme on a simulator. No signing setup is needed;
   use demo mode (launch argument `-demo`, fictional TVs) to try the app without a TV.

To run it on your own iPhone, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` (git-ignored)
and set your `DEVELOPMENT_TEAM` and a bundle identifier of your own. Do this instead of picking a team in
Xcode's Signing & Capabilities, which writes the team into the project file; the build stops if it finds one
there. The app uses iCloud key-value storage
for TV names, which needs a paid Apple Developer Program membership (free personal teams cannot sign it).

The app uses SSDP discovery and broadcast Wake-on-LAN, which need a multicast networking entitlement that Apple
grants per team. If your team doesn't have it, add `SAMSUNG_REMOTE_MULTICAST = NO` to your `Config/Local.xcconfig` to
build for a device (the simulator works either way); the "Check entitlements" build phase keeps the setting and the
signed entitlements in step. See [`docs/protocol-notes.md`](docs/protocol-notes.md) for how discovery and
power-on work with and without it.

### Tests

```sh
# SamsungTVKit (protocol, discovery, pairing, power logic)
swift test --package-path SamsungTVKit

# App unit and UI tests
xcodebuild test -project SamsungRemote.xcodeproj -scheme SamsungRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' -parallel-testing-enabled NO
```

### Other tools

- `scripts/screenshots.sh` captures screenshots of demo mode into `build/screenshots/` (git-ignored).
- `swift build --package-path SamsungTVKit --product tvprobe` builds a command-line probe for checking
  protocol behaviour on a real TV (see [`docs/protocol-notes.md`](docs/protocol-notes.md)).
- `swift scripts/render-icon.swift` regenerates the app icon.

## Project layout

| Path | Contents |
|---|---|
| `SamsungTVKit/` | Swift package: discovery, device info, pairing and the control channel, power, Wake-on-LAN; `tvprobe` CLI |
| `App/SamsungRemote/` | SwiftUI app: app model, views, stores (known TVs, iCloud labels, Keychain), demo mode, assets |
| `App/SamsungRemoteControls/` | WidgetKit extension with the Control Center control |
| `App/Shared/` | Code in both the app and the extension (the "Open TV Remote" App Intent) |
| `App/SamsungRemoteTests/`, `App/SamsungRemoteUITests/` | App unit tests and UI/screenshot tests |
| `Config/` | Shared build settings; your local signing settings |
| `docs/` | Protocol notes, the app's privacy policy, real-device test checklist, images |
| `scripts/` | Screenshot and icon scripts |

## Contributing and feedback

Bug reports, TV compatibility reports, ideas and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md). The maintainer reviews every pull request and decides what goes into
the App Store releases. To report a problem with a particular TV, use the "TV compatibility" issue template.

## License

[MIT](LICENSE).

## Trademarks

Not affiliated with or endorsed by Samsung. Samsung and Tizen are trademarks of Samsung Electronics Co., Ltd.
