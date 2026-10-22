# Wavepod

**Read any podcast. Ask it anything. On your Mac.**

Podcasts are full of things worth keeping: an idea, a number, the exact way a guest put it. But audio is hard to
search, and you can't skim it. Wavepod turns any episode into a transcript you can read, with every speaker named.
It writes a summary in which each point links to the moment it was said. You can ask the episode questions and get
answers with quotes you can click to hear.

Paste a Spotify, Apple Podcasts or YouTube link, and Wavepod does the rest on your Mac. A four-hour episode is
transcribed in about five minutes on an M3. Your audio never leaves your computer.

![Wavepod with an episode open. On the left, the episode with an answer and its quotes, then the summary and its
key points, each with a timestamp. On the right, the transcript with each speaker named. The player is at the
bottom.](docs/images/wavepod.png)

## Why Wavepod

- **Paste any link.** Spotify, Apple Podcasts, YouTube, an RSS feed or a podcast's website. You can also add an
  audio or video file from your Mac.
- **Know who said what.** Wavepod tells the voices apart and names them from the episode itself. Name a voice once
  and Wavepod recognises it in the next episode of that podcast.
- **Get the summary first.** A summary is ready when the transcript is. It's organized under headings, and every
  point links to its moment in the audio.
- **Ask the episode.** "What did they say about pricing?" The answer quotes the transcript, in the language you
  asked in. Click a quote to hear it.
- **Read and listen together.** The transcript follows the audio. Click any timestamp to play from there.
- **Follow your podcasts.** New episodes can be transcribed and summarized while you're away.
- **Private by design.** Transcription runs on your Mac, on Apple Silicon. Answers run on your Mac too, unless you
  choose to use your ChatGPT or Claude plan. Settings › Data and Privacy lists every network request Wavepod makes.
- **Free and open source.** Apache-2.0.

## What you need

- A Mac with **Apple Silicon** (M1 or later).
- **macOS 15** or later.
- About **4 GB of free disk space** for the models. Long episodes and offline downloads need more.
- An internet connection the first time, to download the models, and to fetch episodes.

## Download and install

The first public release is on its way. When it's out, it will be on the
[Releases page](https://github.com/concava/wavepod/releases). Until then, [build Wavepod from source](#build-from-source).

To install a release:

1. Download `Wavepod-<version>.dmg` from the [Releases page](https://github.com/concava/wavepod/releases).
2. Open the `.dmg` and drag **Wavepod** to **Applications**.
3. Open Wavepod from Applications.
4. If macOS says it can't verify Wavepod, the release is a test build that Apple hasn't checked yet (a
   pre-release). Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. Do this once.
   Releases that Apple has checked (notarized) open without this step.

Signed releases update themselves: Wavepod checks for updates and offers to install them. You can also choose
**Wavepod › Check for Updates…**.

## Get started

1. **Download the models.** The first time you open Wavepod, the welcome screen offers two downloads:
   - **Transcription and speakers.** Wavepod needs this to transcribe.
   - **Ask model**, about 2.3 GB. It writes summaries and answers questions on your Mac. You can skip it and add it
     later in Settings › Ask, or use your ChatGPT or Claude plan instead.
2. **Add an episode.** Press **⌘K** and paste a link. You can also drop an audio or video file on the window, or
   press **⌘O**. A podcast's link opens its page, where you can pick an episode or follow the podcast.
3. **Wait a few minutes.** Progress shows on Home and in Settings › Queue. If you quit, a long episode continues
   from where it stopped.
4. **Read, listen and ask.** The episode opens in two cards:
   - **Left:** the episode, the Ask field, your answers and the summary.
   - **Right:** the transcript, or **About** with the show notes. Drag the gap between the cards to resize them.

   Click any timestamp to play from that moment.
5. **Name the speakers.** Click a speaker's name in the transcript to rename them everywhere. Wavepod shows a
   suggested name with its confidence until you confirm it.
6. **Follow podcasts.** Open a podcast and click **Follow**. On **Podcasts**, turn on **Auto-transcribe** to get
   new episodes transcribed and summarized as they come out.

## Good to know

- **Where answers run.** Settings › Ask chooses where questions and summaries go:
  - **On this Mac** (the default). Nothing leaves your computer.
  - **Your ChatGPT plan.** Sign in with your ChatGPT account.
  - **Your Claude plan.** Needs Claude Code or the Claude desktop app, and a separate Wavepod sign-in.

  With a plan, Wavepod sends your question and the transcript text to that company. It never sends audio. Your
  plan's limits apply, and you can set the model and its effort.
- **Keychain.** Wavepod keeps your ChatGPT sign-in in the macOS Keychain. The first time, macOS asks for your Mac
  password. Click **Always Allow** so it doesn't ask again.
- **Languages.** Wavepod transcribes most European languages, including English, Spanish and Catalan.
- **What it can't get.** Wavepod can't download Spotify-exclusive episodes, because Spotify doesn't publish their
  audio.
- **YouTube.** The first YouTube link downloads a small, verified helper (`yt-dlp`) that reads the video's details.
- **Battery.** On battery, transcription pauses below 20 % and continues at 25 % or when you plug in. Low Power
  Mode always pauses it.
- **Background checks.** If you turn on **Check podcasts in the background** (Settings › General), keep Wavepod in
  Applications. The checker runs from inside the app, also when Wavepod is closed.
- **Reading.** Settings › General sets the theme, the text size, and the font and size of everything you read.
- **Your data.** Everything is in `~/Library/Application Support/wavepod`. Settings › Data and Privacy shows the
  50 newest network requests, and **Download All…** saves the full list.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘K | Search, or paste a link |
| ⌘J | Ask this episode |
| ⌘O | Add an audio or video file |
| ⌘1 / ⌘2 | Transcript / About |
| ⌘↩ | Play or pause |
| ⌘← / ⌘→ | Back or forward 15 seconds |
| ⌘] / ⌘\ | Faster / normal speed |
| ⌥⌘F | Follow playback in the transcript |
| ⌘+ / ⌘− / ⌘0 | Bigger, smaller or actual text size |
| ⇧⌘D | Cycle system, light and dark |
| ⌘R | Check followed podcasts for new episodes (on Podcasts) |
| ⌘, | Settings |

The play/pause key on your keyboard and headphones also controls Wavepod.

## Build from source

The first build takes about ten minutes.

**You need**

- A current **Xcode** from the App Store, opened once so it finishes installing its components.
- [Homebrew](https://brew.sh), for XcodeGen.
- About 6 GB of free disk space for the build, plus the models.

**Build and run**

```sh
brew install xcodegen
git clone https://github.com/concava/wavepod.git
cd wavepod
xcodegen generate
open wavepod.xcodeproj
```

In Xcode, choose the **wavepod** scheme and **My Mac**, then press **⌘R**.

To build without opening Xcode and keep the app in Applications:

```sh
xcodebuild -project wavepod.xcodeproj -scheme wavepod -configuration Debug -derivedDataPath build/dd -quiet build
cp -R build/dd/Build/Products/Debug/Wavepod.app /Applications/
```

A build from source is signed only for your Mac. macOS treats each new build as a new app, so the Keychain asks for
your password again after each build. To stop that, add your Apple ID in **Xcode › Settings › Accounts** and sign
the build with your team.

## Documentation

- [How Wavepod works](docs/architecture.md): the processes, modules, the path of an episode, storage and privacy.
- [Developing Wavepod](docs/development.md): build, tests, the evaluation set and how to make a release.
- [Decisions](docs/decisions/README.md): why things are the way they are, with the evidence.

License: [Apache-2.0](LICENSE).
