# Spacebomber

Talk to an OpenAI realtime voice agent through Mentra Live glasses. The iPhone app connects to the glasses, sends the glasses microphone to the agent, and plays the spoken reply on the glasses speaker.

This is a personal test build. The OpenAI API key is compiled into the app on the phone. That is fine only on a device you control. Do not ship this app, and do not commit the key.

## Requirements

- A Mac with Xcode 27
- XcodeGen (`brew install xcodegen`)
- An iPhone
- Mentra Live glasses running software 3.1.1
- An Apple Developer account
- An OpenAI API key

## Build

```bash
brew install xcodegen
git clone https://github.com/AndrewCortado/Spacebomber.git
cd Spacebomber
git checkout feat/1-realtime-voice-prototype
cd ios
xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `ios/Config/Local.xcconfig`. Set `DEVELOPMENT_TEAM` to your Apple Team ID and `OPENAI_API_KEY` to your key. `Local.xcconfig` is gitignored. `xcodegen` writes `ios/Spacebomber/Info.plist`, which is also gitignored. The plist stores the key as the build setting `$(OPENAI_API_KEY)`. Xcode copies the key into the app bundle when it builds.

Open the project and run it on your iPhone:

```bash
open Spacebomber.xcodeproj
```

Signing is automatic. A build that does not sign:

```bash
xcodebuild -scheme Spacebomber -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Pair the glasses

Update the glasses to software 3.1.1 once with Mentra's Starter Kit app. That update is buggy, so check the version on the glasses afterward. Glasses still below 3.1.1 are a known risk.

In the app, tap Scan and choose your Mentra Live. In iOS Settings → Bluetooth, connect Mentra Live so the reply plays from the glasses. iOS does not let the app pick the audio output. If Mentra Live is not the media route when the glasses are ready, the app shows "select Mentra Live in Settings → Bluetooth".

## Talk

Tap Start. Speak into the glasses. The phase line moves from Listening to You're speaking, Thinking, Agent speaking, and back to Listening. The reply comes from the glasses speaker. Tap Stop to end the session. Tap Start to begin another.

This build is half-duplex. The app does not send your voice while the agent is speaking, or for a short moment after the agent finishes. You cannot interrupt the agent.

If the key is missing, the app shows "Add OPENAI_API_KEY to ios/Config/Local.xcconfig" and Start stays off.

The screen stays awake during a session. Locking the phone ends it, because the app does not run audio in the background. A realtime session lasts at most 60 minutes. After it ends, tap Start again.

## Tests

Boot a simulator, then run the suite. Use a simulator name from `xcrun simctl list devices available` if `iPhone 16` is not installed.

```bash
xcodebuild -scheme Spacebomber -destination 'platform=iOS Simulator,name=iPhone 16' test
```
