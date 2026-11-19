using System.Globalization;

namespace Cliphoard.Windows;

internal sealed record TimeScope(string Name, DateTime? Start = null, DateTime? End = null)
{
    internal bool Contains(DateTimeOffset value, DateTimeOffset now)
    {
        DateTime day = value.LocalDateTime.Date, today = now.LocalDateTime.Date;
        return Name switch
        {
            "Today" => day == today,
            "Yesterday" => day == today.AddDays(-1),
            "This week" => day >= today.AddDays(-((7 + (int)today.DayOfWeek - (int)CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek) % 7))
                && day < today.AddDays(7 - ((7 + (int)today.DayOfWeek - (int)CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek) % 7)),
            "This month" => day.Year == today.Year && day.Month == today.Month,
            "Last 7 days" => value >= now.AddDays(-7) && value <= now,
            "Last 30 days" => value >= now.AddDays(-30) && value <= now,
            "Custom range" => Start is DateTime start && End is DateTime end && day >= (start < end ? start : end).Date && day <= (start > end ? start : end).Date,
            _ => true
        };
    }
}

internal sealed record TimeQuery(string Text, TimeScope? Scope)
{
    internal static TimeQuery Parse(string query)
    {
        string[] parts = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        int index = Array.FindIndex(parts, part => part.StartsWith("when:", StringComparison.OrdinalIgnoreCase));
        if (index < 0) return new(query, null);
        string value = parts[index][5..].ToLowerInvariant();
        TimeScope? scope = value switch
        {
            "today" => new("Today"), "yesterday" or "yday" => new("Yesterday"),
            "week" or "this-week" or "thisweek" => new("This week"),
            "month" or "this-month" or "thismonth" => new("This month"),
            "7d" or "week7" or "last7" or "7days" => new("Last 7 days"),
            "30d" or "last30" or "30days" => new("Last 30 days"),
            _ => Dates(value)
        };
        return new(string.Join(' ', parts.Where((_, position) => position != index)), scope);
    }

    private static TimeScope? Dates(string value)
    {
        string[] dates = value.Split("..", StringSplitOptions.None);
        if (dates.Length is < 1 or > 2 || !DateTime.TryParseExact(dates[0], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTime start)) return null;
        DateTime end = start;
        if (dates.Length == 2 && !DateTime.TryParseExact(dates[1], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out end)) return null;
        return new("Custom range", start, end);
    }
}
