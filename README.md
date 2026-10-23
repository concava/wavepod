# Wavepod

**Read any podcast, ask it anything. Open-source on your Mac, completely free**

Podcasts contain ideas, numbers and quotes that you want to keep. But you cannot search audio or skim it. Wavepod
makes a transcript of an episode and names each speaker. It writes a summary, and each point links to the moment in
the audio. You can ask the episode a question. The answer quotes the transcript, and you can click a quote to hear it.

Paste a Spotify, Apple Podcasts or YouTube link. Wavepod does all the work on your Mac. On an M3, it transcribes a
four-hour episode in about five minutes. Your audio stays on your Mac.

[![Watch the 30-second Wavepod film: find an episode, transcribe it on your Mac, click a summary point to hear it,
and ask the episode a question.](docs/marketing/launch-30s/wavepod-launch-30s-poster.jpg)](docs/marketing/launch-30s/wavepod-launch-30s.mp4)

▶ [Watch the 30-second film](docs/marketing/launch-30s/wavepod-launch-30s.mp4) (with sound).

![Wavepod with the Acquired episode about Disney open. On the left, the answer to "Why did the Pixar deal matter so
much for Disney?", with its key points. On the right, the transcript with each speaker
named.](docs/marketing/screenshots/04-ask-light.png)

## What Wavepod does

- **Paste any link.** Use a Spotify, Apple Podcasts or YouTube link, an RSS feed or a podcast's website. You can
  also add an audio or video file from your Mac.
- **Know who said what.** Wavepod tells the voices apart and names them from the episode. Name a voice one time.
  Wavepod then recognizes that voice in the next episode of the same podcast.
- **Read the summary first.** The summary is ready when the transcript is ready. Headings organize it, and each
  point links to its moment in the audio.
- **Ask the episode.** For example: "What did they say about pricing?" The answer quotes the transcript, in the
  language of your question. Click a quote to hear it.
- **Read and listen together.** The transcript follows the audio. Click a timestamp to play from that moment.
- **Follow your podcasts.** Wavepod can transcribe and summarize new episodes while you are away.
- **Keep your data private.** Transcription runs on your Mac, on Apple Silicon. Answers also run on your Mac, unless
  you select your ChatGPT or Claude plan. Settings › Data and Privacy lists each network request that Wavepod makes.
- **Free and open source.** The license is Apache-2.0.

## What you need

- A Mac with **Apple Silicon** (M1 or later).
- **macOS 15** or later.
- About **4 GB of free disk space** for the models. Long episodes and offline downloads need more space.
- An internet connection to download the models the first time, and to get episodes.

## Download and install

**[Download Wavepod for Mac](https://github.com/concava/wavepod/releases/latest/download/Wavepod.dmg)** (the latest
release). The [Releases page](https://github.com/concava/wavepod/releases) has the other versions.

1. Download `Wavepod.dmg` from the link above.
2. Open the `.dmg` file and drag **Wavepod** to **Applications**.
3. Open Wavepod from Applications.
4. macOS can show a message that it cannot verify Wavepod. This message means that the release is a test build that
   Apple did not check (notarize). Do these steps one time:
   1. Click **Done**.
   2. Open **System Settings › Privacy & Security**.
   3. Scroll down and click **Open Anyway**.

   A notarized release opens without these steps.

A signed release updates itself. Wavepod looks for updates and offers to install them. You can also select
**Wavepod › Check for Updates…**. A test build does not update itself. To update it, download the new version and
replace the app.

## Get started

1. **Download the models.** The first time you open Wavepod, the welcome screen shows two downloads:
   - **Transcription and speakers.** Wavepod needs this download to transcribe.
   - **Ask model**, about 2.3 GB. It writes summaries and answers questions on your Mac. You can skip it and add it
     later in Settings › Ask. You can also use your ChatGPT or Claude plan.
2. **Add an episode.** Press **⌘K** and paste a link. You can also drop an audio or video file on the window, or
   press **⌘O**. A link to a podcast opens the podcast's page. There, you can select an episode or follow the
   podcast.
3. **Wait a few minutes.** Home and Settings › Queue show the progress. If you quit, Wavepod continues a long episode
   from the point where it stopped.
4. **Read, listen and ask.** The episode opens in two cards:
   - **Left:** the episode, the Ask field, your answers and the summary.
   - **Right:** the transcript, or **About** with the show notes. Drag the gap between the cards to change their
     width.

   Click a timestamp to play from that moment.
5. **Name the speakers.** Click a speaker's name in the transcript to change it everywhere. Until you confirm a name,
   Wavepod shows its suggested name and its confidence.
6. **Follow podcasts.** Open a podcast and click **Follow**. On **Podcasts**, turn on **Auto-transcribe**. Wavepod
   then transcribes and summarizes each new episode when it is published.

## Good to know

- **Where answers run.** In Settings › Ask, you select where questions and summaries go:
  - **On this Mac** (the default). No data leaves your Mac.
  - **Your ChatGPT plan.** Sign in with your ChatGPT account.
  - **Your Claude plan.** You need Claude Code or the Claude desktop app, and a separate Wavepod sign-in.

  With a plan, Wavepod sends your question and the transcript text to that company. It never sends audio. The
  limits of your plan apply. You can set the model and its effort.
- **Keychain.** Wavepod keeps your ChatGPT sign-in in the macOS Keychain. The first time, macOS asks for your Mac
  password. Click **Always Allow**, and macOS does not ask again.
- **Languages.** Wavepod transcribes most European languages, for example English, Spanish and Catalan.
- **Spotify-exclusive episodes.** Wavepod cannot download these episodes, because Spotify does not publish their
  audio.
- **YouTube.** The first YouTube link downloads a small, verified helper (`yt-dlp`). The helper reads the details of
  the video.
- **Battery.** On battery power, transcription stops below 20 %. It starts again at 25 %, or when you connect power.
  Low Power Mode always stops transcription.
- **Background checks.** If you turn on **Check podcasts in the background** (Settings › General), keep Wavepod in
  Applications. The checker runs from the app, also when Wavepod is closed.
- **Reading.** In Settings › General, you set the theme, the text size, and the font and size of the text you read.
- **Your data.** Wavepod keeps all data in `~/Library/Application Support/wavepod`. Settings › Data and Privacy shows
  the 50 newest network requests. **Download All…** saves the full list.

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

The play/pause key on your keyboard and on your headphones also controls Wavepod.

## Build from source

The first build takes about ten minutes.

**You need**

- A current **Xcode** from the App Store. Open it one time, so that it installs its components.
- [Homebrew](https://brew.sh), to install XcodeGen.
- About 6 GB of free disk space for the build, and more for the models.

**Build and run**

```sh
brew install xcodegen
git clone https://github.com/concava/wavepod.git
cd wavepod
xcodegen generate
open wavepod.xcodeproj
```

In Xcode, select the **wavepod** scheme and **My Mac**. Then press **⌘R**.

To build without Xcode and keep the app in Applications:

```sh
xcodebuild -project wavepod.xcodeproj -scheme wavepod -configuration Debug -derivedDataPath build/dd -quiet build
cp -R build/dd/Build/Products/Debug/Wavepod.app /Applications/
```

A build from source is signed only for your Mac. macOS sees each new build as a new app, so the Keychain asks for
your password again after each build. To prevent this, add your Apple ID in **Xcode › Settings › Accounts**. Then
sign the build with your team.

## Documentation

- [How Wavepod works](docs/architecture.md): the processes, the modules, the path of an episode, storage and privacy.
- [Developing Wavepod](docs/development.md): the build, the tests, the evaluation set and how to make a release.
- [Decisions](docs/decisions/README.md): the reasons for the design, with the evidence.

License: [Apache-2.0](LICENSE).
