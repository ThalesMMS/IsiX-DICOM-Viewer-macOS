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
import WebKit

// The catalogs are shared by every controller and kept ten minutes: the file
// statics of the former PluginManagerController.m.
private var CachedOsiriXPluginsList: NSArray? = nil
private var CachedOsiriXPluginsListDate: Date? = nil

private var CachedHorosPluginsList: NSArray? = nil
private var CachedHorosPluginsListDate: Date? = nil

/// The class methods of PluginManager this window sends, by their Objective-C
/// selectors. PluginManager.h declares them for the application's Objective-C
/// only (OSIRIX_VIEWER), which Swift does not see; the messages go to the
/// PluginManager class object, as [PluginManager ...] did.
@objc private protocol PluginManagerMessages {
    @objc(pluginsList) func pluginsList() -> NSArray?
    @objc(availabilities) func availabilities() -> NSArray?
    @objc(setMenus::::) func setMenus(_ filtersMenu: NSMenu?, _ roisMenu: NSMenu?, _ othersMenu: NSMenu?, _ dbMenu: NSMenu?)
    @objc(activatePluginWithName:) func activatePlugin(withName pluginName: String?)
    @objc(deactivatePluginWithName:) func deactivatePlugin(withName pluginName: String?)
    @objc(changeAvailabilityOfPluginWithName:to:) func changeAvailabilityOfPlugin(withName pluginName: String?, to availability: String?)
    @discardableResult
    @objc(deletePluginWithName:) func deletePlugin(withName pluginName: String?) -> String?
    @discardableResult
    @objc(deletePluginWithName:availability:isActive:) func deletePlugin(withName pluginName: String?, availability: String?, isActive: Bool) -> String?
    @objc(userActivePluginsDirectoryPath) func userActivePluginsDirectoryPath() -> String?
    @objc(movePluginFromPath:toPath:) func movePlugin(fromPath sourcePath: String?, toPath destinationPath: String?)
    @objc(loadPluginAtPath:) func loadPlugin(atPath path: String?)
}

private var pluginManager: PluginManagerMessages {
    unsafeBitCast(PluginManager.self as AnyObject, to: PluginManagerMessages.self)
}

/// The plugin table of PluginManager.xib: Delete and Backspace send -delete:
/// to its delegate, the PluginManagerController.
@objc(PluginsTableView)
public final class PluginsTableView: NSTableView {

    public override func keyDown(with event: NSEvent) {
        guard let characters = event.characters as NSString?, characters.length != 0 else {
            return
        }

        let c = Int(characters.character(at: 0))

        if (c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey) && self.selectedRow >= 0 && self.numberOfRows > 0 {
            _ = (self.delegate as AnyObject?)?.perform(NSSelectorFromString("delete:"), with: self)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Window Controller for PluginFilter management: the plugin manager window
/// (installed plugins, the OsiriX and Horos catalogs, downloads and installs).
///
/// Implemented in Swift since #720: the Objective-C name, the selectors and
/// <Horos/PluginManagerController.h> are those of the former class. The C
/// function sortPluginArrayByName of the former PluginManagerController.m is
/// in PluginManagerController+CAPI.m. MainMenu.xib creates one with -init, and
/// PluginManager.xib has it as File's Owner.
@objc(PluginManagerController)
public final class PluginManagerController: NSWindowController, NSURLDownloadDelegate {

    // Outlets the xibs set: ivars of the former class.
    @IBOutlet @objc var filtersMenu: NSMenu?
    @IBOutlet @objc var roisMenu: NSMenu?
    @IBOutlet @objc var othersMenu: NSMenu?
    @IBOutlet @objc var dbMenu: NSMenu?

    @IBOutlet @objc var pluginsArrayController: NSArrayController?
    @IBOutlet @objc var pluginTable: PluginsTableView?

    @IBOutlet @objc var tabView: NSTabView?
    @IBOutlet @objc var installedPluginsTabViewItem: NSTabViewItem?
    @IBOutlet @objc var osirixPluginsTabViewItem: NSTabViewItem?
    @IBOutlet @objc var horosPluginsTabViewItem: NSTabViewItem?

    @IBOutlet @objc var osirixPluginWebView: WebView?
    @IBOutlet @objc var horosPluginWebView: WebView?
    @IBOutlet @objc var osirixPluginListPopUp: NSPopUpButton?
    @IBOutlet @objc var horosPluginListPopUp: NSPopUpButton?
    @IBOutlet @objc var osirixPluginDownloadButton: NSButton?
    @IBOutlet @objc var horosPluginDownloadButton: NSButton?

    @IBOutlet @objc var osirixPluginStatusTextField: NSTextField?
    @IBOutlet @objc var horosPluginStatusTextField: NSTextField?
    @IBOutlet @objc var osirixPluginStatusProgressIndicator: NSProgressIndicator?
    @IBOutlet @objc var horosPluginStatusProgressIndicator: NSProgressIndicator?

    @IBOutlet @objc var validatedInHorosBox: NSBox?
    @IBOutlet @objc var NOTvalidatedInHorosBox: NSBox?
    @IBOutlet @objc var protectedModeLabel: NSTextField?

    /// What -plugins returns: the array PluginManager.xib's controller binds
    /// to, emptied and refilled in place by -refreshPluginList.
    private var pluginsArray = NSMutableArray()

    private var osirixPluginListURLs: [String] = [OSIRIX_PLUGIN_LIST_URL, OSIRIX_PLUGIN_LIST_ALT_URL]
    private var horosPluginListURLs: [String] = [HOROS_PLUGIN_LIST_URL, HOROS_PLUGIN_LIST_ALT_URL]
    private var osirixPluginDownloadURL: String? = nil
    private var horosPluginDownloadURL: String? = nil
    private var osiriXPluginHorosCompatibility = false

    private var osirixCatalogError: NSError? = nil
    private var horosCatalogError: NSError? = nil
    /// Download path -> NSURLDownload. Also the lock of the downloads, as
    /// @synchronized(downloadingPlugins) was.
    private let downloadingPlugins = NSMutableDictionary()

    // NSWindowController's -init is a convenience initializer: this one
    // replaces it without `override`, as the former -init did.
    @objc public convenience init() {
        self.init(windowNibName: "PluginManager")

        pluginsArray = NSMutableArray(array: (pluginManager.pluginsList() as? [Any]) ?? [])
    }

    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc(WebViewProgressStartedNotification:)
    public func WebViewProgressStartedNotification(_ n: Notification) {
        var statusProgressIndicator: NSProgressIndicator? = nil

        if (n.object as AnyObject?) === osirixPluginWebView {
            statusProgressIndicator = osirixPluginStatusProgressIndicator
        } else {
            statusProgressIndicator = horosPluginStatusProgressIndicator
        }

        statusProgressIndicator?.isHidden = false
        statusProgressIndicator?.startAnimation(self)

        self.window?.display()
    }

    @objc(WebViewProgressFinishedNotification:)
    public func WebViewProgressFinishedNotification(_ n: Notification) {
        var statusProgressIndicator: NSProgressIndicator? = nil

        if (n.object as AnyObject?) === osirixPluginWebView {
            statusProgressIndicator = osirixPluginStatusProgressIndicator
        } else {
            statusProgressIndicator = horosPluginStatusProgressIndicator
        }

        statusProgressIndicator?.isHidden = true
        statusProgressIndicator?.stopAnimation(self)

        self.window?.display()
    }

    @objc(windowDidBecomeMain:)
    public func windowDidBecomeMain(_ notification: Notification) {
        if AppController.isFDACleared() {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Important Notice", comment: ""), message: NSLocalizedString("Plugins are not certified for primary diagnosis in medical imaging, unless specifically written by the plugin author(s).", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    // MARK: -
    // MARK: installed

    @objc(plugins)
    public func plugins() -> NSMutableArray! {
        return pluginsArray
    }

    @objc(availabilities)
    public func availabilities() -> NSArray! {
        return pluginManager.availabilities()
    }

    /// The row of the table's arranged objects: -objectAtIndex: raises for a
    /// row outside the list (-1 when nothing was clicked), as it did.
    private func arrangedPlugin(atRow row: Int) -> NSDictionary? {
        let pluginsList = pluginsArrayController?.arrangedObjects as? NSArray
        return pluginsList?.object(at: row) as? NSDictionary
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? NSString { return string.boolValue }
        return false
    }

    /// [value isEqualToString:other], NO when either is nil.
    private static func isEqualToString(_ value: Any?, _ other: Any?) -> Bool {
        guard let string = value as? NSString, let other = other as? String else { return false }
        return string.isEqual(to: other)
    }

    /// What %@ printed for an object: its description, or (null).
    private static func formatted(_ value: Any?) -> String {
        guard let value = value else { return "(null)" }
        return String(describing: value as AnyObject)
    }

    /// [NSURLRequest requestWithURL:[NSURL URLWithString:string]], which took
    /// the nil URL of a missing or invalid string.
    private static func request(forURLString string: String?) -> URLRequest {
        if let string = string, let url = NSURL(string: string) as URL? {
            return URLRequest(url: url)
        }
        return NSURLRequest() as URLRequest
    }

    @IBAction @objc(modifiyActivation:)
    public func modifiyActivation(_ sender: Any!) {
        let clickedRow = pluginTable?.clickedRow ?? 0
        let pluginName = arrangedPlugin(atRow: clickedRow)?.object(forKey: "name") as? String
        let pluginIsActive = Self.boolValue(arrangedPlugin(atRow: clickedRow)?.object(forKey: "active"))

        if !pluginIsActive {
            pluginManager.deactivatePlugin(withName: pluginName)
        } else {
            pluginManager.activatePlugin(withName: pluginName)
        }

        refreshPluginList()
        pluginTable?.selectRowIndexes(IndexSet(integer: pluginTable?.clickedRow ?? 0), byExtendingSelection: false)
    }

    @IBAction @objc(delete:)
    public func delete(_ sender: Any!) {
        if ((pluginsArrayController?.arrangedObjects as? NSArray)?.count ?? 0) == 0 {
            return
        }

        if HorosAlertPanel.runInformational(title: NSLocalizedString("Delete a plugin", comment: ""),
                                            message: NSLocalizedString("Are you sure you want to delete the selected plugin?", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""),
                                            alternateButton: NSLocalizedString("Cancel", comment: ""),
                                            otherButton: nil) == NSAlertDefaultReturn {
            let selectedRow = pluginTable?.selectedRow ?? 0
            let pluginName = arrangedPlugin(atRow: selectedRow)?.object(forKey: "name") as? String
            let availability = arrangedPlugin(atRow: selectedRow)?.object(forKey: "availability") as? String
            let pluginIsActive = Self.boolValue(arrangedPlugin(atRow: selectedRow)?.object(forKey: "active"))

            pluginManager.deletePlugin(withName: pluginName,
                                       availability: availability,
                                       isActive: pluginIsActive)

            refreshPluginList()
        }
    }

    @IBAction @objc(modifiyAvailability:)
    public func modifiyAvailability(_ sender: Any!) {
        let pluginName = arrangedPlugin(atRow: pluginTable?.clickedRow ?? 0)?.object(forKey: "name") as? String

        pluginManager.changeAvailabilityOfPlugin(withName: pluginName, to: (sender as? NSControl)?.selectedCell()?.title)

        refreshPluginList() // needed to restore the availability menu in case the user did provided a good admin password
    }

    @IBAction @objc(loadPlugins:)
    public func loadPlugins(_ sender: Any!) {
        pluginManager.setMenus(filtersMenu, roisMenu, othersMenu, dbMenu)
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ aNotification: Notification) {
        self.window?.acceptsMouseMovedEvents = false

        do {
            try HorosObjCException.perform {
                self.refreshPluginList()
            }
        } catch {
            NSLog("windowwillClose exception pluginmanagercontroller: %@", Self.formatted((error as NSError).userInfo[HorosObjCExceptionKey]))
        }
    }

    @IBAction public override func showWindow(_ sender: Any?) {
        if self.window?.isVisible == true {
            self.window?.makeKeyAndOrderFront(nil)
            return
        }

        let splash = WaitRendering(NSLocalizedString("Initializing Plugin Manager...", comment: ""))
        splash?.showWindow(self)

        DispatchQueue.global(qos: .default).async {

            _ = self.availableOsiriXPlugins()
            _ = self.availableHorosPlugins()

            DispatchQueue.main.async {

                let viewers = ViewerController.getDisplayed2DViewers() as NSArray?
                for case let viewer as ViewerController in viewers ?? NSArray() {
                    viewer.window?.close()
                }

                super.showWindow(sender)


                self.refreshPluginList()



                ////////////////////////////////////////////////////////////////////////////////////////
                ////////////////////////////////////////////////////////////////////////////////////////
                ////////////////////////////////////////////////////////////////////////////////////////

                if DCMPix.isRunOsiriXInProtectedModeActivated() {
                    self.protectedModeLabel?.isHidden = false
                } else {
                    self.protectedModeLabel?.isHidden = true
                }


                self.configureCatalogStatusFields()
                self.configurePluginLoadDetails()
                // The controller answers the WebPolicyDelegate method by its selector
                // but does not list the protocol: the generated header would then
                // need WebKit's declaration in every Objective-C file importing it.
                self.osirixPluginWebView?.perform(#selector(setter: WebView.policyDelegate), with: self)
                self.horosPluginWebView?.perform(#selector(setter: WebView.policyDelegate), with: self)

                self.osirixPluginStatusTextField?.isHidden = true
                self.osirixPluginStatusProgressIndicator?.isHidden = true

                self.horosPluginStatusTextField?.isHidden = true
                self.horosPluginStatusProgressIndicator?.isHidden = true

                // deactivate the back/forward options in the webView's contextual menu
                self.osirixPluginWebView?.backForwardList.capacity = 0
                self.horosPluginWebView?.backForwardList.capacity = 0

                NotificationCenter.default.addObserver(self, selector: #selector(self.WebViewProgressStartedNotification(_:)), name: .WebViewProgressStarted, object: self.osirixPluginWebView)
                NotificationCenter.default.addObserver(self, selector: #selector(self.WebViewProgressFinishedNotification(_:)), name: .WebViewProgressFinished, object: self.osirixPluginWebView)

                NotificationCenter.default.addObserver(self, selector: #selector(self.WebViewProgressStartedNotification(_:)), name: .WebViewProgressStarted, object: self.horosPluginWebView)
                NotificationCenter.default.addObserver(self, selector: #selector(self.WebViewProgressFinishedNotification(_:)), name: .WebViewProgressFinished, object: self.horosPluginWebView)

                ////////////////////////////////////////////////////////////////////////////////////////

                let availableOsiriXCatalog = self.availableOsiriXPlugins()
                if (availableOsiriXCatalog?.count ?? 0) < 1 {
                    self.osirixPluginListPopUp?.removeAllItems()
                    self.osirixPluginListPopUp?.isEnabled = false
                    self.osirixPluginDownloadButton?.isEnabled = false

                    self.osirixPluginStatusTextField?.isHidden = false
                    self.osirixPluginStatusTextField?.stringValue = availableOsiriXCatalog != nil ? NSLocalizedString("The plugin catalog is empty.", comment: "") : (self.osirixCatalogError?.localizedDescription ?? NSLocalizedString("No OsiriX plugin server available.", comment: ""))
                } else {
                    self.generateAvailableOsiriXPluginsMenu()
                    let first = self.availableOsiriXPlugins()?.object(at: 0) as? NSObject
                    self.setURLforOsiriXPlugin(withName: first?.value(forKey: "name") as? String)
                    self.setOsiriXPluginDownloadURL(first?.value(forKey: "download_url") as? String)

                    self.setOsiriXPluginHorosCompatibility(
                        Self.boolValue(first?.value(forKey: "HorosCompatiblePlugin"))
                    )
                }

                ////////////////////////////////////////////////////////////////////////////////////////

                let availableHorosCatalog = self.availableHorosPlugins()
                if (availableHorosCatalog?.count ?? 0) < 1 {
                    self.horosPluginListPopUp?.removeAllItems()
                    self.horosPluginListPopUp?.isEnabled = false
                    self.horosPluginDownloadButton?.isEnabled = false

                    self.horosPluginStatusTextField?.isHidden = false
                    self.horosPluginStatusTextField?.stringValue = availableHorosCatalog != nil ? NSLocalizedString("The plugin catalog is empty.", comment: "") : (self.horosCatalogError?.localizedDescription ?? NSLocalizedString("No Horos plugin server available.", comment: ""))
                } else {
                    self.generateAvailableHorosPluginsMenu()

                    if let popUp = self.horosPluginListPopUp, popUp.indexOfItem(withTitle: "HorosCloud") != -1 {
                        let idx = popUp.indexOfItem(withTitle: "HorosCloud")

                        popUp.selectItem(at: idx)

                        let plugin = self.availableHorosPlugins()?.object(at: idx) as? NSObject
                        self.setURLforHorosPlugin(withName: plugin?.value(forKey: "name") as? String)
                        self.setHorosPluginDownloadURL(plugin?.value(forKey: "download_url") as? String)
                    } else {
                        let plugin = self.availableHorosPlugins()?.object(at: 0) as? NSObject
                        self.setURLforHorosPlugin(withName: plugin?.value(forKey: "name") as? String)
                        self.setHorosPluginDownloadURL(plugin?.value(forKey: "download_url") as? String)
                    }
                }

                ////////////////////////////////////////////////////////////////////////////////////////
                ////////////////////////////////////////////////////////////////////////////////////////
                ////////////////////////////////////////////////////////////////////////////////////////



                // If we need to remove a plugin with a custom pref pane
                for window in NSApp.windows {
                    if window.windowController is PreferencesWindowController {
                        window.close()
                    }
                }

                self.window?.makeKeyAndOrderFront(nil)


                splash?.close()

            }
        }
    }

    @objc(configurePluginLoadDetails)
    public func configurePluginLoadDetails() {
        guard let view = installedPluginsTabViewItem?.view, view.viewWithTag(16601) == nil else { return }
        let button = NSButton(title: NSLocalizedString("Loading Details...", comment: ""), target: self, action: #selector(showPluginLoadDetails(_:)))
        button.frame = NSMakeRect(430, 10, 180, 32)
        button.autoresizingMask = [.minXMargin, .maxYMargin]
        button.tag = 16601
        view.addSubview(button)
    }

    @objc(showPluginLoadDetails:)
    public func showPluginLoadDetails(_ sender: Any!) {
        let rows = pluginsArrayController?.arrangedObjects as? NSArray
        let row = pluginTable?.selectedRow ?? 0
        let alert = NSAlert()
        if row < 0 || row >= (rows?.count ?? 0) {
            alert.messageText = NSLocalizedString("Select a plugin first", comment: "")
        } else {
            let plugin = rows?.object(at: row) as? NSDictionary
            alert.messageText = "\(Self.formatted(plugin?["name"])): \(Self.formatted(plugin?["loadState"]))"
            alert.informativeText = plugin?["loadReason"] as? String ?? ""
        }
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        if let window = self.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    @objc(configureCatalogStatusFields)
    public func configureCatalogStatusFields() {
        let fields: [NSTextField?] = [osirixPluginStatusTextField, horosPluginStatusTextField]
        let buttons: [NSButton?] = [osirixPluginDownloadButton, horosPluginDownloadButton]
        for index in 0..<2 {
            guard let field = fields[index], let button = buttons[index] else { continue }
            var frame = field.frame
            frame.origin.y = 8
            frame.size.height = 42
            frame.size.width = max(282, NSMinX(button.frame) - NSMinX(frame) - 16)
            field.frame = frame
            field.autoresizingMask = [.width, .maxYMargin]
            field.textColor = NSColor.labelColor
            field.maximumNumberOfLines = 3
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.cell?.isScrollable = false
        }

    }

    public override func awakeFromNib() {
        super.awakeFromNib()

    }

    @objc(refreshPluginList)
    public func refreshPluginList() {
        let selectedIndexes = pluginTable?.selectedRowIndexes

        pluginManager.setMenus(filtersMenu, roisMenu, othersMenu, dbMenu)

        self.willChangeValue(forKey: "plugins")
        pluginsArray.removeAllObjects()
        pluginsArray.addObjects(from: (pluginManager.pluginsList() as? [Any]) ?? [])
        self.didChangeValue(forKey: "plugins")

        if let selectedIndexes = selectedIndexes {
            pluginTable?.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
        }
    }

    // MARK: NSTabView Delegate methods

    @objc(tabView:willSelectTabViewItem:)
    public func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if tabViewItem?.isEqual(to: installedPluginsTabViewItem) == true {
            refreshPluginList()
        }
    }

    // MARK: -
    // MARK: web view

    // MARK: pop up menu

    @objc(availableOsiriXPlugins)
    public func availableOsiriXPlugins() -> NSArray! {
        // showWindow preloads on its worker; UI callbacks must never repeat network I/O.
        if Thread.isMainThread { return CachedOsiriXPluginsList }

        var pluginsList: NSArray? = nil

        if CachedOsiriXPluginsListDate == nil || CachedOsiriXPluginsListDate!.timeIntervalSinceNow < -10 * 60 {

        } else if let cached = CachedOsiriXPluginsList {
            return cached
        }

        ////////////////////////////////////////////

        osirixCatalogError = nil
        let attempted = NSMutableSet()
        for endpoint in osirixPluginListURLs {
            if attempted.contains(endpoint) { continue }
            attempted.add(endpoint)
            var failure: NSError? = nil
            pluginsList = HorosLoadPluginCatalog(NSURL(string: endpoint) as URL?, 10, &failure) as NSArray?
            osirixCatalogError = failure
            if pluginsList != nil { break }
        }

        ////////////////////////////////////////////

        guard let loadedList = pluginsList else {
            CachedOsiriXPluginsList = nil
            return nil
        }

        let sortedPlugins = loadedList.sortedArray({ sortPluginArrayByName($0, $1, $2) }, context: nil) as NSArray

        CachedOsiriXPluginsListDate = Date()

        CachedOsiriXPluginsList = sortedPlugins

        return sortedPlugins
    }

    @objc(availableHorosPlugins)
    public func availableHorosPlugins() -> NSArray! {
        // showWindow preloads on its worker; UI callbacks must never repeat network I/O.
        if Thread.isMainThread { return CachedHorosPluginsList }

        var pluginsList: NSArray? = nil

        if CachedHorosPluginsListDate == nil || CachedHorosPluginsListDate!.timeIntervalSinceNow < -10 * 60 {

        } else if let cached = CachedHorosPluginsList {
            return cached
        }

        ////////////////////////////////////////////

        horosCatalogError = nil
        let attempted = NSMutableSet()
        for endpoint in horosPluginListURLs {
            if attempted.contains(endpoint) { continue }
            attempted.add(endpoint)
            var failure: NSError? = nil
            pluginsList = HorosLoadPluginCatalog(NSURL(string: endpoint) as URL?, 10, &failure) as NSArray?
            horosCatalogError = failure
            if pluginsList != nil { break }
        }

        ////////////////////////////////////////////

        guard let loadedList = pluginsList else {
            CachedHorosPluginsList = nil
            return nil
        }

        let sortedPlugins = loadedList.sortedArray({ sortPluginArrayByName($0, $1, $2) }, context: nil) as NSArray

        CachedHorosPluginsListDate = Date()

        CachedHorosPluginsList = sortedPlugins

        return sortedPlugins
    }

    @objc(generateAvailableOsiriXPluginsMenu)
    public func generateAvailableOsiriXPluginsMenu() {
        osirixPluginListPopUp?.removeAllItems()

        let availablePlugins = availableOsiriXPlugins()

        for loopItem in availablePlugins ?? NSArray() {
            if let name = (loopItem as? NSDictionary)?.object(forKey: "name") as? String {
                osirixPluginListPopUp?.addItem(withTitle: name)
            }
        }
    }

    @objc(generateAvailableHorosPluginsMenu)
    public func generateAvailableHorosPluginsMenu() {
        horosPluginListPopUp?.removeAllItems()

        let availablePlugins = availableHorosPlugins()

        for loopItem in availablePlugins ?? NSArray() {
            if let name = (loopItem as? NSDictionary)?.object(forKey: "name") as? String {
                horosPluginListPopUp?.addItem(withTitle: name)
            }
        }

        //[[horosPluginListPopUp menu] addItem:[NSMenuItem separatorItem]];

        //[horosPluginListPopUp addItemWithTitle:NSLocalizedString(@"Your Horos Plugin here!", nil)];
    }

    // MARK: OsiriX web page

    @objc(setOsiriXPluginURL:)
    public func setOsiriXPluginURL(_ url: String!) {
        osirixPluginWebView?.mainFrame.load(Self.request(forURLString: url))
    }

    /// Whether a catalog entry is installed, and in the same or a later version.
    ///
    /// The catalog names a plugin by its download's file name, which is the
    /// name of the bundle it installs: an installed plugin of that name is
    /// this entry, whatever its version, and the version only decides between
    /// "already installed" and "download the new version". The former
    /// `alreadyInstalled || sameName || (sameName && sameVersion)` said the
    /// same thing with a term that could never count (#777).
    private func installedState(of plugin: NSDictionary) -> (alreadyInstalled: Bool, sameName: Bool, sameVersion: Bool) {
        let name = HorosPluginDownloadName(plugin as? [AnyHashable: Any])
        for case let installedPlugin as NSDictionary in pluginsArray
            where Self.isEqualToString(name, installedPlugin.value(forKey: "name")) {
            let current = HorosComparePluginVersions(installedPlugin.object(forKey: "version"), plugin.object(forKey: "version")) != .orderedAscending
            return (true, true, current)
        }
        return (false, false, false)
    }

    @objc(setURLforOsiriXPluginWithName:)
    public func setURLforOsiriXPlugin(withName name: String!) {
        let availablePlugins = availableOsiriXPlugins()

        ////////////////////////////

        for case let plugin as NSDictionary in availablePlugins ?? NSArray() {
            if Self.isEqualToString(plugin.value(forKey: "name"), name) {
                if Self.boolValue(plugin.value(forKey: "HorosCompatiblePlugin")) {
                    self.validatedInHorosBox?.isHidden = false
                    self.NOTvalidatedInHorosBox?.isHidden = true
                } else {
                    self.NOTvalidatedInHorosBox?.isHidden = false
                    self.validatedInHorosBox?.isHidden = true
                }

                setOsiriXPluginURL(plugin.value(forKey: "url") as? String)
                setOsiriXPluginDownloadURL(plugin.value(forKey: "download_url") as? String)
                setOsiriXPluginHorosCompatibility(Self.boolValue(plugin.value(forKey: "HorosCompatiblePlugin")))

                let (alreadyInstalled, sameName, sameVersion) = installedState(of: plugin)

                if alreadyInstalled {
                    osirixPluginStatusTextField?.isHidden = false

                    if sameName && sameVersion {
                        osirixPluginStatusTextField?.stringValue = NSLocalizedString("Plugin already installed", comment: "")
                    } else {
                        osirixPluginStatusTextField?.stringValue = NSLocalizedString("Download the new version!", comment: "")
                    }
                } else {
                    osirixPluginStatusTextField?.isHidden = true
                }

                return
            }
        }
    }

    /// The popup's selected title: [sender title].
    private static func title(of sender: Any?) -> String? {
        if let button = sender as? NSButton { return button.title }
        if let item = sender as? NSMenuItem { return item.title }
        return nil
    }

    @IBAction @objc(changeOsiriXPluginWebView:)
    public func changeOsiriXPluginWebView(_ sender: Any!) {
        setURLforOsiriXPlugin(withName: Self.title(of: sender))
    }

    // MARK: Horos web page

    @objc(setHorosPluginURL:)
    public func setHorosPluginURL(_ url: String!) {
        horosPluginWebView?.mainFrame.load(Self.request(forURLString: url))
    }

    @objc(setURLforHorosPluginWithName:)
    public func setURLforHorosPlugin(withName name: String!) {
        let availablePlugins = availableHorosPlugins()

        ////////////////////////////

        for case let plugin as NSDictionary in availablePlugins ?? NSArray() {
            if Self.isEqualToString(plugin.value(forKey: "name"), name) {
                setHorosPluginURL(plugin.value(forKey: "url") as? String)
                setHorosPluginDownloadURL(plugin.value(forKey: "download_url") as? String)

                let (alreadyInstalled, sameName, sameVersion) = installedState(of: plugin)

                if alreadyInstalled {
                    horosPluginStatusTextField?.isHidden = false

                    if sameName && sameVersion {
                        horosPluginStatusTextField?.stringValue = NSLocalizedString("Plugin already installed", comment: "")
                    } else {
                        horosPluginStatusTextField?.stringValue = NSLocalizedString("Download the new version!", comment: "")
                    }
                } else {
                    horosPluginStatusTextField?.isHidden = true
                }

                return
            } else if Self.isEqualToString(name, NSLocalizedString("Your Horos Plugin here!", comment: "")) {
                loadSubmitPluginPage()

                return
            }
        }
    }

    @IBAction @objc(changeHorosPluginWebView:)
    public func changeHorosPluginWebView(_ sender: Any!) {
        setURLforHorosPlugin(withName: Self.title(of: sender))
    }

    // MARK: download

    @objc(setOsiriXPluginHorosCompatibility:)
    public func setOsiriXPluginHorosCompatibility(_ compatible: Bool) {
        osiriXPluginHorosCompatibility = compatible
    }

    @objc(setOsiriXPluginDownloadURL:)
    public func setOsiriXPluginDownloadURL(_ url: String!) {
        osirixPluginDownloadURL = url

        if Self.isEqualToString(osirixPluginDownloadURL, "") {
            osirixPluginDownloadButton?.isHidden = true
        } else {
            osirixPluginDownloadButton?.isHidden = false
        }
    }

    @objc(setHorosPluginDownloadURL:)
    public func setHorosPluginDownloadURL(_ url: String!) {
        horosPluginDownloadURL = url

        if Self.isEqualToString(horosPluginDownloadURL, "") {
            horosPluginDownloadButton?.isHidden = true
        } else {
            horosPluginDownloadButton?.isHidden = false
        }
    }

    @objc(fakeThread:)
    public func fakeThread(_ downloadedFilePath: String!) {
        autoreleasepool {
            var downloading = true

            while downloading {
                objc_sync_enter(downloadingPlugins)
                if downloadedFilePath == nil || downloadingPlugins.object(forKey: downloadedFilePath!) == nil {
                    downloading = false
                }

                Thread.sleep(forTimeInterval: 1)
                objc_sync_exit(downloadingPlugins)
            }
        }
    }

    /// Starts the download of a plugin to the temporary folder, unless the same file is
    /// already downloading: the common part of -downloadOsiriXPlugin: and
    /// -downloadHorosPlugin:.
    private func downloadPlugin(from downloadURL: String?) {
        let lastPathComponent = (downloadURL as NSString?)?.lastPathComponent as NSString?
        let fileName = lastPathComponent?.replacingPercentEscapes(using: String.Encoding.utf8.rawValue)
        let downloadedFilePath = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent(fileName ?? "(null)")

        objc_sync_enter(downloadingPlugins)
        defer { objc_sync_exit(downloadingPlugins) }

        if downloadingPlugins.object(forKey: downloadedFilePath) != nil {
            NSLog("---- Already downloading...")
        } else {
            let download = NSURLDownload(request: Self.request(forURLString: downloadURL), delegate: self)

            download.setDestination(downloadedFilePath, allowOverwrite: true)

            downloadingPlugins.setObject(download, forKey: downloadedFilePath as NSString)

            let t = Thread(target: self, selector: #selector(fakeThread(_:)), object: downloadedFilePath)
            t.name = NSLocalizedString("Plugin download...", comment: "")
            t.status = downloadURL
            ThreadsManager.default().addThreadAndStart(t)
        }
    }

    @IBAction @objc(downloadOsiriXPlugin:)
    public func downloadOsiriXPlugin(_ sender: Any!) {
        if self.osiriXPluginHorosCompatibility == false {
            let alert = NSAlert()
            alert.addButton(withTitle: NSLocalizedString("Yes", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("No", comment: ""))
            alert.messageText = NSLocalizedString("Not validated OsiriX plugin.", comment: "")
            alert.informativeText = NSLocalizedString("Not validated OsiriX plugins may cause Horos run-time errors. In case of problems, you can disable/uninstall them in [Plugins => Plugin Manager]. Continue installing?", comment: "")
            alert.alertStyle = .warning

            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        downloadPlugin(from: osirixPluginDownloadURL)
    }

    @IBAction @objc(downloadHorosPlugin:)
    public func downloadHorosPlugin(_ sender: Any!) {
        downloadPlugin(from: horosPluginDownloadURL)
    }

    /// The download's path, when it is in downloadingPlugins once, and the
    /// status field and progress indicator of its catalog: the OsiriX one for
    /// a path containing "osirixplugin", else the Horos one.
    private func statusControls(for download: NSURLDownload) -> (NSTextField?, NSProgressIndicator?) {
        objc_sync_enter(downloadingPlugins)
        defer { objc_sync_exit(downloadingPlugins) }

        let paths = downloadingPlugins.allKeys(for: download) as NSArray

        if paths.count == 1 {
            if (paths.object(at: 0) as? NSString)?.contains("osirixplugin") == true {
                return (osirixPluginStatusTextField, osirixPluginStatusProgressIndicator)
            } else {
                return (horosPluginStatusTextField, horosPluginStatusProgressIndicator)
            }
        }
        return (nil, nil)
    }

    private func downloadPaths(of download: NSURLDownload) -> NSArray {
        objc_sync_enter(downloadingPlugins)
        defer { objc_sync_exit(downloadingPlugins) }

        return downloadingPlugins.allKeys(for: download) as NSArray
    }

    private func removeDownload(atPath path: Any?) {
        guard let path = path else { return }

        objc_sync_enter(downloadingPlugins)
        defer { objc_sync_exit(downloadingPlugins) }

        downloadingPlugins.removeObject(forKey: path)
    }

    @objc(downloadDidBegin:)
    public func downloadDidBegin(_ download: NSURLDownload) {
        let (statusTextField, statusProgressIndicator) = statusControls(for: download)

        //////////////

        statusTextField?.isHidden = false
        statusTextField?.stringValue = NSLocalizedString("Downloading...", comment: "")
        statusProgressIndicator?.isHidden = false
        statusProgressIndicator?.startAnimation(self)
    }

    @objc(downloadDidFinish:)
    public func downloadDidFinish(_ download: NSURLDownload) {
        let (statusTextField, statusProgressIndicator) = statusControls(for: download)

        //////////////

        statusTextField?.stringValue = NSLocalizedString("Plugin downloaded", comment: "")
        statusProgressIndicator?.isHidden = true
        statusProgressIndicator?.stopAnimation(self)

        //////////////

        let paths = downloadPaths(of: download)

        if paths.count == 1 {
            installDownloadedPlugin(atPath: paths.lastObject as? String)

            NotificationCenter.default.post(name: .AppPluginDownloadInstallDidFinish, object: self, userInfo: nil)

            removeDownload(atPath: paths.lastObject)
        } else {
            NSLog("***** downloadDidFinish path for download?")
        }
    }

    @objc(download:didFailWithError:)
    public func download(_ download: NSURLDownload, didFailWithError error: Error) {
        let (statusTextField, statusProgressIndicator) = statusControls(for: download)

        //////////////

        statusTextField?.isHidden = false
        statusTextField?.stringValue = NSLocalizedString("Download failed", comment: "")

        HorosAlertPanel.runCritical(title: NSLocalizedString("Download failed", comment: ""), message: error.localizedDescription,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

        statusProgressIndicator?.isHidden = true
        statusProgressIndicator?.stopAnimation(self)

        //////////////

        let paths = downloadPaths(of: download)

        if paths.count == 1 {
            removeDownload(atPath: paths.lastObject)
        } else {
            NSLog("***** download didFailWithError path for download?")
        }
    }

    // MARK: install / uinstall

    @objc(installDownloadedPluginAtPath:)
    public func installDownloadedPlugin(atPath path: String!) {
        var statusTextField: NSTextField? = nil
        var statusProgressIndicator: NSProgressIndicator? = nil

        if (path as NSString?)?.contains("osirixplugin") == true {
            statusTextField = osirixPluginStatusTextField
            statusProgressIndicator = osirixPluginStatusProgressIndicator
        } else {
            statusTextField = horosPluginStatusTextField
            statusProgressIndicator = horosPluginStatusProgressIndicator
        }


        statusProgressIndicator?.isHidden = false
        statusProgressIndicator?.startAnimation(self)

        statusTextField?.stringValue = NSLocalizedString("Installing...", comment: "")

        var pluginPath: String? = path

        if isZippedFile(atPath: path) && unZipFile(atPath: path) {
            pluginPath = (path as NSString).deletingPathExtension
            try? FileManager.default.removeItem(atPath: path)
        } else {
            statusTextField?.stringValue = NSLocalizedString("Error: bad zip file", comment: "")
            statusProgressIndicator?.isHidden = true
            statusProgressIndicator?.stopAnimation(self)
            return
        }

        let pluginFileName = (pluginPath as NSString?)?.lastPathComponent

        let oldPath = pluginManager.deletePlugin(withName: pluginFileName)

        // determine in which directory to install the plugin (default = user dir, or if the plugin was already installed: in the same dir)
        let installDirectoryPath: String?

        if let oldPath = oldPath {
            installDirectoryPath = oldPath
        } else {
            installDirectoryPath = pluginManager.userActivePluginsDirectoryPath()
        }

        if let installDirectoryPath = installDirectoryPath, !FileManager.default.fileExists(atPath: installDirectoryPath) {
            try? FileManager.default.createDirectory(atPath: installDirectoryPath, withIntermediateDirectories: true, attributes: nil)
        }

        // Install the plugin
        pluginManager.movePlugin(fromPath: pluginPath, toPath: installDirectoryPath)

        // load the plugin
        pluginManager.loadPlugin(atPath: pluginFileName.flatMap { (installDirectoryPath as NSString?)?.appendingPathComponent($0) })

        statusTextField?.stringValue = NSLocalizedString("Plugin Installed", comment: "")
        statusProgressIndicator?.isHidden = true
        statusProgressIndicator?.stopAnimation(self)

        refreshPluginList()
    }

    @objc(isZippedFileAtPath:)
    public func isZippedFile(atPath path: String!) -> Bool {
        return ((path as NSString?)?.pathExtension as NSString?)?.isEqual(to: "zip") ?? false
    }

    @objc(unZipFileAtPath:)
    public func unZipFile(atPath path: String!) -> Bool {
        if ((path as NSString?)?.length ?? 0) == 0 {
            return false
        }

        do {
            try HorosObjCException.perform {
                let aTask = Process()
                var args = [String]()

                args.append("-o")
                args.append(path)
                args.append("-d")
                args.append((path as NSString).deletingLastPathComponent)
                aTask.launchPath = "/usr/bin/unzip"
                aTask.arguments = args
                aTask.launch()
                while aTask.isRunning {
                    Thread.sleep(forTimeInterval: 0.1)
                }

                //[aTask waitUntilExit];		// <- This is VERY DANGEROUS : the main runloop is continuing...
            }
        } catch {
            NSLog("***** exception in %@: %@", "-[PluginManagerController unZipFileAtPath:]", Self.formatted((error as NSError).userInfo[HorosObjCExceptionKey]))
        }

        if FileManager.default.fileExists(atPath: (path as NSString).deletingPathExtension) {
            return true
        } else {
            return false
        }
    }

    // MARK: submit plugin

    @objc(loadSubmitPluginPage)
    public func loadSubmitPluginPage() {
        // HOROS_PLUGIN_SUBMISSION_URL of url.h, which Swift cannot import.
        setHorosPluginURL(URL_HOROS_VIEWER + "/horos-content/plugins/submit.html")
    }

    @objc(sendPluginSubmission:)
    public func sendPluginSubmission(_ request: String!) {
        // -objectAtIndex: raises for a request without "?" or a parameter
        // without "=", as it did.
        let parameters = ((request as NSString?)?.components(separatedBy: "?") as NSArray?)?.object(at: 1) as? NSString
        let parametersArray = parameters?.components(separatedBy: "&") as NSArray?

        let emailMessage = NSMutableString(string: "")

        for loopItem in parametersArray ?? NSArray() {
            let param = (loopItem as? NSString)?.components(separatedBy: "=") as NSArray?
            let value = (param?.object(at: 1) as? NSString)?.replacingPercentEscapes(using: String.Encoding.utf8.rawValue)
            emailMessage.append("\(Self.formatted(param?.object(at: 0))): \(Self.formatted(value)) \n")
        }

        NSWorkspace.shared.open(URL(string: "mailto:" + URL_EMAIL)!)
    }

    // MARK: WebPolicyDelegate Protocol methods

    @objc(webView:decidePolicyForNavigationAction:request:frame:decisionListener:)
    public func webView(_ sender: WebView!, decidePolicyForNavigationAction actionInformation: [AnyHashable: Any]!, request: URLRequest!, frame: WebFrame!, decisionListener listener: WebPolicyDecisionListener!) {
        // Each navigation gets exactly one decision (#777). A web view that is
        // not one of this window's catalogs loads what it asks for, and its
        // links are not also opened in the browser: it used to fall through,
        // decide a second time and hand its clicks to NSWorkspace.
        if !(sender?.isEqual(to: osirixPluginWebView) ?? false) && !(sender?.isEqual(to: horosPluginWebView) ?? false) {
            listener?.use()
            return
        }

        let navigationType = (actionInformation?[WebActionNavigationTypeKey] as? NSNumber)?.int32Value ?? 0

        // A catalog's links open in the browser and its form goes by mail:
        // neither navigates the catalog, which was left undecided.
        if navigationType == Int32(WebNavigationType.linkClicked.rawValue) {
            if let url = request?.url {
                NSWorkspace.shared.open(url)
            }
            listener?.ignore()
        } else if navigationType == Int32(WebNavigationType.formSubmitted.rawValue) {
            sendPluginSubmission(request?.url?.absoluteString)
            listener?.ignore()
        } else {
            listener?.use()
        }
    }
}
