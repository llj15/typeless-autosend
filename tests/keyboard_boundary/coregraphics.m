// Test-only macOS system boundary: no OS tap is installed and no event posted.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
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
    CGEventTapOptions options;
    bool enabled;
    uint32_t identifier;
} Listener;
static Listener listeners[128];
static int listener_count;
static uint32_t next_identifier = 1;
static bool fail_enumeration;
static bool fail_hid_create;
static bool install_during_enumeration;
static void receive_message(CFMachPortRef port, void *message, CFIndex size, void *context) {}
static CFMachPortRef simulated_create(CGEventTapLocation location, CGEventTapPlacement placement,
    CGEventTapOptions options, CGEventMask mask, CGEventTapCallBack callback, void *context) {
    if (location == kCGHIDEventTap && fail_hid_create) return NULL;
    if (listener_count == 128) abort();
    CFMachPortContext port_context = {0};
    CFMachPortRef port = CFMachPortCreate(NULL, receive_message, &port_context, NULL);
    // Keep fixture ownership until process exit. Retired ports can be invalid,
    // but are never dangling when routing/recovery scans the registration list.
    CFRetain(port);
    int index = placement == kCGHeadInsertEventTap ? 0 : listener_count;
    for (int i = listener_count; i > index; i--) listeners[i] = listeners[i - 1];
    listeners[index] = (Listener){location, mask, callback, context, port, options, true, next_identifier++};
    listener_count++;
    return port;
}
static void simulated_enable(CFMachPortRef port, bool enabled) {
    for (int i = 0; i < listener_count; i++) if (listeners[i].port == port) listeners[i].enabled = enabled;
}
static bool simulated_enabled(CFMachPortRef port) {
    for (int i = 0; i < listener_count; i++)
        if (listeners[i].port == port) return listeners[i].enabled && CFMachPortIsValid(port);
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

// Deterministic read-only focus boundary, with real AX element/value CF types.
@interface FixtureApplication : NSObject
@end
@implementation FixtureApplication
- (NSString *)bundleIdentifier { return @"com.test.editor"; }
- (pid_t)processIdentifier { return getpid(); }
@end
@interface NSWorkspace (FixtureFocus)
- (NSRunningApplication *)fixture_frontmostApplication;
@end
@implementation NSWorkspace (FixtureFocus)
+ (void)load {
    method_exchangeImplementations(class_getInstanceMethod(self, @selector(frontmostApplication)),
        class_getInstanceMethod(self, @selector(fixture_frontmostApplication)));
}
- (NSRunningApplication *)fixture_frontmostApplication { return (id)[FixtureApplication new]; }
@end
static bool simulated_ax_trusted(void) { return true; }
static AXError simulated_attribute(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value) {
    if (CFEqual(attribute, kAXSelectedTextRangeAttribute)) {
        CFRange range = CFRangeMake(0, 0);
        *value = AXValueCreate(kAXValueCFRangeType, &range);
    } else { *value = AXUIElementCreateApplication(getpid()); }
    return kAXErrorSuccess;
}
static void run_loop_noop(void *info) {}
static AXError simulated_observer(pid_t pid, AXObserverCallback callback, AXObserverRef *observer) {
    CFRunLoopSourceContext context = {0}; context.perform = run_loop_noop;
    *observer = (AXObserverRef)CFRunLoopSourceCreate(NULL, 0, &context);
    return kAXErrorSuccess;
}
static CFRunLoopSourceRef simulated_observer_source(AXObserverRef observer) { return (CFRunLoopSourceRef)observer; }
static AXError simulated_observer_add(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context) { return kAXErrorSuccess; }
INTERPOSE(simulated_ax_trusted, AXIsProcessTrusted)
INTERPOSE(simulated_attribute, AXUIElementCopyAttributeValue)
INTERPOSE(simulated_observer, AXObserverCreate)
INTERPOSE(simulated_observer_source, AXObserverGetRunLoopSource)
INTERPOSE(simulated_observer_add, AXObserverAddNotification)

static CGEventRef consume(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) { return NULL; }
void install_dictation_consumer(void) {
    simulated_create(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
        CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown), consume, NULL);
}
// Events can originate at HID or session; consumers suppress further delivery,
// whereas listen-only callbacks cannot alter/suppress the routed event.
void emit_keyboard(int session_only, int custom) {
    if (listener_count == 0) { fputs("fixture error: no listener registration\n", stderr); abort(); }
    CGEventRef event = CGEventCreate(NULL);
    CGEventType type = custom ? kCGEventKeyDown : kCGEventFlagsChanged;
    CGEventSetType(event, type);
    CGEventSetFlags(event, custom ? kCGEventFlagMaskCommand | kCGEventFlagMaskShift : kCGEventFlagMaskSecondaryFn);
    CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, custom ? 40 : 63);
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, 0);
    for (int level = session_only ? kCGSessionEventTap : kCGHIDEventTap; level <= kCGAnnotatedSessionEventTap; level++) {
        for (int i = 0; i < listener_count; i++) {
            Listener listener = listeners[i];
            if (listener.location != level || !listener.enabled || !CFMachPortIsValid(listener.port) || !(listener.mask & CGEventMaskBit(type))) continue;
            CGEventRef result = listener.callback((CGEventTapProxy)listener.port, type, event, listener.context);
            if (!(listener.options & kCGEventTapOptionListenOnly) && !result) { CFRelease(event); return; }
        }
    }
    CFRelease(event);
}
void set_hid_creation_failure(int value) { fail_hid_create = value; }
void interrupt_listener(int hid, int invalidate) {
    for (int i = 0; i < listener_count; i++) {
        Listener *listener = &listeners[i];
        if (listener->location != (hid ? kCGHIDEventTap : kCGSessionEventTap) || !CFMachPortIsValid(listener->port) || listener->callback == consume) continue;
        if (invalidate) CFMachPortInvalidate(listener->port);
        else {
            listener->enabled = false;
            CGEventRef event = CGEventCreate(NULL);
            listener->callback((CGEventTapProxy)listener->port, kCGEventTapDisabledByTimeout, event, listener->context);
            CFRelease(event);
        }
    }
}

static CGError simulated_tap_list(uint32_t maximum, CGEventTapInformation *information, uint32_t *count) {
    if (install_during_enumeration) { install_during_enumeration = false; install_dictation_consumer(); }
    if (fail_enumeration) return kCGErrorFailure;
    uint32_t active = 0;
    for (int i = 0; i < listener_count; i++) {
        Listener listener = listeners[i];
        if (!CFMachPortIsValid(listener.port)) continue;
        if (information && active < maximum) {
            information[active] = (CGEventTapInformation){
                .eventTapID = listener.identifier, .tapPoint = listener.location,
                .options = listener.options, .eventsOfInterest = listener.mask,
                .tappingProcess = listener.callback == consume ? 424242 : getpid(),
                .enabled = listener.enabled
            };
        }
        active++;
    }
    if (count) *count = active;
    return kCGErrorSuccess;
}
INTERPOSE(simulated_tap_list, CGGetEventTapList)
void set_enumeration_failure(int value) { fail_enumeration = value; }

void set_install_during_enumeration(int value) { install_during_enumeration = value; }
