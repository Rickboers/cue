# AGENTS.md

Instructions for AI coding agents (Claude Code, Cursor, Codex, Copilot and others) working in this repository. Humans are welcome to read it too.

## What this is

Cue is an iPhone teleprompter written in Swift and SwiftUI. It floats over the Camera app (using Picture in Picture, fed with frames it draws itself) and scrolls by following the reader's voice, by tilt, or at a constant speed. There are no third-party dependencies, servers or accounts. The minimum is iOS 17, and the voice follower is fastest on iOS 26, where it uses Apple's `SpeechAnalyzer`. It needs the iOS 26 SDK, so Xcode 26 or newer.

The person you're helping may not be a programmer. Explain what you're doing in plain words, avoid jargon, and tell them exactly what to click in Xcode or on their iPhone when something has to happen there.

## Installing it for someone

You can't click in Xcode or on their phone, so do the parts you can and walk them through the rest.

1. Check they're on a Mac and have Xcode 26 or newer: `xcodebuild -version`. If not, they install Xcode from the Mac App Store, open it once and tick iOS when it asks. If `xcodebuild` points at the command line tools only, run `sudo xcode-select -s /Applications/Xcode.app` (they type their password).
2. Get the code: `git clone https://github.com/Rickboers/cue.git` into a folder they'll keep, for example `~/Documents/cue`. Without git, they use **Code → Download ZIP** on GitHub.
3. Check it builds before they touch anything: `xcodebuild -project Cue.xcodeproj -scheme Cue -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
4. Walk them through steps 3 to 9 of the README's "Install it": open `Cue.xcodeproj`, add their Apple ID, choose their Personal Team, change the bundle identifier from `com.example.cue` to their own (for example `com.theirname.cue`), plug in the iPhone, press ⌘R, turn on Developer Mode, and trust the developer under VPN & Device Management.
5. Remind them that with a free Apple ID the app stops opening after 7 days, and pressing ⌘R again renews it.

Leave their team ID and bundle identifier in their local Xcode project. If they want them in `project.yml`, that's fine for their own copy, but never commit them to this repository.

## Building and testing

```bash
# The voice follower test: builds the engine for the Mac and simulates someone reading
swiftc -O -o /tmp/cue-harness Cue/Engine/TextNormalizer.swift Cue/Engine/ScriptDocument.swift \
  Cue/Engine/SpeechAligner.swift Cue/Engine/VoiceCommands.swift Cue/Engine/PointTracker.swift EngineTests/main.swift
/tmp/cue-harness

# The app, for the simulator, without signing
xcodebuild -project Cue.xcodeproj -scheme Cue -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The harness prints numbers rather than pass or fail. It reads a script with misheard words, dropped words, fillers, skipped sentences and restarts. Compare its output before and after a change to the engine. These were the numbers at the first public release, and none of them should get worse:

- `clean read`: ±2 at 100.0% and `end: 358/358` for every seed.
- `10% recognizer noise`: ±2 at 98.9% or better, and `end: 358/358`.
- `Skipping a few words mid-sentence`: `0 not within 6` for every skip length.
- `Never mark words that weren't said`: `moved past it early 0`, `jumped ahead 0` for both the aside and the flickering guess, and `clean read: 356/356`.
- `Hard words the recognizer mishears`: `by the next word 25` out of 25.

Speech recognition, the microphone, Picture in Picture and tilt only work on a real iPhone, not in the simulator. Any change to them has to be tried on a phone, with the Camera app open and recording.

`project.yml` is the source of truth for the Xcode project ([XcodeGen](https://github.com/yonaskolb/XcodeGen), `brew install xcodegen`). After editing it, or adding or removing a Swift file, run `xcodegen generate` and commit the regenerated `Cue.xcodeproj` with it.

## File map

| Path | Job |
|---|---|
| `Cue/App/CueApp.swift` | app entry point |
| `Cue/App/DebugSnapshot.swift` | debug builds only: with the launch argument `-snapshot`, saves a screenshot to Documents every 2 seconds |
| `Cue/Model/Script.swift` | a script, its talking points, the welcome script, and `ScriptStore`, which saves every script to `Documents/scripts.json` |
| `Cue/Model/PrompterSettings.swift` | preferences (mode, speed, text size, tilt…) in `UserDefaults` |
| `Cue/Engine/TextNormalizer.swift` | turns script text and speech into the same tokens ("70,000" → "seventy thousand", "don't" → "dont") plus a phonetic key |
| `Cue/Engine/ScriptDocument.swift` | a script parsed into display words, match tokens, word weights and n-gram indexes |
| `Cue/Engine/SpeechAligner.swift` | the voice follower: fuzzy alignment of what was heard against the script |
| `Cue/Engine/VoiceCommands.swift` | spoken commands ("go back", "skip ahead"…) and the check that a phrase isn't simply part of the script |
| `Cue/Engine/PointTracker.swift` | lights up the talking point being talked about |
| `Cue/Engine/SpeechFollower.swift` | microphone, audio session and speech recognition: `SpeechAnalyzer` on iOS 26, `SFSpeechRecognizer` (on-device only) before that, plus a custom language model built from the script |
| `Cue/Engine/LiveTranscriber.swift` | the iOS 26 `SpeechAnalyzer` wrapper |
| `Cue/Engine/PrompterEngine.swift` | ties it together: position, scrolling, modes and commands |
| `Cue/Engine/TiltController.swift` | tilt to scroll, using Core Motion |
| `Cue/Engine/SpokenMarks.swift` | which words show as said |
| `Cue/Engine/CueLog.swift` | a small diary in `Documents/cue-log.txt` (see Rules) |
| `Cue/PiP/` | the floating window: Picture in Picture fed with rendered frames, and the overlay that keeps it live over the Camera app |
| `Cue/Render/` | draws the prompter text into frames |
| `Cue/UI/` | the SwiftUI screens: library, editor, prompter, settings |
| `EngineTests/main.swift` | the voice follower test harness |
| `project.yml` | XcodeGen spec; generates `Cue.xcodeproj` |

## Rules

Keep these unless the person explicitly asks otherwise.

1. **Nothing leaves the phone.** No analytics, crash reporting, accounts, remote config, ads or third-party SDKs, and no network code. Speech recognition must stay on-device (`requiresOnDeviceRecognition`, or `SpeechAnalyzer`). If on-device recognition isn't available, Cue says so rather than falling back to Apple's servers. The one download is Apple's own speech model, fetched by iOS through `AssetInventory`.
2. **Ask for as little as possible.** The permissions are the microphone, speech recognition and motion, plus the `audio` background mode so it keeps listening while floating over the Camera app. Don't add any without a clear reason, and update `PRIVACY.md` and the usage text in `project.yml` when they change.
3. **The log stays small and on the phone.** `CueLog` may write what happened (interruptions, frame rates) and a few recognized words for debugging the follower. It must never write whole scripts or long transcripts, never be sent anywhere, and stay capped in size.
4. **Never mark words that weren't said.** The follower may wait, but it must not jump ahead on a guess. Check the harness numbers above for every engine change.
5. **No dependencies.** Apple frameworks only.
6. **Never commit personal data**: your own Apple team ID (`DEVELOPMENT_TEAM` stays empty), a bundle identifier with your name in it (it stays `com.example.cue`), real scripts, emails, or file paths from your own machine. `xcuserdata` and `build/` are ignored, so keep them that way.

## Common changes

- **A new voice command:** add phrases to `patterns` in `VoiceCommands.swift`. If it needs a new action, add a case to `VoiceCommand` and handle it in `PrompterEngine.swift`. Add it to the harness's "Commands" section, check that a sentence in the script that contains the phrase isn't treated as a command, and list it in the README.
- **A new setting:** add a property to `PrompterSettings` (with its `UserDefaults` key and default), a control in `SettingsView.swift`, and use it where it applies.
- **Text rules** (how numbers, symbols or contractions are said): `TextNormalizer.swift`. Add an example to the harness's "Normalizer" section.
- **Another language:** the follower uses `en-US` in `SpeechFollower.swift` and `LiveTranscriber.swift`, and `TextNormalizer` spells numbers in English. Both need to change together.

## Checking your work

1. Run the harness and compare it with the numbers above when the engine changed.
2. Build with the `xcodebuild` command above. It must succeed with no new warnings.
3. On a real iPhone, try every mode you touched, with the floating window over the Camera app while recording.
4. Keep the README accurate, and add an entry to `CHANGELOG.md` in the same commit.

## Releasing

Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`, run `xcodegen generate`, add a dated entry to `CHANGELOG.md`, run the checks above, then commit and tag it (`git tag v1.1.0`). For TestFlight or the App Store, set your own team and bundle identifier locally, then **Product → Archive** in Xcode. Don't commit those signing settings.
