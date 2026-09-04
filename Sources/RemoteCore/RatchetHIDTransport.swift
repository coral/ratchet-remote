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
    private let manager: IOHIDManager
    private let continuation: AsyncStream<RatchetTransportEvent>.Continuation
    public let events: AsyncStream<RatchetTransportEvent>
    private var currentDevice: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: HIDFraming.reportSize + 1)
    private var started = false

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
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
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            continuation.yield(.error("opening Ratchet HID manager failed: 0x\(String(UInt32(bitPattern: result), radix: 16))"))
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        closeCurrentDevice()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
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
        guard result == kIOReturnSuccess, currentDevice == nil else { return }
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
        guard result == kIOReturnSuccess else {
            continuation.yield(.error("reading Ratchet HID report failed: 0x\(String(UInt32(bitPattern: result), radix: 16))"))
            return
        }
        continuation.yield(.report(report))
    }

    private func closeCurrentDevice() {
        guard let device = currentDevice else { return }
        currentDevice = nil
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
