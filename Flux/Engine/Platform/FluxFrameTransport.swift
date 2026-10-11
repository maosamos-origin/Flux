import Foundation

/// Frame transport header (60 bytes packed, little-endian), shared with
/// `Guest/Windows/FluxIdd/SwapChain.cpp`.
///
/// v1 byte layout: 0 magic[8], 8 version, 12 sequence, 16 width, 20 height,
/// 24 RowPitch, 28 DXGI format, 32 payload length, 36 READY status,
/// 40 additive checksum, 44/48/52 pixel samples, and 56 reserved=0.
/// v2 keeps the binary size/layout so old storage allocations remain valid;
/// byte 56 is CRC-32C/ISCSI of exactly the mapped payload bytes.
public struct FluxFrameTransportHeader {
    public static let magicValue: UInt64 = 0x4E41525446584C46 // "FLXFTRAN" in little-endian
    public static let headerSize = 60
    public static let legacyVersion: UInt32 = 1
    public static let diagnosticVersion: UInt32 = 2
    public static let statusReady: UInt32 = 2
    public static let formatBGRA8: UInt32 = 87 // DXGI_FORMAT_B8G8R8A8_UNORM

    public static let minWidth: UInt32 = 640
    public static let maxWidth: UInt32 = 3840
    public static let minHeight: UInt32 = 480
    public static let maxHeight: UInt32 = 2160
    public static let maxPayloadSize: UInt32 = 16 * 1024 * 1024 // 16 MB bounded maximum

    // Fallback reference constants
    public static let expectedWidth: UInt32 = 800
    public static let expectedHeight: UInt32 = 600
    public static let expectedStride: UInt32 = 3200
    public static let expectedDataSize: UInt32 = 1920000

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
        guard bytes.count >= Self.headerSize else { return nil }
        guard let hdr = bytes.withUnsafeBytes({ raw -> FluxFrameTransportHeader? in
            let m = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            guard m == Self.magicValue else { return nil }

            let v = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            // Explicitly recognize v1 and v2.  Unknown versions are rejected
            // before interpreting any payload fields.
            guard v == Self.legacyVersion || v == Self.diagnosticVersion else { return nil }

            let seq = raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            guard seq > 0 else { return nil }

            let w = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            let h = raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            guard w >= Self.minWidth && w <= Self.maxWidth && h >= Self.minHeight && h <= Self.maxHeight else { return nil }

            let str = raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
            guard str >= w * 4 else { return nil }

            let pf = raw.loadUnaligned(fromByteOffset: 28, as: UInt32.self)
            guard pf == Self.formatBGRA8 else { return nil }

            let (calcSize, overflow) = str.multipliedReportingOverflow(by: h)
            guard !overflow else { return nil }

            let ds = raw.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
            guard ds == calcSize && ds <= Self.maxPayloadSize else { return nil }

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

private struct FluxNVMeWriteDiagnostic {
    let ordinal: UInt64
    let offset: UInt64
    let length: Int
    let overlapsPrior: Bool
    let duplicatesPrior: Bool
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
    private var currentAssemblyWriteOrdinals: [UInt64] = []
    private var currentAssemblyRanges: [(offset: UInt64, length: Int)] = []
    private var currentAssemblyOverlap = false
    private var currentAssemblyDuplicate = false
    private var currentAssemblyNonContiguous = false
    private static let maximumRecordedWrites = 64
    private var recentNVMeWrites: [FluxNVMeWriteDiagnostic] = []
    private var nvmeWriteCount: UInt64 = 0
    private var nvmeWriteOverlapCount: UInt64 = 0
    private var nvmeWriteDuplicateCount: UInt64 = 0
    private var nvmeWriteNonMonotonicCount: UInt64 = 0
    private var lastNVMeWriteOffset: UInt64?
    private var rejectedHeaderCount: UInt64 = 0
    private var rejectedFrameCount: UInt64 = 0

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
    public private(set) var lastCRC32C: UInt32 = 0
    public private(set) var lastCRC32CMatches: Bool = false
    public private(set) var lastProtocolVersion: UInt32 = 0
    public private(set) var lastAssemblyWriteCount: Int = 0
    public private(set) var lastAssemblyHadOverlap: Bool = false
    public private(set) var lastAssemblyHadDuplicate: Bool = false
    public private(set) var lastAssemblyHadNonContiguousRange: Bool = false
    public private(set) var lastPixel0: UInt32 = 0
    public private(set) var lastPixelCenter: UInt32 = 0
    public private(set) var lastPixelLast: UInt32 = 0
    public private(set) var lastFrameValid: Bool = false
    public private(set) var sequenceHistory: [UInt32] = []
    public private(set) var latestFrameData: Data? = nil

    private init() {}

    /// CRC-32C/ISCSI over the exact transmitted byte sequence: reflected
    /// Castagnoli polynomial 0x82F63B78, init/final XOR 0xFFFFFFFF.
    /// `123456789` must evaluate to 0xE3069283 on both Windows and macOS.
    public static func crc32c(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0x82F6_3B78 : 0)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    public static func crc32cTestVectorPasses() -> Bool {
        crc32c(Array("123456789".utf8)) == 0xE306_9283
    }

    /// Records physical namespace-2 ranges before their bytes are parsed.  FAT
    /// overwrites may legitimately overlap, so this is diagnostic evidence and
    /// never by itself causes a frame rejection.
    public func recordNVMeWrite(offset: UInt64, length: Int, ordinal: UInt64) {
        guard length > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let end = offset &+ UInt64(length)
        let overlaps = recentNVMeWrites.contains { prior in
            let priorEnd = prior.offset &+ UInt64(prior.length)
            return offset < priorEnd && prior.offset < end
        }
        let duplicates = recentNVMeWrites.contains { $0.offset == offset && $0.length == length }
        nvmeWriteCount &+= 1
        if overlaps { nvmeWriteOverlapCount &+= 1 }
        if duplicates { nvmeWriteDuplicateCount &+= 1 }
        if let last = lastNVMeWriteOffset, offset < last { nvmeWriteNonMonotonicCount &+= 1 }
        lastNVMeWriteOffset = offset
        recentNVMeWrites.append(.init(ordinal: ordinal, offset: offset, length: length,
                                      overlapsPrior: overlaps, duplicatesPrior: duplicates))
        if recentNVMeWrites.count > Self.maximumRecordedWrites { recentNVMeWrites.removeFirst() }
    }

    /// Consumes a block of bytes from the verified transport stream channel (NSID 2 writes).
    public func consumeBytes(_ ptr: UnsafeRawPointer, count: Int, sourceOffset: UInt64 = 0, writeOrdinal: UInt64 = 0) {
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
                let needed = FluxFrameTransportHeader.headerSize - headerBuffer.count
                let available = count - offset
                let toCopy = (needed < available) ? needed : available
                headerBuffer.append(contentsOf: UnsafeBufferPointer(start: raw + offset, count: toCopy))
                offset += toCopy

                if headerBuffer.count == FluxFrameTransportHeader.headerSize {
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
                        currentAssemblyWriteOrdinals.removeAll(keepingCapacity: true)
                        currentAssemblyRanges.removeAll(keepingCapacity: true)
                        currentAssemblyOverlap = false
                        currentAssemblyDuplicate = false
                        currentAssemblyNonContiguous = false
                        state = .payload
                    } else {
                        rejectedHeaderCount &+= 1
                        state = .idle
                        headerBuffer.removeAll(keepingCapacity: true)
                    }
                }

            case .payload:
                // Check if a new frame header arrived early at this block boundary
                // (e.g. previous frame truncated, guest aborted, or fresh frame started)
                if (count - offset) >= FluxFrameTransportHeader.headerSize {
                    let peekMagic = UnsafeRawPointer(raw + offset).loadUnaligned(as: UInt64.self)
                    if peekMagic == FluxFrameTransportHeader.magicValue {
                        let candidateBytes = Array(UnsafeBufferPointer(start: raw + offset, count: FluxFrameTransportHeader.headerSize))
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
                if writeOrdinal != 0 && toCopy > 0 {
                    let segmentOffset = sourceOffset &+ UInt64(offset)
                    if let previous = currentAssemblyRanges.last,
                       previous.offset &+ UInt64(previous.length) != segmentOffset {
                        // FAT may place clusters non-contiguously.  Preserve
                        // this as evidence rather than rejecting a valid frame.
                        currentAssemblyNonContiguous = true
                    }
                    currentAssemblyWriteOrdinals.append(writeOrdinal)
                    currentAssemblyRanges.append((segmentOffset, toCopy))
                    if currentAssemblyWriteOrdinals.count > Self.maximumRecordedWrites { currentAssemblyWriteOrdinals.removeFirst() }
                    if currentAssemblyRanges.count > Self.maximumRecordedWrites { currentAssemblyRanges.removeFirst() }
                    if let write = recentNVMeWrites.last(where: { $0.ordinal == writeOrdinal }) {
                        currentAssemblyOverlap = currentAssemblyOverlap || write.overlapsPrior
                        currentAssemblyDuplicate = currentAssemblyDuplicate || write.duplicatesPrior
                    }
                }
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

        // v2 protects byte ordering, unlike the additive v1 checksum.  v1
        // remains accepted for compatibility but is explicitly identified in
        // reports; unknown versions were rejected before payload acceptance.
        let calculatedCRC32C = Self.crc32c(payloadBuffer)
        let crc32cMatches = hdr.version == FluxFrameTransportHeader.legacyVersion ||
            calculatedCRC32C == hdr.reserved

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
        let isValid = checksumMatches && pixelsMatch && crc32cMatches

        guard isValid else {
            lastFrameValid = false
            rejectedFrameCount &+= 1
            print("⚠️ [FRAME-TRANSPORT] Integrity check failed for v\(hdr.version) seq=\(hdr.sequence): checksumMatch=\(checksumMatches) crc32cMatch=\(crc32cMatches) (calc=0x\(String(calculatedCRC32C, radix: 16)), hdr=0x\(String(hdr.reserved, radix: 16))) pixelsMatch=\(pixelsMatch); discarding frame")
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
        lastCRC32C = calculatedCRC32C
        lastCRC32CMatches = crc32cMatches
        lastProtocolVersion = hdr.version
        lastAssemblyWriteCount = currentAssemblyWriteOrdinals.count
        lastAssemblyHadOverlap = currentAssemblyOverlap
        lastAssemblyHadDuplicate = currentAssemblyDuplicate
        lastAssemblyHadNonContiguousRange = currentAssemblyNonContiguous
        lastPixel0 = p0
        lastPixelCenter = pCenter
        lastPixelLast = pLast
        lastFrameValid = true
        latestFrameData = Data(payloadBuffer)

        FluxDisplayManager.shared.updateActiveResolution(width: Int(hdr.width), height: Int(hdr.height))

        print("📸 [FRAME-TRANSPORT] v\(hdr.version) Session #\(sessionCount) Frame #\(frameCount) received: seq=\(hdr.sequence), \(hdr.width)x\(hdr.height), rowPitch=\(hdr.stride), bytes=\(payloadBuffer.count), checksum=0x\(String(calculatedChecksum, radix: 16)), crc32c=0x\(String(calculatedCRC32C, radix: 16)), writes=\(currentAssemblyWriteOrdinals.count), overlap=\(currentAssemblyOverlap), duplicate=\(currentAssemblyDuplicate), noncontiguous=\(currentAssemblyNonContiguous) valid=true")

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
        let recentWrites = recentNVMeWrites.map { write in
            "#\(write.ordinal)@0x\(String(write.offset, radix: 16))+\(write.length) overlap=\(write.overlapsPrior ? 1 : 0) duplicate=\(write.duplicatesPrior ? 1 : 0)"
        }.joined(separator: ";")

        let frameLines: [String] = [
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
            "FRAME_TRANSPORT_PROTOCOL_VERSION=\(lastProtocolVersion)",
            "FRAME_TRANSPORT_REJECTED_HEADERS=\(rejectedHeaderCount)",
            "FRAME_TRANSPORT_REJECTED_FRAMES=\(rejectedFrameCount)",
            "FRAME_CHECKSUM=0x" + String(format: "%08X", lastChecksum),
            "FRAME_CRC32C=0x" + String(format: "%08X", lastCRC32C),
            "FRAME_CRC32C_MATCH=" + (lastCRC32CMatches ? "YES" : "NO"),
            "FRAME_ASSEMBLY_WRITE_COUNT=\(lastAssemblyWriteCount)",
            "FRAME_ASSEMBLY_OVERLAP=" + (lastAssemblyHadOverlap ? "YES" : "NO"),
            "FRAME_ASSEMBLY_DUPLICATE=" + (lastAssemblyHadDuplicate ? "YES" : "NO"),
            "FRAME_ASSEMBLY_NONCONTIGUOUS=" + (lastAssemblyHadNonContiguousRange ? "YES" : "NO"),
            "PIXEL_0=0x" + String(format: "%08X", lastPixel0),
            "PIXEL_CENTER=0x" + String(format: "%08X", lastPixelCenter),
            "PIXEL_LAST=0x" + String(format: "%08X", lastPixelLast)
        ]
        let nvmeLines: [String] = [
            "NVME_TRANSPORT_WRITE_COUNT=\(nvmeWriteCount)",
            "NVME_TRANSPORT_OVERLAP_COUNT=\(nvmeWriteOverlapCount)",
            "NVME_TRANSPORT_DUPLICATE_COUNT=\(nvmeWriteDuplicateCount)",
            "NVME_TRANSPORT_NONMONOTONIC_COUNT=\(nvmeWriteNonMonotonicCount)",
            "NVME_TRANSPORT_RECENT_WRITES=" + recentWrites,
            "SEQUENCE_HISTORY=" + sequenceHistory.map { String($0) }.joined(separator: ","),
            "RENDERED_FRAME_COUNT=\(renderedFrameCount)",
            "UNIQUE_FRAMES_PRESENTED=\(uniqueFramesPresentedCount)",
            "RENDERED_SOURCE=\(activeRenderSource)",
            "LAST_RENDERED_SEQUENCE=\(lastRenderedSequence)"
        ]
        let lines = frameLines + nvmeLines

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
        FRAME_TRANSPORT_PROTOCOL_VERSION=\(lastProtocolVersion)
        FRAME_TRANSPORT_REJECTED_HEADERS=\(rejectedHeaderCount)
        FRAME_TRANSPORT_REJECTED_FRAMES=\(rejectedFrameCount)
        FRAME_CHECKSUM=0x\(String(format: "%08X", lastChecksum))
        FRAME_CRC32C=0x\(String(format: "%08X", lastCRC32C))
        FRAME_CRC32C_MATCH=\(lastCRC32CMatches ? "YES" : "NO")
        FRAME_ASSEMBLY_WRITE_COUNT=\(lastAssemblyWriteCount)
        FRAME_ASSEMBLY_OVERLAP=\(lastAssemblyHadOverlap ? "YES" : "NO")
        FRAME_ASSEMBLY_DUPLICATE=\(lastAssemblyHadDuplicate ? "YES" : "NO")
        FRAME_ASSEMBLY_NONCONTIGUOUS=\(lastAssemblyHadNonContiguousRange ? "YES" : "NO")
        PIXEL_0=0x\(String(format: "%08X", lastPixel0))
        PIXEL_CENTER=0x\(String(format: "%08X", lastPixelCenter))
        PIXEL_LAST=0x\(String(format: "%08X", lastPixelLast))
        NVME_TRANSPORT_WRITE_COUNT=\(nvmeWriteCount)
        NVME_TRANSPORT_OVERLAP_COUNT=\(nvmeWriteOverlapCount)
        NVME_TRANSPORT_DUPLICATE_COUNT=\(nvmeWriteDuplicateCount)
        NVME_TRANSPORT_NONMONOTONIC_COUNT=\(nvmeWriteNonMonotonicCount)
        SEQUENCE_HISTORY=\(sequenceHistory.map { String($0) }.joined(separator: ","))
        RENDERED_FRAME_COUNT=\(renderedFrameCount)
        UNIQUE_FRAMES_PRESENTED=\(uniqueFramesPresentedCount)
        RENDERED_SOURCE=\(activeRenderSource)
        LAST_RENDERED_SEQUENCE=\(lastRenderedSequence)
        """
    }
}
