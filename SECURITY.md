# Security

[Русский](SECURITY.ru.md) · [中文](SECURITY.zh.md)

<p align="center"><img src="docs/assets/pantheon/window-wash-source.png" alt="Iris in white marble wiping a pane of glass by a classical column: you can see through, nothing is hidden" width="100%"></p>

## What is actually valuable here

Your speech and your text. Not passwords, not payments — but for a lawyer, a doctor or a
therapist that is worth more than a password: it holds names, amounts, diagnoses and other
people's secrets.

So the line is drawn where you can see it:

- **The audio never leaves the machine.** Recognition runs on your Mac. During dictation the
  network is shut by a switch inside the recognition library, and the switch returns to its
  place even when a download fails.
- **The single trip to the network** is the speech model download, and you start it with a
  button.
- **Only prompt mode sends the transcript out**, only to the agent you picked, and only when
  you pressed its key. The Ollama option sends nothing: it computes on this Mac.
- **Dictations sit on your disk** in the clear with `0600` permissions. Disk encryption is
  FileVault's job, not ours: promising our own encryption on top of the system's would be
  promising twice and delivering neither.

## How this is checked, not promised

A promise in a README is worth nothing until an instrument kicks it:

```bash
bash scripts/offline_binary_gate.sh   # networking symbols in the binary, sockets of the live process
bash scripts/cleanup_privacy_gate.sh  # speech cleanup does not leak into someone else's hands
bash scripts/privacy_tracked_data_gate.sh
bash scripts/verify.sh                # everything together: tests and gates
```

The gates go red when the promise drifts from the code. That is the check.

## If you found a hole

Open an Issue if the hole does not give immediate access to someone's data. If it does, write
privately instead of publicly: `7teenno1@gmail.com`. You will get an answer, and it will be to
the point.

Please do not attach your own dictations to the report. Describe the path — I will reproduce it
on mine.

## What this project does not promise

- No protection against someone already sitting at your Mac under your account.
- No Apple notarization: the build is signed with a self-signed certificate, and macOS will
  honestly warn you about that on the first launch.
- No promise that a third-party agent in prompt mode behaves decently. It is a third party.
  That is exactly why prompt mode is off by default and turned on by you.
