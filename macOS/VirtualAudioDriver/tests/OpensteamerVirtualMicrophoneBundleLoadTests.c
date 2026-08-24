#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include "../include/OpensteamerVirtualMicrophoneDriver.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

typedef void *(*OSVADriverFactoryFunction)(CFAllocatorRef allocator,
                                           CFUUIDRef requested_type_uuid);

static bool OSVACFStringEqualsCString(CFStringRef value,
                                      const char *expected) {
  if (value == NULL || expected == NULL) {
    return false;
  }
  CFStringRef expected_string =
      CFStringCreateWithCString(kCFAllocatorDefault, expected,
                                kCFStringEncodingUTF8);
  if (expected_string == NULL) {
    return false;
  }
  bool equal = CFEqual(value, expected_string);
  CFRelease(expected_string);
  return equal;
}

static bool OSVAValidateDiagnosticSnapshotProperty(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id) {
  AudioObjectPropertyAddress address = {
      .mSelector = kOSVADiagnosticSnapshotProperty,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  if (!(*driver)->HasProperty(driver, device_object_id, 0, &address)) {
    return false;
  }
  AudioObjectPropertyAddress info_address = {
      .mSelector = kAudioObjectPropertyCustomPropertyInfoList,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  if (!(*driver)->HasProperty(driver, device_object_id, 0, &info_address)) {
    return false;
  }
  Boolean settable = true;
  if ((*driver)->IsPropertySettable(driver, device_object_id, 0, &address,
                                    &settable) != noErr ||
      settable) {
    return false;
  }
  UInt32 size = 0;
  if ((*driver)->GetPropertyDataSize(driver, device_object_id, 0, &address, 0,
                                     NULL, &size) != noErr ||
      size != sizeof(CFPropertyListRef)) {
    return false;
  }
  UInt32 info_size = 0;
  AudioServerPlugInCustomPropertyInfo info;
  UInt32 info_used = 0;
  if ((*driver)->GetPropertyDataSize(driver, device_object_id, 0, &info_address,
                                     0, NULL, &info_size) != noErr ||
      info_size != sizeof(info) ||
      (*driver)->GetPropertyData(driver, device_object_id, 0, &info_address, 0,
                                 NULL, (UInt32)sizeof(info), &info_used,
                                 &info) != noErr ||
      info_used != sizeof(info) ||
      info.mSelector != kOSVADiagnosticSnapshotProperty ||
      info.mPropertyDataType !=
          kAudioServerPlugInCustomPropertyDataTypeCFPropertyList ||
      info.mQualifierDataType !=
          kAudioServerPlugInCustomPropertyDataTypeNone) {
    return false;
  }
  CFPropertyListRef property = NULL;
  UInt32 used = 0;
  if ((*driver)->GetPropertyData(driver, device_object_id, 0, &address, 0, NULL,
                                 (UInt32)sizeof(property), &used,
                                 &property) != noErr ||
      used != sizeof(property) || property == NULL ||
      CFGetTypeID(property) != CFDataGetTypeID()) {
    if (property != NULL) {
      CFRelease(property);
    }
    return false;
  }
  CFDataRef data = (CFDataRef)property;
  if (CFDataGetLength(data) != (CFIndex)sizeof(OSVADiagnosticSnapshot)) {
    CFRelease(property);
    return false;
  }
  OSVADiagnosticSnapshot snapshot;
  CFDataGetBytes(data, CFRangeMake(0, CFDataGetLength(data)),
                 (UInt8 *)&snapshot);
  CFRelease(property);
  property = NULL;
  if (snapshot.schema_version != kOSVADiagnosticSnapshotSchemaVersion ||
      snapshot.struct_size != sizeof(snapshot) ||
      snapshot.client_slot_capacity != kOSVADiagnosticClientSlotCapacity ||
      snapshot.driver_instance_generation == 0 ||
      (snapshot.invariant_flags &
       kOSVADiagnosticSnapshotCoreInitialized) == 0 ||
      snapshot.active_client_count != 0 || snapshot.timeline_seed != 0 ||
      snapshot.anchor_host_ticks != 0) {
    return false;
  }
  return (*driver)->SetPropertyData(
             driver, device_object_id, 0, &address, 0, NULL,
             (UInt32)sizeof(property), &property) ==
         kAudioHardwareIllegalOperationError;
}

int main(int argc, char **argv) {
  if (argc != 2 || argv[1] == NULL || argv[1][0] != '/') {
    fprintf(stderr,
            "usage: OpensteamerVirtualMicrophoneBundleLoadTests "
            "/absolute/path/OpensteamerVirtualMicrophone.driver\n");
    return 64;
  }

  CFURLRef bundle_url = CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]),
      true);
  if (bundle_url == NULL) {
    fprintf(stderr, "unable to create driver bundle URL\n");
    return 1;
  }
  CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, bundle_url);
  CFRelease(bundle_url);
  if (bundle == NULL) {
    fprintf(stderr, "unable to create driver CFBundle\n");
    return 1;
  }
  if (!OSVACFStringEqualsCString(
          CFBundleGetIdentifier(bundle),
          "com.elamin.opensteamer.VirtualMicrophoneDriver")) {
    fprintf(stderr, "loaded driver bundle identifier is not exact\n");
    CFRelease(bundle);
    return 1;
  }
  CFErrorRef load_error = NULL;
  if (!CFBundleLoadExecutableAndReturnError(bundle, &load_error)) {
    CFStringRef description =
        load_error == NULL ? NULL : CFErrorCopyDescription(load_error);
    char description_buffer[1024] = "unavailable";
    if (description != NULL) {
      (void)CFStringGetCString(description, description_buffer,
                               sizeof(description_buffer),
                               kCFStringEncodingUTF8);
      CFRelease(description);
    }
    fprintf(stderr, "unable to load driver bundle executable: %s\n",
            description_buffer);
    if (load_error != NULL) {
      CFRelease(load_error);
    }
    CFRelease(bundle);
    return 1;
  }

  void *factory_symbol = CFBundleGetFunctionPointerForName(
      bundle, CFSTR("OpensteamerVirtualMicrophone_Create"));
  OSVADriverFactoryFunction factory = NULL;
  _Static_assert(sizeof(factory) == sizeof(factory_symbol),
                 "Darwin function and data pointers must have equal size");
  memcpy(&factory, &factory_symbol, sizeof(factory));
  if (factory == NULL) {
    fprintf(stderr, "driver factory export is unavailable\n");
    CFBundleUnloadExecutable(bundle);
    CFRelease(bundle);
    return 1;
  }

  CFUUIDRef unsupported_type = CFUUIDCreateFromString(
      kCFAllocatorDefault,
      CFSTR("00000000-0000-0000-0000-000000000001"));
  if (unsupported_type == NULL ||
      factory(kCFAllocatorDefault, unsupported_type) != NULL) {
    fprintf(stderr, "driver factory accepted an unsupported plug-in type\n");
    if (unsupported_type != NULL) {
      CFRelease(unsupported_type);
    }
    CFBundleUnloadExecutable(bundle);
    CFRelease(bundle);
    return 1;
  }
  CFRelease(unsupported_type);

  AudioServerPlugInDriverRef driver = factory(
      kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
  if (driver == NULL || *driver == NULL) {
    fprintf(stderr, "driver factory did not return its production interface\n");
    CFBundleUnloadExecutable(bundle);
    CFRelease(bundle);
    return 1;
  }
  LPVOID queried = NULL;
  HRESULT query_status = (*driver)->QueryInterface(
      driver, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID),
      &queried);
  if (query_status != S_OK || queried != driver) {
    fprintf(stderr, "driver interface QueryInterface contract failed\n");
    CFBundleUnloadExecutable(bundle);
    CFRelease(bundle);
    return 1;
  }
  if ((*driver)->Release(driver) == 0) {
    fprintf(stderr, "driver interface reference accounting underflowed\n");
    CFBundleUnloadExecutable(bundle);
    CFRelease(bundle);
    return 1;
  }

  static const AudioServerPlugInHostInterface diagnostic_test_host = {0};
  if ((*driver)->Initialize(driver, &diagnostic_test_host) != noErr ||
      !OSVAValidateDiagnosticSnapshotProperty(
          driver, kOSVAObjectIDVisibleInputDevice) ||
      !OSVAValidateDiagnosticSnapshotProperty(
          driver, kOSVAObjectIDHiddenWriterDevice)) {
    fprintf(stderr,
            "loaded production driver diagnostic snapshot contract failed\n");
    CFBundleUnloadExecutable(bundle);
    CFRelease(bundle);
    return 1;
  }
  AudioObjectPropertyAddress diagnostic_address = {
      .mSelector = kOSVADiagnosticSnapshotProperty,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  AudioObjectPropertyAddress diagnostic_info_address = {
      .mSelector = kAudioObjectPropertyCustomPropertyInfoList,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  if ((*driver)->HasProperty(driver, kOSVAObjectIDPlugIn, 0,
                             &diagnostic_address) ||
      (*driver)->HasProperty(driver, kOSVAObjectIDVisibleInputStream, 0,
                             &diagnostic_address) ||
      (*driver)->HasProperty(driver, kOSVAObjectIDHiddenWriterStream, 0,
                             &diagnostic_address) ||
      (*driver)->HasProperty(driver, kOSVAObjectIDPlugIn, 0,
                             &diagnostic_info_address) ||
      (*driver)->HasProperty(driver, kOSVAObjectIDVisibleInputStream, 0,
                             &diagnostic_info_address) ||
      (*driver)->HasProperty(driver, kOSVAObjectIDHiddenWriterStream, 0,
                             &diagnostic_info_address)) {
    fprintf(stderr,
            "diagnostic snapshot leaked outside the two device objects\n");
    CFBundleUnloadExecutable(bundle);
    CFRelease(bundle);
    return 1;
  }

  CFBundleUnloadExecutable(bundle);
  CFRelease(bundle);
  puts("PASS: loaded built driver bundle and resolved production interface");
  return 0;
}
