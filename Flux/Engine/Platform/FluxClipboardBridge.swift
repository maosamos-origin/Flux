import Foundation
import AppKit

/// Real-time bidirectional clipboard bridge between macOS (`NSPasteboard`) and
/// the Windows guest (`FluxDevNode.exe`) over NVMe Namespace 2 (`D:\`).
///
/// - **Host -> Guest (`FLXCLIP1`)**: Guest opens `D:\flux_clipboard_in.bin` with
///   `FILE_FLAG_NO_BUFFERING` and reads 64 KB. `FluxNVMe` intercepts reads at the
///   pre-located channel offset and serves the latest macOS clipboard packet.
/// - **Guest -> Host (`FLXCLIP2`)**: Guest writes a `FLXCLIP2` packet to
///   `D:\flux_clipboard_out.bin`. `FluxNVMe` intercepts the write and updates
///   macOS `NSPasteboard.general`.
public final class FluxClipboardBridge: @unchecked Sendable {

    public static let shared = FluxClipboardBridge()

    public static let channelSize = 65536
    public static let maxPayloadBytes = 60000
    private static let headerSize = 20
    private static let inboundMarker = Array("FLXCLIP_IN_CHAN1".utf8)
    private static let hostMagic = Array("FLXCLIP1".utf8)
    private static let guestMagic = Array("FLXCLIP2".utf8)

    private let lock = NSLock()
    private var inboundRange: Range<UInt64>?
    private var hostSequence: UInt32 = 0
    private var hostPacket = Data(count: channelSize)
    private var lastHostChangeCount: Int = -1
    private var lastSuppressedHostText: String?
    private var lastGuestSequence: UInt32 = 0
    private var monitorTimer: Timer?

    private init() {}

    /// Starts polling macOS `NSPasteboard.general` for text changes.
    public func startMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.monitorTimer == nil else { return }
            self.refreshHostPasteboardIfNeeded()
            self.monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                self?.refreshHostPasteboardIfNeeded()
            }
        }
    }

    /// Scans NVMe Namespace 2 (`flux-driver-media.raw`) for `D:\flux_clipboard_in.bin`.
    public func locateInboundChannel(fd: Int32, fileSize: UInt64) {
        guard fd >= 0, fileSize >= UInt64(Self.channelSize) else { return }
        let chunkSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var offset: UInt64 = 0
        let marker = Self.inboundMarker

        while offset < fileSize {
            let toRead = Int(min(UInt64(chunkSize), fileSize - offset))
            let n = pread(fd, &buffer, toRead, off_t(offset))
            if n <= 0 { break }

            // Check 512-byte sector boundaries for the 16-byte channel marker.
            var pos = 0
            while pos + marker.count <= n {
                var matched = true
                for j in 0..<marker.count where buffer[pos + j] != marker[j] {
                    matched = false
                    break
                }
                if matched {
                    let channelStart = offset + UInt64(pos)
                    lock.lock()
                    inboundRange = channelStart..<(channelStart + UInt64(Self.channelSize))
                    lock.unlock()
                    print("📋 [CLIPBOARD] Located inbound channel at NS2 offset 0x\(String(channelStart, radix: 16))")
                    return
                }
                pos += 512
            }
            offset += UInt64(n)
        }
    }

    /// Services unbuffered guest reads from `D:\flux_clipboard_in.bin` directly from RAM.
    public func handleNS2Read(fileOffset: UInt64, iovs: [iovec], totalBytes: Int) -> Bool {
        guard totalBytes > 0 else { return false }
        lock.lock()
        guard let range = inboundRange,
              fileOffset >= range.lowerBound,
              fileOffset + UInt64(totalBytes) <= range.upperBound else {
            lock.unlock()
            return false
        }
        let relativeStart = Int(fileOffset - range.lowerBound)
        let packet = hostPacket
        lock.unlock()

        packet.withUnsafeBytes { raw in
            guard let srcBase = raw.baseAddress else { return }
            var copied = 0
            for iov in iovs where iov.iov_len > 0 {
                guard let dst = iov.iov_base else { continue }
                let len = min(iov.iov_len, max(0, totalBytes - copied))
                if len > 0 && relativeStart + copied + len <= packet.count {
                    memcpy(dst, srcBase.advanced(by: relativeStart + copied), len)
                    copied += len
                }
            }
        }
        return true
    }

    /// Inspects NSID 2 writes for `FLXCLIP2` packets sent from the Windows guest.
    public func consumeWrite(_ ptr: UnsafeRawPointer, count: Int) {
        guard count >= Self.headerSize else { return }
        let bytes = UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: count)

        for i in 0..<Self.guestMagic.count where bytes[i] != Self.guestMagic[i] {
            return
        }

        let raw = ptr
        let seq = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let len = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        let expectedCRC = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        guard len > 0, len <= Self.maxPayloadBytes, Self.headerSize + len <= count else { return }

        let payload = Array(bytes[Self.headerSize..<(Self.headerSize + len)])
        guard FluxFrameTransport.crc32c(payload) == expectedCRC,
              let text = String(bytes: payload, encoding: .utf8) else {
            return
        }

        lock.lock()
        guard seq != lastGuestSequence else {
            lock.unlock()
            return
        }
        lastGuestSequence = seq
        lastSuppressedHostText = text
        lock.unlock()

        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lock.lock()
            self.lastHostChangeCount = pb.changeCount
            self.lock.unlock()
            print("📋 [CLIPBOARD] Guest -> Mac synced (\(len) bytes, seq=\(seq))")
        }
    }

    private func refreshHostPasteboardIfNeeded() {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount
        lock.lock()
        let unchanged = (changeCount == lastHostChangeCount)
        lock.unlock()
        if unchanged { return }

        guard let text = pb.string(forType: .string) else {
            lock.lock()
            lastHostChangeCount = changeCount
            lock.unlock()
            return
        }

        lock.lock()
        if lastSuppressedHostText == text {
            lastHostChangeCount = changeCount
            lastSuppressedHostText = nil
            lock.unlock()
            return
        }
        lastHostChangeCount = changeCount

        var utf8 = Array(text.utf8)
        if utf8.count > Self.maxPayloadBytes {
            utf8 = Array(utf8.prefix(Self.maxPayloadBytes))
        }
        hostSequence &+= 1
        let seq = hostSequence
        let len = UInt32(utf8.count)
        let crc = FluxFrameTransport.crc32c(utf8)

        var packet = Data(count: Self.channelSize)
        packet.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            Self.hostMagic.withUnsafeBytes { m in
                if let mb = m.baseAddress { memcpy(base, mb, Self.hostMagic.count) }
            }
            base.storeBytes(of: seq.littleEndian, toByteOffset: 8, as: UInt32.self)
            base.storeBytes(of: len.littleEndian, toByteOffset: 12, as: UInt32.self)
            base.storeBytes(of: crc.littleEndian, toByteOffset: 16, as: UInt32.self)
            if !utf8.isEmpty {
                utf8.withUnsafeBytes { p in
                    if let pbPtr = p.baseAddress {
                        memcpy(base.advanced(by: Self.headerSize), pbPtr, utf8.count)
                    }
                }
            }
        }
        hostPacket = packet
        lock.unlock()
    }
}
