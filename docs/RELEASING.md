# Build a macOS release

The user install starts at [DOWNLOAD.md](DOWNLOAD.md). This page is for maintainers. The release builder does not stop or replace an installed app.

## One version, two file names

`RELEASE_VERSION` is the version source for local installs and release builds. Set it to a numeric `major.minor.patch`, such as `0.2.1`, and add reviewed notes under `docs/releases/v<version>.md`.

The default build targets Apple Silicon on macOS 14+. It produces:

| File | Purpose |
|---|---|
| `iriz-<version>-arm64.dmg` | Versioned download for archives and rollback |
| `iriz-macos-arm64.dmg` | Stable filename used by the README button |
| `SHA256SUMS.txt` | SHA-256 of the images and manifest |
| `release-manifest.json` | Source commit, dirty-tree flag, version, signing status and image hashes |

The two images are byte-identical. GitHub supports [a latest-release asset URL](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases), so every published release must retain the stable filename. Never mark a draft as Latest before its assets are complete.

## Build and check locally

Use Xcode 26.6 (build 17F113), its macOS 26 SDK and Swift 6.3.3, matching the release toolchain. The app still targets macOS 14+, but compiling its availability-guarded macOS 26 interface requires the newer SDK. Xcode 26.3 failed to type-check two prompt expressions; a Swift 6 version check alone is not enough. Dependencies come from `Package.resolved`. For a build without a signing certificate or Finder automation:

```bash
swift test --no-parallel
bash scripts/make_release_test.sh --selftest
bash scripts/build_app_test.sh --selftest
ruby scripts/macos_release_workflow_test.rb --selftest
SMLTLK_SIGN_IDENTITY=- IRIZ_DMG_HEADLESS=1 bash scripts/make_release.sh
cd release/dist
shasum -a 256 -c SHA256SUMS.txt
```

`-` means ad-hoc signing, not a verified publisher. The normal local mode uses an existing self-signing certificate and a Finder window with an install arrow. That mode needs Pillow for the background renderer; headless mode does not. Both modes contain the same app and Applications shortcut.

The full test suite includes Russian interface-copy checks and native English/Russian keyboard mapping checks. These need the corresponding test language and enabled Apple input sources; they are not locale-independent unit tests. CI prepares these conditions on its disposable runner. Do not run its setup mode on your own account.

Builds live under `release/build`; output goes to `release/dist`. Both stay out of Git. Do not run the release builder and local installer simultaneously: they share the icon renderer. Scratch and output overrides must stay inside this checkout's `release/` or `.build/`, without symlinks.

The builder checks app and framework architectures, deployment targets, language resources, bundled dependencies, code signatures and the mounted image. Previous output is kept until the new images pass. A failed build leaves its log and staging directory for diagnosis; it detaches only its own mounted image.

For an experimental universal build, set `IRIZ_RELEASE_VARIANTS='arm64 universal'`. Its extra `x86_64` slice is a packaging check, not proof that recognition works on an Intel Mac. Do not advertise it as tested Intel support.

## GitHub Actions

The **macOS release draft** workflow runs manually or on a `v*` tag in this public repository. It is inactive in forks and the private working repository. The tag, when present, must match `RELEASE_VERSION`.

The standard ARM64 `macos-26` runner uses Xcode 26.6, listed in [GitHub's runner image manifest](https://github.com/actions/runner-images/blob/0af81b6d930d02b52941d584bee9214c4bc228c6/images/macos/macos-26-arm64-Readme.md#xcode). The preflight checks the selected Xcode, Swift and macOS SDK before compiling. The runner runs the tests, builds the headless ad-hoc image and uploads exactly four files. A separate job verifies their checksums, version and source commit, then creates a **draft** release. It does not execute repository code with a write token. Existing releases and assets are never overwritten. A draft does not change the download button.

Before testing, the hosted-runner setup enables the built-in English and Russian input sources and sets iriz's own language preference to Russian. It does not select a different active keyboard, change the system language, grant permissions or replace the native keyboard map with a fixture. Setup refuses to write outside a GitHub-hosted macOS runner, and a failed prerequisite stops the build before the tests.

To verify the full build for a version that is already published, use **Run workflow → build_only: true**. This runs the tests, builds and verifies the DMG, and uploads the four files as an Actions artifact. The entire release-writing job is skipped: no draft, tag, asset or Latest change. With the default `false`, an existing release makes the draft job fail without changing it.

A maintainer reviews the draft, the release notes and a clean-machine install, runs the publication checks, then publishes it. Publishing is a separate action. No Apple credentials are required by this workflow and no background updater is installed in the app.

Before publishing, check the DMG after downloading it from the draft: mount it, verify its signature, launch a copied app in English and Chinese, and complete the permissions/model/first-dictation flow. Check the public asset hashes against the local output. Do not report a microphone or Intel test that was not performed.

## Developer ID and notarization

Current public builds are not notarized. A self-signed or ad-hoc signature is not an Apple Developer ID signature. Neither proves that Apple has reviewed the app.

For notarization, first obtain a valid **Developer ID Application** certificate and configure a `notarytool` keychain profile yourself. Do not commit a certificate, private key or password. The builder accepts an existing identity and profile:

```bash
SMLTLK_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
IRIZ_NOTARY_PROFILE=iriz-notary \
bash scripts/make_release.sh
```

This mode sends the app and image to Apple. It signs nested code, the app and DMG, uses a secure timestamp, submits with `notarytool`, staples tickets and checks Gatekeeper. A failure stops the build. Checksums are calculated after stapling. See [Apple's distribution signing guide](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) and [packaging guide](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

Moving that identity into CI requires a separate credentials setup. Follow [GitHub's temporary-keychain workflow](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications), restrict secret access and clean up the keychain. Do not print environment variables or turn on shell tracing around secrets.

## Patterns used here

Reviewed on 2026-09-13:

- [VoiceInk](https://github.com/Beingpax/VoiceInk/blob/main/README.md) puts Download ahead of build instructions and retains a stable DMG filename. iriz follows that separation.
- [Handy](https://github.com/cjpais/Handy/blob/main/README.md) distinguishes hardware downloads and explains permissions and local models. iriz names its tested platform and the separate model download.
- [Whispering's v7.11.0 guide](https://github.com/EpicenterHQ/epicenter/blob/v7.11.0/apps/whispering/README.md) makes model installation a step before recording. This is a versioned reference, not a description of its current main branch.

The shared visual identity remains in place. Download clarity, first-run instructions, checksums and rollback instructions answer the practical questions a desktop app installer brings to the page.
