# Cue

A free teleprompter for iPhone that **floats over the Camera app and follows your voice**. Open your script, tap **Float Over Camera**, open the Camera app and hit record. The words you've said fade, and the next line stays right under the lens, so you look at the camera instead of reading off a second screen.

Made for people who talk to camera: YouTubers, TikTok and Reels creators, teachers, anyone recording a pitch or a talk.

- **Free and open source** (MIT license).
- **Private.** Your voice is turned into text on the iPhone itself and never leaves it. No account, no ads, no tracking. See [PRIVACY.md](PRIVACY.md).
- **Keeps up with you.** Skip a sentence and it catches up. Stumble and start again, and it goes back with you. Ad-lib for a bit and it waits.

---

## What it does

- **Three ways to scroll.** *Voice* follows what you say. *Tilt* scrolls when you tip the phone (top away from you is forward). *Constant* scrolls at a steady speed you choose.
- **Voice commands** while you record: "go back", "back two lines", "skip ahead", "next sentence", "back to the top", "pause prompter", "resume prompter", "next point".
- **Talking points.** Write one point per line next to your script. Show them with the script or on their own, and they light up as you talk about them.
- **Floating window** over the Camera app (or any other app), shaped for upright or landscape recording. Pinch it to full width and drag it right under the front camera.
- **Your look.** Text size, margins, line spacing, where the current line sits, and whether spoken words darken.

## What you need

- An **iPhone** with iOS 17 or newer. iOS 26 or newer follows your voice fastest.
- A **Mac** with **Xcode 26 or newer** (free on the Mac App Store), to put the app on your phone.
- A free **Apple ID**. A paid Apple Developer account works too, but isn't needed.

Cue isn't on the App Store, so for now you install it from your Mac with Xcode. It takes about 15 minutes the first time, and you don't have to write any code.

## Install it

1. **Download** this project: click the green **Code** button at the top of this page, then **Download ZIP**, and unzip it. Or clone it with git.
2. Install **Xcode** from the Mac App Store, open it once, and let it finish installing what it needs. When it asks which platforms you want, tick **iOS**.
3. Double-click **`Cue.xcodeproj`** in the downloaded folder. Xcode opens the project.
4. Sign in with your Apple ID: **Xcode → Settings → Apple Accounts → +**.
5. In the left column, click the blue **Cue** project icon, then the **Cue** target, then the **Signing & Capabilities** tab. Under **Team**, choose your name (Personal Team).
6. Still on that tab, change **Bundle Identifier** from `com.example.cue` to something only you use, for example `com.yourname.cue`. Apple requires every app to have its own.
7. Plug in your iPhone with a cable and unlock it. Tap **Trust** if it asks. Pick your iPhone from the device menu at the top of Xcode.
8. Press **⌘R** (or the ▶ button). The first time, your iPhone asks you to turn on **Developer Mode**: go to **Settings → Privacy & Security → Developer Mode**, turn it on and let the phone restart. Then press ⌘R again.
9. If the iPhone says the developer isn't trusted, go to **Settings → General → VPN & Device Management**, tap your Apple ID and tap **Trust**.

Cue opens with a welcome script that shows you how it works. Allow the microphone and speech recognition when it asks.

**With a free Apple ID the app stops opening after 7 days.** Your scripts are kept. Plug the phone in and press ⌘R in Xcode again to renew it for another 7 days. A paid developer account makes that a year.

### Or let your AI install it

If you use an AI coding tool (Claude Code, Cursor, Codex, Windsurf, Copilot and the like), paste this:

> Clone https://github.com/Rickboers/cue, read its AGENTS.md, and help me install the app on my iPhone.

The [AGENTS.md](AGENTS.md) file tells the AI how the project works, how to build it and how to change it safely. It can't click in Xcode or on your phone for you, but it walks you through those steps. You can then ask for changes in plain words, for example:

> Add a voice command "slow down" that lowers the Constant speed.
>
> Make the default text size bigger.

---

## Using it

1. Tap **New** (the pencil icon) to write or paste a script. Add talking points on the **Talking Points** tab if you like.
2. Pick **Voice**, **Tilt** or **Constant** in **Settings** (the gear on the Scripts screen).
3. Tap **Start Prompter**, then **Float Over Camera**. Open the Camera app and record. Cue stays on top.
4. Tap the button on the floating window to go back to Cue.

## Troubleshooting

- **The floating window doesn't appear.** Start it from Cue's **Float Over Camera** button, and check that **Settings → General → Picture in Picture → Start PiP Automatically** is on.
- **It doesn't follow my voice.** Check Cue may use the microphone and speech recognition in **Settings → Privacy & Security**. The first start on iOS 26 downloads Apple's English speech model once, so give it a minute on Wi-Fi.
- **"This iPhone can't recognize speech on the device".** Cue only uses speech recognition that runs on the phone itself, and this iPhone doesn't support that. Use Tilt or Constant instead.
- **Xcode says "Failed to register bundle identifier".** Someone already uses that identifier. Change it to something more unique (step 6).
- **Xcode says "No such module" or the build fails.** Make sure you have Xcode 26 or newer.
- **The app won't open any more.** The 7 days from a free Apple ID ran out. Press ⌘R in Xcode again.

Only English scripts are supported for now.

## How it works

The voice follower lines up the words the speech recognizer hears against your script with a fuzzy match. It understands that "70,000" is said "seventy thousand", forgives misheard and skipped words, and only jumps when it's sure. The floating window is iOS's Picture in Picture, fed with frames Cue draws itself.

| Piece | File |
|---|---|
| Voice following | `Cue/Engine/SpeechAligner.swift` |
| Same text rules for script and speech | `Cue/Engine/TextNormalizer.swift` |
| Voice commands | `Cue/Engine/VoiceCommands.swift` |
| On-device speech, and a language model trained on your script | `Cue/Engine/SpeechFollower.swift`, `Cue/Engine/LiveTranscriber.swift` |
| Tilt to scroll | `Cue/Engine/TiltController.swift` |
| Talking points | `Cue/Engine/PointTracker.swift` |
| Floating window | `Cue/PiP/PiPController.swift`, `Cue/Render/` |
| Screens | `Cue/UI/` |

[AGENTS.md](AGENTS.md) has the full map, the build and test commands, and the rules for changes.

## Contributing

Bug reports and improvements are welcome. Before a pull request, run the voice follower test and build the app (see [AGENTS.md](AGENTS.md)), and try the change on a real iPhone. The rules in AGENTS.md apply to people too.

## License

[MIT](LICENSE). Use it, change it, share it.

Not affiliated with or endorsed by Apple. iPhone and Xcode are trademarks of Apple Inc.
