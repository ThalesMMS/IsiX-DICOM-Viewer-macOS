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

/// The subpredicates of the compound predicates made here, in an NSArray made
/// by Foundation. O2DicomPredicateEditorView reads the second subpredicate of
/// any AND compound inside an @try: past the end, Foundation's -objectAtIndex:
/// raises NSRangeException, which that @catch handles, where the storage of a
/// Swift array stops the process.
private func foundationArray(_ predicates: [NSPredicate]) -> [NSPredicate] {
    return NSArray(array: predicates) as! [NSPredicate]
}

/// The rule editor of the smart albums (SmartAlbum.xib): one row template
/// that shows an O2DicomPredicateEditorView, and a compound template of And
/// and Or over it. Its predicate is what the album stores in the database.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/O2DicomPredicateEditor.h> are those of the former class. For the
/// same inputs, `predicate` and `objectValue` have the same predicateFormat
/// as before.
@objc(O2DicomPredicateEditor)
public final class O2DicomPredicateEditor: NSPredicateEditor {
    private var _inited = false
    private var _inValidateEditing = false
    private var _dbMode = false
    private var _backbinding = false
    private var _setting = false
    private var _dpert: O2DicomPredicateEditorRowTemplate?
    /// Whether -awakeFromNib registered the "value" observer, which the former
    /// -dealloc removed unconditionally.
    private var _observingValue = false

    /// The former code passed [self class] as the observation context.
    private static var observationContext = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        initDicomPredicateEditor()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if _observingValue {
            removeObserver(self, forKeyPath: "value", context: &O2DicomPredicateEditor.observationContext)
        }
    }

    // As before, it does not call super.
    public override func awakeFromNib() {
        initDicomPredicateEditor()

        if let binding = infoForBinding(.value) {
            // As [[options mutableCopy] setObject:…]: without options, none is added.
            var options = binding[.options] as? [NSBindingOption: Any]

            options?[.nullPlaceholder] = NSCompoundPredicate(andPredicateWithSubpredicates: foundationArray([NSPredicate(value: true)]))

            unbind(.value)
            if let observed = binding[.observedObject], let keyPath = binding[.observedKeyPath] as? String {
                bind(.value, to: observed, withKeyPath: keyPath, options: options)
            }
        }

        addObserver(self, forKeyPath: "value", options: [], context: &O2DicomPredicateEditor.observationContext)
        _observingValue = true
    }

    @objc(initDicomPredicateEditor)
    func initDicomPredicateEditor() {
        if _inited {
            return
        }

        // _dpert is set before the templates, as in the former array literal.
        let dpert = O2DicomPredicateEditorRowTemplate()
        _dpert = dpert
        rowTemplates = [dpert, O2DicomPredicateEditorCompoundRowTemplate(subtemplates: [dpert])]

        _inited = true
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &O2DicomPredicateEditor.observationContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        if _setting {
            return
        }

        _backbinding = true
        // The former @catch rethrew after resetting _backbinding. Swift cannot
        // rethrow an NSException, so it is logged.
        do {
            try HorosObjCException.perform {
                if let binding = self.infoForBinding(.value), let observed = binding[.observedObject] as? NSObject {
                    observed.setValue(self.predicate, forKeyPath: binding[.observedKeyPath] as? String ?? "")
                }
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[O2DicomPredicateEditor observeValueForKeyPath:ofObject:change:context:]")
            }
        }
        _backbinding = false
    }

    /// -[NSComparisonPredicate keyPath], declared by the NSComparisonPredicate
    /// (OsiriX) category of O2DicomPredicateEditorView: called by its selector,
    /// as the former [sp keyPath].
    private static func keyPath(of predicate: NSComparisonPredicate) -> Any? {
        return predicate.perform(NSSelectorFromString("keyPath"))?.takeUnretainedValue()
    }

    private func dpertMatches(_ predicate: NSPredicate) -> Bool {
        return (_dpert?.match(for: predicate) ?? 0) != 0
    }

    @objc(regroupedPredicate:)
    func regroupedPredicate(_ predicate: Any?) -> Any? {
        var p = predicate

        if (p as? NSPredicate)?.predicateFormat == "TRUEPREDICATE" {
            return p
        }

        if let pp = p as? NSPredicate, dpertMatches(pp) {
            p = NSCompoundPredicate(andPredicateWithSubpredicates: foundationArray([pp]))
        }

        if let cp = p as? NSCompoundPredicate {
            let d = NSMutableDictionary()
            let a = NSMutableArray()

            for sp in cp.subpredicates {
                if let csp = sp as? NSComparisonPredicate {
                    let keyPath = O2DicomPredicateEditor.keyPath(of: csp)
                    var pka = keyPath.flatMap { d.object(forKey: $0) } as? NSMutableArray
                    if pka == nil {
                        guard let key = keyPath as? NSCopying else {
                            // What -[NSMutableDictionary setObject:forKey:] raised for a nil key.
                            NSException(name: .invalidArgumentException, reason: "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil", userInfo: nil).raise()
                            return nil
                        }
                        let new = NSMutableArray()
                        d.setObject(new, forKey: key)
                        a.add(key)
                        pka = new
                    }
                    pka?.add(csp)
                } else {
                    a.add(sp)
                }
            }

            // a.count grows when a group is spliced back in: it is read at each step.
            var i = 0
            while i < a.count {
                if !(a.object(at: i) is NSPredicate), let pka = d.object(forKey: a.object(at: i)) as? NSArray {
                    if pka.count == 1 {
                        a.replaceObject(at: i, with: pka.lastObject as Any)
                    } else {
                        let np = NSCompoundPredicate(andPredicateWithSubpredicates: foundationArray(pka as! [NSPredicate]))
                        if dpertMatches(np) {
                            a.replaceObject(at: i, with: np)
                        } else {
                            a.replaceObjects(in: NSRange(location: i, length: 1), withObjectsFrom: pka as! [Any])
                        }
                    }
                }
                i += 1
            }

            p = NSCompoundPredicate(type: cp.compoundPredicateType, subpredicates: foundationArray(a as! [NSPredicate]))
        }

        return p
    }

    /// The former class overrode only -setObjectValue:.
    public override var objectValue: Any? {
        get {
            return super.objectValue
        }
        set {
            if _backbinding {
                return
            }

            initDicomPredicateEditor() // weird, this is needed: bindings are assigned before initWithFrame: or awakeFromNib...

            // try grouping conditions on the same keys in separate compounds
            let value = regroupedPredicate(newValue)

            _setting = true
            do {
                try HorosObjCException.perform {
                    super.objectValue = value
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, false, "-[O2DicomPredicateEditor setObjectValue:]")
                }
            }
            _setting = false
        }
    }

    @objc public var dbMode: Bool {
        get {
            return _dbMode
        }
        set {
            _dbMode = newValue
            if newValue {
                nestingMode = .compound
            } else {
                nestingMode = .list
            }
        }
    }

    @objc public var inited: Bool {
        get {
            return _inited
        }
        set {
            _inited = newValue
        }
    }

    @objc public class func keyPathsForValuesAffectingValue() -> Set<String> {
        return ["predicate"]
    }

    public override func validateEditing() { // to avoid an infinite recurse loop
        if !_inValidateEditing {
            _inValidateEditing = true
            super.validateEditing()
            _inValidateEditing = false
        }
    }

    @objc(matchForPredicate:)
    public func match(for predicate: NSPredicate?) -> Bool {
        let p = regroupedPredicate(predicate)

        var ok = false
        for rt in rowTemplates {
            if let p = p as? NSPredicate, rt.match(for: p) != 0 {
                ok = true
                break
            }
        }

        return ok
    }

    @objc(reallyMatchForPredicate:)
    public func reallyMatch(for predicate: NSPredicate?) -> Bool {
        let p = regroupedPredicate(predicate)

        for rt in rowTemplates {
            var rtok: Double = 0
            if let crt = rt as? O2DicomPredicateEditorCompoundRowTemplate {
                rtok = crt.reallyMatch(for: p)
            } else if let p = p as? NSPredicate {
                rtok = rt.match(for: p)
            }
            if rtok > 0 {
                return true
            }
        }

        return false
    }
}

/// The row template of a condition: its view is an O2DicomPredicateEditorView.
/// NSPredicateEditor copies it for each row with -init, and each copy makes its
/// own view.
@objc(O2DicomPredicateEditorRowTemplate)
public final class O2DicomPredicateEditorRowTemplate: NSPredicateEditorRowTemplate {
    private var _view: O2DicomPredicateEditorView?

    /// Retained, and made on first use, as before.
    @objc public var view: O2DicomPredicateEditorView! {
        get {
            if _view == nil {
                let view = O2DicomPredicateEditorView(frame: .zero)
                view.setFrameSize(NSSize(width: 4000, height: 20))
                _view = view
            }
            return _view
        }
        set {
            _view = newValue
        }
    }

    public override func match(for predicate: NSPredicate) -> Double {
        return view.match(for: predicate)
    }

    public override var templateViews: [NSView] {
        return [view]
    }

    public override func setPredicate(_ predicate: NSPredicate) {
        view.predicate = predicate
    }

    public override func predicate(withSubpredicates subpredicates: [NSPredicate]?) -> NSPredicate {
        return view.predicate
    }
}

/// The And/Or row template over the condition template.
@objc(O2DicomPredicateEditorCompoundRowTemplate)
public final class O2DicomPredicateEditorCompoundRowTemplate: NSPredicateEditorRowTemplate {
    /// Empty in the copies NSPredicateEditor makes with -init, as the former
    /// ivar was nil there.
    private var subtemplates: [NSPredicateEditorRowTemplate] = []

    @objc(initWithSubtemplates:)
    public init(subtemplates: [Any]!) {
        self.subtemplates = (subtemplates ?? []).compactMap { $0 as? NSPredicateEditorRowTemplate }
        super.init(compoundTypes: [NSNumber(value: NSCompoundPredicate.LogicalType.and.rawValue), NSNumber(value: NSCompoundPredicate.LogicalType.or.rawValue)])
    }

    // The initializers the former subclass inherited: NSPredicateEditor makes
    // the rows' copies with -init.
    public override init() {
        super.init()
    }

    public override init(compoundTypes: [NSNumber]) {
        super.init(compoundTypes: compoundTypes)
    }

    public override init(leftExpressions: [NSExpression], rightExpressions: [NSExpression], modifier: NSComparisonPredicate.Modifier, operators: [NSNumber], options: Int) {
        super.init(leftExpressions: leftExpressions, rightExpressions: rightExpressions, modifier: modifier, operators: operators, options: options)
    }

    public override init(leftExpressions: [NSExpression], rightExpressionAttributeType attributeType: NSAttributeType, modifier: NSComparisonPredicate.Modifier, operators: [NSNumber], options: Int) {
        super.init(leftExpressions: leftExpressions, rightExpressionAttributeType: attributeType, modifier: modifier, operators: operators, options: options)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(reallyMatchForPredicate:)
    public func reallyMatch(for predicate: Any?) -> Double {
        guard let predicate = predicate as? NSPredicate else {
            return 0
        }

        let r = super.match(for: predicate)

        if r != 0 { // super says we can show this, but can we ?
            for subpredicate in (predicate as? NSCompoundPredicate)?.subpredicates ?? [] {
                var ok = false
                if let subpredicate = subpredicate as? NSPredicate {
                    for rt in subtemplates where rt.match(for: subpredicate) != 0 {
                        ok = true
                        break
                    }
                }
                if !ok {
                    return 0
                }
            }
        }

        return r
    }
}
