# Afterglow

A Tide-themed webOS launcher and its SwiftUI iPhone remote, developed with an LG OLED77G1PUA running firmware 03.53.45.

- **TV launcher 1.3.0** — YouTube, Netflix, Prime Video and Sling shortcuts, remote navigation, a clock, ambient mode, and a Settings menu that opens LG’s native TV settings.
- **iPhone remote** — Pairing, navigation, touchpad, voice and typed commands, playback, app shortcuts and wake. Selecting a compatible TV text field opens the phone keyboard while the remote is in the foreground. Tap Send to insert text. Password fields are excluded.
- **G1 helper** — Optional, firmware-specific Home-button routing and startup for the rooted G1. The iPhone remote uses its own pairing with the TV.

## Open the projects

Open `tv/index.html` for a desktop preview. To package the TV app using the webOS CLI, run `ares-package tv` from this directory. TV services require a compatible TV.

For the phone, copy `ios/DeviceConfig/TV.example.plist` to `ios/DeviceConfig/TV.plist`. Set the TV hostname, SHA-256 fingerprint of its verified TLS leaf certificate, wake address and Wi-Fi MAC. The real file is ignored by Git. Open `ios/AfterglowRemote.xcodeproj` in Xcode with the iOS 26 SDK or later, select your signing team and build for an iPhone. Approve pairing on the TV. The device stores its pairing key in Keychain.

`g1-helper/` contains the boot hook, key mapping, and a restore script intended to run on the original rooted G1. The key mapper verifies the firmware handler before applying the override. The recovery script restores the startup preferences recorded for that G1.

## Device checks

The launcher’s Settings entry opened the native LG settings window on the G1. Text sent from the iPhone arrived in a standard TV input field. Streaming apps with custom keyboards may handle input differently. Closed-app keyboard notifications are outside this version.
