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

#if MACAPPSTORE
import AppKit

@MainActor @objc(PluginManagerController)
public final class PluginManagerController: NSWindowController {
    @IBOutlet @objc var filtersMenu: NSMenu?
    @IBOutlet @objc var roisMenu: NSMenu?
    @IBOutlet @objc var othersMenu: NSMenu?
    @IBOutlet @objc var dbMenu: NSMenu?
    /// No plug-ins in the App Store build: the method the other build has, so
    /// that the browser's call compiles in both.
    @objc public func plugins() -> NSMutableArray! { NSMutableArray() }
    @objc public func refreshPluginList() {}
    public override func showWindow(_ sender: Any?) {}
}
#else
import AppKit
import Synchronization

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
/// (the installed plugins, and the download and installation of the updates
/// of installed plugins).
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/PluginManagerController.h> are those of the former class.
/// MainMenu.xib creates one with -init, and
/// PluginManager.xib has it as File's Owner.
@objc(PluginManagerController)
public final class PluginManagerController: NSWindowController {

    // Outlets the xibs set: ivars of the former class.
    @IBOutlet @objc var filtersMenu: NSMenu?
    @IBOutlet @objc var roisMenu: NSMenu?
    @IBOutlet @objc var othersMenu: NSMenu?
    @IBOutlet @objc var dbMenu: NSMenu?

    @IBOutlet @objc var pluginsArrayController: NSArrayController?
    @IBOutlet @objc var pluginTable: PluginsTableView?

    @IBOutlet @objc var tabView: NSTabView?
    @IBOutlet @objc var installedPluginsTabViewItem: NSTabViewItem?

    /// The status line below the plugin list: where a plugin update reports
    /// its download and installation.
    @IBOutlet @objc var downloadStatusTextField: NSTextField?
    @IBOutlet @objc var downloadStatusProgressIndicator: NSProgressIndicator?

    @IBOutlet @objc var protectedModeLabel: NSTextField?

    /// What -plugins returns: the array PluginManager.xib's controller binds
    /// to, emptied and refilled in place by -refreshPluginList.
    private var pluginsArray = NSMutableArray()

    /// Path -> transfer. The activity thread takes a snapshot under this mutex;
    /// AppKit and installation remain on the main actor.
    private nonisolated let downloadingPlugins = Mutex<[String: PluginPackageDownload]>([:])

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

    /// A former plugin, in an earlier version's folder or in this app's own, is
    /// listed, not managed: its row's checkbox and menu are put back and nothing
    /// else happens.
    private func refusesLegacyPlugin(atRow row: Int) -> Bool {
        guard row >= 0, row < ((pluginsArrayController?.arrangedObjects as? NSArray)?.count ?? 0),
              Self.boolValue(arrangedPlugin(atRow: row)?.object(forKey: PluginManager.legacyPluginKey)) else { return false }
        NSSound.beep()
        refreshPluginList()
        return true
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? NSString { return string.boolValue }
        return false
    }

    /// What %@ printed for an object: its description, or (null).
    private static func formatted(_ value: Any?) -> String {
        guard let value = value else { return "(null)" }
        return String(describing: value as AnyObject)
    }

    @IBAction @objc(modifiyActivation:)
    public func modifiyActivation(_ sender: Any!) {
        let clickedRow = pluginTable?.clickedRow ?? 0
        if refusesLegacyPlugin(atRow: clickedRow) { return }
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
                                            otherButton: nil) == HorosAlertPanel.defaultResponse {
            let selectedRow = pluginTable?.selectedRow ?? 0
            if refusesLegacyPlugin(atRow: selectedRow) { return }
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
        if refusesLegacyPlugin(atRow: pluginTable?.clickedRow ?? 0) { return }
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
        let downloads = downloadingPlugins.withLock { downloads in
            let pending = Array(downloads.values)
            downloads.removeAll()
            return pending
        }
        for download in downloads { download.cancel() }
        downloadStatusProgressIndicator?.stopAnimation(self)
        downloadStatusProgressIndicator?.isHidden = true

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

        for case let viewer as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray() {
            viewer.window?.close()
        }

        super.showWindow(sender)

        refreshPluginList()

        protectedModeLabel?.isHidden = !DCMPix.isRunOsiriXInProtectedModeActivated()

        configurePluginLoadDetails()

        downloadStatusTextField?.isHidden = true
        downloadStatusProgressIndicator?.isHidden = true

        // If we need to remove a plugin with a custom pref pane
        for window in NSApp.windows {
            if window.windowController is PreferencesWindowController {
                window.close()
            }
        }

        self.window?.makeKeyAndOrderFront(nil)
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

    // MARK: download

    @objc(fakeThread:)
    nonisolated public func fakeThread(_ downloadedFilePath: String!) {
        guard let downloadedFilePath,
              let download = downloadingPlugins.withLock({ $0[downloadedFilePath] }) else { return }
        autoreleasepool {
            while true {
                if Thread.current.isCancelled { download.cancel() }
                let state = download.waitForProgress()
                if state.expected > 0 {
                    Thread.current.progress = CGFloat(Double(state.received) / Double(state.expected))
                }
                if state.finished { break }
            }
        }
    }

    /// Starts the download of a plugin to the temporary folder, unless the same file is
    /// already downloading.
    private func downloadPlugin(from downloadURL: String?) {
        guard let downloadURL, let components = URLComponents(string: downloadURL),
              let encodedName = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).last,
              let fileName = String(encodedName).removingPercentEncoding,
              !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
            NSLog("Invalid plugin download filename")
            return
        }
        // Query/fragment belong to the request URL, never to the local filename.
        let downloadedFilePath = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent(fileName)

        guard let url = components.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        guard downloadingPlugins.withLock({ $0[downloadedFilePath] == nil }) else {
            NSLog("---- Already downloading...")
            return
        }
        let download = PluginPackageDownload(url: url, destination: URL(fileURLWithPath: downloadedFilePath),
            progress: { [weak self] download, received, expected in
                DispatchQueue.main.async {
                    guard let self, self.downloadingPlugins.withLock({ $0[downloadedFilePath] === download }) else { return }
                    let (_, indicator) = self.statusControls(forPath: downloadedFilePath)
                    indicator?.isIndeterminate = expected <= 0
                    if expected > 0 { indicator?.doubleValue = 100 * Double(received) / Double(expected) }
                }
            }, completion: { [weak self] download, error in
                DispatchQueue.main.async {
                    guard let self else { download.cancel(); return }
                    self.finishDownload(download, atPath: downloadedFilePath, error: error)
                }
            })
        downloadingPlugins.withLock { $0[downloadedFilePath] = download }
        let (field, indicator) = statusControls(forPath: downloadedFilePath)
        field?.isHidden = false
        field?.stringValue = NSLocalizedString("Downloading...", comment: "")
        indicator?.isHidden = false
        indicator?.isIndeterminate = true
        indicator?.startAnimation(self)
        let thread = PluginDownloadActivity(onCancel: { download.cancel() }) { [weak self] in
            self?.fakeThread(downloadedFilePath)
        }
        thread.name = NSLocalizedString("Plugin download...", comment: "")
        thread.status = downloadURL
        thread.supportsCancel = true
        ThreadsManager.default().addThreadAndStart(thread)
        download.start()
    }

    /// Downloads and installs a newer version of an installed plugin, found by
    /// PluginManager's update check, and reports in the status line below the
    /// plugin list.
    @objc(downloadPluginUpdate:)
    public func downloadPluginUpdate(_ downloadURL: String!) {
        downloadPlugin(from: downloadURL)
    }

    private func statusControls(forPath path: String) -> (NSTextField?, NSProgressIndicator?) {
        return (downloadStatusTextField, downloadStatusProgressIndicator)
    }

    private func finishDownload(_ download: PluginPackageDownload, atPath path: String, error: Error?) {
        // A closed window removes its transfers before cancellation. A queued
        // success from that generation must never reach installation.
        guard downloadingPlugins.withLock({ $0[path] === download }) else { return }
        _ = downloadingPlugins.withLock { $0.removeValue(forKey: path) }
        let (field, indicator) = statusControls(forPath: path)
        indicator?.isHidden = true
        indicator?.stopAnimation(self)
        if let error = error ?? download.terminalError {
            field?.isHidden = false
            field?.stringValue = NSLocalizedString("Download failed", comment: "")
            if (error as NSError).code != NSURLErrorCancelled {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Download failed", comment: ""), message: error.localizedDescription,
                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
            return
        }
        field?.stringValue = NSLocalizedString("Plugin downloaded", comment: "")
        installDownloadedPlugin(atPath: path)
        NotificationCenter.default.post(name: .AppPluginDownloadInstallDidFinish, object: self, userInfo: nil)
    }

    // MARK: install / uinstall

    @objc(installDownloadedPluginAtPath:)
    public func installDownloadedPlugin(atPath path: String!) {
        let statusTextField = downloadStatusTextField
        let statusProgressIndicator = downloadStatusProgressIndicator

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

        // Checked before the installed copy is touched: a download that is not
        // a version 1 plugin, a former plugin among them, replaces nothing.
        if let refusal = PluginManager.pluginInstallRefusal(atPath: pluginPath) {
            statusTextField?.isHidden = true
            statusProgressIndicator?.isHidden = true
            statusProgressIndicator?.stopAnimation(self)
            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugin", comment: ""),
                                        message: String(format: NSLocalizedString("The plugin cannot be installed. The existing installation was preserved. %@", comment: ""), refusal),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

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

        // movePlugin takes the complete bundle destination, not its parent folder.
        let installedPath = pluginFileName.flatMap { (installDirectoryPath as NSString?)?.appendingPathComponent($0) }
        pluginManager.movePlugin(fromPath: pluginPath, toPath: installedPath)

        guard let installedPath,
              FileManager.default.fileExists(atPath: installedPath),
              !FileManager.default.fileExists(atPath: pluginPath ?? "") else {
            statusTextField?.stringValue = NSLocalizedString("The plugin could not be moved. Its activation or location change was not completed. Check folder permissions and try again.", comment: "")
            statusProgressIndicator?.isHidden = true
            statusProgressIndicator?.stopAnimation(self)
            return
        }

        // Load only the bundle actually installed, and never report a failed move as success.
        pluginManager.loadPlugin(atPath: installedPath)

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

}

/// The immutable Sendable callbacks can run on the activity and cancelling
/// threads. Forward cancellation even before Thread starts its main method.
/// This adapter goes away when ThreadsManager accepts an async activity.
private final class PluginDownloadActivity: Thread {
    private let onCancel: @Sendable () -> Void
    private let work: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void, work: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
        self.work = work
        super.init()
    }

    override func main() { work() }

    override func cancel() {
        super.cancel()
        onCancel()
    }
}

/// One package transfer, shared by URLSession's serial delegate queue and the
/// activity thread. Every mutable transfer field is protected by `condition`;
/// session/task are configured before publication and never replaced. This
/// synchronous delegate/activity bridge needs @unchecked Sendable until the
/// legacy ThreadsManager activity becomes an async consumer.
private final class PluginPackageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private let destination: URL
    private let progress: @Sendable (PluginPackageDownload, Int64, Int64) -> Void
    private let completion: @Sendable (PluginPackageDownload, Error?) -> Void
    private var session: URLSession!
    private var task: URLSessionDownloadTask!
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var finished = false
    private var staged = false
    private var failure: Error?

    init(url: URL, destination: URL,
         progress: @escaping @Sendable (PluginPackageDownload, Int64, Int64) -> Void,
         completion: @escaping @Sendable (PluginPackageDownload, Error?) -> Void) {
        self.destination = destination
        self.progress = progress
        self.completion = completion
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = session.downloadTask(with: url)
    }

    func start() { task.resume() }

    var terminalError: Error? {
        condition.lock()
        defer { condition.unlock() }
        return failure
    }

    func waitForProgress() -> (finished: Bool, received: Int64, expected: Int64) {
        condition.lock()
        defer { condition.unlock() }
        if !finished { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1)) }
        return (finished, received, expected)
    }

    func cancel() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        condition.lock()
        failure = error
        let notify = !finished
        finished = true
        if staged { try? FileManager.default.removeItem(at: destination); staged = false }
        condition.broadcast()
        condition.unlock()
        session.invalidateAndCancel()
        if notify { completion(self, error) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        condition.lock()
        guard !finished else { condition.unlock(); return }
        received = totalBytesWritten
        expected = totalBytesExpectedToWrite
        condition.signal()
        condition.unlock()
        progress(self, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), response.statusCode != 206 else {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)"])
            }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            // Content-Length describes the encoded representation. Foundation
            // may decompress it, so compare only when no encoding is applied.
            if size == 0 || (response.value(forHTTPHeaderField: "Content-Encoding") == nil &&
                            response.expectedContentLength >= 0 && size != response.expectedContentLength) {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)
            }
            // Test the central directory AND every member CRC before allowing
            // extraction. A complete HTTP body may still be a truncated ZIP.
            let validation = Process()
            validation.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            validation.arguments = ["-tq", location.path]
            validation.standardOutput = FileHandle.nullDevice
            validation.standardError = FileHandle.nullDevice
            try validation.run()
            validation.waitUntilExit()
            guard validation.terminationStatus == 0 else {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)
            }
            condition.lock()
            defer { condition.unlock() }
            guard !finished else { return }
            // URLSession deletes its temporary file after this callback. Move
            // only the fully validated package to the existing destination.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            staged = true
        } catch {
            condition.lock()
            if !finished { failure = error }
            condition.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        guard !finished else { condition.unlock(); return }
        failure = error ?? failure
        if failure == nil && !staged { failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotCreateFile) }
        if failure != nil && staged { try? FileManager.default.removeItem(at: destination); staged = false }
        finished = true
        let result = failure
        condition.broadcast()
        condition.unlock()
        session.finishTasksAndInvalidate()
        completion(self, result)
    }
}

#endif
