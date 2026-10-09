import Foundation
import MetalKit

final class FluxMetalRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var uploadBuffer: UnsafeMutableRawPointer?
    private var uploadBufferSize = 0

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
    public private(set) var lastRenderedSequence: UInt32 = 0
    private var lastLoggedSource: String = ""

    func draw(in view: MTKView) {
        var width = 0
        var height = 0
        var stride = 0
        var currentSource = "NONE"
        var currentSequence: UInt32 = 0

        // 1. Check for native FluxIdd Indirect Display frame first
        let iddSize = 800 * 600 * 4
        if uploadBufferSize < iddSize {
            uploadBuffer?.deallocate()
            uploadBuffer = UnsafeMutableRawPointer.allocate(byteCount: iddSize, alignment: 64)
            uploadBufferSize = iddSize
        }

        if let uploadBuffer = self.uploadBuffer,
           let iddFrame = FluxFrameTransport.shared.copyLatestFrame(to: uploadBuffer, maxBytes: uploadBufferSize) {
            width = iddFrame.width
            height = iddFrame.height
            stride = iddFrame.stride > 0 ? iddFrame.stride : (width * 4)
            currentSource = "FluxIdd"
            currentSequence = iddFrame.sequence
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
            let uploadSize = stride * height
            guard uploadSize > 0 else { return }

            if uploadBufferSize < uploadSize {
                self.uploadBuffer?.deallocate()
                self.uploadBuffer = UnsafeMutableRawPointer.allocate(byteCount: uploadSize, alignment: 64)
                self.uploadBufferSize = uploadSize
            }
            guard let uploadBuffer = self.uploadBuffer else { return }
            memcpy(uploadBuffer, hostPtr, uploadSize)
            currentSource = "RAMFB"
        }

        guard let uploadBuffer = self.uploadBuffer, width > 0, height > 0 else { return }

        // (Re)create texture if needed
        if texture == nil || texture?.width != width || texture?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.storageMode = .shared
            desc.usage = [.shaderRead]
            self.texture = device.makeTexture(descriptor: desc)
            print("🖥️ [FluxMetalRenderer] Created Metal texture \(width)x\(height) for source=\(currentSource)")
        }

        guard let texture = self.texture,
              let pipelineState = self.pipelineState,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        // Upload framebuffer pixels into Metal texture
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: uploadBuffer, bytesPerRow: stride)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)

        let viewWidth = view.bounds.width
        let viewHeight = view.bounds.height
        let drawableWidth = view.drawableSize.width
        let drawableHeight = view.drawableSize.height

        if viewWidth > 0 && viewHeight > 0 && drawableWidth > 0 && drawableHeight > 0 {
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

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        renderedFrameCount += 1
        activeSource = currentSource
        lastRenderedSequence = currentSequence
        FluxFrameTransport.shared.recordRenderedFrame(source: currentSource, sequence: currentSequence)

        if currentSource != lastLoggedSource {
            lastLoggedSource = currentSource
            print("🎬 [FluxMetalRenderer] Active display source switched to: \(currentSource) (\(width)x\(height), frame #\(renderedFrameCount))")
        }
    }
}
