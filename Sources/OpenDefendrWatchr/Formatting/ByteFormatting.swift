import Foundation

/// Compact, stable byte formatting.
///
/// `Foundation.ByteCountFormatter` is locale-dependent and jitters in width, which makes
/// a menu bar item bounce around. These formatters are deterministic and binary-based
/// (matching how `ps`, `vm_stat` and Activity Monitor talk about memory pressure).
public enum ByteFormatting {
    private static let units: [(suffix: String, scale: Double)] = [
        ("T", 1024 * 1024 * 1024 * 1024),
        ("G", 1024 * 1024 * 1024),
        ("M", 1024 * 1024),
        ("K", 1024),
    ]

    /// Menu-bar form: `18.9G`, `113M`, `4.0K`, `512B`.
    ///
    /// Values >= 1 GB keep one decimal (the difference between 8.4G and 8.9G matters);
    /// smaller values are rounded to whole units to keep the title short.
    public static func compact(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        for unit in units {
            guard value >= unit.scale else { continue }
            let scaled = value / unit.scale
            if unit.suffix == "T" || unit.suffix == "G" {
                return String(format: "%.1f%@", scaled, unit.suffix)
            }
            return String(format: "%.0f%@", scaled.rounded(), unit.suffix)
        }
        return "\(bytes)B"
    }

    /// Menu/detail form: `18.91 GB`, `113.5 MB`, `512 bytes`.
    public static func detailed(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        for unit in units {
            guard value >= unit.scale else { continue }
            return String(format: "%.2f %@B", value / unit.scale, unit.suffix)
        }
        return "\(bytes) bytes"
    }

    /// `12.5%`
    public static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }
}
