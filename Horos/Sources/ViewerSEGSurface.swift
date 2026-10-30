//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Cocoa

extension ViewerController {
    /// The SEG Surfaces panel of the viewer's volume, made on the first request.
    @IBAction @objc(showSEGSurfaces:)
    func showSEGSurfaces(_ sender: Any?) {
        guard let volume = horosVolumeSession(), !volume.isStale else { return }
        var controller = objc_getAssociatedObject(self, &SEGSurfaceController.controllerKey) as? SEGSurfaceController
        if let existing = controller, !existing.uses(volume) {
            existing.sourceClosed(nil)
            controller = nil
        }
        if controller == nil {
            let made = SEGSurfaceController(viewer: self, volume: volume)
            objc_setAssociatedObject(self, &SEGSurfaceController.controllerKey, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            controller = made
        }
        controller?.showWindow(sender)
        controller?.window?.makeKeyAndOrderFront(sender)
    }
}

/// The SEG Surfaces panel of a viewer: the segments of the SEG objects
/// imported for the viewer's volume, their names, colours, opacities and
/// visibility, undo and export. Each segment's mesh is shown in the panel's
/// own 3D view, in the viewer's volume rendering windows (in patient
/// coordinates scaled by each view's volume factor), and, cut by the slice,
/// over the viewer's 2D views. The meshes are VTK actors of the adapter.
@objc(HorosSEGSurfaceController)
final class SEGSurfaceController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    nonisolated(unsafe) static var sessionKey: UInt8 = 0
    nonisolated(unsafe) static var controllerKey: UInt8 = 0

    /// The owner, cleared by its close notification.
    private weak var viewer: ViewerController?
    private let volume: VolumeSession
    /// The session of the volume, kept by the volume for the next panel.
    @objc private(set) var session: SEGViewerSession
    private let table: NSTableView
    private let nameField: NSTextField
    private let colorWell: NSColorWell
    private let opacitySlider: NSSlider
    private var visibleButton: NSButton!
    private let surfaceView: ROIVolumeView
    private var cameraInitialized = false
    /// The panel's actors and those added to the volume rendering views.
    private var actors: [IsiXVTKActor] = []
    /// The volume rendering views' renderers holding some of `actors`.
    private var externalScenes: [IsiXVTKScene] = []
    /// The panel's actor of each segment, whose mesh the 2D views cut.
    private var meshes: [UInt16: IsiXVTKActor] = [:]

    init(viewer: ViewerController, volume: VolumeSession) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.viewer = viewer
        self.volume = volume
        if let existing = objc_getAssociatedObject(volume, &SEGSurfaceController.sessionKey) as? SEGViewerSession {
            session = existing
        } else {
            var references: [SEGSourceFrame] = []
            for case let image as DicomImage in viewer.fileList() ?? [] {
                let count = image.numberOfFrames?.intValue ?? 0
                if let frame = SEGSourceFrame(sopInstanceUID: image.sopInstanceUID() ?? "",
                                              frameNumber: count > 1 ? (image.frameID?.intValue ?? 0) + 1 : 1,
                                              frameCount: count) {
                    references.append(frame)
                }
            }
            session = SEGViewerSession(volume: volume, sourceFrames: references)
            objc_setAssociatedObject(volume, &SEGSurfaceController.sessionKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        table = NSTableView(frame: .zero)
        nameField = NSTextField(frame: NSRect(x: 10, y: 200, width: 255, height: 26))
        colorWell = NSColorWell(frame: NSRect(x: 10, y: 157, width: 55, height: 30))
        opacitySlider = NSSlider(frame: NSRect(x: 10, y: 123, width: 255, height: 24))
        surfaceView = ROIVolumeView(frame: NSRect(x: 280, y: 60, width: 760, height: 590))
        super.init(window: window)

        window.title = NSLocalizedString("SEG Surfaces", comment: "")
        window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        surfaceView.autoresizingMask = [.width, .height]
        content.addSubview(surfaceView)
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 235, width: 255, height: 405))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.height]
        table.frame = scroll.bounds
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        column.title = NSLocalizedString("Segments", comment: "")
        column.width = 235
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        scroll.documentView = table
        content.addSubview(scroll)
        nameField.target = self
        nameField.action = #selector(rename(_:))
        content.addSubview(nameField)
        colorWell.target = self
        colorWell.action = #selector(recolor(_:))
        content.addSubview(colorWell)
        visibleButton = button(NSLocalizedString("Visible", comment: ""), #selector(visibility(_:)), NSRect(x: 75, y: 157, width: 180, height: 30), content)
        visibleButton.setButtonType(.switch)
        opacitySlider.minValue = 0
        opacitySlider.maxValue = 1
        opacitySlider.doubleValue = 1
        opacitySlider.target = self
        opacitySlider.action = #selector(opacity(_:))
        opacitySlider.isContinuous = false
        opacitySlider.setAccessibilityLabel(NSLocalizedString("Surface opacity", comment: ""))
        content.addSubview(opacitySlider)
        button(NSLocalizedString("Duplicate", comment: ""), #selector(duplicate(_:)), NSRect(x: 10, y: 84, width: 120, height: 30), content)
        button(NSLocalizedString("Delete", comment: ""), #selector(remove(_:)), NSRect(x: 140, y: 84, width: 120, height: 30), content)
        button(NSLocalizedString("Undo", comment: ""), #selector(undo(_:)), NSRect(x: 10, y: 45, width: 120, height: 30), content)
        button(NSLocalizedString("Redo", comment: ""), #selector(redo(_:)), NSRect(x: 140, y: 45, width: 120, height: 30), content)
        button(NSLocalizedString("Import SEG...", comment: ""), #selector(importSEG(_:)), NSRect(x: 280, y: 12, width: 150, height: 32), content)
        button(NSLocalizedString("Export Derived SEG...", comment: ""), #selector(exportSEG(_:)), NSRect(x: 435, y: 12, width: 210, height: 32), content)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed(_:)), name: Notification.Name(SEGViewerSession.changedNotification), object: session)
        nc.addObserver(self, selector: #selector(drawOverlay(_:)), name: .HorosDrawObjectsCanvas, object: nil)
        nc.addObserver(self, selector: #selector(sourceClosed(_:)), name: .OsirixCloseViewer, object: viewer)
        nc.addObserver(self, selector: #selector(sourceClosed(_:)), name: .OsirixViewerWillChange, object: viewer)
        nc.addObserver(self, selector: #selector(sourceVolumeChanged(_:)), name: .OsirixUpdateVolumeData, object: nil)
        nc.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowChanged(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        changed(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("The SEG Surfaces panel is made by its viewer")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        detachActors()
        surfaceView.prepareForRelease()
    }

    @discardableResult
    private func button(_ title: String, _ action: Selector, _ frame: NSRect, _ parent: NSView) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        parent.addSubview(button)
        return button
    }

    /// Whether the panel shows `volume`, still current.
    @objc(usesVolume:)
    func uses(_ other: VolumeSession) -> Bool { other === volume && session.isCurrent }

    @objc(sourceClosed:)
    func sourceClosed(_ note: Notification?) {
        guard let viewer else { return }
        withExtendedLifetime(self) {
            session.close()
            detachActors()
            window?.close()
            // Also release the view's bindings when the panel was already closed.
            surfaceView.prepareForRelease()
            objc_setAssociatedObject(volume, &SEGSurfaceController.sessionKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(viewer, &SEGSurfaceController.controllerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            self.viewer = nil
        }
    }

    @objc(sourceVolumeChanged:)
    func sourceVolumeChanged(_ note: Notification?) {
        if !Thread.isMainThread {
            performSelector(onMainThread: #selector(sourceVolumeChanged(_:)), with: note, waitUntilDone: false)
            return
        }
        if let viewer, (note?.object as AnyObject?) === viewer.pixList() { sourceClosed(note) }
    }

    @objc(windowWillClose:)
    func windowWillClose(_ note: Notification) {
        if (note.object as AnyObject?) === window {
            // ROIVolumeView removes its own close observer on the first close.
            // This panel is reusable: every close lets the view go.
            surfaceView.prepareForRelease()
        } else {
            let controller = (note.object as? NSWindow)?.windowController
            guard let controller, controller.isKind(of: VRController.self), ownsWindowController(controller),
                  let closing = IsiXVTKScene(borrowingRendererOf: (controller as! Window3DController).view() as AnyObject) else { return }
            for actor in actors { closing.removeActor(actor) }
            externalScenes.removeAll { $0.rendererIdentity == closing.rendererIdentity }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("SEG Surfaces", comment: "")
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
    }

    @objc(importSEG:)
    func importSEG(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            let diagnosis: String?
            do {
                let data = try NSData(contentsOf: url, options: .mappedIfSafe)
                diagnosis = session.load(data as Data)
            } catch {
                diagnosis = error.localizedDescription
            }
            if let diagnosis {
                showError(diagnosis)
            } else {
                surfaceView.surfaceScene.resetCamera()
                surfaceView.needsDisplay = true
            }
        }
    }

    @objc(exportSEG:)
    func exportSEG(_ sender: Any?) {
        let data: Data
        do {
            data = try session.exportDerived()
        } catch {
            showError(error.localizedDescription)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Derived-SEG.dcm"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private var selected: SEGViewerSurface? {
        let row = table.selectedRow
        return row >= 0 && row < session.snapshots.count ? session.snapshots[row] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { session.snapshots.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let surface = session.snapshots[row]
        return String(format: "%@ (%.3f cm³)", surface.label, surface.mesh.maskVolumeCm3)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func updateSelection() {
        let surface = selected
        nameField.stringValue = surface?.label ?? ""
        colorWell.color = NSColor(srgbRed: CGFloat(surface?.red ?? 0), green: CGFloat(surface?.green ?? 0),
                                  blue: CGFloat(surface?.blue ?? 0), alpha: 1)
        visibleButton.state = surface?.visible == true ? .on : .off
        opacitySlider.doubleValue = surface?.opacity ?? 0
    }

    @objc(rename:)
    func rename(_ sender: Any?) {
        if let surface = selected { session.rename(surface.number, label: nameField.stringValue) }
    }

    @objc(recolor:)
    func recolor(_ sender: Any?) {
        let color = colorWell.color.usingColorSpace(.sRGB)
        if let surface = selected {
            session.recolor(surface.number, red: Double(color?.redComponent ?? 0), green: Double(color?.greenComponent ?? 0),
                            blue: Double(color?.blueComponent ?? 0))
        }
    }

    @objc(visibility:)
    func visibility(_ sender: Any?) {
        if let surface = selected { session.setVisible(surface.number, visible: visibleButton.state == .on) }
    }

    @objc(opacity:)
    func opacity(_ sender: Any?) {
        if let surface = selected { session.setOpacity(surface.number, opacity: opacitySlider.doubleValue) }
    }

    @objc(duplicate:)
    func duplicate(_ sender: Any?) {
        if let surface = selected { session.duplicate(surface.number) }
    }

    @objc(remove:)
    func remove(_ sender: Any?) {
        if let surface = selected { session.remove(surface.number) }
    }

    @objc(undo:)
    func undo(_ sender: Any?) { session.undo() }

    @objc(redo:)
    func redo(_ sender: Any?) { session.redo() }

    /// Whether `controller` is the viewer's or one of its 3D windows'.
    @objc(ownsWindowController:)
    func ownsWindowController(_ controller: Any?) -> Bool {
        guard let object = controller as AnyObject? else { return false }
        if object === viewer { return true }
        for selector in ["viewerController", "viewer", "viewer2D"] {
            let sel = NSSelectorFromString(selector)
            if object.responds(to: sel), let owner = object.perform(sel)?.takeUnretainedValue(), owner === viewer {
                return true
            }
        }
        return false
    }

    private func detachActors() {
        for actor in actors {
            surfaceView.surfaceScene.removeActor(actor)
            for scene in externalScenes { scene.removeActor(actor) }
        }
        actors.removeAll()
        externalScenes.removeAll()
        meshes.removeAll()
    }

    @objc(windowChanged:)
    func windowChanged(_ note: Notification?) { changed(nil) }

    @objc(changed:)
    func changed(_ note: Notification?) {
        guard Thread.isMainThread else { return }
        let selectedRow = table.selectedRow
        detachActors()
        if session.isCurrent {
            for surface in session.snapshots {
                guard let actor = try? IsiXVTKActor.mesh(vertices: surface.mesh.vertices, triangles: surface.mesh.triangles) else { continue }
                meshes[surface.number] = actor
                actor.setColor(red: surface.red, green: surface.green, blue: surface.blue)
                actor.opacity = surface.opacity
                actor.visible = surface.visible
                surfaceView.surfaceScene.addActor(actor)
                actors.append(actor)
            }
        }
        // The volume rendering windows use patient coordinates scaled by their
        // volume factor. Each renderer gets its own actors: one view cannot
        // change another's scale.
        for window in NSApp.windows {
            guard window.isVisible, let controller = window.windowController, controller.isKind(of: VRController.self),
                  ownsWindowController(controller) else { continue }
            let view = (controller as! Window3DController).view() as AnyObject
            guard let scene = IsiXVTKScene(borrowingRendererOf: view) else { continue }
            externalScenes.append(scene)
            let factor = (view.value(forKey: "factor") as? NSNumber)?.doubleValue ?? 1
            for surface in session.snapshots {
                if !session.isCurrent { break }
                guard let shared = meshes[surface.number], let actor = try? shared.actorSharingInput() else { continue }
                actor.setUniformScale(factor)
                actor.setColor(red: surface.red, green: surface.green, blue: surface.blue)
                actor.opacity = surface.opacity
                actor.visible = surface.visible
                scene.addActor(actor)
                actors.append(actor)
            }
            (view as? NSView)?.needsDisplay = true
        }
        if !cameraInitialized && !actors.isEmpty {
            surfaceView.surfaceScene.resetCamera()
            cameraInitialized = true
        }
        surfaceView.needsDisplay = true
        table.reloadData()
        if !session.snapshots.isEmpty {
            table.selectRowIndexes(IndexSet(integer: max(0, min(selectedRow, session.snapshots.count - 1))), byExtendingSelection: false)
        }
        updateSelection()
        for window in NSApp.windows where ownsWindowController(window.windowController) {
            window.contentView?.needsDisplay = true
        }
    }

    // OpenGL's numbers, which the 2D views' canvas takes.
    private static let blend: UInt32 = 0x0BE2, texture2D: UInt32 = 0x0DE1, lineStrip: UInt32 = 0x0003
    private static let sourceAlpha: UInt32 = 0x0302, oneMinusSourceAlpha: UInt32 = 0x0303

    /// The visible segments cut by the slice of a 2D view of the viewer, drawn
    /// on its canvas.
    @objc(drawOverlay:)
    func drawOverlay(_ note: Notification) {
        guard Thread.isMainThread, let view = note.object as? DCMView, ownsWindowController(view.window?.windowController) else { return }
        if !session.isCurrent || viewer?.horosVolumeSession() !== volume {
            DispatchQueue.main.async { [self] in sourceClosed(nil) }
            return
        }
        guard let pix = view.curDCM, pix.pixelSpacingX > 0, pix.pixelSpacingY > 0 else { return }
        var orientation = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&orientation)
        let origin = IsiXVTKPoint(x: pix.originX, y: pix.originY, z: pix.originZ)
        let normal = IsiXVTKPoint(x: orientation[6], y: orientation[7], z: orientation[8])
        let scale = (note.userInfo?["scaleValue"] as AnyObject?)?.doubleValue ?? 0
        let offsetX = (note.userInfo?["offsetx"] as AnyObject?)?.doubleValue ?? 0
        let offsetY = (note.userInfo?["offsety"] as AnyObject?)?.doubleValue ?? 0
        guard let canvas = ROICanvas.current else { return }
        canvas.pushAttributes()
        canvas.disable(SEGSurfaceController.texture2D)
        canvas.enable(SEGSurfaceController.blend)
        canvas.blend(source: SEGSurfaceController.sourceAlpha, destination: SEGSurfaceController.oneMinusSourceAlpha)
        canvas.lineWidth(CGFloat(Float(2 * (view.window?.backingScaleFactor ?? 0))))
        for surface in session.snapshots where surface.visible && surface.opacity > 0 {
            let sections = (try? meshes[surface.number]?.sections(planeThrough: origin, normal: normal)) ?? []
            canvas.color(r: surface.red, g: surface.green, b: surface.blue, a: surface.opacity)
            for line in sections {
                canvas.begin(SEGSurfaceController.lineStrip)
                line.withUnsafeBytes { raw in
                    let values = raw.bindMemory(to: Double.self)
                    var index = 0
                    while index + 2 < values.count {
                        var patient = [values[index], values[index + 1], values[index + 2]]
                        var point = [Double](repeating: 0, count: 3)
                        pix.convertDICOMCoordsDouble(&patient, toSliceCoords: &point, pixelCenter: true)
                        canvas.vertex(x: (point[0] / pix.pixelSpacingX - offsetX) * scale, y: (point[1] / pix.pixelSpacingY - offsetY) * scale)
                        index += 3
                    }
                }
                canvas.end()
            }
        }
        canvas.popAttributes()
    }
}
