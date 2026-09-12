# The conversation at the first install

<!-- owner-greeting:start -->

<p align="center"><img src="assets/pantheon/doc-onboarding.png" alt="Iris sets a tablet on a low table by a column, the gold ribbon of voice settles into the carved groove" width="100%"></p>

Hello. I am Fil, a lawyer who vibe-codes, and I wrote iriz.

From here an agent takes over. It will tell you what it is about to do BEFORE it does it, and
name the price of every step: what appears on the disk, where the time goes, where you have a
choice. If something does not suit you, say so right in the chat. A step can be skipped.

One promise this whole thing was built for: the audio of your speech never leaves the machine.
You download the speech model over the network by pressing a button.

<!-- owner-greeting:end -->

## Step 1: look at what you are running

**What I do:** check the macOS version, the processor, and whether Xcode with Swift 6 is here.

**Why:** iriz lives on macOS 14 and newer. The glass plate and real Liquid Glass are macOS 26;
on 14 and 15 the app works, but the plate is drawn the old way. Better to know that now than
after the build.

**What changes on disk:** nothing. This is reading.

**What you get:** an answer whether we go on, and which visual branch you land on.

**Fork:** no Xcode is not a problem. Take the ready disk image from the Releases page and we
skip the build steps.

## Step 2: bring the sources in

**What I do:** clone the repository into a folder you name, or unpack the ZIP.

**Why:** everything after this happens inside that folder, and it should sit where you will
find it later.

**What changes on disk:** one folder appears, about 40 MB. Nothing else is written anywhere.

**What you get:** a project tree where you can see `Sources`, `Tests`, `scripts` and `docs`.

## Step 3: build the app

**What I do:** run `bash install.sh`, read its report with you, and only then
`bash install.sh --build`.

**Why:** without the flag the installer installs nothing. It explains what the program is,
looks at what your machine is missing, and runs a self-check of the tree. This is your chance
to stop before anything happens.

**What changes on disk:** the first command changes nothing. The second pulls Swift
dependencies (about 300 MB into `.build`) and puts the finished app into `/Applications`.

**What you get:** an icon in the menu bar at the top right, and the welcome window.

**Fork:** if you would rather not hand over `/Applications`, say so. We build into the project
folder and run it from there.

## Step 4: download the model and grant permissions

**What I do:** take you to the second step of the welcome window, right after the greeting.
Click "Download and install Parakeet". iriz downloads about 500 MB, installs the model and
selects it for recognition. The window shows progress; download time depends on your connection.
While it runs, you can click "Next" and grant the macOS permissions.

**Why:** dictation needs a model. The microphone lets iriz hear you, Accessibility lets it
paste text, and Input Monitoring lets it hear the hotkey. After installation, recognition
runs on your Mac without an internet connection.

**What changes on disk:** the model lands in
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`.
You do not need to move files yourself. macOS stores the permissions in its system database,
not in the app.

**Fork:** "Download later" skips the download. To return, open Settings → Dictation →
"Download Parakeet model…". The trial step also has a "Set up the model" button when the model
is missing. If the download fails, read the reason in the window and click "Try again" after
addressing it. We wait for the model before trying dictation.

**What you get:** once the model is installed and permissions are granted, we test dictation
in the welcome window. Press the key, say a sentence, press again. The text appears in the
trial field.

## Step 5: check that it is all honest

**What I do:** after the model download, run the tests and project gates, show you the output
and point out any skipped checks.

**Why:** the network gate compares the built binary's networking symbols with a baseline.
If the app is running from `/Applications`, it also checks its open sockets at that moment.
Otherwise it skips that check. A snapshot cannot prove the app has never connected to the
network; connections are expected during a model download.

**What changes on disk:** tests update `.build` and write logs. The gates also clean up their
temporary test files.

**What you get:** a report of the checks that ran. Failures and skipped checks stay in the
report; they do not become a promise that everything works.

```bash
bash scripts/verify.sh && bash scripts/offline_binary_gate.sh
```
