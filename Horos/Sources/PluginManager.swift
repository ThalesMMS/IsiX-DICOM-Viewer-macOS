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

import Cocoa
import IsiXPluginLoading
import IsiXStorage

// What the static variables of the former Objective-C file held: the loaded
// plugins, by menu title, toolbar name, file format and bundle path.
//
// They are written on the main thread - at launch, when a plugin is installed,
// when the menus are built - and read from any thread: importing, networking and
// the web portal ask for the file format and pre-process plugins. The accessors
// hand out the collection itself, typed mutable, as the SDK always did, and the
// caller enumerates it without a lock. So a collection that has been published
// is never changed again: a change is made on a copy, which then replaces it
// under the lock. A reader holding the former one keeps a collection nobody
// changes. The fusion menu is the exception: a menu, only ever used on
// the main thread; only its reference is kept under the lock.
fileprivate enum Registry {
    struct Storage {
        var plugins: NSMutableDictionary? = nil
        var pluginsDict: NSMutableDictionary? = nil
        var fileFormatPlugins: NSMutableDictionary? = nil
        var reportPlugins: NSMutableDictionary? = nil
        var pluginsBundleDictionnary: NSMutableDictionary? = nil
        var preProcessPlugins: NSMutableArray? = nil
        var fusionPluginsMenu: NSMenu? = nil
        var fusionPlugins: NSMutableArray? = nil
        var pluginsNames: NSMutableDictionary? = nil
    }

    private static let lock = NSLock()
    /// Read and written only under `lock`.
    nonisolated(unsafe) private static var storage = Storage()

    static func value<T>(_ key: KeyPath<Storage, T>) -> T {
        lock.lock(); defer { lock.unlock() }
        return storage[keyPath: key]
    }

    static func set<T>(_ key: WritableKeyPath<Storage, T>, _ value: T) {
        lock.lock(); defer { lock.unlock() }
        storage[keyPath: key] = value
    }

    /// Changes a published dictionary by replacing it with a changed copy. The
    /// body runs outside the lock: it may raise the NSException a nil key or
    /// object raises, and then nothing is published, as nothing was inserted.
    /// Writers are on the main thread, so two changes do not interleave.
    static func change(_ key: WritableKeyPath<Storage, NSMutableDictionary?>,
                       _ body: (NSMutableDictionary?) -> Void) {
        let copy = value(key).map { NSMutableDictionary(dictionary: $0) }
        body(copy)
        set(key, copy)
    }

    /// The same, for a published array.
    static func change(_ key: WritableKeyPath<Storage, NSMutableArray?>,
                       _ body: (NSMutableArray?) -> Void) {
        let copy = value(key).map { NSMutableArray(array: $0 as [AnyObject]) }
        body(copy)
        set(key, copy)
    }

    // Replacing a whole collection publishes it; it is not changed in place.
    static var plugins: NSMutableDictionary? {
        get { value(\.plugins) }
        set { set(\.plugins, newValue) }
    }
    static var pluginsDict: NSMutableDictionary? {
        get { value(\.pluginsDict) }
        set { set(\.pluginsDict, newValue) }
    }
    static var fileFormatPlugins: NSMutableDictionary? {
        get { value(\.fileFormatPlugins) }
        set { set(\.fileFormatPlugins, newValue) }
    }
    static var reportPlugins: NSMutableDictionary? {
        get { value(\.reportPlugins) }
        set { set(\.reportPlugins, newValue) }
    }
    static var pluginsBundleDictionnary: NSMutableDictionary? {
        get { value(\.pluginsBundleDictionnary) }
        set { set(\.pluginsBundleDictionnary, newValue) }
    }
    static var preProcessPlugins: NSMutableArray? {
        get { value(\.preProcessPlugins) }
        set { set(\.preProcessPlugins, newValue) }
    }
    static var fusionPluginsMenu: NSMenu? {
        get { value(\.fusionPluginsMenu) }
        set { set(\.fusionPluginsMenu, newValue) }
    }
    static var fusionPlugins: NSMutableArray? {
        get { value(\.fusionPlugins) }
        set { set(\.fusionPlugins, newValue) }
    }
    static var pluginsNames: NSMutableDictionary? {
        get { value(\.pluginsNames) }
        set { set(\.pluginsNames, newValue) }
    }
}

// The plugin manager reads property-list and dictionary values the way
// Objective-C messaging did: a nil value answers zero or nil, and a value of the
// wrong type, or a nil inserted into a collection, raises the NSException the
// message raised. The callers run inside HorosObjCException.perform where the
// former code had @try, so those exceptions keep ending where they ended.
fileprivate enum ObjC {
    /// The argument of a "%@": nil prints (null), a class prints its name.
    static func arg(_ value: Any?) -> CVarArg {
        guard let value = value else { return "(null)" as NSString }
        if let type = value as? AnyClass { return NSStringFromClass(type) as NSString }
        if let object = (value as AnyObject) as? NSObject { return object }
        return "\(value)" as NSString
    }

    /// [NSString stringWithFormat:format, ...] with object arguments.
    static func format(_ format: String, _ values: Any?...) -> String {
        return String(format: format, arguments: values.map { arg($0) })
    }

    /// The NSException that HorosObjCException caught.
    static func exception(_ error: Error) -> NSException? {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }

    /// -[NSMutableDictionary setObject:forKey:]: a nil object or key raises.
    static func set(_ dictionary: NSMutableDictionary?, _ object: Any?, _ key: Any?) {
        _ = dictionary?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
    }

    /// -[NSMutableArray addObject:]: a nil object raises.
    static func add(_ array: NSMutableArray?, _ object: Any?) {
        _ = array?.perform(#selector(NSMutableArray.add(_:)), with: object)
    }

    /// [value isEqualToString:string], NO for a nil value.
    static func isEqualToString(_ value: Any?, _ string: String?) -> Bool {
        guard let value = value else { return false }
        guard let text = value as? NSString else {
            _ = (value as AnyObject).perform(NSSelectorFromString("isEqualToString:"), with: string)
            return false
        }
        guard let string = string else { return false }
        return text.isEqual(to: string)
    }

    /// [value boolValue], NO for nil.
    static func bool(_ value: Any?) -> Bool {
        guard let value = value else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? NSString { return text.boolValue }
        _ = (value as AnyObject).perform(NSSelectorFromString("boolValue"))
        return false
    }

    /// [value objectAtIndex:index]: out of range raises NSRangeException.
    static func object(_ value: Any, at index: Int) -> Any? {
        if let array = value as? NSArray { return array.object(at: index) }
        _ = (value as AnyObject).perform(NSSelectorFromString("objectAtIndex:"))
        return nil
    }

    /// [NSArray arrayWithObjects:..., nil], which ends at the first nil.
    static func array(upToFirstNil values: [Any?]) -> NSMutableArray {
        let array = NSMutableArray()
        for value in values {
            guard let value = value else { break }
            array.add(value)
        }
        return array
    }

    /// [base stringByAppendingPathComponent:component], also for a nil component.
    static func appendingPathComponent(_ base: NSString?, _ component: String?) -> String? {
        guard let base = base else { return nil }
        guard let component = component else {
            return base.perform(#selector(NSString.appendingPathComponent(_:)), with: nil)?.takeUnretainedValue() as? String
        }
        return base.appendingPathComponent(component)
    }

    /// [object class]: what the object answers, which is not its isa for a
    /// KVO-observed object.
    static func classOf(_ object: Any?) -> AnyClass? {
        guard let object = object else { return nil }
        return (object as AnyObject).perform(NSSelectorFromString("class"))?.takeUnretainedValue() as? AnyClass
    }
}

/** \brief Mangages PluginFilter loading */
@objc(PluginManager)
public final class PluginManager: NSObject {

    /// The plugins an accepted update downloads one after the other. The
    /// former property was atomic; it is only used on the main thread, by the
    /// update alert and the download notifications.
    @objc public var downloadQueue: NSMutableArray!
    private var startedUpdateProcess = false

    @objc(startProtectForCrashWithFilter:)
    public class func startProtectForCrash(withFilter filter: Any!) {
        let filterClassName = ObjC.classOf(filter).map { NSStringFromClass($0) }
        for case let bundle as Bundle in Registry.pluginsBundleDictionnary?.allValues ?? [] {
            let principalName = bundle.principalClass.map { NSStringFromClass($0) }
            if let filterClassName = filterClassName, let principalName = principalName,
               (filterClassName as NSString).isEqual(to: principalName) {
                PluginManager.startProtectForCrash(withPath: bundle.bundlePath)
                return
            }
        }

        // principalClass belongs to NSBundle, and this argument is the filter the
        // loop above compares by -class. Asking the filter for it raised
        // NSInvalidArgumentException out of applicationWillFinishLaunching:, which
        // silently skipped DCMTK, the store SCP, the database and browser classes,
        // the Web Portal, the Bonjour publisher and the XML-RPC interface.
        NSLog("***** unknown plugin - startProtectForCrashWithFilter - %@", ObjC.arg(filterClassName))
    }

    /// The file naming whatever plugin is being loaded right now, removed when it
    /// finishes: one left behind says the last run stopped inside that plugin.
    @objc public class func crashMarkerPath() -> String! {
        // Beside the plugins themselves, not in /tmp: that one is writable by
        // everybody on the machine and shared by every Horos and OsiriX on it.
        let directory = (PluginManager.userActivePluginsDirectoryPath()! as NSString).deletingLastPathComponent
        return PluginQuarantine.markerPath(inDirectory: directory, forBundle: Bundle.main.bundleIdentifier)
    }

    @objc(startProtectForCrashWithPath:)
    public class func startProtectForCrash(withPath path: String!) {
        let marker = PluginManager.crashMarkerPath()! as NSString
        try? FileManager.default.createDirectory(atPath: marker.deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: nil)
        try? (path as NSString?)?.write(toFile: marker as String, atomically: true, encoding: String.Encoding.utf8.rawValue)
    }

    @objc public class func endProtectForCrash() {
        try? FileManager.default.removeItem(atPath: PluginManager.crashMarkerPath())
    }

    @objc(compareVersion:withVersion:)
    public class func compareVersion(_ v1: String!, withVersion v2: String!) -> Int32 {
        return Int32(PluginManagerCAPICompareVersions(v1, v2).rawValue)
    }

    /// Whether a ComPACS plugin is loaded, asked once: the first call decides,
    /// as the former comPACSTested flag did, but a `static let` also decides
    /// once when two threads ask first.
    private static let comPACSLoaded: Bool = PluginManager.plugins()?.value(forKey: "ComPACS") != nil

    @objc public class func isComPACS() -> Bool {
        return comPACSLoaded
    }

    @objc public class func plugins() -> NSMutableDictionary! {
        return Registry.plugins
    }

    @objc public class func pluginsDict() -> NSMutableDictionary! {
        return Registry.pluginsDict
    }

    @objc public class func fileFormatPlugins() -> NSMutableDictionary! {
        return Registry.fileFormatPlugins
    }

    @objc public class func reportPlugins() -> NSMutableDictionary! {
        return Registry.reportPlugins
    }

    /// The mutable array itself, as before.
    @objc public class func preProcessPlugins() -> NSArray! {
        return Registry.preProcessPlugins
    }

    @objc public class func fusionPluginsMenu() -> NSMenu! {
        return Registry.fusionPluginsMenu
    }

    /// The mutable array itself, as before.
    @objc public class func fusionPlugins() -> NSArray! {
        return Registry.fusionPlugins
    }

    @objc(sortMenu:)
    class func sortMenu(_ menu: NSMenu!) {
        // [CH] Get an array of all menu items.
        let items: [NSMenuItem] = menu?.items ?? []
        menu?.removeAllItems()
        // [CH] Sort the array
        let sorted = (items as NSArray).sortedArray(using: [NSSortDescriptor(key: "title", ascending: true,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))])
        // [CH] ok, now set it back.
        for case let item as NSMenuItem in sorted {
            menu?.addItem(item)
            /**
             * [CH] The following code fixes NSPopUpButton's confusion that occurs when
             * we sort this list. NSPopUpButton listens to the NSMenu's add notifications
             * and hides the first item. Sorting this blows it up.
             **/
            if item.isHidden {
                item.isHidden = false
            }
        }
    }

    @objc(setMenus::::)
    public class func setMenus(_ filtersMenu: NSMenu!, _ roisMenu: NSMenu!, _ othersMenu: NSMenu!, _ dbMenu: NSMenu!) {
        filtersMenu?.removeAllItems()
        roisMenu?.removeAllItems()
        othersMenu?.removeAllItems()
        dbMenu?.removeAllItems()

        // The menus hold the commands of version 1 plugins and the app's own
        // filters. Former plugins, which declared their items in Info.plist
        // (MenuTitles, pluginType), are not loaded, so none of theirs is added.

        // Version 1 plugins register their commands in code.
        PluginManager.addIsiXPluginMenuItems(filtersMenu, roisMenu, othersMenu, dbMenu)

        // The app's own filters have no bundle to declare their items: without these, T2 Fit Map and
        // ROI Enhancement were registered and unreachable from any menu.
        // With no plugins or no menu the former call found nothing to add.
        if let plugins = Registry.plugins, let filtersMenu = filtersMenu, let roisMenu = roisMenu {
            NativeFilterMenus.addItems(for: plugins, filtersMenu: filtersMenu, roisMenu: roisMenu)
        }

        // The target of these items is the class, so +noPlugins: is a class
        // method: as an instance method the class did not answer it, and the
        // menu disabled every one of these items.
        if (filtersMenu?.numberOfItems ?? 0) < 1 {
            let item = NSMenuItem()
            item.title = NSLocalizedString("No plugins available for this menu", comment: "")
            item.target = self as AnyObject
            item.action = NSSelectorFromString("noPlugins:")

            filtersMenu?.insertItem(item, at: 0)
        }

        if (roisMenu?.numberOfItems ?? 0) < 1 {
            let item = NSMenuItem()
            item.title = NSLocalizedString("No plugins available for this menu", comment: "")
            item.target = self as AnyObject
            item.action = NSSelectorFromString("noPlugins:")

            roisMenu?.insertItem(item, at: 0)
        }

        if (othersMenu?.numberOfItems ?? 0) < 1 {
            let item = NSMenuItem()
            item.title = NSLocalizedString("No plugins available for this menu", comment: "")
            item.target = self as AnyObject
            item.action = NSSelectorFromString("noPlugins:")

            othersMenu?.insertItem(item, at: 0)
        }

        if (Registry.fusionPluginsMenu?.numberOfItems ?? 0) <= 1 {
            let item = NSMenuItem()
            item.title = NSLocalizedString("No plugins available for this menu", comment: "")
            item.target = self as AnyObject
            item.action = NSSelectorFromString("noPlugins:")

            Registry.fusionPluginsMenu?.removeItem(at: 0)
            Registry.fusionPluginsMenu?.insertItem(item, at: 0)
        }

        if (dbMenu?.numberOfItems ?? 0) < 1 {
            let item = NSMenuItem()
            item.title = NSLocalizedString("No plugins available for this menu", comment: "")
            item.target = self as AnyObject
            item.action = NSSelectorFromString("noPlugins:")

            dbMenu?.insertItem(item, at: 0)
        }

        PluginManager.sortMenu(dbMenu)
        PluginManager.sortMenu(roisMenu)
        PluginManager.sortMenu(filtersMenu)
        PluginManager.sortMenu(othersMenu)

        let pluginEnum = Registry.plugins?.objectEnumerator()

        while let pluginFilter = pluginEnum?.nextObject() {
            PluginManager.startProtectForCrash(withFilter: pluginFilter)

            do {
                try HorosObjCException.perform {
                    // -setMenus is PluginFilter's; the app's own Swift filters (ROI Enhancement, T2 Fit Map)
                    // do not inherit it, and sending it raised and logged an exception at every launch.
                    if let filter = pluginFilter as? NSObjectProtocol, filter.responds(to: NSSelectorFromString("setMenus")) {
                        _ = filter.perform(NSSelectorFromString("setMenus"))
                    }
                }
            } catch {
                NSLog("***** exception in %@: %@", "+[PluginManager setMenus::::]" as NSString, ObjC.arg(ObjC.exception(error)))
            }

            PluginManager.endProtectForCrash()
        }

        let shortcutMenus = ObjC.array(upToFirstNil: [filtersMenu, roisMenu, othersMenu, dbMenu])
        if let fusionPluginsMenu = Registry.fusionPluginsMenu {
            shortcutMenus.add(fusionPluginsMenu)
        }
        if let mainMenu = onMainActorSync({ NSApp?.mainMenu }) {
            shortcutMenus.add(mainMenu)
        }
        MenuShortcutCatalog.applyStoredAssignments(to: shortcutMenus.compactMap { $0 as? NSMenu })
    }

    public override init() {
        super.init()

        // Set DefaultROINames *before* initializing plugins (which may change these)

        let defaultROINames = NSMutableArray()

        defaultROINames.add("ROI 1")
        defaultROINames.add("ROI 2")
        defaultROINames.add("ROI 3")
        defaultROINames.add("ROI 4")
        defaultROINames.add("ROI 5")

        // Sent through Objective-C so that ViewerController keeps this mutable
        // array itself, as before, and not a bridged copy.
        _ = (ViewerController.self as AnyObject).perform(NSSelectorFromString("setDefaultROINames:"), with: defaultROINames)

        #if !MACAPPSTORE
        PluginManager.discoverPlugins()

        NotificationCenter.default.addObserver(self, selector: #selector(downloadNext(_:)),
                                               name: .AppPluginDownloadInstallDidFinish,
                                               object: nil)
        #endif
    }

    @available(*, deprecated)
    @objc(pathResolved:)
    public class func pathResolved(_ inPath: String!) -> String! {
        return (inPath as NSString?)?.resolvingAlias()
    }

    @objc(unloadPluginWithName:)
    public class func unloadPlugin(withName name: String!) {
        // Does nothing, as before: a loaded plugin stays until Horos quits.
        // Unloading crashed when a plugin used KVO bindings, and the former
        // +unloadPluginBundle: this called had its body commented out.
    }

    @objc(isPluginBundleSignatureValid:)
    class func isPluginBundleSignatureValid(_ path: String!) -> Bool {
        var error: NSError? = nil
        let allowed = PluginManagerCAPISignatureAllowsLoading(path, &error)
        if !allowed {
            let reason = ObjC.format(NSLocalizedString("The plugin signature is invalid: %@. Reinstall an intact copy from its author.", comment: ""), error?.localizedDescription)
            PluginManagerCAPIRecordLoad((path as NSString?)?.resolvingAlias(), NSLocalizedString("Blocked", comment: ""), reason)
            NSLog("Plugin signature validation failed (%@ %ld): %@", ObjC.arg(error?.domain), error?.code ?? 0, reason as NSString)
        }
        return allowed
    }

    @objc(loadPluginAtPath:)
    public class func loadPlugin(atPath path: String!) {
        #if !MACAPPSTORE
        let name = (path as NSString).lastPathComponent

        // Only version 1 bundles load. A former plugin is refused by its
        // extension before anything else: no bundle is opened, none of its
        // code runs, and it is left where it is.
        guard PluginAdmission.isManaged(name) else {
            let diagnosticPath = (path as NSString?)?.resolvingAlias()
            if PluginAdmission.kind(of: name) == .formerAPI {
                let reason = PluginInspector().inspect(bundleAt: URL(fileURLWithPath: path)).summary
                PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Incompatible", comment: ""), reason)
                NSLog("Plugin of the former API not loaded: %@", path as NSString)
            }
            return
        }

        if Registry.pluginsNames?.value(forKey: ((name as NSString).lastPathComponent as NSString).deletingPathExtension) != nil {
            PluginManagerCAPIRecordLoad((path as NSString?)?.resolvingAlias(), NSLocalizedString("Blocked", comment: ""), NSLocalizedString("Another plugin with this name was selected for loading. Remove the duplicate through Plugin Manager and restart IsiX DICOM Viewer.", comment: ""))
            NSLog("***** Multiple plugins: %@", (name as NSString).lastPathComponent as NSString)

            var message = NSLocalizedString("Warning! Multiple instances of the same plugin have been found. Only one instance will be loaded. Check the Plugin Manager (Plugins menu) for multiple identical plugins.", comment: "")

            message = (message as NSString).appendingFormat("\r\r%@", (name as NSString).lastPathComponent as NSString) as String

            HorosAlertPanel.run(title: NSLocalizedString("Plugins", comment: ""), message: message, defaultButton: nil, alternateButton: nil, otherButton: nil)

            return
        }

        Registry.change(\.pluginsNames) { $0?.setValue((path as NSString).deletingLastPathComponent, forKey: ((name as NSString).lastPathComponent as NSString).deletingPathExtension) }
        PluginManager.loadIsiXPlugin(atPath: path)

        let outcome = PluginManagerCAPILoadOutcome((path as NSString?)?.resolvingAlias(), true)
        if ObjC.isEqualToString(outcome["loadState"], NSLocalizedString("Loaded", comment: "")) {
            PluginUpdateRecovery.discardPrevious(forDestination: path)
        }
        #endif
    }

    @objc public class func discoverPlugins() {
        #if !MACAPPSTORE
        do {
            try HorosObjCException.perform {
                let appPath = Bundle.main.builtInPlugInsPath
                // The home folder and the root of the disk, unless this is an isolated development launch.
                let isolatedFolder = PluginManager.isolatedPluginsFolder()
                let folders = StorageLocations.discoveryFolders(userDomain: PluginManager.userPluginsDomain(),
                                                                systemDomain: PluginManager.systemPluginsDomain())
                let userPath = folders[0], userAppStorePath = folders[1], sysPath = folders[2]

                let paths = ObjC.array(upToFirstNil: [NSNull(), appPath, userPath, userAppStorePath, sysPath]) // [NSNull null] is a placeholder for launch parameters load commands

                Registry.set(\.pluginsBundleDictionnary, NSMutableDictionary())
                Registry.set(\.plugins, NSMutableDictionary())
                Registry.set(\.pluginsDict, NSMutableDictionary())
                Registry.set(\.fileFormatPlugins, NSMutableDictionary())
                Registry.set(\.preProcessPlugins, NSMutableArray(capacity: 0))
                Registry.set(\.reportPlugins, NSMutableDictionary())
                Registry.set(\.pluginsNames, NSMutableDictionary())
                Registry.set(\.fusionPlugins, NSMutableArray(capacity: 0))

                Registry.set(\.fusionPluginsMenu, NSMenu(title: ""))
                Registry.fusionPluginsMenu!.insertItem(withTitle: NSLocalizedString("Select a fusion plug-in", comment: ""), action: nil, keyEquivalent: "", at: 0)

                NSLog("|||||||||||||||||| Plugins loading START ||||||||||||||||||")
                if let isolatedFolder = isolatedFolder {
                    NSLog("Plugins isolated in %@: the user's and the computer's plugins folders are not read", isolatedFolder as NSString)
                }

                let pluginCrash: String = PluginManager.crashMarkerPath()
                if FileManager.default.fileExists(atPath: pluginCrash) && !UserDefaults.standard.bool(forKey: "DoNotDeleteCrashingPlugins") {
                    let pluginCrashPath = try? NSString(contentsOfFile: pluginCrash, encoding: String.Encoding.utf8.rawValue)
                    // A marker that names a former plugin was left by an earlier
                    // version: such a plugin is not loaded any more, so it cannot
                    // break this start, and it is not this app's to move.
                    if let named = pluginCrashPath as String?, PluginAdmission.kind(of: named) == .formerAPI {
                        NSLog("Crash marker of an earlier version ignored; plugins of the former API are not loaded: %@", named as NSString)
                    } else {
                        if PluginUpdateRecovery.shouldEnterPluginLessMode(markerExists: true) {
                            DCMPix.setRunOsiriXInProtectedMode(true)
                        }
                        // Recovery acts only on a plugin in this app's own folders: the
                        // marker names a path, and a plugin given with --LoadPlugin, or
                        // any other path, is not this app's to restore or move.
                        let ownPlugin = PluginManager.isInOwnPluginsFolder((pluginCrashPath as String?) ?? "")
                                && PluginAdmission.mayManage(bundleAt: URL(fileURLWithPath: (pluginCrashPath as String?) ?? ""))
                        // A nil path reaches the Swift recovery methods as an empty string.
                        if ownPlugin {
                            _ = PluginUpdateRecovery.adoptLeftoverStaging(inDirectory: pluginCrashPath?.deletingLastPathComponent ?? "")
                        }
                        let inactivePath = PluginQuarantine.inactivePath(forPluginAt: (pluginCrashPath as String?) ?? "",
                                                                         active: PluginManager.activeDirectories() as! [String],
                                                                         inactive: PluginManager.inactiveDirectories() as! [String])
                        let canRestore = ownPlugin && FileManager.default.fileExists(atPath: PluginUpdateRecovery.previousPath(forDestination: (pluginCrashPath as String?) ?? ""))
                        let explanation = PluginUpdateRecovery.explanation(pluginNamed: pluginCrashPath?.lastPathComponent ?? "",
                                                                           canRestore: canRestore,
                                                                           canDisable: inactivePath != nil)
                        let defaultButton = canRestore ? NSLocalizedString("Restore Previous", comment: "") : (inactivePath != nil ? NSLocalizedString("Disable Plugin", comment: "") : NSLocalizedString("OK", comment: ""))
                        let alternateButton: String? = canRestore ? (inactivePath != nil ? NSLocalizedString("Disable Plugin", comment: "") : NSLocalizedString("Continue", comment: "")) : (inactivePath != nil ? NSLocalizedString("Continue", comment: "") : nil)
                        let otherButton: String? = canRestore && inactivePath != nil ? NSLocalizedString("Continue", comment: "") : nil
                        let result = HorosAlertPanel.runInformational(title: NSLocalizedString("IsiX DICOM Viewer crashed", comment: ""), message: explanation,
                                                                      defaultButton: defaultButton, alternateButton: alternateButton, otherButton: otherButton)
                        if canRestore && result == HorosAlertPanel.defaultResponse {
                            _ = PluginUpdateRecovery.restorePrevious(forDestination: (pluginCrashPath as String?) ?? "")
                        } else if let inactivePath = inactivePath, (canRestore && result == HorosAlertPanel.alternateResponse) || (!canRestore && result == HorosAlertPanel.defaultResponse) {
                            PluginManager.movePlugin(fromPath: pluginCrashPath as String?, toPath: inactivePath)
                            if FileManager.default.fileExists(atPath: inactivePath) {
                                NSLog("Plugin disabled after a crash: %@ -> %@", ObjC.arg(pluginCrashPath), inactivePath as NSString)
                            } else {
                                NSLog("**** Could not disable the plugin that was loading: %@", ObjC.arg(pluginCrashPath))
                            }
                        }
                    }
                    try? FileManager.default.removeItem(atPath: pluginCrash)
                }

                let pathsOfPluginsToLoad = NSMutableArray()
                let dontLoadOtherWithTheseNames = NSMutableArray()

                for path in paths {
                    var stop = false
                    do {
                        try HorosObjCException.perform {
                            var path: Any = path
                            var donotloadnames: [String]? = nil
                            if !(path is NSNull) {
                                donotloadnames = (try? NSString(contentsOfFile: ((path as! NSString).appendingPathComponent("DoNotLoad.txt")), usedEncoding: nil))?.components(separatedBy: CharacterSet.newlines)
                                if (donotloadnames as NSArray?)?.contains("*") == true {
                                    stop = true
                                    return
                                }
                            }

                            var e: [Any] = []
                            if let directory = path as? String {
                                let pluginsInDir = try? FileManager.default.contentsOfDirectory(atPath: directory)
                                e = (pluginsInDir ?? []).filter { plugin in
                                    let listed = dontLoadOtherWithTheseNames.contains(plugin)
                                    if listed {
                                        let favored = pathsOfPluginsToLoad.filter { ((($0 as! NSString).lastPathComponent) as NSString).compare(plugin) == .orderedSame }.last
                                        NSLog("Won't load %@ from %@ in favor of %@", plugin as NSString, directory as NSString, ObjC.arg(favored))
                                    }
                                    return !listed
                                }
                            } else if path is NSNull {
                                path = "/"
                                let cl = NSMutableArray()
                                let args = ProcessInfo.processInfo.arguments
                                var i = 0
                                while i < args.count {
                                    if args[i] == "--LoadPlugin" && args.count > i + 1 {
                                        i += 1
                                        let pluginpath = args[i]
                                        cl.add(pluginpath)
                                        dontLoadOtherWithTheseNames.add((pluginpath as NSString).lastPathComponent)
                                    }
                                    i += 1
                                }
                                e = cl as! [Any]
                            }

                            for name in e {
                                if (donotloadnames as NSArray?)?.contains(((name as! NSString).deletingPathExtension)) != true {
                                    ObjC.add(pathsOfPluginsToLoad, ((path as! NSString).appendingPathComponent(name as! String) as NSString).resolvingSymlinksAndAliases())
                                }
                            }
                        }
                    } catch {
                        if let e = ObjC.exception(error) {
                            _N2LogExceptionImpl(e, true, "+[PluginManager discoverPlugins]")
                        }
                    }
                    if stop {
                        break
                    }
                }

                // Former plugins could ask, with Requirements in their Info.plist, to
                // load after others; a version 1 bundle that declares it is refused,
                // and no bundle is opened here: the order is the folders'.
                for path in pathsOfPluginsToLoad {
                    PluginManager.loadPlugin(atPath: path as? String)
                }

                if let plugins = Registry.plugins {
                    T2FitMapFilter.register(in: plugins)
                    ROIEnhancementFilter.register(in: plugins)
                }
                NSLog("|||||||||||||||||| Plugins loading END ||||||||||||||||||")
            }
        } catch {
            if let e = ObjC.exception(error) {
                _N2LogExceptionImpl(e, true, "+[PluginManager discoverPlugins]")
            }
        }
        #endif
    }

    /// The action of the "No plugins available for this menu" items, whose
    /// target is the class.
    @objc(noPlugins:)
    class func noPlugins(_ sender: Any!) {
        // URL_HOROS_PLUGINS, which Swift does not import: URL_HOROS_PROJECT@"/horos-content/plugins/index.html".
        if let url = NSURL(string: URL_HOROS_PROJECT + "/horos-content/plugins/index.html") {
            NSWorkspace.shared.open(url as URL)
        }
    }

    // MARK: -
    // MARK: Plugin user management

    // MARK: directories

    /// The only bundle that honours `isolatedPluginsFolderArgument`: the
    /// development copy `script/build_and_run.sh` makes. A release build ignores
    /// the argument and keeps reading the plugins folders.
    @objc public static let developmentBundleIdentifier = StorageLocations.developmentBundleIdentifier

    /// `-IsolatedPluginsFolder <folder>` on the command line of the development
    /// bundle stands that folder in for the user's and the computer's plugins
    /// folders.
    @objc public static let isolatedPluginsFolderArgument = StorageLocations.isolatedPluginsFolderArgument

    /// The folder an isolated development launch keeps its plugins in, or nil.
    ///
    /// The isolated launches kept their own database, listener and updates, and
    /// still loaded the plugins of whoever ran them, from the user's plugins
    /// folder in Application Support. Stopping the development app while one
    /// loaded left its marker there, and the next launch offered to move that
    /// plugin to the disabled folder. In this mode the plugins folders, the one
    /// for Horos App, the earlier versions' folders and the marker are all
    /// inside this folder: the user's and the computer's are never listed, read
    /// or written, and `--LoadPlugin <bundle>` still loads a given plugin. Only
    /// the command line counts, not a saved preference.
    @objc public class func isolatedPluginsFolder() -> String? {
        StorageLocations.runningIsolatedFolder
    }

    /// What the plugins folders of the current user are relative to: the home
    /// folder, or its stand-in inside the isolated folder.
    class func userPluginsDomain() -> String {
        StorageLocations.userPluginsDomain(isolatedFolder: PluginManager.isolatedPluginsFolder())
    }

    /// What the plugins folders of all users are relative to: the root of the
    /// disk, or its stand-in inside the isolated folder.
    class func systemPluginsDomain() -> String {
        StorageLocations.systemPluginsDomain(isolatedFolder: PluginManager.isolatedPluginsFolder())
    }

    @objc public class func activePluginsDirectoryPath() -> String! {
        return StorageLocations.activePluginsRelativePath
    }

    @objc public class func inactivePluginsDirectoryPath() -> String! {
        return StorageLocations.inactivePluginsRelativePath
    }

    @objc public class func userActivePluginsDirectoryPath() -> String! {
        return StorageLocations.pluginsFolder(inDomain: PluginManager.userPluginsDomain(), active: true)
    }

    @objc public class func userInactivePluginsDirectoryPath() -> String! {
        return StorageLocations.pluginsFolder(inDomain: PluginManager.userPluginsDomain(), active: false)
    }

    @objc public class func systemActivePluginsDirectoryPath() -> String! {
        return StorageLocations.pluginsFolder(inDomain: PluginManager.systemPluginsDomain(), active: true)
    }

    @objc public class func systemInactivePluginsDirectoryPath() -> String! {
        return StorageLocations.pluginsFolder(inDomain: PluginManager.systemPluginsDomain(), active: false)
    }

    @objc public class func appActivePluginsDirectoryPath() -> String! {
        return Bundle.main.builtInPlugInsPath
    }

    @objc public class func appInactivePluginsDirectoryPath() -> String! {
        guard let builtInPlugInsPath = Bundle.main.builtInPlugInsPath else {
            // +[NSMutableString stringWithString:nil] raised this.
            NSException(name: .invalidArgumentException, reason: "*** -[NSPlaceholderMutableString initWithString:]: nil argument", userInfo: nil).raise()
            return nil
        }
        let appPath = NSMutableString(string: builtInPlugInsPath)
        appPath.append(" Disabled")
        return appPath as String
    }

    @objc public class func activeDirectories() -> [Any]! {
        #if MACAPPSTORE
        return []
        #else
        return ObjC.array(upToFirstNil: [PluginManager.userActivePluginsDirectoryPath(), PluginManager.systemActivePluginsDirectoryPath(), PluginManager.appActivePluginsDirectoryPath()]) as? [Any]
        #endif
    }

    @objc public class func inactiveDirectories() -> [Any]! {
        #if MACAPPSTORE
        return []
        #else
        return ObjC.array(upToFirstNil: [PluginManager.userInactivePluginsDirectoryPath(), PluginManager.systemInactivePluginsDirectoryPath(), PluginManager.appInactivePluginsDirectoryPath()]) as? [Any]
        #endif
    }

    // MARK: activation

    @objc(movePluginFromPath:toPath:)
    public class func movePlugin(fromPath sourcePath: String!, toPath destinationPath: String!) {
        #if !MACAPPSTORE
        if ObjC.isEqualToString(sourcePath, destinationPath) { return }

        let destinationDirectory = (destinationPath as NSString?)?.deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: destinationDirectory ?? "") {
            if let destinationDirectory = destinationDirectory {
                try? FileManager.default.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true, attributes: nil)
            }
        }

        // Moving within folders the user can write needs no privilege: the
        // administrator password used to be asked for every activation, even
        // in the user's own plugins folder. Only a folder the user
        // cannot write, such as /Library's, goes through the authorization.
        let manager = FileManager.default
        let sourceDirectory = (sourcePath as NSString?)?.deletingLastPathComponent ?? ""
        var moved = false
        if let sourcePath = sourcePath, let destinationPath = destinationPath,
           manager.isWritableFile(atPath: sourceDirectory),
           manager.isWritableFile(atPath: destinationDirectory ?? "") {
            // mv -f replaced an existing destination; so does this.
            if manager.fileExists(atPath: destinationPath) {
                try? manager.removeItem(atPath: destinationPath)
            }
            moved = (try? manager.moveItem(atPath: sourcePath, toPath: destinationPath)) != nil
        }

        if !moved {
            let args = NSMutableArray()
            args.add("-f")
            ObjC.add(args, sourcePath)
            ObjC.add(args, destinationPath)

            _ = PluginManager.authentication()?.executeCommand("/bin/mv", withArgs: args as? [Any])
        }

        // A copy is not a successful move: it can leave a disabled plugin active.
        // The authorization helper does not reliably report the child exit status.
        if FileManager.default.fileExists(atPath: sourcePath) ||
            FileManager.default.fileExists(atPath: destinationPath) == false {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugin", comment: ""),
                                        message: NSLocalizedString("The plugin could not be moved. Its activation or location change was not completed. Check folder permissions and try again.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        #endif
    }

    @objc(activatePluginWithName:)
    public class func activatePlugin(withName pluginName: String!) {
        #if !MACAPPSTORE
        let activePaths = PluginManager.activeDirectories() ?? []
        let inactivePaths = PluginManager.inactiveDirectories() ?? []

        var activePathEnum = activePaths.makeIterator()

        for inactivePath in inactivePaths {
            let activePath = activePathEnum.next()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: inactivePath as! String)) ?? [] where PluginManager.mayManagePlugin(inFolder: inactivePath, named: name) {
                if ((name as NSString).deletingPathExtension as NSString).isEqual(to: pluginName ?? "") && pluginName != nil {
                    let sourcePath = ObjC.format("%@/%@", inactivePath, name)
                    let destinationPath = ObjC.format("%@/%@", activePath, name)
                    PluginManager.movePlugin(fromPath: sourcePath, toPath: destinationPath)
                }
            }
        }

        // The flag and the alert are the main thread's.
        onMainActorSync {
            if !gPluginsAlertAlreadyDisplayed.boolValue {
                HorosAlertPanel.runInformational(title: NSLocalizedString("Plugins", comment: ""), message: NSLocalizedString("Restart IsiX DICOM Viewer to apply the changes to the plugins.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
            gPluginsAlertAlreadyDisplayed = true
        }
        #endif
    }

    @objc(deactivatePluginWithName:)
    public class func deactivatePlugin(withName pluginName: String!) {
        #if !MACAPPSTORE
        //    [PluginManager unloadPluginWithName: pluginName];

        let activePaths = PluginManager.activeDirectories() ?? []
        let inactivePaths = PluginManager.inactiveDirectories() ?? []

        var inactivePathEnum = inactivePaths.makeIterator()

        for activePath in activePaths {
            let inactivePath = inactivePathEnum.next() as? String
            for name in (try? FileManager.default.contentsOfDirectory(atPath: activePath as! String)) ?? [] where PluginManager.mayManagePlugin(inFolder: activePath, named: name) {
                if ((name as NSString).deletingPathExtension as NSString).isEqual(to: pluginName ?? "") && pluginName != nil {
                    var isDir: ObjCBool = true
                    if !FileManager.default.fileExists(atPath: inactivePath ?? "", isDirectory: &isDir) && isDir.boolValue {
                        PluginManager.createDirectory(inactivePath)
                    }
                    //	[[NSFileManager defaultManager] createDirectoryAtPath:inactivePath attributes:nil];
                    let sourcePath = ObjC.format("%@/%@", activePath, name)
                    let destinationPath = ObjC.format("%@/%@", inactivePath, name)
                    PluginManager.movePlugin(fromPath: sourcePath, toPath: destinationPath)
                }
            }
        }

        // The flag and the alert are the main thread's.
        onMainActorSync {
            if !gPluginsAlertAlreadyDisplayed.boolValue {
                HorosAlertPanel.runInformational(title: NSLocalizedString("Plugins", comment: ""), message: NSLocalizedString("Restart IsiX DICOM Viewer to apply the changes to the plugins.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
            gPluginsAlertAlreadyDisplayed = true
        }
        #endif
    }

    @objc(changeAvailabilityOfPluginWithName:to:)
    public class func changeAvailabilityOfPlugin(withName pluginName: String!, to availability: String!) {
        #if !MACAPPSTORE
        let availabilities = PluginManager.availabilities()!

        let paths = NSMutableArray()
        paths.addObjects(from: PluginManager.activeDirectories())
        paths.addObjects(from: PluginManager.inactiveDirectories())

        var completePluginPath: String? = nil
        var found = false

        for path in paths {
            if found { break }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path as! String)) ?? [] where PluginManager.mayManagePlugin(inFolder: path, named: name) {
                if found { break }
                if ((name as NSString).deletingPathExtension as NSString).isEqual(to: pluginName ?? "") && pluginName != nil {
                    completePluginPath = ObjC.format("%@/%@", path, name)
                    found = true
                }
            }
        }

        guard completePluginPath != nil else { return }
        let directory = (completePluginPath as NSString?)?.deletingLastPathComponent
        let newDirectory = NSMutableString(string: "")

        if (availability as AnyObject?)?.isEqual(to: availabilities[0]) == true {
            newDirectory.setString(PluginManager.userActivePluginsDirectoryPath())
        } else if availabilities.count > 1 && (availability as AnyObject?)?.isEqual(to: availabilities[1]) == true {
            newDirectory.setString(PluginManager.systemActivePluginsDirectoryPath())
        } else if availabilities.count > 2 && (availability as AnyObject?)?.isEqual(to: availabilities[2]) == true {
            newDirectory.setString(PluginManager.appActivePluginsDirectoryPath())
        }
        newDirectory.setString(newDirectory.deletingLastPathComponent) // remove /Plugins/
        newDirectory.setString(ObjC.appendingPathComponent(newDirectory, (directory as NSString?)?.lastPathComponent) ?? "") // add /Plugins/ or /Plugins (off)/

        let newPluginPath = NSMutableString(string: "")
        newPluginPath.setString(ObjC.appendingPathComponent(newDirectory, (completePluginPath as NSString?)?.lastPathComponent) ?? "")

        PluginManager.movePlugin(fromPath: completePluginPath, toPath: newPluginPath as String)
        #endif
    }

    @objc(createDirectory:)
    public class func createDirectory(_ directoryPath: String!) {
        #if !MACAPPSTORE
        var isDir: ObjCBool = true
        var directoryCreated = false
        if !FileManager.default.fileExists(atPath: directoryPath ?? "", isDirectory: &isDir) && isDir.boolValue {
            directoryCreated = (try? FileManager.default.createDirectory(atPath: directoryPath ?? "", withIntermediateDirectories: true, attributes: nil)) != nil
        }

        if !directoryCreated {
            let args = NSMutableArray()
            ObjC.add(args, directoryPath)
            _ = PluginManager.authentication()?.executeCommand("/bin/mkdir", withArgs: args as? [Any])
        }
        #endif
    }

    // MARK: Instalation

    @objc(installPluginFromPath:)
    public class func installPlugin(fromPath path: String!) {
        #if !MACAPPSTORE
        // Validate the candidate before touching an existing installation. A
        // former plugin is refused here, whatever the entry that brought it.
        if let refusal = PluginManager.pluginInstallRefusal(atPath: path) {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugin", comment: ""),
                                        message: ObjC.format(NSLocalizedString("The plugin cannot be installed. The existing installation was preserved. %@", comment: ""), refusal),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let archReason = HorosArchitectureAudit.pluginDiagnosis(at: path)
        if let archReason = archReason, !archReason.isEmpty {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugin", comment: ""),
                                        message: ObjC.format(NSLocalizedString("The plugin cannot be installed. The existing installation was preserved. %@", comment: ""), archReason),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let candidate = Bundle(path: path)
        var candidateError: NSError? = nil
        if candidate == nil || !PluginManagerCAPIPreflightBundle(candidate, &candidateError) ||
            !PluginManager.isPluginBundleSignatureValid(path) {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugin", comment: ""),
                                        message: ObjC.format(NSLocalizedString("The plugin cannot be installed. The existing installation was preserved. %@", comment: ""),
                                                             candidateError?.localizedDescription ?? NSLocalizedString("Check the plugin bundle, architecture and signature.", comment: "")),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        // move the plugin package into the plugins (active) directory
        var destinationDirectory: String? = nil
        var destinationPath: String? = nil

        let active = NSMutableDictionary()
        let availabilities = NSMutableDictionary()

        let pluginBundleName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        var matchingInstallations = 0
        for case let plug as NSDictionary in PluginManager.pluginsList() ?? [] {
            // A former plugin of the same name is neither replaced nor counted.
            if ObjC.bool(plug.object(forKey: PluginManager.legacyPluginKey)) { continue }
            if ObjC.isEqualToString(pluginBundleName, plug.object(forKey: "name") as? String) {
                matchingInstallations += 1
                ObjC.set(availabilities, plug.object(forKey: "availability"), path)
                ObjC.set(active, plug.object(forKey: "active"), path)
            }
        }

        if matchingInstallations > 1 {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugin", comment: ""),
                                        message: NSLocalizedString("Multiple installations of this plugin exist. Resolve the duplicates in Plugins Manager before updating. No installation was changed.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        let availability = availabilities.object(forKey: path as Any)
        var isActive = ObjC.bool(active.object(forKey: path as Any))

        if availability == nil {
            isActive = true
        }

        if ObjC.isEqualToString(availability, PluginManager.availabilities()[0] as? String) {
            if isActive {
                destinationDirectory = PluginManager.userActivePluginsDirectoryPath()
            } else {
                destinationDirectory = PluginManager.userInactivePluginsDirectoryPath()
            }
        } else if ObjC.isEqualToString(availability, PluginManager.availabilities()[1] as? String) {
            if isActive {
                destinationDirectory = PluginManager.systemActivePluginsDirectoryPath()
            } else {
                destinationDirectory = PluginManager.systemInactivePluginsDirectoryPath()
            }
        } else if ObjC.isEqualToString(availability, PluginManager.availabilities()[2] as? String) {
            if isActive {
                destinationDirectory = PluginManager.appActivePluginsDirectoryPath()
            } else {
                destinationDirectory = PluginManager.appInactivePluginsDirectoryPath()
            }
        } else {
            if isActive {
                destinationDirectory = PluginManager.userActivePluginsDirectoryPath()
            } else {
                destinationDirectory = PluginManager.userInactivePluginsDirectoryPath()
            }
        }

        destinationPath = ObjC.appendingPathComponent(destinationDirectory as NSString?, (path as NSString).lastPathComponent)

        var installError: NSError? = nil
        if !PluginManagerCAPIInstallPlugin(path, destinationPath, &installError) {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugin", comment: ""),
                                        message: ObjC.format(NSLocalizedString("The plugin update could not be completed. The existing installation was preserved. Check destination permissions and available space. %@", comment: ""), installError?.localizedDescription ?? ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        #endif
    }

    // MARK: Deletion

    @discardableResult
    @objc(deletePluginWithName:)
    public class func deletePlugin(withName pluginName: String!) -> String! {
        return PluginManager.deletePlugin(withName: pluginName, availability: nil, isActive: true)
    }

    @discardableResult
    @objc(deletePluginWithName:availability:isActive:)
    public class func deletePlugin(withName pluginName: String!, availability: String!, isActive: Bool) -> String! {
        #if MACAPPSTORE
        return nil
        #else
        let pluginName = (pluginName as NSString?)?.deletingPathExtension

        // First unload the plugin, if currently running
        //    [PluginManager unloadPluginWithName: pluginName];

        let pluginsPaths = NSMutableArray(array: PluginManager.activeDirectories())
        pluginsPaths.addObjects(from: PluginManager.inactiveDirectories())

        var returnPath: String? = nil

        var directory: String? = nil
        let availabilities = PluginManager.availabilities()!
        if ObjC.isEqualToString(availability, availabilities[0] as? String) {
            if isActive {
                directory = PluginManager.userActivePluginsDirectoryPath()
            } else {
                directory = PluginManager.userInactivePluginsDirectoryPath()
            }
        } else if availabilities.count > 1 && ObjC.isEqualToString(availability, availabilities[1] as? String) {
            if isActive {
                directory = PluginManager.systemActivePluginsDirectoryPath()
            } else {
                directory = PluginManager.systemInactivePluginsDirectoryPath()
            }
        } else if availabilities.count > 2 && ObjC.isEqualToString(availability, availabilities[2] as? String) {
            if isActive {
                directory = PluginManager.appActivePluginsDirectoryPath()
            } else {
                directory = PluginManager.appInactivePluginsDirectoryPath()
            }
        }

        for path in pluginsPaths {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path as! String)) ?? [] where PluginManager.mayManagePlugin(inFolder: path, named: name) {
                if ObjC.isEqualToString((name as NSString).deletingPathExtension, (pluginName as NSString?)?.deletingPathExtension) &&
                    (directory == nil || (directory! as NSString).isEqual(to: path)) {
                    let pluginURL = URL(fileURLWithPath: path as! String, isDirectory: true).appendingPathComponent(name)
                    do {
                        try FileManager.default.trashItem(at: pluginURL, resultingItemURL: nil)
                        returnPath = path as? String
                    } catch {
                        // Keep the plugin in place on failure. A forced move to
                        // ~/.Trash could overwrite another plugin of this name.
                        NSLog("Unable to move plugin to Trash: %@", error.localizedDescription)
                        _ = onMainActorSync {
                            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugins", comment: ""), message: error.localizedDescription, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                        }
                    }
                }
            }
        }

        // The flag and the alert are the main thread's.
        if returnPath != nil { onMainActorSync {
            if !gPluginsAlertAlreadyDisplayed.boolValue {
                HorosAlertPanel.runInformational(title: NSLocalizedString("Plugins", comment: ""), message: NSLocalizedString("Restart IsiX DICOM Viewer to apply the changes to the plugins.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
            gPluginsAlertAlreadyDisplayed = true
        } }

        return returnPath
        #endif
    }

    // MARK: plugins

    @objc public class func pluginsList() -> [Any]! {
        #if MACAPPSTORE
        return []
        #else
        let userActivePath = PluginManager.userActivePluginsDirectoryPath() as NSString
        let userInactivePath = PluginManager.userInactivePluginsDirectoryPath() as NSString
        let sysActivePath = PluginManager.systemActivePluginsDirectoryPath() as NSString
        let sysInactivePath = PluginManager.systemInactivePluginsDirectoryPath() as NSString

        let paths = NSMutableArray()
        paths.addObjects(from: PluginManager.activeDirectories())
        paths.addObjects(from: PluginManager.inactiveDirectories())

        let plugins = NSMutableArray()

        for case let path as String in paths {
            let active = (PluginManager.activeDirectories() as NSArray).contains(path)
            let allUsers = sysActivePath.isEqual(to: path) || sysInactivePath.isEqual(to: path) || ObjC.isEqualToString(path, PluginManager.appActivePluginsDirectoryPath()) || ObjC.isEqualToString(path, PluginManager.appInactivePluginsDirectoryPath())

            var availability: Any? = nil

            if sysActivePath.isEqual(to: path) || sysInactivePath.isEqual(to: path) {
                availability = PluginManager.availabilities()[1]
            } else if ObjC.isEqualToString(path, PluginManager.appActivePluginsDirectoryPath()) || ObjC.isEqualToString(path, PluginManager.appInactivePluginsDirectoryPath()) {
                availability = PluginManager.availabilities()[2]
            } else if userActivePath.isEqual(to: path) || userInactivePath.isEqual(to: path) {
                availability = PluginManager.availabilities()[0]
            }

            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                let pathExtension = (name as NSString).pathExtension as NSString
                if PluginAdmission.isPluginBundle(name) {
                    let pluginPath = ((path as NSString).appendingPathComponent(name) as NSString).resolvingAlias() as String

                    let pluginDescription = NSMutableDictionary(capacity: 3)
                    pluginDescription.setObject((name as NSString).deletingPathExtension, forKey: "name" as NSString)
                    pluginDescription.addEntries(from: PluginManagerCAPILoadOutcome(pluginPath, active))
                    pluginDescription.setObject(NSNumber(value: active), forKey: "active" as NSString)
                    pluginDescription.setObject(NSNumber(value: allUsers), forKey: "allUsers" as NSString)
                    ObjC.set(pluginDescription, availability, "availability")
                    pluginDescription.setObject(pluginPath, forKey: "path" as NSString)

                    if pathExtension.isEqual(to: "osirixplugin") {
                        ObjC.set(pluginDescription, NSImage(named: "osirixplugin"), "typeIcon")
                    } else {
                        ObjC.set(pluginDescription, NSImage(named: "horosplugin"), "typeIcon")
                    }

                    ////////////////////////////////////
                    // plugin version and compatibility
                    ////////////////////////////////////

                    // taking the "version" through NSBundle is a BAD idea: Cocoa keeps the NSBundle in cache... thus for a same path you'll always have the same version
                    let bundleURL = NSURL(fileURLWithPath: pluginPath)
                    let bundleInfoDict = CFBundleCopyInfoDictionaryInDirectory(bundleURL as CFURL) as NSDictionary?

                    //////////////

                    var versionString: Any? = nil

                    if let bundleInfoDict = bundleInfoDict {
                        versionString = bundleInfoDict.object(forKey: "CFBundleVersion")

                        if versionString == nil {
                            versionString = bundleInfoDict.object(forKey: "CFBundleShortVersionString")
                        }
                    }

                    let pluginVersion: Any = versionString ?? ""

                    pluginDescription.setObject(pluginVersion, forKey: "version" as NSString)

                    //////////////

                    if PluginAdmission.mayManage(bundleAt: URL(fileURLWithPath: pluginPath)) {
                        // Read from its metadata only: listing never loads a plugin.
                        pluginDescription.setObject(PluginManager.isIsiXPluginCompatible(atPath: pluginPath) ? "YES" : "NO", forKey: "HorosCompatiblePlugin" as NSString)
                    } else {
                        // A former plugin, renamed or not: incompatible, and no
                        // action is offered on it.
                        pluginDescription.setObject("NO", forKey: "HorosCompatiblePlugin" as NSString)
                        pluginDescription.setObject(NSNumber(value: true), forKey: PluginManager.legacyPluginKey as NSString)
                        pluginDescription.setObject(NSLocalizedString("Incompatible", comment: ""), forKey: "loadState" as NSString)
                        pluginDescription.setObject(PluginInspector().inspect(bundleAt: URL(fileURLWithPath: pluginPath)).summary, forKey: "loadReason" as NSString)
                    }

                    ////////////////////////////////////

                    // plugin description dictionary
                    plugins.add(pluginDescription)
                }
            }
        }

        plugins.addObjects(from: PluginManager.legacyPluginRows())
        let sortedPlugins = plugins.sortedArray(sortPluginArray, context: nil)

        return sortedPlugins
        #endif
    }

    @objc public class func availabilities() -> [Any]! {
        return [NSLocalizedString("Current user", comment: ""),
                NSLocalizedString("All users", comment: ""),
                NSLocalizedString("IsiX DICOM Viewer bundle", comment: "")]
    }

    // MARK: -
    // MARK: auto update

    @objc(checkForHorosPluginsUpdates:)
    func checkForHorosPluginsUpdates(_ sender: Any!) -> [Any]! {
        #if MACAPPSTORE
        return []
        #else
        let pluginsToUpdate = NSMutableArray()

        var catalog: [Any]? = nil
        var catalogError: NSError? = nil
        let endpoints = NSOrderedSet(array: [HOROS_PLUGIN_LIST_URL, HOROS_PLUGIN_LIST_ALT_URL]).array
        for endpoint in endpoints {
            catalog = PluginManagerCAPILoadCatalog(NSURL(string: endpoint as! String) as URL?, 10, &catalogError)
            if catalog != nil { break } // A valid empty catalog is a successful response.
        }
        guard let loaded = catalog else {
            NSLog("Plugin update catalog unavailable (%@ %ld): %@", ObjC.arg(catalogError?.domain), catalogError?.code ?? 0, ObjC.arg(catalogError?.localizedDescription))
            return pluginsToUpdate as? [Any]
        }
        let onlinePlugins = NSMutableArray(array: loaded)

        if onlinePlugins.count > 0 {
            let installedPlugins = PluginManager.pluginsList() ?? []

            for case let installedPlugin as NSDictionary in installedPlugins {
                // A former plugin is not updated: no package of the former API is installed.
                if ObjC.bool(installedPlugin.object(forKey: PluginManager.legacyPluginKey)) { continue }
                let pluginName = installedPlugin.value(forKey: "name")

                var onlinePlugin: NSDictionary? = nil
                for case let plugin as NSDictionary in onlinePlugins {
                    let name = PluginManagerCAPIDownloadName(plugin)

                    if ObjC.isEqualToString(pluginName, name) {
                        onlinePlugin = plugin
                        break
                    }
                }

                if let onlinePlugin = onlinePlugin, PluginManager.isVersion1Download(onlinePlugin.object(forKey: "download_url")) {
                    let currVersion = installedPlugin.object(forKey: "version")
                    let onlineVersion = onlinePlugin.object(forKey: "version")

                    if PluginManagerCAPIVersionIsValid(currVersion) && PluginManagerCAPIVersionIsValid(onlineVersion) {
                        if ObjC.isEqualToString(currVersion, onlineVersion as? String) == false && PluginManager.compareVersion(currVersion as? String, withVersion: onlineVersion as? String) < 0 {
                            NSLog("PLUGIN UPDATE NEEDED -------> current vers: %@ versus online vers: %@ - %@", ObjC.arg(currVersion), ObjC.arg(onlineVersion), ObjC.arg(pluginName))
                            let modifiedOnlinePlugin = NSMutableDictionary(dictionary: onlinePlugin as! [AnyHashable: Any])
                            ObjC.set(modifiedOnlinePlugin, pluginName, "name")
                            pluginsToUpdate.add(modifiedOnlinePlugin)
                        }
                    }
                    onlinePlugins.remove(onlinePlugin)
                }
            }
        }

        return pluginsToUpdate as? [Any]
        #endif
    }

    @objc(checkForOsiriXPluginsUpdates:)
    func checkForOsiriXPluginsUpdates(_ sender: Any!) -> [Any]! {
        #if MACAPPSTORE
        return []
        #else
        let pluginsToUpdate = NSMutableArray()

        var catalog: [Any]? = nil
        var catalogError: NSError? = nil
        let endpoints = NSOrderedSet(array: [OSIRIX_PLUGIN_LIST_URL, OSIRIX_PLUGIN_LIST_ALT_URL]).array
        for endpoint in endpoints {
            catalog = PluginManagerCAPILoadCatalog(NSURL(string: endpoint as! String) as URL?, 10, &catalogError)
            if catalog != nil { break } // A valid empty catalog is a successful response.
        }
        guard let loaded = catalog else {
            NSLog("Plugin update catalog unavailable (%@ %ld): %@", ObjC.arg(catalogError?.domain), catalogError?.code ?? 0, ObjC.arg(catalogError?.localizedDescription))
            return pluginsToUpdate as? [Any]
        }
        let onlinePlugins = NSMutableArray(array: loaded)

        if onlinePlugins.count > 0 {
            let installedPlugins = PluginManager.pluginsList() ?? []

            for case let installedPlugin as NSDictionary in installedPlugins {
                // A former plugin is not updated: no package of the former API is installed.
                if ObjC.bool(installedPlugin.object(forKey: PluginManager.legacyPluginKey)) { continue }
                let pluginName = installedPlugin.value(forKey: "name")

                var onlinePlugin: NSDictionary? = nil
                for case let plugin as NSDictionary in onlinePlugins {
                    let name = PluginManagerCAPIDownloadName(plugin)

                    if ObjC.isEqualToString(pluginName, name) {
                        onlinePlugin = plugin
                        break
                    }
                }

                if let onlinePlugin = onlinePlugin, PluginManager.isVersion1Download(onlinePlugin.object(forKey: "download_url")) {
                    let currVersion = installedPlugin.object(forKey: "version")
                    let onlineVersion = onlinePlugin.object(forKey: "version")

                    if PluginManagerCAPIVersionIsValid(currVersion) && PluginManagerCAPIVersionIsValid(onlineVersion) {
                        if ObjC.isEqualToString(currVersion, onlineVersion as? String) == false && PluginManager.compareVersion(currVersion as? String, withVersion: onlineVersion as? String) < 0 {
                            NSLog("PLUGIN UPDATE NEEDED -------> current vers: %@ versus online vers: %@ - %@", ObjC.arg(currVersion), ObjC.arg(onlineVersion), ObjC.arg(pluginName))
                            let modifiedOnlinePlugin = NSMutableDictionary(dictionary: onlinePlugin as! [AnyHashable: Any])
                            ObjC.set(modifiedOnlinePlugin, pluginName, "name")
                            pluginsToUpdate.add(modifiedOnlinePlugin)
                        }
                    }
                    onlinePlugins.remove(onlinePlugin)
                }
            }
        }

        return pluginsToUpdate as? [Any]
        #endif
    }

    @IBAction @objc(checkForUpdates:)
    public func checkForUpdates(_ sender: Any!) {
        #if !MACAPPSTORE
        Thread.detachNewThreadSelector(#selector(checkForUpdatesInBackground(_:)), toTarget: self, with: nil)
        #endif
    }

    @objc(checkForUpdatesInBackground:)
    nonisolated func checkForUpdatesInBackground(_ sender: Any!) {
        #if !MACAPPSTORE
        autoreleasepool {
            Thread.current.name = "Check for plugins updates"

            Thread.sleep(forTimeInterval: 10)

            let pluginsToUpdate = NSMutableArray(array: self.checkForHorosPluginsUpdates(sender) ?? [])
            pluginsToUpdate.addObjects(from: self.checkForOsiriXPluginsUpdates(sender) ?? [])

            //ici
            if pluginsToUpdate.count > 0 {
                var title: String
                var message = NSMutableString()

                if pluginsToUpdate.count == 1 {
                    title = NSLocalizedString("Plugin Update Available", comment: "")
                    message.append(ObjC.format(NSLocalizedString("A new version of the plugin \"%@\" is available.", comment: ""), (pluginsToUpdate.object(at: 0) as! NSDictionary).object(forKey: "name")))
                } else {
                    title = NSLocalizedString("Plugin Updates Available", comment: "")
                    message.append(NSLocalizedString("New versions of the following plugins are available:\n", comment: ""))
                    for case let plugin as NSDictionary in pluginsToUpdate {
                        message.append(ObjC.format("%@, ", plugin.object(forKey: "name")))
                    }
                    message = NSMutableString(string: message.substring(to: message.length - 2))
                }

                let messageDictionary = NSDictionary(objects: [title, message, pluginsToUpdate], forKeys: ["title" as NSString, "body" as NSString, "plugins" as NSString])

                self.performSelector(onMainThread: #selector(displayUpdateMessage(_:)), with: messageDictionary, waitUntilDone: false)
            }
        }
        #endif
    }

    @objc(displayUpdateMessage:)
    public func displayUpdateMessage(_ messageDictionary: NSDictionary!) {
        #if !MACAPPSTORE
        autoreleasepool {
            let button = HorosAlertPanel.run(title: messageDictionary?.object(forKey: "title") as? String,
                                             message: ObjC.format("%@", messageDictionary?.object(forKey: "body")),
                                             defaultButton: NSLocalizedString("Download", comment: ""),
                                             alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

            if HorosAlertPanel.defaultResponse == button {
                startedUpdateProcess = true
                let pluginManagerController = PluginManager.pluginManagerController()

                if let pluginManagerController = pluginManagerController {
                    let pluginsToDownload = messageDictionary?.object(forKey: "plugins") as? NSArray
                    self.downloadQueue = NSMutableArray(array: (pluginsToDownload as? [Any]) ?? [])

                    // objectAtIndex:0 of an empty list raises, as it did.
                    let first = pluginsToDownload.flatMap { ObjC.object($0, at: 0) } as? NSDictionary

                    NSLog("Download Plugin : %@", ObjC.arg(first?.object(forKey: "download_url")))

                    let pluginURL = first?.object(forKey: "download_url") as? NSString

                    if PluginManager.isVersion1Download(pluginURL) {
                        _ = pluginManagerController.perform(NSSelectorFromString("downloadPluginUpdate:"), with: pluginURL)
                    }
                }
            } else {
                startedUpdateProcess = false
            }
        }
        #endif
    }

    /// [BLAuthentication sharedInstance], which the former header typed id.
    private class func authentication() -> BLAuthentication? {
        return BLAuthentication.sharedInstance() as AnyObject? as? BLAuthentication
    }

    /// -[BrowserController pluginManagerController] of the current browser. The
    /// window controller is reached by its selectors, whatever language it is in.
    private class func pluginManagerController() -> NSObject? {
        return BrowserController.currentBrowser()?.perform(NSSelectorFromString("pluginManagerController"))?.takeUnretainedValue() as? NSObject
    }

    @objc(downloadNext:)
    func downloadNext(_ notification: Notification!) {
        #if !MACAPPSTORE
        if !startedUpdateProcess {
            return
        }

        if (downloadQueue?.count ?? 0) > 1 {
            downloadQueue.removeObject(at: 0)

            let pluginManagerController = PluginManager.pluginManagerController()

            let first = downloadQueue.object(at: 0) as? NSDictionary

            NSLog("Download Plugin : %@", ObjC.arg(first?.object(forKey: "download_url")))

            let pluginURL = first?.object(forKey: "download_url") as? NSString

            if PluginManager.isVersion1Download(pluginURL) {
                _ = pluginManagerController?.perform(NSSelectorFromString("downloadPluginUpdate:"), with: pluginURL)
            }
        } else {
            // The flag and the alert are the main thread's.
            onMainActorSync {
                if !gPluginsAlertAlreadyDisplayed.boolValue {
                    HorosAlertPanel.runInformational(title: NSLocalizedString("Plugin Update Completed", comment: ""), message: NSLocalizedString("All your plugins are now up to date. Restart IsiX DICOM Viewer to use the new or updated plugins.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
                gPluginsAlertAlreadyDisplayed = true
            }

            startedUpdateProcess = false
        }
        #endif
    }
}
