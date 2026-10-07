//
//  FluxApp.swift
//  Flux
//
//  Created by Nin on 9/19/26.
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
