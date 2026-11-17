import Foundation
import Combine
import AppKit

/// Owns the one live VM session independently of any SwiftUI window.
/// A window may be hidden or reopened, but it must never cause a running VM
/// to lose its only lifecycle owner.
@MainActor
final class FluxSessionController: ObservableObject {
    static let shared = FluxSessionController()

    @Published private(set) var isRunning = false
    @Published private(set) var shutdownRequestPending = false
    @Published private(set) var isSendingSecureAttention = false
    @Published private(set) var isPastingClipboard = false
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var sessionStartDate: Date?
    @Published private(set) var lastError: String?

    private var engine: FluxEngine?
    private var activeRunID: UUID?

    private init() {}

    func start() {
        guard !isRunning else { return }
        let engine = FluxEngine()
        let runID = UUID()
        self.engine = engine
        self.activeRunID = runID
        isRunning = true
        shutdownRequestPending = false
        isSendingSecureAttention = false
        sessionStartDate = Date()
        lastError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            engine.testHypervisor()
            DispatchQueue.main.async {
                // A completed VM run may only clear the session it started.
                // This prevents an old worker completion from making a newer
                // live VM look stopped in the UI.
                guard self.activeRunID == runID else { return }
                self.engine = nil
                self.activeRunID = nil
                self.shutdownRequestPending = false
                self.isSendingSecureAttention = false
                self.sessionStartDate = nil
                self.isRunning = false
            }
        }
    }

    /// Requests a normal Windows shutdown through the shell's native power
    /// menu. This avoids command text injection; VM resource release remains
    /// the completion signal.
    func requestGuestShutdown() {
        guard isRunning, !shutdownRequestPending else { return }
        shutdownRequestPending = true

        DispatchQueue.global(qos: .userInitiated).async {
            let delivered = FluxHIDKeyboard.shared.requestWindowsShutdownShortcut()
            DispatchQueue.main.async {
                if !delivered {
                    self.shutdownRequestPending = false
                }
            }
        }
    }

    /// Requests a normal Windows restart through the shell's native power menu.
    func requestGuestRestart() {
        guard isRunning, !shutdownRequestPending else { return }
        showTransientStatus("Restart requested")

        DispatchQueue.global(qos: .userInitiated).async {
            let delivered = FluxHIDKeyboard.shared.requestWindowsRestartShortcut()
            if !delivered {
                DispatchQueue.main.async {
                    self.showTransientStatus("Restart shortcut failed")
                }
            }
        }
    }

    /// Immediately stops all vCPUs and tears down the active VM.
    func forceStop() {
        guard isRunning, let engine else { return }
        shutdownRequestPending = true
        showTransientStatus("Force stopping VM...")

        DispatchQueue.global(qos: .userInitiated).async {
            engine.requestForceStop()
        }
    }

    func sendCtrlAltDel() {
        guard isRunning, !isSendingSecureAttention else { return }
        isSendingSecureAttention = true

        DispatchQueue.global(qos: .userInitiated).async {
            _ = FluxHIDKeyboard.shared.sendCtrlAltDelShortcut()
            DispatchQueue.main.async {
                self.isSendingSecureAttention = false
            }
        }
    }

    func toggleFullScreen() {
        FluxDiagnosticDisplayView.toggleFullScreen()
    }

    /// Types the current macOS text clipboard into the Windows guest via USB HID.
    func pasteMacClipboardToGuest() {
        guard isRunning, !isPastingClipboard else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showTransientStatus("Mac clipboard is empty")
            return
        }
        isPastingClipboard = true
        let boundedText = String(text.prefix(4096))

        DispatchQueue.global(qos: .userInitiated).async {
            FluxHIDKeyboard.shared.typeString(boundedText, charDelay: 0.015)
            DispatchQueue.main.async {
                self.isPastingClipboard = false
                self.showTransientStatus("Pasted \(boundedText.count) chars")
            }
        }
    }

    /// Captures the latest active framebuffer (FluxIdd or RAMFB) as a PNG on the Desktop.
    func captureScreenshot() {
        guard isRunning else { return }

        let pngData: Data?
        if let idd = FluxFrameTransport.shared.latestFrameDataSnapshot() {
            pngData = Self.makePNG(data: idd.data, width: idd.width, height: idd.height, stride: idd.stride)
        } else {
            let snap = FluxFramebuffer.shared.snapshot()
            if snap.isConfigured, let ptr = snap.hostPointer, snap.width > 0, snap.height > 0 {
                let stride = snap.stride > 0 ? snap.stride : snap.width * 4
                let byteCount = stride * snap.height
                if byteCount <= snap.mappedByteCapacity {
                    let data = Data(bytes: ptr, count: byteCount)
                    pngData = Self.makePNG(data: data, width: snap.width, height: snap.height, stride: stride)
                } else {
                    pngData = nil
                }
            } else {
                pngData = nil
            }
        }

        guard let pngData,
              let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            showTransientStatus("Screenshot unavailable")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let filename = "Flux Screenshot \(formatter.string(from: Date())).png"
        let url = desktop.appendingPathComponent(filename)

        do {
            try pngData.write(to: url)
            showTransientStatus("Saved \(filename)")
        } catch {
            showTransientStatus("Screenshot save failed")
        }
    }

    private func showTransientStatus(_ message: String) {
        lastStatusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.lastStatusMessage == message {
                self?.lastStatusMessage = nil
            }
        }
    }

    private static func makePNG(data: Data, width: Int, height: Int, stride: Int) -> Data? {
        guard width > 0, height > 0, stride >= width * 4, data.count >= stride * height else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: stride,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
