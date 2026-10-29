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
