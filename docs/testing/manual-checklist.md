# Manual test checklist (real devices)

Checks that need a real iPhone and real Samsung TVs. Contributors: run the sections your change touches, on
whatever TVs you have, and list the TV model years in your pull request. Run each step once per TV unless it
says otherwise. The steps assume a build with multicast on (the default).

**Record results privately.** Do not commit IP addresses, MAC addresses, serial numbers, device IDs, network
names or TV names. In public notes, refer to TVs only by model year and series.

## Setup

- [ ] The app installed on the iPhone (the build log's `CODE_SIGN_ENTITLEMENTS` line shows which entitlements
      file was used).
- [ ] iPhone and TVs on the same Wi-Fi network (not a guest network).
- [ ] On each TV, "Power On with Mobile" / network standby is enabled (note the menu path per model).
- [ ] Start clean: delete the app, and remove "TV Remote" (and any older "Free Remote" entry) from each TV's Device Connect Manager.

## Discovery

- [ ] First launch shows the Local Network permission prompt; after allowing it, all TVs that are on appear.
- [ ] **Slow answer to the prompt:** on first launch, wait 10 s before answering the Local Network prompt, then
      Allow → TVs appear without a relaunch.
- [ ] A TV that does not answer SSDP (find via `tvprobe`) is still found (Bonjour or the known-TV probe).
- [ ] A TV with AirPlay turned off that answers SSDP appears on launch, without Scan Again.
- [ ] A TV in standby that still answers on the network is found and shown as Asleep.
- [ ] "Scan again" refreshes the list; TVs that are on are listed first.
- [ ] Scan Again (TV menu) shows a spinner and "Looking for TVs…" on the TV card with a light tap, then
  "Found N new TVs" or "No new TVs found" with a success tap; the card returns to normal after about 3 s.
  Automatic scans (launch, returning to the app) show none of this.
- [ ] "Add TV by IP…" adds a TV by its address; a public or invalid address is rejected with a message.
- [ ] With AirPlay turned off on a TV that is on, Scan Again still finds it (subnet sweep).
- [ ] A scan on the home Wi-Fi finishes in about the same time as before.
- [ ] Relaunching the app shows remembered TVs immediately, including ones that are off (Off/Asleep).

## Pairing

- [ ] Selecting a new TV shows "Look at your TV and choose Allow"; choosing Allow pairs and enables the remote.
- [ ] After relaunching the app, the TV connects without a new prompt.
- [ ] Waiting without answering the prompt ends with a timed-out message and a way to retry.
- [ ] **Pairing denied + recovery:** choose Deny on the TV; the app explains how to re-enable it in the TV's
      Device Connect Manager. Re-enable (or remove the entry) on the TV, retry in the app, choose Allow: pairs.

## Every button

On the TV's home screen and inside a streaming app, each press does what the physical remote does and gives
a haptic tap:

- [ ] Power (see Power below)
- [ ] Source; long-press Source → HDMI 1, 2, 3, 4 (note which work per model)
- [ ] Mute
- [ ] D-pad up, down, left, right, OK
- [ ] Volume up/down, channel up/down
- [ ] Back, Home, Play/Pause (pauses and resumes playback inside an app)
- [ ] Play/Pause toggles playback inside apps (e.g. a streaming app); note the TV's model year.
- [ ] "123" sheet: 0–9 change channel on live TV
- [ ] With the TV disconnected, buttons are disabled and show why (not paired / asleep / unreachable).

## Hold-repeat

- [ ] A quick tap on an arrow or volume up/down moves exactly once.
- [ ] Holding an arrow or volume up/down repeats after a short pause, at about 10 steps per second, with a
      light haptic tick for each repeat.
- [ ] Holding volume up/down repeats steadily and stops immediately on release.
- [ ] Holding channel up/down and each arrow repeats and stops on release.
- [ ] Releasing after the app goes to the background (swipe home while holding) does not leave a key repeating.

## Text entry

- [ ] Focusing a search field on the TV (e.g. in YouTube) opens the keyboard sheet in the app.
- [ ] Typed text appears on the TV; Done/Enter submits; the sheet closes when the TV keyboard closes.

## Power

- [ ] **Power off:** with the TV on, Power shows "Turning off…" and the TV turns off; it never turns a TV on.
- [ ] After turning off with the app, confirm the TV shows Asleep/Off in the picker (not On) — some TVs keep
      the WebSocket open in standby — and the status line says the TV is off (never "Connecting…").
- [ ] **A known TV that is off:** it shows Off in the TV menu; choosing it shows "Press Power to turn the TV on"
      with no "Connecting…" first; Power turns it on and it connects. A TV whose wake address isn't known
      still says "Can't reach the TV" (Unreachable in the menu).
- [ ] **Power on from standby:** within a few minutes of turning it off, Power turns the TV on.
- [ ] **Power on after a short while:** turn the TV off with its own remote, wait until the picker shows it
      Asleep, then press Power within 5 minutes: the TV turns on (Wake-on-LAN) and the app reconnects.
- [ ] **Power on from deep sleep:** after 30+ minutes off (no longer answering on the network), press Power:
      record whether it turns on. If not, the message must suggest the TV's own remote (never a spinner without
      an explanation).
- [ ] With "Power On with Mobile" disabled, power-on fails with an explanation of that setting.

## Network changes

- [ ] **IP change:** renew the TV's DHCP lease on the router (or reboot router/TV) so the TV gets a new address;
      the app finds it again as the same TV (same name, still paired, no Allow prompt).
- [ ] **Airplane mode:** turn on airplane mode — the app shows a no Wi-Fi state; turn it off — the app
      reconnects without a relaunch.
- [ ] Turning Wi-Fi off and on from Control Center updates the app without tapping Try Again.
- [ ] **Address change with the app open:** with the app in front, give the TV a new address (renew its DHCP
      lease on the router): the app finds it again within about 10 seconds (automatically at most once a day
      per TV); Scan Again finds it at once.
- [ ] Background the app for a minute, return: it reconnects promptly.
- [ ] **Local Network denied:** in Settings > Privacy & Security > Local Network, turn Simple TV Remote for Samsung off; the
      app shows the permission state with a working link to Settings. Turn it back on: discovery works again.

## TV menu and details

- [ ] Tapping the TV card opens the menu panel in place (same card style), dimming the rest; tapping outside,
      the header, or a VoiceOver escape (two-finger scrub) closes it.
- [ ] Choosing a TV in the menu selects it and closes the menu; the selected TV has a checkmark.
- [ ] Two TVs with the same name (e.g. two of the same model) show their addresses after the model; renaming
      one removes them. Older TVs' names show without a leading "[TV]".
- [ ] Switching TVs shows a blue "Connecting to <TV>…" line with a spinner, then a green "Connected to <TV>"
      for about 2 s; problems show in orange with a warning icon, in light and dark mode.
- [ ] Scan Again keeps the menu open; newly found TVs appear in the list.
- [ ] Can't Find Your TV? opens from the No TVs card and the TV menu; Scan Again and Add TV by IP Address
      work from it.
- [ ] **TV Details** with the TV on: shows "Checking the TV…" briefly, then model, year, IP, MAC, connection,
      resolution, features, language and country; long-press a value → Copy; Copy All copies everything.
- [ ] **TV Details** with the TV unplugged: shows the last known details and the "didn't answer" note.
- [ ] "Feedback & Bug Reports" opens the project's GitHub issues page in the default browser.

## Recovering from a slow or failed power-on

- [ ] Press Power on a TV that takes long to boot (or turn it on with its own remote while the app shows it as
      unreachable): within a few seconds of the TV coming on, the app connects by itself, without Scan Again,
      and "The TV hasn't turned on yet" goes away.
- [ ] Turn the TV off with its own remote while the app is open: within a few seconds the app shows it as
      off ("The TV is off" or "Press Power to turn the TV on", never a long "Connecting…"), and only Power stays
      enabled; turn it back on with its own remote: the app connects within seconds.
- [ ] Turn the TV off with the app's Power button: "Turning off…", then "The TV is off", with no
      "Connecting…" in between.
- [ ] The status line is always one short line in the same place: the D-pad never moves as messages
      come and go (also at the largest text size, where it may use two lines). Lines with more to say
      show ⓘ; tapping opens the explanation.
- [ ] Pressing Power shows "Turning on…" / "Turning off…" at once, with no older message flashing first.
- [ ] With "Press Power to turn the TV on" showing and the TV back on, tapping ⓘ and then Try Again in the status details
      reconnects.
- [ ] Turning the TV off with the app turns the card's dot orange (Asleep) right away.

## Control Center control

- [ ] In Control Center → "+" → Add a Control, "TV Remote" is listed; tapping the added control opens the app
      on the remote for the last-used TV (also from the Lock Screen, and on the Action button where available).
- [ ] With the app already open in the background, the control brings it forward and it reconnects.

## Names and sync

- [ ] **Rename:** "Rename…" sets a label shown in the picker; the sheet explains renaming in the TV's settings.
- [ ] **Rename sync across devices:** on a second device signed in to the same Apple Account, the new label
      appears (allow time for iCloud). Clearing it on one device clears it on the other.

## Forget

- [ ] "Forget…" asks for confirmation, then removes the TV, its label and its pairing.
- [ ] Scanning again finds the TV as new; selecting it asks for Allow again.

## Accessibility and appearance

- [ ] VoiceOver reads a label for every control; the status line is announced.
- [ ] Largest Dynamic Type size: text stays readable and nothing important is clipped.
- [ ] Light and dark mode both look correct; the app icon shows correctly in light, dark and tinted home
      screen styles.
