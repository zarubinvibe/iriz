# Meeting-minutes template package inside the app

[English](MEETING-RESOURCES.md) · [Русский](MEETING-RESOURCES.ru.md) · [简体中文](MEETING-RESOURCES.zh.md)

**Result:** the packaged app carries the complete meeting-minutes template, and both builders stop if its required contents fail validation.

The source package is stored unchanged in `Sources/IrizDictate/Resources/MeetingMinutes`. `Package.swift` includes it in `IrizApp_IrizDictate.bundle` through `.copy("Resources/MeetingMinutes")`.

The installed app and the app inside the DMG contain the same path:

```text
iriz.app/Contents/Resources/IrizApp_IrizDictate.bundle/MeetingMinutes/
```

The entire package is copied: the DOCX template, `fields.json`, `data.schema.json`, the manifest, documentation, examples, tests, helper scripts, and PT Serif with its OFL license.

`scripts/build_app.sh` and `scripts/make_release.sh` keep the existing behavior of copying every adjacent SwiftPM bundle. The new required resource does not replace the localized `IrizApp_IrizCore.bundle`.

Both builders stop if the package is missing, contains a symlink, has a required file that is empty or missing, or has a modified template. They repeat the check in the installed candidate and in the mounted DMG.

If a check fails before replacement, the installed app is left unchanged. If it fails after replacement, the existing rollback runs. The release does not enter `dist` until the disk-image checks pass.

SHA-256 of the reference `template.docx`:

```text
8b4ffde7a7d09c6f3450b2de8667334fe79f544157553c3e81d77456b43807ff
```

## Running without the build directory

`MeetingTemplate` looks for the resource relative to the app bundle or the test module. The packaged app does not need a developer's absolute path to `.build` or `Bundle.module`.

`Tests/IrizDictateTests/MeetingDOCXTests.swift` checks a separately copied `.app` whose package exists only in `Contents/Resources`.

DOCX export uses Swift code and the system `/usr/bin/ditto` for the ZIP container. The bundled `scripts/*.py` and `tests/*.py` belong to the source package for manual checks; the app does not run them.

Python is not a runtime dependency of export. The release builder itself still uses Python on the developer's machine or in CI.

## Packaging regressions

```bash
bash scripts/build_app_test.sh --selftest
bash scripts/make_release_test.sh --selftest
```

The mocks use their own temporary directories. They do not use the shared `.build`, sign real code, mount disk images, or access `/Applications`.

The tests cover copying the complete package and rejecting a missing or modified package. Real packaging of the new package and export from a copied app still require a separate check; the green 0.2.1 CI baseline predates this integration and does not confirm either one.

Next: run the two self-tests above before packaging a release.
