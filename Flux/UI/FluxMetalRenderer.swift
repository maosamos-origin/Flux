import Foundation
import MetalKit

final class FluxMetalRenderer: NSObject, MTKViewDelegate {

    /// Explicit host-only diagnostic selection.  This is deliberately not an
    /// automatic fallback: a valid FluxIdd frame still wins during normal
    /// launches, including when it happens to be black or temporarily stale.
    private static let ramfbDiagnosticOverride =
        ProcessInfo.processInfo.environment["FLUX_RENDER_SOURCE"]?.lowercased() == "ramfb"

    /// This is intentionally independent from the rendering-source override:
    /// normal launches and ordinary RAMFB fallback do not inspect or write
    /// framebuffer telemetry unless the operator explicitly opts in.
    private static let ramfbDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["FLUX_RAMFB_DIAGNOSTICS"] == "1"

    private struct RAMFBDiagnosticState {
        var lastChecksum: UInt64?
        var contentChangeCount: UInt64 = 0
        var lastChangeUptime: TimeInterval?
        var lastReportUptime: TimeInterval = 0
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private struct TextureSlot {
        let texture: MTLTexture
        var inFlightCommands = 0
        var uploadReserved = false
    }

    // A texture must never be overwritten while an earlier command buffer is
    // sampling it.  The old single shared texture did exactly that and caused
    // horizontal tearing when the CPU replaced rows during GPU presentation.
    private let textureLock = NSLock()
    private var textureSlots: [TextureSlot] = []
    private var activeTextureSlot: Int?
    private var textureWidth = 0
    private var textureHeight = 0
    private var lastUploadedSource = "NONE"
    private var lastUploadedSequence: UInt32 = 0
    private var uploadBuffer: UnsafeMutableRawPointer?
    private var uploadBufferSize = 0
    private let ramfbDiagnosticLock = NSLock()
    private var ramfbDiagnosticState = RAMFBDiagnosticState()
    private var fpsWindowStart: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var fpsWindowFrames: Int = 0

    deinit {
        uploadBuffer?.deallocate()
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        super.init()

        setupPipeline()
    }

    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            print("❌ [FluxMetalRenderer] Failed to load default Metal library")
            return
        }

        let vertexFunction = library.makeFunction(name: "displayVertexShader")
        let fragmentFunction = library.makeFunction(name: "displayFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("❌ [FluxMetalRenderer] Failed to create pipeline state: \(error)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // View size changed; Metal handles viewport scaling
    }

    public private(set) var activeSource: String = "NONE"
    public private(set) var renderedFrameCount: Int = 0
    public private(set) var uniqueFramesPresentedCount: Int = 0
    public private(set) var textureRecreationCount: Int = 0
    public private(set) var lastRenderedSequence: UInt32 = 0
    private var lastPresentedSequence: UInt32 = 0
    private var lastLoggedSource: String = ""

    func draw(in view: MTKView) {
        var width = 0
        var height = 0
        var stride = 0
        var currentSource = "NONE"
        var currentSequence: UInt32 = 0
        var needsUpload = false

        var iddData: Data?

        if !Self.ramfbDiagnosticOverride,
           let metadata = FluxFrameTransport.shared.latestFrameMetadata() {
            width = metadata.width
            height = metadata.height
            stride = metadata.stride > 0 ? metadata.stride : (width * 4)
            currentSource = "FluxIdd"
            currentSequence = metadata.sequence
            needsUpload = currentSource != lastUploadedSource || currentSequence != lastUploadedSequence

            if needsUpload {
                guard let snap = FluxFrameTransport.shared.latestFrameDataSnapshot() else {
                    return
                }
                width = snap.width
                height = snap.height
                stride = snap.stride > 0 ? snap.stride : (width * 4)
                currentSequence = snap.sequence
                guard snap.data.count >= stride * height else { return }
                iddData = snap.data
            }
        } else {
            // 2. Fallback to firmware RAMFB when no valid FluxIdd frame is available
            let snap = FluxFramebuffer.shared.snapshot()
            guard snap.isConfigured,
                  let hostPtr = snap.hostPointer,
                  snap.width > 0,
                  snap.height > 0 else {
                return
            }

            width = snap.width
            height = snap.height
            stride = snap.stride > 0 ? snap.stride : (width * 4)
            let (uploadSize, overflow) = stride.multipliedReportingOverflow(by: height)
            guard !overflow,
                  uploadSize > 0,
                  stride >= width * 4,
                  uploadSize <= snap.mappedByteCapacity else {
                if Self.ramfbDiagnosticsEnabled {
                    recordInvalidRAMFBLayout(snap: snap, width: width, height: height, stride: stride, requiredBytes: overflow ? nil : uploadSize)
                }
                return
            }

            if Self.ramfbDiagnosticsEnabled {
                recordRAMFBDiagnostics(
                    snap: snap,
                    width: width,
                    height: height,
                    stride: stride,
                    byteCount: uploadSize,
                    source: Self.ramfbDiagnosticOverride ? "RAMFB_DIAGNOSTIC" : "RAMFB"
                )
            }

            if uploadBufferSize < uploadSize {
                self.uploadBuffer?.deallocate()
                self.uploadBuffer = UnsafeMutableRawPointer.allocate(byteCount: uploadSize, alignment: 64)
                self.uploadBufferSize = uploadSize
            }
            guard let uploadBuffer = self.uploadBuffer else { return }
            memcpy(uploadBuffer, hostPtr, uploadSize)
            currentSource = Self.ramfbDiagnosticOverride ? "RAMFB_DIAGNOSTIC" : "RAMFB"
            // RAMFB has no per-frame sequence.  Keep its existing behaviour,
            // but upload into an ownership-safe texture slot.
            needsUpload = true
        }

        guard width > 0, height > 0 else { return }

        if needsUpload {
            guard let slotIndex = reserveTextureForUpload(width: width, height: height) else {
                // All textures are still sampled by the GPU.  Present the
                // last complete frame rather than mutating an in-flight one.
                return
            }
            let region = MTLRegionMake2D(0, 0, width, height)
            let slotTexture = textureSlots[slotIndex].texture
            if let iddData {
                iddData.withUnsafeBytes { rawBytes in
                    if let baseAddress = rawBytes.baseAddress {
                        slotTexture.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: stride)
                    }
                }
            } else if let uploadBuffer = self.uploadBuffer {
                slotTexture.replace(region: region, mipmapLevel: 0, withBytes: uploadBuffer, bytesPerRow: stride)
            }
            completeTextureUpload(slotIndex: slotIndex, source: currentSource, sequence: currentSequence)
        }

        guard let pipelineState = self.pipelineState,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        guard let (slotIndex, texture) = reserveActiveTextureForRender() else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            completeTextureRender(slotIndex: slotIndex)
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)

        let viewWidth = view.bounds.width
        let viewHeight = view.bounds.height
        let drawableWidth = view.drawableSize.width
        let drawableHeight = view.drawableSize.height

        if viewWidth > 0 && viewHeight > 0 && drawableWidth > 0 && drawableHeight > 0 {
            if FluxDisplayManager.shared.fillScreen {
                let viewport = MTLViewport(
                    originX: 0,
                    originY: 0,
                    width: Double(drawableWidth),
                    height: Double(drawableHeight),
                    znear: 0.0,
                    zfar: 1.0
                )
                encoder.setViewport(viewport)
            } else {
                let fbAspect = CGFloat(width) / CGFloat(height)
                let viewAspect = viewWidth / viewHeight
                let renderWidth: CGFloat
                let renderHeight: CGFloat
                let offsetX: CGFloat
                let offsetY: CGFloat
                if viewAspect > fbAspect {
                    renderHeight = viewHeight
                    renderWidth = viewHeight * fbAspect
                    offsetX = (viewWidth - renderWidth) / 2.0
                    offsetY = 0
                } else {
                    renderWidth = viewWidth
                    renderHeight = viewWidth / fbAspect
                    offsetX = 0
                    offsetY = (viewHeight - renderHeight) / 2.0
                }
                let scaleX = drawableWidth / viewWidth
                let scaleY = drawableHeight / viewHeight
                let viewport = MTLViewport(
                    originX: Double(offsetX * scaleX),
                    originY: Double(offsetY * scaleY),
                    width: Double(renderWidth * scaleX),
                    height: Double(renderHeight * scaleY),
                    znear: 0.0,
                    zfar: 1.0
                )
                encoder.setViewport(viewport)
            }
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.completeTextureRender(slotIndex: slotIndex)
        }
        commandBuffer.commit()

        let isNewUnique = (currentSource == "FluxIdd" && currentSequence > 0 && currentSequence != lastPresentedSequence)
        if isNewUnique {
            lastPresentedSequence = currentSequence
            uniqueFramesPresentedCount += 1
        }

        renderedFrameCount += 1
        activeSource = currentSource
        lastRenderedSequence = currentSequence
        FluxFrameTransport.shared.recordRenderedFrame(source: currentSource, sequence: currentSequence, isNewUniqueFrame: isNewUnique)

        fpsWindowFrames += 1
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - fpsWindowStart
        if elapsed >= 1.0 {
            let fps = Double(fpsWindowFrames) / elapsed
            FluxDisplayManager.shared.updateRenderTelemetry(source: currentSource, fps: fps)
            fpsWindowStart = now
            fpsWindowFrames = 0
        }

        if currentSource != lastLoggedSource {
            lastLoggedSource = currentSource
            print("🎬 [FluxMetalRenderer] Active display source switched to: \(currentSource) (\(width)x\(height), frame #\(renderedFrameCount))")
        }
    }

    private func reserveTextureForUpload(width: Int, height: Int) -> Int? {
        textureLock.lock()
        defer { textureLock.unlock() }

        if textureWidth != width || textureHeight != height || textureSlots.isEmpty {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            let slots = (0..<3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard slots.count == 3 else { return nil }
            textureSlots = slots.map { TextureSlot(texture: $0) }
            activeTextureSlot = nil
            textureWidth = width
            textureHeight = height
            textureRecreationCount += 1
            print("🖥️ [FluxMetalRenderer] Created synchronized texture ring \(width)x\(height) (recreations=\(textureRecreationCount))")
        }

        guard let index = textureSlots.indices.first(where: {
            !textureSlots[$0].uploadReserved && textureSlots[$0].inFlightCommands == 0
        }) else {
            return nil
        }
        textureSlots[index].uploadReserved = true
        return index
    }

    private func completeTextureUpload(slotIndex: Int, source: String, sequence: UInt32) {
        textureLock.lock()
        textureSlots[slotIndex].uploadReserved = false
        activeTextureSlot = slotIndex
        lastUploadedSource = source
        lastUploadedSequence = sequence
        textureLock.unlock()
    }

    private func reserveActiveTextureForRender() -> (Int, MTLTexture)? {
        textureLock.lock()
        defer { textureLock.unlock() }
        guard let index = activeTextureSlot else { return nil }
        textureSlots[index].inFlightCommands += 1
        return (index, textureSlots[index].texture)
    }

    private func completeTextureRender(slotIndex: Int) {
        textureLock.lock()
        defer { textureLock.unlock() }
        guard textureSlots.indices.contains(slotIndex), textureSlots[slotIndex].inFlightCommands > 0 else { return }
        textureSlots[slotIndex].inFlightCommands -= 1
    }

    // MARK: - Opt-in RAMFB diagnostics

    /// Samples the exact guest-RAM bytes immediately before they are copied to
    /// Metal.  FNV-1a is deliberately order-sensitive; sampling is capped at
    /// once per second to keep a 1920x1080 framebuffer diagnostic bounded.
    private func recordRAMFBDiagnostics(
        snap: (isConfigured: Bool, width: Int, height: Int, stride: Int, fourcc: UInt32, guestAddress: UInt64, hostPointer: UnsafeMutableRawPointer?, mappedByteCapacity: Int, version: UInt64),
        width: Int,
        height: Int,
        stride: Int,
        byteCount: Int,
        source: String
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        ramfbDiagnosticLock.lock()
        let shouldSample = now - ramfbDiagnosticState.lastReportUptime >= 1.0
        ramfbDiagnosticLock.unlock()
        guard shouldSample, let hostPointer = snap.hostPointer else { return }

        let firstOffset = 0
        let centerOffset = (height / 2) * stride + (width / 2) * 4
        let lastOffset = (height - 1) * stride + (width - 1) * 4
        guard centerOffset >= 0, lastOffset >= 0,
              centerOffset + 4 <= byteCount,
              lastOffset + 4 <= byteCount else {
            recordInvalidRAMFBLayout(snap: snap, width: width, height: height, stride: stride, requiredBytes: byteCount)
            return
        }

        let bytes = UnsafeRawBufferPointer(start: hostPointer, count: byteCount)
        var checksum: UInt64 = 0xcbf29ce484222325 // FNV-1a 64-bit offset basis
        for byte in bytes {
            checksum ^= UInt64(byte)
            checksum &*= 0x100000001b3
        }
        // Alpha alone must not make an opaque black framebuffer look live.
        // Count B/G/R pixels while the already rate-limited diagnostic is
        // active; padding bytes are deliberately excluded.
        var nonBlackPixelCount = 0
        for y in 0..<height {
            let rowOffset = y * stride
            for x in 0..<width {
                let pixelOffset = rowOffset + x * 4
                if bytes[pixelOffset] != 0 || bytes[pixelOffset + 1] != 0 || bytes[pixelOffset + 2] != 0 {
                    nonBlackPixelCount &+= 1
                }
            }
        }
        let first = hostPointer.loadUnaligned(fromByteOffset: firstOffset, as: UInt32.self)
        let center = hostPointer.loadUnaligned(fromByteOffset: centerOffset, as: UInt32.self)
        let last = hostPointer.loadUnaligned(fromByteOffset: lastOffset, as: UInt32.self)

        ramfbDiagnosticLock.lock()
        if let previous = ramfbDiagnosticState.lastChecksum, previous != checksum {
            ramfbDiagnosticState.contentChangeCount &+= 1
            ramfbDiagnosticState.lastChangeUptime = now
        } else if ramfbDiagnosticState.lastChecksum == nil {
            ramfbDiagnosticState.lastChangeUptime = now
        }
        ramfbDiagnosticState.lastChecksum = checksum
        ramfbDiagnosticState.lastReportUptime = now
        let changeCount = ramfbDiagnosticState.contentChangeCount
        let age = ramfbDiagnosticState.lastChangeUptime.map { now - $0 } ?? 0
        ramfbDiagnosticLock.unlock()

        let report = [
            "RAMFB_DIAGNOSTICS=ENABLED",
            "RAMFB_MAPPING_VALID=YES",
            "RAMFB_WIDTH=\(width)",
            "RAMFB_HEIGHT=\(height)",
            "RAMFB_STRIDE=\(stride)",
            String(format: "RAMFB_FOURCC=0x%08X", snap.fourcc),
            String(format: "RAMFB_GUEST_ADDRESS=0x%016llX", snap.guestAddress),
            "RAMFB_MAPPED_BYTE_CAPACITY=\(snap.mappedByteCapacity)",
            "RAMFB_SAMPLED_BYTE_COUNT=\(byteCount)",
            String(format: "RAMFB_PIXEL_FIRST=0x%08X", first),
            String(format: "RAMFB_PIXEL_CENTER=0x%08X", center),
            String(format: "RAMFB_PIXEL_LAST=0x%08X", last),
            String(format: "RAMFB_FNV1A64=0x%016llX", checksum),
            "RAMFB_NONBLACK_PIXEL_COUNT=\(nonBlackPixelCount)",
            "RAMFB_CONTENT_CHANGE_COUNT=\(changeCount)",
            String(format: "RAMFB_CONTENT_CHANGE_AGE_SECONDS=%.3f", age),
            "METAL_RENDER_SOURCE=\(source)",
            "RAMFB_FRAMEBUFFER_VERSION=\(snap.version)"
        ].joined(separator: "\n") + "\n"
        let path = FluxVM.defaultAppDirectory() + "/ramfb_diagnostic_report.txt"
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func recordInvalidRAMFBLayout(
        snap: (isConfigured: Bool, width: Int, height: Int, stride: Int, fourcc: UInt32, guestAddress: UInt64, hostPointer: UnsafeMutableRawPointer?, mappedByteCapacity: Int, version: UInt64),
        width: Int,
        height: Int,
        stride: Int,
        requiredBytes: Int?
    ) {
        guard Self.ramfbDiagnosticsEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        ramfbDiagnosticLock.lock()
        guard now - ramfbDiagnosticState.lastReportUptime >= 1.0 else {
            ramfbDiagnosticLock.unlock()
            return
        }
        ramfbDiagnosticState.lastReportUptime = now
        ramfbDiagnosticLock.unlock()
        let report = [
            "RAMFB_DIAGNOSTICS=ENABLED",
            "RAMFB_MAPPING_VALID=NO",
            "RAMFB_WIDTH=\(width)",
            "RAMFB_HEIGHT=\(height)",
            "RAMFB_STRIDE=\(stride)",
            String(format: "RAMFB_FOURCC=0x%08X", snap.fourcc),
            String(format: "RAMFB_GUEST_ADDRESS=0x%016llX", snap.guestAddress),
            "RAMFB_MAPPED_BYTE_CAPACITY=\(snap.mappedByteCapacity)",
            "RAMFB_REQUIRED_BYTE_COUNT=\(requiredBytes.map(String.init) ?? "OVERFLOW")",
            "METAL_RENDER_SOURCE=UNAVAILABLE"
        ].joined(separator: "\n") + "\n"
        try? report.write(toFile: FluxVM.defaultAppDirectory() + "/ramfb_diagnostic_report.txt", atomically: true, encoding: .utf8)
    }
}
