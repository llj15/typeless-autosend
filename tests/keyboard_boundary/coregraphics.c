// Test-only CoreGraphics boundary. No OS event tap is installed and no event is posted.
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new_function; const void *old_function; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(replacement), (const void *)(original) };

typedef struct {
    CGEventTapLocation location;
    CGEventMask mask;
    CGEventTapCallBack callback;
    void *context;
    CFMachPortRef port;
    bool enabled;
} Listener;
static Listener listeners[32];
static int listener_count;
static void receive_message(CFMachPortRef port, void *message, CFIndex size, void *context) {}

static CFMachPortRef simulated_create(CGEventTapLocation location, CGEventTapPlacement placement,
    CGEventTapOptions options, CGEventMask mask, CGEventTapCallBack callback, void *context) {
    if (listener_count == 32) abort();
    CFMachPortContext port_context = {0};
    CFMachPortRef port = CFMachPortCreate(NULL, receive_message, &port_context, NULL);
    listeners[listener_count++] = (Listener){location, mask, callback, context, port, true};
    return port;
}
static void simulated_enable(CFMachPortRef port, bool enabled) {
    for (int i = 0; i < listener_count; i++) if (listeners[i].port == port) listeners[i].enabled = enabled;
}
static bool simulated_enabled(CFMachPortRef port) {
    for (int i = 0; i < listener_count; i++) if (listeners[i].port == port) return listeners[i].enabled;
    return false;
}
static bool simulated_permission(void) { return true; }
static Boolean simulated_secure_input(void) { return false; }
static void forbidden_post(CGEventTapLocation location, CGEventRef event) {
    fputs("unsafe event posting attempted\n", stderr); abort();
}
INTERPOSE(simulated_create, CGEventTapCreate)
INTERPOSE(simulated_enable, CGEventTapEnable)
INTERPOSE(simulated_enabled, CGEventTapIsEnabled)
INTERPOSE(simulated_permission, CGPreflightListenEventAccess)
INTERPOSE(simulated_secure_input, IsSecureEventInputEnabled)
INTERPOSE(forbidden_post, CGEventPost)

// Model macOS routing: HID listeners see the physical Fn edge; the dictation
// consumer then suppresses it, so no session/annotated-session listener sees it.
void emit_consumed_dictation_fn(void) {
    if (listener_count == 0) {
        fputs("fixture error: production listener registration was not captured\n", stderr);
        abort();
    }
    CGEventRef event = CGEventCreate(NULL);
    CGEventSetType(event, kCGEventFlagsChanged);
    CGEventSetFlags(event, kCGEventFlagMaskSecondaryFn);
    CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, 63);
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, 0);
    for (int i = 0; i < listener_count; i++) {
        Listener listener = listeners[i];
        if (listener.location == kCGHIDEventTap && listener.enabled &&
            (listener.mask & CGEventMaskBit(kCGEventFlagsChanged))) {
            listener.callback((CGEventTapProxy)listener.port, kCGEventFlagsChanged, event, listener.context);
        }
    }
    CFRelease(event);
}
