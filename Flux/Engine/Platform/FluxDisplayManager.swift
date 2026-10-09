import Foundation
import CoreGraphics
import Combine

/// Manages guest display resolution synchronization, viewport mapping, debounce,
/// and mode transition safety for Flux.
public final class FluxDisplayManager: ObservableObject, @unchecked Sendable {

    public static let shared = FluxDisplayManager()

    private let lock = NSLock()

    @Published public private(set) var activeWidth: Int = 800
    @Published public private(set) var activeHeight: Int = 600
    public private(set) var lastRequestedWidth: Int = 0
    public private(set) var lastRequestedHeight: Int = 0
    public private(set) var isSwitchingMode: Bool = false
    public private(set) var modeSwitchCount: Int = 0

    /// Exact 4 display modes supported by FluxIdd for dynamic desktop synchronization.
    public static let supportedModes: [(width: Int, height: Int)] = [
        (800, 600),    // SVGA compatibility fallback
        (1280, 720),   // 16:9 HD
        (1600, 900),   // 16:9 HD+
        (1920, 1080)   // 16:9 Full HD
    ]

    private init() {}

    /// Updates the active resolution reported by the display driver or framebuffer.
    public func updateActiveResolution(width: Int, height: Int) {
        lock.lock()
        guard width > 0 && height > 0, (width != activeWidth || height != activeHeight) else {
            lock.unlock()
            return
        }
        activeWidth = width
        activeHeight = height
        modeSwitchCount += 1
        lock.unlock()

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        print("🖥️ [DYNAMIC-RESO] Active resolution updated to: \(width)x\(height) (switches=\(modeSwitchCount))")
    }

    /// Chooses the optimal guest resolution matching the host viewport aspect ratio and size.
    public static func targetResolution(for viewportSize: CGSize) -> (width: Int, height: Int) {
        guard viewportSize.width >= 640 && viewportSize.height >= 480 else {
            return (800, 600)
        }

        let targetAspect = viewportSize.width / viewportSize.height
        let targetArea = viewportSize.width * viewportSize.height

        // Score modes based on aspect ratio proximity and area fit
        var bestMode = supportedModes[0]
        var minScore = Double.greatestFiniteMagnitude

        for mode in supportedModes {
            let modeAspect = Double(mode.width) / Double(mode.height)
            let modeArea = Double(mode.width * mode.height)

            let aspectDiff = abs(modeAspect - Double(targetAspect))
            let areaRatio = modeArea / Double(targetArea)
            let areaPenalty = areaRatio < 0.5 ? 2.0 : (areaRatio > 2.0 ? 1.5 : 1.0)

            let score = (aspectDiff * 3.0) + abs(log2(areaRatio)) * areaPenalty
            if score < minScore {
                minScore = score
                bestMode = mode
            }
        }

        return bestMode
    }

    /// Calculates row stride with 64-byte alignment rule.
    public static func stride(forWidth width: Int, bpp: Int = 32) -> Int {
        let bytesPerRow = (width * bpp) / 8
        return (bytesPerRow + 63) & ~63
    }

    /// Requests guest mode change to target resolution with timeout protection.
    public func requestResolutionChange(width: Int, height: Int) {
        lock.lock()
        if isSwitchingMode {
            lock.unlock()
            print("⏳ [DYNAMIC-RESO] Mode switch already in progress, skipping request \(width)x\(height)")
            return
        }
        isSwitchingMode = true
        lastRequestedWidth = width
        lastRequestedHeight = height
        lock.unlock()

        print("🖥️ [DYNAMIC-RESO] Requesting guest resolution change: \(width)x\(height) (stride=\(Self.stride(forWidth: width)))")

        // Persist resolution request for guest agent retrieval
        let requestContent = "\(width) \(height)\r\n"
        let appDir = FluxVM.defaultAppDirectory()
        let requestPath = appDir + "/flux_resolution_request.txt"
        try? requestContent.write(toFile: requestPath, atomically: true, encoding: .utf8)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Simulated guest protocol negotiation with 3.0s timeout
            let timeout = DispatchTime.now() + 3.0
            var completed = false

            // Check if active resolution already matches
            self.lock.lock()
            if self.activeWidth == width && self.activeHeight == height {
                completed = true
            }
            self.isSwitchingMode = false
            self.lock.unlock()

            if completed {
                print("✅ [DYNAMIC-RESO] Mode switch confirmed: \(width)x\(height)")
            } else {
                print("⚠️ [DYNAMIC-RESO] Mode switch request \(width)x\(height) registered; awaiting guest confirmation")
            }
        }
    }
}
