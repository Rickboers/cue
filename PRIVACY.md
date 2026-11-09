# Privacy

Short version: **Cue collects nothing and sends nothing.** Your scripts and your voice stay on your iPhone.

- **Your voice** is turned into text by Apple's speech recognition running on the iPhone itself. Cue only uses on-device recognition. If an iPhone can't do that, Cue tells you so rather than sending audio to Apple's servers. Audio is never recorded or saved.
- **Your scripts** are saved in one file in Cue's own storage on the phone. They're deleted when you delete the app. If your iPhone backs up to iCloud or a computer, they're part of that backup, like any app's files.
- **A language model** is built from your script, on the phone, so the recognizer knows your words. It's kept in Cue's cache and isn't sent anywhere.
- **A small log** (`cue-log.txt`) records what the system did, such as audio interruptions and the floating window's frame rate, and a few recently heard words when the follower moves. It stays in Cue's storage, is kept under about 400 KB and is never sent anywhere. Only you can read it, by downloading the app's data from Xcode.
- **Your settings** (mode, speed, text size and so on) are saved on the phone.
- **No network.** Cue has no servers, analytics, ads, trackers or third-party code. On iOS 26 and newer, iOS may download Apple's English speech model once. That's iOS fetching its own files, and nothing of yours is sent.

## Permissions

| Permission | Why |
|---|---|
| Microphone | to hear you, so the script follows along |
| Speech recognition | to turn what you say into text on the iPhone |
| Motion | for Tilt mode, to scroll when you tip the phone |
| Background audio | to keep listening while the script floats over the Camera app |

Cue doesn't ask for the camera, photos, contacts or location.
