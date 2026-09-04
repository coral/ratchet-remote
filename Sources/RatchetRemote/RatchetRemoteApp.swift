import AppKit
import RMEControl
import RemoteCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
@MainActor
struct RatchetRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator: RemoteCoordinator
    @State private var commandLineTestStarted = false

    init() {
        let diagnostic = ProcessInfo.processInfo.arguments.contains("--input-test")
        _coordinator = State(initialValue: RemoteCoordinator(diagnosticLogging: diagnostic))
    }

    var body: some Scene {
        MenuBarExtra {
            RemoteMenuView(coordinator: coordinator)
        } label: {
            Text("B")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .onAppear { startApplication() }
        }
        .menuBarExtraStyle(.window)
    }

    private func startApplication() {
        coordinator.start()
        let arguments = ProcessInfo.processInfo.arguments
        guard !commandLineTestStarted else { return }
        if arguments.contains("--input-test") {
            commandLineTestStarted = true
            print("Input test ready for 45 seconds: press buttons 0-3 and turn the knob in both roles.")
            Task {
                try? await Task.sleep(for: .seconds(45))
                await coordinator.shutdown()
                NSApp.terminate(nil)
            }
            return
        }
        guard arguments.contains("--smoke-test") else { return }
        commandLineTestStarted = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            let state = coordinator.viewState
            let ratchetStatus = state.ratchetConfigured ? "ready" : state.ratchetConnected ? "configuring" : "offline"
            print("Ratchet: \(ratchetStatus) \(state.ratchetSerial ?? "")")
            if let rme = state.rmeState {
                print("RME: connected serial \(rme.serial)")
                print("Main: \(Double(rme.main.dbTenths) / 10.0) dB, muted=\(rme.main.muted)")
                print("Phones: \(Double(rme.phones.dbTenths) / 10.0) dB, muted=\(rme.phones.muted)")
                print(
                    "Mic/Line 1: \(Double(rme.micLine1GainDBTenths) / 10.0) dB, muted=\(rme.micLine1Muted)"
                )
            } else {
                print("RME: offline")
            }
            if let error = state.errorMessage { print("Error: \(error)") }
            await coordinator.shutdown()
            NSApp.terminate(nil)
        }
    }
}

private struct RemoteMenuView: View {
    @Bindable var coordinator: RemoteCoordinator

    private let amber = Color(red: 1, green: 0.54, blue: 0)
    private let purple = Color(red: 0.66, green: 0.33, blue: 0.97)
    private let muteRed = Color(red: 1, green: 0, blue: 0)

    var body: some View {
        VStack(spacing: 14) {
            header
            volumeCard
            rolePicker
            Divider()
            controls
            Divider()
            deviceStatus
            actions
        }
        .padding(16)
        .frame(width: 330)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.black)
                Text("B")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("RATCHET REMOTE")
                    .font(.system(.headline, design: .monospaced, weight: .bold))
                Text(coordinator.viewState.statusSummary)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            Circle()
                .fill(coordinator.viewState.ratchetConfigured && coordinator.viewState.rmeConnected ? .green : .orange)
                .frame(width: 8, height: 8)
        }
    }

    private var volumeCard: some View {
        VStack(spacing: 0) {
            Text(coordinator.viewState.volumeText)
                .font(.system(size: 46, weight: .semibold, design: .monospaced))
                .contentTransition(.numericText())
                .foregroundStyle(coordinator.viewState.selectedOutputMuted ? muteRed : .white)
                .minimumScaleFactor(0.7)
            Text(coordinator.viewState.rmeConnected ? coordinator.viewState.selectedRole.label : "RME OFFLINE")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(coordinator.viewState.rmeConnected ? Color.yellow : muteRed)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(.black, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(roleColor.opacity(0.55), lineWidth: 1)
        }
    }

    private var rolePicker: some View {
        HStack(spacing: 6) {
            roleButton(.main)
            roleButton(.phones)
        }
        .padding(4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func roleButton(_ role: OutputRole) -> some View {
        Button {
            coordinator.setSelectedRole(role)
        } label: {
            Text(role.label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    coordinator.viewState.selectedRole == role
                        ? (role == .main ? amber : purple)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(coordinator.viewState.selectedRole == role ? .black : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            muteRow(
                title: "Mic/Line 1 gain",
                muted: coordinator.viewState.rmeState?.micLine1Muted,
                action: { await coordinator.toggleMicLine1Mute() }
            )
            muteRow(
                title: "Phones 7/8",
                muted: coordinator.viewState.rmeState?.phones.muted,
                action: { await coordinator.toggleMute(.phones) }
            )
            muteRow(
                title: "Main 1/2",
                muted: coordinator.viewState.rmeState?.main.muted,
                action: { await coordinator.toggleMute(.main) }
            )
        }
    }

    private func muteRow(
        title: String,
        muted: Bool?,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Circle()
                    .fill(muted == true ? muteRed : muted == false ? Color.white : Color.gray)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.gray.opacity(0.6), lineWidth: muted == false ? 1 : 0))
                Text(title)
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                Text(muted == nil ? "OFFLINE" : muted == true ? "MUTED" : "LIVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(muted == true ? muteRed : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(muted == nil)
    }

    private var deviceStatus: some View {
        VStack(spacing: 6) {
            statusRow(
                "Ratchet H1",
                detail: coordinator.viewState.ratchetSerial ?? "Not found",
                connected: coordinator.viewState.ratchetConnected
            )
            statusRow(
                "Fireface UCX II",
                detail: coordinator.viewState.rmeState.map { "Serial \($0.serial)" } ?? "Not found",
                connected: coordinator.viewState.rmeConnected
            )
            if let error = coordinator.viewState.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(muteRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
        }
    }

    private func statusRow(_ name: String, detail: String, connected: Bool) -> some View {
        HStack {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .green : .secondary)
            Text(name).font(.caption)
            Spacer()
            Text(detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var actions: some View {
        HStack {
            Button("Reconnect") {
                Task { await coordinator.reconnect() }
            }
            Spacer()
            Button("Quit") {
                Task {
                    await coordinator.shutdown()
                    NSApp.terminate(nil)
                }
            }
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    private var roleColor: Color {
        coordinator.viewState.selectedRole == .main ? amber : purple
    }

    private var statusColor: Color {
        coordinator.viewState.ratchetConnected && coordinator.viewState.rmeConnected ? .green : .secondary
    }
}
