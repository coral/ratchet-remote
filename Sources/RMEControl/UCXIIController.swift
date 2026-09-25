import CoreFoundation
import Foundation
import IOKit

private let rmeDriverClass = "de_rme_audio_dkusb"
private let deviceIdentitySelector: UInt32 = 7
private let triggerDSPReadSelector: UInt32 = 12
private let writeDSPSelector: UInt32 = 18
private let readDSPSelector: UInt32 = 19
private let dspReadWords = 256
private let dspReadRetryInterval: TimeInterval = 0.020
private let snapshotRetryInterval: TimeInterval = 0.250

private final class RMEConnection: UCXIIDSPTransport, @unchecked Sendable {
    let port: io_connect_t

    init(port: io_connect_t) {
        self.port = port
    }

    deinit {
        IOServiceClose(port)
    }

    func identify() throws -> UCXIIDeviceIdentity {
        var scalars = [UInt64](repeating: 0, count: 2)
        var count: UInt32 = 2
        let status = scalars.withUnsafeMutableBufferPointer {
            IOConnectCallScalarMethod(port, deviceIdentitySelector, nil, 0, $0.baseAddress, &count)
        }
        try checkIO(status, operation: "identifying the opened RME device")
        guard count == 2 else { throw RMEControlError.invalidIdentitySize(count) }
        return UCXIIDeviceIdentity(serial: scalars[0], product: scalars[1])
    }

    func writeDSP(_ words: [UInt32]) throws {
        let packet = try UCXIIDSPWrite(words)
        var scalarCount = packet.wordCount
        let status: kern_return_t = packet.staging.withUnsafeBytes { structure in
            withUnsafePointer(to: &scalarCount) { count in
                IOConnectCallMethod(
                    port,
                    writeDSPSelector,
                    count,
                    1,
                    structure.baseAddress,
                    structure.count,
                    nil,
                    nil,
                    nil,
                    nil
                )
            }
        }
        try checkIO(status, operation: "writing UCX II DSP registers")
    }

    func triggerDSPRead() throws {
        // Mode 2 requests DSP input without starting TotalMix's level-meter
        // transfers, which this client does not consume.
        var mode: UInt32 = 2
        let status = withUnsafePointer(to: &mode) { pointer in
            IOConnectCallMethod(
                port,
                triggerDSPReadSelector,
                nil,
                0,
                pointer,
                MemoryLayout<UInt32>.size,
                nil,
                nil,
                nil,
                nil
            )
        }
        try checkIO(status, operation: "triggering a UCX II DSP read")
    }

    func readDSP() throws -> [UInt32] {
        var buffer = [UInt32](repeating: 0, count: dspReadWords)
        var outputSize = buffer.count * MemoryLayout<UInt32>.size
        let status = buffer.withUnsafeMutableBytes { output in
            IOConnectCallStructMethod(
                port,
                readDSPSelector,
                nil,
                0,
                output.baseAddress,
                &outputSize
            )
        }
        try checkIO(status, operation: "reading UCX II DSP registers")
        guard outputSize <= buffer.count * MemoryLayout<UInt32>.size,
              outputSize.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw RMEControlError.invalidReadSize(outputSize)
        }
        let count = outputSize / MemoryLayout<UInt32>.size
        let words = buffer.prefix(count)
        return words.allSatisfy { $0 == 0 } ? [] : Array(words)
    }
}

private func checkIO(_ status: kern_return_t, operation: String) throws {
    guard status == KERN_SUCCESS else {
        throw RMEControlError.io(operation: operation, status: status)
    }
}

private struct RMEDevice {
    let service: io_service_t
    let serial: UInt64

    func release() {
        IOObjectRelease(service)
    }
}

private func registryString(service: io_service_t, key: String) throws -> String {
    guard let property = IORegistryEntryCreateCFProperty(
        service,
        key as CFString,
        kCFAllocatorDefault,
        0
    ), let value = property.takeRetainedValue() as? String else {
        throw RMEControlError.missingRegistryProperty(key)
    }
    return value
}

private func registryParentNumber(service: io_service_t, key: String) throws -> UInt64 {
    let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    guard let value = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        key as CFString,
        kCFAllocatorDefault,
        options
    ) as? NSNumber else {
        throw RMEControlError.missingRegistryProperty(key)
    }
    return value.uint64Value
}

private func selectUCXII(serial wantedSerial: UInt64?) throws -> RMEDevice {
    guard let matching = IOServiceNameMatching(rmeDriverClass) else {
        throw RMEControlError.noDevice(serial: wantedSerial)
    }
    var iterator: io_iterator_t = 0
    try checkIO(
        IOServiceGetMatchingServices(0, matching, &iterator),
        operation: "enumerating RME DriverKit services"
    )
    defer { IOObjectRelease(iterator) }

    var matches: [RMEDevice] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        do {
            let vendorID = try registryParentNumber(service: service, key: "idVendor")
            let productID = try registryParentNumber(service: service, key: "idProduct")
            guard vendorID == UCXIIDeviceIdentity.vendor, productID == UCXIIDeviceIdentity.product else {
                IOObjectRelease(service)
                continue
            }
            let uid = try registryString(service: service, key: "device UID")
            guard let suffix = uid.split(separator: "-").last,
                  let serial = UInt64(suffix) else {
                throw RMEControlError.malformedDeviceUID(uid)
            }
            if wantedSerial == nil || serial == wantedSerial {
                matches.append(RMEDevice(service: service, serial: serial))
            } else {
                IOObjectRelease(service)
            }
        } catch {
            IOObjectRelease(service)
            matches.forEach { $0.release() }
            throw error
        }
    }
    guard !matches.isEmpty else { throw RMEControlError.noDevice(serial: wantedSerial) }
    guard matches.count == 1 else {
        matches.forEach { $0.release() }
        throw RMEControlError.multipleDevices
    }
    return matches[0]
}

/// Owns the single serialized RME DriverKit user client used by the app.
/// No two DSP reads or writes can overlap because all access is actor-isolated.
public actor UCXIIController {
    private var connection: (any UCXIIDSPTransport)?
    private var serial: UInt64?
    private var pollSequence: UInt8 = 0
    private var readArmed = false
    private var identityValidated = false
    private var accumulator = UCXIIStateAccumulator()
    private var generation: UInt64 = 0
    private var refreshBusy = false
    private var nextArm: TimeInterval = 0
    private var writeSequence: UInt64 = 0
    private struct PendingControl: Equatable {
        let value: Int16
        let sequence: UInt64
    }
    private var pendingControls: [UInt16: PendingControl] = [:]

    public init() {}

    // Inject the same DSP boundary used by DriverKit for hardware-free tests.
    init(connection: any UCXIIDSPTransport, serial: UInt64) {
        self.connection = connection
        self.serial = serial
    }

    public var isConnected: Bool { connection != nil }

    @discardableResult
    public func connect(serial wantedSerial: UInt64? = nil) async throws -> UCXIIState {
        disconnect()
        let device = try selectUCXII(serial: wantedSerial)
        defer { device.release() }
        var port: io_connect_t = 0
        try checkIO(
            IOServiceOpen(device.service, mach_task_self_, 0, &port),
            operation: "opening the RME driver user client"
        )
        connection = TimedDSPTransport(RMEConnection(port: port))
        serial = device.serial
        pollSequence = 0
        readArmed = false
        identityValidated = false
        accumulator = UCXIIStateAccumulator()
        let session = generation
        do {
            return try await refreshState(timeout: 2.0, drainFirst: true)
        } catch {
            if generation == session { disconnect() }
            throw error
        }
    }

    public func disconnect() {
        generation &+= 1
        refreshBusy = false
        nextArm = 0
        pendingControls.removeAll()
        connection = nil
        serial = nil
        readArmed = false
        identityValidated = false
        pollSequence = 0
        accumulator = UCXIIStateAccumulator()
    }

    public func currentState() -> UCXIIState? {
        guard let serial else { return nil }
        return accumulator.state(serial: serial)
    }

    /// Reads at most one completed frame. Idle USB waits never occupy the actor.
    public func poll() throws -> UCXIIState? {
        guard !refreshBusy else { return nil }
        let connection = try requireConnection()
        try armRead(connection)
        let words = try connection.readDSP()
        guard !words.isEmpty else { return nil }
        readArmed = false
        try acknowledge(connection)
        guard accumulator.update(words: words) else { return nil }
        try validateConfiguration(accumulator)
        return presentedState()
    }

    /// Desired control values are presented immediately but never stored as
    /// observed device state. A later fresh snapshot reconciles them.
    private func presentedState() -> UCXIIState? {
        guard let serial else { return nil }
        var presentation = accumulator
        for (register, pending) in pendingControls {
            presentation.values[register] = pending.value
        }
        return presentation.state(serial: serial)
    }

    public func refreshState(timeout: TimeInterval = 2.0, drainFirst: Bool = true) async throws -> UCXIIState {
        let pendingAtStart = pendingControls
        let refreshed = try await refreshRegisters(timeout: timeout, drainFirst: drainFirst)
        guard let serial, refreshed.state(serial: serial) != nil else {
            throw RMEControlError.snapshotTimedOut(missingRegisters: refreshed.missingRegisters)
        }
        accumulator = refreshed
        for (register, pending) in pendingAtStart where pendingControls[register] == pending {
            if refreshed.values[register] != pending.value {
                RMETiming.log.error("control.readback-mismatch register=\(register) expected=\(pending.value) actual=\(refreshed.values[register] ?? -9999)")
            }
            pendingControls.removeValue(forKey: register)
        }
        return presentedState()!
    }

    private func refreshRegisters(
        timeout: TimeInterval, drainFirst: Bool
    ) async throws -> UCXIIStateAccumulator {
        let session = generation
        while refreshBusy {
            try await Task.sleep(for: .milliseconds(5))
            guard generation == session else { throw RMEControlError.notConnected }
        }
        refreshBusy = true
        defer { if generation == session { refreshBusy = false } }
        let operationStart = ProcessInfo.processInfo.systemUptime
        var frames = 0
        var requests = 1
        var succeeded = false
        defer {
            RMETiming.record("refresh", since: operationStart, slowThreshold: timeout,
                detail: "frames=\(frames) requests=\(requests) success=\(succeeded)")
        }
        let connection = try requireConnection()
        if drainFirst { try drain(connection) }
        var refreshed = UCXIIStateAccumulator()
        try armRead(connection)
        try connection.writeDSP([
            RMEWordCodec.encodeWrite(register: RMERegisterMap.refresh, value: RMERegisterMap.refreshValue),
        ])

        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + timeout
        var nextRequest = started + snapshotRetryInterval
        var seen: Set<UInt16> = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            try armRead(connection)
            if ProcessInfo.processInfo.systemUptime >= nextRequest {
                // A stalled transfer can lose the first snapshot packet while
                // the driver recovers. Request it again within the same timeout.
                try connection.writeDSP([
                    RMEWordCodec.encodeWrite(register: RMERegisterMap.refresh, value: RMERegisterMap.refreshValue),
                ])
                nextRequest = ProcessInfo.processInfo.systemUptime + snapshotRetryInterval
                requests += 1
            }
            guard let words = try await waitForRead(connection, deadline: min(deadline, nextRequest)) else { continue }
            frames += 1
            // As in the Rust session, extend only when new register addresses
            // arrive. Repeated unsolicited updates must not suppress retries.
            let previousCount = seen.count
            for word in words where word != 0 && !word.nonzeroBitCount.isMultiple(of: 2) {
                seen.insert(RMEWordCodec.decode(word).register)
            }
            if seen.count > previousCount {
                nextRequest = ProcessInfo.processInfo.systemUptime + snapshotRetryInterval
            }
            _ = accumulator.update(words: words)
            _ = refreshed.update(words: words)
            try validateConfiguration(refreshed)
            if refreshed.missingRegisters.isEmpty {
                succeeded = true
                return refreshed
            }
        }
        throw RMEControlError.snapshotTimedOut(missingRegisters: refreshed.missingRegisters)
    }

    public func setMicLine1Gain(dbTenths: Int16) throws -> UCXIIState? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { RMETiming.record("mic.submit", since: start, detail: "target=\(dbTenths)") }
        guard currentState() != nil else { throw RMEControlError.notConnected }
        let value = min(
            max(dbTenths, RMERegisterMap.minimumMicGainDBTenths),
            RMERegisterMap.maximumMicGainDBTenths
        )
        try write([(RMERegisterMap.micLine1Gain, value)])
        // Present the submitted value immediately; reconciliation is exclusively
        // background work. No input action waits for a device snapshot.
        rememberSubmitted([(RMERegisterMap.micLine1Gain, value)])
        return presentedState()
    }

    public func setVolume(dbTenths: Int16, output: RMEOutput) throws -> UCXIIState? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { RMETiming.record("volume.submit", since: start, detail: "output=\(output.rawValue) target=\(dbTenths)") }
        let value = min(max(dbTenths, RMERegisterMap.minimumDBTenths), output.maximumDBTenths)
        guard let state = currentState() else { throw RMEControlError.notConnected }
        let registers = try RMERegisterMap.volumeRegisters(for: output, mainPair: state.mainOutputPair)
        try write([(registers.0, value), (registers.1, value)])
        rememberSubmitted([(registers.0, value), (registers.1, value)])
        return presentedState()
    }

    private func rememberSubmitted(_ values: [(UInt16, Int16)]) {
        writeSequence &+= 1
        for (register, value) in values {
            pendingControls[register] = PendingControl(value: value, sequence: writeSequence)
        }
    }

    private func validateConfiguration(_ state: UCXIIStateAccumulator) throws {
        if let mode = state.values[RMERegisterMap.classCompliantMode], mode != 0 {
            throw RMEControlError.unsupportedDeviceMode(mode)
        }
        if let pair = state.values[RMERegisterMap.controlRoomMain], !(0..<10).contains(pair) {
            throw RMEControlError.invalidMainAssignment(pair)
        }
    }

    private func write(_ values: [(UInt16, Int16)]) throws {
        let connection = try requireConnection()
        try connection.writeDSP(values.map { RMEWordCodec.encodeWrite(register: $0.0, value: $0.1) })
    }

    private func requireConnection() throws -> any UCXIIDSPTransport {
        guard let connection else { throw RMEControlError.notConnected }
        if !identityValidated {
            guard let serial else { throw RMEControlError.notConnected }
            try connection.identify().validate(expectedSerial: serial)
            identityValidated = true
        }
        return connection
    }

    private func drain(_ connection: any UCXIIDSPTransport) throws {
        let start = ProcessInfo.processInfo.systemUptime
        var frames = 0
        defer { RMETiming.record("drain", since: start, detail: "frames=\(frames)") }
        for _ in 0..<64 {
            if try connection.readDSP().isEmpty {
                readArmed = false
                return
            }
            try acknowledge(connection)
            frames += 1
        }
        throw RMEControlError.dspQueueNotDrained
    }

    private func armRead(_ connection: any UCXIIDSPTransport) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard !readArmed || now >= nextArm else { return }
        try connection.triggerDSPRead()
        readArmed = true
        nextArm = now + dspReadRetryInterval
    }

    private func acknowledge(_ connection: any UCXIIDSPTransport) throws {
        try connection.writeDSP([
            RMEWordCodec.encodeWrite(register: RMERegisterMap.poll, value: Int16(pollSequence)),
        ])
        pollSequence = (pollSequence &+ 1) & 0x0f
    }

    private func waitForRead(_ connection: any UCXIIDSPTransport, deadline: TimeInterval) async throws -> [UInt32]? {
        let session = generation
        let start = ProcessInfo.processInfo.systemUptime
        var emptyReads = 0
        var rearms = 0
        defer { RMETiming.record("read.wait", since: start, slowThreshold: snapshotRetryInterval,
                                detail: "empty=\(emptyReads) rearms=\(rearms)") }
        var nextTrigger = ProcessInfo.processInfo.systemUptime + dspReadRetryInterval
        while ProcessInfo.processInfo.systemUptime < deadline {
            let words = try connection.readDSP()
            if !words.isEmpty {
                readArmed = false
                try acknowledge(connection)
                return words
            }
            if ProcessInfo.processInfo.systemUptime >= nextTrigger {
                // The driver's asynchronous USB read can time out or stall.
                // Trigger again so it can clear the stall and arm a new read.
                try connection.triggerDSPRead()
                nextTrigger = ProcessInfo.processInfo.systemUptime + dspReadRetryInterval
                rearms += 1
            }
            emptyReads += 1
            try await Task.sleep(for: .milliseconds(5))
            guard generation == session else { throw RMEControlError.notConnected }
        }
        return nil
    }
}
