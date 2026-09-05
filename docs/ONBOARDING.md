# Onboarding

<p align="center"><img src="assets/pantheon/doc-onboarding.png" alt="Iris in white marble sets her tablet on a low table beside the classical column, a gold ribbon of voice ending in the carved groove" width="100%"></p>

This walkthrough assumes you have never installed a menu bar app that listens to your keyboard. Every step says what to type or press and what you should see afterwards. If your screen shows something else, stop at that step: the answer sits in the difference, not further down the page.

You need a Mac on macOS 14 or newer, and about half a gigabyte of free disk for the speech model. Building from source also wants Xcode with Swift 6. Nothing gets installed behind your back at any point.

1. **Get the app. Two doors, either one works.** The short door is the ready disk image from [Releases](https://github.com/zarubinvibe/iriz/releases): download the `.dmg`, open it, drag the icon onto `Applications`. Inside that image sit two objects and an arrow between them, nothing else.

   The long door is the source:

   ```bash
   git clone https://github.com/zarubinvibe/iriz.git ~/iriz
   cd ~/iriz
   bash install.sh
   ```

   You see a short introduction, then a list of what your machine has and what it lacks: `swift`, `python3`, `git`, and the macOS version. Then the tree runs its own selfcheck, `scripts/selfcheck.sh`. Then one line naming the next command. Without a flag the installer compiles nothing and installs nothing, so you can run it before deciding whether you want the product at all. If you want to see the network promise checked rather than stated, run `scripts/offline_binary_gate.sh` on the app built by `install.sh`.

   No Git on the machine? Download the [ZIP](https://github.com/zarubinvibe/iriz/archive/refs/heads/main.zip), unpack it, run the same command inside the folder. Doing any of this for the first time? Open the project in Claude Code and run `/iriz-setup`: the install goes as a conversation, one question at a time.

2. **Build it, if you took the source door.**

   ```bash
   bash install.sh --build
   ```

   You see the build run. The first one pulls dependencies and takes a few minutes. At the end the app lands in `/Applications/iriz.app`, and the script tells you the icon is about to appear in the menu bar. Something you compiled yourself opens on a double click, so skip the next step and go to 4.

3. **Open a downloaded build for the first time.** There is no Apple Developer ID for this project, the build is not notarized, and macOS will refuse to start it. You get either "iriz can't be opened because Apple cannot check it for malicious software" or a nastier line claiming the app is damaged. The file is intact. The wording is the loudest one the system owns.

   Control-click the icon in `Applications`, choose Open, then confirm Open in the dialog. If your macOS does not offer that (Apple dropped the shortcut after 14), go to System Settings, Privacy & Security, scroll to the line about the blocked app and press Open Anyway.

   You see the app start, and you are never asked again.

4. **Walk the introduction window.** It opens by itself on first launch, one thought per screen, a button to move on. It shows you the shape of the thing: press a key, say a sentence, press the key again, and the text appears where the cursor was blinking. In an email, in a chat, in a terminal.

   You also learn where it lives. The icon is at the top right of the screen, near the clock. No dock icon, no main window. History, dictionary and settings all open from that icon.

5. **Start the model download early.** Speech is decoded on your Mac, on the Neural Engine, by Parakeet TDT v3 converted to CoreML. The model is not packed into the image on purpose: it gets updated more often than the app is released, and a fresh one beats a year-old one you carried around. Press the button on this step.

   You see the download begin: around half a gigabyte, roughly five minutes on an ordinary connection. Do not sit and watch it. Keep walking the steps, because the permissions ahead take about the same time.

6. **Microphone.** Press the button on this step and answer the system prompt.

   You see the step switch to granted. Without the microphone nothing is heard, so this one comes first. The sound is never written to disk: it lives exactly as long as it takes to turn it into letters.

7. **Accessibility.** macOS calls this one Accessibility, and pasting text into somebody else's field needs it. The button on this step opens the right list in System Settings. Find iriz there and flip the switch yourself, because the system does not allow the app to do it.

   You see the step turn green when the switch is on. Without it the speech still gets decoded and then has nowhere to go.

8. **Input Monitoring. Read this one before you press.** The system will warn you that the app can see keystrokes in every program, and that is the system's own wording, not a softened version of it. Two things need it: noticing that you pressed the dictation key, and noticing that a word came out in the wrong layout. Keys are read here, on your Mac. Nothing is stored, nothing goes out, and password fields are left alone entirely.

   The button opens System Settings again. Flip the switch next to iriz, and the app restarts itself right after. That is macOS demanding a restart, not a crash.

   You also get the first function for free at this point. Type `ghbdtn` into any field and watch it turn into `привет` on its own, no key pressed.

9. **Say your first sentence.** The next step shows your dictation key and a field to test it in. Press the key, say something out loud, press it again. "Hello, this is a test, can you hear me" is plenty.

   You see the words land in that field a moment later. While this window is open the text goes only there and nowhere else. If pressing the key does nothing, the app tells you straight that it cannot hear the key yet: the Input Monitoring switch did not take, go back a step. If that key is already taken by another program, the same screen lets you pick a different one.

   While dictation runs, the app has no road to the network at all: the switch inside the download library sits at "not allowed" (`DownloadUtils.enforceOffline = true`).

10. **Decide about prompt mode, or leave it alone.** The last two steps of the introduction offer the third function. A separate key hands your raw dictation to an agent command line you already have installed, and what comes back is a framed task instead of a stream of speech. Translation runs the same road: you say a sentence in Russian, the English one lands in the field.

    This is exactly where "everything is computed on your Mac" stops being true, so the mode ships off. It stays off until you turn it on. If no agent is found on your machine, the app says so and moves on: layout repair and dictation never needed one. Settings will let you come back to this later.

11. **If the text did not land.** It is not lost. The plate that shows dictation opens into a panel holding the transcript, and you take it from there.

    Heard a word wrong? Correct it once in the dictionary behind the menu bar icon, and it comes out right from then on. That icon is also where this introduction window, settings and history live, so nothing you walked through is a one-time screen.

## Keeping it current

When a new version comes out, do not clone the project again: open it in Claude Code and run `/iriz-update`. It shows what changed before touching a single file, pulls only fast-forward changes, and re-checks itself afterwards. Your settings, dictionary and history sit outside the project folder, so an update does not reach them.

There is no auto-update inside the app itself, and there will not be one while the build carries no Apple signature. A downloaded build is opened by hand once, as in step 3.

## If this helped

If iriz saved you from retyping a paragraph, give it a star: [https://github.com/zarubinvibe/iriz](https://github.com/zarubinvibe/iriz). It costs a second, and it decides whether anyone else ever finds the project.

Now that you have run it end to end, you are the person who can improve it. The path is short: fork the repository, create a branch, commit your change, push the branch, then open a Pull Request. Do not push to `main` directly, the release gate rejects it.

Something broke instead, or a step above lied to you? Open an issue at [https://github.com/zarubinvibe/iriz/issues](https://github.com/zarubinvibe/iriz/issues) and say what you did and what you saw. A wrong step in this file is a bug like any other.
