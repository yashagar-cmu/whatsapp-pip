<img src="icon/icon.png" width="128" alt="WhatsApp PiP icon">

# WhatsApp PiP

Picture-in-picture for WhatsApp video calls on macOS.

The WhatsApp Mac app has no PiP mode. Its call window floats with **Call → Always On Top**, but it can't be made smaller than 600×500. WhatsApp PiP mirrors the live call into a small floating tile that you can drag and resize. The tile stays above every app, Space and full-screen window.

The tile shows only the remote video. WhatsApp's title bar and call buttons are cropped off, and black letterboxing is trimmed as the video changes.

## Use

1. Start a WhatsApp video call.
2. Open **WhatsApp PiP**.
3. If macOS shows a window picker, click **Share This Window** on the call. This only sends the call window to the PiP tile on your own Mac. Nothing is shared with the other person.

| Action | What it does |
| --- | --- |
| Drag | Move the tile |
| Drag an edge | Resize (keeps the video's aspect ratio) |
| Double-click | Bring the full WhatsApp call window to the front |
| Right-click | Show call / Quit |

The tile closes itself when the call ends. While it runs, the purple screen-capture icon shows in the menu bar.

To let the big call window go behind other windows, turn off **Call → Always On Top** in WhatsApp (⌃⌘T).

### Skip the picker

Turn on **WhatsApp PiP** in System Settings → Privacy & Security → Screen & System Audio Recording. The app then finds the call window by itself, and it also follows the window if you resize it.

Without that permission, the app uses the system window picker, which needs no permission. The picker only offers WhatsApp's call window, and the app refuses any other window.

## Build

Requires macOS 15.2+ and the Xcode command line tools.

```sh
./build.sh
```

This compiles `main.swift`, packages `WhatsApp PiP.app` with its icon, signs it ad hoc and installs it to `~/Applications`.

To redraw the icon after changing it:

```sh
swift icon/make_icon.swift icon/icon.png
```

## How it works

[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) captures WhatsApp's call window on its own, so the capture still works when the window is covered by other windows. The frames, cropped to the video area, go into a non-activating `NSPanel` with a hidden title bar, at the floating window level. The panel joins all Spaces.

It doesn't work if the call window is minimized, because macOS stops drawing minimized windows. Cover the call window instead.
