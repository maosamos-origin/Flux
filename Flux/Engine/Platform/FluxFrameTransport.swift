import Foundation

/// Frame transport protocol header (60 bytes packed, little-endian).
/// Matches the C++ struct FluxFrameTransportHeader in SwapChain.cpp.
public struct FluxFrameTransportHeader {
    public static let magicValue: UInt64 = 0x4E41525446584C46 // "FLXFTRAN" in little-endian
    public static let expectedVersion: UInt32 = 1
    public static let statusReady: UInt32 = 2
    public static let formatBGRA8: UInt32 = 87 // DXGI_FORMAT_B8G8R8A8_UNORM

    public static let expectedWidth: UInt32 = 800
    public static let expectedHeight: UInt32 = 600
    public static let expectedStride: UInt32 = 3200
    public static let expectedDataSize: UInt32 = 1920000
    public static let maxPayloadSize: UInt32 = 16 * 1024 * 1024 // 16 MB bounded maximum

    public var magic: UInt64
    public var version: UInt32
    public var sequence: UInt32
    public var width: UInt32
    public var height: UInt32
    public var stride: UInt32
    public var pixelFormat: UInt32
    public var dataSize: UInt32
    public var status: UInt32
    public var checksum: UInt32
    public var pixel0: UInt32
    public var pixelCenter: UInt32
    public var pixelLast: UInt32
    public var reserved: UInt32
}

extension FluxFrameTransportHeader {
    /// Strictly validates all header fields before returning a valid header instance.
    /// Rejects any header with invalid magic, version, format, dimensions, stride, or payload size.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 60 else { return nil }
        guard let hdr = bytes.withUnsafeBytes({ raw -> FluxFrameTransportHeader? in
            let m = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            guard m == Self.magicValue else { return nil }

            let v = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            guard v == Self.expectedVersion else { return nil }

            let seq = raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            guard seq > 0 else { return nil }

            let w = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            let h = raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            guard w == Self.expectedWidth && h == Self.expectedHeight else { return nil }

            let str = raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
            guard str >= w * 4 else { return nil }

            let pf = raw.loadUnaligned(fromByteOffset: 28, as: UInt32.self)
            guard pf == Self.formatBGRA8 else { return nil }

            let (calcSize, overflow) = str.multipliedReportingOverflow(by: h)
            guard !overflow else { return nil }

            let ds = raw.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
            guard ds == calcSize && ds == Self.expectedDataSize && ds <= Self.maxPayloadSize else { return nil }

            let st = raw.loadUnaligned(fromByteOffset: 36, as: UInt32.self)
            guard st == Self.statusReady else { return nil }

            let ck = raw.loadUnaligned(fromByteOffset: 40, as: UInt32.self)
            let p0 = raw.loadUnaligned(fromByteOffset: 44, as: UInt32.self)
            let pc = raw.loadUnaligned(fromByteOffset: 48, as: UInt32.self)
            let pl = raw.loadUnaligned(fromByteOffset: 52, as: UInt32.self)
            let res = raw.loadUnaligned(fromByteOffset: 56, as: UInt32.self)

            return FluxFrameTransportHeader(
                magic: m,
                version: v,
                sequence: seq,
                width: w,
                height: h,
                stride: str,
                pixelFormat: pf,
                dataSize: ds,
                status: st,
                checksum: ck,
                pixel0: p0,
                pixelCenter: pc,
                pixelLast: pl,
                reserved: res
            )
        }) else {
            return nil
        }
        self = hdr
    }
}

/// Receives, validates, and stores frames transferred from the Windows guest via the transport stream.
public final class FluxFrameTransport: @unchecked Sendable {
    public static let shared = FluxFrameTransport()

    private let lock = NSLock()

    public enum ReceiverState {
        case idle
        case header
        case payload
    }

    private var state: ReceiverState = .idle
    private var magicBuffer: [UInt8] = []
    private var headerBuffer: [UInt8] = []
    private var payloadBuffer: [UInt8] = []
    private var currentHeader: FluxFrameTransportHeader?
    private var expectedPayloadSize: Int = 0

    // Magic bytes: "FLXFTRAN"
    public static let magicBytes: [UInt8] = [
        UInt8(ascii: "F"), UInt8(ascii: "L"), UInt8(ascii: "X"), UInt8(ascii: "F"),
        UInt8(ascii: "T"), UInt8(ascii: "R"), UInt8(ascii: "A"), UInt8(ascii: "N")
    ]

    // Session and Telemetry fields
    public private(set) var isConnected: Bool = false
    public private(set) var frameCount: Int = 0
    public private(set) var sessionCount: Int = 0
    public private(set) var sessionFrameCount: Int = 0
    private var sessionActive: Bool = false
    private var sessionLastSequence: UInt32 = 0

    public private(set) var lastSequence: UInt32 = 0
    public private(set) var lastWidth: UInt32 = 0
    public private(set) var lastHeight: UInt32 = 0
    public private(set) var lastStride: UInt32 = 0
    public private(set) var lastFormat: String = "UNKNOWN"
    public private(set) var lastDataSize: Int = 0
    public private(set) var lastChecksum: UInt32 = 0
    public private(set) var lastPixel0: UInt32 = 0
    public private(set) var lastPixelCenter: UInt32 = 0
    public private(set) var lastPixelLast: UInt32 = 0
    public private(set) var lastFrameValid: Bool = false
    public private(set) var sequenceHistory: [UInt32] = []
    public private(set) var latestFrameData: Data? = nil

    private init() {}

    /// Consumes a block of bytes from the verified transport stream channel (NSID 2 writes).
    public func consumeBytes(_ ptr: UnsafeRawPointer, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        var offset = 0
        let raw = ptr.assumingMemoryBound(to: UInt8.self)

        while offset < count {
            switch state {
            case .idle:
                let b = raw[offset]
                offset += 1
                if b == Self.magicBytes[magicBuffer.count] {
                    magicBuffer.append(b)
                    if magicBuffer.count == Self.magicBytes.count {
                        state = .header
                        headerBuffer = magicBuffer
                        magicBuffer.removeAll(keepingCapacity: true)
                    }
                } else {
                    magicBuffer.removeAll(keepingCapacity: true)
                    if b == Self.magicBytes[0] {
                        magicBuffer.append(b)
                    }
                }

            case .header:
                let needed = 60 - headerBuffer.count
                let available = count - offset
                let toCopy = (needed < available) ? needed : available
                headerBuffer.append(contentsOf: UnsafeBufferPointer(start: raw + offset, count: toCopy))
                offset += toCopy

                if headerBuffer.count == 60 {
                    if let hdr = FluxFrameTransportHeader(bytes: headerBuffer) {
                        // Sequence monotonicity and session handling:
                        if hdr.sequence == 1 {
                            // Driver session started or reconnected
                            sessionActive = true
                            sessionCount += 1
                            sessionFrameCount = 0
                            sessionLastSequence = 0
                            print("📸 [FRAME-TRANSPORT] Session #\(sessionCount) started (seq=1)")
                        } else if !sessionActive || hdr.sequence <= sessionLastSequence {
                            print("⚠️ [FRAME-TRANSPORT] Rejected non-monotonic sequence \(hdr.sequence) in session #\(sessionCount) (expected > \(sessionLastSequence))")
                            state = .idle
                            headerBuffer.removeAll(keepingCapacity: true)
                            continue
                        }

                        currentHeader = hdr
                        expectedPayloadSize = Int(hdr.dataSize)
                        payloadBuffer.removeAll(keepingCapacity: true)
                        payloadBuffer.reserveCapacity(expectedPayloadSize)
                        state = .payload
                    } else {
                        state = .idle
                        headerBuffer.removeAll(keepingCapacity: true)
                    }
                }

            case .payload:
                // Check if a new frame header arrived early at this block boundary
                // (e.g. previous frame truncated, guest aborted, or fresh frame started)
                if (count - offset) >= 60 {
                    let peekMagic = UnsafeRawPointer(raw + offset).loadUnaligned(as: UInt64.self)
                    if peekMagic == FluxFrameTransportHeader.magicValue {
                        let candidateBytes = Array(UnsafeBufferPointer(start: raw + offset, count: 60))
                        if let newHdr = FluxFrameTransportHeader(bytes: candidateBytes) {
                            if newHdr.sequence == 1 || (sessionActive && newHdr.sequence > sessionLastSequence) {
                                print("⚠️ [FRAME-TRANSPORT] New frame header seq=\(newHdr.sequence) arrived early while in payload (have \(payloadBuffer.count)/\(expectedPayloadSize)); resynchronizing")
                                state = .idle
                                magicBuffer.removeAll(keepingCapacity: true)
                                headerBuffer.removeAll(keepingCapacity: true)
                                payloadBuffer.removeAll(keepingCapacity: true)
                                currentHeader = nil
                                continue
                            }
                        }
                    }
                }

                let needed = expectedPayloadSize - payloadBuffer.count
                let available = count - offset
                let toCopy = (needed < available) ? needed : available
                payloadBuffer.append(contentsOf: UnsafeBufferPointer(start: raw + offset, count: toCopy))
                offset += toCopy

                if payloadBuffer.count == expectedPayloadSize {
                    processCompletedPayload()
                    state = .idle
                    headerBuffer.removeAll(keepingCapacity: true)
                    currentHeader = nil
                }
            }
        }
    }

    private func processCompletedPayload() {
        guard let hdr = currentHeader else { return }

        // 1. Verify 32-bit additive checksum
        var calculatedChecksum: UInt32 = 0
        for b in payloadBuffer {
            calculatedChecksum &+= UInt32(b)
        }

        // 2. Sample pixels
        let stride = Int(hdr.stride)
        let width = Int(hdr.width)
        let height = Int(hdr.height)

        var p0: UInt32 = 0
        var pCenter: UInt32 = 0
        var pLast: UInt32 = 0

        if payloadBuffer.count >= 4 {
            payloadBuffer.withUnsafeBytes { raw in
                p0 = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                let centerOffset = (height / 2) * stride + (width / 2) * 4
                if centerOffset + 4 <= payloadBuffer.count {
                    pCenter = raw.loadUnaligned(fromByteOffset: centerOffset, as: UInt32.self)
                }
                let lastOffset = (height - 1) * stride + (width - 1) * 4
                if lastOffset + 4 <= payloadBuffer.count {
                    pLast = raw.loadUnaligned(fromByteOffset: lastOffset, as: UInt32.self)
                }
            }
        }

        let checksumMatches = (calculatedChecksum == hdr.checksum)
        let pixelsMatch = (p0 == hdr.pixel0 && pCenter == hdr.pixelCenter && pLast == hdr.pixelLast)
        let isValid = checksumMatches && pixelsMatch

        guard isValid else {
            lastFrameValid = false
            print("⚠️ [FRAME-TRANSPORT] Integrity check failed for seq=\(hdr.sequence): checksumMatch=\(checksumMatches) (calc=0x\(String(calculatedChecksum, radix: 16)), hdr=0x\(String(hdr.checksum, radix: 16))), pixelsMatch=\(pixelsMatch); discarding frame")
            writeStatusReport()
            return
        }

        isConnected = true
        frameCount += 1
        sessionFrameCount += 1
        sessionLastSequence = hdr.sequence
        lastSequence = hdr.sequence
        sequenceHistory.append(hdr.sequence)
        lastWidth = hdr.width
        lastHeight = hdr.height
        lastStride = hdr.stride
        lastFormat = (hdr.pixelFormat == 87) ? "BGRA8" : "FORMAT_\(hdr.pixelFormat)"
        lastDataSize = payloadBuffer.count
        lastChecksum = calculatedChecksum
        lastPixel0 = p0
        lastPixelCenter = pCenter
        lastPixelLast = pLast
        lastFrameValid = true
        latestFrameData = Data(payloadBuffer)

        print("📸 [FRAME-TRANSPORT] Session #\(sessionCount) Frame #\(frameCount) received: seq=\(hdr.sequence), \(hdr.width)x\(hdr.height), stride=\(hdr.stride), bytes=\(payloadBuffer.count), checksum=0x\(String(calculatedChecksum, radix: 16)), P0=0x\(String(p0, radix: 16)), PC=0x\(String(pCenter, radix: 16)), PL=0x\(String(pLast, radix: 16)) valid=true")

        writeStatusReport()
    }

    // Render tracking fields
    public private(set) var renderedFrameCount: Int = 0
    public private(set) var uniqueFramesPresentedCount: Int = 0
    public private(set) var lastRenderedSequence: UInt32 = 0
    public private(set) var activeRenderSource: String = "NONE"

    public func recordRenderedFrame(source: String, sequence: UInt32, isNewUniqueFrame: Bool = false) {
        lock.lock()
        renderedFrameCount += 1
        if isNewUniqueFrame {
            uniqueFramesPresentedCount += 1
        }
        activeRenderSource = source
        lastRenderedSequence = sequence
        lock.unlock()
    }

    /// Safely copies the latest validated frame into destination pointer without heap allocation.
    /// Returns frame metadata if a valid frame is ready, or nil if no valid frame exists.
    public func copyLatestFrame(to dest: UnsafeMutableRawPointer, maxBytes: Int) -> (width: Int, height: Int, stride: Int, sequence: UInt32)? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = latestFrameData,
              lastFrameValid,
              lastWidth > 0,
              lastHeight > 0,
              maxBytes >= data.count else {
            return nil
        }

        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(dest, base, data.count)
            }
        }

        return (Int(lastWidth), Int(lastHeight), Int(lastStride), lastSequence)
    }

    /// Provides access to the latest validated frame for screenshots.
    public func latestFrameDataSnapshot() -> (data: Data, width: Int, height: Int, stride: Int, sequence: UInt32)? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = latestFrameData, lastFrameValid, lastWidth > 0, lastHeight > 0 else { return nil }
        return (data, Int(lastWidth), Int(lastHeight), Int(lastStride), lastSequence)
    }

    /// Writes diagnostic report to disk for retrieval.
    public func writeStatusReport() {
        let appDir = FluxVM.defaultAppDirectory()
        let reportPath = appDir + "/flux_frame_transport_report.txt"
        let localReportPath = FileManager.default.currentDirectoryPath + "/flux_frame_transport_report.txt"

        let lines = [
            "FRAME_TRANSPORT_CONNECTED=" + (isConnected ? "YES" : "NO"),
            "FRAME_TRANSPORT_SEQUENCE=\(lastSequence)",
            "FRAME_TRANSPORT_WIDTH=\(lastWidth)",
            "FRAME_TRANSPORT_HEIGHT=\(lastHeight)",
            "FRAME_TRANSPORT_FORMAT=\(lastFormat)",
            "FRAME_TRANSPORT_DATA_SIZE=\(lastDataSize)",
            "FRAME_TRANSPORT_FRAME_COUNT=\(frameCount)",
            "FRAME_TRANSPORT_SESSION_COUNT=\(sessionCount)",
            "FRAME_TRANSPORT_SESSION_FRAME_COUNT=\(sessionFrameCount)",
            "FRAME_TRANSPORT_LAST_FRAME_VALID=" + (lastFrameValid ? "YES" : "NO"),
            "FRAME_CHECKSUM=0x" + String(format: "%08X", lastChecksum),
            "PIXEL_0=0x" + String(format: "%08X", lastPixel0),
            "PIXEL_CENTER=0x" + String(format: "%08X", lastPixelCenter),
            "PIXEL_LAST=0x" + String(format: "%08X", lastPixelLast),
            "SEQUENCE_HISTORY=" + sequenceHistory.map { String($0) }.joined(separator: ","),
            "RENDERED_FRAME_COUNT=\(renderedFrameCount)",
            "UNIQUE_FRAMES_PRESENTED=\(uniqueFramesPresentedCount)",
            "RENDERED_SOURCE=\(activeRenderSource)",
            "LAST_RENDERED_SEQUENCE=\(lastRenderedSequence)"
        ]

        let content = lines.joined(separator: "\r\n") + "\r\n"
        try? content.write(toFile: reportPath, atomically: true, encoding: .utf8)
        try? content.write(toFile: localReportPath, atomically: true, encoding: .utf8)
    }

    /// Formats the current report string.
    public func formattedReport() -> String {
        lock.lock()
        defer { lock.unlock() }

        return """
        FRAME_TRANSPORT_CONNECTED=\(isConnected ? "YES" : "NO")
        FRAME_TRANSPORT_SEQUENCE=\(lastSequence)
        FRAME_TRANSPORT_WIDTH=\(lastWidth)
        FRAME_TRANSPORT_HEIGHT=\(lastHeight)
        FRAME_TRANSPORT_FORMAT=\(lastFormat)
        FRAME_TRANSPORT_DATA_SIZE=\(lastDataSize)
        FRAME_TRANSPORT_FRAME_COUNT=\(frameCount)
        FRAME_TRANSPORT_SESSION_COUNT=\(sessionCount)
        FRAME_TRANSPORT_SESSION_FRAME_COUNT=\(sessionFrameCount)
        FRAME_TRANSPORT_LAST_FRAME_VALID=\(lastFrameValid ? "YES" : "NO")
        FRAME_CHECKSUM=0x\(String(format: "%08X", lastChecksum))
        PIXEL_0=0x\(String(format: "%08X", lastPixel0))
        PIXEL_CENTER=0x\(String(format: "%08X", lastPixelCenter))
        PIXEL_LAST=0x\(String(format: "%08X", lastPixelLast))
        SEQUENCE_HISTORY=\(sequenceHistory.map { String($0) }.joined(separator: ","))
        RENDERED_FRAME_COUNT=\(renderedFrameCount)
        UNIQUE_FRAMES_PRESENTED=\(uniqueFramesPresentedCount)
        RENDERED_SOURCE=\(activeRenderSource)
        LAST_RENDERED_SEQUENCE=\(lastRenderedSequence)
        """
    }
}
