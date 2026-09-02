import Foundation

/// When the background update check last ran, and whether it is due again.
///
/// The timestamp lives on disk rather than in memory so restarting Hangar does
/// not restart the clock. A laptop that is opened and closed all day would
/// otherwise check on every launch, which is not what "once a day" means.
public enum UpdateSchedule {
    public static var stampPath: String {
        (HangarConfig.home as NSString).appendingPathComponent("cache/last-update-check")
    }

    public static func lastCheck(path: String = stampPath) -> Date? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static func recordCheck(at date: Date = Date(), path: String = stampPath) {
        // Everything Hangar writes under ~/.hangar is 0600, including this.
        PrivateFile.write(Data("\(date.timeIntervalSince1970)".utf8), to: path)
    }

    /// `hours` of zero or less turns the schedule off entirely.
    public static func isDue(every hours: Int, now: Date = Date(),
                             lastCheck last: Date?) -> Bool {
        guard hours > 0 else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Double(hours) * 3600
    }

    public static func isDue(every hours: Int, now: Date = Date(),
                             path: String = stampPath) -> Bool {
        isDue(every: hours, now: now, lastCheck: lastCheck(path: path))
    }
}
