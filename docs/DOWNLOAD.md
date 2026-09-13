# Install iriz on macOS

[Русский](DOWNLOAD.ru.md) · [简体中文](DOWNLOAD.zh.md) · [README](../README.md)

[![Download for macOS](https://img.shields.io/badge/Download%20for%20macOS-111111?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/zarubinvibe/iriz/releases/latest/download/iriz-macos-arm64.dmg)

This download needs an Apple Silicon Mac (M1 or newer) and macOS 14 or newer. This download does not support Intel Macs. The app is free under MIT; you do not need an account, API key, Xcode or Terminal. The default speech model downloads separately, about 500 MB. Allow extra disk space for its temporary download and installation.

## First launch

<img src="assets/pantheon/doc-onboarding.png" alt="Iris guides a gold voice ribbon onto a marble tablet beside the family column" width="100%">

1. Open the DMG and drag **iriz** onto **Applications**. Eject the disk image. Launch iriz from Applications, not from the mounted image.
2. This release is self-signed, **not notarized by Apple**. macOS cannot verify its publisher. If you trust this repository and have checked the download, try opening the app, then use System Settings → Privacy & Security → Open Anyway. Read [Apple's explanation](https://support.apple.com/en-us/102445). Do not disable Gatekeeper or override a malware warning.
3. After the welcome, choose **Download and install Parakeet** on the model step. Parakeet downloads over the internet, about 500 MB. iriz installs and selects it automatically. The screen shows progress and offers **Try again** after an error. Keep the Mac online until it says the model is ready; the DMG does not include the model.
4. Continue through the onboarding permissions for Microphone, Accessibility and Input Monitoring. They let iriz hear your voice, insert text and respond to the dictation key. Reopen the app if macOS asks you to. You can complete these steps while the model downloads; wait for readiness before dictating.
5. Focus an empty text field. Press the dictation key shown in onboarding (right Command by default), say a short sentence, then press it again. The text should appear in that field.

If you skip the model step, layout repair still works, but dictation needs a model. Open **iriz → Settings → Dictation → Download Parakeet model…** to return to model setup. If a model is already installed, the button reads **Set up speech recognition…**. Parakeet is the only model the app installs automatically. The recognition picker also lists other engines, but their model files need separate installation, which this guide does not cover. Parakeet does not recognize Chinese. Interface language and speech language are separate settings.

## If something stops

No model or a failed download: return to **Settings → Dictation**, reopen model setup and retry. Check internet access and free disk space. No sound: check microphone permission and the selected input. No pasted text: check Accessibility; the transcript remains available in the overlay or history. A shortcut that does nothing usually needs Input Monitoring or a different key.

For help, open an [issue](https://github.com/zarubinvibe/iriz/issues) with the app version, macOS version, chip and steps that failed. Do not attach private recordings, transcripts or full logs without inspecting them.

## Update or go back

Read the [release notes](https://github.com/zarubinvibe/iriz/releases/latest), download the new DMG and quit iriz before replacing the app in Applications. Keep the previous app or its DMG until the new one works. Models, preferences and history live outside the app bundle and are not removed by replacing it. macOS may ask you to grant permissions again after a signature change.

There is no background updater. The download button follows the latest published release; unfinished drafts do not replace it. To go back, quit iriz and restore the previous app. Back up local data before trying an older version: a future release may change its storage format.

## Verify the download

The release includes **SHA256SUMS.txt** and **release-manifest.json** (version, architectures and signing status). Compare the DMG's SHA-256 with the entry for its exact filename:

```bash
shasum -a 256 ~/Downloads/iriz-macos-arm64.dmg
```

A matching checksum detects corruption; it does not replace Apple's publisher verification. For building and releasing from source, see [RELEASING.md](RELEASING.md). The [full walkthrough](ONBOARDING.md) explains the other app surfaces.
