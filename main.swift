// WhatsApp PiP: mirrors the live WhatsApp call window into a small floating,
// draggable, resizable picture-in-picture tile that stays above every app and Space.
//
//   drag            move the tile
//   drag an edge    resize (aspect ratio is kept)
//   double-click    bring the WhatsApp call window to the front
//   right-click     menu (show call, quit)
//
// The tile closes itself when the call ends.

import AppKit
import ScreenCaptureKit
import CoreMedia

let whatsAppID = "net.whatsapp.WhatsApp"
// Fixed chrome of WhatsApp's call window, in points: title bar on top, call controls at the bottom.
// Any black letterboxing left around the video is trimmed per frame.
let cropTop: CGFloat = 32, cropBottom: CGFloat = 60, cropSide: CGFloat = 0

/// Unit rect of the non-black area of a BGRA frame, kept centred (WhatsApp letterboxes symmetrically).
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
    var onDoubleClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { window?.performDrag(with: event) }
    }
}

final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Mirror: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver {
    let view: PiPView
    var stream: SCStream?
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
            // Only the WhatsApp call window is offered, so nothing else can be picked by mistake.
            let picker = SCContentSharingPicker.shared
            var cfg = SCContentSharingPickerConfiguration()
            cfg.allowedPickerModes = [.singleWindow]
            cfg.excludedBundleIDs = NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier).filter { $0 != whatsAppID }
            cfg.excludedWindowIDs = otherWhatsAppWindows().map { Int($0) }
            picker.defaultConfiguration = cfg
            picker.add(self)
            picker.isActive = true
            picker.present(using: .window)
        }
    }

    /// WhatsApp windows other than the call window (chat list, menus, …).
    func otherWhatsAppWindows() -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: whatsAppID).first?.processIdentifier
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
        let isCall: ([String: Any]) -> Bool = {
            (($0[kCGWindowName as String] as? String) ?? "").localizedCaseInsensitiveContains("call")
        }
        guard mine.contains(where: isCall) else { return [] }  // titles hidden: can't tell, offer them all
        return mine.filter { !isCall($0) }.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    func startAutomatically() async {
        guard let window = await findCallWindow() else {
            await MainActor.run { fail("No WhatsApp video call window found. Start the call first.") }
            return
        }
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

    func findCallWindow() async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == whatsAppID && $0.frame.width > 200 && $0.frame.height > 200
        }
        let calls = windows.filter { ($0.title ?? "").localizedCaseInsensitiveContains("call") }
        return (calls.isEmpty ? windows : calls).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
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
        let src = CGRect(x: cropSide, y: cropTop,
                         width: max(100, size.width - 2 * cropSide),
                         height: max(100, size.height - cropTop - cropBottom))
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
        view.window?.orderFrontRegardless()
    }

    @MainActor func fitPanel(to size: CGSize) {
        sourceSize = CGSize(width: max(100, size.width - 2 * cropSide), height: max(100, size.height - cropTop - cropBottom))
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
        guard filter.includedWindows.contains(where: { $0.owningApplication?.bundleIdentifier == whatsAppID }) else {
            DispatchQueue.main.async { fail("That wasn't the WhatsApp call window. Reopen WhatsApp PiP and pick the call.") }
            return
        }
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

func showCall() {
    NSRunningApplication.runningApplications(withBundleIdentifier: whatsAppID).first?.activate()
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
        view.onDoubleClick = showCall
        let menu = NSMenu()
        menu.addItem(withTitle: "Show WhatsApp Call", action: #selector(showCallAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PiP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        view.menu = menu
        panel.contentView = view

        mirror = Mirror(view: view)
        mirror.start()
    }

    @objc func showCallAction() { showCall() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
