# opensteamer Virtual Microphone driver

This directory contains the test-first replacement for the incompatible
BlackHole 2ch route. It is a separate Core Audio `AudioServerPlugIn`; it does
not replace, modify, or reuse the installed BlackHole bundle.

The production topology is fixed:

- `opensteamer Virtual Microphone` is visible, input-only, mono Float32 at
  48 kHz, and may be selected only as the default input.
- `opensteamer Virtual Microphone Writer` is hidden, output-only, mono Float32
  at 48 kHz, and cannot be any default device.
- Both endpoints share one lock-free PCM ring and one clock domain.
- Every transition from zero global I/O clients to the first client starts a
  fresh timeline, clears stale PCM by generation, and increments a nonzero
  zero-timestamp seed. A client joining an active timeline preserves that seed.

The driver must pass its direct production-core and plug-in-interface tests in
both endpoint start orders and across repeated complete stops before it is
eligible for installation. A public installed-driver loopback and VPIO
compatibility probe are additional gates; neither substitutes for the final
FaceTime/far-end acceptance call.

The plug-in wrapper is based on Apple's MIT-licensed “Creating an Audio Server
Driver Plug-in” sample. `APPLE_SAMPLE_LICENSE.txt` preserves that notice. No
BlackHole source is incorporated.

## Local verification

Run the core, direct plug-in-interface, and sanitizer suites without loading a
driver:

```sh
make -C macOS/VirtualAudioDriver test test-sanitizers
```

Build and verify a reproducible universal local bundle at a new temporary
path:

```sh
mkdir -p /private/tmp/opensteamer-driver-check
macOS/VirtualAudioDriver/scripts/build-driver.sh \
  /private/tmp/opensteamer-driver-check/OpensteamerVirtualMicrophone.driver
macOS/VirtualAudioDriver/scripts/verify-driver-bundle.sh \
  /private/tmp/opensteamer-driver-check/OpensteamerVirtualMicrophone.driver
```

The local build is deliberately ad hoc signed and is not an installable
production release. Production distribution requires a Developer ID
Application signature for the driver, a Developer ID Installer signature for
its package, notarization, stapling, and the separate journaled host/driver
migration. Do not copy this bundle into `/Library/Audio/Plug-Ins/HAL`, reload
Core Audio, or replace the running host outside that authorized transaction.
