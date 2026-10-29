# Keyboard boundary regression

`python3 tests/test_keyboard_boundary.py` compiles production Swift sources with
a test-only dynamic library interposing CoreGraphics event-tap registration and
health APIs. The library creates local Mach ports instead of OS event taps. It
uses the callbacks and event masks supplied by production registration, and
passes an in-memory Fn event through a simulated HID route. A dictation consumer
suppresses onward session delivery. No keyboard event is posted or real user
input intercepted. Registration capture is checked as fixture setup; the sole
product assertion is the public `InputMonitor.onKeyboard` cancellation callback.
Source attribution executes production code with a physical/unknown source PID.

Baseline RED, 2026-10-29, production commit `72c2833`:

```text
$ python3 tests/test_keyboard_boundary.py
FAIL: starting Fn dictation must cancel a pending send even when the dictation consumer swallows the shortcut before session delivery
(exit 1)
```

This simulation verifies routing policy and cancellation, not actual physical Fn
delivery on a particular macOS installation. Live physical verification remains
separate.

Second slice: ordered head/tail routing now honors consumer suppression and
listen-only forwarding. Fixture retains ports, skips invalidated ports, and
uses deterministic read-only AX/AppKit boundaries for successful public
`beginAttempt()` -> `armAttempt(focus:)` flow. `consumer-after-daemon` installs a
consumer after daemon construction and before beginning the attempt.

Both scenarios fail on `72c2833` and pass with production `861c684`.
A temporary build of `861c684` omitting only its beginAttempt rehead guard fails
`consumer-after-daemon` (exit 1), confirming sensitivity to the ordering fix.
No production source file was edited for that mutation experiment.

Additional routing/health coverage (no further production changes):

- Swallowed custom Cmd+Shift+K: baseline RED, `861c684` GREEN.
- Session-origin keyboard: baseline and `861c684` GREEN.
- HID creation failure, timeout and invalidation: baseline RED, `861c684` GREEN.
- Session timeout/invalidation: baseline and `861c684` GREEN.

Health assertions use public `available`, `beginAttempt`, `poll`, and cancellation
callbacks. Recovery must restore monitoring while notifying cancellation of the
old attempt. Creation-failure recovery observes the existing bounded retry delay.

Persistent restart slice RED against `861c684`:

```text
$ python3 tests/test_keyboard_boundary.py
[nine existing scenarios PASS]
FAIL: persistent dictation consumer installed during countdown must block unsafe sending
(exit 1)
```

The added consumer is installed after public begin/arm. Its swallowed Fn never
reaches the monitor. Public health must therefore block the old send and poll
must notify cancellation when persistent routing changed. The CGGetEventTapList
fixture reports retained, valid system registrations with stable IDs, options,
masks and enabled status. Product assertions do not inspect IDs or tap placement.
