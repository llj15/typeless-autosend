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

Topology GREEN: all ten scenarios pass with production `e260ec0`.
The essential `enumeration-failure` case then verifies failed OS routing inspection
blocks public health and poll notifies cancellation. It fails against `861c684`
with `FAIL: failed routing inspection must block unsafe sending` (exit 1), and
passes with `e260ec0`. All eleven scenarios pass together.

## Harness quality and limits

- Exercises actual production InputMonitor initialization, event masks/callbacks,
  source attribution, begin/arm, health queries, interruption and poll recovery.
  Assertions use public cancellation callbacks, availability and attempt result.
- Models per-level head/tail insertion, enabled/valid port gating, active consumer
  suppression, and listen-only callbacks being unable to suppress the event.
  Ports have fixture ownership until process exit, including retired invalid ports.
- All tap creation is interposed to local Mach ports. Events are constructed in
  memory and dispatched to captured callbacks; they are never posted. CGEventPost
  aborts if reached. Test focus uses deterministic read-only AX/AppKit stubs.
  Tests do not launch dictation, type text/Return, change installed services, or
  open transcript databases. Production main.swift is excluded from this binary.
- System simulation assumes macOS tap ordering/consumption semantics. It cannot
  establish physical Fn delivery, actual TCC permissions, real application focus,
  event-tap scheduling/timeouts, or Typeless behavior on the user's machine.
  Source attribution executes with PID 0 (unknown/physical); verified Typeless
  synthetic-paste exemption is not established by this boundary suite.
- The restart case covers a persistent new consuming HID keyboard filter visible
  in the OS tap list. An invisible transient filter is outside this guarantee.
  Event replacement by a non-suppressing active filter is not modeled.
- The fixture is macOS-specific and requires CLT Swift/Clang/AppKit, matching the
  application. Recovery includes a bounded real-time retry wait (up to 2 seconds).
  Each scenario runs in its own process, isolating swizzles and fixture state.

## Review repair regressions

`consumer-during-preparation` reproduces a filter installed during preparation's
first OS enumeration. It was RED on `e260ec0`; `d9ec4cc` makes all twelve boundary
cases GREEN by safely preparing ahead of the consumer or refusing unsafe setup.

`python3 tests/test_keyboard_daemon_boundary.py` compiles the complete unchanged
daemon entry point and interposes macOS APIs. Config, executable lock/runtime
state, HOME and SQLite all live in a temporary directory. It waits for explicit
`fixture: isolated macOS boundary loaded` and production baseline readiness.
The fake front app is rejected by the first config. After that production skip,
a marker makes the boundary install a persistent consumer during idle polling.
A new fresh completion with the fake app enabled must send normally.

RED on `d9ec4cc`: first row correctly skips whitelist; topology becomes unhealthy
while idle; the subsequent fresh row incorrectly skips with `completed at or
before input monitoring recovery`. This executes the real main.swift early exit.

For this daemon fixture only, `TYPELESS_BOUNDARY_CAPTURE_POSTS=1` makes the
CGEventPost interceptor log `fixture: suppressed native key posting` and return.
It never forwards to macOS. Other boundary tests still abort posting attempts.
Accessibility trust and focus reads remain simulated; no real app is enabled,
no typing/dictation/Return reaches the desktop, and no installed service changes.
