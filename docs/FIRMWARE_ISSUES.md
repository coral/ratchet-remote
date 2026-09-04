# Ratchet firmware integration issues

Originally observed against firmware `0.1.0` on `DEV0001` on 2026-09-02.
Resolution was verified on the optimized development firmware using the
factory-derived serial `RATCHET-DC5475EF5108`.

## FW-1: Valid host traffic overflowed the USB receive queue — resolved

Severity: resolved in firmware

Resolution: the firmware USB receive queue now holds 96 reports. This covers
the 79 reports required by a maximum-size 4096-byte protocol message. The
five-second Rust reference demo now completes with one `Ready`, normal visual
updates, no receive/reassembly/stale faults, and a clean `DisableOutputs`.

Original behavior: the checked-in Rust reference host could complete its
atomic `Configure`, but ordinary reliable UI mutations sent immediately
afterward repeatedly put the firmware back into its fault/waiting state.

Reproduction:

```sh
ratchet-host demo --duration-seconds 5 --original-haptics
```

Observed sequence:

1. Device emits a compatible `Hello` (`ring=60`, `keys=8`, `buttons=4`, display `240x240`).
2. Reference host receives `Ready` for its valid `Configure`.
3. Device emits `FAULT_CODE_PROTOCOL`: `USB receive queue overflowed; host input was discarded`.
4. Device then emits `host message reassembly timed out` and a new unconfigured `Hello`.
5. Recovery repeats several times; one delayed replay eventually receives `command sequence is stale and no replay remains cached`.

The HID SetReport calls return success, so the host has no transport-level
backpressure signal. A conforming host is allowed to send the next reliable
mutation once `Ready` completes Configure. The firmware needs enough buffering
or fast enough draining to retain the fragments it has accepted.

Acceptance check passed: the five-second reference demo configured once, sent
normal display/LED updates, and exited through `DisableOutputs` without a
protocol fault, reassembly timeout, or stale replay rejection.

## FW-2: Seven-fragment Configure diagnosis — not a firmware issue

Severity: resolved in Ratchet Remote

After FW-1 was repaired, firmware received the complete 357-byte Configure and
immediately returned `INVALID_CONFIGURATION: invalid display frame:
GeometryOutsideDisplay`.

The cause was client-side: Ratchet Remote used `x = 120`, `max_width = 224` for
center-aligned text. `Text.x` is the field's left edge, so that field ended at
pixel 344. The corrected field uses `x = 8` and ends at pixel 232.

The coordinator also failed to copy the value-type session back after
`processDeviceMessage` cleared a rejected transaction and threw its diagnostic.
That left the old in-flight transaction in the coordinator and later produced
a misleading retry-exhaustion error. The error path now persists the cleared
session before surfacing the firmware rejection.

The corrected configuration contains:

- regular haptics, 20 detents/turn, bounds `-2048...2048`;
- a present, complete 204-byte LED frame;
- a present display frame beginning with Clear and ending with SetBacklight;
- 10 ms knob reporting and a 2500 ms watchdog.

Acceptance check passed on `RATCHET-DC5475EF5108`: the corrected seven-fragment
Configure produced a matching `Ready`, the five-second Swift smoke test read
the live RME state without an error, and shutdown completed cleanly. A matching
negative Ack is now surfaced immediately and cannot later be reported as retry
exhaustion.

Historical pre-fix Ratchet Remote smoke result:

```text
Ratchet: offline
RME: connected serial 24096863
Main: 0.0 dB, muted=false
Phones: -65.0 dB, muted=false
Mic/Line 1 USB: muted=true
Error: Configure command 36 was not acknowledged after 3 retries
       (356 protobuf bytes across 7 HID reports)
```
