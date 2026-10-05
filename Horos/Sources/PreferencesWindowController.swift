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
import ObjectiveC
import PreferencePanes
import SecurityInterface

/// One pane of the preferences window: a built-in NSPreferencePane subclass
/// named by `resourceName`, or a `.prefPane` bundle of that name in
/// `parentBundle`. The pane is made on first use and shared by name.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// <Horos/PreferencesWindowController.h> are those of the former class.
// Main actor: the preferences window makes the contexts of its panes and asks
// them for their panes on the main thread.
@MainActor
@objc(PreferencesWindowContext)
public final class PreferencesWindowContext: NSObject {
    /// Every pane made so far, by resource name: a pane is made once.
    private static let prefPanes = NSMutableDictionary()

    // Atomic and retained in the former header.
    @objc public var title: String?
    @objc public var parentBundle: Bundle?
    @objc public var resourceName: String?

    private var _pane: NSPreferencePane?

    public override init() {
        super.init()
    }

    @objc(initWithTitle:withResourceNamed:inBundle:)
    public init(title: String?, withResourceNamed resourceName: String?, inBundle parentBundle: Bundle?) {
        super.init()

        self.title = title
        self.parentBundle = parentBundle
        self.resourceName = resourceName
    }

    /// Nonatomic and retained, as it was. Reading it makes the pane, which can
    /// raise (a pane initializer loads its nib): the preferences window reads
    /// it through HorosObjCException.
    @objc public var pane: NSPreferencePane? {
        get {
            if _pane == nil {
                var builtinPrefPaneClass: AnyClass? = resourceName.flatMap { NSClassFromString($0) }

                if let candidate = builtinPrefPaneClass, !candidate.isSubclass(of: NSPreferencePane.self) {
                    builtinPrefPaneClass = nil
                }

                if let resourceName = resourceName, let pane = PreferencesWindowContext.prefPanes.object(forKey: resourceName) {
                    return pane as? NSPreferencePane
                }

                if let builtinPrefPaneClass = builtinPrefPaneClass as? NSPreferencePane.Type {
                    self.pane = builtinPrefPaneClass.init(bundle: Bundle.main)
                } else {
                    let path = parentBundle?.path(forResource: resourceName, ofType: "prefPane")
                    let bundle = path.flatMap { Bundle(path: $0) }
                    if let bundle = bundle, let principalClass = bundle.principalClass as? NSPreferencePane.Type {
                        self.pane = principalClass.init(bundle: bundle)
                    } else {
                        self.pane = nil
                    }
                }

                if let pane = _pane {
                    guard let resourceName = resourceName else {
                        // -[NSMutableDictionary setObject:forKey:] raised for a nil key.
                        NSException(name: .invalidArgumentException,
                                    reason: "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil",
                                    userInfo: nil).raise()
                        return _pane
                    }
                    PreferencesWindowContext.prefPanes.setObject(pane, forKey: resourceName as NSString)
                }
            }

            return _pane
        }
        set {
            _pane = newValue
        }
    }
}

/// The document view the selected pane is laid out in.
@objc(PreferencesFlippedView)
final class PreferencesFlippedView: NSView {
    override var isFlipped: Bool {
        return true
    }
}

/// Window Controller for Preferences
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// <Horos/PreferencesWindowController.h> are those of the former class. The
/// category PreferencesWindowController (DCMTK) stays Objective-C++ and
/// extends it.
@objc(PreferencesWindowController)
public final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    /// Plugin panes, as [resourceName, parentBundle, title, image] arrays.
    private static let pluginPanes = NSMutableArray()

    // Outlets were protected instance variables; the nib sets them by name.
    @IBOutlet var panesListView: PreferencesView!
    @IBOutlet var authButton: NSButton!
    /// Readonly in the former header; set by the nib.
    @IBOutlet @objc public private(set) var authView: SFHorosAuthorizationView!

    private var currentContextStorage: PreferencesWindowContext?

    /// The window's `currentContext` binding reads this; -setCurrentContext:
    /// sends its change notifications.
    @objc var currentContext: PreferencesWindowContext? {
        return currentContextStorage
    }

    @objc public private(set) var animations = NSMutableArray()

    @objc(sharedPreferencesWindowController)
    public class func sharedPreferencesWindowController() -> PreferencesWindowController {
        var prefsController: PreferencesWindowController?

        for window in NSApp.windows {
            if let controller = window.windowController as? PreferencesWindowController {
                prefsController = controller
                break
            }
        }

        if prefsController == nil {
            let created = PreferencesWindowController()
            // The former method never released the controller it made: its
            // window lives on and is found again through NSApp.windows. The
            // window does not own its controller, so keep that reference.
            _ = Unmanaged.passRetained(created)
            prefsController = created
        }

        return prefsController!
    }

    public override var windowNibName: NSNib.Name? {
        return "PreferencesWindow"
    }

    /// -initWithWindowNibName:@"PreferencesWindow"; the window is loaded here.
    @objc public init() {
        super.init(window: nil)

        window?.delegate = self
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(addPaneWithResourceNamed:inBundle:withTitle:image:toGroupWithName:)
    func addPane(withResourceNamed resourceName: String?, inBundle parentBundle: Bundle?, withTitle title: String,
                 image: NSImage?, toGroupWithName groupName: String) {
        var builtinPrefPaneClass: AnyClass? = resourceName.flatMap { NSClassFromString($0) }

        if let candidate = builtinPrefPaneClass, !candidate.isSubclass(of: NSPreferencePane.self) {
            builtinPrefPaneClass = nil
        }

        if parentBundle?.path(forResource: resourceName, ofType: "prefPane") == nil && builtinPrefPaneClass == nil {
            NSLog("Warning: preferences pane %@ not added because resource %@ not found in %@",
                  title, resourceName ?? "(null)", parentBundle?.resourcePath ?? "(null)")
            return
        }

        let context = PreferencesWindowContext(title: title, withResourceNamed: resourceName, inBundle: parentBundle)
        panesListView.addItem(withTitle: title, image: image, toGroupWithName: groupName, context: context)
    }

    @objc(addPluginPaneWithResourceNamed:inBundle:withTitle:image:)
    public class func addPluginPane(withResourceNamed resourceName: String?, inBundle parentBundle: Bundle?,
                                    withTitle title: String?, image: NSImage?) {
        var image = image
        if image == nil {
            image = NSImage(named: "horosplugin")

            if let resourceName = resourceName, (resourceName as NSString).range(of: "osirixplugin", options: .caseInsensitive).location != NSNotFound {
                image = NSImage(named: "osirixplugin")
            } else {
                image = NSImage(named: "horosplugin")
            }
        }

        // +arrayWithObjects: stopped at the first nil.
        var items: [Any] = []
        for item in [resourceName as Any?, parentBundle, title, image] {
            guard let item = item else { break }
            items.append(item)
        }
        pluginPanes.add(items as NSArray)
    }

    @objc(removePluginPaneWithBundle:)
    public class func removePluginPane(with parentBundle: Bundle?) {
        for case let pluginPane as NSArray in pluginPanes {
            if (pluginPane.object(at: 1) as AnyObject) === parentBundle {
                pluginPanes.remove(pluginPane)
                return
            }
        }
    }

    @objc(view:recursiveBindEnableToObject:withKeyPath:)
    func view(_ view: NSView?, recursiveBindEnableTo obj: Any?, withKeyPath keyPath: String) {
        guard let view = view else { return }
        if view is NSControl {
            var bki = 0
            var bk = ""
            var doBind = true

            while doBind {
                bki += 1
                bk = "enabled" + (bki == 1 ? "" : String(bki))

                guard let b = view.infoForBinding(NSBindingName(bk)) else { break }

                if (b[.observedObject] as AnyObject?) === (obj as AnyObject?) && (b[.observedKeyPath] as? String) == keyPath {
                    doBind = false // already bound
                }
            }

            if doBind {
                var bound = false
                do {
                    try HorosObjCException.perform {
                        view.bind(NSBindingName(bk), to: obj as Any, withKeyPath: keyPath,
                                  options: [.conditionallySetsEnabled: NSNumber(value: true)])
                        bound = true
                    }
                } catch {
                    let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                    NSLog("Warning: %@", exception?.description ?? error.localizedDescription)
                }
                if bound {
                    return
                }
            }
        }

        for subview in view.subviews {
            self.view(subview, recursiveBindEnableTo: obj, withKeyPath: keyPath)
        }
    }

    @objc(view:recursiveUnBindEnableFromObject:withKeyPath:)
    func view(_ view: NSView?, recursiveUnBindEnableFrom obj: Any?, withKeyPath keyPath: String) {
        guard let view = view else { return }
        if view is NSControl {
            var bki = 0
            var bk = ""
            var unbind = false

            while !unbind {
                bki += 1
                bk = "enabled" + (bki == 1 ? "" : String(bki))

                guard let b = view.infoForBinding(NSBindingName(bk)) else { break }

                if (b[.observedObject] as AnyObject?) === (obj as AnyObject?) && (b[.observedKeyPath] as? String) == keyPath {
                    unbind = true
                }
            }

            if unbind {
                view.unbind(NSBindingName(bk))
            }
            return
        }

        for subview in view.subviews {
            self.view(subview, recursiveUnBindEnableFrom: obj, withKeyPath: keyPath)
        }
    }

    @objc(pane:enable:)
    func pane(_ pane: NSPreferencePane?, enable: Bool) {
        willChangeValue(forKey: "isUnlocked")

        authButton.image = NSImage(named: enable ? "NSLockUnlockedTemplate" : "NSLockLockedTemplate")

        didChangeValue(forKey: "isUnlocked")

        let enableControls = NSSelectorFromString("enableControls:")
        if let pane = pane, pane.responds(to: enableControls) {
            // retro-compatibility with old preference bundles: -enableControls:(BOOL)
            typealias EnableControls = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
            let implementation = unsafeBitCast(pane.method(for: enableControls), to: EnableControls.self)
            implementation(pane, enableControls, ObjCBool(enable))
        }
    }

    /// SFAuthorizationView's informal delegate protocol, a category of NSObject.
    public override func authorizationViewDidAuthorize(_ view: SFAuthorizationView!) {
        MainActor.assumeIsolated {
            pane(currentContextStorage?.pane, enable: true)
        }
    }

    /// SFAuthorizationView's informal delegate protocol, a category of NSObject.
    public override func authorizationViewDidDeauthorize(_ view: SFAuthorizationView!) {
        MainActor.assumeIsolated {
            pane(currentContextStorage?.pane, enable: false)
        }
    }

    @objc public func isUnlocked() -> Bool {
        return !UserDefaults.standard.bool(forKey: "AUTHENTICATION") || authView?.authorizationState() == SFAuthorizationViewUnlockedState
    }

    @IBAction @objc(authAction:)
    public func authAction(_ sender: Any?) {
        authView?.buttonPressed(sender)
    }

    /// The authorization right: SFAuthorizationView may keep the pointer, so it
    /// is a literal's static storage, as the former C string literal was.
    private static func cString(_ string: StaticString) -> UnsafePointer<CChar> {
        return UnsafeRawPointer(string.utf8Start).assumingMemoryBound(to: CChar.self)
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            authView.setDelegate(self)

            if UserDefaults.standard.bool(forKey: "AUTHENTICATION") {
                authView.setString(PreferencesWindowController.cString("BUNDLE_IDENTIFIER.preferences.database"))
            } else {
                authView.setString(PreferencesWindowController.cString("BUNDLE_IDENTIFIER.preferences.allowalways"))
                authView.setEnabled(false)
            }

            _ = authView.updateStatus(self)

            let mainScreenFrame = NSScreen.main?.visibleFrame ?? .zero
            window?.setFrameTopLeftPoint(NSPoint(x: mainScreenFrame.origin.x, y: mainScreenFrame.origin.y + mainScreenFrame.size.height))

            panesListView.buttonActionTarget = self
            panesListView.buttonActionSelector = #selector(setCurrentContext(_:))

            let bundle = Bundle.main
            var name: String

            name = NSLocalizedString("Basics", comment: "Section in preferences window")
            addPane(withResourceNamed: "OSIGeneralPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("General", comment: "Panel in preferences window"), image: NSImage(named: "GeneralPreferences"), toGroupWithName: name)
            addPane(withResourceNamed: "OSIDatabasePreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("Database", comment: "Panel in preferences window"), image: NSImage(named: "DatabaseIcon"), toGroupWithName: name)
            addPane(withResourceNamed: "OSICDPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("CD/DVD", comment: "Panel in preferences window"), image: NSImage(named: "CD"), toGroupWithName: name)
            addPane(withResourceNamed: "OSIHangingPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("Protocols", comment: "Panel in preferences window"), image: NSImage(named: "ZoomToFit"), toGroupWithName: name)
            addPane(withResourceNamed: "OSIHotKeysPref", inBundle: bundle, withTitle: NSLocalizedString("Hot Keys", comment: "Panel in preferences window"), image: NSImage(named: "key"), toGroupWithName: name)
            addPane(withResourceNamed: "HorosMenuShortcutPref", inBundle: bundle, withTitle: NSLocalizedString("Menu Shortcuts", comment: "Panel in preferences window"), image: NSImage(named: "key"), toGroupWithName: name)

            name = NSLocalizedString("Display", comment: "Section in preferences window")
            addPane(withResourceNamed: "OSIViewerPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("Viewers", comment: "Panel in preferences window"), image: NSImage(named: "AxialSmall"), toGroupWithName: name)
            addPane(withResourceNamed: "OSI3DPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("3D", comment: "Panel in preferences window"), image: NSImage(named: "VolumeRendering"), toGroupWithName: name)
            addPane(withResourceNamed: "OSIPETPreferencePane", inBundle: bundle, withTitle: NSLocalizedString("PET", comment: "Panel in preferences window"), image: NSImage(named: "SUV"), toGroupWithName: name)
            addPane(withResourceNamed: "OSICustomImageAnnotations", inBundle: bundle, withTitle: NSLocalizedString("Annotations", comment: "Panel in preferences window"), image: NSImage(named: "CustomImageAnnotations"), toGroupWithName: name)
            addPane(withResourceNamed: "AYDicomPrintPref", inBundle: bundle, withTitle: NSLocalizedString("DICOM Print", comment: "Panel in preferences window"), image: NSImage(named: "Print"), toGroupWithName: name)

            name = NSLocalizedString("Sharing", comment: "Section in preferences window")
            addPane(withResourceNamed: "OSIListenerPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("Listener", comment: "Panel in preferences window"), image: NSImage(named: "Network"), toGroupWithName: name)
            addPane(withResourceNamed: "OSILocationsPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("Locations", comment: "Panel in preferences window"), image: NSImage(named: "AccountPreferences"), toGroupWithName: name)
            addPane(withResourceNamed: "OSIAutoroutingPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("Routing", comment: "Panel in preferences window"), image: NSImage(named: "route"), toGroupWithName: name)
            addPane(withResourceNamed: "OSIWebSharingPreferencePanePref", inBundle: bundle, withTitle: NSLocalizedString("Web Server", comment: "Panel in preferences window"), image: NSImage(named: "Safari"), toGroupWithName: name)
            addPane(withResourceNamed: "OSIPACSOnDemandPreferencePane", inBundle: bundle, withTitle: NSLocalizedString("On-Demand", comment: "Panel in preferences window"), image: NSImage(named: "Cloud"), toGroupWithName: name)

            for case let pluginPane as NSArray in PreferencesWindowController.pluginPanes {
                addPane(withResourceNamed: pluginPane.object(at: 0) as? String,
                        inBundle: pluginPane.object(at: 1) as? Bundle,
                        withTitle: pluginPane.object(at: 2) as? String ?? "",
                        image: pluginPane.object(at: 3) as? NSImage,
                        toGroupWithName: NSLocalizedString("Plugins", comment: "Title of Plugins section in preferences window"))
            }

            let initialSize = panesListView.frame.size

            window?.contentView = panesListView

            synchronizeSize(withContent: initialSize)

            // If we need to remove a plugin with a custom pref pane
            // (PluginManagerController.h imports WebKit and the plugin headers,
            // which the bridging header does not take: the class is found by name.)
            if let pluginManagerController = NSClassFromString("PluginManagerController") {
                for window in NSApp.windows {
                    if window.windowController?.isKind(of: pluginManagerController) == true {
                        window.close()
                    }
                }
            }
        }
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
        showAllAction(nil)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A context without a pane answered NSUnselectCancel (0), as it did.
        if let current = currentContextStorage, (current.pane?.shouldUnselect ?? .unselectCancel) == .unselectCancel {
            return false
        }

        return true
    }

    public func windowWillClose(_ notification: Notification) {
        setCurrentContext(nil)

        window?.acceptsMouseMovedEvents = false
        UserDefaults.standard.synchronize()
    }

    @objc(setCurrentContextWithResourceName:)
    public func setCurrentContext(withResourceName name: String?) {
        let panesCount = panesListView.itemsCount()

        var index: UInt = 0
        while index < panesCount {
            let context = panesListView.contextForItem(at: index) as? PreferencesWindowContext
            if context?.resourceName == name && name != nil {
                setCurrentContext(panesListView.contextForItem(at: index) as? PreferencesWindowContext)
            }
            index += 1
        }
    }

    @objc(setCurrentContext:)
    public func setCurrentContext(_ context: PreferencesWindowContext?) {
        if context === currentContextStorage {
            return
        }

        if currentContextStorage == nil || (currentContextStorage?.pane?.shouldUnselect ?? .unselectCancel) != .unselectCancel {
            // Construct and load before touching the displayed view or starting KVO.
            // Both the pane initializer and loadMainView may fail (e.g. a missing nib).
            // mainView is declared nonnull but stays nil until a view is loaded:
            // it is read through KVC, which the optimizer cannot assume non-nil.
            if let context = context {
                var nextPane: NSPreferencePane?
                do {
                    try HorosObjCException.perform {
                        nextPane = context.pane
                        if let pane = nextPane, pane.value(forKey: "mainView") == nil {
                            _ = pane.loadMainView()
                        }
                    }
                } catch {
                    let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                    NSLog("Preferences pane failed to load: %@ (%@)", context.resourceName ?? "(null)", exception?.name.rawValue ?? "(null)")
                    nextPane = nil
                }
                if nextPane?.value(forKey: "mainView") == nil {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Preferences Could Not Be Opened", comment: "")
                    alert.informativeText = String(format: NSLocalizedString("The %@ preferences could not be loaded. The previous panel has been kept. Check that the application or preference plugin is installed completely, then try again.", comment: ""), context.title ?? "")
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    if let window = self.window {
                        alert.beginSheetModal(for: window, completionHandler: nil)
                    }
                    return
                }
            }
            willChangeValue(forKey: "currentContext")

            // remove old view
            currentContextStorage?.pane?.willUnselect()
            currentContextStorage?.pane?.mainView.window?.makeFirstResponder(nil)

            if let current = currentContextStorage {
                view(current.pane?.mainView, recursiveUnBindEnableFrom: self, withKeyPath: "isUnlocked")
            }

            // add new view

            var title = NSLocalizedString("IsiX DICOM Viewer Preferences", comment: "")
            var newSize: NSSize

            if let context = context, let pane = context.pane {
                let cview: NSView = pane.mainView
                title = title.appendingFormat("%@%@", NSLocalizedString(": ", comment: "Semicolon with space prefix and suffix (example: english ': ', french ' : ')"), context.title ?? "(null)")

                pane.willSelect()

                view(cview, recursiveBindEnableTo: self, withKeyPath: "isUnlocked")

                let fview = PreferencesFlippedView(frame: cview.frame)
                fview.translatesAutoresizingMaskIntoConstraints = false
                fview.addSubview(cview)
                fview.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "|[cview]|", options: [], metrics: nil, views: ["cview": cview]))
                fview.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|[cview]|", options: [], metrics: nil, views: ["cview": cview]))

                let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: fview.fittingSize.width, height: fview.fittingSize.height))
                sv.documentView = fview

                sv.hasHorizontalScroller = false
                sv.borderType = .noBorder
                sv.backgroundColor = NSColor.windowBackgroundColor
                sv.drawsBackground = true
                sv.horizontalScrollElasticity = .none
                sv.verticalScrollElasticity = .none

                window?.contentView = sv

                newSize = fview.fittingSize
            } else {
                newSize = panesListView.frame.size
                window?.contentView = panesListView
            }

            window?.title = title

            currentContextStorage?.pane?.didUnselect()
            currentContextStorage = context
            context?.pane?.didSelect()

            synchronizeSize(withContent: newSize)

            didChangeValue(forKey: "currentContext")
        }
    }

    isolated deinit {
        setCurrentContext(nil)
    }

    @objc func toolbarHeight() -> CGFloat {
        guard let window = window else { return 0 }
        var toolbarHeight: CGFloat = 0

        if let toolbar = window.toolbar, toolbar.isVisible {
            let windowFrame = type(of: window).contentRect(forFrameRect: window.frame, styleMask: window.styleMask)

            toolbarHeight = windowFrame.height - (window.contentView?.frame.height ?? 0)
        }

        return toolbarHeight
    }

    @objc(synchronizeSizeWithContent:)
    func synchronizeSize(withContent newContentSize: NSSize) {
        guard let window = window else { return }
        var newSize = type(of: window).frameRect(forContentRect: NSRect(x: 0, y: 0, width: newContentSize.width, height: newContentSize.height + window.toolbarHeight()),
                                                 styleMask: window.styleMask).size

        let maxHeight = window.screen?.visibleFrame.size.height ?? 0
        if newSize.height > maxHeight {
            newSize.height = maxHeight
        }

        let frame = window.frame

        let newFrame = NSRect(x: frame.origin.x, y: frame.origin.y + (frame.size.height - newSize.height), width: newSize.width, height: newSize.height)

        window.setFrame(newFrame, display: true, animate: true)
    }

    @IBAction @objc(navigationAction:)
    public func navigationAction(_ sender: Any?) {
        var index = -1
        if let current = currentContextStorage {
            index = panesListView.indexOfItem(withContext: current)
        }

        // A nil sender answered 0, as it did.
        switch (sender as? NSSegmentedControl)?.selectedSegment ?? 0 {
        case 0: index -= 1
        case 1: index += 1
        default: break
        }

        let panesCount = Int(bitPattern: panesListView.itemsCount())
        if index < 0 { index = panesCount - 1 }
        if index >= panesCount { index = 0 }

        setCurrentContext(panesListView.contextForItem(at: UInt(bitPattern: index)) as? PreferencesWindowContext)
    }

    @IBAction @objc(showAllAction:)
    public func showAllAction(_ sender: Any?) {
        setCurrentContext(nil)
    }

    // ------

    @objc public func reopenDatabase() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "DEFAULT_DATABASELOCATION"), forKey: "DATABASELOCATION")
        defaults.set(defaults.string(forKey: "DEFAULT_DATABASELOCATIONURL"), forKey: "DATABASELOCATIONURL")
        BrowserController.currentBrowser()?.resetToLocalDatabase()
    }
}
