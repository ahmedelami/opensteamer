# Migrate an existing Mac host

> **USER-DIRECTED HOLD — DO NOT EXECUTE THIS MIGRATION.**
>
> As of 2026-07-25, the user explicitly requires
> `/Applications/AudioStreamer Host.app` and
> `com.elamin.audiostreamer.worldwide` to remain installed and usable while
> opensteamer is developed separately. Do not stop, move, replace, or delete that
> app/job, and do not install the new host, unless the user later authorizes the
> migration. See [USER_PROTECTED_LEGACY_RUNTIME.md](USER_PROTECTED_LEGACY_RUNTIME.md).
> This hold overrides the removal steps below.

The rebrand changes the LaunchAgent label and installed app path, but deliberately keeps the
signed bundle identifier and Keychain service. That preserves pairing secrets and macOS privacy
grants while preventing the old and new persistent jobs from competing for the same runtime lock.

Before loading `org.example.opensteamer.worldwide`, stop and remove the pre-rebrand job:

```sh
launchctl bootout "gui/$(id -u)/org.example.audiostreamer.worldwide" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/org.example.audiostreamer.worldwide.plist"
if launchctl print "gui/$(id -u)/org.example.audiostreamer.worldwide" >/dev/null 2>&1; then
  echo "The pre-rebrand LaunchAgent is still loaded; stop before continuing." >&2
  exit 1
fi
```

Also quit any host that was started manually from
`/Applications/AudioStreamer Host.app`. Confirm that its `CaptureServer` process is gone before
continuing; do not run the old and new host bundles at the same time. Move that old bundle out of
`/Applications` before installing the renamed host so LaunchServices cannot select between two
apps with the same preserved bundle identifier. Keep it only as an offline backup until the new
deployment passes verification, then remove it. Leaving both bundles in an application-search path
is not a supported migration state.

Then build and install the signed `/Applications/opensteamer Host.app`, customize a local copy of
`macOS/LaunchAgents/org.example.opensteamer.worldwide.plist` by adding `--rendezvous-url` and your
WSS origin to `ProgramArguments`, and bootstrap that installed plist. Do not configure the origin
through a launchd environment section: the deployment oracle rejects such overrides. The stable
bundle identifier is intentional—do not replace it during migration. Run
`verify-mac-host-deployment.sh` with `OPENSTEAMER_HOST_LAUNCH_AGENT_TEMPLATE` pointing to the same
configured local template; it proves that launchd is running the renamed signed bundle and the
exact installed LaunchAgent.
