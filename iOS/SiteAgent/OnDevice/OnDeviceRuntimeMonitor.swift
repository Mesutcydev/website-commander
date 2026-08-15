import Foundation
import UIKit

/// Runtime policy for local model work. It keeps on-device generation bursty
/// under normal conditions, then backs off when iOS reports heat or memory
/// pressure so the app avoids turning one long answer into sustained load.
struct OnDeviceRuntimePolicy: Equatable {
    enum Mode: Equatable {
        case full
        case reduced
        case suspended
    }

    static let standardMaxCompletionTokens = 4_096
    private static let fairThermalMaxTokens = 3_072
    private static let constrainedMaxTokens = 2_048
    private static let throttledDecodeDelayNanoseconds: UInt64 = 40_000_000

    let mode: Mode
    let maxCompletionTokens: Int
    let constrainedByMemoryWarning: Bool
    let decodeDelayNanoseconds: UInt64

    var allowsGeneration: Bool { mode != .suspended }

    static func make(
        thermalState: ProcessInfo.ThermalState,
        recentMemoryWarning: Bool,
        lowPowerMode: Bool = false,
        requestedMaxTokens: Int = Self.standardMaxCompletionTokens
    ) -> OnDeviceRuntimePolicy {
        let requested = max(0, requestedMaxTokens)
        let thermalMode: Mode
        let thermalLimit: Int

        switch thermalState {
        case .nominal:
            thermalMode = .full
            thermalLimit = requested
        case .fair:
            thermalMode = .reduced
            thermalLimit = min(requested, fairThermalMaxTokens)
        case .serious:
            thermalMode = .reduced
            thermalLimit = min(requested, constrainedMaxTokens)
        case .critical:
            return OnDeviceRuntimePolicy(
                mode: .suspended,
                maxCompletionTokens: 0,
                constrainedByMemoryWarning: recentMemoryWarning,
                decodeDelayNanoseconds: 0
            )
        @unknown default:
            thermalMode = .reduced
            thermalLimit = min(requested, constrainedMaxTokens)
        }

        let memoryLimit = recentMemoryWarning ? min(thermalLimit, constrainedMaxTokens) : thermalLimit
        let finalLimit = lowPowerMode ? min(memoryLimit, constrainedMaxTokens) : memoryLimit
        let mode: Mode = (recentMemoryWarning || lowPowerMode) && thermalMode == .full
            ? .reduced : thermalMode
        let decodeDelay = (lowPowerMode || thermalState == .serious)
            ? throttledDecodeDelayNanoseconds : 0
        return OnDeviceRuntimePolicy(
            mode: mode,
            maxCompletionTokens: finalLimit,
            constrainedByMemoryWarning: recentMemoryWarning,
            decodeDelayNanoseconds: decodeDelay
        )
    }
}

/// Watches the OS signals that matter for sustained local inference: thermal
/// state and memory warnings. Views read it for status, providers read it right
/// before generation to pick the current budget.
@MainActor
final class OnDeviceRuntimeMonitor: ObservableObject {
    static let shared = OnDeviceRuntimeMonitor()

    private static let recentMemoryWarningWindow: TimeInterval = 5 * 60

    @Published private(set) var thermalState: ProcessInfo.ThermalState
    @Published private(set) var memoryWarningCount = 0
    @Published private(set) var lastMemoryWarning: Date?

    private let notificationCenter: NotificationCenter
    private let processInfo: ProcessInfo
    private var thermalTask: Task<Void, Never>?
    private var memoryWarningTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?

    private init(
        notificationCenter: NotificationCenter = .default,
        processInfo: ProcessInfo = .processInfo
    ) {
        self.notificationCenter = notificationCenter
        self.processInfo = processInfo
        self.thermalState = processInfo.thermalState
        installObservers()
        installKernelMemoryPressureObserver()
    }

    deinit {
        thermalTask?.cancel()
        memoryWarningTask?.cancel()
        pressureSource?.cancel()
    }

    func currentPolicy(
        requestedMaxTokens: Int = OnDeviceRuntimePolicy.standardMaxCompletionTokens,
        now: Date = Date()
    ) -> OnDeviceRuntimePolicy {
        OnDeviceRuntimePolicy.make(
            thermalState: thermalState,
            recentMemoryWarning: hasRecentMemoryWarning(now: now),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            requestedMaxTokens: requestedMaxTokens
        )
    }

    func hasRecentMemoryWarning(now: Date = Date()) -> Bool {
        guard let lastMemoryWarning else { return false }
        return now.timeIntervalSince(lastMemoryWarning) < Self.recentMemoryWarningWindow
    }

    private func installObservers() {
        thermalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in notificationCenter.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                thermalState = processInfo.thermalState
            }
        }

        memoryWarningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in notificationCenter.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                memoryWarningCount += 1
                lastMemoryWarning = Date()
            }
        }
    }

    /// UIKit warnings are advisory and can fire during a healthy model load.
    /// A kernel `.critical` pressure edge is the imminent-Jetsam signal; publish
    /// it separately so the engine can cancel decode before releasing buffers.
    private func installKernelMemoryPressureObserver() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            let event = source.data
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: event.contains(.critical)
                        ? .siteAgentCriticalMemoryPressure
                        : .siteAgentMemoryPressureWarning,
                    object: nil
                )
            }
        }
        source.resume()
        pressureSource = source
    }
}

extension Notification.Name {
    static let siteAgentMemoryPressureWarning = Notification.Name("SiteAgent_MemoryPressureWarning")
    static let siteAgentCriticalMemoryPressure = Notification.Name("SiteAgent_CriticalMemoryPressure")
}
