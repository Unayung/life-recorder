# Life Recorder

A native iPhone recorder, a private receiver that transcribes locally, and an optional Claude summarizer that turns each day into a short, readable page on the phone.

- **iPhone app** records about one minute of AAC at a time, drops minutes with no sound in them, and uploads each clip to your receiver over pinned HTTPS.
- **Receiver** (`receiver/receiver.py`) runs on a Mac or a Linux box. It transcribes every clip with whisper.cpp and the [Breeze ASR 25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) model (Taiwanese Mandarin mixed with English terms), keeps one continuous transcript, and deletes the audio once it has been transcribed.
- **Desktop meeting capture** (optional) records both sides of a call on a Mac or Linux desktop while a meeting app holds the microphone, and uploads to the receiver the same way the phone does.
- **Summarizer** (optional, `deploy/omarchy/summarize.sh`) runs every ten minutes. When new speech has been transcribed, it asks Claude Code to update `summaries/<YYYY-MM-DD>.md`, which the phone shows on its "Read your days" page.

No paid transcription service is involved. The summarizer uses your own Claude subscription through the `claude` CLI.

## Setting it up on a Mac

This walks through the whole thing on one Mac: receiver, iPhone app, summarizer, and meeting capture. Run the commands from the repository root.

### 1. Requirements

- macOS on Apple Silicon, with Xcode and an Apple ID signed in to Xcode (Settings › Accounts). A free account works, but the build then expires after 7 days and needs reinstalling.
- iPhone with Developer Mode on (Settings › Privacy & Security › Developer Mode), connected by cable the first time.
- [Homebrew](https://brew.sh), then:

  ```sh
  brew install whisper-cpp ffmpeg xcodegen
  ```

  Homebrew's `whisper-cpp` provides `whisper-cli` with Metal acceleration. `sqlite3` and Python 3 come with macOS and the Xcode command line tools.
- For the summarizer: [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in (run `claude` once interactively). Calendar-based segmentation also needs the Google Calendar connector enabled on that claude.ai account; without it the summarizer still works and splits the day by silence only.

### 2. Download the models

The models stay out of Git (`models/` is ignored):

```sh
mkdir -p models
curl -L -o models/ggml-breeze-asr-25-q5_k.bin \
  https://huggingface.co/shdennlin/breeze-asr-25-ggml/resolve/main/ggml-breeze-asr-25-q5_k.bin
curl -L -o models/ggml-silero-v6.2.0.bin \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin
```

The first is Breeze ASR 25 as a 5-bit quantized GGML file (about 1.1 GB, a good fit for whisper.cpp on a laptop). The second is the Silero voice activity model, which lets whisper skip silence.

### 3. Make the project yours

The source carries the original author's Apple identifiers. Apple only lets one team own a bundle identifier, so change these before building:

| File | What to change |
|---|---|
| `ios/project.yml` | `bundleIdPrefix`, `DEVELOPMENT_TEAM` (your team ID from developer.apple.com › Membership, or Xcode's account list) and `PRODUCT_BUNDLE_IDENTIFIER`, e.g. `com.yourname.liferecorder` |
| `scripts/install-iphone.sh` | `bundle_id` to match the identifier above |
| `ios/LifeRecorder/Info.plist` | the `tail3fdc0b.ts.net` entry under `NSExceptionDomains`: replace it with your own tailnet domain if you use Tailscale Funnel (step 7), or leave it alone for LAN-only use |
| `desktop/capture_mac/Info.plist`, `install.sh`, `main.swift` | the same tailnet domain, the `com.unayung.*` identifiers, and the default receiver URL, only if you install the Mac meeting capture (step 9) |

### 4. Configure and start the receiver

Use `~/.local/share/life-recorder` as the data directory. The summarizer looks there by default.

```sh
mkdir -p ~/.local/share/life-recorder
python3 receiver/setup.py \
  --data-dir ~/.local/share/life-recorder \
  --model "$PWD/models/ggml-breeze-asr-25-q5_k.bin" \
  --vad-model "$PWD/models/ggml-silero-v6.2.0.bin" \
  --vocabulary ~/.local/share/life-recorder/vocabulary.md \
  --language zh --timezone Asia/Taipei \
  --install-agent
```

This creates a random bearer token, a self-signed TLS certificate, and a private pairing page (`pairing.html`) in the data directory. `--install-agent` registers a LaunchAgent so the receiver starts at login, listening on port 8765 for `https://<this Mac>.local:8765`. Logs go to `receiver.log` and `receiver-error.log` in the data directory.

- `--language` defaults to `zh`; pass `auto` for automatic detection.
- `--timezone` sets the dates and hourly markers in the transcript; the database keeps UTC.
- `--url https://host:port` replaces the `.local` address in the pairing page, for example with a Tailscale name (step 7). On the first run with `--install-agent`, the receiver also listens on that port.
- `--prompt "PR, deploy, staging"` adds a fixed vocabulary hint.

The glossary (`--vocabulary`) is how you fix names whisper keeps getting wrong. It is read again before every clip, so edits take effect without a restart, and the phone can edit it too. Only the section whose heading contains `提示詞` (or `prompt`) is sent to whisper; keep it short, under about 200 tokens. The other sections are for the summarizer. A starting point:

```markdown
# Life Recorder glossary

## 提示詞用
Kubernetes, PR, deploy, staging, <names of people and products you mention often>

## Names
- "Jace", "JS" → Jayce

## To confirm
```

Keep the glossary in the data directory and out of the repository: it names real people.

### 5. Build and install the iPhone app

Connect the iPhone, unlock it, and run:

```sh
scripts/install-iphone.sh
```

It regenerates the Xcode project from `ios/project.yml`, picks the connected iPhone (`--device NAME` if several are attached), builds with your team, installs, and launches the app. `--build-only` and `--no-launch` stop earlier. Signing needs the login keychain, so run it from Terminal on an unlocked Mac.

The first time, the iPhone asks you to trust the developer: Settings › General › VPN & Device Management. The app also asks for microphone and local network access; allow both.

You can also open `ios/LifeRecorder.xcodeproj` in Xcode, select the iPhone and press Run.

### 6. Pair the phone

Get `~/.local/share/life-recorder/pairing.html` onto the iPhone (AirDrop it, for example) and tap its link. The app stores the receiver URL, token and certificate pin in the Keychain. Open that page only on your own phone: it holds the token.

Tap the record switch. Within a minute or two clips should arrive, and the transcript grows in `~/.local/share/life-recorder/life.md`.

### 7. Recording away from home (optional)

By default the phone reaches the receiver only on the same Wi-Fi. For cellular uploads, either put the phone on a private VPN with the Mac, or expose the receiver through [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) in TCP passthrough mode, so the phone needs no VPN:

```sh
tailscale funnel --bg --tcp 8443 tcp://127.0.0.1:8765
```

Then rerun the step 4 command with `--url https://<machine>.<tailnet>.ts.net:8443` and without `--install-agent`. That only rewrites the pairing page: the token and certificate are reused, and the receiver keeps listening on 8765. Pair again with the new page. Use passthrough (`--tcp`), not HTTPS Funnel: the app pins the receiver's own certificate, and an HTTPS Funnel would present a Let's Encrypt certificate instead. Funnel only allows ports 443, 8443 and 10000. Add your tailnet domain to the app's `Info.plist` as described in step 3.

### 8. Daily summaries with Claude (optional)

The summarizer is one shell script. It does nothing until a new clip with speech has been transcribed, then runs `claude -p` once for each day that received new speech. Claude reads the inbox with `sqlite3`, checks your calendar, and edits that day's summary file. Claude's tools are restricted to reading, `sqlite3`, the calendar, and editing the summaries and the glossary.

Install the script and write your summary rules:

```sh
cp deploy/omarchy/summarize.sh ~/.local/share/life-recorder/
$EDITOR ~/.local/share/life-recorder/summary-conventions.md
```

The conventions file tells Claude how you want the day written. Claude reads it at the start of every run. For example:

```markdown
- Write in Traditional Chinese, phone-length Markdown: one `## HH:MM Title` section per segment, short bullets.
- Segment by Google Calendar events; snap real start and end to runs of empty clips, since meetings overrun.
- Sections in clock order. Apply the glossary's name fixes; put unsure terms under its "To confirm" section.
- Headphone calls only capture my side; never present them as a full meeting record.
- Desktop captures (device = '<id from desktop-device-id>') hold both sides of a call. Inside a desktop capture window, ignore the phone's copy of the same speech.
- Be discreet with family and medical content: summarize, don't dwell.
```

Run it once by hand so you see it work and approve any Keychain prompt for Claude's credentials:

```sh
~/.local/share/life-recorder/summarize.sh
```

Then schedule it every ten minutes with a LaunchAgent:

```sh
cat > ~/Library/LaunchAgents/life-recorder.summary.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>life-recorder.summary</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/share/life-recorder/summarize.sh</string></array>
  <key>StartInterval</key><integer>600</integer>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/.local/share/life-recorder/summary.log</string>
  <key>StandardErrorPath</key><string>$HOME/.local/share/life-recorder/summary.log</string>
</dict></plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/life-recorder.summary.plist
```

Things to know:

- `summarize.sh 2026-10-05` rebuilds that whole day. Use it after fixing the glossary or when a day looks wrong.
- The script records how far it has summarized in `.summarized-through`. Delete that file to make the next run look at everything uploaded since midnight.
- The day boundary is fixed to Asia/Taipei (`'+8 hours'` in the script and the prompt). Change both if you live elsewhere.
- Environment overrides: `LIFE_RECORDER_DIR` (data directory), `CLAUDE` (path to the CLI), `CONVENTIONS` (rules file).
- Each run that finds new speech is a Claude Code session and counts against your plan's usage.

### 9. Record calls on the Mac (optional)

The phone only hears your side of a headphone call. `desktop/capture_mac` is a small menu-less app that records the microphone plus everything the Mac plays, but only while a meeting app (Edge, Chrome, Slack, Zoom, Teams) holds the microphone, and uploads 60-second clips to the receiver.

It reads the token and certificate from `~/Library/Application Support/LifeRecorder`, so link that to the data directory first:

```sh
ln -s ~/.local/share/life-recorder ~/Library/Application\ Support/LifeRecorder
desktop/capture_mac/install.sh --receiver https://127.0.0.1:8765
```

macOS asks once for microphone and system audio access. Its device ID is written to `desktop-device-id` in the data directory; put it in your summary conventions so Claude knows those clips hold both sides of a call.

## Running the receiver on Linux

The reference deployment runs the receiver, the Linux meeting capture and the summarizer as systemd user services; see [`deploy/omarchy/README.md`](deploy/omarchy/README.md). The differences from the Mac:

- Build whisper.cpp from source with CUDA (`cmake -B build -DGGML_CUDA=1 && cmake --build build -j --config Release`) and pass `--whisper path/to/build/bin/whisper-cli` to the receiver. If the GPU runs out of memory, the receiver retries that clip on the CPU.
- `receiver/setup.py` is macOS-only for now (it calls `scutil` and `launchctl`). Run it once on a Mac and copy `receiver.token`, `receiver.crt` and `receiver.key` into the Linux data directory, then start `receiver.py` directly as in `deploy/omarchy/life-recorder-receiver.service`.
- `desktop/capture_linux.py` records the microphone plus the default speaker monitor through PipeWire while a browser, Slack or Zoom holds the microphone, and records the microphone alone while a game is running.

## Reading days back on the phone

The app's "Read your days" page lists every recorded date and opens one day at a time, at its latest section. It reads `GET /v1/days` and `GET /v1/days/<YYYY-MM-DD>` over the same pinned connection the uploads use, and keeps every day it has loaded on the phone, so a day stays readable while the receiver is offline. A search box looks through the whole archive.

A day shows its summary when one exists, otherwise the raw transcript. The glossary can be edited from the phone as well (`GET`/`PUT /v1/vocabulary`), entry by entry or as plain text.

The pairing token can read transcripts, summaries and the glossary, not just upload audio. Treat it as a key to the transcript itself.

The receiver writes the combined transcript to `life.md` in the data directory. You can move that file anywhere, such as `~/Documents/life.md`, and leave a symlink at the original path.

## Recording behavior

Tap the record switch once. Recording continues while the screen is locked and while other apps are used. If the iPhone reboots or the app is force-quit, iOS requires opening Life Recorder once before the microphone can resume; reopening the app resumes recording on its own. Minutes whose loudest moment never reaches speech level are dropped before upload (the main screen shows how many, and has a switch to keep everything), and a long run of completely silent clips is reported as a fault. Pending audio stays on the phone until the receiver acknowledges it.

The receiver removes common stage-direction markers, subtitle-credit hallucinations (such as Amara.org credits) and highly repetitive hallucinated noise, then writes one continuous document with an hourly marker. This is cleanup, not a guarantee of perfect transcription. Clips that can never be decoded are set aside rather than retried forever.

## Using Codex to reproduce the setup

The accompanying `SKILL.md` is a reusable Codex procedure. Codex can inspect and edit this source, build it with Xcode, and use Apple CoreDevice tooling to install and launch it on a connected iPhone. For visual phone interaction it uses the CUA iPhone Mirroring surface. Codex must not guess or bypass the iPhone passcode; the user handles protected prompts, trust dialogs, Developer Mode, and microphone/local-network approval. Codex should never print or commit runtime tokens, private keys, pairing pages, audio, transcripts, device identifiers, or user-specific paths.

## Security and limits

The connection is HTTPS with certificate pinning and a 256-bit random bearer token. Nothing is exposed to the internet unless you set up Funnel yourself, and then only the authenticated receiver port. The receiver performs the TLS handshake per connection with a timeout, so a client that connects and never speaks cannot stall other uploads.

Anyone who can read the data directory can read the token, the transcripts and the summaries, so keep it private and out of repositories. The summarizer sends transcript text to Claude; leave it off if that is not acceptable for what you record.

## License

MIT. See [LICENSE](LICENSE).
