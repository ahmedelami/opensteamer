# opensteamer naming and compatibility

The product, repository, app display name, Xcode project, build products, host bundle name,
packages, services, scripts, and documentation use the lowercase name **opensteamer**.

Some pre-rebrand identifiers are intentionally immutable compatibility data rather than branding:

- The production iOS bundle identifier stays `org.example.AudioStreamer` so an App Store or
  TestFlight release remains an update to the installed app and retains its container and default
  Keychain access group.
- The iOS Keychain service stays `org.example.AudioStreamer`, and the macOS host keeps its shipped
  bundle and Keychain identifiers, so activation state, durable pairings, and macOS privacy grants
  survive the rename.
- The deployed v1 WebSocket headers/subprotocols, WebRTC data-channel identifiers, invitation
  checksum domain, and cryptographic transcript labels retain their original bytes. These values
  are authenticated protocol ABI. They may change only behind a negotiated new protocol version
  with mixed-version rollout tests.

Do not “clean up” those legacy literals with a global replacement. They are documented next to
their definitions and covered by compatibility tests. New user-facing names and new unversioned
internal identifiers must use `opensteamer`.
