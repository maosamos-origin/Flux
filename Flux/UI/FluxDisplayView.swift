import SwiftUI
import MetalKit
import AppKit

struct FluxDisplayView: NSViewRepresentable {

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = FluxDiagnosticDisplayView()
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ [FluxDisplayView] Metal is not supported on this Mac")
            return mtkView
        }

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false

        let renderer = FluxMetalRenderer(device: device)
        context.coordinator.renderer = renderer
        mtkView.delegate = renderer

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if let window = nsView.window, window.isKeyWindow, window.firstResponder !== nsView {
            DispatchQueue.main.async { [weak nsView, weak window] in
                guard let nsView = nsView, let window = window, window.isKeyWindow else { return }
                if window.firstResponder !== nsView {
                    window.makeFirstResponder(nsView)
                }
            }
        }
    }

    final class Coordinator {
        var renderer: FluxMetalRenderer?
    }
}

/// Native USB HID Boot Keyboard, Absolute Pointer, and diagnostic serial-console input view.
internal final class FluxDiagnosticDisplayView: MTKView {
    static weak var current: FluxDiagnosticDisplayView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var scrollAccumulator: CGFloat = 0.0

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func resignFirstResponder() -> Bool {
        scrollAccumulator = 0.0
        FluxHIDKeyboard.shared.resetState()
        FluxHIDPointer.shared.resetButtons()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window = self.window {
            Self.current = self
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidChangeFullScreen), name: NSWindow.didEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidChangeFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)

            if window.isKeyWindow {
                claimFirstResponder()
            }
            setupKeyEventMonitor()
        } else {
            if Self.current === self {
                Self.current = nil
            }
            teardownKeyEventMonitor()
        }
    }

    deinit {
        teardownKeyEventMonitor()
        if Self.current === self {
            Self.current = nil
        }
    }

    private var resizeDebounceTimer: Timer?

    @objc private func windowDidResize() {
        resizeDebounceTimer?.invalidate()
        resizeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.handleDebouncedWindowResize()
        }
    }

    private func handleDebouncedWindowResize() {
        let viewSize = bounds.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

        let target = FluxDisplayManager.targetResolution(for: viewSize)
        let activeWidth = FluxDisplayManager.shared.activeWidth
        let activeHeight = FluxDisplayManager.shared.activeHeight
        print("🖥️ [DYNAMIC-RESO] Viewport resized: \(Int(viewSize.width))x\(Int(viewSize.height)) -> Target: \(target.width)x\(target.height) (Active: \(activeWidth)x\(activeHeight))")

        if activeWidth != target.width || activeHeight != target.height {
            FluxDisplayManager.shared.requestResolutionChange(width: target.width, height: target.height)
        }
    }

    @objc private func windowDidResignKey() {
        print("🪟 [WINDOW-STATE] windowDidResignKey: isKey=\(window?.isKeyWindow ?? false) isMain=\(window?.isMainWindow ?? false) appActive=\(NSApp.isActive)")
        scrollAccumulator = 0.0
        FluxHIDKeyboard.shared.resetState()
        FluxHIDPointer.shared.resetButtons()
    }

    @objc private func windowDidBecomeKey() {
        print("🪟 [WINDOW-STATE] windowDidBecomeKey: isKey=\(window?.isKeyWindow ?? false) isMain=\(window?.isMainWindow ?? false) appActive=\(NSApp.isActive) keyWin=\(NSApp.keyWindow != nil)")
        claimFirstResponder()
        let flags = NSEvent.modifierFlags.rawValue
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: 0, rawFlags: flags)
    }

    private func claimFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window, window.isKeyWindow else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    @objc private func windowDidChangeFullScreen() {
        window?.makeFirstResponder(self)
        needsDisplay = true
        handleDebouncedWindowResize()
    }

    // MARK: - Native Mouse / Pointer Events

    private func handleMouseEvent(_ event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let snap = FluxFramebuffer.shared.snapshot()
        let fbW = snap.width > 0 ? snap.width : 1024
        let fbH = snap.height > 0 ? snap.height : 768
        guard let map = FluxHIDPointer.mapPointToHID(viewPoint: loc, viewSize: bounds.size, fbWidth: fbW, fbHeight: fbH) else {
            return
        }
        let buttons = UInt8(NSEvent.pressedMouseButtons & 0x07)
        FluxHIDPointer.shared.updateState(x: map.hidX, y: map.hidY, buttons: buttons)
    }

    override func mouseEntered(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func mouseExited(with event: NSEvent) {
        if NSEvent.pressedMouseButtons == 0 {
            FluxHIDPointer.shared.resetButtons()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseEvent(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseEvent(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        handleMouseEvent(event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            // Trackpad smooth scrolling
            scrollAccumulator += event.scrollingDeltaY
            let threshold: CGFloat = 8.0 // points per HID wheel tick
            if abs(scrollAccumulator) >= threshold {
                let steps = Int(scrollAccumulator / threshold)
                scrollAccumulator -= CGFloat(steps) * threshold
                let clampedDelta = Int8(clamping: max(-5, min(5, steps)))
                if clampedDelta != 0 {
                    FluxHIDPointer.shared.updateWheel(delta: clampedDelta)
                }
            }
        } else {
            // Traditional mouse wheel
            let ticks = Int8(clamping: Int(round(event.deltaY)))
            if ticks != 0 {
                FluxHIDPointer.shared.updateWheel(delta: ticks)
            }
        }
    }

    // MARK: - Native Keyboard Fallback Monitor

    private var keyEventMonitor: Any?

    private func setupKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            FluxHIDKeyboard.appendKeyboardTrace("[LOCAL-KEY-MONITOR-PRE-GATE] type=\(event.type) keyCode=\(event.keyCode) modifierFlags=\(event.modifierFlags.rawValue) eventWindowNumber=\(event.windowNumber) eventWindowTitle=\(event.window?.title ?? "nil") appActive=\(NSApp.isActive) keyWindowTitle=\(NSApp.keyWindow?.title ?? "nil") mainWindowTitle=\(NSApp.mainWindow?.title ?? "nil") fluxWindowNumber=\(self?.window?.windowNumber.description ?? "nil") fluxIsKeyWindow=\(self?.window?.isKeyWindow.description ?? "nil") fluxIsMainWindow=\(self?.window?.isMainWindow.description ?? "nil") firstResponder=\(String(describing: self?.window?.firstResponder)))")
            guard let self = self,
                  let window = self.window,
                  window.isKeyWindow,
                  (event.window === window || (event.window == nil && NSApp.keyWindow === window)),
                  window.firstResponder !== self
            else {
                return event
            }

            switch event.type {
            case .keyDown:
                self.processKeyDown(event)
                return nil
            case .keyUp:
                self.processKeyUp(event)
                return nil
            case .flagsChanged:
                self.processFlagsChanged(event)
                return nil
            default:
                return event
            }
        }
    }

    private func teardownKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    private func processKeyDown(_ event: NSEvent) {
        // Route to USB HID Boot Keyboard
        FluxHIDKeyboard.appendKeyboardTrace("[DISPLAY-KEYDOWN] keyCode=\(event.keyCode) isRepeat=\(event.isARepeat)")
        FluxHIDKeyboard.shared.handleKeyDown(keyCode: event.keyCode, isRepeat: event.isARepeat)

        // Preserve temporary diagnostic UART forwarding
        let bytes: [UInt8]
        switch event.keyCode {
        case 36: bytes = [0x0D]                    // Return
        case 48: bytes = [0x09]                    // Tab
        case 51: bytes = [0x08]                    // Backspace
        case 53: bytes = [0x1B]                    // Escape
        case 123: bytes = Array("\u{1B}[D".utf8)  // Left
        case 124: bytes = Array("\u{1B}[C".utf8)  // Right
        case 125: bytes = Array("\u{1B}[B".utf8)  // Down
        case 126: bytes = Array("\u{1B}[A".utf8)  // Up
        case 109: bytes = Array("\u{1B}[21~".utf8) // F10
        default:
            guard let text = event.characters, !text.isEmpty else { return }
            bytes = Array(text.utf8)
        }
        FluxUART.injectDiagnosticInput(bytes)
    }

    private func processKeyUp(_ event: NSEvent) {
        FluxHIDKeyboard.appendKeyboardTrace("[DISPLAY-KEYUP] keyCode=\(event.keyCode)")
        FluxHIDKeyboard.shared.handleKeyUp(keyCode: event.keyCode)
    }

    private func processFlagsChanged(_ event: NSEvent) {
        FluxHIDKeyboard.shared.handleFlagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue)
    }

    override func keyDown(with event: NSEvent) {
        guard let window = self.window, window.isKeyWindow, window.firstResponder === self else { return }
        processKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        guard let window = self.window, window.isKeyWindow, window.firstResponder === self else { return }
        processKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let window = self.window, window.isKeyWindow, window.firstResponder === self else { return }
        processFlagsChanged(event)
    }
}
