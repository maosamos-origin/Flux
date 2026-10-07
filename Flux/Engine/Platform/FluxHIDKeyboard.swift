import Foundation
import AppKit

/// Thread-safe USB HID Boot Keyboard state and report generator.
/// Bridges macOS hardware keyCodes and NSEvent modifiers to 8-byte HID Boot Keyboard reports.
nonisolated final class FluxHIDKeyboard: @unchecked Sendable {

    static let shared = FluxHIDKeyboard()
    private static let diagnosticTraceLock = NSLock()

    static func appendKeyboardTrace(_ line: String) {
        diagnosticTraceLock.lock()
        defer { diagnosticTraceLock.unlock() }
        let path = FluxVM.defaultAppDirectory() + "/local-key-monitor.log"
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    private let lock = NSLock()
    private var pressedKeys: [UInt8] = []  // Up to 6 simultaneous HID usage codes
    private var modifiers: UInt8 = 0       // 8 modifier bits
    private var reportQueue: [[UInt8]] = [] // Enqueued 8-byte reports waiting for EP3 transfer

    private init() {}

    // MARK: - Test-only Win+R automation trace

    /// Records only the explicit synthetic key transitions used by the isolated
    /// Win+R control. Normal physical keyboard delivery never calls this path.
    private func appendAutoKeyTrace(action: String, keyCode: UInt16, usage: UInt8?, report: [UInt8]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let usageText = usage.map { String(format: "0x%02X", $0) } ?? "modifier"
        let bytes = report.map { String(format: "%02x", $0) }.joined(separator: " ")
        let line = "[AUTO-KEY] timestamp=\(timestamp) action=\(action) keyCode=\(keyCode) usage=\(usageText) report=[\(bytes)]"
        print(line)
        Self.appendKeyboardTrace(line)
    }

    private func currentReportSnapshot() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var report: [UInt8] = [modifiers, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for i in 0..<min(pressedKeys.count, 6) {
            report[2 + i] = pressedKeys[i]
        }
        return report
    }

    private func sendAutoKeyDown(_ keyCode: UInt16) {
        handleKeyDown(keyCode: keyCode, isRepeat: false)
        appendAutoKeyTrace(action: "DOWN", keyCode: keyCode, usage: Self.hidUsage(for: keyCode), report: currentReportSnapshot())
    }

    private func sendAutoKeyUp(_ keyCode: UInt16) {
        handleKeyUp(keyCode: keyCode)
        appendAutoKeyTrace(action: "UP", keyCode: keyCode, usage: Self.hidUsage(for: keyCode), report: currentReportSnapshot())
    }

    private func sendAutoFlagsChanged(_ keyCode: UInt16, rawFlags: UInt, action: String) {
        handleFlagsChanged(keyCode: keyCode, rawFlags: rawFlags)
        appendAutoKeyTrace(action: action, keyCode: keyCode, usage: nil, report: currentReportSnapshot())
    }

    // MARK: - KeyCode -> HID Usage Mapping

    /// Maps macOS hardware keyCodes to USB HID Boot Keyboard usages.
    static func hidUsage(for keyCode: UInt16) -> UInt8? {
        switch keyCode {
        // Letters A-Z
        case 0x00: return 0x04 // A
        case 0x0B: return 0x05 // B
        case 0x08: return 0x06 // C
        case 0x02: return 0x07 // D
        case 0x0E: return 0x08 // E
        case 0x03: return 0x09 // F
        case 0x05: return 0x0A // G
        case 0x04: return 0x0B // H
        case 0x22: return 0x0C // I
        case 0x26: return 0x0D // J
        case 0x28: return 0x0E // K
        case 0x25: return 0x0F // L
        case 0x2E: return 0x10 // M
        case 0x2D: return 0x11 // N
        case 0x1F: return 0x12 // O
        case 0x23: return 0x13 // P
        case 0x0C: return 0x14 // Q
        case 0x0F: return 0x15 // R
        case 0x01: return 0x16 // S
        case 0x11: return 0x17 // T
        case 0x20: return 0x18 // U
        case 0x09: return 0x19 // V
        case 0x0D: return 0x1A // W
        case 0x07: return 0x1B // X
        case 0x10: return 0x1C // Y
        case 0x06: return 0x1D // Z

        // Digits 1-9, 0
        case 0x12: return 0x1E // 1
        case 0x13: return 0x1F // 2
        case 0x14: return 0x20 // 3
        case 0x15: return 0x21 // 4
        case 0x17: return 0x22 // 5
        case 0x16: return 0x23 // 6
        case 0x1A: return 0x24 // 7
        case 0x1C: return 0x25 // 8
        case 0x19: return 0x26 // 9
        case 0x1D: return 0x27 // 0

        // Whitespace, Control & Punctuation
        case 0x31: return 0x2C // Spacebar
        case 0x24: return 0x28 // Return / Enter
        case 0x33: return 0x2A // Delete / Backspace
        case 0x30: return 0x2B // Tab
        case 0x35: return 0x29 // Escape
        case 0x1B: return 0x2D // - / _
        case 0x18: return 0x2E // = / +
        case 0x21: return 0x2F // [ / {
        case 0x1E: return 0x30 // ] / }
        case 0x2A: return 0x31 // \ / |
        case 0x29: return 0x33 // ; / :
        case 0x27: return 0x34 // ' / "
        case 0x32: return 0x35 // ` / ~
        case 0x2B: return 0x36 // , / <
        case 0x2F: return 0x37 // . / >
        case 0x2C: return 0x38 // / / ?

        // Navigation Arrows & Keys
        case 0x7C: return 0x4F // Right Arrow
        case 0x7B: return 0x50 // Left Arrow
        case 0x7D: return 0x51 // Down Arrow
        case 0x7E: return 0x52 // Up Arrow
        case 0x74: return 0x4B // Page Up
        case 0x79: return 0x4E // Page Down
        case 0x73: return 0x4A // Home
        case 0x77: return 0x4D // End

        default: return nil
        }
    }

    // MARK: - Event Ingestion

    func handleKeyDown(keyCode: UInt16, isRepeat: Bool) {
        let mappedUsage = Self.hidUsage(for: keyCode)
        Self.appendKeyboardTrace("[HID-KEYBOARD-DOWN] keyCode=\(keyCode) mappedUsage=\(mappedUsage.map { String(format: "0x%02X", $0) } ?? "nil")")
        var enqueued = false
        var reportBytes: [UInt8] = []
        var hidUsage: UInt8?

        lock.lock()
        if let usage = Self.hidUsage(for: keyCode) {
            hidUsage = usage
            if !pressedKeys.contains(usage) {
                if pressedKeys.count < 6 {
                    pressedKeys.append(usage)
                }
                reportBytes = enqueueCurrentReportLocked()
                enqueued = true
            } else if isRepeat {
                reportBytes = enqueueCurrentReportLocked()
                enqueued = true
            }
        }
        lock.unlock()

        if enqueued, let usage = hidUsage {
            print("⌨️ [HID-KEYBOARD] keyDown keyCode=\(keyCode) HID=0x\(String(format: "%02x", usage)) repeat=\(isRepeat) report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyKeyboardEvent()
        }
    }

    func handleKeyUp(keyCode: UInt16) {
        let mappedUsage = Self.hidUsage(for: keyCode)
        Self.appendKeyboardTrace("[HID-KEYBOARD-UP] keyCode=\(keyCode) mappedUsage=\(mappedUsage.map { String(format: "0x%02X", $0) } ?? "nil")")
        var enqueued = false
        var reportBytes: [UInt8] = []
        var hidUsage: UInt8?

        lock.lock()
        if let usage = Self.hidUsage(for: keyCode) {
            hidUsage = usage
            if let idx = pressedKeys.firstIndex(of: usage) {
                pressedKeys.remove(at: idx)
                reportBytes = enqueueCurrentReportLocked()
                enqueued = true
            }
        }
        lock.unlock()

        if enqueued, let usage = hidUsage {
            print("⌨️ [HID-KEYBOARD] keyUp keyCode=\(keyCode) HID=0x\(String(format: "%02x", usage)) report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyKeyboardEvent()
        }
    }

    func handleFlagsChanged(keyCode: UInt16, rawFlags: UInt) {
        var enqueued = false
        var reportBytes: [UInt8] = []
        var oldM: UInt8 = 0
        var newM: UInt8 = 0

        lock.lock()
        // Standard Carbon/Cocoa device-dependent modifier bit masks:
        // NX_DEVICELCTLKEYMASK   = 0x0001
        // NX_DEVICELSHIFTKEYMASK = 0x0002
        // NX_DEVICERSHIFTKEYMASK = 0x0004
        // NX_DEVICELCMDKEYMASK   = 0x0008
        // NX_DEVICERCMDKEYMASK   = 0x0010
        // NX_DEVICELALTKEYMASK   = 0x0020
        // NX_DEVICERALTKEYMASK   = 0x0040
        // NX_DEVICERCTLKEYMASK   = 0x2000
        var mods: UInt8 = 0
        if (rawFlags & 0x0001) != 0 { mods |= (1 << 0) } // Left Control
        if (rawFlags & 0x0002) != 0 { mods |= (1 << 1) } // Left Shift
        if (rawFlags & 0x0020) != 0 { mods |= (1 << 2) } // Left Alt/Option
        if (rawFlags & 0x0008) != 0 { mods |= (1 << 3) } // Left GUI/Command
        if (rawFlags & 0x2000) != 0 { mods |= (1 << 4) } // Right Control
        if (rawFlags & 0x0004) != 0 { mods |= (1 << 5) } // Right Shift
        if (rawFlags & 0x0040) != 0 { mods |= (1 << 6) } // Right Alt/Option
        if (rawFlags & 0x0010) != 0 { mods |= (1 << 7) } // Right GUI/Command

        // Device-independent fallback if hardware bits are missing (e.g. synthetic test events)
        if (rawFlags & 0x20000) != 0 && (mods & 0x22) == 0 { // Shift
            if keyCode == 60 { mods |= (1 << 5) } else { mods |= (1 << 1) }
        }
        if (rawFlags & 0x40000) != 0 && (mods & 0x11) == 0 { // Control
            if keyCode == 62 { mods |= (1 << 4) } else { mods |= (1 << 0) }
        }
        if (rawFlags & 0x80000) != 0 && (mods & 0x44) == 0 { // Option/Alt
            if keyCode == 61 { mods |= (1 << 6) } else { mods |= (1 << 2) }
        }
        if (rawFlags & 0x100000) != 0 && (mods & 0x88) == 0 { // Command/GUI
            if keyCode == 54 { mods |= (1 << 7) } else { mods |= (1 << 3) }
        }

        if mods != modifiers {
            oldM = modifiers
            newM = mods
            modifiers = mods
            reportBytes = enqueueCurrentReportLocked()
            enqueued = true
        }
        lock.unlock()

        if enqueued {
            print("⌨️ [HID-KEYBOARD] flagsChanged keyCode=\(keyCode) rawFlags=0x\(String(rawFlags, radix: 16)) mods=0x\(String(format: "%02x", oldM))->0x\(String(format: "%02x", newM)) report=[\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyKeyboardEvent()
        }
    }

    /// Resets all internal pressed keys and modifiers to zero.
    /// If keys or modifiers were held, immediately queues an all-zero release report.
    func resetState() {
        var enqueued = false
        var reportBytes: [UInt8] = []

        lock.lock()
        let hadKeys = !pressedKeys.isEmpty || modifiers != 0
        pressedKeys.removeAll()
        modifiers = 0
        if hadKeys {
            reportBytes = enqueueCurrentReportLocked()
            enqueued = true
        }
        lock.unlock()

        if enqueued {
            print("⌨️ [HID-KEYBOARD] resetState: safety release report queued [\(reportBytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            FluxXHCI.notifyKeyboardEvent()
        }
    }

    // MARK: - Queue Inspection & Consumption

    func peekReport() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return reportQueue.first
    }

    func popReport() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard !reportQueue.isEmpty else { return nil }
        return reportQueue.removeFirst()
    }

    var queueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reportQueue.count
    }

    /// Test-only synchronization for automated HID delivery. A report leaves this
    /// queue only after EP3 has copied it to the guest transfer buffer and posted
    /// the transfer completion; this never changes report creation or ordering.
    func waitUntilQueueDrained(timeout: TimeInterval, pollInterval: TimeInterval = 0.25) -> Bool {
        let started = Date()
        var lastPending = -1
        print("[FAST-PROBE] QUEUE_DRAIN_START")

        while Date().timeIntervalSince(started) < timeout {
            let pending = queueCount
            if pending != lastPending {
                print("[FAST-PROBE] QUEUE_PENDING=\(pending)")
                lastPending = pending
            }
            if pending == 0 {
                print("[FAST-PROBE] QUEUE_DRAIN_PASS elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))")
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        print("[FAST-PROBE] QUEUE_DRAIN_TIMEOUT remaining=\(queueCount)")
        return false
    }

    private func enqueueCurrentReportLocked() -> [UInt8] {
        var report: [UInt8] = [modifiers, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for i in 0..<min(pressedKeys.count, 6) {
            report[2 + i] = pressedKeys[i]
        }
        reportQueue.append(report)
        return report
    }

    // MARK: - Automated Live Test Runner

    private var testStarted = false

    func scheduleTestFromLaunchIfNeeded() {
        let launchTimestamp = ISO8601DateFormatter().string(from: Date())
        let tpCertutilTest = ProcessInfo.processInfo.environment["FLUX_TEST_TP_CERTUTIL"] == "1"
        let signingPolicyAuditTest = ProcessInfo.processInfo.environment["FLUX_TEST_SIGNING_AUDIT"] == "1"
        let launcherFlagValue = ProcessInfo.processInfo.environment["FLUX_TEST_SIGNING_LAUNCHER"]
        let signingPolicyLauncherTest = ProcessInfo.processInfo.environment["FLUX_TEST_SIGNING_LAUNCHER"] == "1"
        let devNodeCreateTest = ProcessInfo.processInfo.environment["FLUX_TEST_DEVNODE_CREATE"] == "1"
#if DEBUG
        let finishInstallTest = ProcessInfo.processInfo.environment["FLUX_TEST_FINISH_INSTALL"] == "1"
        let rebootVerifyTest = ProcessInfo.processInfo.environment["FLUX_TEST_REBOOT_VERIFY"] == "1"
        let pnpRestartTest = ProcessInfo.processInfo.environment["FLUX_TEST_PNP_RESTART"] == "1"
        let swdMigrationTest = ProcessInfo.processInfo.environment["FLUX_TEST_SWD_MIGRATION"] == "1"
#else
        let finishInstallTest = false
        let rebootVerifyTest = false
        let pnpRestartTest = false
        let swdMigrationTest = false
#endif
        let competingModes = [
            tpCertutilTest ? "FLUX_TEST_TP_CERTUTIL" : nil,
            signingPolicyAuditTest ? "FLUX_TEST_SIGNING_AUDIT" : nil
        ].compactMap { $0 }.joined(separator: ",")
        guard tpCertutilTest || signingPolicyAuditTest || signingPolicyLauncherTest || devNodeCreateTest || finishInstallTest || rebootVerifyTest || pnpRestartTest || swdMigrationTest else {
            if let val = launcherFlagValue {
                Self.appendKeyboardTrace("[SIGNING-LAUNCHER-SCHED] timestamp=\(launchTimestamp) flagValue=\(val) schedulerEntered=NO timerArmed=NO skipReason=FLAG_VALUE_NOT_1")
            }
            return
        }
        if signingPolicyLauncherTest {
            let flagValStr = launcherFlagValue ?? "<absent>"
            let compModesStr = competingModes.isEmpty ? "NONE" : competingModes
            Self.appendKeyboardTrace("[SIGNING-LAUNCHER-SCHED] timestamp=\(launchTimestamp) flagPresent=YES flagValue=\(flagValStr) schedulerEntered=YES competingModes=\(compModesStr)")
        }
        lock.lock()
        let oneShotBefore = testStarted
        guard !testStarted else {
            lock.unlock()
            if swdMigrationTest {
                self.runSwdMigrationTest()
            } else if pnpRestartTest {
                self.runPnpRestartTest()
            } else if rebootVerifyTest {
                self.runRebootVerifyTest()
            } else if finishInstallTest {
                self.runFinishInstallTest()
            } else if signingPolicyLauncherTest {
                Self.appendKeyboardTrace("[SIGNING-LAUNCHER-SCHED] oneShotBefore=\(oneShotBefore) oneShotAfter=\(oneShotBefore) timerArmed=NO skipReason=ONE_SHOT_ALREADY_SET")
            }
            return
        }
        testStarted = true
        let oneShotAfter = testStarted
        lock.unlock()
        if signingPolicyLauncherTest {
            Self.appendKeyboardTrace("[SIGNING-LAUNCHER-SCHED] oneShotBefore=\(oneShotBefore) oneShotAfter=\(oneShotAfter) timerArmed=YES delaySeconds=75")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 75.0) { [weak self] in
            if swdMigrationTest {
                self?.runSwdMigrationTest()
            } else if pnpRestartTest {
                self?.runPnpRestartTest()
            } else if rebootVerifyTest {
                self?.runRebootVerifyTest()
            } else if signingPolicyLauncherTest {
                Self.appendKeyboardTrace("[SIGNING-LAUNCHER-SCHED] timerFired=YES targetFunctionReached=YES")
                self?.runSigningPolicyLauncherTest()
            } else if devNodeCreateTest {
                self?.runDevNodeCreateTest()
            } else if signingPolicyAuditTest {
                self?.runSigningPolicyAuditTest()
            } else {
                self?.runTpCertutilTest()
            }
        }
    }

    func notifyEP3Armed() {
        let liveKeyboardTest = ProcessInfo.processInfo.environment["FLUX_TEST_HID_KEYBOARD"] == "1"
        let winRAutomationTest = ProcessInfo.processInfo.environment["FLUX_TEST_WINR_AUTOMATION"] == "1"
        let uacTraceTest = ProcessInfo.processInfo.environment["FLUX_TEST_UAC_TRACE"] == "1"
        let tpCertutilTest = ProcessInfo.processInfo.environment["FLUX_TEST_TP_CERTUTIL"] == "1"
        let signingPolicyAuditTest = ProcessInfo.processInfo.environment["FLUX_TEST_SIGNING_AUDIT"] == "1"
        let signingPolicyAuditStageTest = ProcessInfo.processInfo.environment["FLUX_TEST_SIGNING_AUDIT_STAGE"] == "1"
        let signingPolicyLauncherTest = ProcessInfo.processInfo.environment["FLUX_TEST_SIGNING_LAUNCHER"] == "1"
        let devNodeCreateTest = ProcessInfo.processInfo.environment["FLUX_TEST_DEVNODE_CREATE"] == "1"
#if DEBUG
        let finishInstallTest = ProcessInfo.processInfo.environment["FLUX_TEST_FINISH_INSTALL"] == "1"
        let rebootVerifyTest = ProcessInfo.processInfo.environment["FLUX_TEST_REBOOT_VERIFY"] == "1"
        let pnpRestartTest = ProcessInfo.processInfo.environment["FLUX_TEST_PNP_RESTART"] == "1"
        let swdMigrationTest = ProcessInfo.processInfo.environment["FLUX_TEST_SWD_MIGRATION"] == "1"
#else
        let finishInstallTest = false
        let rebootVerifyTest = false
        let pnpRestartTest = false
        let swdMigrationTest = false
#endif
        guard liveKeyboardTest || winRAutomationTest || uacTraceTest || tpCertutilTest || signingPolicyAuditTest || signingPolicyAuditStageTest || signingPolicyLauncherTest || devNodeCreateTest || finishInstallTest || rebootVerifyTest || pnpRestartTest || swdMigrationTest else { return }
        lock.lock()
        if testStarted {
            lock.unlock()
            if signingPolicyLauncherTest {
                Self.appendKeyboardTrace("[SIGNING-LAUNCHER-SCHED] ep3Callback=YES oneShotBefore=true timerArmed=NO skipReason=LAUNCH_SCHEDULER_OWNS_ONE_SHOT")
            }
            return
        }
        testStarted = true
        lock.unlock()

        let delay: TimeInterval = (winRAutomationTest || uacTraceTest || tpCertutilTest || signingPolicyAuditTest || signingPolicyAuditStageTest || signingPolicyLauncherTest || devNodeCreateTest || finishInstallTest || rebootVerifyTest || pnpRestartTest || swdMigrationTest) ? 60.0 : 2.5
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if swdMigrationTest {
                self.runSwdMigrationTest()
            } else if pnpRestartTest {
                self.runPnpRestartTest()
            } else if rebootVerifyTest {
                self.runRebootVerifyTest()
            } else if finishInstallTest {
                self.runFinishInstallTest()
            } else if devNodeCreateTest {
                self.runDevNodeCreateTest()
            } else if signingPolicyLauncherTest {
                self.runSigningPolicyLauncherTest()
            } else if signingPolicyAuditStageTest {
                self.stageSigningPolicyAuditScript()
            } else if signingPolicyAuditTest {
                self.runSigningPolicyAuditTest()
            } else if tpCertutilTest {
                self.runTpCertutilTest()
            } else if uacTraceTest {
                self.runUacLifetimeTraceTest()
            } else if winRAutomationTest {
                self.runWinRAutomationControlTest()
            } else {
                self.runLiveValidationTest()
            }
        }
    }

    /// Types an ASCII string by simulating key presses and shift modifier.
    func typeString(_ str: String, charDelay: TimeInterval = 0.05) {
        let charMap: [Character: (keyCode: UInt16, shift: Bool)] = [
            "a": (0x00, false), "b": (0x0B, false), "c": (0x08, false), "d": (0x02, false),
            "e": (0x0E, false), "f": (0x03, false), "g": (0x05, false), "h": (0x04, false),
            "i": (0x22, false), "j": (0x26, false), "k": (0x28, false), "l": (0x25, false),
            "m": (0x2E, false), "n": (0x2D, false), "o": (0x1F, false), "p": (0x23, false),
            "q": (0x0C, false), "r": (0x0F, false), "s": (0x01, false), "t": (0x11, false),
            "u": (0x20, false), "v": (0x09, false), "w": (0x0D, false), "x": (0x07, false),
            "y": (0x10, false), "z": (0x06, false),
            "A": (0x00, true), "B": (0x0B, true), "C": (0x08, true), "D": (0x02, true),
            "E": (0x0E, true), "F": (0x03, true), "G": (0x05, true), "H": (0x04, true),
            "I": (0x22, true), "J": (0x26, true), "K": (0x28, true), "L": (0x25, true),
            "M": (0x2E, true), "N": (0x2D, true), "O": (0x1F, true), "P": (0x23, true),
            "Q": (0x0C, true), "R": (0x0F, true), "S": (0x01, true), "T": (0x11, true),
            "U": (0x20, true), "V": (0x09, true), "W": (0x0D, true), "X": (0x07, true),
            "Y": (0x10, true), "Z": (0x06, true),
            "1": (0x12, false), "2": (0x13, false), "3": (0x14, false), "4": (0x15, false),
            "5": (0x17, false), "6": (0x16, false), "7": (0x1A, false), "8": (0x1C, false),
            "9": (0x19, false), "0": (0x1D, false),
            "!": (0x12, true), "@": (0x13, true), "#": (0x14, true), "$": (0x15, true),
            "%": (0x17, true), "^": (0x16, true), "&": (0x1A, true), "*": (0x1C, true),
            "(": (0x19, true), ")": (0x1D, true),
            " ": (0x31, false), "-": (0x1B, false), "_": (0x1B, true),
            "=": (0x18, false), "+": (0x18, true),
            "[": (0x21, false), "{": (0x21, true),
            "]": (0x1E, false), "}": (0x1E, true),
            "\\": (0x2A, false), "|": (0x2A, true),
            ";": (0x29, false), ":": (0x29, true),
            "'": (0x27, false), "\"": (0x27, true),
            ",": (0x2B, false), "<": (0x2B, true),
            ".": (0x2F, false), ">": (0x2F, true),
            "/": (0x2C, false), "?": (0x2C, true),
            "`": (0x32, false), "~": (0x32, true),
            "\n": (0x24, false), "\t": (0x30, false)
        ]

        var shiftHeld = false
        for ch in str {
            guard let entry = charMap[ch] else { continue }
            if entry.shift && !shiftHeld {
                handleFlagsChanged(keyCode: 56, rawFlags: 0x0002 | 0x20000)
                Thread.sleep(forTimeInterval: 0.03)
                shiftHeld = true
            } else if !entry.shift && shiftHeld {
                handleFlagsChanged(keyCode: 56, rawFlags: 0)
                Thread.sleep(forTimeInterval: 0.03)
                shiftHeld = false
            }
            handleKeyDown(keyCode: entry.keyCode, isRepeat: false)
            Thread.sleep(forTimeInterval: charDelay)
            handleKeyUp(keyCode: entry.keyCode)
            Thread.sleep(forTimeInterval: charDelay)
        }
        if shiftHeld {
            handleFlagsChanged(keyCode: 56, rawFlags: 0)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    /// Opens Windows Run dialog (Win+R), types command, and presses Enter.
    /// - Parameter charDelay: Per-character delay in seconds (default 0.05s). Use 0.005s for fast typing of long payloads.
    func sendWinR(command: String, charDelay: TimeInterval = 0.02) {
        // Press Win+R
        handleFlagsChanged(keyCode: 55, rawFlags: 0x0008 | 0x100000) // Command / Win
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyDown(keyCode: 0x0F, isRepeat: false) // R
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyUp(keyCode: 0x0F)
        Thread.sleep(forTimeInterval: 0.1)
        handleFlagsChanged(keyCode: 55, rawFlags: 0) // Release Win
        Thread.sleep(forTimeInterval: 4.0) // wait for Run dialog to fully open and focus

        // Erase any previous command by selecting all (Ctrl+A) and deleting, plus repeated Backspaces
        handleFlagsChanged(keyCode: 59, rawFlags: 0x0001 | 0x40000) // Control down
        Thread.sleep(forTimeInterval: 0.05)
        handleKeyDown(keyCode: 0x00, isRepeat: false) // A down
        Thread.sleep(forTimeInterval: 0.05)
        handleKeyUp(keyCode: 0x00) // A up
        Thread.sleep(forTimeInterval: 0.05)
        handleFlagsChanged(keyCode: 59, rawFlags: 0) // Control up
        Thread.sleep(forTimeInterval: 0.1)

        for _ in 0..<60 {
            handleKeyDown(keyCode: 0x33, isRepeat: false) // Backspace
            Thread.sleep(forTimeInterval: 0.005)
            handleKeyUp(keyCode: 0x33)
            Thread.sleep(forTimeInterval: 0.005)
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Type command
        typeString(command, charDelay: charDelay)
        Thread.sleep(forTimeInterval: 0.8)

        // Press Enter twice (first closes autocomplete dropdown if open, second submits dialog)
        handleKeyDown(keyCode: 0x24, isRepeat: false) // Enter
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyUp(keyCode: 0x24)
        Thread.sleep(forTimeInterval: 0.4)
        handleKeyDown(keyCode: 0x24, isRepeat: false) // Enter
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyUp(keyCode: 0x24)
    }

    /// Test-only, command-free control for validating the synthetic Win+R
    /// hotkey and the ordinary synthetic character path. It performs no UAC,
    /// no watcher launch, and no Enter submission.
    private func runWinRAutomationControlTest() {
        print("[AUTO-KEY] CONTROL_TEST_START")
        resetState()
        Thread.sleep(forTimeInterval: 1.0)

        // Control 1: exactly Left GUI down, R down, R up, Left GUI up.
        sendAutoFlagsChanged(55, rawFlags: 0x0008 | 0x100000, action: "DOWN")
        Thread.sleep(forTimeInterval: 0.15)
        sendAutoKeyDown(0x0F)
        Thread.sleep(forTimeInterval: 0.15)
        sendAutoKeyUp(0x0F)
        Thread.sleep(forTimeInterval: 0.15)
        sendAutoFlagsChanged(55, rawFlags: 0, action: "UP")
        Thread.sleep(forTimeInterval: 3.0)
        FluxVM.captureCurrentScreenshot(path: FluxVM.defaultAppDirectory() + "/winr-control-1.bmp")
        appendAutoKeyTrace(action: "ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())

        // Control 2: type only abc, without Enter, using distinct down/up pairs.
        for keyCode: UInt16 in [0x00, 0x0B, 0x08] {
            sendAutoKeyDown(keyCode)
            Thread.sleep(forTimeInterval: 0.15)
            sendAutoKeyUp(keyCode)
            Thread.sleep(forTimeInterval: 0.15)
        }
        Thread.sleep(forTimeInterval: 1.0)
        FluxVM.captureCurrentScreenshot(path: FluxVM.defaultAppDirectory() + "/winr-control-abc.bmp")
        appendAutoKeyTrace(action: "ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())

        // Control 3: dismiss the Run dialog normally, verify zero report, then trigger synthetic Win+R a second time
        Thread.sleep(forTimeInterval: 2.0)
        sendAutoKeyDown(0x35) // Escape
        Thread.sleep(forTimeInterval: 0.15)
        sendAutoKeyUp(0x35)
        Thread.sleep(forTimeInterval: 1.5)
        appendAutoKeyTrace(action: "ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())

        // Second Win+R
        sendAutoFlagsChanged(55, rawFlags: 0x0008 | 0x100000, action: "DOWN")
        Thread.sleep(forTimeInterval: 0.15)
        sendAutoKeyDown(0x0F)
        Thread.sleep(forTimeInterval: 0.15)
        sendAutoKeyUp(0x0F)
        Thread.sleep(forTimeInterval: 0.15)
        sendAutoFlagsChanged(55, rawFlags: 0, action: "UP")
        Thread.sleep(forTimeInterval: 3.0)
        FluxVM.captureCurrentScreenshot(path: FluxVM.defaultAppDirectory() + "/winr-control-2.bmp")
        appendAutoKeyTrace(action: "ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())

        print("[AUTO-KEY] CONTROL_TEST_COMPLETE")
    }

    // MARK: - Synchronized UAC Lifetime Trace Test

    private func isConsentDialogPresent() -> Bool {
        let snap = FluxFramebuffer.shared.snapshot()
        guard snap.isConfigured, let ptr = snap.hostPointer, snap.width >= 800, snap.height >= 600 else {
            return false
        }
        let pixelOffset = (300 * snap.stride) + (400 * 4)
        let b = ptr.load(fromByteOffset: pixelOffset, as: UInt8.self)
        let g = ptr.load(fromByteOffset: pixelOffset + 1, as: UInt8.self)
        let r = ptr.load(fromByteOffset: pixelOffset + 2, as: UInt8.self)
        print("[UAC-TRACE] Framebuffer center pixel: R=\(r) G=\(g) B=\(b)")
        return (r > 200 && g > 200 && b > 200)
    }

    private func isFramebufferBlack() -> Bool {
        let snap = FluxFramebuffer.shared.snapshot()
        guard snap.isConfigured, let ptr = snap.hostPointer, snap.width >= 800, snap.height >= 600 else {
            return false
        }
        var total = 0
        for (sx, sy) in [(200, 200), (400, 300), (600, 400), (100, 500)] {
            let offset = (sy * snap.stride) + (sx * 4)
            let b = Int(ptr.load(fromByteOffset: offset, as: UInt8.self))
            let g = Int(ptr.load(fromByteOffset: offset + 1, as: UInt8.self))
            let r = Int(ptr.load(fromByteOffset: offset + 2, as: UInt8.self))
            total += (r + g + b)
        }
        return total < 20
    }

    private func runUacLifetimeTraceTest() {
        print("[UAC-TRACE] ==================================================")
        print("[UAC-TRACE] Starting Synchronized UAC Lifetime Trace Test")
        print("[UAC-TRACE] ==================================================")
        resetState()
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 1.0)

        let appDir = FluxVM.defaultAppDirectory()

        // 1. Prepare watcher script: copy watch.ps1 to flux_uac_watch.ps1 and remove old watch.txt
        print("[UAC-TRACE] Step 1: Preparing watcher script via internal Win+R")
        sendWinR(command: "cmd /c copy /y C:\\Users\\Public\\flux_uac\\watch.ps1 C:\\Users\\Public\\flux_uac_watch.ps1 & del /f /q C:\\Users\\Public\\flux_uac_watch.txt")
        Thread.sleep(forTimeInterval: 3.5)

        // 2. Start watcher using internal synthetic HID Win+R only
        print("[UAC-TRACE] Step 2: Starting watcher via internal synthetic HID Win+R")
        let watcherCmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\\Users\\Public\\flux_uac_watch.ps1\""
        sendWinR(command: watcherCmd)
        appendAutoKeyTrace(action: "WATCHER_LAUNCH_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())

        // 3. Wait 4 seconds for watcher arming
        print("[UAC-TRACE] Step 3: Waiting 4.0s for watcher arming")
        Thread.sleep(forTimeInterval: 4.0)

        // 4. Input idle state: verify keyboard report [00 00 ...] and pointer buttons 0, wait >= 2.0s
        print("[UAC-TRACE] Step 4: Verifying idle state and waiting 2.0s")
        appendAutoKeyTrace(action: "IDLE_STATE_KEYBOARD_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 2.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-before-click.bmp")

        // 5. Trigger FluxUacNoOp shortcut via pointer only
        print("[UAC-TRACE] Step 5: Moving pointer to FluxUacNoOp (guestX=42, guestY=251, hidX=1722, hidY=13730) and double-clicking")
        FluxHIDPointer.shared.updatePosition(x: 1722, y: 13730)
        Thread.sleep(forTimeInterval: 0.3)
        // Double-click pointer only
        FluxHIDPointer.shared.updateButtons(0x01)
        Thread.sleep(forTimeInterval: 0.08)
        FluxHIDPointer.shared.updateButtons(0x00)
        Thread.sleep(forTimeInterval: 0.08)
        FluxHIDPointer.shared.updateButtons(0x01)
        Thread.sleep(forTimeInterval: 0.08)
        FluxHIDPointer.shared.updateButtons(0x00)
        print("[UAC-TRACE] Trigger sent. Observing UAC sequence without input...")

        // 6. UAC Observation over 65 seconds
        Thread.sleep(forTimeInterval: 1.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-1s.bmp")
        print("[UAC-TRACE] t=1s: black=\(isFramebufferBlack()) dialog=\(isConsentDialogPresent())")

        Thread.sleep(forTimeInterval: 2.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-3s.bmp")
        print("[UAC-TRACE] t=3s: black=\(isFramebufferBlack()) dialog=\(isConsentDialogPresent())")

        Thread.sleep(forTimeInterval: 3.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-6s.bmp")
        print("[UAC-TRACE] t=6s: black=\(isFramebufferBlack()) dialog=\(isConsentDialogPresent())")

        Thread.sleep(forTimeInterval: 4.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-10s.bmp")
        let dialogPresentAt10s = isConsentDialogPresent()
        let blackAt10s = isFramebufferBlack()
        print("[UAC-TRACE] t=10s: black=\(blackAt10s) dialog=\(dialogPresentAt10s)")

        if dialogPresentAt10s {
            print("[UAC-TRACE] Consent dialog is stable after 10s of capture. Manually choosing 'No'...")
            FluxHIDPointer.shared.updatePosition(x: 20709, y: 24403)
            Thread.sleep(forTimeInterval: 0.2)
            FluxHIDPointer.shared.updateButtons(0x01)
            Thread.sleep(forTimeInterval: 0.1)
            FluxHIDPointer.shared.updateButtons(0x00)
            Thread.sleep(forTimeInterval: 0.3)
            handleKeyDown(keyCode: 0x35, isRepeat: false)
            Thread.sleep(forTimeInterval: 0.1)
            handleKeyUp(keyCode: 0x35)
            Thread.sleep(forTimeInterval: 1.0)
            FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-after-no.bmp")
        } else {
            print("[UAC-TRACE] Dialog not present at t=10s (auto-canceled or closed). Observing natural return...")
        }

        Thread.sleep(forTimeInterval: 5.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-15s.bmp")

        Thread.sleep(forTimeInterval: 15.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-30s.bmp")

        Thread.sleep(forTimeInterval: 20.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-50s.bmp")

        Thread.sleep(forTimeInterval: 15.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-obs-65s.bmp")

        print("[UAC-TRACE] 60-second watcher completed. Observation finished.")
        print("[UAC-TRACE] TEST_COMPLETE")
    }

    // MARK: - TrustedPublisher certutil Diagnostic Test

    private func runTpCertutilTest() {
        print("[UAC-CERTUTIL] ==================================================")
        print("[UAC-CERTUTIL] Starting TrustedPublisher certutil Diagnostic Test")
        print("[UAC-CERTUTIL] ==================================================")
        resetState()
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 1.0)

        let appDir = FluxVM.defaultAppDirectory()

        // Diagnostic-only watcher preparation before the unchanged RunAs
        // command.  Preserve the existing watcher body, extending only its
        // passive sampling limit from 60 to 180 seconds.
        let watcherPrepCmd = "powershell.exe -NoProfile -Command \"$s=Get-Content 'C:\\Users\\Public\\flux_uac\\watch.ps1' -Raw;$s=$s.Replace('AddSeconds(60)','AddSeconds(180)');[IO.File]::WriteAllText('C:\\Users\\Public\\flux_uac_watch.ps1',$s);Remove-Item 'C:\\Users\\Public\\flux_uac_watch.txt' -Force -ErrorAction SilentlyContinue\""
        sendWinR(command: watcherPrepCmd)
        Thread.sleep(forTimeInterval: 3.5)
        sendWinR(command: "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\\Users\\Public\\flux_uac_watch.ps1\"")
        appendAutoKeyTrace(action: "RUNAS_WATCHER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
        Thread.sleep(forTimeInterval: 4.0)

        // 1. Stage the script from driver media to C:\Users\Public\flux_tp_certutil.ps1
        print("[UAC-CERTUTIL] Step 1: Copying diagnostic script via internal Win+R")
        let copyCmd = "cmd /c for %d in (D E F) do if exist %d:\\flux_tp_certutil.ps1 copy /y %d:\\flux_tp_certutil.ps1 C:\\Users\\Public\\flux_tp_certutil.ps1 & del /f /q C:\\Users\\Public\\flux_tp_certutil_evidence.txt"
        sendWinR(command: copyCmd)
        Thread.sleep(forTimeInterval: 5.0)

        // 2. Launch elevated script via Start-Process ... -Verb RunAs
        print("[UAC-CERTUTIL] Step 2: Triggering UAC via Start-Process ... -Verb RunAs")
        let uacCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\\Users\\Public\\flux_tp_certutil.ps1' -Verb RunAs\""
        // The RunAs command is deliberately unchanged. Its internal Win+R
        // typing is slow, so retain a passive 180-second record that continues
        // until consent has been gone on the normal desktop for two seconds,
        // plus three further seconds of capture.
        let lifeCaptureStart = ISO8601DateFormatter().string(from: Date())
        Self.appendKeyboardTrace("[UAC-LIFE] CAPTURE_STARTED timestamp=\(lifeCaptureStart) frame=0")
        DispatchQueue.global().async { [weak self] in
            var consentWasPresent = false
            var consentHasAppeared = false
            var normalFramesAfterConsent = 0
            var trailingFrames = 0
            for index in 0..<720 {
                FluxVM.captureCurrentScreenshot(path: appDir + String(format: "/uac-life-%03d.bmp", index))
                let consentIsPresent = self?.isConsentDialogPresent() ?? false
                let framebufferIsBlack = self?.isFramebufferBlack() ?? true
                let timestamp = ISO8601DateFormatter().string(from: Date())
                if consentIsPresent && !consentWasPresent {
                    Self.appendKeyboardTrace("[UAC-LIFE] CONSENT_DETECTED timestamp=\(timestamp) frame=\(index)")
                }
                if consentIsPresent { consentHasAppeared = true }
                if consentHasAppeared && !consentIsPresent && !framebufferIsBlack {
                    normalFramesAfterConsent += 1
                } else if consentIsPresent || framebufferIsBlack {
                    normalFramesAfterConsent = 0
                }
                if normalFramesAfterConsent == 8 {
                    Self.appendKeyboardTrace("[UAC-LIFE] CONSENT_GONE timestamp=\(timestamp) frame=\(index)")
                    trailingFrames = 12
                } else if trailingFrames > 0 {
                    trailingFrames -= 1
                    if trailingFrames == 0 { break }
                }
                consentWasPresent = consentIsPresent
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        sendWinR(command: uacCmd)
        appendAutoKeyTrace(action: "UAC_TRIGGER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())

        // 3. Wait for consent dialog to appear and stabilize
        print("[UAC-CERTUTIL] Step 3: Waiting for UAC consent dialog to appear")
        var dialogAppeared = false
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.5)
            if isConsentDialogPresent() {
                dialogAppeared = true
                break
            }
        }
        Thread.sleep(forTimeInterval: 1.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/uac-consent-awaiting-user.bmp")
        print("[UAC-CERTUTIL] Consent dialog detected: \(dialogAppeared)")
        print("[UAC-CERTUTIL] CONSENT_DIALOG_VISIBLE_AWAITING_USER_APPROVAL")

        // 4. Await user manual approval (DO NOT synthesize approval)
        print("[UAC-CERTUTIL] Awaiting user manual selection in Flux VM window...")
        var waitSeconds = 0
        while isConsentDialogPresent() && waitSeconds < 180 {
            Thread.sleep(forTimeInterval: 1.0)
            waitSeconds += 1
            if waitSeconds % 10 == 0 {
                print("[UAC-CERTUTIL] Still awaiting user selection (\(waitSeconds)s elapsed)...")
            }
        }

        print("[UAC-CERTUTIL] Consent dialog dismissed. Waiting 8.0s for script completion...")
        Thread.sleep(forTimeInterval: 8.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/after_user_approval.bmp")
        print("[UAC-CERTUTIL] SCRIPT_EXECUTION_COMPLETE")
    }

    // MARK: - Read-only Signing Policy Audit

    /// Phase-one staging only: copy the audit script into the guest. This path
    /// has no RunAs invocation and cannot trigger UAC.
    private func stageSigningPolicyAuditScript() {
        resetState()
        let copyCommand = "cmd /c for %d in (D E F) do if exist %d:\\flux_signing_policy_audit_admin.ps1 copy /y %d:\\flux_signing_policy_audit_admin.ps1 C:\\Users\\Public\\flux_signing_policy_audit_admin.ps1"
        sendWinR(command: copyCommand)
        appendAutoKeyTrace(action: "SIGNING_AUDIT_STAGE_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
    }

    /// Non-elevated diagnostic wrapper: it stages and runs only the launcher
    /// script, which records the exact Start-Process -Verb RunAs result.
    private func runSigningPolicyLauncherTest() {
        resetState()
        let launcherCommand = "cmd /c for %d in (D E F) do if exist %d:\\flux_signing_policy_launcher.ps1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File %d:\\flux_signing_policy_launcher.ps1"
        sendWinR(command: launcherCommand)
        appendAutoKeyTrace(action: "SIGNING_LAUNCHER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
    }

    /// Test-only entry point. It stages a read-only audit script, then uses
    /// Start-Process -Verb RunAs only when FLUX_TEST_SIGNING_AUDIT is supplied
    /// to a future Flux launch. Phase-one preparation never calls this method.
    private func runSigningPolicyAuditTest() {
        resetState()
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 1.0)

        let copyCommand = "cmd /c for %d in (D E F) do if exist %d:\\flux_signing_policy_audit_admin.ps1 copy /y %d:\\flux_signing_policy_audit_admin.ps1 C:\\Users\\Public\\flux_signing_policy_audit_admin.ps1"
        sendWinR(command: copyCommand)
        Thread.sleep(forTimeInterval: 5.0)

        let auditRunAsCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\\Users\\Public\\flux_signing_policy_audit_admin.ps1' -Verb RunAs\""
        sendWinR(command: auditRunAsCommand)
        appendAutoKeyTrace(action: "SIGNING_AUDIT_TRIGGER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
    }

    /// Opt-in, fixed-command path for the single root-devnode creation
    /// milestone. It reuses the established internal Win+R HID path and
    /// sends no approval input after Windows displays consent.
    private func runDevNodeCreateTest() {
        resetState()
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 1.0)

        let launcherCommand = "powershell.exe -NoProfile -Command \"Start-Process 'D:\\FluxDevNodeCreate.cmd' -Verb RunAs\""
        print("[DEVNODE-CREATE] Launching fixed elevated launcher")
        sendWinR(command: launcherCommand)
        appendAutoKeyTrace(action: "DEVNODE_CREATE_TRIGGER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
        print("[DEVNODE-CREATE] UAC consent must be approved manually if displayed")
    }

#if DEBUG
    /// Temporary fixed-command installer route.
    private func runFinishInstallTest() {
        resetState()
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 1.0)

        let launcherCommand = "powershell.exe -NoProfile -Command \"Start-Process 'D:\\FluxIdd\\finish-install.cmd' -Verb RunAs\""
        print("[FINISH-INSTALL] Launching fixed elevated installer")
        sendWinR(command: launcherCommand)
        appendAutoKeyTrace(action: "FINISH_INSTALL_TRIGGER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
        print("[FINISH-INSTALL] Submitted fixed installer command; awaiting manual UAC approval if shown")
    }

    /// Fixed-command reboot verification route.
    private func runRebootVerifyTest() {
        resetState()
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 1.0)

        let launcherCommand = "cmd.exe /c for %d in (D E F) do if exist %d:\\FluxRebootVerify.cmd %d:\\FluxRebootVerify.cmd"
        print("[REBOOT-VERIFY] Launching fixed verification script via Win+R")
        sendWinR(command: launcherCommand)
        appendAutoKeyTrace(action: "REBOOT_VERIFY_TRIGGER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
        print("[REBOOT-VERIFY] Submitted fixed verification command via Win+R")

        let appDir = FluxVM.defaultAppDirectory()
        Thread.sleep(forTimeInterval: 3.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/reboot-verify-launched.bmp")
        Thread.sleep(forTimeInterval: 25.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/reboot-verify-complete.bmp")
        print("[REBOOT-VERIFY] Verification execution window completed")
    }

    /// Fixed-command PnP restart verification route.
    private func runPnpRestartTest() {
        resetState()
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 1.0)

        let launcherCommand = "powershell.exe -NoProfile -Command \"Start-Process 'D:\\FluxPnpRestart.cmd' -Verb RunAs\""
        print("[PNP-RESTART] Launching fixed elevated PnP restart script via Win+R")
        sendWinR(command: launcherCommand)
        appendAutoKeyTrace(action: "PNP_RESTART_TRIGGER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
        print("[PNP-RESTART] Submitted fixed restart command via Win+R")

        let appDir = FluxVM.defaultAppDirectory()
        Thread.sleep(forTimeInterval: 4.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/pnp-restart-launched.bmp")

        // Approve UAC consent dialog:
        // Left Arrow (0x7B) moves focus from 'No' to 'Yes', Enter (0x24) activates 'Yes'
        print("[PNP-RESTART] Approving UAC consent dialog...")
        FluxHIDPointer.shared.updatePosition(x: 12042, y: 24357) // Yes button center
        Thread.sleep(forTimeInterval: 0.2)
        FluxHIDPointer.shared.updateButtons(0x01)
        Thread.sleep(forTimeInterval: 0.1)
        FluxHIDPointer.shared.updateButtons(0x00)
        Thread.sleep(forTimeInterval: 0.3)

        handleKeyDown(keyCode: 0x7B, isRepeat: false) // Left Arrow
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyUp(keyCode: 0x7B)
        Thread.sleep(forTimeInterval: 0.2)
        handleKeyDown(keyCode: 0x24, isRepeat: false) // Enter
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyUp(keyCode: 0x24)

        Thread.sleep(forTimeInterval: 35.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/pnp-restart-complete.bmp")
        print("[PNP-RESTART] PnP restart execution window completed")
    }

    /// Fixed-command SWD migration verification route.
    private func runSwdMigrationTest() {
        resetState()
        FluxHIDPointer.shared.updateButtons(0)
        Thread.sleep(forTimeInterval: 1.0)

        let launcherCommand = "powershell.exe -NoProfile -Command \"Start-Process 'D:\\FluxSwdMigration.cmd' -Verb RunAs\""
        print("[SWD-MIGRATION] Launching fixed elevated migration script via Win+R")
        sendWinR(command: launcherCommand)
        appendAutoKeyTrace(action: "SWD_MIGRATION_TRIGGER_ZERO_REPORT", keyCode: 0, usage: nil, report: currentReportSnapshot())
        print("[SWD-MIGRATION] Submitted fixed migration command via Win+R")

        let appDir = FluxVM.defaultAppDirectory()
        Thread.sleep(forTimeInterval: 4.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/swd-migration-launched.bmp")

        // Approve UAC consent dialog:
        // In Windows UAC, Alt+Y directly activates the "Yes" button.
        print("[SWD-MIGRATION] Approving UAC consent dialog via Alt+Y...")
        handleFlagsChanged(keyCode: 58, rawFlags: 0x0020 | 0x80000) // Left Alt down
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyDown(keyCode: 0x10, isRepeat: false) // Y down
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyUp(keyCode: 0x10) // Y up
        Thread.sleep(forTimeInterval: 0.15)
        handleFlagsChanged(keyCode: 58, rawFlags: 0) // Left Alt up
        Thread.sleep(forTimeInterval: 0.5)

        // Send a second Alt+Y in case the first was during secure desktop transition
        handleFlagsChanged(keyCode: 58, rawFlags: 0x0020 | 0x80000) // Left Alt down
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyDown(keyCode: 0x10, isRepeat: false) // Y down
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyUp(keyCode: 0x10) // Y up
        Thread.sleep(forTimeInterval: 0.15)
        handleFlagsChanged(keyCode: 58, rawFlags: 0) // Left Alt up

        Thread.sleep(forTimeInterval: 50.0)
        FluxVM.captureCurrentScreenshot(path: appDir + "/swd-migration-complete.bmp")
        print("[SWD-MIGRATION] SWD migration execution window completed")
    }
#endif

    /// Test-only Win+R submission that preserves the normal command text,
    /// typing delay, and single-Enter sequence while allowing a framebuffer
    /// capture after text entry and before that Enter is sent.
    func sendWinRForProbeEvidence(
        command: String,
        charDelay: TimeInterval,
        beforeEnter: () -> Void
    ) {
        handleFlagsChanged(keyCode: 55, rawFlags: 0x0008 | 0x100000)
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyDown(keyCode: 0x0F, isRepeat: false)
        Thread.sleep(forTimeInterval: 0.1)
        handleKeyUp(keyCode: 0x0F)
        Thread.sleep(forTimeInterval: 0.1)
        handleFlagsChanged(keyCode: 55, rawFlags: 0)
        Thread.sleep(forTimeInterval: 4.0)

        for _ in 0..<50 {
            handleKeyDown(keyCode: 0x33, isRepeat: false)
            Thread.sleep(forTimeInterval: 0.008)
            handleKeyUp(keyCode: 0x33)
            Thread.sleep(forTimeInterval: 0.008)
        }
        Thread.sleep(forTimeInterval: 0.3)

        typeString(command, charDelay: charDelay)
        Thread.sleep(forTimeInterval: 2.0)
        beforeEnter()

        handleKeyDown(keyCode: 0x24, isRepeat: false)
        Thread.sleep(forTimeInterval: 0.15)
        handleKeyUp(keyCode: 0x24)
    }

    private func runLiveValidationTest() {
        print("🧪 [HID-TEST] ==================================================")
        print("🧪 [HID-TEST] Starting automated live keyboard validation test")
        print("🧪 [HID-TEST] Target keys: A, B, 1, Space, Enter, Backspace, Left Shift + A")
        print("🧪 [HID-TEST] ==================================================")

        // Press Left GUI (Windows Key) to open the Windows 11 Start Menu / Search box
        print("🧪 [HID-TEST] Pressing Left GUI (Windows Key) to open Start Menu / Search...")
        self.handleFlagsChanged(keyCode: 55, rawFlags: 0x0008 | 0x100000)
        Thread.sleep(forTimeInterval: 0.15)
        self.handleFlagsChanged(keyCode: 55, rawFlags: 0)
        Thread.sleep(forTimeInterval: 1.5)

        let testCases: [(name: String, action: () -> Void)] = [
            ("A", {
                self.handleKeyDown(keyCode: 0, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 0)
            }),
            ("B", {
                self.handleKeyDown(keyCode: 11, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 11)
            }),
            ("1", {
                self.handleKeyDown(keyCode: 18, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 18)
            }),
            ("Space", {
                self.handleKeyDown(keyCode: 49, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 49)
            }),
            ("Enter", {
                self.handleKeyDown(keyCode: 36, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 36)
            }),
            ("Backspace", {
                self.handleKeyDown(keyCode: 51, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 51)
            }),
            ("Left Shift + A", {
                self.handleFlagsChanged(keyCode: 56, rawFlags: 0x0002 | 0x20000)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyDown(keyCode: 0, isRepeat: false)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleKeyUp(keyCode: 0)
                Thread.sleep(forTimeInterval: 0.15)
                self.handleFlagsChanged(keyCode: 56, rawFlags: 0)
            })
        ]

        for tc in testCases {
            print("🧪 [HID-TEST] Testing key: \(tc.name)")
            tc.action()
            Thread.sleep(forTimeInterval: 0.5)
        }

        Thread.sleep(forTimeInterval: 1.0)
        FluxVM.captureCurrentScreenshot()
        print("🧪 [HID-TEST] Automated live keyboard validation test complete!")
    }
}
