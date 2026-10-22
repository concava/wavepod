# Wavepod

A private, podcast-native transcription app for macOS. Paste a podcast link or drop an audio or video file and get
a transcript with speakers named that you can read, listen to, search and ask questions about. All of it runs on
your Mac.

![Wavepod showing an episode: the podcast on the left, the summary and an answer with timestamped quotes in the
middle, and the transcript with named speakers on the right](docs/images/wavepod.png)

- **Any link.** Spotify, Apple Podcasts, YouTube, an RSS feed or a show's website, or a local audio or video file.
- **Speakers by name.** Voices are told apart and named from the episode itself; a name you confirm is
  remembered for that show.
- **A summary, automatically.** Written when a transcription finishes, on this Mac or your ChatGPT or Claude
  plan, every point linked to the moment it was said.
- **Ask the episode.** Questions are answered from the whole transcript with quotes you can click to hear.
- **Follow podcasts.** New episodes can be transcribed, summarized and downloaded by themselves.
- **Private.** Audio and transcripts stay on this Mac. Settings › Data and Privacy lists every network request
  the app has made.

## Install

Wavepod has no signed download yet, so you build it from source. The first build takes about ten minutes.

**You need**

- A Mac with Apple Silicon (M1 or later) running **macOS 15 or later**.
- A current **Xcode** from the App Store (tested with Xcode 27), opened once so it finishes installing its
  components.
- [Homebrew](https://brew.sh), for XcodeGen.
- About 10 GB of free disk space: roughly 6 GB for the build and 3 GB for the models.

**Build and run**

```sh
brew install xcodegen
git clone https://github.com/concava/wavepod.git
cd wavepod
xcodegen generate
open wavepod.xcodeproj
```

In Xcode, choose the **Wavepod** scheme and **My Mac**, then press **⌘R**.

To build without opening Xcode and keep the app in Applications:

```sh
xcodebuild -project wavepod.xcodeproj -scheme wavepod -configuration Debug -derivedDataPath build/dd -quiet build
cp -R build/dd/Build/Products/Debug/Wavepod.app /Applications/
```

Keep the app in one place once you follow podcasts: the background feed checker runs from inside it.

## How to use it

1. **First launch.** A short welcome asks to download the models once:
   - **Transcription and speakers** is needed to transcribe.
   - **Ask and summaries** (about 2.3 GB) writes summaries and answers questions. You can add it later in
     Settings › Models.
2. **Add an episode.** Press **⌘K** and paste a link, or drop an audio or video file on the window (**⌘O** opens
   one). A show's link, rather than an episode's, opens the show on the Podcasts page. Progress shows on Home, and
   a long episode resumes where it stopped if you quit.
3. **Read and listen.** The episode opens as two cards:
   - **Left:** the episode, with its podcast's menu (other episodes, All Episodes and Follow), the Ask field,
     answers and the summary.
   - **Right:** the transcript or details. Close it to read the episode alone.

   Click any timestamp to play from that moment.
4. **Name the speakers.** Click a speaker's name in the transcript to rename them everywhere. Suggested names show
   a confidence until you confirm them.
5. **Ask.** Type a question in the middle card's field (**⌘J**). The answer quotes the transcript, in the language
   you asked in. Answers run on this Mac by default. Settings › Ask can use your ChatGPT or Claude plan instead,
   which sends the question and transcript text (never audio) to that provider. Claude needs a current Claude Code
   installation and a separate Wavepod sign-in.
6. **Follow podcasts.** On **Podcasts**, each show you follow lists its five newest episodes. Turn on
   **Auto-transcribe** to have new episodes transcribed and summarized as they come out. The ⋯ menu sets offline
   downloads, how many downloads to keep, and Unfollow. **⌘R** checks for new episodes now.
7. **Settings** (**⌘,**) holds the theme, text size, transcription engine, the queue, models, followed podcasts
   and the privacy log.

On battery, the queue pauses below 20 % and resumes at 25 % or when you plug in. Low Power Mode always pauses it.

### Keyboard shortcuts

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

## Documentation

- [How Wavepod works](docs/architecture.md): the processes, modules, the path of an episode, storage and privacy.
- [Developing Wavepod](docs/development.md): build, tests, the golden-set evaluation and the release checklist.
- [Decisions](docs/decisions/README.md): why things are the way they are, with the evidence.

License: [Apache-2.0](LICENSE).
