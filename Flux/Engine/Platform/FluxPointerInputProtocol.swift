import CoreGraphics

/// Shared, host-only definition of Flux's USB absolute-pointer report.
///
/// The final byte uses the HID Consumer `AC Pan` usage (0x0238). Windows
/// maps that relative control to horizontal scrolling while preserving the
/// standard Generic Desktop Wheel for vertical scrolling.
enum FluxPointerInputProtocol {
    nonisolated static let reportLength = 7
    nonisolated static let releasedButtons: UInt8 = 0

    /// HID report descriptor for Endpoint 0x82 / DCI 5. There is no report ID:
    /// [buttons, xLo, xHi, yLo, yHi, verticalWheel, horizontalPan].
    nonisolated static let reportDescriptor: [UInt8] = [
        0x05, 0x01, // Usage Page (Generic Desktop)
        0x09, 0x02, // Usage (Mouse)
        0xA1, 0x01, // Collection (Application)
        0x09, 0x01, //   Usage (Pointer)
        0xA1, 0x00, //   Collection (Physical)
        0x05, 0x09, //     Usage Page (Button)
        0x19, 0x01, //     Usage Minimum (1)
        0x29, 0x03, //     Usage Maximum (3)
        0x15, 0x00, //     Logical Minimum (0)
        0x25, 0x01, //     Logical Maximum (1)
        0x95, 0x03, //     Report Count (3)
        0x75, 0x01, //     Report Size (1)
        0x81, 0x02, //     Input (Data, Variable, Absolute)
        0x95, 0x01, //     Report Count (1)
        0x75, 0x05, //     Report Size (5)
        0x81, 0x01, //     Input (Constant): button padding
        0x05, 0x01, //     Usage Page (Generic Desktop)
        0x09, 0x30, //     Usage (X)
        0x09, 0x31, //     Usage (Y)
        0x15, 0x00, //     Logical Minimum (0)
        0x26, 0xFF, 0x7F, // Logical Maximum (32767)
        0x75, 0x10, //     Report Size (16)
        0x95, 0x02, //     Report Count (2)
        0x81, 0x02, //     Input (Data, Variable, Absolute): X/Y
        0x09, 0x38, //     Usage (Wheel)
        0x15, 0x81, //     Logical Minimum (-127)
        0x25, 0x7F, //     Logical Maximum (127)
        0x75, 0x08, //     Report Size (8)
        0x95, 0x01, //     Report Count (1)
        0x81, 0x06, //     Input (Data, Variable, Relative): vertical wheel
        0x05, 0x0C, //     Usage Page (Consumer)
        0x0A, 0x38, 0x02, // Usage (AC Pan)
        0x15, 0x81, //     Logical Minimum (-127)
        0x25, 0x7F, //     Logical Maximum (127)
        0x75, 0x08, //     Report Size (8)
        0x95, 0x01, //     Report Count (1)
        0x81, 0x06, //     Input (Data, Variable, Relative): horizontal pan
        0xC0,       //   End Collection
        0xC0,       // End Collection
    ]

    /// USB HID `wDescriptorLength`, derived from the descriptor that is served
    /// for the pointer interface.
    nonisolated static let reportDescriptorLength = UInt16(reportDescriptor.count)
    nonisolated static let reportDescriptorLengthLittleEndian: [UInt8] = [
        UInt8(truncatingIfNeeded: reportDescriptorLength),
        UInt8(truncatingIfNeeded: reportDescriptorLength >> 8),
    ]

    nonisolated static func makeReport(buttons: UInt8, x: UInt16, y: UInt16, verticalWheel: Int8, horizontalPan: Int8) -> [UInt8] {
        [
            buttons & 0x07,
            UInt8(truncatingIfNeeded: x),
            UInt8(truncatingIfNeeded: x >> 8),
            UInt8(truncatingIfNeeded: y),
            UInt8(truncatingIfNeeded: y >> 8),
            UInt8(bitPattern: verticalWheel),
            UInt8(bitPattern: horizontalPan),
        ]
    }

    nonisolated static func endpointCanCarryReport(requestLength: Int, maxPacketSize: Int) -> Bool {
        requestLength >= reportLength && maxPacketSize >= reportLength
    }

    nonisolated static func mapPointToHID(
        viewPoint: CGPoint,
        viewSize: CGSize,
        fbWidth: Int,
        fbHeight: Int,
        fillScreen: Bool = false
    ) -> (hidX: UInt16, hidY: UInt16, guestX: Int, guestY: Int)? {
        guard fbWidth > 0, fbHeight > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }

        let renderWidth: CGFloat
        let renderHeight: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        if fillScreen {
            renderWidth = viewSize.width
            renderHeight = viewSize.height
            offsetX = 0
            offsetY = 0
        } else {
            let fbAspect = CGFloat(fbWidth) / CGFloat(fbHeight)
            let viewAspect = viewSize.width / viewSize.height
            if viewAspect > fbAspect {
                renderHeight = viewSize.height
                renderWidth = viewSize.height * fbAspect
                offsetX = (viewSize.width - renderWidth) / 2.0
                offsetY = 0
            } else {
                renderWidth = viewSize.width
                renderHeight = viewSize.width / fbAspect
                offsetX = 0
                offsetY = (viewSize.height - renderHeight) / 2.0
            }
        }

        let normalizedX = min(max(viewPoint.x - offsetX, 0), renderWidth) / renderWidth
        let normalizedY = min(max(viewPoint.y - offsetY, 0), renderHeight) / renderHeight
        return (
            UInt16(clamping: Int(round(normalizedX * 32767.0))),
            UInt16(clamping: Int(round(normalizedY * 32767.0))),
            Int(round(normalizedX * CGFloat(fbWidth - 1))),
            Int(round(normalizedY * CGFloat(fbHeight - 1)))
        )
    }
}

/// Bounded, independent trackpad accumulators. AppKit already applies the
/// user's natural-scrolling preference before these deltas arrive, so Flux
/// intentionally forwards their orientation unchanged.
struct FluxScrollAccumulator {
    private(set) var horizontal: CGFloat = 0
    private(set) var vertical: CGFloat = 0

    mutating func consume(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) -> (vertical: Int8, horizontal: Int8) {
        let threshold: CGFloat = precise ? 8.0 : 1.0
        let maximumPending = threshold * 5.0
        horizontal = min(max(horizontal + deltaX, -maximumPending), maximumPending)
        vertical = min(max(vertical + deltaY, -maximumPending), maximumPending)

        let horizontalSteps = Int(horizontal / threshold)
        let verticalSteps = Int(vertical / threshold)
        horizontal -= CGFloat(horizontalSteps) * threshold
        vertical -= CGFloat(verticalSteps) * threshold
        return (Int8(clamping: verticalSteps), Int8(clamping: horizontalSteps))
    }

    mutating func reset() {
        horizontal = 0
        vertical = 0
    }
}

/// AppKit-event-derived button state. The display view owns this state instead
/// of polling NSEvent.pressedMouseButtons, which is not reliable for every
/// trackpad-generated click event.
struct FluxPointerButtonState {
    private(set) var mask: UInt8 = 0

    static func bit(forButtonNumber number: Int) -> UInt8? {
        switch number {
        case 0: return 0x01 // primary / left
        case 1: return 0x02 // secondary / right
        case 2: return 0x04 // middle
        default: return nil
        }
    }

    @discardableResult
    mutating func press(buttonNumber: Int) -> Bool {
        guard let bit = Self.bit(forButtonNumber: buttonNumber) else { return false }
        let previous = mask
        mask |= bit
        return mask != previous
    }

    @discardableResult
    mutating func release(buttonNumber: Int) -> Bool {
        guard let bit = Self.bit(forButtonNumber: buttonNumber) else { return false }
        let previous = mask
        mask &= ~bit
        return mask != previous
    }

    @discardableResult
    mutating func reset() -> Bool {
        let hadButtons = mask != 0
        mask = 0
        return hadButtons
    }
}
