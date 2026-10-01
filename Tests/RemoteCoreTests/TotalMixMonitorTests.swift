import Testing
@testable import RemoteCore

@MainActor
@Test func totalMixDetectionUsesActualBundleAndExecutableNames() {
    #expect(TotalMixMonitor.isTotalMix(bundleIdentifier: "de.rme-audio.TotalmixFX", executableName: nil))
    #expect(TotalMixMonitor.isTotalMix(bundleIdentifier: nil, executableName: "TotalmixFX"))
    #expect(!TotalMixMonitor.isTotalMix(bundleIdentifier: "com.coral.RatchetRemote", executableName: "RatchetRemote"))
    #expect(!TotalMixMonitor.isTotalMix(bundleIdentifier: nil, executableName: "TotalMix Remote"))
    #expect(!TotalMixMonitor.isTotalMix(bundleIdentifier: nil, executableName: nil))
}

@Test func totalMixHandoffHasDistinctStatusInsteadOfAConnectionError() {
    var state = RemoteViewState()
    state.totalMixRunning = true
    #expect(state.statusSummary == "Controlled by TotalMix")
    #expect(state.errorMessage == nil)
    #expect(state.selectedOutput == nil)
}
