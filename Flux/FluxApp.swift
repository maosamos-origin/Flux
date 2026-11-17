//
//  FluxApp.swift
//  Flux
//
//  Created by Nin on 9/19/26.
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    private var activationObserver: Any?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationDidBecomeActive()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    @objc func windowDidBecomeMain(_ notification: Notification) {
        (notification.object as? NSWindow)?.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the last window must never detach a live VM from its owner
        // and controls. A user can minimize or hide Flux and later reactivate
        // the same window; shutdown is always explicit and guest-initiated.
        guard FluxSessionController.shared.isRunning else { return true }
        sender.makeKeyAndOrderFront(nil)
        NSApp.requestUserAttention(.informationalRequest)
        return false
    }

    deinit {
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }
    }

    private func handleApplicationDidBecomeActive() {
        // Find the existing visible VM NSWindow
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) }) else {
            return
        }

        // Ensure no Flux-owned modal/sheet is active
        guard window.attachedSheet == nil, NSApp.modalWindow == nil else {
            return
        }

        // Call window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            print("🪟 [APP-ACTIVATION] Restoring key window: makeKeyAndOrderFront(nil)")
            window.makeKeyAndOrderFront(nil)
        }

        // Then, if appropriate: window.makeFirstResponder(displayView)
        let displayView = FluxDiagnosticDisplayView.current ?? findDisplayView(in: window.contentView)
        if let targetView = displayView, targetView.window === window, window.firstResponder !== targetView {
            print("🪟 [APP-ACTIVATION] Restoring first responder to displayView")
            window.makeFirstResponder(targetView)
        }
    }

    private func findDisplayView(in view: NSView?) -> NSView? {
        guard let view = view else { return nil }
        if view is FluxDiagnosticDisplayView { return view }
        for subview in view.subviews {
            if let found = findDisplayView(in: subview) { return found }
        }
        return nil
    }
}

@main
struct FluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session: FluxSessionController

    init() {
        // Keep the one VM owner alive independently of SwiftUI window
        // recreation.  Every Flux window receives this exact instance.
        _session = StateObject(wrappedValue: FluxSessionController.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandMenu("Actions") {
                Button("Send Ctrl+Alt+Del") {
                    session.sendCtrlAltDel()
                }
                .keyboardShortcut(.delete, modifiers: [.control, .option])
                .disabled(!session.isRunning || session.isSendingSecureAttention)

                Button("Paste Mac Clipboard") {
                    session.pasteMacClipboardToGuest()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!session.isRunning || session.isPastingClipboard)

                Button("Take Screenshot") {
                    session.captureScreenshot()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!session.isRunning)

                Button("Toggle Full Screen") {
                    session.toggleFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.control, .command])

                Divider()

                Button(session.shutdownRequestPending ? "Shutdown Requested..." : "Shut Down Windows") {
                    session.requestGuestShutdown()
                }
                .disabled(!session.isRunning || session.shutdownRequestPending)

                Button("Restart Windows") {
                    session.requestGuestRestart()
                }
                .disabled(!session.isRunning || session.shutdownRequestPending)
            }
        }
    }
}
