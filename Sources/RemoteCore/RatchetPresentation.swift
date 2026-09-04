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

    public init() {}

    public static func haptics(
        enabled: Bool,
        role: OutputRole = .main
    ) -> Ratchet_V1_HapticConfig {
        var config = Ratchet_V1_HapticConfig()
        config.mode = enabled ? .regular : .disabled
        config.startPosition = -2048
        config.endPosition = 2048
        config.initialPosition = 0
        // Main is exactly 30% faster than the original 20-detent profile.
        // Phones rounds its requested 20% increase from 22 to 26 detents.
        config.detentsPerTurn = enabled ? 26 : 60
        config.vernier = enabled ? 0 : 1
        config.progressiveForce = false
        config.detentStrength = enabled ? (role == .main ? 3.5 : 2.5) : 0
        config.endstopStrength = enabled ? 1.0 : 0
        config.damping = enabled ? 0.012 : 0
        config.outputRamp = enabled ? (role == .main ? 250 : 200) : 0
        config.maximumTorque = enabled ? (role == .main ? 0.4 : 0.35) : 0
        config.maximumVelocity = 30
        return config
    }

    public mutating func configuration(
        viewState: RemoteViewState,
        brightness: UInt32 = ActivityBrightness.active
    ) -> Ratchet_V1_Configure {
        var configure = Ratchet_V1_Configure()
        configure.haptics = Self.haptics(
            enabled: viewState.rmeConnected,
            role: viewState.selectedRole
        )
        configure.leds = ledFrame(viewState: viewState, brightness: brightness)
        configure.display = displayFrame(viewState: viewState, full: true, brightness: brightness)
        configure.knobReportIntervalMs = 10
        configure.hostWatchdogTimeoutMs = 2_500
        return configure
    }

    public mutating func hapticsCommand(
        enabled: Bool,
        role: OutputRole
    ) -> Ratchet_V1_SetHaptics {
        var command = Ratchet_V1_SetHaptics()
        command.haptics = Self.haptics(enabled: enabled, role: role)
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
        frameID &+= 1
        var operations: [Ratchet_V1_DrawOp] = []
        if full {
            var clear = Ratchet_V1_Clear()
            clear.color = Self.rgb(RemotePalette.black)
            var op = Ratchet_V1_DrawOp()
            op.operation = .clear(clear)
            operations.append(op)
        }

        if viewState.rmeConnected {
            let outputMuted = viewState.selectedOutputMuted
            if !full, outputMuted {
                operations.append(Self.fillRect(
                    x: 8,
                    y: 62,
                    width: 224,
                    height: 60,
                    color: RemotePalette.black
                ))
            }
            operations.append(Self.text(
                viewState.volumeText,
                y: outputMuted ? 72 : 62,
                size: .large,
                scale: outputMuted ? 2 : 3,
                color: outputMuted ? RemotePalette.red : RemotePalette.white
            ))
            if includeRole {
                operations.append(Self.text(
                    viewState.selectedRole.label,
                    y: 154,
                    size: .small,
                    scale: 2,
                    color: RemotePalette.yellow
                ))
            }
        } else {
            operations.append(Self.text(
                "RME OFFLINE",
                y: 104,
                size: .medium,
                scale: 2,
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
        color: UInt32
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
        text.opaqueBackground = true
        text.scale = scale
        var operation = Ratchet_V1_DrawOp()
        operation.operation = .text(text)
        return operation
    }
}
