# Dictation shortcut cancellation

## User contract

While an automatic send is pending after a completed transcription, pressing the dictation keyboard shortcut cancels that pending send immediately and permanently. This covers Fn and configurable key combinations, not the letter F. Releasing/canceling the new dictation does not revive the previous send. A genuinely new completed transcription starts a fresh countdown. Preserve the basic release's other cancellation rules and its exclusion of verified Typeless paste injection.

## Verified failure (2026-10-29, Asia/Shanghai)

Installed version v1.2.1, main 13a0be5. Typeless has active HID and session event taps; autosend only has a passive session tap. A temporary passive probe observed the user's Fn event at 17:53:36.078 at HID, but not at session. The installed daemon posted Return at 17:53:36.326. Existing simulated keyboard tests bypass the event routing boundary and cannot catch this regression.

## Agreed test seams

The user confirmed both seams on 2026-10-29:

1. macOS keyboard-event boundary -> InputMonitor public cancellation callback. Verify cancellation when a dictation consumer prevents the event from reaching session listeners. Cover Fn and ordinary/custom key combinations. Do not test private methods or assert internal tap counts/placement as the product outcome. System-boundary simulation is allowed; production routing and source-attribution policy must be exercised. Native probes must never type text, send Return, trigger dictation, or swallow real user input.
2. Daemon entry point -> service status and dry-run send/skip output. Verify old attempts remain canceled and a later completion gets its own delay. Use the existing isolated SQLite/event-stream test harness. Never touch the user's installed service or real transcript database in automated tests.

Real physical Fn verification remains a separate final check; simulation cannot prove macOS delivery on this machine.

## Shared interfaces and responsibility

Keep InputMonitor's existing public init(dryRun:environment:), onKeyboard(String), onFocusChange(String), beginAttempt(), armAttempt(focus:), endAttempt(), poll(), available and monitoringDetails contracts. Existing monitoring status keys keep their types and meanings; sending requires every necessary listener to be healthy. System adapters, if needed to test routing, must be narrow macOS boundary dependencies rather than mocks of InputMonitor or its own methods. Discuss any public-interface change before parallel edits.

The tests agent owns the first behavioral regression and records baseline failure. The implementation agent owns the minimal production fix only after that failure is reproduced. Work happens in separate worktrees from this shared commit. Main agent integrates tests before code, runs full validation, and coordinates review/fix rounds. Do not alter PR #7 or merge/release/install until the candidate is validated.

## TDD order

1. One regression test reproduces a swallowed shortcut on unchanged basic main (RED).
2. Implement only enough to make it pass (GREEN).
3. Add the next required scenario only if it is not covered, then repeat RED/GREEN.
4. Run existing regression suites and independent code review; address material findings before installing.

A preliminary untested candidate was saved outside the repository before the user requested TDD. It is not part of this baseline and is not evidence of a fix.
