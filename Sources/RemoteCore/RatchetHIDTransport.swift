import CoreFoundation
import Foundation
import IOKit.hid
import RatchetProtocol

public enum RatchetTransportEvent: Sendable {
    case connected(serial: String?)
    case disconnected
    case report(Data)
    case error(String)
}

private func ratchetDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let owner = Unmanaged<RatchetHIDTransport>.fromOpaque(context).takeUnretainedValue()
    owner.handleMatched(device, result: result)
}

private func ratchetDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let owner = Unmanaged<RatchetHIDTransport>.fromOpaque(context).takeUnretainedValue()
    owner.handleRemoved(device, result: result)
}

private func ratchetInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context else { return }
    let owner = Unmanaged<RatchetHIDTransport>.fromOpaque(context).takeUnretainedValue()
    let data = Data(bytes: report, count: reportLength)
    owner.handleReport(data, result: result)
}

/// IOKit callbacks are scheduled on the main run loop. The unchecked Sendable
/// conformance records that confinement for Swift's concurrency checker.
public final class RatchetHIDTransport: @unchecked Sendable {
    private var manager: IOHIDManager?
    private let continuation: AsyncStream<RatchetTransportEvent>.Continuation
    public let events: AsyncStream<RatchetTransportEvent>
    private var currentDevice: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: HIDFraming.reportSize + 1)
    private var started = false

    public init() {
        let pair = AsyncStream<RatchetTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = pair.stream
        continuation = pair.continuation
    }

    deinit {
        inputBuffer.deallocate()
    }

    public func start() {
        guard !started else { return }
        started = true
        // Reusing a closed manager can retain its known-device set without
        // replaying matching callbacks, leaving currentDevice nil forever.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: RatchetProtocolConstants.vendorID,
            kIOHIDProductIDKey as String: RatchetProtocolConstants.productID,
            kIOHIDPrimaryUsagePageKey as String: RatchetProtocolConstants.usagePage,
            kIOHIDPrimaryUsageKey as String: RatchetProtocolConstants.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, ratchetDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, ratchetDeviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            continuation.yield(.error("opening Ratchet HID manager failed: 0x\(String(UInt32(bitPattern: result), radix: 16))"))
            return
        }
        // Adopt already-enumerated devices as well as future callback matches.
        // handleMatched is idempotent when the callback subsequently arrives.
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices {
                handleMatched(device, result: kIOReturnSuccess)
            }
        }
    }

    public func stop() {
        guard started, let manager else { return }
        started = false
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        closeCurrentDevice()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    public func send(_ report: Data) throws {
        guard let currentDevice else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Ratchet H1 is not connected"])
        }
        guard report.count == HIDFraming.reportSize else {
            throw HIDFraming.FrameError.invalidReportSize(report.count)
        }
        let result = report.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(
                currentDevice,
                kIOHIDReportTypeOutput,
                0,
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "writing Ratchet HID report failed: 0x\(String(UInt32(bitPattern: result), radix: 16))",
            ])
        }
    }

    fileprivate func handleMatched(_ device: IOHIDDevice, result: IOReturn) {
        guard started, result == kIOReturnSuccess, currentDevice == nil else { return }
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            continuation.yield(.error("opening Ratchet H1 failed: 0x\(String(UInt32(bitPattern: openResult), radix: 16))"))
            return
        }
        currentDevice = device
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            HIDFraming.reportSize + 1,
            ratchetInputReport,
            Unmanaged.passUnretained(self).toOpaque()
        )
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        continuation.yield(.connected(serial: serial))
    }

    fileprivate func handleRemoved(_ device: IOHIDDevice, result: IOReturn) {
        guard let currentDevice, CFEqual(currentDevice, device) else { return }
        closeCurrentDevice()
        continuation.yield(.disconnected)
    }

    fileprivate func handleReport(_ report: Data, result: IOReturn) {
        guard started, currentDevice != nil else { return }
        guard result == kIOReturnSuccess else {
            continuation.yield(.error("reading Ratchet HID report failed: 0x\(String(UInt32(bitPattern: result), radix: 16))"))
            return
        }
        continuation.yield(.report(report))
    }

    private func closeCurrentDevice() {
        guard let device = currentDevice else { return }
        currentDevice = nil
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, HIDFraming.reportSize + 1, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
