import Foundation

/// A time window over a clip's `createdAt` — the "when did I copy this?" filter.
/// Presets resolve against the user's calendar; `.range` is an explicit closed
/// day interval. Set by the time chip or parsed from a `when:` token, and
/// composes with kind / dimension / text filters in every search mode.
///
/// `contains` takes an injectable `now`/`calendar` so the windows are testable
/// without touching wall-clock.
enum TimeFilter: Equatable {
    case any
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case last7
    case last30
    case range(Date, Date)

    var isActive: Bool { self != .any }

    /// Short, human label for the chip / active-filter pill.
    var label: String {
        switch self {
        case .any:       return "Any time"
        case .today:     return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek:  return "This week"
        case .thisMonth: return "This month"
        case .last7:     return "Last 7 days"
        case .last30:    return "Last 30 days"
        case .range(let a, let b):
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return "\(f.string(from: a))–\(f.string(from: b))"
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .any:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .yesterday:
            guard let y = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
            return calendar.isDate(date, inSameDayAs: y)
        case .thisWeek:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return false }
            return interval.contains(date)
        case .thisMonth:
            guard let interval = calendar.dateInterval(of: .month, for: now) else { return false }
            return interval.contains(date)
        case .last7:
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return false }
            return date >= start && date <= now
        case .last30:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return false }
            return date >= start && date <= now
        case .range(let a, let b):
            // Inclusive of both calendar days: [startOfDay(a), endOfDay(b)).
            let lo = min(a, b), hi = max(a, b)
            let start = calendar.startOfDay(for: lo)
            guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: hi))
            else { return date >= start }
            return date >= start && date < end
        }
    }
}

/// Parses a `when:` token out of a search query so time words don't pollute the
/// text match. Recognises easy words (`today`, `yesterday`, `week`, `month`,
/// `7d`, `30d`) and explicit dates (`2026-07-15`, `2026-07-01..2026-07-15`).
/// Returns the resolved filter (if any) and the query with the token removed.
enum WhenToken {
    static func parse(_ query: String) -> (filter: TimeFilter?, rest: String) {
        let parts = query.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let idx = parts.firstIndex(where: { $0.lowercased().hasPrefix("when:") }) else {
            return (nil, query)
        }
        let value = String(parts[idx].dropFirst("when:".count)).lowercased()
        let rest = (parts[..<idx] + parts[(idx + 1)...]).joined(separator: " ")
        return (filter(for: value), rest)
    }

    /// Resolve a bare value (`today`, `week`, `2026-07-15`, `a..b`) to a filter.
    static func filter(for value: String) -> TimeFilter? {
        switch value {
        case "today":               return .today
        case "yesterday", "yday":   return .yesterday
        case "week", "this-week", "thisweek": return .thisWeek
        case "month", "this-month", "thismonth": return .thisMonth
        case "7d", "week7", "last7", "7days": return .last7
        case "30d", "last30", "30days": return .last30
        default:
            if value.contains("..") {
                let ends = value.components(separatedBy: "..")
                if ends.count == 2, let a = date(ends[0]), let b = date(ends[1]) { return .range(a, b) }
                return nil
            }
            if let d = date(value) { return .range(d, d) }   // single day
            return nil
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func date(_ s: String) -> Date? { dayFormatter.date(from: s) }
}
