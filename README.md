# Audio Index

[![CI](https://github.com/Jibbithy/audio-index-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/Jibbithy/audio-index-ios/actions/workflows/ci.yml)

A native iOS music player that brings Spotify and a self-hosted music library together, with playlists that can mix both sources.

Built with SwiftUI, AVFoundation and the Spotify iOS SDK. Includes 217 unit tests.

**This is a portfolio project.** It needs a personal backend that isn't in this repo, plus your own Spotify developer credentials, so it won't play music out of the box.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open AudioIndex.xcodeproj
```

To connect real services, fill in the placeholders in `AudioIndex/Config.swift`.

## Run the tests

The tests use the keychain, so they need simulator signing:

```bash
xcodebuild test -scheme AudioIndex \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Change the simulator name to one you have installed.

## License

[MIT](LICENSE)

Third-party packages, including the Spotify iOS SDK, are covered by their own licenses.
