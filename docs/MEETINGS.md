# Meeting transcripts and minutes

<p align="center"><img src="assets/pantheon/doc-contributing.png" alt="A voice waveform beside a blank tablet: retain the source, then fill the minutes" width="100%"></p>

Open **Settings → Meetings**, install a speech model using the controls on that
page, and drop a Russian-language recording into the queue. A live recording
can also start from the menu bar. Meeting audio is retained; ordinary dictation
does not retain audio.

Before processing, choose local transcription alone or consent to send the
transcript to the selected CLI agent. The dialog names the destination and
model. This is separate from consent for dictation cleanup. Configure the CLI
in **Prompt mode** if it is missing. Provider charges and access limits may
apply. The audio file is not included in the agent request.

## What is saved

The meeting archive contains a copy of the audio, the original recognition
text in Markdown, and an immutable `meeting-source.json`. Each export creates
a new version folder containing:

- `meeting-minutes.docx`: part I, minutes; part II, the full available transcript
  starting on a new page;
- `meeting-data.json`: the exact fields and repeated blocks used for that DOCX;
- `clarifications.txt`: unknown details and checks still needed.

All 38 common fields and seven block types are validated. Every actual card
must contain its required keys. Missing information is marked explicitly;
empty lists do not fabricate attendees, decisions or tasks. The agent is
instructed to separate proposals from agreed decisions; check that distinction
against the recording. The document is never automatically approved.

Local-only processing produces a transcript and an unfilled minutes form.
Choose **Fill minutes** to populate the minutes through the agent later.
If the agent or exporter fails, the saved source stays available. A retry reads
that source without recognizing the audio again, and does not overwrite older
exports. Recent meetings remain accessible after restarting the app. Archives
from older versions without a source snapshot must be imported again to use
the new export.

## Accuracy and limits

The transcript preserves the text returned by the speech engine, including
repetitions and unfinished phrases. This does not make automatic recognition
a human-verified verbatim transcript: compare it with the recording before
relying on names, dates, decisions or assignments.

Only usable timing data from the speech engine becomes a timestamp. Unknown
timing, uncertain speakers and incomplete alignment are explicit. A failed
alignment retains the entire recognition text; it does not discard the tail
or invent timestamps. Speaker labels identify detected voices, not verified
people. An import date is not used as the meeting date, and a complete file
does not prove that the whole meeting was recorded.

Agent requests currently accept up to 120,000 UTF-8 bytes of recognition text.
Larger sources remain saved but are not sent or silently truncated. The agent
response must pass structural and source-evidence checks; at most one repair
request follows an invalid response. Refusal, timeout and cancellation do not
trigger a hidden provider switch.

## Template and privacy

The supplied template, schema and fonts are included in the app. Export does
not require a Desktop folder, Python, an internet download or the source
checkout. The native filler is tested against the package's Python filler.
The original template stays unchanged. PT Serif, page settings, headings and
footer numbering are retained; authoring instructions are removed from the
output. A document reader may substitute fonts if PT Serif is not installed
in that reader's environment; the font files and OFL license are bundled.

Meeting files are stored as plaintext with owner-only file permissions, not
app-level encryption. FileVault provides disk encryption if enabled. The
external agent sees the transcript only after the separate consent step.
Custom CLI configuration may change its actual endpoint. An argument-based
CLI also exposes its prompt to processes running under the same account;
the consent dialog warns about this.

The plain `iriz transcribe` command remains a text-only file transcription
command; the meeting workflow described here is in the app. See the
[resource and packaging contract](MEETING-RESOURCES.md) for build checks.

## Speaker models

The Meetings page has a separate **Download speaker models · 22 MB** button.
This optional download is 21,599,417 bytes across 21 pinned files. Progress,
cancellation and retry are shown in the page. A restart checks the installed
files again; recognition does not silently download them. Without these
models, transcription still works but speakers remain undetermined.

The models are [Speaker Diarization CoreML by FluidInference](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/1ed7a662fdc7109e36d822db793ee6eebdaf8594/README.md),
revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594`. That model card declares
CC BY 4.0 and credits the upstream
[Pyannote Community-1 model](https://huggingface.co/pyannote/speaker-diarization-community-1).
The model license is distinct from the FluidAudio SDK license. The app downloads
the pinned model bytes without modifying them and verifies their sizes and
SHA-256 hashes before publishing the cache. These weights are not bundled
in the app or DMG. The download path does not enable networking in the speech
recognizer and does not upload audio or transcript text.
