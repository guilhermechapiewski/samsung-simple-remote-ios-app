# Protocol notes

How SamsungTVKit talks to Samsung Tizen TVs, as implemented. Items marked "unverified" have not yet been
confirmed on real hardware; see the checklist at the end.

## Endpoints

- `GET http://<host>:8001/api/v2/` — device info (JSON). Used for discovery, identity and power state.
  Only ever contacted for private (RFC 1918) or link-local IPv4 hosts. Responses are size-capped.
  TV Details also shows its informational fields: `resolution`, `Language`, `countryCode`, `ssid` (the
  access point's BSSID on the TVs seen so far; shown only when it is a MAC), the `*Support` feature flags,
  `developerMode`, `firmwareVersion` (most TVs say "Unknown"; hidden then) and the top-level `version`.
  The model year comes from the `model` code's two-digit prefix ("22_…" is 2022).
  2019 models (Q50) start `name` with "[TV] " (dropped by the app), and two TVs of the same model and size
  report the same name ("Samsung Q50 Series (32)"), so the TV list adds the address after the model when
  two TVs share a title.
  While the app is in front, the app GETs this endpoint for the selected TV every 2 s, connected or not
  (not while pairing). While connected: `standby` means the TV was turned off with its own remote (in network
  standby the WebSocket can stay open), so it is shown as off with only Power usable; two missed answers in
  a row mean it lost power, so the connection is replaced (the transport's 15 s ping would take 15-30 s to
  notice). While not connected, when the TV answers `PowerState: on`, a
  failed session reconnects, and a retry stuck waiting out its backoff (still connecting after 4 checks)
  starts over at once; so a TV that boots late or is turned on with its own remote connects within seconds.
  A `standby` answer only marks the TV asleep; no answer while retrying shows "Can't reach the TV"
  instead of "Connecting…". The session's own retries (backoff 0.5 s doubling to 30 s, 5 failures, 5 s
  connect timeout) would otherwise take about 40 s to give up.
- Stalls: a 2024 model, while on, sometimes accepted the TCP connection on 8001 and then sent nothing for up
  to about 12 s (several requests in a row), then answered in milliseconds again; HTTPS on 8002 answered
  throughout. A TV that is off the network times out the same way (`URLError.timedOut`), but never completes a
  TCP connection. So when a request times out, the fetcher tries a TCP connect to 8001 (at most 1 s): if it
  connects, the TV is there and is asked again, until a stall budget runs out (12 s for discovery, the watch
  and TV Details; 5 s for the power button's check); if not, it fails at once, as before. Refusals and
  non-TV answers are never retried.
- `wss://<host>:8002/api/v2/channels/samsung.remote.control?name=<base64 name>[&token=<token>]` — the
  remote-control channel. The pairing name sent is the constant `TV Remote` (base64 encoded).
  Port 8001 is never used for control.
- SSDP (`M-SEARCH` for `urn:samsung.com:device:RemoteControlReceiver:1` and
  `urn:dial-multiscreen-org:service:dial:1`) and Bonjour (Samsung TXT records) provide candidate hosts;
  every candidate is confirmed with the device-info request before it is reported.
- AirPlay advertising can stop while the TV is on: a 2022 model kept answering on port 8001 (`PowerState`
  `on`) but sent no `_airplay._tcp` or `_raop._tcp` records, with AirPlay on in its settings. Standby and back
  did not help; a full restart (hold the remote's power button until the Samsung logo shows) restored it about
  a minute after boot. That model does not answer the `RemoteControlReceiver` search (it does answer the
  `dial` one), so without the multicast entitlement it is found by the subnet sweep or by IP address, and a
  saved TV is still found because known addresses are re-probed directly.
- Subnet sweep: a TCP connect to port 8001 on every address of the Wi-Fi subnet (skipped above 1,024
  addresses (prefixes shorter than /22) and for non-contiguous netmasks), 64 at a time with a 500 ms timeout
  each, nearest addresses first. Every address that accepts is a candidate and is confirmed with `/api/v2/`
  like the others. It needs neither multicast nor Bonjour, so it runs with and without the multicast
  entitlement and finds TVs that advertise nothing. Because it is the costly part of a scan, a scan includes
  it only when the user started it (Scan Again, Try Again) or when no TV is known yet; otherwise Bonjour (and
  SSDP) plus probing the known addresses look for the TVs. A known TV missing from a scan is no reason to
  sweep: usually it is simply off. The one automatic exception: when the selected TV has not answered 5
  presence checks in a row (about 10 s) while the app is in front, one scan with the sweep runs in case the TV
  moved to another address. It is limited to once per foreground period and once per 24 hours per TV, and is
  skipped for a TV the app just turned off. The once-per-foreground limit re-arms when the TV answers, another
  TV is selected, Wi-Fi returns or the app returns from the background; the 24-hour limit does not.

## Device info

Fields used: device id (stable TV identity), name, model name and code, Wi-Fi MAC, network type,
`PowerState` (absent or `on` means on, empty or `standby` means standby, anything else is kept as unknown) and
token-auth support.

## Messages

Events from the TV (JSON with an `event` field): `ms.channel.connect` (optionally carrying a `token`),
`ms.channel.unauthorized`, `ms.channel.timeOut`, `ms.remote.imeStart` (on-screen keyboard shown),
`ms.remote.imeEnd` (hidden). Anything else is reported as an unknown event name.

Commands to the TV are `ms.remote.control` messages with `TypeOfRemote`:
- `SendRemoteKey`: `Cmd` is `Click`, `Press` or `Release`; `DataOfCmd` is the key code (e.g. `KEY_VOLUP`).
- `SendInputString`: `Cmd` is the base64 text, `DataOfCmd` is `base64`.
- `SendInputEnd`: closes the text entry.

## Pairing

1. Connect without a token. The TV shows an "Allow" prompt; the session waits (default 30 s).
2. On `ms.channel.connect` the TV may include a token; it is stored with the pinned certificate.
3. Later connections send the stored token and no prompt appears. `unauthorized` or `timeOut` while
   pairing ends the session as denied or timed out.

## Certificate pinning

TVs use self-signed certificates, so system trust cannot be used and trust is never disabled.
On first connection the SHA-256 of the certificate's SubjectPublicKeyInfo is recorded (trust on first
use) and every later connection must present the same key; a mismatch fails as "identity changed".

## Connection handling

After an established connection drops, the session reconnects with backoff, giving up after a fixed number
of consecutive failures.

## Power logic

State is read from the device-info `PowerState`:
- on: send `KEY_POWER` (turn off), then confirm the state changed.
- standby (or unknown while the TV answers): send `KEY_POWER` over the channel to wake it.
- unreachable: send a Wake-on-LAN magic packet (UDP port 9) from the Wi-Fi interface: unicast to the TV's
  last known address and, with the multicast entitlement, also to the subnet and limited broadcast
  addresses. iOS refuses broadcasts without that entitlement (EHOSTUNREACH); the unicast packet reaches the
  TV only while its hardware address is still in the iPhone's or router's ARP cache.

Key repeat for held keys is `RepeatStrategy`: `.pressRelease` or `.clickEvery(interval, initialDelay:)`.
On a 2022 model both work: after Press the TV repeats by itself at about 10 steps per second until Release,
and repeated Click steps once per click. The app uses Click, because a lost Release (dropped connection,
app suspended) could run the volume to an end: one click at once, then after a 400 ms initial delay one
every 100 ms until the key is let go, so a short tap stays a single step. Not verified on other model years.

Playback keys on the same model: `KEY_PAUSE` only pauses, `KEY_PLAY` only plays, and `KEY_PLAY_BACK` toggles
(tried in YouTube and ESPN), so `KEY_PLAY_BACK` (`RemoteKey.playPause`) suits a single play/pause button.
Not verified on other model years.

## To verify on real TVs

Use `tvprobe` (`swift build --product tvprobe`), per model generation:

- [x] (a) `tvprobe hold <host> KEY_VOLUP 2`: does Press/Release or repeated Click repeat correctly? Set
  `RepeatStrategy.default` accordingly. A 2022 model: both repeat (Press/Release at about 10 steps per
  second); the default is Click with a 400 ms initial delay and a 100 ms interval (see the key repeat
  paragraph above).
- [x] (b) Which of `KEY_PLAY`, `KEY_PAUSE`, `KEY_PLAY_BACK` toggles playback inside an app? A 2022 model:
  `KEY_PLAY_BACK` toggles (YouTube, ESPN); `KEY_PAUSE` only pauses and `KEY_PLAY` only plays.
- [ ] (b2) Confirm `KEY_PLAY_BACK` toggles playback inside apps on other model years.
- [ ] (c) `tvprobe listen <host>` while focusing a search box: record the exact IME event names, then
  check `tvprobe text <host> <string>` fills the box.
- [ ] (d) Put the TV in standby with its remote: record the `PowerState` value from `tvprobe info` per model,
  and whether `KEY_POWER` over the channel wakes it.
- [ ] (e) `KEY_HDMI1` to `KEY_HDMI4`: which switch sources, per model.
- [ ] (f) After about 30 minutes in standby, is the TV still reachable over the network? Does
  `tvprobe wake <mac>` wake it afterwards?
