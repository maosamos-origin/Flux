import Foundation
import OSLog

/// Metadata-only input diagnostic record. The monotonic timestamp is captured
/// at the producing stage, not by the asynchronous writer.
nonisolated struct FluxInputDiagnosticRecord: Sendable {
    let directory: URL
    let wallTimestamp: String
    let monotonicNanoseconds: UInt64
    let stage: String
    let detail: String

    var line: String {
        "\(wallTimestamp) \(stage) monoNs=\(monotonicNanoseconds) \(detail)\n"
    }
}

/// Bounded serial disk writer. Producers only use a short in-memory lock;
/// opening, writing, and synchronizing files always occurs on `writerQueue`.
nonisolated final class FluxInputDiagnosticWriter: @unchecked Sendable {
    typealias BatchWriter = ([FluxInputDiagnosticRecord]) -> Result<Void, FluxInputDiagnostics.WriteFailure>
    typealias FailureHandler = (FluxInputDiagnostics.WriteFailure) -> Void

    struct Snapshot: Equatable {
        let pendingCount: Int
        let droppedCount: UInt64
        let writeFailureCount: UInt64
    }

    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "com.flux.Flux.input-diagnostics", qos: .utility)
    private let maximumPending: Int
    private let batchSize: Int
    private let writeBatch: BatchWriter
    private let onFailure: FailureHandler
    private var pending: [FluxInputDiagnosticRecord] = []
    private var isDraining = false
    private var droppedCount: UInt64 = 0
    private var unreportedDropCount: UInt64 = 0
    private var writeFailureCount: UInt64 = 0

    init(
        maximumPending: Int = 512,
        batchSize: Int = 64,
        writeBatch: @escaping BatchWriter,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        self.maximumPending = max(1, maximumPending)
        self.batchSize = max(1, batchSize)
        self.writeBatch = writeBatch
        self.onFailure = onFailure
    }

    /// Never waits for filesystem work. On overflow, the newest diagnostic
    /// record is dropped while guest-visible HID delivery continues unchanged.
    func enqueue(_ record: FluxInputDiagnosticRecord) {
        lock.lock()
        guard pending.count < maximumPending else {
            droppedCount &+= 1
            unreportedDropCount &+= 1
            lock.unlock()
            return
        }
        pending.append(record)
        if !isDraining {
            isDraining = true
            writerQueue.async { [weak self] in self?.drain() }
        }
        lock.unlock()
    }

    /// Flushes work submitted before the marker, bounded by the caller.
    func flush(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        writerQueue.async { done.signal() }
        return done.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(pendingCount: pending.count, droppedCount: droppedCount, writeFailureCount: writeFailureCount)
    }

    private func drain() {
        while true {
            var batch: [FluxInputDiagnosticRecord]
            lock.lock()
            guard !pending.isEmpty else {
                isDraining = false
                lock.unlock()
                return
            }
            let count = min(batchSize, pending.count)
            batch = Array(pending.prefix(count))
            pending.removeFirst(count)
            let droppedSinceLastBatch = unreportedDropCount
            unreportedDropCount = 0
            lock.unlock()

            if droppedSinceLastBatch > 0, let reference = batch.first {
                batch.append(FluxInputDiagnosticRecord(
                    directory: reference.directory,
                    wallTimestamp: ISO8601DateFormatter().string(from: Date()),
                    monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    stage: "DIAGNOSTIC_DROP",
                    detail: "droppedCount=\(droppedSinceLastBatch)"
                ))
            }

            if case let .failure(failure) = writeBatch(batch) {
                lock.lock()
                writeFailureCount &+= UInt64(batch.count)
                lock.unlock()
                onFailure(failure)
            }
        }
    }
}

/// Bounded, host-only pointer telemetry. It records metadata about mouse
/// events and HID reports only; callers must never pass keyboard text or guest
/// contents.
nonisolated enum FluxInputDiagnostics {
    static let maximumBytes = 256 * 1024
    static let maximumPendingRecords = 512
    private static let logger = Logger(subsystem: "com.flux.Flux", category: "InputDiagnostics")
    private static let failureLock = NSLock()
    private static var lastFailureUptime: TimeInterval = 0

    enum WriteFailure: Error, Equatable {
        case cannotCreateDirectory(String)
        case cannotCreateFile(String)
        case cannotOpenFile(String)
        case writeFailed(String)
    }

    private static let writer = FluxInputDiagnosticWriter(
        maximumPending: maximumPendingRecords,
        writeBatch: writeBatch,
        onFailure: reportFailure
    )

    static func logURL(in directory: URL) -> URL {
        directory.appendingPathComponent("input_diagnostic.log", isDirectory: false)
    }

    static func runtimeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        fallback: URL
    ) -> URL {
        if let override = environment["FLUX_APP_SUPPORT_DIR"], fileExists(override) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fallback
    }

    /// Production entry point for AppKit, HID, and xHCI. It performs no disk
    /// I/O and preserves both wall-clock and monotonic producer timestamps.
    static func enqueue(
        stage: String,
        detail: String,
        directory: URL,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        wallTimestamp: String = ISO8601DateFormatter().string(from: Date())
    ) {
        writer.enqueue(FluxInputDiagnosticRecord(
            directory: directory,
            wallTimestamp: wallTimestamp,
            monotonicNanoseconds: monotonicNanoseconds,
            stage: stage,
            detail: detail
        ))
    }

    /// Bounded teardown flush. A timeout leaves diagnostics behind rather than
    /// blocking VM destruction indefinitely.
    @discardableResult
    static func flush(timeout: TimeInterval = 0.25) -> Bool {
        writer.flush(timeout: timeout)
    }

    static func snapshot() -> FluxInputDiagnosticWriter.Snapshot {
        writer.snapshot()
    }

    /// Isolated host-test factory. Production callers must use `enqueue`.
    static func makeWriterForTesting(
        maximumPending: Int = maximumPendingRecords,
        batchSize: Int = 64
    ) -> FluxInputDiagnosticWriter {
        FluxInputDiagnosticWriter(
            maximumPending: maximumPending,
            batchSize: batchSize,
            writeBatch: writeBatch,
            onFailure: reportFailure
        )
    }

    private static func writeBatch(_ records: [FluxInputDiagnosticRecord]) -> Result<Void, WriteFailure> {
        guard !records.isEmpty else { return .success(()) }
        var offset = 0
        while offset < records.count {
            let directory = records[offset].directory
            var end = offset + 1
            while end < records.count, records[end].directory == directory { end += 1 }
            switch write(records: Array(records[offset..<end]), to: directory) {
            case .success: break
            case let .failure(failure): return .failure(failure)
            }
            offset = end
        }
        return .success(())
    }

    private static func write(records: [FluxInputDiagnosticRecord], to directory: URL) -> Result<Void, WriteFailure> {
        let fileManager = FileManager.default
        let path = logURL(in: directory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.cannotCreateDirectory(directory.path))
        }
        if !fileManager.fileExists(atPath: path.path), !fileManager.createFile(atPath: path.path, contents: nil) {
            return .failure(.cannotCreateFile(path.path))
        }

        let header = Data("=== Flux input diagnostics rotated ===\n".utf8)
        var payloadRecords = records
        var payload = Data(payloadRecords.map(\.line).joined().utf8)
        do {
            let existingSize = (try? fileManager.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            if existingSize + payload.count > maximumBytes {
                // Keep complete newest records only; even an unexpectedly long
                // metadata line cannot make the rotated file exceed its cap.
                let payloadBudget = max(0, maximumBytes - header.count)
                var kept: [FluxInputDiagnosticRecord] = []
                var keptBytes = 0
                for record in records.reversed() {
                    let bytes = record.line.lengthOfBytes(using: .utf8)
                    guard bytes <= payloadBudget - keptBytes else { continue }
                    kept.append(record)
                    keptBytes += bytes
                }
                payloadRecords = Array(kept.reversed())
                payload = Data(payloadRecords.map(\.line).joined().utf8)
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: header)
            } else {
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: payload)
            try handle.synchronize()
            return .success(())
        } catch {
            return .failure(.cannotOpenFile(path.path))
        }
    }

    private static func reportFailure(_ failure: WriteFailure) {
        let now = ProcessInfo.processInfo.systemUptime
        failureLock.lock()
        let shouldReport = now - lastFailureUptime >= 60
        if shouldReport { lastFailureUptime = now }
        failureLock.unlock()
        if shouldReport {
            logger.error("Input diagnostic write failed: \(String(describing: failure), privacy: .public)")
        }
    }
}
