import RMEControl
import RatchetProtocol
import Testing
@testable import RemoteCore

@Test func oneFullTurnMapsToTenDBAtHalfDBPerDetent() {
    var mapper = KnobVolumeMapper()
    #expect(mapper.consume(position: 0, authoritativeDBTenths: -400, maximumDBTenths: 0) == nil)
    #expect(mapper.consume(position: 20, authoritativeDBTenths: -400, maximumDBTenths: 0) == -300)
}

@Test func mainVolumeMapsToOneDBPerDetent() {
    var mapper = KnobVolumeMapper(tenthsPerDetent: 10)
    #expect(mapper.consume(position: 0, authoritativeDBTenths: -400, maximumDBTenths: 0) == nil)
    #expect(mapper.consume(position: 1, authoritativeDBTenths: -400, maximumDBTenths: 0) == -390)
    #expect(mapper.consume(position: -1, authoritativeDBTenths: -390, maximumDBTenths: 0) == -410)
}

@Test func mapperPreservesTenthsAndClampsRoleMaximum() {
    var mapper = KnobVolumeMapper()
    _ = mapper.consume(position: 0, authoritativeDBTenths: -151, maximumDBTenths: -150)
    #expect(mapper.consume(position: 1, authoritativeDBTenths: -151, maximumDBTenths: -150) == -150)
    #expect(mapper.consume(position: 2, authoritativeDBTenths: -150, maximumDBTenths: -150) == nil)
}

@Test func mapperIgnoresMotionInsideTheCurrentDetent() {
    var mapper = KnobVolumeMapper()
    _ = mapper.consume(position: 10, authoritativeDBTenths: -200, maximumDBTenths: 0)
    #expect(mapper.consume(position: 10, authoritativeDBTenths: -200, maximumDBTenths: 0) == nil)
    #expect(mapper.consume(position: 11, authoritativeDBTenths: -200, maximumDBTenths: 0) == -195)
    #expect(mapper.consume(position: 9, authoritativeDBTenths: -195, maximumDBTenths: 0) == -205)
}

@Test func activityBrightnessHoldsThenFadesLinearlyToIdle() {
    #expect(ActivityBrightness.level(elapsedSinceInteraction: 0) == 80)
    #expect(ActivityBrightness.level(elapsedSinceInteraction: 5) == 80)
    #expect(ActivityBrightness.level(elapsedSinceInteraction: 10) == 43)
    #expect(ActivityBrightness.level(elapsedSinceInteraction: 15) == 5)
    #expect(ActivityBrightness.level(elapsedSinceInteraction: 30) == 5)
}

@Test func presentationUsesOneBrightnessForLEDsAndDisplay() throws {
    let view = RemoteViewState(selectedRole: .main)
    var builder = RatchetPresentationBuilder()
    let configuration = builder.configuration(viewState: view, brightness: 73)
    #expect(configuration.leds.brightness == 73)

    let backlights = configuration.display.operations.compactMap { operation -> UInt32? in
        guard case .setBacklight(let backlight)? = operation.operation else { return nil }
        return backlight.brightness
    }
    #expect(backlights == [73])

    let brightnessOnly = builder.displayBrightnessFrame(brightness: 41)
    #expect(brightnessOnly.operations.count == 1)
    let operation = try #require(brightnessOnly.operations.first)
    guard case .setBacklight(let backlight)? = operation.operation else {
        Issue.record("Expected a brightness-only display update")
        return
    }
    #expect(backlight.brightness == 41)
}

@Test func presentationShowsMuteOnlyKeysAndBottomMicIndicator() throws {
    var view = RemoteViewState(selectedRole: .main)
    view.rmeConnected = true
    view.rmeState = UCXIIState(
        serial: 1,
        micLine1GainDBTenths: 0,
        main: .init(leftDBTenths: -200, rightDBTenths: -200),
        phones: .init(leftDBTenths: -650, rightDBTenths: -650)
    )
    var builder = RatchetPresentationBuilder()
    let frame = builder.ledFrame(viewState: view)
    #expect(frame.rgb888.count == 204)
    func pixel(_ index: Int) -> [UInt8] {
        let offset = index * 3
        return Array(frame.rgb888[offset..<(offset + 3)])
    }

    // The three bottom ring LEDs are red only because Mic 1 is muted.
    #expect(pixel(43) == [0x00, 0x00, 0x00])
    for ringPixel in 44...46 {
        #expect(pixel(ringPixel) == [0xff, 0x00, 0x00])
    }
    #expect(pixel(47) == [0x00, 0x00, 0x00])

    // Buttons 0 and 1 are muted (red); live Button 2 is dark. Each button
    // owns two key pixels after the 60 ring pixels.
    for key in [3, 4, 2, 5] {
        #expect(pixel(60 + key) == [0xff, 0x00, 0x00])
    }
    for key in [1, 6] {
        #expect(pixel(60 + key) == [0x00, 0x00, 0x00])
    }
    for key in [0, 7] {
        #expect(pixel(60 + key) == [0x00, 0x00, 0x00])
    }
}

@Test func mutedOutputUsesSavedLevelRedArcAndLeavesBottomGapDark() {
    var view = RemoteViewState(selectedRole: .phones)
    view.rmeConnected = true
    view.rmeState = UCXIIState(
        serial: 1,
        micLine1GainDBTenths: 580,
        main: .init(leftDBTenths: 0, rightDBTenths: 0),
        phones: .init(leftDBTenths: -650, rightDBTenths: -650)
    )
    view.mutedRestoreVolumes[.phones] = -400
    var builder = RatchetPresentationBuilder()
    let bytes = builder.ledFrame(viewState: view).rgb888
    for pixel in 0..<60 {
        let expected: [UInt8] = (15...35).contains(pixel)
            ? [0xff, 0x00, 0x00]
            : [0x00, 0x00, 0x00]
        #expect(Array(bytes[(pixel * 3)..<(pixel * 3 + 3)]) == expected)
    }
}

@Test func mainRingRunsRightToLeftFromPlus120ThroughMinus120Degrees() {
    var view = RemoteViewState(selectedRole: .main)
    view.rmeConnected = true
    view.rmeState = UCXIIState(
        serial: 1,
        micLine1GainDBTenths: 580,
        main: .init(leftDBTenths: -325, rightDBTenths: -325),
        phones: .init(leftDBTenths: -300, rightDBTenths: -300)
    )

    var builder = RatchetPresentationBuilder()
    let bytes = builder.ledFrame(viewState: view).rgb888
    let white: [UInt8] = [0xff, 0xff, 0xff]
    let black: [UInt8] = [0x00, 0x00, 0x00]

    // Pixel 15 is north. At half level, the lit half runs from the
    // right-hand +120-degree endpoint at pixel 35 back to north.
    for pixel in 0..<60 {
        let expected = (15...35).contains(pixel) ? white : black
        #expect(Array(bytes[(pixel * 3)..<(pixel * 3 + 3)]) == expected)
    }
}

@Test func phonesRingRetainsPurpleRoleColor() {
    var view = RemoteViewState(selectedRole: .phones)
    view.rmeConnected = true
    view.rmeState = UCXIIState(
        serial: 1,
        micLine1GainDBTenths: 580,
        main: .init(leftDBTenths: -200, rightDBTenths: -200),
        phones: .init(leftDBTenths: -150, rightDBTenths: -150)
    )

    var builder = RatchetPresentationBuilder()
    let bytes = builder.ledFrame(viewState: view).rgb888
    for pixel in 0...35 {
        #expect(Array(bytes[(pixel * 3)..<(pixel * 3 + 3)]) == [0xa8, 0x55, 0xf7])
    }
    for pixel in 55..<60 {
        #expect(Array(bytes[(pixel * 3)..<(pixel * 3 + 3)]) == [0xa8, 0x55, 0xf7])
    }
    for pixel in [60, 67] {
        #expect(Array(bytes[(pixel * 3)..<(pixel * 3 + 3)]) == [0xa8, 0x55, 0xf7])
    }
}

@Test func hapticProfilesMatchActiveAndSafeDisabledSettings() {
    let main = RatchetPresentationBuilder.haptics(enabled: true, role: .main)
    #expect(main.mode == .regular)
    #expect(main.detentsPerTurn == 26)
    #expect(main.vernier == 0)
    #expect(main.detentStrength == 3.5)
    #expect(main.outputRamp == 250)
    #expect(main.maximumTorque == 0.4)

    let phones = RatchetPresentationBuilder.haptics(enabled: true, role: .phones)
    #expect(phones.mode == .regular)
    #expect(phones.detentsPerTurn == 26)
    #expect(phones.detentStrength == 2.5)
    #expect(phones.outputRamp == 200)
    #expect(phones.maximumTorque == 0.35)

    let disabled = RatchetPresentationBuilder.haptics(enabled: false, role: .main)
    #expect(disabled.mode == .disabled)
    #expect(disabled.detentsPerTurn == 60)
    #expect(disabled.vernier == 1)
    #expect(disabled.detentStrength == 0)
    #expect(disabled.maximumTorque == 0)
}

@Test func partialVolumeFrameAvoidsClearAndUnchangedRoleLabel() throws {
    var view = RemoteViewState(selectedRole: .main)
    view.rmeConnected = true
    view.rmeState = UCXIIState(
        serial: 1,
        micLine1GainDBTenths: 580,
        main: .init(leftDBTenths: -200, rightDBTenths: -200),
        phones: .init(leftDBTenths: -300, rightDBTenths: -300)
    )

    var builder = RatchetPresentationBuilder()
    let display = builder.displayFrame(
        viewState: view,
        full: false,
        includeRole: false,
        brightness: 80
    )
    #expect(display.present)
    #expect(display.operations.count == 2)
    #expect(display.operations.contains { operation in
        if case .clear? = operation.operation { true } else { false }
    } == false)
    let rectangles = display.operations.compactMap { operation -> Ratchet_V1_FillRect? in
        guard case .fillRect(let rectangle)? = operation.operation else { return nil }
        return rectangle
    }
    #expect(rectangles.isEmpty)
    let texts = display.operations.compactMap { operation -> Ratchet_V1_Text? in
        guard case .text(let text)? = operation.operation else { return nil }
        return text
    }
    let text = try #require(texts.first)
    #expect(texts.count == 1)
    #expect(text.value == "-20.0")
    #expect(text.opaqueBackground)
}

@Test func partialMutedFrameClearsTheLargerNumericField() throws {
    var view = RemoteViewState(selectedRole: .main)
    view.rmeConnected = true
    view.rmeState = UCXIIState(
        serial: 1,
        micLine1GainDBTenths: 580,
        main: .init(leftDBTenths: -650, rightDBTenths: -650),
        phones: .init(leftDBTenths: -300, rightDBTenths: -300)
    )

    var builder = RatchetPresentationBuilder()
    let display = builder.displayFrame(
        viewState: view,
        full: false,
        includeRole: false,
        brightness: 80
    )
    let rectangles = display.operations.compactMap { operation -> Ratchet_V1_FillRect? in
        guard case .fillRect(let rectangle)? = operation.operation else { return nil }
        return rectangle
    }
    let clearedField = try #require(rectangles.first)
    #expect(rectangles.count == 1)
    #expect(clearedField.x == 8)
    #expect(clearedField.y == 62)
    #expect(clearedField.width == 224)
    #expect(clearedField.height == 60)
    #expect(clearedField.color.rgb888 == RemotePalette.black)
}

@Test func helloCapabilitiesAreValidatedBeforeConfiguration() throws {
    var hello = Ratchet_V1_Hello()
    var capabilities = Ratchet_V1_Capabilities()
    capabilities.ringLedCount = 60
    capabilities.keyLedCount = 8
    capabilities.buttonCount = 4
    capabilities.displayWidth = 240
    capabilities.displayHeight = 240
    capabilities.maxMessageBytes = 4096
    capabilities.hapticModes = [.disabled, .regular]
    hello.capabilities = capabilities
    try hello.validateForRemote()

    hello.capabilities.buttonCount = 3
    #expect(throws: RatchetCompatibilityError.self) {
        try hello.validateForRemote()
    }
}

@Test func displayTextFieldsStayInsidePanelGeometry() {
    var view = RemoteViewState(selectedRole: .main)
    view.rmeConnected = true
    view.rmeState = UCXIIState(
        serial: 1,
        micLine1GainDBTenths: 580,
        main: .init(leftDBTenths: -200, rightDBTenths: -200),
        phones: .init(leftDBTenths: -300, rightDBTenths: -300)
    )
    var builder = RatchetPresentationBuilder()
    let display = builder.configuration(viewState: view).display
    var textCount = 0
    for operation in display.operations {
        guard case .text(let text)? = operation.operation else { continue }
        textCount += 1
        #expect(text.x >= 0)
        #expect(Int(text.x) + Int(text.maxWidth) <= 240)
    }
    #expect(textCount == 2)
}

@Test func mutedSelectedOutputDrawsMutedInRed() throws {
    var view = RemoteViewState(selectedRole: .phones)
    view.rmeConnected = true
    view.rmeState = UCXIIState(
        serial: 1,
        micLine1GainDBTenths: 580,
        main: .init(leftDBTenths: -200, rightDBTenths: -200),
        phones: .init(leftDBTenths: -650, rightDBTenths: -650)
    )

    #expect(view.selectedOutputMuted)
    #expect(view.volumeText == "MUTED")

    var builder = RatchetPresentationBuilder()
    let display = builder.displayFrame(viewState: view, full: true)
    let texts = display.operations.compactMap { operation -> Ratchet_V1_Text? in
        guard case .text(let text)? = operation.operation else { return nil }
        return text
    }
    let primary = try #require(texts.first)
    #expect(primary.value == "MUTED")
    #expect(primary.foreground.rgb888 == RemotePalette.red)
    #expect(primary.scale == 2)
    #expect(primary.y == 72)
}

@Test func encoderNoiseDoesNotKeepTheDeviceAwake() {
    var noise = Ratchet_V1_KnobEvent()
    noise.position = 12
    noise.delta = 0
    noise.angleRadians = 0.001
    noise.velocityRadiansPerSecond = 0.01
    var noiseInput = Ratchet_V1_InputEvent()
    noiseInput.input = .knob(noise)
    #expect(!RatchetInputActivity.shouldWake(for: noiseInput))

    var movement = noise
    movement.position = 13
    movement.delta = 1
    var movementInput = Ratchet_V1_InputEvent()
    movementInput.input = .knob(movement)
    #expect(RatchetInputActivity.shouldWake(for: movementInput))
}

@Test func statusDistinguishesOpenHIDFromReadyConfiguration() {
    var state = RemoteViewState()
    state.ratchetConnected = true
    state.rmeConnected = true
    #expect(state.statusSummary == "Configuring Ratchet")
    state.ratchetConfigured = true
    #expect(state.statusSummary == "Connected")
}

@Test func rapidVolumeTargetsCoalesceWithoutReordering() {
    var writes = VolumeWriteCoalescer()
    let acceptedInitial = writes.enqueue(-137, for: .main)
    let initial = writes.beginNext()
    #expect(acceptedInitial)
    #expect(initial?.value == -137)

    let acceptedIntermediate = writes.enqueue(-150, for: .main)
    let acceptedLatest = writes.enqueue(-183, for: .main)
    #expect(acceptedIntermediate)
    #expect(acceptedLatest)
    writes.finish(.main)
    let coalesced = writes.beginNext()
    #expect(coalesced?.value == -183)

    let acceptedAfterCompletion = writes.enqueue(-184, for: .main)
    #expect(acceptedAfterCompletion)
    let returnedToInFlight = writes.enqueue(-183, for: .main)
    #expect(!returnedToInFlight)
    writes.finish(.main)
    #expect(writes.isEmpty)

    let acceptedFinal = writes.enqueue(-184, for: .main)
    let final = writes.beginNext()
    #expect(acceptedFinal)
    #expect(final?.value == -184)
}

@Test func muteCanDiscardAnUnsentKnobTarget() {
    var writes = VolumeWriteCoalescer()
    let accepted = writes.enqueue(-200, for: .main)
    #expect(accepted)
    writes.discardPending(.main)
    #expect(writes.isEmpty)
}
