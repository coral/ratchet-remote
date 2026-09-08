import Foundation
import RatchetProtocol
import RMEControl

public enum RemotePalette {
    public static let black: UInt32 = 0x000000
    public static let white: UInt32 = 0xffffff
    public static let yellow: UInt32 = 0xffd60a
    public static let red: UInt32 = 0xff0000
    public static let amber: UInt32 = 0xff8a00
    public static let purple: UInt32 = 0xa855f7
    public static let dim: UInt32 = 0x080808
}

public enum ActivityBrightness {
    public static let active: UInt32 = 80
    public static let idle: UInt32 = 5
    public static let holdDuration: TimeInterval = 5
    public static let fadeDuration: TimeInterval = 10

    public static func level(elapsedSinceInteraction elapsed: TimeInterval) -> UInt32 {
        guard elapsed > holdDuration else { return active }
        guard elapsed < holdDuration + fadeDuration else { return idle }

        let progress = (elapsed - holdDuration) / fadeDuration
        let level = Double(active) - (Double(active - idle) * progress)
        return UInt32(level.rounded())
    }
}

public struct RatchetPresentationBuilder: Sendable {
    public private(set) var frameID: UInt32 = 0
    private var displayedMuted = false
    private var displayedRole: OutputRole?

    public init() {}

    public static func haptics(
        enabled: Bool,
        role: OutputRole = .main,
        currentDBTenths: Int16 = -300,
        muted: Bool = false
    ) -> Ratchet_V1_HapticConfig {
        var config = Ratchet_V1_HapticConfig()
        config.mode = enabled ? .regular : .disabled
        config.initialPosition = 0
        config.maximumVelocity = 30

        guard enabled else {
            config.startPosition = -2048
            config.endPosition = 2048
            config.detentsPerTurn = 60
            config.vernier = 1
            return config
        }

        config.vernier = 0
        config.progressiveForce = false

        if muted {
            // A zero-width regular range cannot cross a detent. Equal center
            // and end-stop strengths make it feel like damped friction with a
            // continuous elastic return rather than a row of clicks.
            config.startPosition = 0
            config.endPosition = 0
            config.detentsPerTurn = 60
            config.detentStrength = 3.0
            config.endstopStrength = 3.0
            config.damping = 0.06
            config.outputRamp = 200
            config.maximumTorque = 0.43
            return config
        }

        let minimum = Int(RMERegisterMap.minimumDBTenths)
        let maximum = Int(role.maximumDBTenths)
        let current = min(max(Int(currentDBTenths), minimum), maximum)
        let step = role == .main ? 10 : 5

        // Anchor the current soundcard level at logical zero. The available
        // detents in either direction exactly match the remaining audio range,
        // so firmware end stops become the physical min/max volume limits.
        config.startPosition = -Int32(Self.roundingUp(current - minimum, by: step))
        config.endPosition = Int32(Self.roundingUp(maximum - current, by: step))

        // Main is another 30% faster than its previous 26-detent profile
        // (33.8 rounded to 34). Phones retains its 26-detent precision profile.
        config.detentsPerTurn = role == .main ? 34 : 26
        config.detentStrength = role == .main ? 3.5 : 2.5
        config.endstopStrength = 12.0
        config.damping = 0.012
        config.outputRamp = role == .main ? 250 : 200
        // Current firmware maps this through its 5.3-ohm legacy phase model
        // and rejects demands above its 5 V * 0.8 / sqrt(3) linear-modulation
        // limit. 0.43 is just below that enforced ceiling.
        config.maximumTorque = 0.43
        return config
    }

    private static func roundingUp(_ distance: Int, by step: Int) -> Int {
        precondition(distance >= 0 && step > 0)
        return (distance + step - 1) / step
    }

    public mutating func configuration(
        viewState: RemoteViewState,
        brightness: UInt32 = ActivityBrightness.active
    ) -> Ratchet_V1_Configure {
        var configure = Ratchet_V1_Configure()
        let output = viewState.selectedOutput
        configure.haptics = Self.haptics(
            enabled: viewState.rmeConnected && output != nil,
            role: viewState.selectedRole,
            currentDBTenths: output?.dbTenths ?? RMERegisterMap.minimumDBTenths,
            muted: output?.muted ?? false
        )
        configure.leds = ledFrame(viewState: viewState, brightness: brightness)
        configure.display = displayFrame(viewState: viewState, full: true, brightness: brightness)
        configure.knobReportIntervalMs = 10
        configure.hostWatchdogTimeoutMs = 2_500
        return configure
    }

    public mutating func hapticsCommand(
        enabled: Bool,
        role: OutputRole,
        currentDBTenths: Int16,
        muted: Bool
    ) -> Ratchet_V1_SetHaptics {
        var command = Ratchet_V1_SetHaptics()
        command.haptics = Self.haptics(
            enabled: enabled,
            role: role,
            currentDBTenths: currentDBTenths,
            muted: muted
        )
        command.preservePosition = false
        return command
    }

    public mutating func ledFrame(
        viewState: RemoteViewState,
        brightness: UInt32 = ActivityBrightness.active
    ) -> Ratchet_V1_LedFrame {
        frameID &+= 1
        var colors = [UInt32](repeating: RemotePalette.black, count: 68)

        if let rme = viewState.rmeState {
            let output = rme[viewState.selectedRole.rmeOutput]
            let activeColor = viewState.selectedRole == .main ? RemotePalette.white : RemotePalette.purple
            let ringLevel = output.isAtFloor
                ? viewState.mutedRestoreVolumes[viewState.selectedRole.rmeOutput] ?? output.dbTenths
                : output.dbTenths
            let ringColor = output.muted ? RemotePalette.red : activeColor
            let floor = Double(RMERegisterMap.minimumDBTenths)
            let cap = Double(viewState.selectedRole.maximumDBTenths)
            let fraction = min(max((Double(ringLevel) - floor) / (cap - floor), 0), 1)
            // The meter grows from the right-hand +120-degree endpoint,
            // through north, toward the left-hand -120-degree endpoint.
            let lit = min(41, max(1, Int((fraction * 40).rounded()) + 1))
            for step in 0..<lit {
                colors[Self.physicalRingIndex(clockwiseStepFromNorth: 20 - step)] = ringColor
            }

            if rme.micLine1Muted {
                // Pixel 15 is north, so 44...46 are the three LEDs centered
                // on the otherwise-unused bottom (180-degree) ring gap.
                for pixel in 44...46 { colors[pixel] = RemotePalette.red }
            }

            Self.setKey(0, color: rme.micLine1Muted ? RemotePalette.red : RemotePalette.black, in: &colors)
            Self.setKey(1, color: rme.phones.muted ? RemotePalette.red : RemotePalette.black, in: &colors)
            Self.setKey(2, color: rme.main.muted ? RemotePalette.red : RemotePalette.black, in: &colors)
            Self.setKey(
                3,
                color: viewState.selectedRole == .phones ? RemotePalette.purple : RemotePalette.black,
                in: &colors
            )
        }

        var frame = Ratchet_V1_LedFrame()
        frame.frameID = frameID
        frame.rgb888 = Data(colors.flatMap { color in
            [UInt8(color >> 16), UInt8((color >> 8) & 0xff), UInt8(color & 0xff)]
        })
        frame.brightness = min(brightness, 255)
        frame.present = true
        return frame
    }

    public mutating func displayFrame(
        viewState: RemoteViewState,
        full: Bool,
        includeRole: Bool = true,
        brightness: UInt32 = ActivityBrightness.active
    ) -> Ratchet_V1_DisplayFrame {
        let outputMuted = viewState.rmeConnected && viewState.selectedOutputMuted
        // A haptic acknowledgement requests another display update after the
        // mute frame. The panel draws directly, so clearing that same field
        // again visibly cuts through the ring already on screen.
        if !full, outputMuted, displayedMuted,
           !includeRole || displayedRole == viewState.selectedRole {
            return displayBrightnessFrame(brightness: brightness)
        }
        let redrawVolume = full || !outputMuted || !displayedMuted
        defer {
            displayedMuted = outputMuted
            if !viewState.rmeConnected {
                displayedRole = nil
            } else if includeRole {
                displayedRole = viewState.selectedRole
            }
        }
        frameID &+= 1
        var operations: [Ratchet_V1_DrawOp] = []
        if full || !viewState.rmeConnected {
            var clear = Ratchet_V1_Clear()
            clear.color = Self.rgb(RemotePalette.black)
            var op = Ratchet_V1_DrawOp()
            op.operation = .clear(clear)
            operations.append(op)
        }

        if viewState.rmeConnected {
            if !full, outputMuted {
                if redrawVolume {
                    operations.append(Self.fillRect(
                        x: 8,
                        y: 62,
                        width: 224,
                        height: 60,
                        color: RemotePalette.black
                    ))
                }
                if includeRole {
                    // Both role labels fit here, entirely inside the ring.
                    operations.append(Self.fillRect(
                        x: 40, y: 154, width: 160, height: 24,
                        color: RemotePalette.black
                    ))
                }
            }
            let ringIndex = operations.count
            if redrawVolume {
                operations.append(Self.text(
                    viewState.volumeText,
                    y: outputMuted ? 72 : 62,
                    size: .large,
                    scale: outputMuted ? 2 : 3,
                    color: outputMuted ? RemotePalette.red : RemotePalette.white,
                    opaqueBackground: !outputMuted
                ))
            }
            if includeRole {
                operations.append(Self.text(
                    viewState.selectedRole.label,
                    y: 154,
                    size: .small,
                    scale: 2,
                    color: RemotePalette.yellow,
                    opaqueBackground: !outputMuted
                ))
            }
            // The device strokes circles inward: 12 pixels is 5% of the
            // 240-pixel panel. Clear first, then draw the ring, then text.
            // Muted text is transparent so it cannot clear over the ring.
            var ring = Ratchet_V1_Circle()
            ring.centerX = 120
            ring.centerY = 120
            // Firmware rejects the entire frame if center + radius reaches
            // 240; the last valid pixel coordinate is 239.
            ring.radius = 119
            ring.strokeWidth = 12
            ring.color = Self.rgb(outputMuted ? RemotePalette.red : RemotePalette.black)
            var ringOp = Ratchet_V1_DrawOp()
            ringOp.operation = .circle(ring)
            if redrawVolume {
                operations.insert(ringOp, at: ringIndex)
            }
        } else {
            operations.append(Self.text(
                "RME",
                y: 86,
                size: .medium,
                scale: 2,
                color: RemotePalette.red
            ))
            operations.append(Self.text(
                "DISCONNECTED",
                y: 128,
                size: .medium,
                scale: 1,
                color: RemotePalette.red
            ))
        }

        var backlight = Ratchet_V1_SetBacklight()
        backlight.brightness = min(brightness, 255)
        var backlightOp = Ratchet_V1_DrawOp()
        backlightOp.operation = .setBacklight(backlight)
        operations.append(backlightOp)

        var frame = Ratchet_V1_DisplayFrame()
        frame.frameID = frameID
        frame.operations = operations
        frame.present = true
        return frame
    }

    public mutating func displayBrightnessFrame(
        brightness: UInt32
    ) -> Ratchet_V1_DisplayFrame {
        frameID &+= 1
        var backlight = Ratchet_V1_SetBacklight()
        backlight.brightness = min(brightness, 255)
        var operation = Ratchet_V1_DrawOp()
        operation.operation = .setBacklight(backlight)

        var frame = Ratchet_V1_DisplayFrame()
        frame.frameID = frameID
        frame.operations = [operation]
        frame.present = true
        return frame
    }

    private static func physicalRingIndex(clockwiseStepFromNorth step: Int) -> Int {
        (15 + step + 60) % 60
    }

    private static func setKey(_ button: Int, color: UInt32, in colors: inout [UInt32]) {
        let pairs = [[3, 4], [2, 5], [1, 6], [0, 7]]
        for key in pairs[button] { colors[60 + key] = color }
    }

    private static func fillRect(
        x: Int32,
        y: Int32,
        width: UInt32,
        height: UInt32,
        color: UInt32
    ) -> Ratchet_V1_DrawOp {
        var rectangle = Ratchet_V1_FillRect()
        rectangle.x = x
        rectangle.y = y
        rectangle.width = width
        rectangle.height = height
        rectangle.color = rgb(color)
        var operation = Ratchet_V1_DrawOp()
        operation.operation = .fillRect(rectangle)
        return operation
    }

    private static func rgb(_ value: UInt32) -> Ratchet_V1_Rgb {
        var color = Ratchet_V1_Rgb()
        color.rgb888 = value
        return color
    }

    private static func text(
        _ value: String,
        y: Int32,
        size: Ratchet_V1_FontSize,
        scale: UInt32,
        color: UInt32,
        opaqueBackground: Bool = true
    ) -> Ratchet_V1_DrawOp {
        var text = Ratchet_V1_Text()
        // Text.x is the field's left edge; alignment happens within maxWidth.
        // An x of 8 centers the 224-pixel field on the 240-pixel display.
        text.x = 8
        text.y = y
        text.maxWidth = 224
        text.value = value
        text.size = size
        text.align = .center
        text.foreground = rgb(color)
        text.background = rgb(RemotePalette.black)
        text.opaqueBackground = opaqueBackground
        text.scale = scale
        var operation = Ratchet_V1_DrawOp()
        operation.operation = .text(text)
        return operation
    }
}
