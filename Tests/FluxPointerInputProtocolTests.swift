import CoreGraphics
import Foundation

@main
struct FluxPointerInputProtocolTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }

    static func main() {
        let report = FluxPointerInputProtocol.makeReport(buttons: 0x03, x: 0x1234, y: 0x5678, verticalWheel: -2, horizontalPan: 3)
        require(report.count == FluxPointerInputProtocol.reportLength, "seven-byte pointer report")
        require(report == [0x03, 0x34, 0x12, 0x78, 0x56, 0xFE, 0x03], "report field encoding")
        require(FluxPointerInputProtocol.makeReport(buttons: 1, x: 1, y: 2, verticalWheel: 0, horizontalPan: 0)[0] == 1, "button press")
        require(FluxPointerInputProtocol.makeReport(buttons: 0, x: 1, y: 2, verticalWheel: 0, horizontalPan: 0)[0] == 0, "button release")
        require(FluxPointerInputProtocol.makeReport(buttons: FluxPointerInputProtocol.releasedButtons, x: 1, y: 2, verticalWheel: 0, horizontalPan: 0)[0] == 0, "focus-loss release report")
        require(FluxPointerInputProtocol.endpointCanCarryReport(requestLength: 7, maxPacketSize: 8), "seven-byte endpoint transfer")
        require(!FluxPointerInputProtocol.endpointCanCarryReport(requestLength: 6, maxPacketSize: 8), "reject truncated TRB")
        require(!FluxPointerInputProtocol.endpointCanCarryReport(requestLength: 7, maxPacketSize: 6), "reject undersized endpoint")
        let descriptor = FluxPointerInputProtocol.reportDescriptor
        require(descriptor.count == 78, "pointer HID report descriptor has 78 bytes")
        require(
            FluxPointerInputProtocol.reportDescriptorLength == UInt16(descriptor.count),
            "pointer HID advertised report length matches descriptor"
        )
        require(
            FluxPointerInputProtocol.reportDescriptorLengthLittleEndian == [0x4E, 0x00],
            "pointer HID advertised report length is little-endian 78"
        )
        let acPan = [UInt8]([0x05, 0x0C, 0x0A, 0x38, 0x02])
        require(descriptor.indices.dropLast(acPan.count - 1).contains { Array(descriptor[$0..<$0 + acPan.count]) == acPan }, "AC Pan descriptor")

        var scroll = FluxScrollAccumulator()
        require(scroll.consume(deltaX: 16, deltaY: -8, precise: true) == (vertical: -1, horizontal: 2), "independent precise axes")
        require(scroll.consume(deltaX: 1000, deltaY: 1000, precise: true) == (vertical: 5, horizontal: 5), "bounded momentum")
        scroll.reset()
        require(scroll.consume(deltaX: 1, deltaY: -1, precise: false) == (vertical: -1, horizontal: 1), "traditional wheel compatibility")

        let center = FluxPointerInputProtocol.mapPointToHID(viewPoint: CGPoint(x: 960, y: 540), viewSize: CGSize(width: 1920, height: 1080), fbWidth: 1920, fbHeight: 1080)
        require(center?.guestX == 960 && center?.guestY == 540, "coordinate mapping")
        let pillarbox = FluxPointerInputProtocol.mapPointToHID(viewPoint: CGPoint(x: 0, y: 500), viewSize: CGSize(width: 2000, height: 1000), fbWidth: 1920, fbHeight: 1080)
        require(pillarbox?.hidX == 0, "letterbox clamp")

        var buttons = FluxPointerButtonState()
        require(buttons.press(buttonNumber: 0) && buttons.mask == 0x01, "left down")
        require(!buttons.press(buttonNumber: 0) && buttons.mask == 0x01, "duplicate left down")
        require(buttons.mask == 0x01, "drag preserves held left button")
        require(buttons.press(buttonNumber: 1) && buttons.mask == 0x03, "simultaneous left right")
        require(buttons.release(buttonNumber: 0) && buttons.mask == 0x02, "left up while right held")
        require(buttons.release(buttonNumber: 1) && buttons.mask == 0x00, "right up")
        require(buttons.press(buttonNumber: 2) && buttons.mask == 0x04, "middle down")
        require(buttons.release(buttonNumber: 2) && buttons.mask == 0x00, "middle up")
        require(buttons.press(buttonNumber: 0) && buttons.mask == 0x01, "focus-loss setup")
        require(buttons.reset() && buttons.mask == 0x00, "focus-loss release")
        require(!buttons.press(buttonNumber: 3) && buttons.mask == 0x00, "unsupported other button")

        let shutdown = FluxSecondaryVCPUShutdownCoordinator()
        require(shutdown.registerLaunch(id: 1), "register first secondary vCPU")
        require(shutdown.registerLaunch(id: 2), "register partially started secondary vCPU")
        require(!shutdown.registerLaunch(id: 1), "reject duplicate secondary vCPU registration")
        shutdown.markExited(id: 1)
        require(!shutdown.waitForAllExits(timeout: 0.01), "partial-start cleanup remains pending")
        require(shutdown.outstandingIDs == [2], "report pending secondary vCPU")
        shutdown.markExited(id: 2)
        require(shutdown.waitForAllExits(timeout: 0.01), "wait for all secondary vCPU exits")
        shutdown.markExited(id: 2)
        require(shutdown.waitForAllExits(timeout: 0.01), "repeated shutdown completion is safe")

        let fallback = URL(fileURLWithPath: "/private/tmp/flux-input-diagnostics-fallback", isDirectory: true)
        let selected = FluxInputDiagnostics.runtimeDirectory(
            environment: ["FLUX_APP_SUPPORT_DIR": "/private/tmp/flux-input-diagnostics-override"],
            fileExists: { $0 == "/private/tmp/flux-input-diagnostics-override" },
            fallback: fallback
        )
        require(selected.path == "/private/tmp/flux-input-diagnostics-override", "diagnostic log uses active runtime override")
        let fallbackSelected = FluxInputDiagnostics.runtimeDirectory(
            environment: ["FLUX_APP_SUPPORT_DIR": "/missing"],
            fileExists: { _ in false },
            fallback: fallback
        )
        require(fallbackSelected == fallback, "diagnostic log falls back deterministically")

        let diagnosticDir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-input-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: diagnosticDir) }
        let diagnosticWriter = FluxInputDiagnostics.makeWriterForTesting(batchSize: 8)
        diagnosticWriter.enqueue(FluxInputDiagnosticRecord(directory: diagnosticDir, wallTimestamp: "wall-1", monotonicNanoseconds: 10, stage: "APPKIT", detail: "mouse metadata only"))
        diagnosticWriter.enqueue(FluxInputDiagnosticRecord(directory: diagnosticDir, wallTimestamp: "wall-2", monotonicNanoseconds: 20, stage: "HID_POINTER", detail: "right down"))
        diagnosticWriter.enqueue(FluxInputDiagnosticRecord(directory: diagnosticDir, wallTimestamp: "wall-3", monotonicNanoseconds: 30, stage: "XHCI_EP5", detail: "completion"))
        require(diagnosticWriter.flush(timeout: 1), "diagnostic writer bounded flush")
        let diagnosticText = try! String(contentsOf: FluxInputDiagnostics.logURL(in: diagnosticDir), encoding: .utf8)
        require(diagnosticText.contains("APPKIT monoNs=10"), "diagnostic monotonic AppKit timestamp")
        require(diagnosticText.contains("HID_POINTER monoNs=20"), "diagnostic monotonic HID timestamp")
        require(diagnosticText.contains("XHCI_EP5 monoNs=30"), "diagnostic monotonic EP5 timestamp")
        require(diagnosticText.range(of: "APPKIT")!.lowerBound < diagnosticText.range(of: "HID_POINTER")!.lowerBound, "diagnostic ordering AppKit before HID")
        require(diagnosticText.range(of: "HID_POINTER")!.lowerBound < diagnosticText.range(of: "XHCI_EP5")!.lowerBound, "diagnostic ordering HID before EP5")

        let rotationDir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-input-diagnostics-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rotationDir) }
        let rotationWriter = FluxInputDiagnostics.makeWriterForTesting(maximumPending: 512, batchSize: 64)
        for index in 0..<300 {
            rotationWriter.enqueue(FluxInputDiagnosticRecord(directory: rotationDir, wallTimestamp: "wall-\(index)", monotonicNanoseconds: UInt64(index), stage: "TEST", detail: String(repeating: "x", count: 1024)))
        }
        require(rotationWriter.flush(timeout: 2), "diagnostic rotation flush")
        let rotationURL = FluxInputDiagnostics.logURL(in: rotationDir)
        let rotationSize = (try! FileManager.default.attributesOfItem(atPath: rotationURL.path)[.size] as! NSNumber).intValue
        require(rotationSize <= FluxInputDiagnostics.maximumBytes, "diagnostic rotation remains bounded")
        require((try! String(contentsOf: rotationURL, encoding: .utf8)).contains("rotated"), "diagnostic rotation marker")

        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let blockLock = NSLock()
        var shouldBlockFirstBatch = true
        let overflowWriter = FluxInputDiagnosticWriter(maximumPending: 2, batchSize: 1, writeBatch: { _ in
            blockLock.lock()
            let shouldBlock = shouldBlockFirstBatch
            shouldBlockFirstBatch = false
            blockLock.unlock()
            if shouldBlock {
                started.signal()
                _ = gate.wait(timeout: .now() + 1)
            }
            return .success(())
        })
        let overflowRecord = FluxInputDiagnosticRecord(directory: diagnosticDir, wallTimestamp: "wall", monotonicNanoseconds: 1, stage: "TEST", detail: "overflow")
        overflowWriter.enqueue(overflowRecord)
        _ = started.wait(timeout: .now() + 1)
        overflowWriter.enqueue(overflowRecord)
        overflowWriter.enqueue(overflowRecord)
        overflowWriter.enqueue(overflowRecord)
        require(overflowWriter.snapshot().droppedCount >= 1, "diagnostic queue drops when bounded")
        gate.signal()
        require(overflowWriter.flush(timeout: 1), "overflow writer flush")

        var failureSeen = false
        let failureLock = NSLock()
        let failingWriter = FluxInputDiagnosticWriter(maximumPending: 2, batchSize: 1, writeBatch: { _ in .failure(.cannotOpenFile("test")) }, onFailure: { _ in
            failureLock.lock(); failureSeen = true; failureLock.unlock()
        })
        failingWriter.enqueue(overflowRecord)
        require(failingWriter.flush(timeout: 1), "failure writer flush")
        failureLock.lock()
        let sawFailure = failureSeen
        failureLock.unlock()
        require(sawFailure && failingWriter.snapshot().writeFailureCount == 1, "writer failure accounting")
        print("PASS FluxPointerInputProtocolTests")
    }
}
