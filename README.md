# Ratchet Remote

Ratchet Remote is a native SwiftUI menu-bar controller for an RME Fireface
UCX II and a NanoD Ratchet H1 running the custom
[`ratchet-rs`](https://github.com/coral/ratchet-rs) protocol.

It keeps the current RME state visible on the Ratchet, turns the hardware into
a haptic Main/Phones volume knob, and provides dedicated mute controls. The app
runs as a macOS accessory with no Dock icon; its status and software controls
are available from the **B** in the menu bar.

## Features

- Live Main Out, Phones, and Mic/Line 1 state from the UCX II
- Haptic volume control with separate Main and Phones tuning
- Reversible output and microphone mute behavior
- Directional LED volume arc and persistent microphone-mute indicator
- Partial display updates to avoid flicker during normal volume changes
- Automatic USB reconnect and Ratchet protocol transaction retries
- Activity-based display and LED dimming
- Optional launch at login using macOS Service Management
- Native SwiftUI menu-bar interface plus CLI diagnostics

## Requirements

- macOS 14 or newer
- Xcode 26 command-line tools with Swift 6.2
- RME's USB DriverKit driver and a connected Fireface UCX II
- A Ratchet H1 running compatible custom firmware with:
  - USB VID `303a`, PID `4004`
  - HID usage page `ff00`, usage `0001`
  - 60 ring LEDs, 8 key LEDs, 4 buttons, and a 240×240 display

SwiftPM resolves the only external package, SwiftProtobuf `1.38.1`, from the
checked-in `Package.resolved`. Protocol bindings are generated at build time
from `Sources/RatchetProtocol/ratchet.proto`.

## Build and run

Run directly through Swift Package Manager:

```sh
swift run RatchetRemote
```

The first build takes longer because SwiftPM also builds the protobuf tools.
For an optimized build:

```sh
swift build -c release
.build/release/RatchetRemote
```

Use **Quit** in the menu-bar window to shut down cleanly and disable the
Ratchet outputs.

## Install as a macOS app

The installer builds an optimized application bundle, gives its executable and
resources standard macOS permissions, applies a local ad-hoc signature, and
copies it to `/Applications/Ratchet Remote.app`:

```sh
./install.sh
```

If `/Applications` is not writable by your account, the script asks for an
administrator password through `sudo`. To install and open it in one command:

```sh
./install.sh --launch
```

Quit any already-running CLI or app instance before launching the installed
copy. You can then start it from Applications, Spotlight, or the command line:

```sh
open "/Applications/Ratchet Remote.app"
```

Once running from `/Applications`, open the menu-bar window and enable
**Launch at Login**. macOS may require approval under **System Settings →
General → Login Items**; the app shows an **Open Settings** button when that is
needed. The option is intentionally unavailable when running through
`swift run`, because macOS can only register the signed application bundle.

This is an ad-hoc signature intended for a locally built app. Distribution to
other Macs without Gatekeeper warnings will eventually require an Apple
Developer ID signature and notarization.

## Hardware controls

| Control | Action |
| --- | --- |
| Button 0 | Toggle Mic/Line 1 between `0.0 dB` preamp gain and its saved gain |
| Button 1 | Select Phones, then toggle Phones mute |
| Button 2 | Select Main, then toggle Main mute |
| Button 3 | Switch the knob between Main and Phones |
| Knob on Main | Adjust Main in `1.0 dB` steps, capped at `0.0 dB` |
| Knob on Phones | Adjust Phones in `0.5 dB` steps, capped at `-15.0 dB` |

Main uses 34 detents per turn with a stronger, snappier haptic profile. Phones
uses 26 detents per turn with a lighter precision profile. Movement inside the
current detent does not change volume.

Main Out follows the UCX II's live Control Room Main assignment (`0x3050`).
In the supplied TotalMix setup this is Analog 1/2 (Genelec). Phones controls
the Phones 7/8 destination (Headphones), matching `Phones1Chan=6` in the supplied
workspace. The documented protocol has no live Phones assignment binding, so
reassigning Phones in TotalMix requires updating that mapping here.
These controls change the destination's stereo master volume; they do not
change the input or playback sends that make up its submix.

Output mute is implemented by saving the current level and writing the RME
volume floor of `-65.0 dB`. Unmuting restores the saved level. If the app has no
saved value, it falls back to `-30.0 dB`, constrained by the output's cap.

Mic/Line 1 mute uses `0.0 dB` preamp gain as a practical mute for the attached
low-output microphone. The app reads the live gain at startup, saves it before
muting, and restores it when unmuted. If it first starts with the gain already
at zero and has no saved value, the fallback restore gain is `59.0 dB`, matching
the supplied SM7B setup.

Mic mute/unmute writes only the Mic/Line 1 preamp gain register (`0x0008`) and
updates the UI immediately, with background readback reconciliation. It preserves the
existing mic send to ADAT 1/2, all other input/playback sends, and the ADAT
return routing. It does not configure or repair those routes: keep the intended
mic-only-to-ADAT routing in TotalMix. Ordinary computer recording receives Mic 1
independently of monitor sends. Zero preamp gain is a practical attenuation for
this microphone, not digital silence.

The DriverKit write boundary rejects input-mute metadata, submix faders/pans,
matrix coefficients, and all settings outside gain/output volume and the DSP
read handshake. Received snapshots are never replayed as writes.

## Ratchet indicators

- The selected output's ring grows right-to-left from +120°, through north,
  toward -120°.
- Main uses a white arc; Phones uses a purple arc.
- Muting the selected output preserves its saved arc length and turns it red.
- Three red LEDs at the bottom of the ring indicate that Mic/Line 1 is muted.
- Buttons 0–2 are dark while live and red only while their channel is muted.
- Button 3 is off for Main and purple for Phones.
- The display shows the live numeric level in white with a yellow role label.
  A muted selected output displays the smaller red word `MUTED` and a red
  screen border extending 12 pixels inward (5% of the screen width).
- When RME disconnects, the display clears and shows `RME` above `DISCONNECTED`.

On interaction, the display and LEDs run at 80% brightness. After five seconds
without a button press or crossed knob detent, they fade to 5% over ten seconds.
Sub-detent encoder noise does not restart the idle timer.

## Menu-bar controls

The menu-bar window shows connection status, device serials, selected output,
live volume, and all three mute states. It can also:

- select Main or Phones;
- toggle Mic/Line 1, Phones, or Main mute;
- reconnect both devices; and
- shut the controller down cleanly.

Ratchet hardware controls and the menu-bar controls share the same coordinator
and state model.

Opening Ratchet Remote again from Applications or Spotlight brings up a normal
controls window in the existing process, even if the menu-bar item is missing.
The app restores its menu-bar item after display changes and wake. Hardware
connections start with the application and do not depend on the menu rendering.

## Diagnostic modes

Run a five-second connection check:

```sh
swift run RatchetRemote --smoke-test
```

The smoke test prints the detected Ratchet and current UCX II state, changes no
RME volume or mute state, disables Ratchet outputs, and exits.

To check repeated recovery with both devices connected:

```sh
swift run RatchetRemote --reconnect-test
```

This deliberately reconnects five times and opens/closes the controls window
on each cycle. It checks that both devices and the controls recover, then
disables Ratchet outputs and exits. Quit other Ratchet Remote instances first.

To log physical button and knob events for 45 seconds:

```sh
swift run RatchetRemote --input-test
```

Input-test mode uses the normal mappings and can therefore change volume and
mute state. It does not restore those changes automatically.

## State behavior

The app uses one serialized RME user client and treats live device state as
authoritative, including changes made in TotalMix FX. If a stereo pair is
unlinked, the quieter channel is displayed for safety; the next write through
Ratchet Remote sets both channels to the same value.

Discovery matches RME vendor `2a39` and UCX II product `3f82`, then checks the
opened connection's serial/product via DriverKit's device-identity method.
The initial snapshot must confirm RME USB mode before gain/volume control is
available. Reconnects retain the selected serial for the app session, clear
observed state, and read fresh values without restoring cached mixer settings.
Knob, mic mute, and output mute commands are sent immediately and their requested
values are shown while pending; they are kept separate from observed device
state. Input actions never request or wait for snapshots. After 150 ms without a control write, one
fresh snapshot reconciles the latest levels. A snapshot already in flight
cannot overwrite a newer requested level. No stream start/stop, sample-rate
or buffer-size calls are made.

DSP reads use the driver's DSP-only trigger mode and periodically rearm empty
reads so timed-out or stalled USB transfers can recover. Refreshes first drain
and acknowledge queued responses; only fresh responses complete a snapshot.
Incomplete snapshots are retried after a quiet interval within the original
timeout, allowing later register blocks to arrive. This allows standalone reads
with USB DriverKit 1.0.59 without requiring TotalMix FX to remain open.

Live polls consume one completed frame and return immediately. Snapshot waits
suspend asynchronously so new writes and disconnects can proceed; individual
DriverKit calls and the response/ACK stream remain serialized.
An incomplete background snapshot retains the last known state and schedules
a retry; it does not disconnect the controller. Initial connection still
requires a complete snapshot before enabling controls.

Slow RME operations and main-thread stalls are logged under
`com.coral.RatchetRemote`, categories `RMETiming` and `ControlTiming`. To include
fast operations and knob/button events, launch with `--diagnostics`:

```sh
open -a "Ratchet Remote" --args --diagnostics
log stream --style compact --predicate 'subsystem == "com.coral.RatchetRemote"'
```

Quit the existing instance before launching with this flag. Logs distinguish
driver call duration, snapshot frames/retries, response waiting, total knob
round-trip time, main-actor tick gaps, readback mismatches, and recovery errors.

The selected role and saved restore levels persist in macOS user defaults.
Disconnects are surfaced in both the menu bar and Ratchet presentation, and
the coordinator reconnects when the hardware becomes available again.

Ratchet recovery creates a fresh HID manager and adopts already-present
devices. Valid fragment tails received midway through a USB reconnect are
discarded until the next complete message. Missing Hello or device responses
trigger recovery after three seconds; discovery also retries when no device
was selected. Connection transitions and recovery errors are recorded in the
macOS unified log under `com.coral.RatchetRemote` / `Connection`.

## Tests

```sh
swift test
```

The test suite covers HID fragmentation and reassembly, reliable protocol
transactions, RME register encoding and state decoding, Main assignment,
mic gain write isolation/readback, identity/mode validation, DSP payload boundaries
and ACKs, knob mapping, idle
dimming, and display/LED presentation. Tests do not write to attached audio
hardware.

## Project structure

- `RatchetProtocol` — protobuf API, strict HID framing, and reliable command
  transactions
- `RMEControl` — actor-isolated DriverKit client and UCX II register map
- `RemoteCore` — device coordination, reconnect policy, input mapping, and
  Ratchet presentation
- `RatchetRemote` — accessory-mode SwiftUI menu-bar application
- `Packaging` and `install.sh` — macOS app metadata, bundling, signing, and
  local installation
