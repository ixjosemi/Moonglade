import Foundation

/// Compact elapsed-time rendering for session rows: the two most significant
/// units, minute resolution ("47m", "1h 12m", "1d 2h"). Zero-valued trailing
/// units are dropped so a round duration stays short ("2h", "3d").
public enum SessionDurationFormatter {
    public static func string(from start: Date, to now: Date) -> String {
        let elapsedMinutes = Int(now.timeIntervalSince(start)) / 60
        guard elapsedMinutes >= 1 else { return "<1m" }
        let days = elapsedMinutes / 1_440
        let hours = elapsedMinutes % 1_440 / 60
        let minutes = elapsedMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
