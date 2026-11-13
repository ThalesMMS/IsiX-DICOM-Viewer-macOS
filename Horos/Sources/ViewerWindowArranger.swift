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
import IsiXImaging
import IsiXPreferences

/// The arrangement of the viewers' windows on the screens: the screens the
/// viewers use, the series list panel of each screen, the tiling of the 2D
/// and 3D viewers (`ViewerTilingLayout` chooses the grid, this moves the
/// windows), the tiling menus and the tiling put off for a moment while
/// viewers open and close.
///
/// The application controller makes it and forwards to it the selectors the
/// nibs and plugins send.
@MainActor
final class ViewerWindowArranger: NSObject {

    typealias Request = ViewerTilingLayout.Request

    /// One series list panel per screen, at most this many screens.
    static let maximumScreens = 10

    /// AppKit's own key: windows move with an animation.
    private static let animatesWindowFrames = PreferenceKey<Bool>("NSWindowsSetFrameAnimate")
    /// Two keys no pane writes, which a user sets by hand: the database's
    /// screen goes last when there are fewer viewers than screens, and the
    /// order by study date starts from the earliest study.
    private static let usesDatabaseScreenLast = PreferenceKey<Bool>("UseDBScreenAtLast")
    private static let reversesStudyDateOrder = PreferenceKey<Bool>("reversedTileWindowsOrderByStudyDate")

    private let processGraph: ProcessGraph

    /// The database window, whose screen the viewers can leave to it: the
    /// nib gives it to the application controller after this object is made.
    var databaseWindow: @MainActor () -> NSWindow? = { nil }

    /// The grid the last tiling chose.
    private(set) var layout = ViewerTilingLayout()

    /// A tiling put off for a moment is waiting.
    private(set) var isTilingScheduled = false

    /// The tilings put off, each with the grid it asks for.
    private var scheduledTilings: [(timer: Timer, request: Request?)] = []

    /// The screens as the last change of the screen parameters left them, and
    /// their order, which gives each series list panel its screen.
    private var previousScreenParameters: [ScreenParameters]? = nil
    private var previousScreenOrder: [UInt32]? = nil

    /// Made by the process graph, the one arrangement of the process.
    nonisolated init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
        super.init()
    }

    // MARK: - Screens

    /// A screen as the screen parameters compare it.
    private struct ScreenParameters: Equatable {
        let identifier: UInt32
        let frame: NSRect
        let visibleFrame: NSRect
    }

    /// The screens changed: the series list panels follow their screen, and
    /// the browser brings back the windows left off screen. A transient list
    /// (no screen, or an empty frame) is ignored until the final one.
    func updateScreenParameters() {
        let screens = NSScreen.screens
        if screens.isEmpty {
            NSLog("updateScreenParameters: ignoring transient empty display list")
            return
        }
        var parameters: [ScreenParameters] = []
        for screen in screens {
            // During a display reconfiguration AppKit can transiently report a 0x0 screen. Rescaling or
            // closing windows from such a snapshot corrupts window frames; wait for the final notification.
            if NSIsEmptyRect(screen.frame) || !screen.frame.origin.x.isFinite || !screen.frame.origin.y.isFinite || !screen.frame.size.width.isFinite || !screen.frame.size.height.isFinite {
                NSLog("updateScreenParameters: ignoring transient empty screen frame")
                return
            }

            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            parameters.append(ScreenParameters(identifier: number?.uint32Value ?? 0, frame: screen.frame, visibleFrame: screen.visibleFrame))
        }

        // NSScreen order can change when focus/main screen changes. Compare by the
        // stable display identifier so reordering cannot close open studies/ROIs.
        let order = parameters.map(\.identifier)
        let sorted = ViewerTilingLayout.mergeSorted(Array(parameters.indices)) { first, second in
            let a = parameters[first].identifier, b = parameters[second].identifier
            return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }.map { parameters[$0] }

        let geometryChanged = sorted != previousScreenParameters
        let panelMappingChanged = order != previousScreenOrder
        if !geometryChanged && !panelMappingChanged { return }

        // Publish before moving any windows: AppKit can synchronously send another
        // screen notification while the new layout is being applied.
        previousScreenParameters = sorted
        previousScreenOrder = order
        if panelMappingChanged { resetThumbnailsLists() }
        processGraph.currentBrowser?.recoverWindowsAfterScreenChange()
    }

    /// A series list panel for each screen, and one more in case a screen is
    /// connected while the application runs.
    func resetThumbnailsLists() {
        let numberOfScreens = min(Self.maximumScreens, NSScreen.screens.count + 1)

        prepareThumbnailsListsForScreenReconfiguration()
        for i in 0..<Self.maximumScreens {
            AppControllerCAPISetThumbnailsListPanel(i, nil)
        }

        for i in 0..<numberOfScreens {
            AppControllerCAPISetThumbnailsListPanel(i, ThumbnailsListPanel(forScreen: i))
        }
    }

    /// Every series list panel gives back the list it borrowed.
    func prepareThumbnailsListsForScreenReconfiguration() {
        for i in 0..<Self.maximumScreens {
            AppControllerCAPIThumbnailsListPanel(i)?.prepareForScreenReconfiguration()
        }
    }

    /// The series list panel of `screen`; nil for a screen not in the list,
    /// or beyond the panels.
    static func thumbnailsListPanel(for screen: NSScreen?) -> ThumbnailsListPanel? {
        guard let screen, let i = NSScreen.screens.firstIndex(where: { $0 === screen }), i < maximumScreens else { return nil }
        return AppControllerCAPIThumbnailsListPanel(i)
    }

    /// Moves `window` to `frame`, with an animation when the system asks for
    /// one; during a tiling the animations are gathered and run together.
    static func resizeWindow(withAnimation window: NSWindow?, newSize frame: NSRect) {
        guard PreferencesSource.process.preferences[animatesWindowFrames] else {
            window?.setFrame(frame, display: true)
            return
        }
        guard let window else { return }
        let resize: [NSViewAnimation.Key: Any] = [.target: window, .endFrame: NSValue(rect: frame)]

        if accumulateAnimations.boolValue {
            if accumulateAnimationsArray == nil { accumulateAnimationsArray = [] }
            accumulateAnimationsArray.add(resize)
        } else {
            OSIWindowController.setDontEnterWindowDidChangeScreen(true)

            let animation = NSViewAnimation(viewAnimations: [resize])
            animation.animationBlockingMode = .blocking
            animation.duration = 0.15
            animation.start()

            OSIWindowController.setDontEnterWindowDidChangeScreen(false)
        }
    }

    /// The area of `screen` the windows are tiled in: its tiling area, and
    /// without the floating panels (toolbar, series list, 4D navigator) when
    /// `showFloatingWindows`.
    static func usefulRect(for screen: NSScreen?, showFloatingWindows: Bool) -> NSRect {
        // The area this screen is allowed to hold the windows, which is the whole
        // visible frame unless somebody reserved part of it for something else.
        // Narrowing first means the floating panels are taken out of the chosen
        // area, not out of the screen.
        var screenFrame = TilingArea.rect(for: screen, visibleFrame: screen?.visibleFrame ?? .zero)

        if showFloatingWindows {
            let preferences = PreferencesSource.process.preferences
            if AppController.usetoolbarpanel() || preferences[ViewerPreferences.alwaysUsesToolbarPanel] {
                // 78 was 100 minus a 22-point menu bar, frozen in place. Both halves
                // move - the toolbar needs more than 100 now, and the menu bar is
                // not 22 - so the room the tiling leaves has to come from the panel
                // itself, or the windows are laid over the bottom of its labels.
                screenFrame.size.height -= CGFloat(ToolbarPanelController.exposedHeight())
            }

            if preferences[ViewerPreferences.useFloatingThumbnailsList] && preferences[ViewerPreferences.seriesListVisible] {
                screenFrame.origin.x += CGFloat(ThumbnailsListPanel.fixedWidth())
                screenFrame.size.width -= CGFloat(ThumbnailsListPanel.fixedWidth())
            }

            screenFrame = NavigatorView.adjustIfScreenAreaIf4DNavigator(screenFrame)
        }

        return screenFrame
    }

    /// The database window's screen, when a screen is reserved for it.
    func databaseScreen() -> NSScreen? {
        processGraph.preferences[ViewerPreferences.reserveScreenForDB] ? databaseWindow()?.screen : nil
    }

    /// The screens the viewers use, from left to right: those chosen in the
    /// preferences, or all, without the database's screen when it is
    /// reserved and another one is left.
    func viewerScreens() -> [NSScreen] {
        var screens = (processGraph.preferences.screensUsedForViewers() as? [NSScreen]) ?? []
        if screens.isEmpty {
            screens = NSScreen.screens
        }

        if processGraph.preferences[ViewerPreferences.reserveScreenForDB], let databaseScreen = databaseWindow()?.screen,
           screens.contains(where: { $0 === databaseScreen }) && screens.count > 1 {
            screens.removeAll { $0 === databaseScreen }
        }

        if screens.isEmpty {
            screens = NSScreen.screens
        }

        // Left to right, by their centres.
        let centres = screens.map { $0.frame.origin.x + $0.frame.size.width / 2 }
        return ViewerTilingLayout.mergeSorted(Array(screens.indices)) { first, second in
            centres[first] < centres[second] ? .orderedAscending : centres[first] > centres[second] ? .orderedDescending : .orderedSame
        }.map { screens[$0] }
    }

    /// All the screens, from the lowest and leftmost.
    static func orderedScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        return ViewerTilingLayout.orderedScreens(visibleFrames: screens.map(\.visibleFrame)).map { screens[$0] }
    }

    // MARK: - Viewers

    /// The window controller of the nib `nibName` that shows `pixList` (the
    /// same array), unless its window is closing: a request made while it
    /// closes opens a new viewer.
    func findViewer(nibName: String?, pixList: AnyObject?) -> NSWindowController? {
        for window in NSApp.windows {
            guard let controller = window.windowController, let name = controller.windowNibName, let nibName, name == nibName else { continue }
            if ViewerMessages.object(controller, "pixList") === pixList && !Self.windowWillClose(controller) {
                return controller
            }
        }
        return nil
    }

    /// [controller windowWillClose], for the controllers that answer it
    /// (OSIWindowController and its subclasses); NO for the others.
    private static func windowWillClose(_ controller: NSWindowController) -> Bool {
        guard controller.responds(to: NSSelectorFromString("windowWillClose")) else { return false }
        return ViewerMessages.bool(controller, "windowWillClose")
    }

    /// The window controllers that show `pixList` (the same array).
    func findRelatedViewers(pixList: AnyObject?) -> [NSWindowController] {
        var related: [NSWindowController] = []
        for window in NSApp.windows {
            guard let controller = window.windowController, controller.responds(to: NSSelectorFromString("pixList")) else { continue }
            if ViewerMessages.object(controller, "pixList") === pixList {
                related.append(controller)
            }
        }
        return related
    }

    /// Brings the 2D viewers to the front, the last one key when `makeKey`.
    func bringViewersToFront(makeKey: Bool) {
        var last: NSWindow? = nil

        for window in NSApp.windows {
            if let viewer = window.windowController as? ViewerController, !viewer.windowWillClose() {
                last = window
                window.orderFront(self)
                viewer.checkBuiltMatrixPreview()
            }
        }

        if makeKey {
            last?.makeKeyAndOrderFront(self)

            if processGraph.preferences[DatabasePreferences.syncPreviewList] {
                ViewerMessages.send(last?.windowController, "syncThumbnails")
            }
        }
    }

    /// Closes the viewers, unless a window is in full screen.
    func closeAllViewers() {
        for window in NSApp.orderedWindows where window is NSFullScreenWindow {
            NSSound.beep()
            return
        }

        ViewerController.closeAllWindows()
    }

    // MARK: - Tiling menus

    /// The Rows and Columns menus send their choice to `target`, and the
    /// Screen Area menu goes beside them.
    func installTilingMenus(rows: NSMenu?, columns: NSMenu?, target: AnyObject) {
        for item in rows?.items ?? [] {
            item.target = target
            item.action = #selector(AppController.setFixedTilingRows(_:))
        }

        for item in columns?.items ?? [] {
            item.target = target
            item.action = #selector(AppController.setFixedTilingColumns(_:))
        }

        buildTilingAreaMenu(beside: rows, target: target)
    }

    // Built here rather than in a nib: there is one nib per language, and this is a
    // list that belongs to TilingArea. It goes next to the Rows and Columns
    // submenus, because it answers the question they raise - how much of the screen.
    private func buildTilingAreaMenu(beside rows: NSMenu?, target: AnyObject) {
        guard let rows, let parent = rows.supermenu else { return }
        let at = parent.indexOfItem(withSubmenu: rows)
        guard at >= 0 else { return }

        let title = NSLocalizedString("Screen Area", comment: "")
        if parent.indexOfItem(withTitle: title) >= 0 { return }      // built already

        let areaItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let areaMenu = NSMenu(title: title)
        areaMenu.autoenablesItems = false

        for name in TilingArea.presetNames {
            let item = NSMenuItem(title: NSLocalizedString(name, comment: ""),
                                  action: #selector(AppController.setTilingArea(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = name
            areaMenu.addItem(item)
        }

        areaItem.submenu = areaMenu
        parent.insertItem(areaItem, at: at + 1)
    }

    /// The Screen Area menu: the area of the key window's screen (or the main
    /// screen) the windows are tiled in is now the preset `presetName`.
    func setTilingArea(presetNamed presetName: String?) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main

        // A nil name is read as an empty one.
        TilingArea.set(fractions: TilingArea.fractions(presetNamed: presetName ?? ""), for: screen)

        NSLog("Tiling area on \"%@\" is now %@; %@",
              TilingArea.identifier(for: screen) as NSString, (presetName ?? "(null)") as NSString,
              NSStringFromRect(Self.usefulRect(for: screen, showFloatingWindows: true)) as NSString)

        // The floating panels place themselves from the screen parameters, and each
        // viewer has its own: without this only the front one would move, and the
        // others would stay across the part that was just reserved.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        tileWindows(nil)
    }

    // MARK: - Tiling

    /// The grid a sender of -tileWindows: asks for: a dictionary with "rows"
    /// or "columns" (the tiling menus), or "Rows" and "Columns" (a hanging
    /// protocol). Any other sender asks for none.
    static func request(from sender: Any?) -> Request? {
        guard let dictionary = sender as? [AnyHashable: Any] else { return nil }
        // [value intValue]: a number or a string; 0 for anything else.
        func number(_ key: String) -> Int32? {
            guard let value = dictionary[key] else { return nil }
            if let number = value as? NSNumber { return number.int32Value }
            if let string = value as? NSString { return string.intValue }
            return 0
        }
        return Request(rows: number("rows"), columns: number("columns"), protocolRows: number("Rows"), protocolColumns: number("Columns"))
    }

    /// -tileWindows: and -tile3DWindows:, for the grid their sender asks for.
    func tileWindows(sender: Any?) {
        tileWindows(Self.request(from: sender))
    }

    func tile3DWindows(sender: Any?) {
        tile3DWindows(Self.request(from: sender))
    }

    /// The Rows and Columns menus: the number of rows, or of columns, is
    /// fixed (the item's tag), and the other one grows.
    func tileWindows(fixedRows rows: Int) {
        tileWindows(Request(rows: Int32(truncatingIfNeeded: rows)))
    }

    func tileWindows(fixedColumns columns: Int) {
        tileWindows(Request(columns: Int32(truncatingIfNeeded: columns)))
    }

    /// Tiles the magnetic viewers' windows (the 2D viewers), unless one is in
    /// full screen.
    func tileWindows(_ request: Request?) {
        var controllers: [NSWindowController] = []

        for window in NSApp.orderedWindows {
            if let controller = window.windowController as? OSIWindowController, controller.magnetic() {
                if !ViewerMessages.bool(controller, "windowWillClose") && !window.isMiniaturized {
                    controllers.append(controller)
                }

                if ViewerMessages.bool(controllers.last, "FullScreenON") {
                    return
                }
            }

            window.animationBehavior = .none
        }

        tile(request, controllers: controllers, display2DViewerToolbar: AppController.usetoolbarpanel())

        processGraph.currentBrowser?.closeWaitWindowIfNecessary()
    }

    /// Tiles the visible 3D viewers' windows, unless one is in full screen,
    /// and brings them to the front.
    func tile3DWindows(_ request: Request?) {
        var controllers: [NSWindowController] = []

        for window in NSApp.orderedWindows {
            if let controller = window.windowController as? Window3DController {
                if !controller.windowWillClose() && !window.isMiniaturized && window.isVisible {
                    controllers.append(controller)
                }

                if ViewerMessages.bool(controllers.last, "FullScreenON") {
                    return
                }
            }
        }

        tile(request, controllers: controllers, display2DViewerToolbar: false)

        for controller in controllers {
            controller.window?.makeKeyAndOrderFront(self)
        }
    }

    /// Moves `controllers`' windows to the frames `ViewerTilingLayout` chooses,
    /// then makes the right one key and rebuilds the series lists.
    ///
    /// The windows that move do not copy their settings to one another:
    /// "COPYSETTINGS" is off for this process while they are placed
    /// (TemporaryPreferenceWork), the application not being told of it.
    private func tile(_ request: Request?, controllers: [NSWindowController], display2DViewerToolbar: Bool) {
        isTilingScheduled = false

        var placed: ViewerTilingLayout.Arrangement?
        TemporaryPreferenceWork.during(ViewerPreferences.copySettings, at: false, silently: true) {
            placed = place(request, controllers: controllers, display2DViewerToolbar: display2DViewerToolbar)
        }
        guard let arrangement = placed else { return }
        let preferences = processGraph.preferences

        for i in 0..<NSScreen.screens.count {
            AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(nil, viewer: nil)
        }

        let tiled = arrangement.order.map { controllers[$0] }
        let hidden = arrangement.hidden.map { controllers[$0] }
        let key: NSWindowController? = arrangement.keyViewer.map { controllers[$0] } ?? (ViewerController.frontMostDisplayed2DViewer(for: nil) as NSWindowController?)

        guard !tiled.isEmpty, let key else { return }
        DCMView.setDontListenToSyncMessage(true)

        key.window?.makeKeyAndOrderFront(self)
        ViewerMessages.send(key, "propagateSettings")

        for case let viewer as ViewerController in tiled.reversed() where viewer !== key {
            viewer.buildMatrixPreview(hidden.contains { $0 === viewer })
        }

        ToolbarPanelController.checkForValidToolbar()

        if let keyViewer = key as? ViewerController {
            keyViewer.imageView()?.becomeMainWindow()
            keyViewer.buildMatrixPreview(true)

            keyViewer.redrawToolbar()
        }

        if preferences[DatabasePreferences.syncPreviewList] {
            ViewerMessages.send(key, "syncThumbnails")
        }

        DCMView.setDontListenToSyncMessage(false)
    }

    /// The frames `ViewerTilingLayout` chooses, with `controllers`' windows moved to them.
    private func place(_ request: Request?, controllers: [NSWindowController], display2DViewerToolbar: Bool) -> ViewerTilingLayout.Arrangement {
        let preferences = processGraph.preferences

        var screens = viewerScreens()
        if controllers.count < screens.count && preferences[Self.usesDatabaseScreenLast], let databaseScreen = databaseWindow()?.screen {
            screens.removeAll { $0 === databaseScreen }
        }
        if screens.isEmpty {
            screens = viewerScreens()
        }

        let windowLayout = WindowLayoutManager.shared()
        let options = ViewerTilingLayout.Options(rows: windowLayout?.windowsRows() ?? 0, columns: windowLayout?.windowsColumns() ?? 0,
                                                 hasHangingProtocol: windowLayout?.currentHangingProtocol != nil,
                                                 keepsStudiesOnSameScreen: preferences[ViewerPreferences.keepStudiesTogetherOnSameScreen],
                                                 stretchesWindows: preferences[ViewerPreferences.strechWindows],
                                                 ordersByStudyDate: preferences[ViewerPreferences.tileWindowsOrderByStudyDate],
                                                 reversesStudyDateOrder: preferences[Self.reversesStudyDateOrder])
        let ordered = Self.orderedScreens()
        let viewers = controllers.map { controller in
            Self.describe(controller, orderedScreens: ordered, tilingScreens: screens,
                          study: options.keepsStudiesOnSameScreen, date: options.ordersByStudyDate)
        }
        let tilingScreens = screens.map { screen in
            ViewerTilingLayout.Screen(visibleFrame: screen.visibleFrame,
                                      gridRect: Self.usefulRect(for: screen, showFloatingWindows: true),
                                      rowRect: Self.usefulRect(for: screen, showFloatingWindows: display2DViewerToolbar))
        }

        let arrangement = layout.arrange(viewers, on: tilingScreens, request: request, options: options)

        accumulateAnimations = true
        for placement in arrangement.placements {
            ViewerMessages.setWindowFrame(controllers[placement.viewer], placement.frame)
        }
        if arrangement.fitsNoGrid {
            NSLog("NO tiling")
        }

        preferences.set(layout.lastRowsColumns(viewerScreens: viewerScreens().count), for: ViewerPreferences.lastWindowsTilingRowsColumns)

        accumulateAnimations = false
        if let animations = accumulateAnimationsArray as? [[NSViewAnimation.Key: Any]], !animations.isEmpty {
            OSIWindowController.setDontEnterMagneticFunctions(true)
            OSIWindowController.setDontEnterWindowDidChangeScreen(true)

            let animation = NSViewAnimation(viewAnimations: animations)
            animation.animationBlockingMode = .blocking
            animation.duration = animations.count == 1 ? 0.20 : 0.40
            animation.start()

            accumulateAnimationsArray = nil

            OSIWindowController.setDontEnterMagneticFunctions(false)
            OSIWindowController.setDontEnterWindowDidChangeScreen(false)
        }
        return arrangement
    }

    /// A viewer as `ViewerTilingLayout` sees it; its study and the study's
    /// date only when the tiling reads them.
    private static func describe(_ controller: NSWindowController, orderedScreens: [NSScreen], tilingScreens: [NSScreen],
                                 study: Bool, date: Bool) -> ViewerTilingLayout.Viewer {
        let window = controller.window
        let screen = window?.screen
        var studyInstanceUID: String? = nil
        if study, let files = ViewerMessages.object(controller, "fileList") as? [Any], let image = files.first as? DicomImage {
            studyInstanceUID = image.series?.study?.studyInstanceUID
        }
        let studyDate: Date? = date ? (controller as? OSIWindowController)?.currentStudy()?.date : nil
        return ViewerTilingLayout.Viewer(frame: window?.frame ?? .zero, isVisible: window?.isVisible ?? false,
                                         isKey: window?.isKeyWindow ?? false,
                                         orderedScreenIndex: screen.flatMap { screen in orderedScreens.firstIndex { $0 === screen } },
                                         screenVisibleOriginY: screen?.visibleFrame.origin.y ?? 0,
                                         tilingScreenIndex: screen.flatMap { screen in tilingScreens.firstIndex { $0 === screen } },
                                         studyInstanceUID: studyInstanceUID, studyDate: studyDate)
    }

    // MARK: - Tiling put off

    /// Tiles the windows after `delay` (seconds), with the grid `request`
    /// asks for. A tiling already put off without a grid is dropped first.
    func scheduleTiling(_ request: Request? = nil, after delay: TimeInterval) {
        if isTilingScheduled {
            dropScheduledTilingsWithoutGrid()
        }
        isTilingScheduled = true

        // The run loop's default mode, where -performSelector:afterDelay: put it.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            let fired = ObjectIdentifier(timer)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduledTilings.removeAll { ObjectIdentifier($0.timer) == fired }
                self.tileWindows(request)
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        scheduledTilings.append((timer, request))
    }

    /// Drops the tiling put off, if one is waiting.
    func cancelScheduledTiling() {
        guard isTilingScheduled else { return }
        isTilingScheduled = false
        dropScheduledTilingsWithoutGrid()
    }

    /// Tiles now if a tiling was put off.
    func tileNowIfScheduled() {
        guard isTilingScheduled else { return }
        cancelScheduledTiling()
        tileWindows(nil)
    }

    /// Tiles now, in place of any tiling put off.
    func tileNow() {
        cancelScheduledTiling()
        tileWindows(nil)
    }

    // The tilings were put off with -performSelector:withObject:afterDelay:
    // and dropped with -cancelPreviousPerformRequestsWithTarget:selector:object:
    // given nil, which drops only the requests made with nil: a grid the
    // tiling menu asked for still came. The same requests are dropped here.
    private func dropScheduledTilingsWithoutGrid() {
        for scheduled in scheduledTilings where scheduled.request == nil {
            scheduled.timer.invalidate()
        }
        scheduledTilings.removeAll { $0.request == nil }
    }
}

/// The messages the arrangement sends a window controller whatever its class:
/// OSIWindowController answers some of them only at run time, with defaults
/// its subclasses replace. A nil receiver answers NO or nil, and a receiver
/// that does not answer raises the same exception as before.
private enum ViewerMessages {
    static func bool(_ target: AnyObject?, _ name: String) -> Bool {
        guard let object = target as? NSObject else { return false }
        typealias Imp = @convention(c) (AnyObject, Selector) -> ObjCBool
        let selector = NSSelectorFromString(name)
        return unsafeBitCast(object.method(for: selector), to: Imp.self)(object, selector).boolValue
    }

    static func send(_ target: AnyObject?, _ name: String) {
        guard let object = target as? NSObject else { return }
        typealias Imp = @convention(c) (AnyObject, Selector) -> Void
        let selector = NSSelectorFromString(name)
        unsafeBitCast(object.method(for: selector), to: Imp.self)(object, selector)
    }

    static func object(_ target: AnyObject?, _ name: String) -> AnyObject? {
        guard let object = target as? NSObject else { return nil }
        return object.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }

    /// [target setWindowFrame: frame showWindow: YES animate: YES]
    static func setWindowFrame(_ target: AnyObject?, _ frame: NSRect) {
        guard let object = target as? NSObject else { return }
        typealias Imp = @convention(c) (AnyObject, Selector, NSRect, ObjCBool, ObjCBool) -> Void
        let selector = NSSelectorFromString("setWindowFrame:showWindow:animate:")
        unsafeBitCast(object.method(for: selector), to: Imp.self)(object, selector, frame, true, true)
    }
}
