// WhatsApp PiP: mirrors a live WhatsApp or FaceTime video call window into a small
// floating, draggable, resizable picture-in-picture tile that stays above every app and Space.
//
//   click           go back to the call (the tile hides)
//   drag            move the tile
//   drag an edge    resize (aspect ratio is kept)
//   right-click     menu (show call, quit)
//
// The tile hides while the call window is the window you're looking at, and
// reappears as soon as you switch to another app or another window of the
// calling app (e.g. your WhatsApp chats). It closes itself when the call ends.

import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia

/// An app whose video calls can be mirrored, and the window chrome around its video, in points.
struct CallApp {
    let bundleID: String
    let name: String
    let cropTop: CGFloat
    let cropBottom: CGFloat
}

let whatsApp = CallApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", cropTop: 32, cropBottom: 60)
// FaceTime's video fills its window; the controls only appear while the pointer is over it.
let faceTime = CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime", cropTop: 0, cropBottom: 0)
let callApps = [whatsApp, faceTime]

func callApp(for bundleID: String?) -> CallApp? { callApps.first { $0.bundleID == bundleID } }

// Maps an accessibility window to its CGWindowID (private but long-stable; used by yabai, AltTab, …).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The frontmost normal window of `pid` on the current Space.
func frontWindow(of pid: pid_t) -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.first {
        ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
            && ((($0[kCGWindowBounds as String] as? [String: Double])?["Height"]) ?? 0) > 100
    }?[kCGWindowNumber as String] as? CGWindowID
}

/// Raise one specific window of `pid` and make it the app's main window. Needs Accessibility permission.
@discardableResult
func raise(window id: CGWindowID, of pid: pid_t) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return false }
    for w in windows {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(w, &wid) == .success, wid == id {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            return true
        }
    }
    return false
}

/// Whether window `id` of `pid` has an "End" (hang up) button. Tells FaceTime's call window apart from
/// its main window, which shares the title "FaceTime". Needs Accessibility; without it, says yes.
func hasEndCallButton(window id: CGWindowID, of pid: pid_t) -> Bool {
    guard AXIsProcessTrusted() else { return true }
    func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
        return v as? [AXUIElement] ?? []
    }
    func isEnd(_ e: AXUIElement) -> Bool {
        var role: CFTypeRef?, title: CFTypeRef?, desc: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
        guard role as? String == kAXButtonRole else { return false }
        AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &desc)
        return title as? String == "End" || desc as? String == "End"
    }
    func search(_ e: AXUIElement, depth: Int) -> Bool {
        isEnd(e) || (depth > 0 && children(e).contains { search($0, depth: depth - 1) })
    }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
    for w in value as? [AXUIElement] ?? [] {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(w, &wid) == .success, wid == id { return search(w, depth: 8) }
    }
    return true
}

/// Unit rect of the non-black area of a BGRA frame, kept centred (call apps letterbox symmetrically).
func videoRect(_ pb: CVPixelBuffer) -> CGRect? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let px = base.assumingMemoryBound(to: UInt8.self)
    func lit(_ x: Int, _ y: Int) -> Bool {
        let o = y * bpr + x * 4
        return Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2]) > 60
    }
    let sampleCols = Array(stride(from: w / 10, to: w, by: max(1, w / 10)))
    let sampleRows = Array(stride(from: h / 10, to: h, by: max(1, h / 10)))
    func rowLit(_ y: Int) -> Bool { sampleCols.contains { lit($0, y) } }
    func colLit(_ x: Int) -> Bool { sampleRows.contains { lit(x, $0) } }
    var top = 0; while top < h / 2 && !rowLit(top) { top += 1 }
    var bottom = 0; while bottom < h / 2 && !rowLit(h - 1 - bottom) { bottom += 1 }
    var left = 0; while left < w / 2 && !colLit(left) { left += 1 }
    var right = 0; while right < w / 2 && !colLit(w - 1 - right) { right += 1 }
    let mv = Double(min(top, bottom)), mh = Double(min(left, right))
    if mv > Double(h) * 0.4 || mh > Double(w) * 0.4 { return nil }  // frame is (nearly) all black
    return CGRect(x: mh / Double(w), y: mv / Double(h),
                  width: 1 - 2 * mh / Double(w), height: 1 - 2 * mv / Double(h))
}

final class PiPView: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }

    // A press that doesn't move the tile is a click; anything else was a drag.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let before = window.frame.origin
        window.performDrag(with: event)
        if window.frame.origin == before { onClick?() }
    }
}

final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Mirror: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver {
    let view: PiPView
    var onStarted: (() -> Void)?
    var stream: SCStream?
    var app = whatsApp
    var windowID: CGWindowID?
    var lastFrame: CGRect = .zero
    var poll: Timer?
    var frameCount = 0
    var trim = CGRect(x: 0, y: 0, width: 1, height: 1)
    var sourceSize = CGSize(width: 16, height: 9)
    let queue = DispatchQueue(label: "pip.frames")

    init(view: PiPView) { self.view = view }

    func start() {
        if CGPreflightScreenCaptureAccess() {
            Task { await self.startAutomatically() }
        } else {
            // No Screen Recording permission: the system window picker works without it.
            // Only call windows are offered, so nothing else can be picked by mistake.
            let picker = SCContentSharingPicker.shared
            var cfg = SCContentSharingPickerConfiguration()
            cfg.allowedPickerModes = [.singleWindow]
            cfg.excludedBundleIDs = NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier).filter { callApp(for: $0) == nil }
            cfg.excludedWindowIDs = (otherWhatsAppWindows() + otherFaceTimeWindows()).map { Int($0) }
            picker.defaultConfiguration = cfg
            picker.add(self)
            picker.isActive = true
            picker.present(using: .window)
        }
    }

    /// WhatsApp windows other than the call window (chat list, menus, …).
    func otherWhatsAppWindows() -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: whatsApp.bundleID).first?.processIdentifier
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
        let isCall: ([String: Any]) -> Bool = {
            (($0[kCGWindowName as String] as? String) ?? "").localizedCaseInsensitiveContains("call")
        }
        guard mine.contains(where: isCall) else { return [] }  // titles hidden: can't tell, offer them all
        return mine.filter { !isCall($0) }.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    /// FaceTime windows other than the call window (its main window). Only known with Accessibility.
    func otherFaceTimeWindows() -> [CGWindowID] {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: faceTime.bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            .filter { !hasEndCallButton(window: $0, of: pid) }
    }

    func startAutomatically() async {
        guard let window = await findCallWindow(), let found = callApp(for: window.owningApplication?.bundleIdentifier) else {
            await MainActor.run { fail("No WhatsApp or FaceTime video call found. Start the call first.") }
            return
        }
        app = found
        windowID = window.windowID
        lastFrame = window.frame
        let filter = SCContentFilter(desktopIndependentWindow: window)
        await MainActor.run {
            run(filter: filter, size: window.frame.size)
            // Follow resizes of the call window, and close when the call ends.
            poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { await self?.refresh() }
            }
        }
    }

    /// A WhatsApp or FaceTime call window, preferring the app you're using, then WhatsApp.
    func findCallWindow() async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        let windows = content.windows.filter { $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 200 }
        func calls(_ app: CallApp) -> [SCWindow] {
            let mine = windows.filter { $0.owningApplication?.bundleIdentifier == app.bundleID }
            if app.bundleID == faceTime.bundleID {
                return mine.filter { w in
                    w.isOnScreen && hasEndCallButton(window: w.windowID, of: w.owningApplication!.processID)
                }
            }
            let titled = mine.filter { ($0.title ?? "").localizedCaseInsensitiveContains("call") }
            return titled.isEmpty ? mine : titled
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for app in callApps.filter({ $0.bundleID == front }) + callApps.filter({ $0.bundleID != front }) {
            if let w = calls(app).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return w
            }
        }
        return nil
    }

    func refresh() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            await MainActor.run { NSApp.terminate(nil) }
            return
        }
        if window.frame.size != lastFrame.size {
            lastFrame = window.frame
            try? await stream?.updateConfiguration(config(for: window.frame.size))
            await MainActor.run { fitPanel(to: window.frame.size) }
        }
    }

    func config(for size: CGSize) -> SCStreamConfiguration {
        let src = CGRect(x: 0, y: app.cropTop,
                         width: max(100, size.width),
                         height: max(100, size.height - app.cropTop - app.cropBottom))
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = src
        cfg.width = Int(src.width * 2)
        cfg.height = Int(src.height * 2)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = false
        cfg.queueDepth = 5
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        return cfg
    }

    @MainActor func run(filter: SCContentFilter, size: CGSize) {
        let s = SCStream(filter: filter, configuration: config(for: size), delegate: self)
        try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        s.startCapture { err in
            if let err { DispatchQueue.main.async { fail("Could not mirror the call: \(err.localizedDescription)") } }
        }
        stream = s
        fitPanel(to: size)
        // Start with the tile's longer side 340pt, so portrait calls (common on FaceTime) aren't huge.
        if let panel = view.window, sourceSize.height > sourceSize.width {
            var f = panel.frame
            let w = 340 * sourceSize.width / sourceSize.height
            f.origin.x = f.maxX - w
            f.size = NSSize(width: w, height: 340)
            panel.setFrame(f, display: true)
        }
        onStarted?()
    }

    @MainActor func fitPanel(to size: CGSize) {
        sourceSize = CGSize(width: max(100, size.width), height: max(100, size.height - app.cropTop - app.cropBottom))
        applyAspect()
    }

    @MainActor func applyAspect() {
        guard let panel = view.window else { return }
        let w = sourceSize.width * trim.width, h = sourceSize.height * trim.height
        panel.contentAspectRatio = NSSize(width: w, height: h)
        var f = panel.frame
        let newH = f.width * h / w
        f.origin.y += f.height - newH
        f.size.height = newH
        panel.setFrame(f, display: true)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        frameCount += 1
        var newTrim: CGRect?
        if frameCount % 15 == 1, let r = videoRect(pb),
           abs(r.width - trim.width) > 0.02 || abs(r.height - trim.height) > 0.02 {
            trim = r
            newTrim = r
        }
        DispatchQueue.main.async {
            if let r = newTrim {
                self.view.layer?.contentsRect = r
                self.applyAspect()
            }
            self.view.layer?.contents = surface
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: picker (used when Screen Recording permission is not granted)

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        picker.isActive = false
        guard let window = filter.includedWindows.first(where: { callApp(for: $0.owningApplication?.bundleIdentifier) != nil }),
              let picked = callApp(for: window.owningApplication?.bundleIdentifier) else {
            DispatchQueue.main.async { fail("That wasn't a WhatsApp or FaceTime call. Reopen WhatsApp PiP and pick the call.") }
            return
        }
        app = picked
        windowID = window.windowID
        let size = filter.contentRect.size
        DispatchQueue.main.async { self.run(filter: filter, size: size) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { fail("Window picker failed: \(error.localizedDescription)") }
    }
}

@MainActor func fail(_ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "WhatsApp PiP"
    alert.informativeText = message
    alert.runModal()
    NSApp.terminate(nil)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: PiPPanel!
    var mirror: Mirror!
    var quietUntil = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.main!.visibleFrame
        let width: CGFloat = 340, height: CGFloat = 220
        let rect = NSRect(x: screen.maxX - width - 16, y: screen.minY + 16, width: width, height: height)

        panel = PiPPanel(contentRect: rect,
                         styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 160, height: 90)
        panel.backgroundColor = .black

        let view = PiPView(frame: NSRect(origin: .zero, size: rect.size))
        view.autoresizingMask = [.width, .height]
        view.onClick = { [weak self] in self?.showCall() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Call", action: #selector(showCallAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PiP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        view.menu = menu
        panel.contentView = view

        mirror = Mirror(view: view)
        mirror.onStarted = { [weak self] in self?.updateVisibility() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateVisibility() }
        // Switching between one app's own windows sends no notification, so also check a few times a second.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateVisibility() }
        mirror.start()
    }

    /// Hidden while the call window is the front window of the active app, shown otherwise.
    func updateVisibility() {
        guard mirror.stream != nil, let front = NSWorkspace.shared.frontmostApplication, front != .current else { return }
        let callInFront = front.bundleIdentifier == mirror.app.bundleID
            && (mirror.windowID == nil || frontWindow(of: front.processIdentifier) == mirror.windowID)
        if callInFront {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible && Date() > quietUntil {
            panel.orderFrontRegardless()
        }
    }

    /// Hide the tile and bring the call window to the front (switching to its Space if it's full screen).
    func showCall() {
        guard let callApp = NSRunningApplication.runningApplications(withBundleIdentifier: mirror.app.bundleID).first else { return }
        let pid = callApp.processIdentifier
        panel.orderOut(nil)
        quietUntil = Date() + 0.8  // don't flash back while the app and its call window come forward
        // Raising the call window itself (not just the app's last-used window) needs Accessibility;
        // the first click asks for it, and until then this just switches to the app.
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        if let id = mirror.windowID { raise(window: id, of: pid) }
        // The tile never activates this app, so ask to become active first and hand activation over.
        NSApp.activate()
        callApp.activate(from: .current)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if let id = self?.mirror.windowID { raise(window: id, of: pid) }
            guard NSWorkspace.shared.frontmostApplication != callApp, let url = callApp.bundleURL else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc func showCallAction() { showCall() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
