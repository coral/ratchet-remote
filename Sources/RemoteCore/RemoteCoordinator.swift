import AppKit
import Foundation
import Observation
import RatchetProtocol
import RMEControl

struct HapticTransitionGate: Sendable {
    private(set) var pendingChanges = 0

    var blocksKnobInput: Bool { pendingChanges > 0 }

    mutating func begin() {
        pendingChanges += 1
    }

    mutating func complete() {
        guard pendingChanges > 0 else { return }
        pendingChanges -= 1
    }

    mutating func cancelNewest() {
        complete()
    }

    mutating func reset() {
        pendingChanges = 0
    }
}

@MainActor
@Observable
public final class RemoteCoordinator {
    public private(set) var viewState: RemoteViewState

    @ObservationIgnored private let transport: RatchetHIDTransport
    @ObservationIgnored private let rme: UCXIIController
    @ObservationIgnored private let diagnosticLogging: Bool
    @ObservationIgnored private var session: RatchetSession?
    @ObservationIgnored private var presentation = RatchetPresentationBuilder()
    @ObservationIgnored private var ratchetReady = false
    @ObservationIgnored private var configuredRMEState = false
    @ObservationIgnored private var hapticTransitions = HapticTransitionGate()
    @ObservationIgnored private var pressedMask: UInt32 = 0
    @ObservationIgnored private var mappers: [OutputRole: KnobVolumeMapper] = [
        .main: KnobVolumeMapper(tenthsPerDetent: 10),
        .phones: KnobVolumeMapper(tenthsPerDetent: 5),
    ]
    @ObservationIgnored private var volumeWrites = VolumeWriteCoalescer()
    @ObservationIgnored private var outputMuteTransitions: Set<RMEOutput> = []
    @ObservationIgnored private var restoreVolumes: [RMEOutput: Int16] = [:]
    @ObservationIgnored private var micMuteTransition = false
    @ObservationIgnored private var restoreMicGain: Int16?
    @ObservationIgnored private var volumeWriterTask: Task<Void, Never>?
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var rmeTask: Task<Void, Never>?
    @ObservationIgnored private var ratchetReconnectTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastInteractionAt = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var presentationBrightness = ActivityBrightness.active

    private static let selectedRoleDefaultsKey = "selectedOutputRole"
    private static let fallbackRestoreDBTenths: Int16 = -300
    private static let micRestoreGainDefaultsKey = "restoreMicLine1GainDBTenths"
    private static let fallbackMicRestoreGainDBTenths: Int16 = 580

    public init(
        transport: RatchetHIDTransport? = nil,
        rme: UCXIIController = UCXIIController(),
        diagnosticLogging: Bool = false
    ) {
        let saved = UserDefaults.standard.string(forKey: Self.selectedRoleDefaultsKey)
        let role = saved.flatMap(OutputRole.init(rawValue:)) ?? .main
        viewState = RemoteViewState(selectedRole: role)
        self.transport = transport ?? RatchetHIDTransport()
        self.rme = rme
        self.diagnosticLogging = diagnosticLogging
        for output in RMEOutput.allCases {
            let key = Self.restoreVolumeDefaultsKey(output)
            guard let saved = UserDefaults.standard.object(forKey: key) as? NSNumber else { continue }
            let value = Int16(clamping: saved.intValue)
            if value > RMERegisterMap.minimumDBTenths, value <= output.maximumDBTenths {
                restoreVolumes[output] = value
            }
        }
        if let saved = UserDefaults.standard.object(forKey: Self.micRestoreGainDefaultsKey) as? NSNumber {
            let value = Int16(clamping: saved.intValue)
            if value > RMERegisterMap.minimumMicGainDBTenths,
               value <= RMERegisterMap.maximumMicGainDBTenths {
                restoreMicGain = value
            }
        }
        viewState.mutedRestoreVolumes = restoreVolumes
    }

    public func start() {
        guard !started else { return }
        started = true
        lastInteractionAt = now
        presentationBrightness = ActivityBrightness.active
        transport.start()

        transportTask = Task { [weak self, events = transport.events] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.handleTransportEvent(event)
            }
        }
        sessionTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self.tickSession()
            }
        }
        rmeTask = Task { [weak self] in
            await self?.runRMEConnection()
        }
    }

    public func reconnect() async {
        recordInteraction()
        ratchetReconnectTask?.cancel()
        ratchetReconnectTask = nil
        await rme.disconnect()
        markRMEOffline(error: nil)
        transport.stop()
        session = nil
        ratchetReady = false
        configuredRMEState = false
        viewState.ratchetConnected = false
        viewState.ratchetConfigured = false
        viewState.ratchetSerial = nil
        transport.start()
    }

    public func setSelectedRole(_ role: OutputRole) {
        recordInteraction()
        guard role != viewState.selectedRole else { return }
        viewState.selectedRole = role
        UserDefaults.standard.set(role.rawValue, forKey: Self.selectedRoleDefaultsKey)
        mappers[role]?.resetBaseline()
        if ratchetReady {
            do {
                try sendHaptics(enabled: viewState.rmeConnected, role: role)
            } catch {
                report(error)
            }
        }
        synchronizeRatchetPresentation(displayRefresh: .role)
    }

    public func toggleMicLine1Mute() async {
        recordInteraction()
        guard !micMuteTransition, let state = viewState.rmeState else { return }
        micMuteTransition = true
        defer { micMuteTransition = false }

        let target: Int16
        if state.micLine1Muted {
            target = restoreMicGain ?? Self.fallbackMicRestoreGainDBTenths
            diagnostic("Unmuting Mic/Line 1: restoring \(Double(target) / 10.0) dB gain")
        } else {
            rememberMicRestoreGain(state.micLine1GainDBTenths)
            target = RMERegisterMap.minimumMicGainDBTenths
            diagnostic(
                "Muting Mic/Line 1: saving \(Double(state.micLine1GainDBTenths) / 10.0) dB gain and writing 0.0 dB"
            )
        }

        do {
            applyRMEState(try await rme.setMicLine1Gain(dbTenths: target))
        } catch {
            await handleRMEOperationFailure(error)
        }
    }

    public func toggleMute(_ output: RMEOutput) async {
        recordInteraction()
        guard viewState.rmeState != nil,
              outputMuteTransitions.insert(output).inserted else { return }
        defer { outputMuteTransitions.remove(output) }

        let role: OutputRole = output == .main ? .main : .phones
        volumeWrites.discardPending(role)
        while volumeWrites.isBusy(role) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        guard let current = viewState.rmeState?[output] else { return }
        let target: Int16
        if current.isAtFloor {
            target = restoreVolumes[output]
                ?? min(Self.fallbackRestoreDBTenths, output.maximumDBTenths)
            diagnostic("Unmuting \(output.label): restoring \(Double(target) / 10.0) dB")
        } else {
            rememberRestoreVolume(current.dbTenths, for: output)
            target = RMERegisterMap.minimumDBTenths
            diagnostic("Muting \(output.label): saving \(Double(current.dbTenths) / 10.0) dB and writing -INF")
        }

        do {
            applyRMEState(try await rme.setVolume(dbTenths: target, output: output))
            mappers[role]?.resetBaseline()
        } catch {
            await handleRMEOperationFailure(error)
        }
    }

    public func shutdown() async {
        guard started else { return }
        if ratchetReady {
            if var session {
                session.discardPendingMutations()
                self.session = session
            }
            var disable = Ratchet_V1_DisableOutputs()
            disable.reason = "Ratchet Remote is quitting"
            try? send(.disableOutputs(disable))
            let deadline = now + 0.5
            while ratchetReady, now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        started = false
        ratchetReconnectTask?.cancel()
        transportTask?.cancel()
        sessionTask?.cancel()
        rmeTask?.cancel()
        volumeWriterTask?.cancel()
        transport.stop()
        await rme.disconnect()
    }

    private func handleTransportEvent(_ event: RatchetTransportEvent) {
        switch event {
        case .connected(let serial):
            session = RatchetSession(now: now)
            ratchetReady = false
            configuredRMEState = false
            hapticTransitions.reset()
            viewState.ratchetConnected = true
            viewState.ratchetConfigured = false
            viewState.ratchetSerial = serial
            viewState.ratchetError = nil
            diagnostic("Ratchet HID connected: \(serial ?? "unknown serial")")
        case .disconnected:
            session = nil
            ratchetReady = false
            configuredRMEState = false
            hapticTransitions.reset()
            viewState.ratchetConnected = false
            viewState.ratchetConfigured = false
            viewState.ratchetSerial = nil
        case .report(let report):
            processRatchetReport(report)
        case .error(let message):
            recoverRatchet(after: message)
        }
    }

    private func processRatchetReport(_ report: Data) {
        do {
            guard var session else { return }
            let update: SessionUpdate
            do {
                update = try session.pushDeviceRead(report, now: now)
            } catch {
                // RatchetSession deliberately clears a rejected mutation before
                // throwing. Preserve that value-semantic state so the timer
                // cannot retry bytes the device has already rejected.
                self.session = session
                throw error
            }
            self.session = session
            try transmit(update.outbound)

            if update.hello != nil,
               case .hello(let hello)? = update.message?.event {
                try hello.validateForRemote()
                ratchetReady = false
                viewState.ratchetConfigured = false
                var configureSession = self.session
                let reports: [Data]
                if configureSession?.hasPendingMutation(.configure) == true {
                    reports = []
                } else {
                    configuredRMEState = viewState.rmeConnected
                    reports = try configureSession?.send(
                        .configure(presentation.configuration(
                            viewState: viewState,
                            brightness: presentationBrightness
                        )),
                        now: now
                    ) ?? []
                }
                self.session = configureSession
                try transmit(reports)
            }
            if let completion = update.completion {
                if completion.kind == .configure {
                    ratchetReady = true
                    viewState.ratchetConfigured = true
                    viewState.ratchetError = nil
                    diagnostic("Ratchet configuration Ready: command \(completion.sequence)")
                    if configuredRMEState != viewState.rmeConnected {
                        try sendHaptics(
                            enabled: viewState.rmeConnected,
                            role: viewState.selectedRole
                        )
                    } else {
                        hapticTransitions.reset()
                        mappers[viewState.selectedRole]?.resetBaseline()
                    }
                    synchronizeRatchetPresentation(displayRefresh: .full)
                }
                if completion.kind == .setHaptics {
                    hapticTransitions.complete()
                    mappers[viewState.selectedRole]?.resetBaseline()
                    synchronizeRatchetPresentation(displayRefresh: .role)
                }
            }
            if update.authorityLost {
                ratchetReady = false
                viewState.ratchetConfigured = false
                configuredRMEState = false
                hapticTransitions.reset()
            }
            if case .fault(let fault)? = update.message?.event {
                viewState.ratchetError = "Ratchet fault: \(fault.detail)"
                diagnostic("Ratchet fault: \(fault.detail)")
            }
            if case .input(let input)? = update.message?.event {
                handleInput(input)
            }
        } catch {
            handleRatchetProcessingError(error)
        }
    }

    private func handleInput(_ input: Ratchet_V1_InputEvent) {
        if RatchetInputActivity.shouldWake(for: input) {
            recordInteraction()
        }
        switch input.input {
        case .button(let button):
            pressedMask = button.pressedMask
            diagnostic("Button \(button.index) \(button.edge == .pressed ? "pressed" : "released"), mask=0x\(String(button.pressedMask, radix: 16))")
            guard button.edge == .pressed else { return }
            switch button.index {
            case 0: Task { await toggleMicLine1Mute() }
            case 1:
                setSelectedRole(.phones)
                Task { await toggleMute(.phones) }
            case 2:
                setSelectedRole(.main)
                Task { await toggleMute(.main) }
            case 3: setSelectedRole(viewState.selectedRole.alternate)
            default: break
            }
        case .knob(let knob):
            handleKnob(knob)
        case .none:
            break
        }
    }

    private func handleKnob(_ knob: Ratchet_V1_KnobEvent) {
        guard !hapticTransitions.blocksKnobInput,
              let output = viewState.selectedOutput,
              !output.isAtFloor,
              !outputMuteTransitions.contains(viewState.selectedRole.rmeOutput),
              var mapper = mappers[viewState.selectedRole] else {
            mappers[viewState.selectedRole]?.resetBaseline()
            return
        }
        let requested = mapper.consume(
            position: knob.position,
            reportedDelta: knob.delta,
            authoritativeDBTenths: output.dbTenths,
            maximumDBTenths: viewState.selectedRole.maximumDBTenths
        )
        mappers[viewState.selectedRole] = mapper
        guard let requested else { return }
        guard volumeWrites.enqueue(requested, for: viewState.selectedRole) else { return }
        diagnostic("Knob \(viewState.selectedRole.label): requesting \(Double(requested) / 10.0) dB")
        startVolumeWriterIfNeeded()
    }

    private func startVolumeWriterIfNeeded() {
        guard volumeWriterTask == nil else { return }
        volumeWriterTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let request = self.volumeWrites.beginNext() {
                do {
                    let state = try await self.rme.setVolume(
                        dbTenths: request.value,
                        output: request.role.rmeOutput
                    )
                    self.applyRMEState(state)
                    self.volumeWrites.finish(request.role)
                    // Limit DriverKit writes to 50 Hz and give newer HID samples
                    // a chance to replace the unsent target.
                    if !self.volumeWrites.isEmpty {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                } catch {
                    self.volumeWrites.finish(request.role)
                    await self.handleRMEOperationFailure(error)
                    break
                }
            }
            self.volumeWriterTask = nil
            self.reconcileVolumeMappers()
            if !self.volumeWrites.isEmpty { self.startVolumeWriterIfNeeded() }
        }
    }

    private func tickSession() {
        let tickTime = now
        updateBrightness(at: tickTime)
        guard var session else { return }
        do {
            let reports = try session.tick(
                now: tickTime,
                hostMicros: UInt64(max(tickTime, 0) * 1_000_000)
            )
            self.session = session
            try transmit(reports)
        } catch {
            self.session = session
            if case RatchetSessionError.retryExhausted = error {
                recoverRatchet(after: error.localizedDescription)
            } else {
                handleRatchetProcessingError(error)
            }
        }
    }

    private func runRMEConnection() async {
        var nextRefresh = 0.0
        while !Task.isCancelled {
            do {
                if !viewState.rmeConnected {
                    let state = try await rme.connect()
                    applyRMEState(state)
                    nextRefresh = now + 2.0
                    if ratchetReady {
                        try sendHaptics(enabled: true, role: viewState.selectedRole)
                    }
                } else if now >= nextRefresh {
                    let state = try await rme.refreshState(timeout: 2.0)
                    applyRMEState(state)
                    nextRefresh = now + 2.0
                } else if let state = try await rme.poll() {
                    applyRMEState(state)
                }
            } catch {
                await rme.disconnect()
                markRMEOffline(error: error)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func applyRMEState(_ state: UCXIIState?) {
        guard let state else { return }
        let wasConnected = viewState.rmeConnected
        let previousState = viewState.rmeState
        if !state.micLine1Muted {
            rememberMicRestoreGain(state.micLine1GainDBTenths)
        }
        for output in RMEOutput.allCases {
            if state[output].isAtFloor, restoreVolumes[output] == nil {
                rememberRestoreVolume(
                    min(Self.fallbackRestoreDBTenths, output.maximumDBTenths),
                    for: output
                )
            } else if !state[output].isAtFloor {
                rememberRestoreVolume(state[output].dbTenths, for: output)
            }
        }
        let changed = viewState.rmeState != state || !viewState.rmeConnected
        viewState.rmeConnected = true
        viewState.rmeState = state
        viewState.rmeError = nil
        if !volumeWrites.isBusy(.main) {
            mappers[.main]?.replaceAuthoritativeVolume(state.main.dbTenths)
        }
        if !volumeWrites.isBusy(.phones) {
            mappers[.phones]?.replaceAuthoritativeVolume(state.phones.dbTenths)
        }
        if changed {
            let selectedOutputChanged = previousState?[viewState.selectedRole.rmeOutput]
                != state[viewState.selectedRole.rmeOutput]
            let displayRefresh: DisplayRefresh = !wasConnected
                ? .full
                : selectedOutputChanged ? .volume : .none
            synchronizeRatchetPresentation(displayRefresh: displayRefresh)
        }
        if changed {
            diagnostic(
                "RME state: Main \(format(state.main)), Phones \(format(state.phones)), Mic/Line 1 \(formatMic(state))"
            )
        }
    }

    private func markRMEOffline(error: Error?) {
        let wasOnline = viewState.rmeConnected
        viewState.rmeConnected = false
        viewState.rmeState = nil
        volumeWrites.removeAll()
        mappers[.main]?.resetBaseline()
        mappers[.phones]?.resetBaseline()
        if let error { viewState.rmeError = error.localizedDescription }
        guard ratchetReady, wasOnline else { return }
        do {
            try sendHaptics(enabled: false, role: viewState.selectedRole)
            synchronizeRatchetPresentation(displayRefresh: .full)
        } catch {
            report(error)
        }
    }

    private func handleRMEOperationFailure(_ error: Error) async {
        await rme.disconnect()
        markRMEOffline(error: error)
    }

    private func reconcileVolumeMappers() {
        guard let state = viewState.rmeState else { return }
        if !volumeWrites.isBusy(.main) {
            mappers[.main]?.replaceAuthoritativeVolume(state.main.dbTenths)
        }
        if !volumeWrites.isBusy(.phones) {
            mappers[.phones]?.replaceAuthoritativeVolume(state.phones.dbTenths)
        }
    }

    private enum DisplayRefresh: Equatable {
        case none
        case volume
        case role
        case full
    }

    private func synchronizeRatchetPresentation(displayRefresh: DisplayRefresh) {
        guard ratchetReady else { return }
        do {
            try send(.ledFrame(presentation.ledFrame(
                viewState: viewState,
                brightness: presentationBrightness
            )))
            if displayRefresh != .none {
                try send(.displayFrame(presentation.displayFrame(
                    viewState: viewState,
                    full: displayRefresh == .full,
                    includeRole: displayRefresh != .volume,
                    brightness: presentationBrightness
                )))
            }
        } catch {
            report(error)
        }
    }

    private func recordInteraction() {
        lastInteractionAt = now
        guard presentationBrightness != ActivityBrightness.active else { return }
        presentationBrightness = ActivityBrightness.active
        synchronizeBrightness()
    }

    private func updateBrightness(at time: TimeInterval) {
        let brightness = ActivityBrightness.level(
            elapsedSinceInteraction: max(time - lastInteractionAt, 0)
        )
        guard brightness != presentationBrightness else { return }
        presentationBrightness = brightness
        synchronizeBrightness()
    }

    private func synchronizeBrightness() {
        guard ratchetReady else { return }
        do {
            try send(.ledFrame(presentation.ledFrame(
                viewState: viewState,
                brightness: presentationBrightness
            )))
            try send(.displayFrame(presentation.displayBrightnessFrame(
                brightness: presentationBrightness
            )))
        } catch {
            report(error)
        }
    }

    private func send(_ command: Ratchet_V1_HostToDevice.OneOf_Command) throws {
        guard var session else { return }
        let reports = try session.send(command, now: now)
        self.session = session
        try transmit(reports)
    }

    private func sendHaptics(enabled: Bool, role: OutputRole) throws {
        hapticTransitions.begin()
        do {
            try send(.setHaptics(presentation.hapticsCommand(
                enabled: enabled,
                role: role
            )))
        } catch {
            hapticTransitions.cancelNewest()
            throw error
        }
    }

    private func transmit(_ reports: [Data]) throws {
        for report in reports { try transport.send(report) }
    }

    private func report(_ error: Error) {
        viewState.ratchetError = error.localizedDescription
        diagnostic("Error: \(error.localizedDescription)")
    }

    private func diagnostic(_ message: String) {
        if diagnosticLogging { print(message) }
    }

    private func format(_ output: StereoOutputState) -> String {
        let level = output.isAtFloor ? "-INF" : String(format: "%.1f dB", Double(output.dbTenths) / 10.0)
        return "\(level) \(output.muted ? "muted" : "live")"
    }

    private func rememberRestoreVolume(_ value: Int16, for output: RMEOutput) {
        guard value > RMERegisterMap.minimumDBTenths else { return }
        let clamped = min(value, output.maximumDBTenths)
        guard restoreVolumes[output] != clamped else { return }
        restoreVolumes[output] = clamped
        viewState.mutedRestoreVolumes[output] = clamped
        UserDefaults.standard.set(Int(clamped), forKey: Self.restoreVolumeDefaultsKey(output))
    }

    private func rememberMicRestoreGain(_ value: Int16) {
        guard value > RMERegisterMap.minimumMicGainDBTenths else { return }
        let clamped = min(value, RMERegisterMap.maximumMicGainDBTenths)
        guard restoreMicGain != clamped else { return }
        restoreMicGain = clamped
        UserDefaults.standard.set(Int(clamped), forKey: Self.micRestoreGainDefaultsKey)
    }

    private func formatMic(_ state: UCXIIState) -> String {
        let gain = String(format: "%.1f dB", Double(state.micLine1GainDBTenths) / 10.0)
        return "\(gain) \(state.micLine1Muted ? "muted" : "live")"
    }

    private static func restoreVolumeDefaultsKey(_ output: RMEOutput) -> String {
        "restoreVolumeDBTenths.\(output.rawValue)"
    }

    private func handleRatchetProcessingError(_ error: Error) {
        switch error {
        case is RatchetCompatibilityError:
            session = nil
            ratchetReady = false
            viewState.ratchetConfigured = false
            configuredRMEState = false
            hapticTransitions.reset()
            report(error)
        case RatchetSessionError.protocolVersion:
            session = nil
            ratchetReady = false
            viewState.ratchetConfigured = false
            configuredRMEState = false
            hapticTransitions.reset()
            report(error)
        case RatchetSessionError.commandRejected(let kind, _, _, _):
            hapticTransitions.reset()
            if kind == .configure {
                ratchetReady = false
                viewState.ratchetConfigured = false
                configuredRMEState = false
            }
            report(error)
        case RatchetSessionError.queueFull:
            report(error)
        default:
            recoverRatchet(after: error.localizedDescription)
        }
    }

    private func recoverRatchet(after message: String) {
        guard ratchetReconnectTask == nil else {
            viewState.ratchetError = message
            return
        }
        viewState.ratchetError = message
        session = nil
        ratchetReady = false
        configuredRMEState = false
        hapticTransitions.reset()
        viewState.ratchetConnected = false
        viewState.ratchetConfigured = false
        viewState.ratchetSerial = nil
        transport.stop()
        ratchetReconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                self?.ratchetReconnectTask = nil
                return
            }
            guard let self, !Task.isCancelled, self.started else {
                self?.ratchetReconnectTask = nil
                return
            }
            self.ratchetReconnectTask = nil
            self.transport.start()
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
