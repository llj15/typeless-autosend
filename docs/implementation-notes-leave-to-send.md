# Leave-to-send implementation notes

The requested behavior is specified in [design-leave-to-send.md](design-leave-to-send.md). The implementation and its tests include the following explicit limits. The pull request remains a draft for review of these limits.

## Delivery after a same-application focus change

`CGEvent.postToPid` selects a process, not an Accessibility input object. AppKit dispatches ordinary key events through the current key window and first responder, as documented in [Apple's Handling Key Events guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingKeyEvents/HandlingKeyEvents.html).

Consequently, posting Return after another input or window has gained focus can submit the new input. Saving the original AX object does not change keyboard routing. This conflicts with the design's combination of sending after any same-application focus change and retaining PID-only delivery.

The implementation cancels when it observes such a completed focus change. It also cancels a departure during the paste buffer if focus has already moved to a different input before settlement. Outside clicks after settlement can still post while their event-tap callback holds the click. The callback orders the post call before releasing the click; unit tests do not establish the receiving application's native processing order.

Departure requires confirmation of the original application's focused window and input identity. An unreadable identity cancels instead of treating an unknown receiver as the original input. This adds a cancellation case beyond the original design. Content reads and identity reads are handled separately: an unreadable text value alone does not prove editing, and expiry does not reread text or selection.

When hit testing returns only the original window/application boundary, or parent traversal is incomplete, the relationship is unknown. Such a click does not trigger an early send. A blank-area click whose target cannot be distinguished from the original input therefore waits for another confirmed departure or expiry.

Supporting the original behavior for these cases requires a separate routing design: intercepting and deferring transitions, or a supported element-level submission/focus mechanism. Neither is introduced implicitly in this change.

Expiry relies on the latest foreground observations and notifications, then checks health and authorization without another AX read. A focus or content change whose notification has not yet arrived can fall between the last observation and actual event delivery. This change does not claim an atomic guarantee about native first-responder routing; that remains outside the unit-test evidence.

## Paste association and content alignment

Each captured paste is consumed once and associated with a local database record. A paste observed while the newest local record is incomplete cannot establish that association; the implementation waits for a matching capture and eventually skips a stale completion. This prevents a delayed paste from an older dictation from being assigned to a newly started recording. No clipboard text is read.

Content alignment protects the pasted lines and accepts refreshes elsewhere. Ambiguous alignment, an unknown selection replacement that cannot be recovered, or an alignment larger than the configured bounds uses the whole input as a baseline. These cases may cancel on unrelated refreshes. A buffer edit is cancelled when the before/after snapshots establish that the protected content or caret was changed; an unresolvable snapshot still uses the documented whole-input fallback.

## Verification boundary

Development used failing unit cases followed by implementation and passing cases. The independent review agents use GPT-6 Solar (`gpt-6-sol`) with `max` reasoning and receive no inherited conversation history.

Tests compile separate executables and use pure algorithms, simulated events, temporary SQLite databases, and stubbed system APIs or commands. No real application integration or end-to-end tests were run. The installed executable, permissions, LaunchAgents, desktop focus, keyboard and mouse were not changed.
