# Community macOS preview releases

The `lflish/codex-account-switcher` fork publishes `v0.2.0-rc.1` as a GitHub prerelease from `codex/native-quota-release`. It is separate from the upstream unified, signed macOS/Windows stable workflow. This preview is published manually. The inherited stable workflow accepts only numeric stable tags and rejects the prerelease tag before building; its signing secrets and update-feed publication are not used.

The numeric application version is `0.2.0`; the prerelease tag is `v0.2.0-rc.1`. No Windows binary or signed Sparkle feed is published. The archive is ad hoc signed and is not Apple notarized. Do not disable Gatekeeper to treat it as trusted signed distribution.

Build on Apple Silicon:

```sh
APP_DISPLAY_NAME='Codex Account Switcher Community' \
APP_BUNDLE_ID=io.github.lflish.codex-account-switcher \
SWITCHER_DATA_DIRECTORY_NAME='Codex Account Switcher Community' \
SWITCHER_DISABLE_UPDATES=1 SWIFT_BUILD_ARCH=arm64 \
./scripts/package-local-app.sh
```

The bundle uses a directory name resolved against the current user's Application Support directory. It includes no home paths, environment overrides, profiles, tokens or account data. The default Codex home remains the current user's configured home; shared Desktop safety disables background app-server quota refresh and automatic reset. Quota reads use fixed GET endpoints. Explicit switches still require native confirmation and graceful Desktop exit. The Community app does not automatically import another Switcher installation's store.

Before publishing, execute the full Swift Testing suite (require its test summary, see `testing.md`), CoreChecks and Node script tests. Package the tagged commit; verify architecture, resources, version, ad hoc signature and portable configuration. Archive with `ditto --keepParent`, compute SHA-256, then publish a GitHub prerelease with immutable tag and checksum file. Do not overwrite tags/releases, modify `main`, or install over a running application during publication. Local fixtures do not establish a real Desktop account handoff.
