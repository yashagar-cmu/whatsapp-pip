<img src="icon/icon.png" width="128" alt="WhatsApp PiP icon">

# WhatsApp PiP

Picture-in-picture for WhatsApp and FaceTime video calls on macOS.

The WhatsApp Mac app has no PiP mode. Its call window floats with **Call → Always On Top**, but it can't be made smaller than 600×500. WhatsApp PiP mirrors the live call into a small floating tile that you can drag and resize. The tile stays above every app, Space and full-screen window.

The same tile works for FaceTime calls.

The tile shows only the remote video. WhatsApp's title bar and call buttons are cropped off, and black letterboxing is trimmed as the video changes. FaceTime's video already fills its window, so nothing is cropped there. Portrait calls get a portrait tile.

## Use

1. Start a WhatsApp or FaceTime video call.
2. Open **WhatsApp PiP**.
3. If macOS shows a window picker, click **Share This Window** on the call. This only sends the call window to the PiP tile on your own Mac. Nothing is shared with the other person.
4. Switch to another app. The tile appears.

The tile hides while the call window is the window you're using. It appears as soon as you switch to another app or to another window of the calling app, such as your WhatsApp chats or FaceTime's call list.

| Action | What it does |
| --- | --- |
| Click | Go back to the call window (switching to its Space if the call is full screen); the tile hides |
| Drag | Move the tile |
| Drag an edge | Resize (keeps the video's aspect ratio) |
| Right-click | Show call / Quit |

The tile closes itself when the call ends. While it runs, the purple screen-capture icon shows in the menu bar.

To let the big call window go behind other windows, turn off **Call → Always On Top** in WhatsApp (⌃⌘T).

### Click goes straight to the call

The first time you click the tile, macOS asks to give **WhatsApp PiP** Accessibility access. Allow it in System Settings → Privacy & Security → Accessibility. The app uses it only to bring the call window itself to the front. Without it, a click only switches to the calling app, which may show its chats or call list instead of the call. It also lets the app tell FaceTime's call window apart from its main window, since both are titled "FaceTime".

The app is signed ad hoc, so macOS treats every rebuild as a new app. After running `./build.sh`, turn the permission off and on again.

### Skip the picker

Turn on **WhatsApp PiP** in System Settings → Privacy & Security → Screen & System Audio Recording. The app then finds the call window by itself, and it also follows the window if you resize it. If both apps have a call, it picks the app you're using, then WhatsApp.

Without that permission, the app uses the system window picker, which needs no permission. The picker only offers WhatsApp and FaceTime windows. With Accessibility allowed, it narrows that to their call windows. The app refuses any other window.

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

[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) captures the call window on its own, so the capture still works when the window is covered by other windows. The frames, cropped to the video area, go into a non-activating `NSPanel` with a hidden title bar, at the floating window level. The panel joins all Spaces.

It doesn't work if the call window is minimized, because macOS stops drawing minimized windows. Cover the call window instead.
