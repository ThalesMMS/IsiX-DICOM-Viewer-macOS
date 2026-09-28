/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// A value of the query window with the way it is matched, turned into the
/// string of a C-FIND key by -filteredValue.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/QueryFilter.h> are those of the former class. The enums of the
/// former header (searchTypes, dateSearchTypes, dateWithinSearch, modalities,
/// studyState) stay in the compatibility header; the values this file switches
/// on are restated below.
@objc(QueryFilter)
public final class QueryFilter: NSObject {
    // enum searchTypes
    private static let searchContains: Int32 = 0
    private static let searchStartsWith: Int32 = 1
    private static let searchEndsWith: Int32 = 2
    private static let searchExactMatch: Int32 = 3
    // enum dateSearchTypes
    private static let searchToday: Int32 = 4
    private static let searchYesterday: Int32 = 5
    private static let searchBefore: Int32 = 6
    private static let searchAfter: Int32 = 7
    private static let searchWithin: Int32 = 8
    private static let searchExactDate: Int32 = 9
    // enum dateWithinSearch
    private static let searchWithinToday: Int32 = 10
    private static let searchWithinLast2Days: Int32 = 11
    private static let searchWithinLastWeek: Int32 = 12
    private static let searchWithinLast2Weeks: Int32 = 13
    private static let searchWithinLastMonth: Int32 = 14
    private static let searchWithinLast2Months: Int32 = 15
    private static let searchWithinLast3Months: Int32 = 16
    private static let searchWithinLastYear: Int32 = 17

    /// -key / -setKey:, retained.
    @objc public var key: Any!
    /// -object / -setObject:, retained.
    @objc public var object: Any!
    /// -searchType / -setSearchType:.
    @objc public var searchType: Int32

    @objc(queryFilter)
    public class func queryFilter() -> QueryFilter! {
        return QueryFilter(object: nil, ofSearchType: 0, forKey: nil)
    }

    @objc(queryFilterWithObject:ofSearchType:forKey:)
    public class func queryFilter(withObject object: Any!, ofSearchType searchType: Int32, forKey key: Any!) -> QueryFilter! {
        return QueryFilter(object: object, ofSearchType: searchType, forKey: key)
    }

    @objc(initWithObject:ofSearchType:forKey:)
    public init(object: Any!, ofSearchType searchType: Int32, forKey key: Any!) {
        self.object = object
        self.searchType = searchType
        self.key = key
        super.init()
    }

    /// -init, which NSObject gave the former class: no object, no key,
    /// searchContains.
    public override convenience init() {
        self.init(object: nil, ofSearchType: 0, forKey: nil)
    }

    // MARK: -

    /// `[NSString stringWithFormat:format, _object]`: nil prints as "(null)".
    private func formatted(_ format: String) -> String {
        guard let object = object else {
            return format.replacingOccurrences(of: "%@", with: "(null)")
        }
        if let value = (object as AnyObject) as? NSObject {
            return String(format: format, value)
        }
        return format.replacingOccurrences(of: "%@", with: String(describing: object))
    }

    /// `[_object descriptionWithCalendarFormat:format timeZone:nil locale:nil]`:
    /// nil for no object and, as a message to an object that is no date, the
    /// same unrecognized-selector exception.
    private func calendarDescription(_ format: String) -> String? {
        guard let object = object else { return nil }
        if let date = object as? NSDate {
            return date.description(withCalendarFormat: format, timeZone: nil, locale: nil)
        }
        (object as AnyObject as? NSObject)?.doesNotRecognizeSelector(
            #selector(NSDate.description(withCalendarFormat:timeZone:locale:)))
        return nil
    }

    /// NSString, not String: an exact match returns the object itself, as the
    /// former method did, without a bridging copy.
    @objc(filteredValue)
    public func filteredValue() -> NSString! {
        switch searchType {
        case Self.searchContains:
            return formatted("*%@*") as NSString // contains

        case Self.searchStartsWith:
            return formatted("%@*") as NSString // searchStartsWith

        case Self.searchEndsWith:
            return formatted("*%@") as NSString // searchEndsWith

        case Self.searchExactMatch:
            if object is NSDate { // need to convert dates to strings
                return calendarDescription("%Y%m%d") as NSString?
            } else {
                // Returned as it is, whatever its class, as the former -filteredValue did.
                guard let object = object else { return nil }
                return unsafeBitCast(object as AnyObject, to: NSString.self)
            }

        case Self.searchToday:
            return calendarDescription("%Y%m%d-%Y%m%d") as NSString? // today

        case Self.searchYesterday:
            return calendarDescription("%Y%m%d-%Y%m%d") as NSString? // Yesterday

        case Self.searchBefore:
            return NSString(format: "-%@", describeNil(calendarDescription("%Y%m%d"))) // before

        case Self.searchAfter:
            if UserDefaults.standard.bool(forKey: "DICOMQueryAllowFutureQuery") {
                return NSString(format: "%@-", describeNil(calendarDescription("%Y%m%d"))) // after
            } else {
                return NSString(format: "%@-%@", describeNil(calendarDescription("%Y%m%d")),
                              describeNil(DCMCalendarDate().description(withCalendarFormat: "%Y%m%d", timeZone: nil, locale: nil))) // after
            }

        case Self.searchWithin:
            return withinDateString() as NSString? // within

        case Self.searchExactDate:
            return calendarDescription("%Y%m%d-%Y%m%d") as NSString?

        default:
            return nil
        }
    }

    /// A nil string argument of `%@` prints as "(null)".
    private func describeNil(_ string: String?) -> NSString {
        return (string ?? "(null)") as NSString
    }

    /// `[_object intValue]`: 0 for no object.
    private func objectIntValue() -> Int32 {
        guard let object = object else { return 0 }
        if let string = object as? NSString {
            return string.intValue
        }
        if let number = object as? NSNumber {
            return number.int32Value
        }
        (object as AnyObject as? NSObject)?.doesNotRecognizeSelector(#selector(getter: NSNumber.intValue))
        return 0
    }

    @objc(withinDateString)
    public func withinDateString() -> String! {
        let endDate = DCMCalendarDate()
        var startDate: NSDate? = nil // an NSCalendarDate, a type Swift does not name

        let today = endDate.dateString()

        switch objectIntValue() {
        case Self.searchWithinLast2Days:
            startDate = endDate.addingYears(0, months: 0, days: -1, hours: 0, minutes: 0, seconds: 0)
            // last 2 days
        case Self.searchWithinLastWeek:
            startDate = endDate.addingYears(0, months: 0, days: -7, hours: 0, minutes: 0, seconds: 0)
        case Self.searchWithinLast2Weeks:
            startDate = endDate.addingYears(0, months: 0, days: -14, hours: 0, minutes: 0, seconds: 0)
        case Self.searchWithinLastMonth:
            startDate = endDate.addingYears(0, months: -1, days: 0, hours: 0, minutes: 0, seconds: 0)
        case Self.searchWithinLast2Months:
            startDate = endDate.addingYears(0, months: -2, days: 0, hours: 0, minutes: 0, seconds: 0)
        case Self.searchWithinLast3Months:
            startDate = endDate.addingYears(0, months: -3, days: 0, hours: 0, minutes: 0, seconds: 0)
        case Self.searchWithinLastYear:
            startDate = endDate.addingYears(-1, months: 0, days: 0, hours: 0, minutes: 0, seconds: 0)
        default: // and searchWithinToday
            return today // today
        }

        let start = (DCMCalendarDate.dicomDate(with: startDate as Date?) as? DCMCalendarDate)?.dateString()
        let dateRange: String
        if UserDefaults.standard.bool(forKey: "DICOMQueryAllowFutureQuery") {
            dateRange = String(format: "%@-", describeNil(start))
        } else {
            dateRange = String(format: "%@-%@", describeNil(start), describeNil(DCMCalendarDate().dateString()))
        }
        return dateRange
    }
}
