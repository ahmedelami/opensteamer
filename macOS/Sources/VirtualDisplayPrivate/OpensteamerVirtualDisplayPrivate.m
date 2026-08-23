#import "OpensteamerVirtualDisplayPrivate.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

// The compatibility runtime is optional. Resolve both classes and selectors dynamically so the
// ordinary flag-off host has no loader dependency on Apple's private Objective-C class symbols.
@interface OpensteamerVirtualDisplayTerminationState : NSObject
@property(atomic, getter=isTerminated) BOOL terminated;
@end

@implementation OpensteamerVirtualDisplayTerminationState
@end

struct OpensteamerVirtualDisplayHandle {
    void *retainedDisplay;
    void *retainedTerminationState;
    CGDirectDisplayID displayID;
};

static Class OpensteamerPrivateClass(NSString *name) {
    return NSClassFromString(name);
}

static bool OpensteamerInstancesRespondTo(Class classObject, const char *selectorName) {
    return classObject != Nil
        && [classObject instancesRespondToSelector:sel_registerName(selectorName)];
}

static bool OpensteamerVirtualDisplayClassesAreAvailable(void) {
    Class display = OpensteamerPrivateClass(@"CGVirtualDisplay");
    Class descriptor = OpensteamerPrivateClass(@"CGVirtualDisplayDescriptor");
    Class mode = OpensteamerPrivateClass(@"CGVirtualDisplayMode");
    Class settings = OpensteamerPrivateClass(@"CGVirtualDisplaySettings");
    return OpensteamerInstancesRespondTo(
            mode,
            "initWithWidth:height:refreshRate:"
        )
        && OpensteamerInstancesRespondTo(descriptor, "setQueue:")
        && OpensteamerInstancesRespondTo(descriptor, "setName:")
        && OpensteamerInstancesRespondTo(descriptor, "setMaxPixelsHigh:")
        && OpensteamerInstancesRespondTo(descriptor, "setMaxPixelsWide:")
        && OpensteamerInstancesRespondTo(descriptor, "setSizeInMillimeters:")
        && OpensteamerInstancesRespondTo(descriptor, "setSerialNum:")
        && OpensteamerInstancesRespondTo(descriptor, "setProductID:")
        && OpensteamerInstancesRespondTo(descriptor, "setVendorID:")
        && OpensteamerInstancesRespondTo(descriptor, "setTerminationHandler:")
        && OpensteamerInstancesRespondTo(display, "initWithDescriptor:")
        && OpensteamerInstancesRespondTo(display, "displayID")
        && OpensteamerInstancesRespondTo(display, "applySettings:")
        && OpensteamerInstancesRespondTo(settings, "setHiDPI:")
        && OpensteamerInstancesRespondTo(settings, "setModes:");
}

bool OpensteamerVirtualDisplayRuntimeIsAvailable(void) {
    return OpensteamerVirtualDisplayClassesAreAvailable();
}

static bool OpensteamerDiagnosticsAreEnabled(void) {
    const char *value = getenv("OPENSTEAMER_VIRTUAL_DISPLAY_DIAGNOSTICS");
    return value != NULL && strcmp(value, "1") == 0;
}

static void OpensteamerLogAvailableModes(CGDirectDisplayID displayID) {
    if (!OpensteamerDiagnosticsAreEnabled()) {
        return;
    }
    NSDictionary *options = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    CFArrayRef availableModes = CGDisplayCopyAllDisplayModes(
        displayID,
        (__bridge CFDictionaryRef)options
    );
    fprintf(stderr, "virtual-display id=%u available modes:\n", displayID);
    if (availableModes == NULL) {
        fprintf(stderr, "  unavailable\n");
        return;
    }
    CFIndex count = CFArrayGetCount(availableModes);
    for (CFIndex index = 0; index < count; index += 1) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(
            availableModes,
            index
        );
        fprintf(
            stderr,
            "  %zux%zu@%zux%zu %.2fHz\n",
            CGDisplayModeGetWidth(mode),
            CGDisplayModeGetHeight(mode),
            CGDisplayModeGetPixelWidth(mode),
            CGDisplayModeGetPixelHeight(mode),
            CGDisplayModeGetRefreshRate(mode)
        );
    }
    CFRelease(availableModes);
}

static bool OpensteamerModeMatches(
    CGDisplayModeRef mode,
    OpensteamerVirtualDisplayResolvedMode requestedMode
) {
    double refreshRate = CGDisplayModeGetRefreshRate(mode);
    return CGDisplayModeGetWidth(mode) == requestedMode.logicalWidth
        && CGDisplayModeGetHeight(mode) == requestedMode.logicalHeight
        && CGDisplayModeGetPixelWidth(mode) == requestedMode.pixelWidth
        && CGDisplayModeGetPixelHeight(mode) == requestedMode.pixelHeight
        && isfinite(refreshRate)
        && fabs(refreshRate - requestedMode.refreshRate) < 0.05;
}

static bool OpensteamerAllRequestedModesAreAvailable(
    CGDirectDisplayID displayID,
    const OpensteamerVirtualDisplayResolvedMode *requestedModes,
    size_t requestedModeCount
) {
    NSDictionary *options = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    for (NSUInteger attempt = 0; attempt < 100; attempt += 1) {
        bool displayIsReady = CGDisplayIsOnline(displayID) && CGDisplayIsActive(displayID);
        CFArrayRef availableModes = CGDisplayCopyAllDisplayModes(
            displayID,
            (__bridge CFDictionaryRef)options
        );
        bool foundEveryMode = displayIsReady && availableModes != NULL;
        if (availableModes != NULL) {
            CFIndex availableModeCount = CFArrayGetCount(availableModes);
            for (size_t requestedIndex = 0;
                 foundEveryMode && requestedIndex < requestedModeCount;
                 requestedIndex += 1) {
                bool foundRequestedMode = false;
                for (CFIndex availableIndex = 0;
                     availableIndex < availableModeCount;
                     availableIndex += 1) {
                    CGDisplayModeRef candidate = (CGDisplayModeRef)CFArrayGetValueAtIndex(
                        availableModes,
                        availableIndex
                    );
                    if (OpensteamerModeMatches(
                            candidate,
                            requestedModes[requestedIndex]
                        )) {
                        foundRequestedMode = true;
                        break;
                    }
                }
                foundEveryMode = foundRequestedMode;
            }
            CFRelease(availableModes);
        }
        if (foundEveryMode) {
            return true;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    OpensteamerLogAvailableModes(displayID);
    return false;
}

static bool OpensteamerSelectInitialMode(
    CGDirectDisplayID displayID,
    OpensteamerVirtualDisplayResolvedMode requestedMode
) {
    CGDisplayModeRef targetMode = NULL;
    NSDictionary *options = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    for (NSUInteger attempt = 0; attempt < 100 && targetMode == NULL; attempt += 1) {
        CFArrayRef availableModes = CGDisplayCopyAllDisplayModes(
            displayID,
            (__bridge CFDictionaryRef)options
        );
        if (availableModes != NULL) {
            CFIndex count = CFArrayGetCount(availableModes);
            for (CFIndex index = 0; index < count; index += 1) {
                CGDisplayModeRef candidate = (CGDisplayModeRef)CFArrayGetValueAtIndex(
                    availableModes,
                    index
                );
                if (OpensteamerModeMatches(candidate, requestedMode)) {
                    targetMode = (CGDisplayModeRef)CFRetain(candidate);
                    break;
                }
            }
            CFRelease(availableModes);
        }
        if (targetMode == NULL) {
            [NSThread sleepForTimeInterval:0.05];
        }
    }
    if (targetMode == NULL) {
        OpensteamerLogAvailableModes(displayID);
        return false;
    }

    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(displayID);
    bool alreadySelected = currentMode != NULL
        && OpensteamerModeMatches(currentMode, requestedMode);
    if (currentMode != NULL) {
        CFRelease(currentMode);
    }
    if (alreadySelected) {
        CFRelease(targetMode);
        return true;
    }

    CGDisplayConfigRef configuration = NULL;
    CGError result = CGBeginDisplayConfiguration(&configuration);
    if (result == kCGErrorSuccess) {
        result = CGConfigureDisplayWithDisplayMode(
            configuration,
            displayID,
            targetMode,
            NULL
        );
    }
    if (result == kCGErrorSuccess) {
        result = CGCompleteDisplayConfiguration(configuration, kCGConfigureForAppOnly);
    } else if (configuration != NULL) {
        CGCancelDisplayConfiguration(configuration);
    }
    CFRelease(targetMode);
    if (result != kCGErrorSuccess) {
        if (OpensteamerDiagnosticsAreEnabled()) {
            fprintf(stderr, "virtual-display mode configuration failed: %d\n", result);
        }
        OpensteamerLogAvailableModes(displayID);
        return false;
    }

    // On some macOS 26 builds the configuration call reports success before WindowServer has
    // actually switched the framebuffer. Treat the observed logical and pixel sizes as proof.
    for (NSUInteger attempt = 0; attempt < 20; attempt += 1) {
        CGDisplayModeRef appliedMode = CGDisplayCopyDisplayMode(displayID);
        bool didApply = appliedMode != NULL
            && OpensteamerModeMatches(appliedMode, requestedMode);
        if (appliedMode != NULL) {
            CFRelease(appliedMode);
        }
        if (didApply) {
            return true;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    OpensteamerLogAvailableModes(displayID);
    return false;
}

static bool OpensteamerWaitForSoleMainDisplay(CGDirectDisplayID displayID) {
    for (NSUInteger attempt = 0; attempt < 100; attempt += 1) {
        CGDirectDisplayID onlineDisplays[4] = {0};
        uint32_t displayCount = 0;
        bool enumerated = CGGetOnlineDisplayList(
            4,
            onlineDisplays,
            &displayCount
        ) == kCGErrorSuccess;
        CGRect bounds = CGDisplayBounds(displayID);
        if (enumerated && displayCount == 1 && onlineDisplays[0] == displayID
            && CGMainDisplayID() == displayID
            && CGDisplayIsOnline(displayID) && CGDisplayIsActive(displayID)
            && CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay
            && bounds.origin.x == 0 && bounds.origin.y == 0) {
            return true;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    return false;
}

static id OpensteamerInitializeMode(
    Class modeClass,
    NSUInteger width,
    NSUInteger height,
    CGFloat refreshRate
) {
    id allocated = [modeClass alloc];
    typedef id (*InitializeModeFunction)(id, SEL, NSUInteger, NSUInteger, CGFloat);
    return ((InitializeModeFunction)objc_msgSend)(
        allocated,
        sel_registerName("initWithWidth:height:refreshRate:"),
        width,
        height,
        refreshRate
    );
}

static id OpensteamerInitializeDisplay(Class displayClass, id descriptor) {
    id allocated = [displayClass alloc];
    typedef id (*InitializeDisplayFunction)(id, SEL, id);
    return ((InitializeDisplayFunction)objc_msgSend)(
        allocated,
        sel_registerName("initWithDescriptor:"),
        descriptor
    );
}

static void OpensteamerSetObject(id object, const char *selectorName, id value) {
    typedef void (*SetObjectFunction)(id, SEL, id);
    ((SetObjectFunction)objc_msgSend)(object, sel_registerName(selectorName), value);
}

static void OpensteamerSetQueue(
    id object,
    const char *selectorName,
    dispatch_queue_t value
) {
    typedef void (*SetQueueFunction)(id, SEL, dispatch_queue_t);
    ((SetQueueFunction)objc_msgSend)(object, sel_registerName(selectorName), value);
}

static void OpensteamerSetUnsignedInt(
    id object,
    const char *selectorName,
    unsigned int value
) {
    typedef void (*SetUnsignedIntFunction)(id, SEL, unsigned int);
    ((SetUnsignedIntFunction)objc_msgSend)(object, sel_registerName(selectorName), value);
}

static void OpensteamerSetSize(id object, const char *selectorName, CGSize value) {
    typedef void (*SetSizeFunction)(id, SEL, CGSize);
    ((SetSizeFunction)objc_msgSend)(object, sel_registerName(selectorName), value);
}

static CGDirectDisplayID OpensteamerDisplayID(id display) {
    typedef CGDirectDisplayID (*DisplayIDFunction)(id, SEL);
    return ((DisplayIDFunction)objc_msgSend)(
        display,
        sel_registerName("displayID")
    );
}

static bool OpensteamerApplySettings(id display, id settings) {
    typedef BOOL (*ApplySettingsFunction)(id, SEL, id);
    return ((ApplySettingsFunction)objc_msgSend)(
        display,
        sel_registerName("applySettings:"),
        settings
    );
}

static bool OpensteamerWaitUntilDisplayIsOffline(CGDirectDisplayID displayID) {
    for (NSUInteger attempt = 0; attempt < 60; attempt += 1) {
        if (displayID == kCGNullDirectDisplay || !CGDisplayIsOnline(displayID)) {
            return true;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    return false;
}

bool OpensteamerVirtualDisplayWaitUntilOffline(CGDirectDisplayID displayID) {
    return OpensteamerWaitUntilDisplayIsOffline(displayID);
}

static void OpensteamerRetireRejectedDisplay(
    id __strong *display,
    CGDirectDisplayID displayID
) {
    *display = nil;
    OpensteamerWaitUntilDisplayIsOffline(displayID);
}

OpensteamerVirtualDisplayHandle *OpensteamerVirtualDisplayCreate(
    const char *name,
    uint32_t vendorID,
    uint32_t productID,
    uint32_t serialNumber,
    uint32_t maximumWidth,
    uint32_t maximumHeight,
    double physicalWidthMillimeters,
    double physicalHeightMillimeters,
    uint32_t displaySettingsHiDPI,
    const OpensteamerVirtualDisplayMode *modes,
    size_t modeCount,
    const OpensteamerVirtualDisplayResolvedMode *requiredResolvedModes,
    size_t requiredResolvedModeCount,
    CGDirectDisplayID *displayID,
    OpensteamerVirtualDisplayStatus *status
) {
    if (status != NULL) {
        *status = OpensteamerVirtualDisplayStatusInvalidConfiguration;
    }
    if (displayID != NULL) {
        *displayID = kCGNullDirectDisplay;
    }
    if (name == NULL || name[0] == '\0' || vendorID == 0 || productID == 0
        || serialNumber == 0 || maximumWidth == 0 || maximumHeight == 0
        || !isfinite(physicalWidthMillimeters) || physicalWidthMillimeters <= 0
        || !isfinite(physicalHeightMillimeters) || physicalHeightMillimeters <= 0
        || displaySettingsHiDPI == 0 || displaySettingsHiDPI > 4
        || modes == NULL || modeCount == 0
        || requiredResolvedModes == NULL || requiredResolvedModeCount == 0
        || displayID == NULL || status == NULL) {
        return NULL;
    }
    if (!OpensteamerVirtualDisplayClassesAreAvailable()) {
        *status = OpensteamerVirtualDisplayStatusRuntimeUnavailable;
        return NULL;
    }

    @autoreleasepool {
        NSString *displayName = [[NSString alloc] initWithUTF8String:name];
        if (displayName == nil || displayName.length == 0) {
            *status = OpensteamerVirtualDisplayStatusInvalidConfiguration;
            return NULL;
        }

        Class displayClass = OpensteamerPrivateClass(@"CGVirtualDisplay");
        Class descriptorClass = OpensteamerPrivateClass(@"CGVirtualDisplayDescriptor");
        Class modeClass = OpensteamerPrivateClass(@"CGVirtualDisplayMode");
        Class settingsClass = OpensteamerPrivateClass(@"CGVirtualDisplaySettings");
        NSMutableArray *nativeModes = [[NSMutableArray alloc] initWithCapacity:modeCount];
        for (size_t index = 0; index < modeCount; index += 1) {
            OpensteamerVirtualDisplayMode mode = modes[index];
            if (mode.logicalWidth == 0 || mode.logicalHeight == 0
                || mode.logicalWidth > maximumWidth || mode.logicalHeight > maximumHeight
                || !isfinite(mode.refreshRate) || mode.refreshRate <= 0) {
                *status = OpensteamerVirtualDisplayStatusInvalidConfiguration;
                return NULL;
            }
            id nativeMode = OpensteamerInitializeMode(
                modeClass,
                mode.logicalWidth,
                mode.logicalHeight,
                mode.refreshRate
            );
            if (nativeMode == nil) {
                *status = OpensteamerVirtualDisplayStatusCreationFailed;
                return NULL;
            }
            [nativeModes addObject:nativeMode];
        }
        for (size_t index = 0; index < requiredResolvedModeCount; index += 1) {
            OpensteamerVirtualDisplayResolvedMode mode = requiredResolvedModes[index];
            if (mode.logicalWidth == 0 || mode.logicalHeight == 0
                || mode.pixelWidth == 0 || mode.pixelHeight == 0
                || mode.pixelWidth > maximumWidth || mode.pixelHeight > maximumHeight
                || !isfinite(mode.refreshRate) || mode.refreshRate <= 0) {
                *status = OpensteamerVirtualDisplayStatusInvalidConfiguration;
                return NULL;
            }
        }

        id descriptor = [[descriptorClass alloc] init];
        dispatch_queue_t displayQueue = dispatch_queue_create(
            "com.elamin.opensteamer.virtual-display",
            DISPATCH_QUEUE_SERIAL
        );
        OpensteamerSetQueue(descriptor, "setQueue:", displayQueue);
        OpensteamerSetObject(descriptor, "setName:", displayName);
        OpensteamerSetUnsignedInt(descriptor, "setMaxPixelsWide:", maximumWidth);
        OpensteamerSetUnsignedInt(descriptor, "setMaxPixelsHigh:", maximumHeight);
        OpensteamerSetSize(
            descriptor,
            "setSizeInMillimeters:",
            CGSizeMake(physicalWidthMillimeters, physicalHeightMillimeters)
        );
        OpensteamerSetUnsignedInt(descriptor, "setVendorID:", vendorID);
        OpensteamerSetUnsignedInt(descriptor, "setProductID:", productID);
        OpensteamerSetUnsignedInt(descriptor, "setSerialNum:", serialNumber);
        OpensteamerVirtualDisplayTerminationState *terminationState =
            [[OpensteamerVirtualDisplayTerminationState alloc] init];
        void (^terminationHandler)(id, id) = ^(id _, id __) {
            terminationState.terminated = YES;
        };
        OpensteamerSetObject(
            descriptor,
            "setTerminationHandler:",
            terminationHandler
        );

        id display = OpensteamerInitializeDisplay(displayClass, descriptor);
        CGDirectDisplayID resolvedDisplayID = display == nil
            ? kCGNullDirectDisplay
            : OpensteamerDisplayID(display);
        if (display == nil || resolvedDisplayID == kCGNullDirectDisplay) {
            *status = OpensteamerVirtualDisplayStatusCreationFailed;
            return NULL;
        }

        id settings = [[settingsClass alloc] init];
        OpensteamerSetUnsignedInt(settings, "setHiDPI:", displaySettingsHiDPI);
        OpensteamerSetObject(settings, "setModes:", nativeModes);
        if (!OpensteamerApplySettings(display, settings)) {
            *status = OpensteamerVirtualDisplayStatusSettingsRejected;
            OpensteamerRetireRejectedDisplay(&display, resolvedDisplayID);
            return NULL;
        }
        if (!OpensteamerAllRequestedModesAreAvailable(
                resolvedDisplayID,
                requiredResolvedModes,
                requiredResolvedModeCount
            )) {
            *status = OpensteamerVirtualDisplayStatusModesUnavailable;
            OpensteamerRetireRejectedDisplay(&display, resolvedDisplayID);
            return NULL;
        }
        if (!OpensteamerSelectInitialMode(
                resolvedDisplayID,
                requiredResolvedModes[0]
            )) {
            *status = OpensteamerVirtualDisplayStatusModeSelectionFailed;
            OpensteamerRetireRejectedDisplay(&display, resolvedDisplayID);
            return NULL;
        }
        if (!OpensteamerWaitForSoleMainDisplay(resolvedDisplayID)) {
            *status = OpensteamerVirtualDisplayStatusUnsafeArrangement;
            OpensteamerRetireRejectedDisplay(&display, resolvedDisplayID);
            return NULL;
        }
        // The headless placeholder disappears asynchronously. Re-prove the complete mode set and
        // preserved starting mapping after the replacement is the settled sole main display.
        if (!OpensteamerAllRequestedModesAreAvailable(
                resolvedDisplayID,
                requiredResolvedModes,
                requiredResolvedModeCount
            )) {
            *status = OpensteamerVirtualDisplayStatusModesUnavailable;
            OpensteamerRetireRejectedDisplay(&display, resolvedDisplayID);
            return NULL;
        }
        if (!OpensteamerSelectInitialMode(
                resolvedDisplayID,
                requiredResolvedModes[0]
            )) {
            *status = OpensteamerVirtualDisplayStatusModeSelectionFailed;
            OpensteamerRetireRejectedDisplay(&display, resolvedDisplayID);
            return NULL;
        }

        OpensteamerVirtualDisplayHandle *handle = calloc(1, sizeof(*handle));
        if (handle == NULL) {
            *status = OpensteamerVirtualDisplayStatusAllocationFailed;
            OpensteamerRetireRejectedDisplay(&display, resolvedDisplayID);
            return NULL;
        }
        handle->retainedDisplay = (__bridge_retained void *)display;
        handle->retainedTerminationState = (__bridge_retained void *)terminationState;
        handle->displayID = resolvedDisplayID;
        *displayID = handle->displayID;
        *status = OpensteamerVirtualDisplayStatusSuccess;
        return handle;
    }
}

bool OpensteamerVirtualDisplayIsAlive(OpensteamerVirtualDisplayHandle *handle) {
    if (handle == NULL || handle->retainedDisplay == NULL
        || handle->retainedTerminationState == NULL
        || handle->displayID == kCGNullDirectDisplay) {
        return false;
    }
    OpensteamerVirtualDisplayTerminationState *terminationState =
        (__bridge OpensteamerVirtualDisplayTerminationState *)
            handle->retainedTerminationState;
    return !terminationState.isTerminated
        && CGDisplayIsOnline(handle->displayID)
        && CGDisplayIsActive(handle->displayID);
}

bool OpensteamerVirtualDisplayDestroy(OpensteamerVirtualDisplayHandle *handle) {
    if (handle == NULL) {
        return true;
    }
    CGDirectDisplayID retiredDisplayID = handle->displayID;
    if (handle->retainedDisplay != NULL) {
        id display = (__bridge_transfer id)handle->retainedDisplay;
        handle->retainedDisplay = NULL;
        display = nil;
    }
    if (handle->retainedTerminationState != NULL) {
        id terminationState = (__bridge_transfer id)handle->retainedTerminationState;
        handle->retainedTerminationState = NULL;
        terminationState = nil;
    }
    handle->displayID = kCGNullDirectDisplay;
    free(handle);

    return OpensteamerWaitUntilDisplayIsOffline(retiredDisplayID);
}
