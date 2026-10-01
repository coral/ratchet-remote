import AppKit

/// Monitor the process lifetime, not the mixer window's visibility: a hidden
/// TotalMix still owns its driver client and continues exchanging DSP state.
@MainActor
final class TotalMixMonitor {
    private let workspace: NSWorkspace
    private var observers: [NSObjectProtocol] = []
    private var processes: Set<pid_t> = []
    private var onChange: ((Bool) -> Void)?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    nonisolated static func isTotalMix(bundleIdentifier: String?, executableName: String?) -> Bool {
        bundleIdentifier?.lowercased() == "de.rme-audio.totalmixfx"
            || executableName?.lowercased() == "totalmixfx"
    }

    func start(onChange: @escaping (Bool) -> Void) {
        stop()
        self.onChange = onChange
        let center = workspace.notificationCenter
        for name in [NSWorkspace.willLaunchApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      Self.isTotalMix(bundleIdentifier: app.bundleIdentifier,
                                      executableName: app.executableURL?.lastPathComponent) else { return }
                let process = app.processIdentifier
                let running = note.name != NSWorkspace.didTerminateApplicationNotification
                MainActor.assumeIsolated {
                    self?.update(process: process, running: running)
                }
            })
        }
        processes = Set(workspace.runningApplications.filter {
            Self.isTotalMix(bundleIdentifier: $0.bundleIdentifier, executableName: $0.executableURL?.lastPathComponent)
        }.map(\.processIdentifier))
        onChange(!processes.isEmpty)
    }

    private func update(process: pid_t, running: Bool) {
        let wasRunning = !processes.isEmpty
        if running { processes.insert(process) } else { processes.remove(process) }
        let isRunning = !processes.isEmpty
        if wasRunning != isRunning { onChange?(isRunning) }
    }

    func stop() {
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        processes.removeAll()
        onChange = nil
    }
}
