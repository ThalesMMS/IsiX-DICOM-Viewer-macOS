//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Which autorouting rules run now and which wait for their hour, and how long.
///
/// Each activated rule is applied once per import. A rule with a schedule is
/// applied by itself when its time comes, so a schedule on one rule does not
/// apply the others again; the rules without one are applied together, once.
/// (Applying the whole list once per rule sent the same images again after
/// the routing queue, drained every ten seconds, had forgotten them.)
public enum RoutingSchedule {
    /// The rules to apply straight away, in their order.
    public static func immediateRules(in rules: [RoutingRule]) -> [RoutingRule] {
        rules.filter { $0.isActivated && !isScheduled($0) }
    }

    /// The rules that wait, in their order; each is applied by itself.
    public static func scheduledRules(in rules: [RoutingRule]) -> [RoutingRule] {
        rules.filter { $0.isActivated && isScheduled($0) }
    }

    /// Whether a rule's schedule can be worked out. A rule asking for a time
    /// window without both times runs now.
    public static func isScheduled(_ rule: RoutingRule) -> Bool {
        switch rule.scheduleType {
        case 1: return true
        case 2: return rule.fromTime != nil && rule.toTime != nil
        default: return false
        }
    }

    /// When a scheduled rule is applied to images that arrive at `date`.
    public struct Delay: Sendable, Hashable {
        /// Seconds from `date`; 0 or less is at once.
        public var seconds: Int64
        /// A time window whose times cannot be read: applied at once, and
        /// said so in the log.
        public var windowIsUnreadable: Bool
    }

    /// The delay of a scheduled rule: `delayTime` hours for schedule 1, the
    /// wait until the daily window opens for schedule 2.
    public static func delay(for rule: RoutingRule, at date: Date, calendar: Calendar = .current) -> Delay {
        if rule.scheduleType == 1 {
            return Delay(seconds: 3600 &* Int64(rule.delayTime), windowIsUnreadable: false)
        }
        if let delay = windowDelay(for: rule, at: date, calendar: calendar) {
            return Delay(seconds: Int64(delay), windowIsUnreadable: false)
        }
        return Delay(seconds: 0, windowIsUnreadable: true)
    }

    // MARK: - Time windows (scheduleType 2)
    //
    // A rule with scheduleType 2 routes only between its fromTime and its
    // toTime, every day. The window is worked out on seconds after midnight: a
    // window whose end comes before its start crosses midnight, and one already
    // over for today waits for tomorrow's start. The times are read in every
    // format the preference pane has written: its date picker's full date and
    // time in the user's locale, a former fixed format, and the "21:00" of a
    // new rule.

    static let secondsPerDay = 24 * 60 * 60

    /// The time of day `value` names, in seconds after midnight of
    /// `calendar`'s time zone; nil when it cannot be read.
    static func secondsOfDay(_ value: PropertyListValue?, calendar: Calendar = .current) -> Int? {
        switch value {
        case .date(let date)?:
            return secondsOfDay(date, calendar: calendar)
        case .string(let text)?:
            let text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            for formatter in timeFormatters(calendar) {
                if let parsed = formatter.date(from: text) {
                    return secondsOfDay(parsed, calendar: calendar)
                }
            }
            return nil
        default:
            return nil
        }
    }

    static func secondsOfDay(_ date: Date, calendar: Calendar) -> Int? {
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
    /// after midnight) is open: 0 inside it, bounds included.
    static func delayUntilWindow(from: Int, to: Int, now: Int) -> Int {
        let day = secondsPerDay
        let from = ((from % day) + day) % day, to = ((to % day) + day) % day, now = ((now % day) + day) % day
        let inside = from <= to ? (now >= from && now <= to) : (now >= from || now <= to)
        if inside { return 0 }
        return now < from ? from - now : from - now + day
    }

    /// The delay, in seconds, before a time-window rule is applied to images
    /// that arrive at `date`; nil when its times cannot be read.
    public static func windowDelay(for rule: RoutingRule, at date: Date, calendar: Calendar = .current) -> Int? {
        guard let from = secondsOfDay(rule.fromTime, calendar: calendar),
              let to = secondsOfDay(rule.toTime, calendar: calendar),
              let now = secondsOfDay(date, calendar: calendar) else { return nil }
        return delayUntilWindow(from: from, to: to, now: now)
    }
}
