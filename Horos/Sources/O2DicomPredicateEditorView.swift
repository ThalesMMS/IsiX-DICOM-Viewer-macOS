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

import AppKit

/// The tags (DICOM dictionary plus the database's own), built once, as the
/// former static tagsCache.
private var tagsCache: NSMutableArray?
/// The tags pop-up's items, built by the first view and copied by each, as the
/// former static menuItemsCache.
private var menuItemsCache: NSMutableArray?
/// The former dispatch_once of -initWithFrame: that warns about CS tags with no
/// known values.
private var codeStringsWarningDone = false

private let kvoContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

private let O2DicomPredicateEditorSortTagsByName = 0
private let O2DicomPredicateEditorSortTagsByTag = 1

// O2TimeTag: runtime only values, negative so they are not taken for
// NSPredicateOperatorType values. O21Year was 12 until #752.
private let O2Today = -1
private let O2Yesterday = -2
private let O2Within = -3
private let O21Hour = -4
private let O26Hours = -5
private let O212Hours = -6
private let O21Day = O2Today
private let O22Days = -7
private let O21Week = -8
private let O21Month = -9
private let O22Months = -10
private let O23Months = -11
private let O21Year = -12
private let O2DayBeforeYesterday = -13

private let O2VarToday = "NSDATE_TODAY"
private let O2VarYesterday = "NSDATE_YESTERDAY"
private let O2Var1Hour = "NSDATE_LASTHOUR"
private let O2Var6Hours = "NSDATE_LAST6HOURS"
private let O2Var12Hours = "NSDATE_LAST12HOURS"
private let O2Var1Day = "NSDATE_TODAY" // O2VarToday
private let O2Var2Days = "NSDATE_2DAYS"
private let O2Var1Week = "NSDATE_WEEK"
private let O2Var1Month = "NSDATE_MONTH"
private let O2Var2Months = "NSDATE_2MONTHS"
private let O2Var3Months = "NSDATE_3MONTHS"
private let O2Var1Year = "NSDATE_YEAR"

/// LegacyTimeKey(str): [str substringFromIndex:7].
private func legacyTimeKey(_ str: String) -> String {
    return (str as NSString).substring(from: 7)
}

/// UnLegacyTimeKey(str): [@"NSDATE_" stringByAppendingString:str], which
/// raised NSInvalidArgumentException for nil; this raises the same.
private func unLegacyTimeKey(_ str: String?) -> String {
    guard let str = str else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSCFConstantString stringByAppendingString:]: nil argument", userInfo: nil).raise()
        return ""
    }
    return "NSDATE_" + str
}

/// The value representations of DCMAttribute.h (O2ValueRepresentation).
private enum VR {
    static let AE = UInt(DCM_AE), AS = UInt(DCM_AS), AT = UInt(DCM_AT), CS = UInt(DCM_CS)
    static let DA = UInt(DCM_DA), DS = UInt(DCM_DS), DT = UInt(DCM_DT), FL = UInt(DCM_FL)
    static let FD = UInt(DCM_FD), IS = UInt(DCM_IS), LO = UInt(DCM_LO), LT = UInt(DCM_LT)
    static let OB = UInt(DCM_OB), OF = UInt(DCM_OF), OW = UInt(DCM_OW), PN = UInt(DCM_PN)
    static let SH = UInt(DCM_SH), SL = UInt(DCM_SL), SQ = UInt(DCM_SQ), SS = UInt(DCM_SS)
    static let ST = UInt(DCM_ST), TM = UInt(DCM_TM), UI = UInt(DCM_UI), UL = UInt(DCM_UL)
    static let UN = UInt(DCM_UN), US = UInt(DCM_US), UT = UInt(DCM_UT)
}

/// DLog of N2Debug.h: NSLog in a DEBUG build, otherwise only while N2Debug is
/// active.
private func o2DicomPredicateEditorViewDLog(_ format: String, _ arguments: CVarArg...) {
    #if DEBUG
    withVaList(arguments) { NSLogv(format, $0) }
    #else
    if N2Debug.isActive() { withVaList(arguments) { NSLogv(format, $0) } }
    #endif
}

// MARK: - Objective-C messaging

// The former code sent chains of messages to whatever the predicates held:
// a message to nil answered nil, NO or 0, and one the receiver did not
// implement (-variable of a constant expression, -keyPath of a compound
// predicate, -objectAtIndex: past the end...) raised. setPredicate: lets that
// exception reach its caller and matchForPredicate: catches it, so these
// helpers send the same messages, with the same answers and exceptions.

/// [object selector] for a message answering an object.
private func objcSend(_ object: Any?, _ selector: Selector) -> Any? {
    guard let object = object else { return nil }
    return (object as AnyObject).perform(selector)?.takeUnretainedValue()
}

/// [object variable]
private func objcVariable(_ object: Any?) -> String? {
    return objcSend(object, NSSelectorFromString("variable")) as? String
}

/// [object constantValue]
private func objcConstantValue(_ object: Any?) -> Any? {
    return objcSend(object, NSSelectorFromString("constantValue"))
}

/// [object keyPath]
private func objcKeyPath(_ object: Any?) -> String? {
    return objcSend(object, NSSelectorFromString("keyPath")) as? String
}

/// [predicate subpredicates], the array itself: -objectAtIndex: past its end
/// raises, as before, where an array bridged from Swift would trap.
private func objcSubpredicates(_ predicate: NSCompoundPredicate) -> NSArray {
    return objcSend(predicate, #selector(getter: NSCompoundPredicate.subpredicates)) as! NSArray
}

/// [object objectAtIndex:index]. The arrays come from Objective-C unbridged
/// (-subpredicates, -collection, -arguments), so past the end it raises.
private func objcObjectAtIndex(_ array: Any?, at index: Int) -> Any? {
    guard let array = array else { return nil }
    guard let nsArray = array as? NSArray else {
        (array as AnyObject).doesNotRecognizeSelector?(#selector(NSArray.object(at:)))
        return nil
    }
    return nsArray.object(at: index)
}

/// [object predicateOperatorType]
private func objcPredicateOperatorType(_ object: Any?) -> Int {
    guard let object = object else { return 0 }
    guard let predicate = object as? NSComparisonPredicate else {
        (object as AnyObject).doesNotRecognizeSelector?(#selector(getter: NSComparisonPredicate.predicateOperatorType))
        return 0
    }
    return Int(bitPattern: predicate.predicateOperatorType.rawValue)
}

/// [object isEqualToString:string]
private func objcIsEqualToString(_ object: Any?, _ string: String?) -> Bool {
    guard let object = object else { return false }
    guard let nsString = object as? NSString else {
        (object as AnyObject).doesNotRecognizeSelector?(#selector(NSString.isEqual(to:)))
        return false
    }
    guard let string = string else { return false }
    return nsString.isEqual(to: string)
}

/// [object isKindOfClass:cls], nil answering NO.
private func objcIsKind(_ object: Any?, of cls: AnyClass) -> Bool {
    guard let object = object else { return false }
    return (object as AnyObject).isKind(of: cls)
}

/// An object stored as the property's declared class without a check, as
/// Objective-C stored whatever -constantValue answered.
private func unchecked<T: AnyObject>(_ object: Any?, as type: T.Type) -> T? {
    guard let object = object else { return nil }
    return unsafeBitCast(object as AnyObject, to: T.self)
}

/// [NSExpression expressionForKeyPath:], which takes nil.
private func keyPathExpression(_ keyPath: String?) -> NSExpression {
    guard let keyPath = keyPath else {
        return (NSExpression.self as AnyObject).perform(NSSelectorFromString("expressionForKeyPath:"), with: nil)!.takeUnretainedValue() as! NSExpression
    }
    return NSExpression(forKeyPath: keyPath)
}

/// [NSExpression expressionForVariable:], which takes nil.
private func variableExpression(_ variable: String?) -> NSExpression {
    guard let variable = variable else {
        return (NSExpression.self as AnyObject).perform(NSSelectorFromString("expressionForVariable:"), with: nil)!.takeUnretainedValue() as! NSExpression
    }
    return NSExpression(forVariable: variable)
}

/// The comparison of an operator tag, passed on as the NSUInteger it was cast to.
private func comparison(_ left: NSExpression, _ right: NSExpression, _ type: Int, _ options: NSComparisonPredicate.Options) -> NSComparisonPredicate {
    return NSComparisonPredicate(leftExpression: left, rightExpression: right, modifier: .direct,
                                 type: NSComparisonPredicate.Operator(rawValue: UInt(bitPattern: type))!, options: options)
}

/// [O2DicomPredicateEditorCodeStrings codeStringsForTag:tag], as the
/// NSDictionary it answers. Bridging it to a Swift dictionary would lose the
/// order of its keys, which numbers the code-string pop-up's items.
private func codeStrings(for tag: DCMAttributeTag?) -> NSDictionary? {
    return (O2DicomPredicateEditorCodeStrings.self as AnyObject).perform(NSSelectorFromString("codeStringsForTag:"), with: tag)?.takeUnretainedValue() as? NSDictionary
}

/// The first date of "KeyPath BETWEEN {date, date}", which the "is" row of a
/// DA or DT tag writes (#752); nil for any other comparison.
private func isDateValue(of predicate: NSComparisonPredicate) -> NSDate? {
    guard predicate.predicateOperatorType == .between,
          let collection = predicate.collection() as? [NSExpression], collection.count == 2,
          collection.allSatisfy({ $0.expressionType == .constantValue && $0.constantValue is NSDate }) else {
        return nil
    }
    return collection[0].constantValue as? NSDate
}

/// The row view of O2DicomPredicateEditor: a tag pop-up, then an operator and
/// a value control that suit the tag's value representation. It answers the
/// predicate of the row and shows the one it is given.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/O2DicomPredicateEditorView.h> are those of the former class. Its
/// -tag and -setTag:, whose getter has the selector of NSView's -tag with
/// another type, are a category in O2DicomPredicateEditorView+CAPI.m.
@objc(O2DicomPredicateEditorView)
public final class O2DicomPredicateEditorView: NSView, NSMenuDelegate, NSTextFieldDelegate {
    private var _reviewing = false
    private var _tagsSortKey = 0
    private var _menuItems: NSMutableArray!
    // Whether -initWithFrame: registered the key-value observers that deinit
    // removes. A view decoded by -initWithCoder: had none, as before.
    private var observing = false

    // views
    private var _tagsPopUp: O2DicomPredicateEditorPopUpButton!
    private var _operatorsPopUp: O2DicomPredicateEditorPopUpButton!
    private var _stringValueTextField: NSTextField!
    private var _numberValueTextField: NSTextField!
    private var _datePicker: O2DicomPredicateEditorDatePicker!
    private var _timePicker: O2DicomPredicateEditorDatePicker!
    private var _dateTimePicker: O2DicomPredicateEditorDatePicker!
    private var _withinPopUp: O2DicomPredicateEditorPopUpButton!
    private var _codeStringPopUp: O2DicomPredicateEditorPopUpButton!
    private var _isLabel: NSTextField!

    // MARK: Values

    /// Atomic in the former header. Only the main thread uses it.
    @objc public dynamic var tagsSortKey: Int {
        get { return _tagsSortKey }
        set { _tagsSortKey = newValue }
    }

    /// Retained and atomic in the former header. The key the view observes
    /// ("tag") and the tags pop-up's "selectedTag" depend on it.
    @objc(DCMAttributeTag) public dynamic var dcmAttributeTag: DCMAttributeTag!

    /// NSPredicateOperatorType, or one of the O2TimeTag values.
    @objc(operator) public dynamic var operatorTag: Int = 0

    /// Retained. It holds what the predicate's constant was, as before, even
    /// when that was not a string.
    @objc public dynamic var stringValue: NSString!

    /// Retained and atomic in the former header.
    @objc public dynamic var numberValue: NSNumber!

    /// Retained and atomic in the former header.
    @objc public dynamic var dateValue: NSDate!

    /// An O2TimeTag. Atomic in the former header.
    @objc public dynamic var within: Int = 0

    /// The item of the code-string pop-up, from 1. Atomic in the former header.
    @objc public dynamic var codeStringTag: Int = 0

    // MARK: Time keys

    @objc(timeKeys)
    class func timeKeys() -> NSArray {
        return [O2Var1Hour, O2Var6Hours, O2Var12Hours, O2Var1Day, O2Var2Days, O2Var1Week, O2Var1Month, O2Var2Months, O2Var3Months, O2Var1Year] as NSArray
    }

    @objc(legacyTimeKeys)
    class func legacyTimeKeys() -> NSArray {
        let legacyTimeKeys = NSMutableArray()
        for case let key as String in timeKeys() {
            legacyTimeKeys.add(legacyTimeKey(key))
        }
        return legacyTimeKeys
    }

    @objc(timeTagFromKey:)
    class func timeTag(fromKey key: String!) -> Int {
        if key == O2Var1Day { return O21Day }
        if key == O2Var2Days { return O22Days }
        if key == O2Var1Week { return O21Week }
        if key == O2Var1Month { return O21Month }
        if key == O2Var2Months { return O22Months }
        if key == O2Var3Months { return O23Months }
        if key == O2Var1Year { return O21Year }
        if key == O2Var1Hour { return O21Hour }
        if key == O2Var6Hours { return O26Hours }
        if key == O2Var12Hours { return O212Hours }

        return 0
    }

    @objc(timeKeyFromTag:)
    class func timeKey(fromTag tk: Int) -> String! {
        switch tk {
        case O21Day: return O2Var1Day
        case O22Days: return O2Var2Days
        case O21Week: return O2Var1Week
        case O21Month: return O2Var1Month
        case O22Months: return O2Var2Months
        case O23Months: return O2Var3Months
        case O21Year: return O2Var1Year
        case O21Hour: return O2Var1Hour
        case O26Hours: return O2Var6Hours
        case O212Hours: return O2Var12Hours
        case O2Yesterday: return O2VarYesterday
        case O2DayBeforeYesterday: return O2Var2Days
        case O2Within: return nil
        default: return nil
        }
    }

    @objc(valueRepresentationFromVR:)
    class func valueRepresentation(fromVR vr: String!) -> UInt {
        guard let vr = vr else { return 0 }
        switch vr {
        case "AE": return UInt(DCM_AE)
        case "AS": return UInt(DCM_AS)
        case "AT": return UInt(DCM_AT)
        case "CS": return UInt(DCM_CS)
        case "DA": return UInt(DCM_DA)
        case "DS": return UInt(DCM_DS)
        case "DT": return UInt(DCM_DT)
        case "FL": return UInt(DCM_FL)
        case "FD": return UInt(DCM_FD)
        case "IS": return UInt(DCM_IS)
        case "LO": return UInt(DCM_LO)
        case "LT": return UInt(DCM_LT)
        case "OB": return UInt(DCM_OB)
        case "OF": return UInt(DCM_OF)
        case "OW": return UInt(DCM_OW)
        case "PN": return UInt(DCM_PN)
        case "SH": return UInt(DCM_SH)
        case "SL": return UInt(DCM_SL)
        case "SQ": return UInt(DCM_SQ)
        case "SS": return UInt(DCM_SS)
        case "ST": return UInt(DCM_ST)
        case "TM": return UInt(DCM_TM)
        case "UI": return UInt(DCM_UI)
        case "UL": return UInt(DCM_UL)
        case "UN": return UInt(DCM_UN)
        case "US": return UInt(DCM_US)
        case "UT": return UInt(DCM_UT)
        default: return 0
        }
    }

    // MARK: Life cycle

    public override init(frame: NSRect) {
        super.init(frame: frame)

        var mi: NSMenuItem
        var menu: NSMenu

        // tags pop-up

        _tagsPopUp = O2DicomPredicateEditorPopUpButton(frame: NSZeroRect, pullsDown: false)
        _tagsPopUp.bezelStyle = .roundRect
        _tagsPopUp.cell?.controlSize = .small
        _tagsPopUp.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        _tagsPopUp.autoenablesItems = false
        _tagsPopUp.noSelectionLabel = NSLocalizedString("Select a Tag...", comment: "")
        _tagsPopUp.n2mode = true

        NotificationCenter.default.addObserver(self, selector: #selector(_observePopUpButtonWillPopUpNotification(_:)), name: NSPopUpButton.willPopUpNotification, object: _tagsPopUp)

        menu = NSMenu(title: "")
        _tagsPopUp.contextualMenu = menu
        menu.delegate = self
        mi = menu.addItem(withTitle: NSLocalizedString("Sort by Description", comment: ""), action: #selector(_contextualMenuSortTags(_:)), keyEquivalent: "")
        mi.tag = O2DicomPredicateEditorSortTagsByName
        mi.target = self
        mi = menu.addItem(withTitle: NSLocalizedString("Sort by Tag", comment: ""), action: #selector(_contextualMenuSortTags(_:)), keyEquivalent: "")
        mi.tag = O2DicomPredicateEditorSortTagsByTag
        mi.target = self

        menu = NSMenu(title: "")
        _tagsPopUp.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false

        if menuItemsCache == nil {
            let cache = NSMutableArray()
            menuItemsCache = cache
            for case let tag as DCMAttributeTag in tags {
                let title: String
                if tag.isKind(of: O2DicomPredicateEditorDCMAttributeTag.self) {
                    title = tag.description
                } else {
                    title = String(format: "(%04x,%04x) %@", tag.group, tag.element, (Self._transformTagName(tag.name) ?? "(null)") as NSString)
                }

                let mi = menu.addItem(withTitle: title, action: nil, keyEquivalent: "") // @selector(_setTag:)

                mi.representedObject = tag
                mi.tag = Self.tag(for: tag)

                cache.add(mi)
            }

            cache.sort(comparator: { (item1, item2) -> ComparisonResult in
                let mi1 = item1 as! NSMenuItem, mi2 = item2 as! NSMenuItem
                if mi1.isEnabled != mi2.isEnabled {
                    if !mi1.isEnabled {
                        return .orderedDescending
                    } else {
                        return .orderedAscending
                    }
                }

                let obj1 = mi1.representedObject as? DCMAttributeTag
                let obj2 = mi2.representedObject as? DCMAttributeTag

                if obj1 == nil {
                    if obj2 == nil {
                        return .orderedSame
                    } else {
                        return .orderedAscending
                    }
                } else if obj2 == nil {
                    return .orderedDescending
                }

                // by tag
                if self._tagsSortKey == O2DicomPredicateEditorSortTagsByTag {
                    let t1 = Self.tag(for: obj1)
                    let t2 = Self.tag(for: obj2)
                    if t1 < t2 {
                        return .orderedAscending
                    }
                    if t1 > t2 {
                        return .orderedDescending
                    }
                }

                // by name
                guard let name1 = Self._transformTagName(obj1!.name) as NSString? else { return .orderedSame }
                return name1.caseInsensitiveCompare(Self._transformTagName(obj2!.name) ?? "")
            })
        }

        _menuItems = NSMutableArray(array: menuItemsCache! as [AnyObject], copyItems: true)

        if !codeStringsWarningDone {
            codeStringsWarningDone = true
            for case let tag as DCMAttributeTag in tags {
                if tag.vr == "CS" {
                    let csd = codeStrings(for: tag)
                    if (csd?.count ?? 0) == 0 && objcIsEqualToString(Self._transformTagName(tag.name), tag.name) {
                        o2DicomPredicateEditorViewDLog("Warning: no known values for %@", tag)
                    }
                }
            }
        }

        _tagsPopUp.bind(NSBindingName("selectedTag"), to: self, withKeyPath: "selectedTag", options: [.validatesImmediately: NSNumber(value: true)])

        _observePopUpButtonWillPopUpNotification(nil)

        // operators pop-up

        _operatorsPopUp = O2DicomPredicateEditorPopUpButton(frame: NSZeroRect, pullsDown: false)
        _operatorsPopUp.bezelStyle = .roundRect
        _operatorsPopUp.cell?.controlSize = .small
        _operatorsPopUp.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        _operatorsPopUp.autoenablesItems = false

        menu = NSMenu(title: "")
        _operatorsPopUp.menu = menu

        // for strings: NSContainsPredicateOperatorType, NSBeginsWithPredicateOperatorType, NSEndsWithPredicateOperatorType, NSEqualToPredicateOperatorType
        mi = menu.addItem(withTitle: NSLocalizedString("contains", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = Int(NSComparisonPredicate.Operator.contains.rawValue)
        mi = menu.addItem(withTitle: NSLocalizedString("begins with", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = Int(NSComparisonPredicate.Operator.beginsWith.rawValue)
        mi = menu.addItem(withTitle: NSLocalizedString("ends with", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = Int(NSComparisonPredicate.Operator.endsWith.rawValue)

        // for dates: O2EqualsToToday, O2EqualsToYesterday, NSLessThanComparison, NSGreaterThanComparison, O2Within, NSEqualToPredicateOperatorType
        mi = menu.addItem(withTitle: NSLocalizedString("is today", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O2Today
        mi = menu.addItem(withTitle: NSLocalizedString("is yesterday", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O2Yesterday
        mi = menu.addItem(withTitle: NSLocalizedString("is day before yesterday", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O2DayBeforeYesterday
        mi = menu.addItem(withTitle: NSLocalizedString("is before", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = Int(NSComparisonPredicate.Operator.lessThanOrEqualTo.rawValue)
        mi = menu.addItem(withTitle: NSLocalizedString("is after", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = Int(NSComparisonPredicate.Operator.greaterThanOrEqualTo.rawValue)
        mi = menu.addItem(withTitle: NSLocalizedString("is within", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O2Within

        // multi-purpose
        mi = menu.addItem(withTitle: NSLocalizedString("is", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = Int(NSComparisonPredicate.Operator.equalTo.rawValue)

        mi = menu.addItem(withTitle: NSLocalizedString("is not", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = Int(NSComparisonPredicate.Operator.notEqualTo.rawValue)

        _operatorsPopUp.bind(NSBindingName("selectedTag"), to: self, withKeyPath: "operator", options: nil)

        // string value field

        _stringValueTextField = NSTextField(frame: NSZeroRect)
        _stringValueTextField.cell?.controlSize = .small
        _stringValueTextField.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)

        _stringValueTextField.bind(.value, to: self, withKeyPath: "stringValue", options: [
            .continuouslyUpdatesValue: NSNumber(value: true),
            .nullPlaceholder: NSLocalizedString("empty", comment: "")])

        // number value field

        _numberValueTextField = NSTextField(frame: NSZeroRect)
        _numberValueTextField.cell?.controlSize = .small
        _numberValueTextField.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)

        _numberValueTextField.bind(.value, to: self, withKeyPath: "numberValue", options: [.continuouslyUpdatesValue: NSNumber(value: true)])

        // date picker

        _datePicker = O2DicomPredicateEditorDatePicker(frame: NSZeroRect)
        _datePicker.cell?.controlSize = .small
        _datePicker.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        _datePicker.datePickerElements = .yearMonthDay

        _datePicker.bind(.value, to: self, withKeyPath: "dateValue", options: nil)

        // time picker

        _timePicker = O2DicomPredicateEditorDatePicker(frame: NSZeroRect)
        _timePicker.cell?.controlSize = .small
        _timePicker.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        _timePicker.datePickerElements = .hourMinute

        _timePicker.bind(.value, to: self, withKeyPath: "dateValue", options: nil)

        // datetime picker

        _dateTimePicker = O2DicomPredicateEditorDatePicker(frame: NSZeroRect)
        _dateTimePicker.cell?.controlSize = .small
        _dateTimePicker.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        _dateTimePicker.datePickerElements = [.yearMonthDay, .hourMinute]

        _dateTimePicker.bind(.value, to: self, withKeyPath: "dateValue", options: nil)

        // within pop-up

        _withinPopUp = O2DicomPredicateEditorPopUpButton(frame: NSZeroRect, pullsDown: false)
        _withinPopUp.bezelStyle = .roundRect
        _withinPopUp.cell?.controlSize = .small
        _withinPopUp.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        _withinPopUp.autoenablesItems = false

        menu = NSMenu(title: "")
        _withinPopUp.menu = menu

        // "The last day" is omitted because "is today" already covers it.
        mi = menu.addItem(withTitle: NSLocalizedString("the last 2 days", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O22Days
        mi = menu.addItem(withTitle: NSLocalizedString("the last 7 days", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O21Week
        mi = menu.addItem(withTitle: NSLocalizedString("the last 31 days", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O21Month
        mi = menu.addItem(withTitle: NSLocalizedString("the last 2 months", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O22Months
        mi = menu.addItem(withTitle: NSLocalizedString("the last 3 months", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O23Months
        mi = menu.addItem(withTitle: NSLocalizedString("the last year", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O21Year
        menu.addItem(NSMenuItem.separator())
        mi = menu.addItem(withTitle: NSLocalizedString("the last hour", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O21Hour
        mi = menu.addItem(withTitle: NSLocalizedString("the last 6 hours", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O26Hours
        mi = menu.addItem(withTitle: NSLocalizedString("the last 12 hours", comment: ""), action: nil, keyEquivalent: "")
        mi.tag = O212Hours

        _withinPopUp.bind(NSBindingName("selectedTag"), to: self, withKeyPath: "within", options: nil)

        // code string (CS) pop-up

        _codeStringPopUp = O2DicomPredicateEditorPopUpButton(frame: NSZeroRect, pullsDown: false)
        _codeStringPopUp.bezelStyle = .roundRect
        _codeStringPopUp.cell?.controlSize = .small
        _codeStringPopUp.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        _codeStringPopUp.autoenablesItems = false

        menu = NSMenu(title: "")
        _codeStringPopUp.menu = menu

        _codeStringPopUp.bind(NSBindingName("selectedTag"), to: self, withKeyPath: "codeStringTag", options: nil)

        // is

        _isLabel = NSTextField(frame: NSZeroRect)
        _isLabel.cell?.controlSize = .small
        _isLabel.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        _isLabel.stringValue = NSLocalizedString("is", comment: "")
        _isLabel.isBordered = false
        _isLabel.isBezeled = false
        _isLabel.drawsBackground = false
        _isLabel.isEditable = false

        // ...

        observing = true
        addObserver(self, forKeyPath: "selectedTag", options: .initial, context: kvoContext)
        addObserver(self, forKeyPath: "tag", options: .initial, context: kvoContext)
        addObserver(self, forKeyPath: "operator", options: .initial, context: kvoContext)
        addObserver(self, forKeyPath: "stringValue", options: .initial, context: kvoContext)
        addObserver(self, forKeyPath: "numberValue", options: .initial, context: kvoContext)
        addObserver(self, forKeyPath: "dateValue", options: .initial, context: kvoContext)
        addObserver(self, forKeyPath: "within", options: .initial, context: kvoContext)
        addObserver(self, forKeyPath: "codeStringTag", options: .initial, context: kvoContext)
    }

    /// The former class did not override -initWithCoder:, so a decoded view
    /// has no controls and observes nothing.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        if observing {
            removeObserver(self, forKeyPath: "codeStringTag")
            removeObserver(self, forKeyPath: "within")
            removeObserver(self, forKeyPath: "dateValue")
            removeObserver(self, forKeyPath: "numberValue")
            removeObserver(self, forKeyPath: "stringValue")
            removeObserver(self, forKeyPath: "operator")
            removeObserver(self, forKeyPath: "tag")
            removeObserver(self, forKeyPath: "selectedTag")
        }

        // The former -dealloc also set self.tags = nil, which only logs.
        setTags(nil)

        // TODO memory leaking... this dealloc is never called...
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context != kvoContext {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        if (object as AnyObject?) === self {
            if keyPath == "tag" || keyPath == "operator" || keyPath == "codeStringTag" {
                review()
            }

            if keyPath == "tag" {
                switch Self.valueRepresentation(fromVR: dcmAttributeTag?.vr) {
                case VR.SH, VR.LO, VR.ST, VR.LT, VR.UT, VR.AE, VR.AS, VR.PN, VR.UI, VR.IS,
                     // VR.CS,
                     VR.DS:
                    if !objcIsKind(stringValue, of: NSString.self) {
                        stringValue = NSString()
                    }

                case VR.CS:
                    codeStringTag = 1
                    stringValue = NSString()

                case VR.SS, VR.SL, VR.US, VR.UL, VR.FL, VR.FD:
                    if !objcIsKind(numberValue, of: NSNumber.self) {
                        numberValue = NSNumber(value: Int32(0))
                    }

                case VR.DA, VR.TM, VR.DT:
                    if !objcIsKind(dateValue, of: NSDate.self) {
                        dateValue = NSDate()
                    }

                default:
                    break
                }
            }

            if keyPath == "operator" {
                if operatorTag == O2Within {
                    within = O26Hours
                }
            }

            resizeSubviews(withOldSize: bounds.size)

            editor()?.reloadPredicate()
        }
    }

    @objc(editor)
    public func editor() -> O2DicomPredicateEditor! {
        var view: NSView? = self
        while let v = view {
            if let editor = v as? O2DicomPredicateEditor {
                return editor
            }
            view = v.superview
        }
        return nil
    }

    // MARK: Tags

    @objc(_transformTagName:)
    class func _transformTagName(_ name: String!) -> String! {
        guard var name = name else { return nil }
        if name.hasPrefix("RETIRED_") {
            name = (name as NSString).substring(from: 8) + NSLocalizedString(" (retired)", comment: "")
        }
        if name.hasPrefix("ACR_NEMA_") {
            name = (name as NSString).substring(from: 9)
        }
        if name.hasPrefix("2C_") {
            name = (name as NSString).substring(from: 3)
        }
        return name
    }

    /// (group<<16)|element, computed in int as before.
    @objc(tagForTag:)
    class func tag(for tag: DCMAttributeTag!) -> Int {
        guard let tag = tag else { return 0 }
        return Int((tag.group &<< 16) | tag.element)
    }

    @objc(setTags:)
    func setTags(_ tags: NSArray!) {
        NSLog("We should not be here")
    }

    /// Retained and read-only in the former header.
    @objc public var tags: NSArray! {
        if tagsCache == nil {
            let cache = NSMutableArray()
            tagsCache = cache

            // common DICOM tags
            let dictionary = DCMTagDictionary.sharedTagDictionary() as AnyObject
            for case let dcmTagsKey as String in (dictionary as? NSDictionary)?.allKeys ?? [] {
                guard let tag = DCMAttributeTag.tag(withTagString: dcmTagsKey) as? DCMAttributeTag else { continue }
                let vr = Self.valueRepresentation(fromVR: tag.vr)
                if !tag.isPrivate && tag.group != 0x0000 && ((tag.group & 0xfff0) != 0xfff0) && vr != VR.SQ && vr != VR.OW && vr != VR.OF && vr != VR.OB && vr != VR.UN {
                    cache.add(tag)
                }
            }

            var i: Int32 = 0
            let g: Int32 = 0x0001 // we use group 0x0001 which is private
            func next() -> Int32 { i += 1; return i }
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "PN", name: "name", description: NSLocalizedString("Patient Name", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "LO", name: "patientID", description: NSLocalizedString("Patient ID", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "CS", name: "modality", description: NSLocalizedString("Modality", comment: ""), cskey: "Modality") as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "DT", name: "date", description: NSLocalizedString("Study Date", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "SH", name: "id", description: NSLocalizedString("Study ID", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "LO", name: "studyName", description: NSLocalizedString("Study Description", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "PN", name: "referringPhysician", description: NSLocalizedString("Referring Physician", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "PN", name: "performingPhysician", description: NSLocalizedString("Performing Physician", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "LO", name: "institutionName", description: NSLocalizedString("Institution", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "CS", name: "stateText", description: NSLocalizedString("Study Status", comment: ""), cskey: "OsiriX StudyStatus") as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "DT", name: "dateAdded", description: NSLocalizedString("Date Added", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "DT", name: "dateOpened", description: NSLocalizedString("Date Opened", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "LT", name: "comment", description: NSLocalizedString("Comments", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "LT", name: "comment2", description: NSLocalizedString("Comments 2", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "LT", name: "comment3", description: NSLocalizedString("Comments 3", comment: "")) as Any)
            cache.add(O2DicomPredicateEditorDCMAttributeTag.tag(withGroup: g, element: next(), vr: "LT", name: "comment4", description: NSLocalizedString("Comments 4", comment: "")) as Any)
        }

        return tagsCache
    }

    @objc(tagWithGroup:element:)
    func tag(withGroup group: Int32, element: Int32) -> DCMAttributeTag! {
        for case let tag as DCMAttributeTag in tags {
            if tag.group == group && tag.element == element {
                return tag
            }
        }
        return nil
    }

    @objc(tagWithKeyPath:)
    func tag(withKeyPath keyPath: String!) -> DCMAttributeTag! {
        for case let tag as DCMAttributeTag in tags {
            if objcIsEqualToString(tag.name, keyPath) {
                return tag
            }
        }
        return nil
    }

    @objc class var keyPathsForValuesAffectingTag: Set<String> {
        return ["DCMAttributeTag"]
    }

    @objc class var keyPathsForValuesAffectingSelectedTag: Set<String> {
        return ["tag"]
    }

    /// The tags pop-up's "selectedTag" is bound to this.
    @objc dynamic var selectedTag: Int {
        get {
            return Self.tag(for: dcmAttributeTag)
        }
        set {
            dcmAttributeTag = tag(withGroup: Int32(truncatingIfNeeded: newValue >> 16), element: Int32(truncatingIfNeeded: newValue & 0xffff))
        }
    }

    @objc(_contextualMenuSortTags:)
    func _contextualMenuSortTags(_ sender: NSMenuItem!) {
        _tagsSortKey = sender.tag
    }

    @objc(_observePopUpButtonWillPopUpNotification:)
    func _observePopUpButtonWillPopUpNotification(_ notification: Notification?) {
        let stag = _tagsPopUp.selectedTag()
        let binding = _tagsPopUp.infoForBinding(NSBindingName("selectedTag"))
        _tagsPopUp.unbind(NSBindingName("selectedTag"))

        _tagsPopUp.menu?.removeAllItems()
        for case let mi as NSMenuItem in _menuItems {
            if !(editor()?.inited ?? false) || objcIsKind(mi.representedObject, of: O2DicomPredicateEditorDCMAttributeTag.self) == (editor()?.dbMode ?? false) {
                _tagsPopUp.menu?.addItem(mi)
            }
        }

        if let binding = binding {
            _tagsPopUp.bind(NSBindingName("selectedTag"), to: binding[.observedObject] as Any, withKeyPath: binding[.observedKeyPath] as! String,
                            options: binding[.options] as? [NSBindingOption: Any])
        } else if stag != -1 {
            _tagsPopUp.selectItem(withTag: stag)
        }

        if editor()?.dbMode ?? false {
            _tagsSortKey = O2DicomPredicateEditorSortTagsByTag
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        if menu === _tagsPopUp.contextualMenu {
            for mi in menu.items {
                mi.isEnabled = (mi.tag != _tagsSortKey)
                mi.state = (mi.tag == _tagsSortKey) ? .on : .off
            }
        }
    }

    /// The former -setAvailableOperators:, a nil-terminated list of NSNumbers.
    private func setAvailableOperators(_ operators: [Int]) {
        let oops = Set(operators)

        var firstItem: NSMenuItem?
        for mi in _operatorsPopUp.itemArray {
            mi.isHidden = !oops.contains(mi.tag)
            if firstItem == nil && !mi.isHidden {
                firstItem = mi
            }
        }

        if _operatorsPopUp.selectedTag() != operatorTag && oops.contains(operatorTag) { // fix the selection
            _operatorsPopUp.selectItem(withTag: operatorTag)
        }
        if !oops.contains(_operatorsPopUp.selectedTag()) { // invalid selection... select a valid item
            _operatorsPopUp.select(firstItem)
        }
        if operatorTag != _operatorsPopUp.selectedTag() { // fix the bound value
            operatorTag = _operatorsPopUp.selectedTag()
        }
    }

    // MARK: Formatters

    private static let integerFormatterValue: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let decimalFormatterValue: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    // Each multiplicity formatter takes its own mono formatter; until #752
    // they took each other's.
    private static let integersFormatterValue: O2DicomPredicateEditorMultiplicityFormatter = {
        let formatter = O2DicomPredicateEditorMultiplicityFormatter()
        formatter.monoFormatter = integerFormatter()
        return formatter
    }()

    private static let decimalsFormatterValue: O2DicomPredicateEditorMultiplicityFormatter = {
        let formatter = O2DicomPredicateEditorMultiplicityFormatter()
        formatter.monoFormatter = decimalFormatter()
        return formatter
    }()

    private static let ageFormatterValue = O2DicomPredicateEditorAgeStringFormatter()

    @objc(integerFormatter)
    class func integerFormatter() -> Formatter {
        return integerFormatterValue
    }

    @objc(decimalFormatter)
    class func decimalFormatter() -> Formatter {
        return decimalFormatterValue
    }

    @objc(integersFormatter)
    class func integersFormatter() -> Formatter {
        return integersFormatterValue
    }

    @objc(decimalsFormatter)
    class func decimalsFormatter() -> Formatter {
        return decimalsFormatterValue
    }

    @objc(ageFormatter)
    class func ageFormatter() -> Formatter {
        return ageFormatterValue
    }

    // MARK: Views

    @objc(views)
    func views() -> NSArray {
        let views = NSMutableArray(object: _tagsPopUp!)

        let tag = dcmAttributeTag
        let vr = Self.valueRepresentation(fromVR: tag?.vr)

        let contains = Int(NSComparisonPredicate.Operator.contains.rawValue)
        let beginsWith = Int(NSComparisonPredicate.Operator.beginsWith.rawValue)
        let endsWith = Int(NSComparisonPredicate.Operator.endsWith.rawValue)
        let equalTo = Int(NSComparisonPredicate.Operator.equalTo.rawValue)
        let notEqualTo = Int(NSComparisonPredicate.Operator.notEqualTo.rawValue)
        let lessThanOrEqualTo = Int(NSComparisonPredicate.Operator.lessThanOrEqualTo.rawValue)
        let greaterThanOrEqualTo = Int(NSComparisonPredicate.Operator.greaterThanOrEqualTo.rawValue)

        switch vr {
        case VR.SH, VR.LO, VR.ST, VR.LT, VR.UT,
             VR.AE, // TODO: should be more restrictive for AE
             VR.PN, VR.UI:
            views.add(_operatorsPopUp!)
            setAvailableOperators([contains, beginsWith, endsWith, equalTo, notEqualTo])
            _stringValueTextField.formatter = nil
            views.add(_stringValueTextField!)

        case VR.IS:
            views.add(_isLabel!)
            setAvailableOperators([equalTo])
            _stringValueTextField.formatter = Self.integersFormatter()
            views.add(_stringValueTextField!)

        case VR.SS, VR.SL, VR.US, VR.UL:
            views.add(_isLabel!)
            setAvailableOperators([equalTo])
            _numberValueTextField.formatter = Self.integerFormatter()
            views.add(_numberValueTextField!)

        case VR.DS:
            views.add(_isLabel!)
            setAvailableOperators([equalTo])
            _stringValueTextField.formatter = Self.decimalsFormatter()
            views.add(_stringValueTextField!)

        case VR.FL, VR.FD:
            views.add(_isLabel!)
            setAvailableOperators([equalTo])
            _numberValueTextField.formatter = Self.decimalFormatter()
            views.add(_numberValueTextField!)

        case VR.AS:
            views.add(_isLabel!)
            setAvailableOperators([equalTo])
            _stringValueTextField.formatter = Self.ageFormatter()
            views.add(_stringValueTextField!)

        case VR.DA:
            views.add(_operatorsPopUp!)
            setAvailableOperators([O2Today, O2Yesterday, O2DayBeforeYesterday, lessThanOrEqualTo, greaterThanOrEqualTo, O2Within, equalTo]) // TODO: add 'is between'
            switch operatorTag {
            case lessThanOrEqualTo, greaterThanOrEqualTo, equalTo:
                views.add(_datePicker!)
            case O2Within:
                views.add(_withinPopUp!)
            default:
                break
            }

        case VR.TM:
            views.add(_operatorsPopUp!)
            setAvailableOperators([lessThanOrEqualTo, greaterThanOrEqualTo, equalTo])
            switch operatorTag {
            case lessThanOrEqualTo, greaterThanOrEqualTo, equalTo:
                views.add(_timePicker!)
            default:
                break
            }

        case VR.DT:
            views.add(_operatorsPopUp!)
            setAvailableOperators([O2Today, O2Yesterday, O2DayBeforeYesterday, lessThanOrEqualTo, greaterThanOrEqualTo, O2Within, equalTo]) // TODO: add 'is between'
            switch operatorTag {
            case lessThanOrEqualTo, greaterThanOrEqualTo, equalTo:
                views.add(_dateTimePicker!)
            case O2Within:
                views.add(_withinPopUp!)
            default:
                break
            }

        case VR.CS:
            views.add(_isLabel!)
            // .. popup
            _codeStringPopUp.menu?.removeAllItems()
            let dic = codeStrings(for: dcmAttributeTag)
            var i = 0
            if let dic = dic {
                for (k, _) in dic {
                    let value = dic.object(forKey: k)
                    var t: Any?
                    if objcIsKind(k, of: NSString.self) && !objcIsEqualToString(k, value as? String) && ((value as? NSString)?.length ?? 0) < 80 {
                        t = String(format: NSLocalizedString("%@, %@", comment: ""), k as! NSString, (value as? NSObject) ?? ("(null)" as NSString))
                    } else {
                        t = value
                    }
                    if !objcIsKind(t, of: NSString.self) {
                        t = objcSend(t, #selector(getter: NSNumber.stringValue))
                    }
                    let mi = _codeStringPopUp.menu!.addItem(withTitle: (t as? String) ?? "", action: nil, keyEquivalent: "")
                    i += 1
                    mi.tag = i
                }
            }
            // if there are items, show the popup
            if i != 0 {
                views.add(_codeStringPopUp!)
            }
            // add custom-value menu item
            let mi = _codeStringPopUp.menu!.addItem(withTitle: NSLocalizedString("user-defined", comment: ""), action: nil, keyEquivalent: "")
            i += 1
            mi.tag = i
            mi.representedObject = _stringValueTextField

            _codeStringPopUp.selectItem(withTag: codeStringTag)

            if codeStringTag == i {
                _stringValueTextField.formatter = nil
                views.add(_stringValueTextField!)
            }

        default:
            break
        }

        return views
    }

    @objc(review)
    func review() {
        if _reviewing {
            return
        }

        _reviewing = true

        var views: NSArray?

        do {
            try HorosObjCException.perform {
                views = self.views()
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[O2DicomPredicateEditorView review]")
            }
        }
        _reviewing = false

        // show/hide

        for subview in subviews {
            subview.removeFromSuperview()
        }

        var p: NSView?
        for case let subview as NSView in views ?? [] {
            if subview.superview !== self {
                addSubview(subview)
            }
            p?.nextKeyView = subview
            p = subview
        }

        resizeSubviews(withOldSize: bounds.size)
    }

    // MARK: Predicate

    @objc(matchForPredicate:)
    public func match(for p: NSPredicate!) -> Double {
        if objcIsKind(p, of: NSComparisonPredicate.self) {
            var match: Double?
            do {
                try HorosObjCException.perform {
                    match = self.match(forComparison: p as! NSComparisonPredicate)
                }
            } catch {
            }
            if let match = match {
                return match
            }
        }

        if objcIsKind(p, of: NSCompoundPredicate.self) && (p as! NSCompoundPredicate).compoundPredicateType == .and {
            var match: Double?
            do {
                try HorosObjCException.perform {
                    match = self.match(forAndPredicate: p as! NSCompoundPredicate)
                }
            } catch {
            }
            if let match = match {
                return match
            }
        }

        if objcIsKind(p, of: NSPredicate.self) && p.predicateFormat == "TRUEPREDICATE" {
            return 0.6
        }

        return 0
    }

    /// The comparison part of -matchForPredicate:, in its @try: nil where it
    /// went on.
    private func match(forComparison predicate: NSComparisonPredicate) -> Double? {
        let otype = Int(bitPattern: predicate.predicateOperatorType.rawValue)

        let tag = self.tag(withKeyPath: predicate.keyPath())
        let vr = Self.valueRepresentation(fromVR: tag?.vr)

        if vr == 0 || vr == VR.UN {
            return 0 // we cannot handle tags of unknown type
        }

        let contains = Int(NSComparisonPredicate.Operator.contains.rawValue)
        let equalTo = Int(NSComparisonPredicate.Operator.equalTo.rawValue)
        let lessThanOrEqualTo = Int(NSComparisonPredicate.Operator.lessThanOrEqualTo.rawValue)
        let greaterThanOrEqualTo = Int(NSComparisonPredicate.Operator.greaterThanOrEqualTo.rawValue)
        let between = Int(NSComparisonPredicate.Operator.between.rawValue)

        switch vr {
        case VR.CS:
            if (otype == equalTo || otype == contains) && predicate.constantValue() != nil {
                return 1 // is
            }

        case VR.SH, VR.LO, VR.ST, VR.LT, VR.UT, VR.AE, VR.PN,
             // VR.CS,
             VR.UI: /* TODO: should be more restrictive for AE */
            switch NSComparisonPredicate.Operator(rawValue: UInt(bitPattern: otype))! {
            case .contains, .beginsWith, .endsWith, .equalTo, .notEqualTo:
                return 1
            default:
                break
            }

        case VR.AS, VR.IS, VR.DS, VR.SS, VR.SL, VR.US, VR.UL, VR.FL, VR.FD:
            if otype == equalTo {
                return 1
            }

        case VR.DA, VR.DT:
            if otype == greaterThanOrEqualTo && objcIsKind(predicate.constantValue(), of: NSDate.self) {
                return 1 // is after DATE
            }
            if otype == greaterThanOrEqualTo && ((predicate.variable().map { Self.timeKeys().contains($0) } ?? false)
                    || (objcIsEqualToString(predicate.function(), "castObject:toType:")
                        && (objcConstantValue(objcObjectAtIndex(predicate.arguments(), at: 1)) as AnyObject?)?.isEqual("NSDate") == true
                        && (objcVariable(objcObjectAtIndex(predicate.arguments(), at: 0)).map { Self.legacyTimeKeys().contains($0) } ?? false))) {
                return 1 // is today & is within
            }
            if otype == lessThanOrEqualTo && objcIsKind(predicate.constantValue(), of: NSDate.self) {
                return 1 // is before
            }
            // Before the checks below, whose -variable raises for its constants.
            if isDateValue(of: predicate) != nil {
                return 1 // is DATE, as makePredicate() writes it (#752)
            }
            if otype == between &&
                objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.collection(), at: 0)), O2VarYesterday) &&
                objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.collection(), at: 1)), O2VarToday) { // match "KeyPath between {NSDATE_YESTERDAY, NSDATE_TODAY}" for Yesterday
                return 1 // is yesterday
            }
            if otype == between &&
                objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.collection(), at: 0)), O2Var2Days) &&
                objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.collection(), at: 1)), O2VarYesterday) { // match "KeyPath between {NSDATE_2DAYS, NSDATE_YESTERDAY}" for Yesterday
                return 1 // is day before yesterday
            }
            if otype == equalTo && objcIsKind(predicate.constantValue(), of: NSDate.self) {
                return 1 // is
            }

        case VR.TM:
            if otype == lessThanOrEqualTo && objcIsKind(predicate.constantValue(), of: NSDate.self) {
                return 1 // is before
            }
            if otype == greaterThanOrEqualTo && objcIsKind(predicate.constantValue(), of: NSDate.self) {
                return 1 // is after
            }
            if otype == equalTo && objcIsKind(predicate.constantValue(), of: NSDate.self) {
                return 1 // is
            }

        default:
            break
        }

        return nil
    }

    /// The AND part of -matchForPredicate:, in its @try: nil where it went on.
    private func match(forAndPredicate predicate: NSCompoundPredicate) -> Double? {
        let subpredicates = objcSubpredicates(predicate)
        // subpredicates must be of same KeyPath
        var keyPath: String?
        for p in subpredicates {
            if objcIsKind(p, of: NSComparisonPredicate.self) {
                if keyPath != nil && !objcIsEqualToString((p as! NSComparisonPredicate).keyPath(), keyPath) { // subpredicates must have the same keyPath
                    keyPath = nil; break
                } else {
                    keyPath = (p as! NSComparisonPredicate).keyPath()
                }
            } else { // subpredicates must all be comparisons
                keyPath = nil; break
            }
        }

        let tag = self.tag(withKeyPath: keyPath)
        let vr = Self.valueRepresentation(fromVR: tag?.vr)

        let sp0 = objcObjectAtIndex(subpredicates, at: 0)
        let sp1 = objcObjectAtIndex(subpredicates, at: 1)

        let notEqualTo = Int(NSComparisonPredicate.Operator.notEqualTo.rawValue)
        let lessThanOrEqualTo = Int(NSComparisonPredicate.Operator.lessThanOrEqualTo.rawValue)
        let greaterThanOrEqualTo = Int(NSComparisonPredicate.Operator.greaterThanOrEqualTo.rawValue)

        // match old "DA_KeyPath >= $NSDATE_YESTERDAY AND DA_KeyPath <= $NSDATE_TODAY" for "KeyPath between {NSDATE_YESTERDAY, NSDATE_TODAY}"
        if (vr == VR.DA || vr == VR.DT) &&
            subpredicates.count == 2 &&
            objcPredicateOperatorType(sp0) == greaterThanOrEqualTo && objcIsEqualToString(objcVariable(sp0), O2VarYesterday) &&
            objcPredicateOperatorType(sp1) == lessThanOrEqualTo && objcIsEqualToString(objcVariable(sp1), O2VarToday) {
            return 1
        }

        // match old "DA_KeyPath >= $NSDATE_2DAYS AND DA_KeyPath <= $NSDATE_YESTERDAY" for "KeyPath between {NSDATE_YESTERDAY, NSDATE_TODAY}"
        if (vr == VR.DA || vr == VR.DT) &&
            subpredicates.count == 2 &&
            objcPredicateOperatorType(sp0) == greaterThanOrEqualTo && objcIsEqualToString(objcVariable(sp0), O2Var2Days) &&
            objcPredicateOperatorType(sp1) == lessThanOrEqualTo && objcIsEqualToString(objcVariable(sp1), O2VarYesterday) {
            return 1
        }

        // match "LT_KeyPath != '' AND LT_KeyPath != nil"
        if (vr == VR.SH || vr == VR.LO || vr == VR.ST || vr == VR.LT || vr == VR.UT || vr == VR.AE || vr == VR.PN || vr == VR.UI) &&
            subpredicates.count == 2 &&
            objcPredicateOperatorType(sp0) == notEqualTo && objcPredicateOperatorType(sp1) == notEqualTo &&
            objcIsEqualToString(objcConstantValue(sp0), "") && objcConstantValue(sp1) == nil {
            return 1
        }

        return nil
    }

    /// Retained and atomic (assign) in the former header: the getter builds
    /// the row's predicate, the setter shows the one it is given. An exception
    /// the setter raises reaches its caller, as before.
    @objc public dynamic var predicate: NSPredicate! {
        get {
            return makePredicate()
        }
        set {
            show(newValue)
        }
    }

    private func show(_ p: Any?) {
        if objcIsKind(p, of: NSPredicate.self) && (p as! NSPredicate).predicateFormat == "TRUEPREDICATE" {
            dcmAttributeTag = nil
            return
        }

        let notEqualTo = Int(NSComparisonPredicate.Operator.notEqualTo.rawValue)
        let lessThanOrEqualTo = Int(NSComparisonPredicate.Operator.lessThanOrEqualTo.rawValue)
        let greaterThanOrEqualTo = Int(NSComparisonPredicate.Operator.greaterThanOrEqualTo.rawValue)
        let between = Int(NSComparisonPredicate.Operator.between.rawValue)

        if objcIsKind(p, of: NSComparisonPredicate.self) {
            let predicate = p as! NSComparisonPredicate

            let tag = self.tag(withKeyPath: predicate.keyPath())
            let vr = Self.valueRepresentation(fromVR: tag?.vr)

            let otype = Int(bitPattern: predicate.predicateOperatorType.rawValue)

            dcmAttributeTag = tag

            switch vr {
            case VR.SH, VR.LO, VR.ST, VR.LT, VR.UT, VR.AE, VR.PN, VR.UI,
                 // VR.CS,
                 VR.AS:
                operatorTag = otype
                stringValue = unchecked(predicate.constantValue(), as: NSString.self)

            case VR.IS, VR.DS:
                operatorTag = otype
                let value = predicate.constantValue()
                if objcIsKind(value, of: NSNumber.self) {
                    stringValue = (value as! NSNumber).stringValue as NSString
                } else if objcIsKind(value, of: NSString.self) {
                    stringValue = (value as! NSString)
                }

            case VR.SS, VR.SL, VR.US, VR.UL, VR.FL, VR.FD:
                operatorTag = otype
                let value = predicate.constantValue()
                if objcIsKind(value, of: NSNumber.self) {
                    numberValue = (value as! NSNumber)
                } else if objcIsKind(value, of: NSString.self) {
                    numberValue = NSNumber(value: (value as! NSString).doubleValue)
                }

            case VR.DA, VR.DT:
                if otype == greaterThanOrEqualTo && (predicate.variable() != nil || predicate.function() != nil) {
                    if objcIsEqualToString(predicate.variable(), O2VarToday) || objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.arguments(), at: 0)), legacyTimeKey(O2VarToday)) {
                        operatorTag = O2Today
                    } else {
                        operatorTag = O2Within
                        var tt = Self.timeTag(fromKey: predicate.variable())
                        if tt == 0 {
                            tt = Self.timeTag(fromKey: unLegacyTimeKey(objcVariable(objcObjectAtIndex(predicate.arguments(), at: 0))))
                        }
                        within = tt
                    }
                } else if let date = isDateValue(of: predicate) { // is DATE (#752), before -variable raises for its constants
                    operatorTag = Int(NSComparisonPredicate.Operator.equalTo.rawValue)
                    dateValue = date
                } else if otype == between && objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.collection(), at: 0)), O2VarYesterday) && objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.collection(), at: 1)), O2VarToday) { // yesterday
                    operatorTag = O2Yesterday
                } else if otype == between && objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.collection(), at: 0)), O2Var2Days) && objcIsEqualToString(objcVariable(objcObjectAtIndex(predicate.collection(), at: 1)), O2VarYesterday) { // day before yesterday
                    operatorTag = O2DayBeforeYesterday
                } else if objcIsKind(predicate.constantValue(), of: NSDate.self) {
                    operatorTag = otype
                    dateValue = (predicate.constantValue() as! NSDate)
                } else {
                    NSException(name: .genericException, reason: "Unexpected comparison for DA tag: \(predicate)", userInfo: nil).raise()
                }

            case VR.TM:
                operatorTag = otype
                dateValue = unchecked(predicate.constantValue(), as: NSDate.self)

            case VR.CS:
                let value = predicate.constantValue()
                codeStringTag = self.tag(forCodeString: value)
                if codeStringTag > (codeStrings(for: tag)?.count ?? 0) {
                    // A code outside the list is the user-defined item's
                    // value, kept as it was stored: until #752 a string became
                    // nil and a number the tag's empty string.
                    stringValue = unchecked(value, as: NSString.self)
                } else if objcIsKind(value, of: NSString.self) {
                    stringValue = nil
                }

            default:
                break
            }
        }

        if objcIsKind(p, of: NSCompoundPredicate.self) && (p as! NSCompoundPredicate).compoundPredicateType == .and {
            let predicate = p as! NSCompoundPredicate

            let subpredicates = objcSubpredicates(predicate)
            let tag = self.tag(withKeyPath: objcKeyPath(objcObjectAtIndex(subpredicates, at: 0)))
            let vr = Self.valueRepresentation(fromVR: tag?.vr)

            dcmAttributeTag = tag

            let sp0 = objcObjectAtIndex(subpredicates, at: 0)
            let sp1 = objcObjectAtIndex(subpredicates, at: 1)

            // match old "DA_KeyPath >= $NSDATE_YESTERDAY AND DA_KeyPath <= $NSDATE_TODAY" for "KeyPath between {NSDATE_YESTERDAY, NSDATE_TODAY}"
            if (vr == VR.DA || vr == VR.DT) &&
                subpredicates.count == 2 &&
                objcPredicateOperatorType(sp0) == greaterThanOrEqualTo && objcIsEqualToString(objcVariable(sp0), O2VarYesterday) &&
                objcPredicateOperatorType(sp1) == lessThanOrEqualTo && objcIsEqualToString(objcVariable(sp1), O2VarToday) {
                operatorTag = O2Yesterday
            }

            if (vr == VR.DA || vr == VR.DT) &&
                subpredicates.count == 2 &&
                objcPredicateOperatorType(sp0) == greaterThanOrEqualTo && objcIsEqualToString(objcVariable(sp0), O2Var2Days) &&
                objcPredicateOperatorType(sp1) == lessThanOrEqualTo && objcIsEqualToString(objcVariable(sp1), O2VarYesterday) {
                operatorTag = O2DayBeforeYesterday
            }

            // match "LT_KeyPath != '' AND LT_KeyPath != nil"
            if (vr == VR.SH || vr == VR.LO || vr == VR.ST || vr == VR.LT || vr == VR.UT || vr == VR.AE || vr == VR.PN || vr == VR.UI) &&
                objcPredicateOperatorType(sp0) == notEqualTo && objcPredicateOperatorType(sp1) == notEqualTo &&
                objcIsEqualToString(objcConstantValue(sp0), "") && objcConstantValue(sp1) == nil {
                operatorTag = notEqualTo
                stringValue = ""
            }
        }
    }

    @objc class var keyPathsForValuesAffectingPredicate: Set<String> {
        return ["tag", "operator", "stringValue", "numberValue", "dateValue", "within", "codeStringTag"]
    }

    private func makePredicate() -> NSPredicate {
        let tag = dcmAttributeTag
        let vr = Self.valueRepresentation(fromVR: tag?.vr)

        let tagNameExpression = keyPathExpression(tag?.name)

        let equalTo = Int(NSComparisonPredicate.Operator.equalTo.rawValue)
        let lessThanOrEqualTo = Int(NSComparisonPredicate.Operator.lessThanOrEqualTo.rawValue)
        let greaterThanOrEqualTo = Int(NSComparisonPredicate.Operator.greaterThanOrEqualTo.rawValue)
        let between = Int(NSComparisonPredicate.Operator.between.rawValue)
        let contains = Int(NSComparisonPredicate.Operator.contains.rawValue)

        switch vr {
        case VR.SH, VR.LO, VR.ST, VR.LT, VR.UT, VR.AE, VR.PN,
             // VR.CS,
             VR.UI, VR.AS:
            if (stringValue?.length ?? 0) != 0 {
                return comparison(tagNameExpression, NSExpression(forConstantValue: stringValue), operatorTag, .caseInsensitive)
            } else {
                return NSCompoundPredicate(andPredicateWithSubpredicates: [
                    comparison(tagNameExpression, NSExpression(forConstantValue: ""), operatorTag, .caseInsensitive),
                    comparison(tagNameExpression, NSExpression(forConstantValue: nil), operatorTag, .caseInsensitive)])
            }

        case VR.DS, VR.IS:
            return comparison(tagNameExpression, NSExpression(forConstantValue: stringValue), operatorTag, .caseInsensitive)

        case VR.SS, VR.SL, VR.US, VR.UL, VR.FL, VR.FD:
            return comparison(tagNameExpression, NSExpression(forConstantValue: numberValue), operatorTag, .caseInsensitive)

        case VR.DA, VR.DT:
            switch operatorTag {
            case O2Today:
                return comparison(tagNameExpression, variableExpression(O2VarToday), greaterThanOrEqualTo, [])
            case O2Yesterday:
                return comparison(tagNameExpression, NSExpression(forAggregate: [variableExpression(O2VarYesterday), variableExpression(O2VarToday)]), between, []) // TODO: is this coredata compatible?
            case O2DayBeforeYesterday:
                return comparison(tagNameExpression, NSExpression(forAggregate: [variableExpression(O2Var2Days), variableExpression(O2VarYesterday)]), between, []) // TODO: is this coredata compatible?
            case lessThanOrEqualTo, greaterThanOrEqualTo:
                return comparison(tagNameExpression, NSExpression(forConstantValue: dateValue), operatorTag, [])
            case O2Within:
                return comparison(tagNameExpression, variableExpression(Self.timeKey(fromTag: within)), greaterThanOrEqualTo, [])
            case equalTo:
                let calendar = NSCalendar.current as NSCalendar
                // A nil date gave nil components and was taken for the
                // reference date when adding the day, as before.
                let dc: NSDateComponents? = dateValue.map { calendar.components([.era, .year, .month, .day], from: $0 as Date) as NSDateComponents }
                let from = dc.flatMap { calendar.date(from: $0 as DateComponents) }
                let day = NSDateComponents()
                day.day = 1
                let to = calendar.date(byAdding: day as DateComponents, to: from ?? Date(timeIntervalSinceReferenceDate: 0), options: .wrapComponents)
                return comparison(tagNameExpression, NSExpression(forAggregate: [NSExpression(forConstantValue: from), NSExpression(forConstantValue: to)]), between, []) // TODO: is this coredata compatible?
            default:
                break
            } // switch DA operator

        case VR.TM:
            switch operatorTag {
            case lessThanOrEqualTo, greaterThanOrEqualTo, equalTo:
                return comparison(tagNameExpression, NSExpression(forConstantValue: dateValue), operatorTag, [])
            default:
                break
            }

        case VR.CS:
            return comparison(tagNameExpression, NSExpression(forConstantValue: codeString(forTag: codeStringTag)), contains /* NSEqualToPredicateOperatorType */, [])

        default:
            break
        }

        return NSPredicate(value: true)
    }

    public override func resizeSubviews(withOldSize oldBoundsSize: NSSize) {
        let bounds = self.bounds
        var frame = NSZeroRect
        let kSeparatorWidth: CGFloat = 5

        frame.origin.x = 0

        for view in subviews {
            frame = NSMakeRect(frame.origin.x, 0, 0, 0)
            if view is NSPopUpButton || view is NSDatePicker {
                (view as! NSControl).sizeToFit(); frame.size = NSMakeSize(view.frame.size.width, bounds.size.height)
            } else if let field = view as? NSTextField, !field.isEditable {
                guard let font = field.font else {
                    NSException(name: .invalidArgumentException, reason: "*** +[NSDictionary dictionaryWithObject:forKey:]: object cannot be nil", userInfo: nil).raise()
                    return
                }
                frame.size = NSMakeSize((field.stringValue as NSString).size(withAttributes: [.font: font]).width + 4, bounds.size.height - 3)
                frame.origin.y += 0
            } else {
                frame.size = NSMakeSize(150, bounds.size.height)
            }

            view.frame = frame

            frame.origin.x += frame.size.width + kSeparatorWidth
        }
    }

    /// The code's item in the code-string pop-up, from 1; the user-defined
    /// item, last, for a code outside the list or a tag without one. For the
    /// latter, until #752, 0 selected nothing and hid the value field.
    @objc(tagForCodeString:)
    func tag(forCodeString str: Any!) -> Int {
        guard let dic = codeStrings(for: dcmAttributeTag) else {
            return 1
        }

        let i = str.map { (dic.allKeys as NSArray).index(of: $0) } ?? NSNotFound

        if i == NSNotFound { return dic.count + 1 }

        return i + 1
    }

    @objc(codeStringForTag:)
    func codeString(forTag cst: Int) -> Any! {
        let dic = codeStrings(for: dcmAttributeTag)

        if let dic = dic, cst > 0 && dic.count >= cst {
            return (dic.allKeys as NSArray).object(at: cst - 1)
        }

        return stringValue
    }
}

/// The former NSComparisonPredicate (OsiriX) category of
/// O2DicomPredicateEditorView.m: the side of the comparison that is of the
/// asked type. O2DicomPredicateEditor sends -keyPath to comparisons too.
extension NSComparisonPredicate {
    @objc(collection)
    func collection() -> Any? {
        if leftExpression.expressionType == .aggregate { return leftExpression.collection }
        if rightExpression.expressionType == .aggregate { return rightExpression.collection }
        return nil
    }

    @objc(constantValue)
    func constantValue() -> Any? {
        if leftExpression.expressionType == .constantValue { return leftExpression.constantValue }
        if rightExpression.expressionType == .constantValue { return rightExpression.constantValue }
        return nil
    }

    @objc(function)
    func function() -> String? {
        if leftExpression.expressionType == .function { return leftExpression.function }
        if rightExpression.expressionType == .function { return rightExpression.function }
        return nil
    }

    @objc(keyPath)
    func keyPath() -> String? {
        if leftExpression.expressionType == .keyPath { return leftExpression.keyPath }
        if rightExpression.expressionType == .keyPath { return rightExpression.keyPath }
        return nil
    }

    @objc(variable)
    func variable() -> String? {
        if leftExpression.expressionType == .variable { return leftExpression.variable }
        if rightExpression.expressionType == .variable { return rightExpression.variable }
        return nil
    }

    /// The expression's own array, not bridged through Swift.
    @objc(arguments)
    func arguments() -> NSArray? {
        let arguments = #selector(getter: NSExpression.arguments)
        if leftExpression.expressionType == .function { return leftExpression.perform(arguments)?.takeUnretainedValue() as? NSArray }
        if rightExpression.expressionType == .function { return rightExpression.perform(arguments)?.takeUnretainedValue() as? NSArray }
        return nil
    }
}
