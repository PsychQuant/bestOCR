import Foundation

/// Host provenance helpers for the condition tuple (spec §5.3).
public enum HostInfo {
    /// e.g. "Apple M5 Max, 128GB" — CPU brand via sysctl + physical memory.
    public static func hardwareLabel() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        let brand = String(cString: chars)
        let gb = ProcessInfo.processInfo.physicalMemory / (1 << 30)
        return "\(brand), \(gb)GB"
    }

    /// Current thermal state as the evidence-schema label (hard rule 5).
    public static func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
