import XCTest
@testable import StayAwakeCore

final class ScheduleTests: XCTestCase {
    private let workday = [TimeWindow(start: 7 * 60, end: 20 * 60)]

    func open(_ s: Schedule, _ date: String) -> Bool { s.isOpen(at: iso(date), in: amsterdam) }

    func testStartInclusiveEndExclusive() {
        let s = Schedule.default
        // Monday 2026-11-09, Amsterdam is UTC+1
        XCTAssertFalse(open(s, "2026-11-09T05:59:59Z"), "06:59:59")
        XCTAssertTrue(open(s, "2026-11-09T06:00:00Z"), "07:00:00 is the start, inclusive")
        XCTAssertTrue(open(s, "2026-11-09T18:59:59Z"), "19:59:59")
        XCTAssertFalse(open(s, "2026-11-09T19:00:00Z"), "20:00:00 is the end, exclusive")
    }

    func testMultipleWindowsInOneDay() {
        let s = weekdays([TimeWindow(start: 8 * 60, end: 12 * 60), TimeWindow(start: 13 * 60, end: 17 * 60),
                          TimeWindow(start: 21 * 60, end: 23 * 60)], on: [1])
        XCTAssertTrue(open(s, "2026-11-09T07:00:00Z"))   // 08:00
        XCTAssertFalse(open(s, "2026-11-09T11:00:00Z"))  // 12:00
        XCTAssertFalse(open(s, "2026-11-09T11:30:00Z"))  // 12:30, gap
        XCTAssertTrue(open(s, "2026-11-09T12:00:00Z"))   // 13:00
        XCTAssertFalse(open(s, "2026-11-09T16:00:00Z"))  // 17:00
        XCTAssertTrue(open(s, "2026-11-09T20:30:00Z"))   // 21:30
        XCTAssertFalse(open(s, "2026-11-09T22:00:00Z"))  // 23:00
    }

    func testEmptyWeekdayIsClosedAllDay() {
        let s = Schedule.default
        for h in 0..<24 {
            let saturday = iso("2026-11-07T00:00:00Z").addingTimeInterval(Double(h) * 3600)
            XCTAssertFalse(s.isOpen(at: saturday, in: amsterdam), "Saturday hour \(h)")
        }
        XCTAssertFalse(open(s, "2026-11-08T10:00:00Z"), "Sunday")
        XCTAssertFalse(open(s, "2026-11-07T10:00:00Z"), "Saturday")
    }

    func testPerWeekdayWindowsDiffer() {
        var days = Array(repeating: [TimeWindow](), count: 7)
        days[1] = [TimeWindow(start: 9 * 60, end: 10 * 60)]   // Monday
        days[3] = [TimeWindow(start: 15 * 60, end: 16 * 60)]  // Wednesday
        let s = Schedule(enabled: true, days: days)
        XCTAssertTrue(open(s, "2026-11-09T08:30:00Z"))   // Mon 09:30
        XCTAssertFalse(open(s, "2026-11-10T08:30:00Z"))  // Tue 09:30
        XCTAssertTrue(open(s, "2026-11-11T14:30:00Z"))   // Wed 15:30
        XCTAssertFalse(open(s, "2026-11-11T08:30:00Z"))  // Wed 09:30
    }

    func testDisabledScheduleIsAlwaysOpen() {
        XCTAssertTrue(open(.off, "2026-11-08T03:00:00Z"))
        XCTAssertEqual(Schedule.off.nextOpen(from: iso("2026-11-08T03:00:00Z"), in: amsterdam), iso("2026-11-08T03:00:00Z"))
        XCTAssertNil(Schedule.off.currentWindowEnd(at: iso("2026-11-08T03:00:00Z"), in: amsterdam))
    }

    func testNextOpenWhenOpenIsNow() {
        let now = iso("2026-11-09T10:00:00Z")
        XCTAssertEqual(Schedule.default.nextOpen(from: now, in: amsterdam), now)
    }

    func testNextOpenLaterTheSameDay() {
        let s = weekdays([TimeWindow(start: 8 * 60, end: 9 * 60), TimeWindow(start: 14 * 60, end: 15 * 60)], on: [1])
        XCTAssertEqual(s.nextOpen(from: iso("2026-11-09T09:00:00Z"), in: amsterdam), iso("2026-11-09T13:00:00Z"))
    }

    func testNextOpenWrapsTheWeek() {
        // Friday evening after the window: next open is Monday 07:00 (06:00Z).
        let s = Schedule.default
        XCTAssertEqual(s.nextOpen(from: iso("2026-11-13T20:00:00Z"), in: amsterdam), iso("2026-11-16T06:00:00Z"))
        // Saturday and Sunday are skipped as well.
        XCTAssertEqual(s.nextOpen(from: iso("2026-11-14T12:00:00Z"), in: amsterdam), iso("2026-11-16T06:00:00Z"))
    }

    func testNextOpenWrapsFromSaturdayToSundayWindow() {
        var days = Array(repeating: [TimeWindow](), count: 7)
        days[0] = [TimeWindow(start: 10 * 60, end: 11 * 60)]
        let s = Schedule(enabled: true, days: days)
        XCTAssertEqual(s.nextOpen(from: iso("2026-11-14T12:00:00Z"), in: amsterdam), iso("2026-11-15T09:00:00Z"))
        // From Sunday after the window the next open is a week later.
        XCTAssertEqual(s.nextOpen(from: iso("2026-11-15T11:00:00Z"), in: amsterdam), iso("2026-11-22T09:00:00Z"))
    }

    func testNextOpenIsNilWithoutAnyWindow() {
        let s = Schedule(enabled: true, days: Array(repeating: [], count: 7))
        XCTAssertNil(s.nextOpen(from: iso("2026-11-09T10:00:00Z"), in: amsterdam))
    }

    func testCurrentWindowEnd() {
        XCTAssertEqual(Schedule.default.currentWindowEnd(at: iso("2026-11-09T10:00:00Z"), in: amsterdam), iso("2026-11-09T19:00:00Z"))
        XCTAssertNil(Schedule.default.currentWindowEnd(at: iso("2026-11-09T19:30:00Z"), in: amsterdam))
    }

    func testWindowEndingAtMidnight() {
        let s = weekdays([TimeWindow(start: 22 * 60, end: 1440)], on: [1])
        XCTAssertTrue(open(s, "2026-11-09T22:59:00Z"))  // 23:59
        XCTAssertFalse(open(s, "2026-11-09T23:00:00Z")) // 00:00 Tuesday, no window that day
        XCTAssertEqual(s.currentWindowEnd(at: iso("2026-11-09T21:30:00Z"), in: amsterdam), iso("2026-11-09T23:00:00Z"))
    }

    // MARK: DST

    func testSpringForwardNextOpenAndBoundaries() {
        // Sunday 2026-03-29: 02:00 CET jumps to 03:00 CEST. Window 02:30 to 04:00 clock time.
        let s = weekdays([TimeWindow(start: 150, end: 240)], on: [0])
        // 01:00Z is 03:00 CEST, the first real moment inside the window.
        XCTAssertFalse(open(s, "2026-03-29T00:59:59Z"), "01:59:59 CET")
        XCTAssertTrue(open(s, "2026-03-29T01:00:00Z"), "03:00 CEST")
        XCTAssertTrue(open(s, "2026-03-29T01:59:59Z"), "03:59:59 CEST")
        XCTAssertFalse(open(s, "2026-03-29T02:00:00Z"), "04:00 CEST is the exclusive end")
        XCTAssertEqual(s.nextOpen(from: iso("2026-03-29T00:00:00Z"), in: amsterdam), iso("2026-03-29T01:00:00Z"))
    }

    func testSpringForwardWindowLengthInRealTime() {
        let s = weekdays([TimeWindow(start: 60, end: 240)], on: [0]) // 01:00 to 04:00 clock time
        let end = s.currentWindowEnd(at: iso("2026-03-29T00:30:00Z"), in: amsterdam) // 01:30 CET
        XCTAssertEqual(end, iso("2026-03-29T02:00:00Z"), "04:00 CEST, only 2 real hours after 01:00 CET")
    }

    func testFallBackRepeatedHourIsOpenTwice() {
        // Sunday 2026-10-25: 03:00 CEST falls back to 02:00 CET. Window 02:00 to 03:00 clock time.
        let s = weekdays([TimeWindow(start: 120, end: 180)], on: [0])
        XCTAssertTrue(open(s, "2026-10-25T00:30:00Z"), "02:30 CEST")
        XCTAssertTrue(open(s, "2026-10-25T01:30:00Z"), "02:30 CET, same clock time again")
        XCTAssertFalse(open(s, "2026-10-25T02:00:00Z"), "03:00 CET")
        XCTAssertFalse(open(s, "2026-10-24T23:59:00Z"), "01:59 CEST")
    }

    func testFallBackNextOpenUsesFirstOccurrence() {
        let s = weekdays([TimeWindow(start: 150, end: 180)], on: [0])
        XCTAssertEqual(s.nextOpen(from: iso("2026-10-24T20:00:00Z"), in: amsterdam), iso("2026-10-25T00:30:00Z"))
    }

    func testOtherTimeZoneChangesWhichDayItIs() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let s = Schedule.default
        // Monday 2026-11-09 23:00Z is Tuesday 08:00 in Tokyo.
        XCTAssertTrue(s.isOpen(at: iso("2026-11-09T23:00:00Z"), in: tokyo))
        XCTAssertFalse(s.isOpen(at: iso("2026-11-09T23:00:00Z"), in: amsterdam))
    }

    // MARK: Normalization

    func testNormalizeKeepsAtMostThreeWindowsPerDay() {
        let many = (0..<5).map { TimeWindow(start: $0 * 120, end: $0 * 120 + 60) }
        let n = weekdays(many, on: [1]).normalized()
        XCTAssertEqual(n.days[1].count, 3)
    }

    func testNormalizeSnapsToFiveMinutesAndDropsEmptyWindows() {
        let n = weekdays([TimeWindow(start: 422, end: 1198), TimeWindow(start: 600, end: 600), TimeWindow(start: 700, end: 650)], on: [1]).normalized()
        XCTAssertEqual(n.days[1], [TimeWindow(start: 420, end: 1200)])
    }

    func testNormalizeMergesOverlappingAndTouchingWindows() {
        let n = weekdays([TimeWindow(start: 480, end: 720), TimeWindow(start: 720, end: 900), TimeWindow(start: 600, end: 650)], on: [2]).normalized()
        XCTAssertEqual(n.days[2], [TimeWindow(start: 480, end: 900)])
    }

    func testNormalizePadsToSevenDaysAndClampsToTheDay() {
        let n = Schedule(enabled: true, days: [[TimeWindow(start: -30, end: 2000)]]).normalized()
        XCTAssertEqual(n.days.count, 7)
        XCTAssertEqual(n.days[0], [TimeWindow(start: 0, end: 1440)])
    }

    func testDefaultScheduleIsMondayToFridaySevenToTwenty() {
        let d = Schedule.default
        XCTAssertEqual(d.days[0], [])
        XCTAssertEqual(d.days[6], [])
        for i in 1...5 { XCTAssertEqual(d.days[i], [TimeWindow(start: 420, end: 1200)]) }
        XCTAssertEqual(d, d.normalized())
    }
}
