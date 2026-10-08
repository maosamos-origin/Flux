import Foundation

/// Frame transport protocol header (60 bytes packed, little-endian).
/// Matches the C++ struct FluxFrameTransportHeader in SwapChain.cpp.
public struct FluxFrameTransportHeader {
    public static let magicValue: UInt64 = 0x4E41525446584C46 // "FLXFTRAN" in little-endian
    public static let expectedVersion: UInt32 = 1

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

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 60 else { return nil }
        self = bytes.withUnsafeBytes { raw in
            raw.load(as: FluxFrameTransportHeader.self)
        }
        guard magic == Self.magicValue && version == Self.expectedVersion else {
            return nil
        }
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

    // Telemetry fields
    public private(set) var isConnected: Bool = false
    public private(set) var frameCount: Int = 0
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

    /// Consumes a single byte from the UART Data Register.
    /// Returns `true` if the byte was absorbed as part of a binary frame transport packet.
    /// Returns `false` if the byte is normal console output.
    public func consumeByte(_ byte: UInt8) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .idle:
            // Match the 8 magic bytes: "FLXFTRAN"
            if byte == Self.magicBytes[magicBuffer.count] {
                magicBuffer.append(byte)
                if magicBuffer.count == Self.magicBytes.count {
                    // Magic detected! Switch to receiving the rest of the 60-byte header
                    state = .header
                    headerBuffer = magicBuffer
                    magicBuffer.removeAll(keepingCapacity: true)
                    return true
                }
                return true
            } else {
                // Not matching next expected magic byte.
                magicBuffer.removeAll(keepingCapacity: true)
                if byte == Self.magicBytes[0] {
                    magicBuffer.append(byte)
                    return true
                }
                return false
            }

        case .header:
            headerBuffer.append(byte)
            if headerBuffer.count == 60 {
                if let hdr = FluxFrameTransportHeader(bytes: headerBuffer) {
                    currentHeader = hdr
                    expectedPayloadSize = Int(hdr.dataSize)
                    payloadBuffer.removeAll(keepingCapacity: true)
                    payloadBuffer.reserveCapacity(expectedPayloadSize)
                    state = .payload
                } else {
                    // Invalid header, reset
                    state = .idle
                    headerBuffer.removeAll(keepingCapacity: true)
                }
            }
            return true

        case .payload:
            payloadBuffer.append(byte)
            if payloadBuffer.count == expectedPayloadSize {
                processCompletedPayload()
                state = .idle
                headerBuffer.removeAll(keepingCapacity: true)
                currentHeader = nil
            }
            return true
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
                p0 = raw.load(fromByteOffset: 0, as: UInt32.self)
                let centerOffset = (height / 2) * stride + (width / 2) * 4
                if centerOffset + 4 <= payloadBuffer.count {
                    pCenter = raw.load(fromByteOffset: centerOffset, as: UInt32.self)
                }
                let lastOffset = (height - 1) * stride + (width - 1) * 4
                if lastOffset + 4 <= payloadBuffer.count {
                    pLast = raw.load(fromByteOffset: lastOffset, as: UInt32.self)
                }
            }
        }

        let checksumMatches = (calculatedChecksum == hdr.checksum)
        let dimensionsValid = (hdr.width == 800 && hdr.height == 600 && hdr.dataSize == 1920000)
        let sequenceIncreasing = sequenceHistory.isEmpty || (hdr.sequence > sequenceHistory.last!)

        let isValid = checksumMatches && dimensionsValid && sequenceIncreasing

        isConnected = true
        frameCount += 1
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
        lastFrameValid = isValid
        latestFrameData = Data(payloadBuffer)

        print("📸 [FRAME-TRANSPORT] Frame #\(frameCount) received: seq=\(hdr.sequence), \(hdr.width)x\(hdr.height), stride=\(hdr.stride), bytes=\(payloadBuffer.count), checksum=0x\(String(calculatedChecksum, radix: 16)), P0=0x\(String(p0, radix: 16)), PC=0x\(String(pCenter, radix: 16)), PL=0x\(String(pLast, radix: 16)) valid=\(isValid)")

        writeStatusReport()
    }

    /// Writes diagnostic report to disk for retrieval.
    public func writeStatusReport() {
        let appDir = FluxVM.defaultAppDirectory()
        let reportPath = appDir + "/flux_frame_transport_report.txt"

        var lines = [
            "FRAME_TRANSPORT_CONNECTED=" + (isConnected ? "YES" : "NO"),
            "FRAME_TRANSPORT_SEQUENCE=\(lastSequence)",
            "FRAME_TRANSPORT_WIDTH=\(lastWidth)",
            "FRAME_TRANSPORT_HEIGHT=\(lastHeight)",
            "FRAME_TRANSPORT_FORMAT=\(lastFormat)",
            "FRAME_TRANSPORT_DATA_SIZE=\(lastDataSize)",
            "FRAME_TRANSPORT_FRAME_COUNT=\(frameCount)",
            "FRAME_TRANSPORT_LAST_FRAME_VALID=" + (lastFrameValid ? "YES" : "NO"),
            "FRAME_CHECKSUM=0x" + String(format: "%08X", lastChecksum),
            "PIXEL_0=0x" + String(format: "%08X", lastPixel0),
            "PIXEL_CENTER=0x" + String(format: "%08X", lastPixelCenter),
            "PIXEL_LAST=0x" + String(format: "%08X", lastPixelLast),
            "SEQUENCE_HISTORY=" + sequenceHistory.map { String($0) }.joined(separator: ",")
        ]

        let content = lines.joined(separator: "\r\n") + "\r\n"
        try? content.write(toFile: reportPath, atomically: true, encoding: .utf8)
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
        FRAME_TRANSPORT_LAST_FRAME_VALID=\(lastFrameValid ? "YES" : "NO")
        FRAME_CHECKSUM=0x\(String(format: "%08X", lastChecksum))
        PIXEL_0=0x\(String(format: "%08X", lastPixel0))
        PIXEL_CENTER=0x\(String(format: "%08X", lastPixelCenter))
        PIXEL_LAST=0x\(String(format: "%08X", lastPixelLast))
        SEQUENCE_HISTORY=\(sequenceHistory.map { String($0) }.joined(separator: ","))
        """
    }
}
