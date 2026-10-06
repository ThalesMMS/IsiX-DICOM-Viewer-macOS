//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Which autorouting rules run now and which wait for their hour.
///
/// `-applyRoutingRules:toImages:` used to walk the rules and, for every
/// activated one, hand `-__applyRoutingRules:` **the whole list**. With two
/// rules every rule was applied twice; with five, five times. A rule carrying a
/// schedule did it again when its delay elapsed — for every other rule too, not
/// just its own.
///
/// The send queue de-duplicates against what is *currently* queued, so the
/// repeats were invisible while the first copy was still there. The routing
/// timer drains that queue every ten seconds, and after it does, the same images
/// are queued again and sent again: an automatic re-send with no new instance
/// behind it.
///
/// Partitioning the rules is the part that was wrong, so it is the part that is
/// here and can be tested.
@objc(HorosRoutingSchedule)
public final class RoutingSchedule: NSObject {
    /// A rule with no `activated` key is activated, as the routing treats it.
    @objc(isActivated:)
    public static func isActivated(_ rule: [String: Any]) -> Bool {
        guard let activated = rule["activated"] else { return true }
        if let number = activated as? NSNumber { return number.boolValue }
        if let text = activated as? String { return text != "0" && !text.isEmpty }
        return true
    }

    /// `0` and a missing key both mean "as soon as the images arrive".
    @objc(scheduleTypeOf:)
    public static func scheduleType(of rule: [String: Any]) -> Int {
        return (rule["scheduleType"] as? NSNumber)?.intValue
            ?? Int(rule["scheduleType"] as? String ?? "") ?? 0
    }

    /// Whether a rule's schedule can actually be worked out. A rule asking for a
    /// time window without the times is not scheduled; it runs now, which is
    /// what the routing already did with it.
    static func isScheduled(_ rule: [String: Any]) -> Bool {
        switch scheduleType(of: rule) {
        case 1:
            return true
        case 2:
            return rule["fromTime"] != nil && rule["toTime"] != nil
        default:
            return false
        }
    }

    /// The rules to apply straight away — as one list, applied once.
    @objc(immediateRulesIn:)
    public static func immediateRules(in rules: [[String: Any]]) -> [[String: Any]] {
        return rules.filter { isActivated($0) && !isScheduled($0) }
    }

    /// The rules that wait. Each is applied by itself when its time comes, so a
    /// schedule on one rule does not re-apply the others.
    @objc(scheduledRulesIn:)
    public static func scheduledRules(in rules: [[String: Any]]) -> [[String: Any]] {
        return rules.filter { isActivated($0) && isScheduled($0) }
    }

    // MARK: - Time windows (scheduleType 2)
    //
    // A rule with scheduleType 2 routes only between its fromTime and its toTime,
    // every day. The former computation did not add up:
    //
    // - the day added to toTime when the window crosses midnight went to
    //   -dateByAddingTimeInterval:, whose result was thrown away, so a window
    //   such as 21:00-06:00 was taken for already over at 23:00 and at 01:00;
    // - once the window was over, it waited |fromTime - now| plus a day, which
    //   is now - fromTime plus a day: 12:00 for an 08:00-10:00 window came out as
    //   28 hours, the next day at 16:00, outside the window;
    // - the current time was written with "%2ld", padding with spaces, and read
    //   back with a formatter;
    // - the times were read with one format, "EEEE, dd MMMM yyyy HH:mm:ss zzzz",
    //   which is not what the preference pane's date picker writes today
    //   ("Thursday, January 1, 1970 at 9:00:00 PM ..."), nor the "21:00" of a
    //   new rule. Unread, every comparison was with nil and the rule waited a day.
    //
    // The window is now worked out on seconds after midnight.

    static let secondsPerDay = 24 * 60 * 60

    /// The time of day `value` names, in seconds after midnight of `calendar`'s
    /// time zone: a date, or a string as the preference pane stored it - its
    /// date picker's full date and time, the former fixed format, or "HH:mm"
    /// and "HH:mm:ss". Nil when it cannot be read.
    static func secondsOfDay(_ value: Any?, calendar: Calendar = .current) -> Int? {
        var date = value as? Date
        if date == nil, let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            for formatter in timeFormatters(calendar) {
                if let parsed = formatter.date(from: text) {
                    date = parsed
                    break
                }
            }
        }
        guard let date else { return nil }
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return hour * 3600 + minute * 60 + (components.second ?? 0)
    }

    private static func timeFormatters(_ calendar: Calendar) -> [DateFormatter] {
        func formatter(_ configure: (DateFormatter) -> Void) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            configure(formatter)
            return formatter
        }
        return [
            // NSDatePicker's -stringValue, in the user's locale.
            formatter { $0.dateStyle = .full; $0.timeStyle = .full },
            formatter { $0.dateStyle = .full; $0.timeStyle = .long },
            formatter { $0.dateStyle = .full; $0.timeStyle = .medium },
            // The format the routing read before.
            formatter { $0.dateFormat = "EEEE, dd MMMM yyyy HH:mm:ss zzzzzzzzz" },
            formatter { $0.locale = Locale(identifier: "en_US_POSIX"); $0.dateFormat = "EEEE, dd MMMM yyyy HH:mm:ss zzzzzzzzz" },
            formatter { $0.locale = Locale(identifier: "en_US_POSIX"); $0.dateFormat = "HH:mm:ss" },
            formatter { $0.locale = Locale(identifier: "en_US_POSIX"); $0.dateFormat = "HH:mm" },
        ]
    }

    /// Seconds from `now` until the daily window from `from` to `to` (seconds
    /// after midnight) is open: 0 inside it, bounds included. A window whose end
    /// comes before its start crosses midnight.
    static func delayUntilWindow(from: Int, to: Int, now: Int) -> Int {
        let day = secondsPerDay
        let from = ((from % day) + day) % day, to = ((to % day) + day) % day, now = ((now % day) + day) % day
        let inside = from <= to ? (now >= from && now <= to) : (now >= from || now <= to)
        if inside { return 0 }
        return now < from ? from - now : from - now + day
    }

    /// The delay, in seconds, before a time-window rule is applied to images
    /// that arrive at `date`. Nil when its times cannot be read: such a rule is
    /// not scheduled, as one without times is not.
    @objc(windowDelayForRule:at:)
    public static func windowDelay(for rule: [String: Any], at date: Date) -> NSNumber? {
        let calendar = Calendar.current
        guard let from = secondsOfDay(rule["fromTime"], calendar: calendar),
              let to = secondsOfDay(rule["toTime"], calendar: calendar),
              let now = secondsOfDay(date, calendar: calendar) else { return nil }
        return NSNumber(value: delayUntilWindow(from: from, to: to, now: now))
    }
}
