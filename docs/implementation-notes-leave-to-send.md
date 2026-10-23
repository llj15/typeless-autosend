# Leave-to-send implementation notes

The requested behavior is specified in [design-leave-to-send.md](design-leave-to-send.md). These notes describe delivery decisions, content alignment and the unit-test verification boundary.

## Delivery on departure

Changing to another window or input in the original application requests immediate delivery to the captured PID. It does not cancel the attempt. Application deactivation takes the same delivery path. During the 150 ms paste buffer, departure is retained until settlement reads the captured original input and establishes its baseline, then delivery proceeds.

Departure checks the captured original input object for a confirmed protected-content or caret change; it does not compare the newly focused input against the old baseline. Unknown focus identity or unreadable text alone is not proof of editing. Confirmed editing, a newer local record, missing permissions, Secure Input and process exit still prevent delivery.

Caret and selection comparisons require confirmation that the original input remains focused. A control may clear its Accessibility selection when it blurs; that reset alone does not prove a user edit. A confirmed departure notification is retained through settlement and takes precedence over a cached focused-element identity. Protected-content checks still use the original input during departure. Cancellation diagnostics distinguish content, caret and selection changes and identify the original application without logging input text.

Within the same window, a focused child or non-window ancestor proven to belong to the original input keeps the countdown. A relationship that cannot be determined also waits for later observations or expiry. A confirmed different window requests delivery independently of input ancestry. Focus and deactivation notifications that arrive while the state lock is busy are retained; delivery waits for queued notifications, and capture generations and attempt epochs keep old events from affecting new work.

After settlement, an outside click posts while its event-tap callback holds the click. The callback orders the post call before releasing the click. During the buffer, the click records departure and settlement sends later; that click is not retained for replay.

An existing mouse limitation remains: an outside click between paste capture and arming can be missed when the state lock is busy. If that click causes no observable focus change, delivery waits for expiry. This window-switch correction does not change the physical mouse callback's contention policy.

The two ancestry walks advance together. Separate input branches joining at a known common ancestor establish an outside relationship even when ancestors above it cannot be read. Without that evidence or completed boundary walks, the relationship remains unknown. A blank-area click whose target cannot be distinguished from the original input therefore waits for another confirmed departure or expiry.

Delivery keeps the design's existing `CGEvent.postToPid` mechanism. The unit tests establish when delivery is requested, which PID is retained, and that an attempt sends at most once. They do not establish which native window or first responder ultimately receives Return after a focus transition. AppKit describes ordinary keyboard dispatch in [Apple's Handling Key Events guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingKeyEvents/HandlingKeyEvents.html). No window-specific injection, input refocusing, or element-level submission action is introduced in this change.

Expiry relies on the latest foreground observations and notifications, then checks health and authorization without another AX read. A focus or content change whose notification has not yet arrived can fall between the last observation and actual event delivery. Native application processing order remains outside the unit-test evidence.

## Paste association and content alignment

Each captured paste is consumed once and associated with a local database record. A paste observed while the newest local record is incomplete cannot establish that association; the implementation waits for a matching capture and eventually skips a stale completion. This prevents a delayed paste from an older dictation from being assigned to a newly started recording. No clipboard text is read.

After the initial 150 ms buffer, an empty or unchanged value can still be a cached pre-paste snapshot. A changed value without the pasted text can also be an unrelated output refresh. Settlement retries the saved original input every 50 ms, for at most one second after arming, retaining any departure request; the delivery timer waits for settlement. Minimum paste evidence requires the complete text, allowing CRLF/LF equivalence and omission of a single final newline. Matching historical text alone cannot establish the insertion location; region alignment or the whole-input fallback still applies. If the window expires without observing a paste, the attempt skips unless a reported selection proves an identical-text replacement. A capture event alone does not prove that the application accepted the paste. This avoids submitting an empty input or a pre-existing draft after an ineffective paste. Replacing a reported selection with the same nonempty text remains supported; without selection information, an unchanged value cannot establish that replacement.

Content alignment protects the pasted lines and accepts refreshes elsewhere. Ambiguous alignment, an unknown selection replacement that cannot be recovered, or an alignment larger than the configured bounds uses the whole input as a baseline. These cases may cancel on unrelated refreshes. A buffer edit is cancelled when the before/after snapshots establish that the protected content or caret was changed; an unresolvable snapshot still uses the documented whole-input fallback.

## Verification boundary

Development used failing unit cases followed by implementation and passing cases. The independent review agents use GPT-6 Solar (`gpt-6-sol`) with `max` reasoning and receive no inherited conversation history.

Tests compile separate executables and use pure algorithms, simulated events, temporary SQLite databases, and stubbed system APIs or commands. No real application integration or end-to-end tests were run. These checks do not move desktop focus, type, click, or submit content. Local installation and service health checks are separate operations performed only when requested.
