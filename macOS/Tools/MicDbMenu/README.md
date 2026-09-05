# Mic dB Menu

Companion utility patch for the always-running `com.ahmed.micdbmenu` app. The
existing AppKit menu extra and status-level overlay are preserved. The original
June 4 utility compiled its source directly from stdin and captured the current
default input continuously, including OpenSteamer's virtual microphone.

The patched utility measures only a verified physical default input. It pins an
input-only AUHAL to that device ID, verifies its UID, transport, topology, and
sample format before starting, then repeats the identity checks after start.
It never changes a default input/output selector. Virtual, aggregate, unknown,
unreadable, and unsupported devices are not captured. Selecting a virtual input
clears previous levels and displays `Virtual`, with an explanation that its
level is unavailable; this is not a virtual microphone audio test.

Independent CoreAudio default/device listeners and a one-second passive poll
remain active when capture is off. Changes release capture and invalidate queued
restarts and old samples. Temporary start failure or missing samples permits
three delayed retries; manual **Restart Audio**, a route change, or five fresh
readings resets that budget. Levels describe captured digital RMS/peak dBFS,
not calibrated acoustic dB SPL. A failed native disposal retains its callback
storage and prevents further capture until the utility is relaunched.

## Verify and build

From this directory:

```sh
swift test
meter_artifact_dir="$(mktemp -d /Volumes/t7/micdbmenu-artifact.XXXXXX)"
bash build-app.sh "$meter_artifact_dir/MicDbMenu.app"
```

The package has no external dependencies. Tests use fake capture objects and
synthetic samples; they do not request microphone access, start audio I/O, or
launch the app. The artifact script builds/signs a new bundle and refuses to
overwrite an existing destination. It does not replace the installed app or
modify its LaunchAgent. Keeping the existing bundle identifier supports the
existing launch configuration, but microphone permission after replacement
still needs to be checked on the actual Mac.

After a separately authorized install, physical validation should confirm:

- A hardware microphone shows fresh levels and keeps the same device UID.
- Switching the default to OpenSteamer releases the meter's HAL client and
  immediately clears the displayed dBFS measurement.
- Switching back to hardware resumes fresh levels without restarting the app.
- Device removal/read failure clears capture; old callbacks cannot restore old levels.

This utility change removes one source of continuous virtual-clock ownership.
Other recording applications may still hold the virtual endpoint open, so it
does not replace the host's guarded clock recovery or prove remote microphone
delivery by itself.
