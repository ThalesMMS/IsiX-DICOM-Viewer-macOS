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
import IsiXPreferences
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
        // What the callers guard is a command or a hook of a plugin that has loaded.
        PluginManager.startProtectForCrash(withFilter: filter, phase: .running)
    }

    /// Notes the plugin `filter` belongs to before its code is entered. A
    /// command or a hook of a loaded plugin is `running`; what the launch sends
    /// every plugin while it sets the menus up is still part of `loading` it.
    class func startProtectForCrash(withFilter filter: Any!, phase: PluginCrashMarker.Phase) {
        let filterClassName = ObjC.classOf(filter).map { NSStringFromClass($0) }
        for case let bundle as Bundle in Registry.pluginsBundleDictionnary?.allValues ?? [] {
            let principalName = bundle.principalClass.map { NSStringFromClass($0) }
            if let filterClassName = filterClassName, let principalName = principalName,
               (filterClassName as NSString).isEqual(to: principalName) {
                PluginManager.writeCrashMarker(forPluginAt: bundle.bundlePath, phase: phase)
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

    /// The file naming whatever plugin is being loaded or run right now, removed
    /// when it finishes, and when the application is asked to quit: one left
    /// behind says the last run ended inside that plugin without being asked to.
    @objc public class func crashMarkerPath() -> String! {
        // Beside the plugins themselves, not in /tmp: that one is writable by
        // everybody on the machine and shared by every Horos and OsiriX on it.
        let directory = (PluginManager.userActivePluginsDirectoryPath()! as NSString).deletingLastPathComponent
        return PluginQuarantine.markerPath(inDirectory: directory, forBundle: Bundle.main.bundleIdentifier)
    }

    /// The note of a bundle that is about to be opened or registered.
    @objc(startProtectForCrashWithPath:)
    public class func startProtectForCrash(withPath path: String!) {
        PluginManager.writeCrashMarker(forPluginAt: path, phase: .loading)
    }

    /// Writes the note: the plugin's path and what it is doing (PluginCrashMarker).
    private class func writeCrashMarker(forPluginAt path: String!, phase: PluginCrashMarker.Phase) {
        let marker = PluginManager.crashMarkerPath()! as NSString
        try? FileManager.default.createDirectory(atPath: marker.deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: nil)
        guard let path else { return }
        let note = PluginCrashMarker(pluginPath: path, phase: phase).contents
        try? (note as NSString).write(toFile: marker as String, atomically: true, encoding: String.Encoding.utf8.rawValue)
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

        // Plugins made for Horos or OsiriX declare their items in Info.plist
        // (MenuTitles, pluginType).
        PluginManager.addFormerPluginMenuItems(filtersMenu, roisMenu, othersMenu, dbMenu)

        // Version 1 plugins register their commands in code.
        PluginManager.addIsiXPluginMenuItems(filtersMenu, roisMenu, othersMenu, dbMenu)

        // The app's own filters have no bundle to declare their items: without these, T1 Fit Map,
        // T2 Fit Map and ROI Enhancement were registered and unreachable from any menu.
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
            // Sent to every plugin at each launch: one that stops here stops the launch.
            PluginManager.startProtectForCrash(withFilter: pluginFilter, phase: .loading)

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

    /// The items of the plugins made for Horos or OsiriX, as each one's
    /// Info.plist declares them: one item, or, when it declares several, a
    /// submenu named after its executable. The menu and the message the items
    /// send are LegacyPluginDeclaration's.
    private class func addFormerPluginMenuItems(_ filtersMenu: NSMenu?, _ roisMenu: NSMenu?, _ othersMenu: NSMenu?, _ dbMenu: NSMenu?) {
        // pluginsDict holds a bundle under each of its titles.
        var seen = Set<ObjectIdentifier>()
        for case let plugin as Bundle in Registry.pluginsDict?.allValues ?? [] where seen.insert(ObjectIdentifier(plugin)).inserted {
            let declaration = LegacyPluginDeclaration(info: plugin.infoDictionary ?? [:])
            guard let titles = declaration.menuTitles, let first = titles.first else { continue }
            let menu: NSMenu?
            switch declaration.menu {
            case .imageFilters: menu = filtersMenu
            case .roiTools: menu = roisMenu
            case .fusion: menu = Registry.fusionPluginsMenu
            case .database: menu = dbMenu
            case .others: menu = othersMenu
            }

            PluginManager.startProtectForCrash(withPath: plugin.bundlePath)

            func item(_ title: String) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: NSSelectorFromString(declaration.command.selectorName), keyEquivalent: "")
                switch declaration.command {
                case .fusion: Registry.change(\.fusionPlugins) { ObjC.add($0, title) }
                case .database: item.target = PluginManager.databaseWindow() // the database window runs these
                case .viewer: item.target = nil // the first responder: the front viewer
                }
                return item
            }

            if declaration.hasSubmenu {
                // A menu that already has an item of this name keeps it.
                let name = declaration.executableName ?? ""
                if let menu, menu.indexOfItem(withTitle: name) == -1 {
                    let subMenu = NSMenu(title: name)
                    for title in titles {
                        subMenu.addItem(title == LegacyPluginDeclaration.menuSeparator ? .separator() : item(title))
                    }
                    let subMenuItem = menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
                    menu.setSubmenu(subMenu, for: subMenuItem)
                    subMenuItem.representedObject = plugin
                }
            } else {
                let single = item(first)
                single.representedObject = plugin
                menu?.addItem(single)
            }

            PluginManager.endProtectForCrash()
        }
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

    /// Loads a plugin made for Horos or OsiriX, as it was built: its bundle is
    /// neither changed nor rebuilt. Protected mode, the signature and what its
    /// files say (an executable for this process's architecture, among the
    /// rest) come first, before NSBundle opens it. Its principal class, named
    /// by NSPrincipalClass or the bundle's own, is then registered by what its
    /// Info.plist declares (LegacyPluginDeclaration): `+filter`, which runs
    /// its -initPlugin, under each menu title and toolbar name for the menus
    /// and -filterImage:, or as a pre-process filter, a file format decoder or
    /// a report.
    @objc(loadPluginBundle:)
    class func loadPluginBundle(_ path: String!) {
        #if !MACAPPSTORE
        guard let path, !path.isEmpty else { return }
        let diagnosticPath = (path as NSString).resolvingAlias()
        guard DCMPix.isRunOsiriXInProtectedModeActivated() == false else {
            PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Blocked", comment: ""), NSLocalizedString("Loading is disabled by protected mode or the plugin signature policy. Check protected mode and obtain a compatible plugin from its author.", comment: ""))
            return
        }
        // Records its own refusal.
        guard PluginManager.isPluginBundleSignatureValid(path) else { return }

        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        Registry.change(\.pluginsNames) { ObjC.set($0, (path as NSString).deletingLastPathComponent, name) }

        let resolved = (path as NSString).resolvingAlias() as String
        PluginManager.startProtectForCrash(withPath: resolved)
        defer { PluginManager.endProtectForCrash() }

        let url = URL(fileURLWithPath: resolved)
        let inspection = PluginInspector().inspect(bundleAt: url)
        guard inspection.isLoadable, let declaration = LegacyPluginDeclaration(bundleAt: url) else {
            PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Incompatible", comment: ""), inspection.summary)
            NSLog("Plugin not loaded: %@: %@", resolved as NSString, inspection.summary as NSString)
            return
        }

        var outcome: (state: String, reason: String)?
        // Loading the bundle runs its initializers, and +filter its
        // -initPlugin: an Objective-C or C++ exception that escapes them is
        // caught here, and the plugin is not loaded.
        do {
            try IsiXPluginExceptionGuard.perform {
                outcome = PluginManager.registerFormerPlugin(atPath: resolved, declaration: declaration)
            }
        } catch {
            let exception = IsiXPluginException(error as NSError)
            PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Load failed", comment: ""),
                                        String(format: NSLocalizedString("Plugin initialization failed: %@. Obtain an updated plugin from its author.", comment: ""),
                                               exception.description as NSString))
            NSLog("******** Plugin loading exception: %@", exception.description)
            return
        }
        if let outcome {
            PluginManagerCAPIRecordLoad(diagnosticPath, outcome.state, outcome.reason)
        }
        #endif
    }

    /// Opens and loads the bundle at `path` and registers its principal class
    /// by its declaration; answers the state and reason to record.
    private class func registerFormerPlugin(atPath path: String, declaration: LegacyPluginDeclaration) -> (state: String, reason: String) {
        guard let plugin = Bundle(path: path) else {
            NSLog("**** Bundle opening failed for plugin: %@", path as NSString)
            return (NSLocalizedString("Incompatible", comment: ""), NSLocalizedString("The plugin bundle could not be opened. Reinstall a complete compatible copy from its author.", comment: ""))
        }
        var loadError: NSError? = nil
        guard PluginManagerCAPILoadBundle(plugin, &loadError) else {
            let failure = loadError.map(LegacyPluginLoadFailure.init)
            var refusal = loadError?.localizedDescription ?? NSLocalizedString("The bundle loader refused the plugin.", comment: "")
            // dyld's words, untranslated: they name the symbol the plugin looks for in the application.
            if let detail = failure?.linkDetail { refusal += " (dyld: \(detail))" }
            let reason = ObjC.format(NSLocalizedString("%@ Obtain a plugin compatible with this Mac and IsiX DICOM Viewer from its author.", comment: ""), refusal)
            NSLog("Plugin load failed: %@ (%@ %ld) dyld: %@", reason as NSString, ObjC.arg(loadError?.domain), loadError?.code ?? 0,
                  (failure?.dyldReason ?? "no reason given") as NSString)
            return (failure?.isArchitectureMismatch == true ? NSLocalizedString("Incompatible", comment: "") : NSLocalizedString("Load failed", comment: ""), reason)
        }
        // A class the Info.plist names and the bundle lacks is not replaced by another.
        let principal: AnyClass? = declaration.principalClass.map { plugin.classNamed($0) } ?? plugin.principalClass
        guard let filterClass = principal else {
            NSLog("********* principal class not found for: %@ - %@", path as NSString, ObjC.arg(declaration.principalClass))
            return (NSLocalizedString("Incompatible", comment: ""), NSLocalizedString("The principal class is missing. Obtain a corrected plugin from its author.", comment: ""))
        }

        let version = plugin.infoDictionary?[kCFBundleVersionKey as String] ?? plugin.infoDictionary?["CFBundleShortVersionString"]
        NSLog("Registering: %@, vers: %@ (%@)", ((path as NSString).lastPathComponent as NSString).deletingPathExtension as NSString,
              ObjC.arg(version), (path as NSString).deletingLastPathComponent as NSString)

        // ARGS is only kept as a loaded bundle.
        if let args: AnyClass = NSClassFromString("ARGS"), ObjectIdentifier(filterClass) == ObjectIdentifier(args) {
            Registry.change(\.pluginsBundleDictionnary) { ObjC.set($0, plugin, path) }
            return (NSLocalizedString("Loaded", comment: ""), NSLocalizedString("The bundle and its principal class loaded in this session.", comment: ""))
        }

        /// [filterClass filter], PluginFilter's factory: a class that does not answer it raises.
        func makeFilter() -> Any? {
            (filterClass as AnyObject).perform(NSSelectorFromString("filter"))?.takeUnretainedValue()
        }
        let answersFilterImage = (filterClass as? NSObject.Type)?.instancesRespond(to: NSSelectorFromString("filterImage:")) == true
        switch declaration.registration(answersFilterImage: answersFilterImage) {
        case .preProcess:
            let filter = makeFilter()
            Registry.change(\.preProcessPlugins) { ObjC.add($0, filter) }
        case .fileFormats(let formats):
            // The bundle, not a filter: each file decoded makes its own decoder.
            for format in formats {
                Registry.change(\.fileFormatPlugins) { ObjC.set($0, plugin, format) }
            }
        case .filter(let titles):
            let filter = makeFilter()
            for title in titles {
                Registry.change(\.plugins) { ObjC.set($0, filter, title) }
                Registry.change(\.pluginsDict) { ObjC.set($0, plugin, title) }
            }
        case .none:
            break
        }
        if declaration.isReport {
            Registry.change(\.reportPlugins) { ObjC.set($0, plugin, declaration.executableName) }
        }
        Registry.change(\.pluginsBundleDictionnary) { ObjC.set($0, plugin, path) }
        return (NSLocalizedString("Loaded", comment: ""), NSLocalizedString("The bundle and its principal class loaded and registration completed in this session.", comment: ""))
    }

    @objc(loadHorosPluginAtPath:)
    class func loadHorosPlugin(atPath path: String!) {
        PluginManager.loadPluginBundle(path)
    }

    @objc(loadOsiriXPluginAtPath:)
    class func loadOsiriXPlugin(atPath path: String!) {
        PluginManager.loadPluginBundle(path)
    }

    @objc(loadPluginAtPath:)
    public class func loadPlugin(atPath path: String!) {
        #if !MACAPPSTORE
        let name = (path as NSString).lastPathComponent

        // The extension decides the loader: a .isixplugin goes to the version 1
        // loader, which never hands a bundle it refuses on to the former one.
        // Anything else in a plugins folder is not a plugin.
        guard PluginAdmission.isManaged(name), let loader = PluginAdmission.loader(for: name) else { return }

        if Registry.pluginsNames?.value(forKey: ((name as NSString).lastPathComponent as NSString).deletingPathExtension) != nil {
            PluginManager.reportDuplicate(atPath: path, reason: NSLocalizedString("Another plugin with this name was selected for loading. Remove the duplicate through Plugin Manager and restart IsiX DICOM Viewer.", comment: ""))
            return
        }

        Registry.change(\.pluginsNames) { $0?.setValue((path as NSString).deletingLastPathComponent, forKey: ((name as NSString).lastPathComponent as NSString).deletingPathExtension) }
        switch loader {
        case .version1:
            PluginManager.loadIsiXPlugin(atPath: path)
        case .formerAPI:
            if (name as NSString).pathExtension.lowercased() == "osirixplugin" {
                PluginManager.loadOsiriXPlugin(atPath: path)
            } else {
                PluginManager.loadHorosPlugin(atPath: path)
            }
        }

        let outcome = PluginManagerCAPILoadOutcome((path as NSString?)?.resolvingAlias(), true)
        if ObjC.isEqualToString(outcome["loadState"], NSLocalizedString("Loaded", comment: "")) {
            PluginUpdateRecovery.discardPrevious(forDestination: path)
        }
        #endif
    }

    /// Moves the plugins found inside the application to the user's plugins
    /// folders (BundledPluginMigration says why, and what it never does), and
    /// answers the paths of those still inside that the user's folder has as
    /// they are, for the discovery to pass over. The folder inside is still
    /// read after this: a plugin that could not be taken out goes on loading.
    /// A session without plugins moves nothing.
    private class func takePluginsOutOfApplication() -> Set<String> {
        guard DCMPix.isRunOsiriXInProtectedModeActivated() == false, let bundled = PluginManager.appActivePluginsDirectoryPath() else { return [] }
        let migration = BundledPluginMigration(bundled: URL(fileURLWithPath: bundled, isDirectory: true),
                                               bundledDisabled: URL(fileURLWithPath: bundled + " Disabled", isDirectory: true),
                                               userDomain: PluginManager.userPluginsDomain())
        let entries = migration.run(isPlugin: PluginAdmission.isManaged)
        for entry in entries {
            let name = entry.source.lastPathComponent as NSString
            switch entry.outcome {
            case .moved(let destination):
                NSLog("Plugin %@ moved out of the application to %@", name, destination.deletingLastPathComponent().path as NSString)
            case .copied(let destination, let reason):
                NSLog("Plugin %@ copied out of the application to %@; the copy inside could not be removed: %@", name,
                      destination.deletingLastPathComponent().path as NSString, reason as NSString)
            case .nameTaken(let existing, let sameBuild):
                NSLog("Plugin %@ stays inside the application: %@ is %@", name, existing.path as NSString,
                      (sameBuild ? "the same plugin" : "another plugin of that name") as NSString)
            case .failed(let reason):
                NSLog("Plugin %@ could not be moved out of the application: %@", name, reason as NSString)
            }
        }
        return Set(BundledPluginMigration.duplicatesLeftInside(entries).compactMap { ($0.path as NSString).resolvingSymlinksAndAliases() })
    }

    /// Records a bundle that does not load because another one of its name
    /// does, with the reason the plugins list shows, and says so once.
    private class func reportDuplicate(atPath path: String, reason: String) {
        let name = (path as NSString).lastPathComponent
        PluginManagerCAPIRecordLoad((path as NSString?)?.resolvingAlias(), NSLocalizedString("Blocked", comment: ""), reason)
        NSLog("***** Multiple plugins: %@", name as NSString)

        var message = NSLocalizedString("Warning! Multiple instances of the same plugin have been found. Only one instance will be loaded. Check the Plugin Manager (Plugins menu) for multiple identical plugins.", comment: "")

        message = (message as NSString).appendingFormat("\r\r%@", name as NSString) as String

        HorosAlertPanel.run(title: NSLocalizedString("Plugins", comment: ""), message: message, defaultButton: nil, alternateButton: nil, otherButton: nil)
    }

    /// The rank of the folder a discovered bundle is in, for bundles of one
    /// name and one version: nil is the command line's.
    private class func folderRank(of folder: String?, userAndSystemFolders: [String]) -> Int {
        guard let folder else { return 0 }
        if let index = userAndSystemFolders.firstIndex(of: folder) { return 1 + index }
        return 1 + userAndSystemFolders.count
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
                // NSNull stands for explicit load commands from the launch arguments.
                let paths = ObjC.array(upToFirstNil: [NSNull(), appPath] + folders.map { $0 as Any? })

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
                if FileManager.default.fileExists(atPath: pluginCrash) && !PreferencesSource.process.preferences[ApplicationPreferences.doNotDeleteCrashingPlugins] {
                    // An unreadable note reads as an empty path, which is nobody's plugin.
                    let marker = PluginCrashMarker(contents: (try? String(contentsOfFile: pluginCrash, encoding: .utf8)) ?? "")
                    let pluginCrashPath = marker.pluginPath
                    let wasRunning = marker.phase == .running
                    // Recovery acts only on a plugin in this app's own folders: the
                    // marker names a path, and a plugin given with --LoadPlugin, or
                    // any other path, is not this app's to restore or move.
                    let ownPlugin = PluginManager.isInOwnPluginsFolder(pluginCrashPath)
                            && PluginAdmission.mayManage(bundleAt: URL(fileURLWithPath: pluginCrashPath))
                    if ownPlugin {
                        _ = PluginUpdateRecovery.adoptLeftoverStaging(inDirectory: (pluginCrashPath as NSString).deletingLastPathComponent)
                    }
                    let inactivePath = PluginQuarantine.inactivePath(forPluginAt: pluginCrashPath,
                                                                     active: PluginManager.activeDirectories() as! [String],
                                                                     inactive: PluginManager.inactiveDirectories() as! [String])
                    let canRestore = ownPlugin && FileManager.default.fileExists(atPath: PluginUpdateRecovery.previousPath(forDestination: pluginCrashPath))
                    // A plugin that stopped while loading may stop every launch there, so
                    // this one opens without plugins and proposes to take it out. One that
                    // was running a command had loaded: it stays unless the user says so.
                    let recovery = marker.recovery(canRestore: canRestore, canDisable: inactivePath != nil)
                    if recovery.opensWithoutPlugins && PluginUpdateRecovery.shouldEnterPluginLessMode(markerExists: true) {
                        ProtectedMode.activateAfterPluginFailure()
                    }
                    NSLog("Plugin note left by the previous run: %@ was %@", (pluginCrashPath as NSString).lastPathComponent as NSString,
                          (wasRunning ? "running a command" : "loading") as NSString)
                    let explanation = PluginUpdateRecovery.explanation(pluginNamed: (pluginCrashPath as NSString).lastPathComponent,
                                                                       wasRunning: wasRunning,
                                                                       canRestore: canRestore,
                                                                       canDisable: inactivePath != nil)
                    let buttons = recovery.choices.map { choice -> String in
                        switch choice {
                        case .restorePrevious: return NSLocalizedString("Restore Previous", comment: "")
                        case .disablePlugin: return NSLocalizedString("Disable Plugin", comment: "")
                        case .keepPlugin: return recovery.choices.count == 1 ? NSLocalizedString("OK", comment: "") : NSLocalizedString("Continue", comment: "")
                        }
                    }
                    let result = HorosAlertPanel.runInformational(title: PluginUpdateRecovery.alertTitle(wasRunning: wasRunning), message: explanation,
                                                                  defaultButton: buttons[0],
                                                                  alternateButton: buttons.count > 1 ? buttons[1] : nil,
                                                                  otherButton: buttons.count > 2 ? buttons[2] : nil)
                    let answered = result == HorosAlertPanel.defaultResponse ? 0 : (result == HorosAlertPanel.otherResponse ? 2 : 1)
                    switch recovery.choice(at: answered) {
                    case .restorePrevious:
                        _ = PluginUpdateRecovery.restorePrevious(forDestination: pluginCrashPath)
                    case .disablePlugin:
                        if let inactivePath {
                            PluginManager.movePlugin(fromPath: pluginCrashPath, toPath: inactivePath)
                            if FileManager.default.fileExists(atPath: inactivePath) {
                                NSLog("Plugin disabled after a crash: %@ -> %@", pluginCrashPath as NSString, inactivePath as NSString)
                            } else {
                                NSLog("**** Could not disable the plugin the note names: %@", pluginCrashPath as NSString)
                            }
                        }
                    case .keepPlugin:
                        break
                    }
                    try? FileManager.default.removeItem(atPath: pluginCrash)
                }

                // A plugin installed inside the application goes to the user's folder
                // before the folders are read, and loads from there.
                let duplicatesInsideApplication = PluginManager.takePluginsOutOfApplication()

                let pathsOfPluginsToLoad = NSMutableArray()
                // Which folder each bundle came from, for the choice between bundles
                // of one name and one version: a bundle named on the command line
                // first, then the user's folder, the computer's, and the application's.
                var folderRanks: [String: Int] = [:]
                let dontLoadOtherWithTheseNames = NSMutableArray()

                for path in paths {
                    var stop = false
                    do {
                        try HorosObjCException.perform {
                            // NSNull, the command line, becomes "/" below.
                            let folder = path as? String
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
                                    let resolved = ((path as! NSString).appendingPathComponent(name as! String) as NSString).resolvingSymlinksAndAliases()
                                    if let resolved, duplicatesInsideApplication.contains(resolved) {
                                        NSLog("Won't load %@ from inside the application: the user's plugins folder has this plugin", ObjC.arg(name))
                                        continue
                                    }
                                    ObjC.add(pathsOfPluginsToLoad, resolved)
                                    if let resolved, folderRanks[resolved] == nil {
                                        folderRanks[resolved] = PluginManager.folderRank(of: folder, userAndSystemFolders: folders)
                                    }
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

                // A plugin made for Horos or OsiriX can ask, with Requirements in
                // its Info.plist, to load after others; the property lists are
                // read as files, no bundle is opened here. A version 1 bundle that
                // declares it is refused by its inspection.
                // One plugin under two bundles, as the installers of plugins made for
                // Horos and OsiriX leave it (Thing.horosplugin and a newer
                // Thing.osirixplugin): the higher version loads, whatever the order the
                // folder lists them in and whatever their extensions (SameNamePlugins).
                // The others are set aside here, each with the reason and both versions.
                let found = pathsOfPluginsToLoad.compactMap { $0 as? String }.filter { PluginAdmission.isManaged($0) }.map { path in
                    SameNamePlugins.Candidate(path: path, version: PluginBundleVersion.declared(byBundleAt: URL(fileURLWithPath: path)),
                                              folderRank: folderRanks[path] ?? Int.max)
                }
                for duplicate in SameNamePlugins.setAside(among: found) {
                    pathsOfPluginsToLoad.remove(duplicate.bundle.path)
                    PluginManager.reportDuplicate(atPath: duplicate.bundle.path, reason: String(format: NSLocalizedString(
                        "%1$@ (%2$@) has the same name and was selected for loading instead of this plugin (%3$@). Remove the duplicate through Plugin Manager and restart IsiX DICOM Viewer.",
                        comment: "The plugin loaded, its version, and the version of the one set aside"),
                        (duplicate.preferred.path as NSString).lastPathComponent,
                        duplicate.preferred.version ?? NSLocalizedString("no version", comment: "A plugin that declares no version"),
                        duplicate.bundle.version ?? NSLocalizedString("no version", comment: "A plugin that declares no version")))
                }

                let pending = pathsOfPluginsToLoad.compactMap { $0 as? String }.map { path -> LegacyPluginDeclaration.Pending in
                    let declaration = LegacyPluginDeclaration(bundleAt: URL(fileURLWithPath: path))
                    let name = declaration?.bundleName ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    let requirements = PluginAdmission.kind(of: path) == .formerAPI ? (declaration?.requirements ?? []) : []
                    return LegacyPluginDeclaration.Pending(path: path, name: name, requirements: requirements)
                }
                let (order, unmet) = LegacyPluginDeclaration.loadOrder(pending)
                for (plugin, requirement) in unmet {
                    // It still loads: it may only fail where it uses the other plugin.
                    NSLog("Warning: plugin requirement %@ not available for %@", requirement as NSString, plugin as NSString)
                }
                for plugin in order {
                    PluginManager.loadPlugin(atPath: plugin.path)
                }

                if let plugins = Registry.plugins {
                    T2FitMapFilter.register(in: plugins)
                    ROIEnhancementFilter.register(in: plugins)
                    // A loaded plugin that declares the title keeps it.
                    if plugins[T1FitMapFilter.menuTitle] == nil {
                        plugins[T1FitMapFilter.menuTitle] = T1FitMapFilter()
                    }
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
    /// plugin to the disabled folder. In this mode the plugins folders and the
    /// marker are inside the isolated folder. `--LoadPlugin <bundle>` still
    /// loads a given plugin. Only the command line counts, not a saved preference.
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

    /// Crash recovery may only change a plugin in a managed folder.
    public class func isInOwnPluginsFolder(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        func resolved(_ folder: String) -> String {
            URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let parent = resolved((path as NSString).deletingLastPathComponent)
        let own = ((activeDirectories() ?? []) + (inactiveDirectories() ?? [])).compactMap { $0 as? String }
        return own.contains { resolved($0) == parent }
    }

    // MARK: activation

    @objc(movePluginFromPath:toPath:)
    public class func movePlugin(fromPath sourcePath: String!, toPath destinationPath: String!) {
        #if !MACAPPSTORE
        if ObjC.isEqualToString(sourcePath, destinationPath) { return }

        // The plugins folders of all users, under /Library, do not exist until a
        // plugin goes there, and the user cannot make them: the move then
        // makes them with its own authorization.
        let destinationDirectory = (destinationPath as NSString?)?.deletingLastPathComponent
        var directoryNeedsPrivilege = false
        if let destinationDirectory, !FileManager.default.fileExists(atPath: destinationDirectory) {
            directoryNeedsPrivilege = (try? FileManager.default.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true, attributes: nil)) == nil
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
            let authentication = PluginManager.authentication()
            if directoryNeedsPrivilege, let destinationDirectory {
                // Both rights at once, so that one password makes the folder
                // and moves the plugin.
                _ = authentication?.authenticate(["/bin/mkdir", "/bin/mv"])
                _ = authentication?.executeCommand("/bin/mkdir", withArgs: ["-p", destinationDirectory])
            }

            let args = NSMutableArray()
            args.add("-f")
            ObjC.add(args, sourcePath)
            ObjC.add(args, destinationPath)

            _ = authentication?.executeCommand("/bin/mv", withArgs: args as? [Any])
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

    /// Asks for a restart once per run, from any thread, and returns when the
    /// alert is answered. The flag and the alert are the main thread's; the
    /// alert opens from the main run loop, so that the main queue goes on while
    /// it is open, and the flag is set before it opens, so that a change made
    /// meanwhile does not open a second one.
    private static func askForRestart(title: String, message: String) {
        onMainRunLoopSync {
            guard !gPluginsAlertAlreadyDisplayed.boolValue else { return }
            gPluginsAlertAlreadyDisplayed = true
            HorosAlertPanel.runInformational(title: title, message: message, defaultButton: NSLocalizedString("OK", comment: ""),
                                             alternateButton: nil, otherButton: nil)
        }
    }

    /// Asks for the restart that makes installed, replaced or removed plugins take effect.
    class func askForRestartAfterPluginChanges() {
        PluginManager.askForRestart(title: NSLocalizedString("Plugins", comment: ""), message: NSLocalizedString("Restart IsiX DICOM Viewer to apply the changes to the plugins.", comment: ""))
    }

    /// Puts the bundle at `source` in the place of the installed plugin at
    /// `installed`, under the name it is installed with, as an update does:
    /// the candidate is checked first, the swap is atomic, and the copy it
    /// replaces is kept until the new one has loaded once.
    class func replaceInstalledPlugin(at installed: URL, with source: URL) throws {
        #if !MACAPPSTORE
        var error: NSError?
        guard PluginManagerCAPIInstallPlugin(source.path, installed.path, &error) else {
            throw error ?? CocoaError(.fileWriteUnknown)
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

        PluginManager.askForRestart(title: NSLocalizedString("Plugins", comment: ""), message: NSLocalizedString("Restart IsiX DICOM Viewer to apply the changes to the plugins.", comment: ""))
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

        PluginManager.askForRestart(title: NSLocalizedString("Plugins", comment: ""), message: NSLocalizedString("Restart IsiX DICOM Viewer to apply the changes to the plugins.", comment: ""))
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
        } else {
            // The application itself is no longer a place to put a plugin: it
            // is lost when the application is replaced, and it breaks the seal
            // of the signature. Nor is an availability nobody offers.
            NSLog("Plugin %@ was not moved: %@ is not an availability a plugin can be given", ObjC.arg(pluginName), ObjC.arg(availability))
            return
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
        // Validate the candidate before touching an existing installation, by
        // the rules of the loader its format goes to, whatever the entry that
        // brought it.
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
        } else {
            // A new plugin, and the update of one still inside the application:
            // nothing is installed into the application any more.
            if isActive {
                destinationDirectory = PluginManager.userActivePluginsDirectoryPath()
            } else {
                destinationDirectory = PluginManager.userInactivePluginsDirectoryPath()
            }
        }

        destinationPath = ObjC.appendingPathComponent(destinationDirectory as NSString?, (path as NSString).lastPathComponent)

        // A plugin made for Horos or OsiriX is updated in place under the
        // extension it was installed with.
        if PluginAdmission.kind(of: path) == .formerAPI {
            for pathExtension in PluginAdmission.formerExtensions.sorted() {
                let existingPath = ObjC.appendingPathComponent(destinationDirectory as NSString?,
                    (pluginBundleName as NSString).appendingPathExtension(pathExtension))
                if let existingPath, FileManager.default.fileExists(atPath: existingPath) {
                    destinationPath = existingPath
                    break
                }
            }
        }

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
                        // From the main run loop: the main queue goes on while it is open.
                        onMainRunLoopSync {
                            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Plugins", comment: ""), message: error.localizedDescription, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                        }
                    }
                }
            }
        }

        if returnPath != nil {
            PluginManager.askForRestart(title: NSLocalizedString("Plugins", comment: ""), message: NSLocalizedString("Restart IsiX DICOM Viewer to apply the changes to the plugins.", comment: ""))
        }

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

                    // Read from its metadata and executable only, by the rules of
                    // its format's loader: listing never loads a plugin.
                    pluginDescription.setObject(PluginManager.isIsiXPluginCompatible(atPath: pluginPath) ? "YES" : "NO", forKey: "HorosCompatiblePlugin" as NSString)

                    ////////////////////////////////////

                    // plugin description dictionary
                    plugins.add(pluginDescription)
                }
            }
        }

        let sortedPlugins = plugins.sortedArray(sortPluginArray, context: nil)

        return sortedPlugins
        #endif
    }

    /// The three places a plugin can be found in, by their names in the
    /// plugins list: the last one, inside the application, is only where one
    /// may still be, not where one can be put.
    @objc public class func availabilities() -> [Any]! {
        return [NSLocalizedString("Current user", comment: ""),
                NSLocalizedString("All users", comment: ""),
                NSLocalizedString("IsiX DICOM Viewer bundle", comment: "")]
    }

    /// The availabilities the plugin manager offers for a plugin: the current
    /// user's folder and the one of all users.
    public class func offeredAvailabilities() -> [Any] {
        return Array(PluginManager.availabilities().prefix(2))
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

    /// The database window, read on the main actor: it runs the items of
    /// database and report plugins, and holds the plugin manager's window.
    private class func databaseWindow() -> BrowserController? {
        onMainActorSync { BrowserDatabaseSource.process.processGraph.currentBrowser }
    }

    /// The plugin manager's window controller, which the database window
    /// holds. It is reached by its selectors, whatever language it is in.
    private class func pluginManagerController() -> NSObject? {
        return PluginManager.databaseWindow()?.pluginManagerController
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
            PluginManager.askForRestart(title: NSLocalizedString("Plugin Update Completed", comment: ""), message: NSLocalizedString("All your plugins are now up to date. Restart IsiX DICOM Viewer to use the new or updated plugins.", comment: ""))

            startedUpdateProcess = false
        }
        #endif
    }
}
