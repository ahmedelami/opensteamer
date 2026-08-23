#ifndef OpensteamerVirtualDisplayPrivate_h
#define OpensteamerVirtualDisplayPrivate_h

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OpensteamerVirtualDisplayHandle OpensteamerVirtualDisplayHandle;

typedef struct {
    uint32_t logicalWidth;
    uint32_t logicalHeight;
    double refreshRate;
} OpensteamerVirtualDisplayMode;

typedef struct {
    uint32_t logicalWidth;
    uint32_t logicalHeight;
    uint32_t pixelWidth;
    uint32_t pixelHeight;
    double refreshRate;
} OpensteamerVirtualDisplayResolvedMode;

typedef int32_t OpensteamerVirtualDisplayStatus;

enum {
    OpensteamerVirtualDisplayStatusSuccess = 0,
    OpensteamerVirtualDisplayStatusInvalidConfiguration = 1,
    OpensteamerVirtualDisplayStatusRuntimeUnavailable = 2,
    OpensteamerVirtualDisplayStatusCreationFailed = 3,
    OpensteamerVirtualDisplayStatusSettingsRejected = 4,
    OpensteamerVirtualDisplayStatusAllocationFailed = 5,
    OpensteamerVirtualDisplayStatusModeSelectionFailed = 6,
    OpensteamerVirtualDisplayStatusUnsafeArrangement = 7,
    OpensteamerVirtualDisplayStatusModesUnavailable = 8,
};

bool OpensteamerVirtualDisplayRuntimeIsAvailable(void);

OpensteamerVirtualDisplayHandle * _Nullable OpensteamerVirtualDisplayCreate(
    const char * _Nonnull name,
    uint32_t vendorID,
    uint32_t productID,
    uint32_t serialNumber,
    uint32_t maximumWidth,
    uint32_t maximumHeight,
    double physicalWidthMillimeters,
    double physicalHeightMillimeters,
    uint32_t displaySettingsHiDPI,
    const OpensteamerVirtualDisplayMode * _Nonnull modes,
    size_t modeCount,
    const OpensteamerVirtualDisplayResolvedMode * _Nonnull requiredResolvedModes,
    size_t requiredResolvedModeCount,
    CGDirectDisplayID * _Nonnull displayID,
    OpensteamerVirtualDisplayStatus * _Nonnull status
);

bool OpensteamerVirtualDisplayDestroy(
    OpensteamerVirtualDisplayHandle * _Nullable handle
);

bool OpensteamerVirtualDisplayWaitUntilOffline(CGDirectDisplayID displayID);

bool OpensteamerVirtualDisplayIsAlive(
    OpensteamerVirtualDisplayHandle * _Nullable handle
);

#ifdef __cplusplus
}
#endif

#endif
