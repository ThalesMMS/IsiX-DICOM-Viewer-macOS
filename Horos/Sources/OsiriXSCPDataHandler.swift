/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreData
import Foundation

/** \brief  Finds the appropriate study/series/image for Q/R

 The implementation of OsiriXSCPDataHandler, declared in
 OsiriXSCPDataHandler.h: the class of the Horos and OsiriX plugin SDK through
 which the DICOM listener read the database. The listener asks the
 application's own rules now, so that a handler finds and moves nothing; the
 messages of the SDK that carry DCMTK's C++ types are answered in the DCMTK
 adapter.
 */
@objc @implementation extension OsiriXSCPDataHandler {
    // The instance variables of the SDK, with its types: a plugin built for
    // it binds each name when it loads. The title's name here is another
    // because the property callingAET answers a Swift string. No find and no
    // move is prepared through this class: the others are nil and zero.
    final var findArray: NSArray?
    final var specificCharacterSet: NSString?
    final var findEnumerator: NSEnumerator?
    final var findEnumeratorIndex: Int32 = 0
    final var horos_callingAET: NSString?
    final var context: NSManagedObjectContext?
    final var numberMoving: Int32 = 0
    final var encoding: UInt = 0
    final var moveArrayEnumerator: Int32 = 0
    final var moveArray: NSArray?
    final var logDictionary: NSMutableDictionary?, findTemplate: NSMutableDictionary?
    // Declared only by the header of an older SDK, whose handler kept the
    // files of a move as C strings and a C record of the log for each: their
    // number and the records. No move is prepared here, as above.
    final var moveArraySize: Int32 = 0
    final var logFiles: UnsafeMutablePointer<logStruct>?

    var callingAET: String! {
        get { horos_callingAET as String? }
        set { horos_callingAET = newValue as NSString? }
    }

    override init() {
        super.init()
    }

    /// A new handler the caller owns: the selector is of the alloc family,
    /// whose methods answer an object of the receiving class, retained.
    /// NSObject's -init, by message, is the one a metatype may construct with.
    @objc(allocRequestDataHandler) class func allocRequest() -> Self! {
        (self as NSObject.Type).init() as? Self
    }

    func end(ofDay day: Any!) -> TimeInterval {
        guard let start = Self.midnight(of: day) else { return 0 }
        // 24 hours, not a calendar day, as the SDK's class added them.
        return start.timeIntervalSinceReferenceDate + 24 * 3600
    }

    func start(ofDay day: Any!) -> TimeInterval {
        Self.midnight(of: day)?.timeIntervalSinceReferenceDate ?? 0
    }

    func findMatchFound() -> Bool {
        Self.inert("-findMatchFound")
        return false
    }

    func moveMatchFound() -> Int32 {
        Self.inert("-moveMatchFound")
        return 0
    }

    func cancelMove() {
        Self.inert("-cancelMove")
    }

    private static func inert(_ selector: String) {
        FormerSDKFacade.inert("OsiriXSCPDataHandler", selector,
                              because: "the DICOM listener reads the database through the application's own rules")
    }

    /// Midnight, in the default time zone, of the day `day` falls on in its
    /// own time zone; nil for what is not a date. A calendar date has a time
    /// zone of its own, which a plain date has not: the default one is its.
    private static func midnight(of day: Any?) -> Date? {
        guard let date = day as? NSDate else { return nil }
        var own = Calendar(identifier: .gregorian)
        // NSCalendarDate, which Swift cannot name, and the application's
        // DICOM calendar date both answer -timeZone.
        let timeZone = NSSelectorFromString("timeZone")
        if date.responds(to: timeZone), let zone = date.perform(timeZone)?.takeUnretainedValue() as? TimeZone {
            own.timeZone = zone
        }
        let day = own.dateComponents([.year, .month, .day], from: date as Date)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = NSTimeZone.default
        return local.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }
}
