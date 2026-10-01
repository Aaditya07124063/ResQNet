# Physical mesh test plan

Automated tests prove the protocol logic (dedup, TTL, hop limit, store-and-forward, gateway upload) against simulated devices. They do not prove that phones find each other, connect, or deliver over real radios. This plan does. **No results are recorded yet.**

## Setup

- **Build:** `flutter build apk --debug --dart-define=API_ENV=production` (or `--release`). Install the same build on every phone.
- **Devices:** at least 5 Android phones. Record each one before testing:

| Label | Model | Android version | ResQNet build | Battery % at start | Battery saver on? |
|---|---|---|---|---|---|
| A | | | | | |
| B | | | | | |
| C | | | | | |
| D | | | | | |
| E | | | | | |

- **Permissions:** allow Nearby devices, Location, and Notifications on every phone.
- **Offline phones:** turn off mobile data and Wi-Fi Internet on A–D; airplane mode, then turn Bluetooth and Wi-Fi back on. Only E has Internet (Wi-Fi or data), and E is signed in to ResQNet.
- **Record for every run:** environment (open field / street / building / forest / valley), distances between phones (measured, not estimated), weather, screen on/off, app foreground/background.

## Tests

| Test | Topology | Steps |
|---|---|---|
| A | A ↔ B direct | A presses SOS, lets the countdown finish; B in range |
| B | A → B → C | A and C out of each other's range, B between them |
| C | A → B → C → D | chain; each phone in range only of its neighbours |
| D | A → B → C → D → E | E is the Internet gateway |
| E | store-and-forward | A sends with only B in range; carry B out of A's range and into C's range afterwards (no simultaneous A–C path). Repeat up to D and E |
| F | duplicate paths | A in range of B and C; both in range of D |
| G | restart | after B receives A's SOS, force-stop and reopen ResQNet on B, then bring C into range |
| H | expiry | (needs a short-TTL debug build) event must not reach phones after it expires |
| I | cancellation | A presses "I'm safe" after the SOS reached B/C; check the cancellation reaches them and shows as verified |
| J | signed official alert | build with `RESQNET_ALERT_PUBLIC_KEY`; backend with `OFFICIAL_ALERT_SIGNING_KEY`. E (online) fetches an official test alert; A–D offline receive it over the mesh and must label it OFFICIAL. Repeat with a debug build that alters the text: it must show as an unverified community report |

## What to measure

For each device and test:

- received (yes/no) and time from A's send to receipt (s)
- hop count shown for the event
- whether the event is still present after an app restart
- number of times the same event appeared (duplicate rate; expected 1)
- notification shown (yes/no); tapping it opens the right screen
- for E: time from receipt to backend receipt (check `GET /api/v1/sos` as A, or the server log), and whether A's trusted contact received the push
- events lost (sent but never received)
- battery change over the test

## Results

Fill in after running; do not pre-fill.

| Date | Test | Devices | Distance(s) | Environment | Delivered? | Time | Hops | Duplicates | Gateway sync | Notes |
|---|---|---|---|---|---|---|---|---|---|---|

## Known limitations to confirm or disprove

- iOS mesh (MultipeerConnectivity) is expected to work only in the foreground; not covered by this Android plan.
- Background discovery on Android depends on the manufacturer's power management.
- The gateway phone must be signed in for the upload; otherwise it only keeps relaying.
