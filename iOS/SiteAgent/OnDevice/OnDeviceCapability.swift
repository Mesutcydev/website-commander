import Foundation

#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
// Security.framework exports these on iOS, but the Swift overlay does not expose
// SecTask. Keep a minimal local ABI bridge so the running code signature — not
// the source .entitlements file — is authoritative. A free-account re-sign of a
// sideloaded IPA strips the kernel memory entitlements even though the source
// file still declares them; only the live signature tells the truth.
@_silgen_name("SecTaskCreateFromSelf")
private func SiteAgentCreateSecurityTask(_ allocator: CFAllocator?) -> CFTypeRef?

@_silgen_name("SecTaskCopyValueForEntitlement")
private func SiteAgentCopyEntitlementValue(
    _ task: CFTypeRef,
    _ entitlement: CFString,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> CFTypeRef?
#endif

/// Decides whether this device may run on-device LLMs, and exposes a coarse
/// memory tier. Distilled from the on-device reference app's device gating:
/// it keys off physical RAM, which cleanly maps to "iPhone 15 Pro and newer"
/// (the first 8 GB iPhones). No model-identifier allowlist to maintain.
enum OnDeviceCapability {

    /// Memory floor. iPhone 15 Pro / Pro Max, every iPhone 16/17, and M-series
    /// iPads report ≥ 8 GB; everything older reports ≤ 6 GB. A 7.5 GB floor sits
    /// safely between those two clusters, so the rule is effectively
    /// "iPhone 15 Pro and up".
    private static let memoryFloor: UInt64 = 7_500_000_000

    /// True when the device meets the RAM floor for on-device models. The
    /// Simulator always passes so the feature stays testable on a Mac.
    static var isCapable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.physicalMemory >= memoryFloor
        #endif
    }

    /// Whether the `increased-memory-limit` entitlement is present in the
    /// signature iOS is actually running. Declaring the key in the source
    /// entitlements file is not enough — a free-account re-sign of a sideloaded
    /// IPA drops it, so the process runs at the default (much lower) jetsam
    /// ceiling and large on-device models would be memory-killed. Simulator and
    /// Catalyst aren't governed by iOS jetsam provisioning, so they report true.
    static var hasIncreasedMemoryLimitEntitlement: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        guard let task = SiteAgentCreateSecurityTask(nil),
              let value = SiteAgentCopyEntitlementValue(
                task,
                "com.apple.developer.kernel.increased-memory-limit" as CFString,
                nil
              ) else {
            return false
        }
        return (value as? Bool) == true
        #else
        return true
        #endif
    }

    enum Tier {
        case pro   // ~8 GB  — iPhone 15 Pro, 16, 16 Pro, 17 …
        case max   // ≥12 GB — iPhone 17 Pro Max, M-series iPad …
    }

    /// Coarse tier used to flag which catalog entries are comfortable vs tight.
    static var tier: Tier {
        let base = tier(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        // A resigned/sideloaded build that stripped the memory entitlement runs
        // at the default jetsam ceiling, so the .max tier's large models would
        // OOM. Cap such installs at .pro regardless of physical RAM.
        return hasIncreasedMemoryLimitEntitlement ? base : .pro
    }

    static func tier(physicalMemoryBytes: UInt64) -> Tier {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824
        // A marketed 12 GB device reports about 10.7 GiB through physicalMemory.
        // The old 11.0 GiB threshold incorrectly classified iPhone 17 Pro Max
        // as the lower tier and hid its intended large-model recommendation.
        return gb >= 10.5 ? .max : .pro
    }

    /// `hw.machine` identifier (e.g. "iPhone16,1"), for diagnostics / UI.
    static var machineIdentifier: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Physical RAM in whole GB, for display.
    static var physicalMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }
}
