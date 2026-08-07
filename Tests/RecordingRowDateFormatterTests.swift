import Foundation
import Testing
@testable import OpenMinutes

@Suite("Recording row dates")
struct RecordingRowDateFormatterTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private static let locale = Locale(identifier: "en_US")

    private static func date(
        year: Int = 2026,
        month: Int = 6,
        day: Int,
        hour: Int = 15,
        minute: Int = 4
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }

    @Test func todayShowsTime() {
        let text = RecordingRowDateFormatter.text(
            for: Self.date(day: 10, hour: 15, minute: 4),
            now: Self.date(day: 10, hour: 18, minute: 0),
            calendar: Self.calendar,
            locale: Self.locale
        )

        #expect(text == "3:04 PM")
    }

    @Test func yesterdayShowsYesterday() {
        let text = RecordingRowDateFormatter.text(
            for: Self.date(day: 9),
            now: Self.date(day: 10),
            calendar: Self.calendar,
            locale: Self.locale
        )

        #expect(text == "Yesterday")
    }

    @Test func olderDatesShowFullDate() {
        let text = RecordingRowDateFormatter.text(
            for: Self.date(day: 8),
            now: Self.date(day: 10),
            calendar: Self.calendar,
            locale: Self.locale
        )

        #expect(text == "June 8, 2026")
    }

    @Test func formattingUsesCalendarTimeZone() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Self.date(day: 10, hour: 15, minute: 4)
        let now = Self.date(day: 10, hour: 18, minute: 0)

        let chicagoText = RecordingRowDateFormatter.text(
            for: date,
            now: now,
            calendar: Self.calendar,
            locale: Self.locale
        )
        let utcText = RecordingRowDateFormatter.text(
            for: date,
            now: now,
            calendar: utcCalendar,
            locale: Self.locale
        )

        #expect(chicagoText == "3:04 PM")
        #expect(utcText == "8:04 PM")
    }
}
