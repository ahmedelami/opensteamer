# User-protected legacy AudioStreamer runtime

Status: **PRESERVE AND KEEP USABLE**\
User direction recorded: **2026-07-25**

The user is continuing to use the older iPhone client while opensteamer is
developed. The legacy runtime is intentional, not stale build output. Do not
delete, replace, migrate, move, rename, uninstall, or clean it up without the
user's explicit approval.

## Protected working Mac host

- Installed app: `/Applications/AudioStreamer Host.app`
- Executable:
  `/Applications/AudioStreamer Host.app/Contents/MacOS/CaptureServer`
- Bundle identifier: `com.elamin.AudioStreamer.CaptureServer`
- LaunchAgent label: `com.elamin.audiostreamer.worldwide`
- LaunchAgent plist:
  `/Users/ahmed/Library/LaunchAgents/com.elamin.audiostreamer.worldwide.plist`
- Expected launch arguments:
  `--worldwide --allow-remote-control --duration 0 --verbose`
- Preserved executable SHA-256:
  `1bd5bbe685522f995ee01f52650198753d11344857f883898e29ee7a3f4c80bc`
- Bit-identical recovery copy:
  `/Applications/.audiostreamer-failed-20260720-102747-44276/AudioStreamer Host.app`

The recovery directory's `failed` name does not make it disposable. Do not
delete any `/Applications/.audiostreamer-*` recovery bundles as routine cleanup.

## Separate development copy

- Active checkout: `/Users/ahmed/Documents/Codex/opensteamer`
- Uninstalled build artifact:
  `/Users/ahmed/Documents/Codex/opensteamer/build/opensteamer Host.app`
- Development host bundle identifier:
  `org.example.AudioStreamer.CaptureServer`

Keep the development host uninstalled and offline while the legacy host is in
use. In particular:

1. Do not install anything over `/Applications/AudioStreamer Host.app`.
2. Do not load a new opensteamer host LaunchAgent.
3. Do not run the legacy and development hosts concurrently. This installed
   legacy release uses the `com.elamin...` runtime/Keychain namespace while the
   current development build uses `org.example...`; the development singleton
   lock does not protect against this particular legacy host, so both can run
   and interfere.
4. Do not follow the destructive steps in `HOST_MIGRATION.md` while this hold is
   active.

## Protected iPhone client

The old production iOS app and the new development Release target both use
bundle identifier `com.elamin.AudioStreamer`. Installing the new Release or
TestFlight build can replace the working old client, while the newer code uses a
different Keychain service and may not see its legacy pairing data.

- Do not install a development Release/TestFlight build on the user's iPhone.
- Use the simulator or the separate development Debug bundle
  `org.example.AudioStreamer.dev`.
- Do not remove or reset the old iOS app except when the user explicitly asks.

## Pairing and service operations

Fresh pairing codes for the old client must come from the installed legacy
`AudioStreamer Host.app`, never from the development build. Preserve the stable
Mac identity and the original LaunchAgent plist. Never add
`--reset-worldwide-pairing` to the persistent KeepAlive plist; doing so would
erase the pairing after every restart.

If a future task genuinely requires migration or deletion, pause and ask the
user to explicitly release this preservation hold first.
