# Elysia
The missing graphical interface of Apple Music.

**English** · [简体中文](./README.zh-Hans.md)

## Requirements

- macOS 13 or later
- Apple Music with a library (Elysia drives the Music app, it does not play audio itself)

## Languages

The interface ships in English and Simplified Chinese, as two independent
packs in `Elysia/en.lproj` and `Elysia/zh-Hans.lproj`. By default it follows the
system language; **Settings → Language** overrides it, which takes effect after
a restart.

## Install

1. Download `Elysia-x.y.z.dmg` from the [releases page](../../releases).
2. Open the DMG and drag **Elysia** onto the **Applications** shortcut.
3. Launch Elysia from Applications and allow it to control **Music** when macOS asks.

### If macOS refuses to open it

Released builds are signed but not notarized, which needs a paid Apple Developer
account. Gatekeeper therefore reports the app as coming from an unidentified
developer. Either workaround is fine:

- Right-click (or Control-click) Elysia in Applications, choose **Open**, then
  confirm. macOS remembers the choice.
- Or clear the download quarantine flag:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Elysia.app
  ```

## Build from source

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen),
so `Elysia.xcodeproj` is disposable:

```sh
xcodegen generate
open Elysia.xcodeproj
```

To produce a signed, universal (arm64 + x86_64) DMG in `dist/`:

```sh
Scripts/package-dmg.sh
```

The script picks the first `Apple Development` identity in your keychain; set
`SIGN_IDENTITY` to override it, or to `-` for ad-hoc signing. It deliberately
leaves the hardened runtime off: enabling it would require the
`com.apple.security.automation.apple-events` entitlement to keep controlling
Music, and a personal team cannot notarize anyway.

The app icon is regenerated from a single source image with
`Scripts/generate-appicon.py`.
