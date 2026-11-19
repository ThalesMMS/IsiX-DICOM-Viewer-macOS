//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXImaging

/// The paths of a curved MPR window: several, each with a name, one of them
/// shown (see `CurvedPathSet`). The window still has one path at a time, the
/// one it shows; this keeps the others as archives, swaps them in from a
/// menu of the toolbar, and reads and writes them all in the window's path
/// file - the one kept with the series and the one Save Path writes.
///
/// From the paths it opens the coronary MIP: a volume rendering of the
/// series where only the voxels within a tube around the paths are left
/// (see `VesselTube`), so the arteries show without the chambers in front.
@MainActor @objc(HorosCurvedPathLibrary)
public final class CurvedPathLibrary: NSObject, NSMenuDelegate {
    static let pathsItem = "tbCurvedPaths"
    static let coronaryMIPItem = "tbCoronaryMIP"

    private weak var controller: CPRController?
    private(set) var paths = CurvedPathSet()
    /// The radius of the coronary MIP's tube, in mm.
    private(set) var tubeRadius = VesselTube.defaultRadius
    private let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 25), pullsDown: true)
    private let mipButton: NSButton

    /// The name of the one path of a window that was given no name.
    static var defaultName: String { NSLocalizedString("Path", comment: "Curved MPR: the name of a path that was given none") }

    init(controller: CPRController) {
        self.controller = controller
        mipButton = NSButton(title: NSLocalizedString("Coronary MIP", comment: "Curved MPR toolbar: opens a MIP of the voxels around the paths"), target: nil, action: nil)
        super.init()
        popUp.bezelStyle = .texturedRounded
        popUp.menu?.delegate = self
        popUp.toolTip = NSLocalizedString("The paths of this window: choose the one shown, add one for another vessel, rename or delete.", comment: "Curved MPR toolbar: tooltip of the Paths menu")
        mipButton.bezelStyle = .texturedRounded
        mipButton.target = self
        mipButton.action = #selector(openCoronaryMIP(_:))
        mipButton.toolTip = NSLocalizedString("Opens a MIP of the series with only what lies within a few millimetres of the paths, as an angiogram shows the arteries.", comment: "Curved MPR toolbar: tooltip of the Coronary MIP button")
        mipButton.sizeToFit()
        rebuildMenu()
    }

    /// Gives `item` the Paths menu or the Coronary MIP button when `identifier` names one of them.
    func configure(_ item: NSToolbarItem?, as identifier: String) -> Bool {
        let (label, view): (String, NSView)
        switch identifier {
        case Self.pathsItem: (label, view) = (NSLocalizedString("Paths", comment: "Curved MPR toolbar: the menu of the window's paths"), popUp)
        case Self.coronaryMIPItem: (label, view) = (mipButton.title, mipButton)
        default: return false
        }
        item?.label = label
        item?.paletteLabel = label
        item?.toolTip = view.toolTip
        item?.view = view
        ToolbarPolicy.constrainView(of: item, minimum: ToolbarPolicy.designedSize(of: view), maximum: .zero)
        return true
    }

    // MARK: - Archives

    private static func archive(_ path: CPRCurvedPath) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: path, requiringSecureCoding: true)
    }

    /// Secure coding: an archive names its classes, and only a curved path's
    /// are decoded, not whatever it names before it is checked.
    private static func path(from archive: Data) -> CPRCurvedPath? {
        var path: CPRCurvedPath?
        try? HorosObjCException.perform { path = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CPRCurvedPath.self, from: archive) }
        return path
    }

    /// Keeps the path the window shows as the set's current one.
    private func storeShown() {
        guard let shown = controller?.curvedPath, let archive = Self.archive(shown) else { return }
        // A window with no path marked and no path kept has nothing to keep.
        if paths.entries.isEmpty && shown.nodes.count == 0 { return }
        paths.store(archive, defaultName: Self.defaultName)
    }

    // MARK: - The file

    /// Writes the paths to `file`, the one shown as it is now; one path with
    /// no name of its own as the archive it always was. Nothing is written
    /// when the path shown cannot be read back.
    func save(toFile file: String?) {
        guard let file, let shown = controller?.curvedPath, let archive = Self.archive(shown), Self.path(from: archive) != nil else { return }
        var written = paths
        written.store(archive, defaultName: Self.defaultName)
        guard let data = written.fileData(defaultName: Self.defaultName) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        } catch {
            NSLog("Unable to save curved path: %@", (error as NSError).localizedDescription)
        }
    }

    /// Reads the paths of `file` and shows its current one. False when the
    /// file holds no path that opens, a text of points for one.
    func load(fromFile file: String?) -> Bool {
        guard let file, let data = FileManager.default.contents(atPath: file) else { return false }
        let read = CurvedPathSet(fileData: data, defaultName: Self.defaultName)
        guard let current = read.current, let path = Self.path(from: current.path) else { return false }
        paths = read
        controller?.showLoadedPath(path)
        rebuildMenu()
        return true
    }

    // MARK: - The menu

    @objc public var pathNames: [String] { paths.names }
    @objc public var shownPathName: String { paths.current?.name ?? "" }

    public func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = popUp.menu else { return }
        menu.removeAllItems()
        // The first item of a pull-down menu is its title.
        menu.addItem(withTitle: paths.current?.name ?? NSLocalizedString("Paths", comment: "Curved MPR toolbar: the menu of the window's paths"), action: nil, keyEquivalent: "")
        for (index, name) in paths.names.enumerated() {
            let item = menu.addItem(withTitle: name, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == paths.selected ? .on : .off
        }
        if !paths.entries.isEmpty { menu.addItem(.separator()) }
        let new = menu.addItem(withTitle: NSLocalizedString("New Path", comment: "Curved MPR Paths menu: adds a path for another vessel"), action: nil, keyEquivalent: "")
        let names = NSMenu()
        for name in CurvedPathSet.suggestedNames + [NSLocalizedString("Other…", comment: "Curved MPR Paths menu: a new path with a name to type")] {
            let item = names.addItem(withTitle: name, action: #selector(newPath(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CurvedPathSet.suggestedNames.contains(name) ? name : nil
        }
        new.submenu = names
        let rename = menu.addItem(withTitle: NSLocalizedString("Rename…", comment: "Curved MPR Paths menu: renames the path shown"), action: #selector(renameShown(_:)), keyEquivalent: "")
        let delete = menu.addItem(withTitle: NSLocalizedString("Delete Path", comment: "Curved MPR Paths menu: deletes the path shown"), action: #selector(deleteShown(_:)), keyEquivalent: "")
        for item in [rename, delete] {
            item.target = self
            item.isEnabled = !paths.entries.isEmpty
        }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let radius = menu.addItem(withTitle: NSLocalizedString("Coronary MIP Radius", comment: "Curved MPR Paths menu: how far from the paths the coronary MIP keeps the voxels"), action: nil, keyEquivalent: "")
        let radii = NSMenu()
        for mm in [2.0, 3, 4, 5, 6, 8, 10] {
            let item = radii.addItem(withTitle: String(format: NSLocalizedString("%@ mm around the paths", comment: "Curved MPR Paths menu: a radius of the coronary MIP's tube"), String(Int(mm))), action: #selector(chooseRadius(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(mm)
            item.state = mm == tubeRadius ? .on : .off
        }
        radius.submenu = radii
    }

    @objc func choose(_ sender: NSMenuItem) { showPath(at: sender.tag) }

    /// Shows the path at `index`, keeping the one shown as it is now.
    @objc(showPathAtIndex:)
    public func showPath(at index: Int) {
        storeShown()
        guard paths.entries.indices.contains(index), let path = Self.path(from: paths.entries[index].path) else { return }
        paths.select(index)
        controller?.showLoadedPath(path)
        rebuildMenu()
    }

    @objc func newPath(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            addPath(named: name)
        } else if let name = askName(paths.nextName(generic: Self.defaultName)) {
            addPath(named: name)
        }
    }

    /// Adds an empty path named `name`, made unique, and shows it: the next
    /// points marked are its own.
    @objc(addPathNamed:)
    public func addPath(named name: String) {
        storeShown()
        let empty = CPRCurvedPath()
        // The slab of the path shown goes on with the new one.
        if let shown = controller?.curvedPath { empty.thickness = shown.thickness }
        guard let archive = Self.archive(empty) else { return }
        // The first path of a window that had none marked takes the name itself.
        if paths.entries.isEmpty { paths = CurvedPathSet(entries: [.init(name: paths.uniqueName(name, fallback: Self.defaultName), path: archive)], selected: 0) }
        else { paths.add(name: name, path: archive, fallback: Self.defaultName) }
        controller?.showLoadedPath(empty)
        rebuildMenu()
    }

    @objc func renameShown(_ sender: Any?) {
        guard let current = paths.current, let name = askName(current.name) else { return }
        renameShownPath(to: name)
    }

    @objc(renameShownPathTo:)
    public func renameShownPath(to name: String) {
        storeShown()
        paths.rename(paths.selected, to: name, fallback: Self.defaultName)
        rebuildMenu()
    }

    @objc(deleteShown:)
    public func deleteShown(_ sender: Any?) {
        guard !paths.entries.isEmpty else { return }
        paths.remove(paths.selected)
        let next = paths.current.flatMap { Self.path(from: $0.path) } ?? CPRCurvedPath()
        controller?.showLoadedPath(next)
        rebuildMenu()
    }

    @objc func chooseRadius(_ sender: NSMenuItem) { setTubeRadius(Double(sender.tag)) }

    @objc(setTubeRadiusInMm:)
    public func setTubeRadius(_ mm: Double) {
        tubeRadius = min(max(mm, VesselTube.radii.lowerBound), VesselTube.radii.upperBound)
        rebuildMenu()
    }

    private func askName(_ proposed: String) -> String? {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Name of the path:", comment: "Curved MPR: asks the name of a path")
        let field = NSTextField(string: proposed)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - The coronary MIP

    /// Each path with points, as the points it runs through, in patient space, about half a millimetre apart.
    private func polylines() -> [[SIMD3<Double>]] {
        storeShown()
        return paths.entries.compactMap { entry -> [SIMD3<Double>]? in
            guard let path = Self.path(from: entry.path), path.nodes.count > 0 else { return nil }
            if path.nodes.count == 1, let node = (path.nodes.firstObject as? NSValue)?.n3VectorValue() {
                return [SIMD3(Double(node.x), Double(node.y), Double(node.z))]
            }
            guard let flattened = path.bezierPath?.mutableCopy() as? N3MutableBezierPath, flattened.elementCount() >= 2 else { return nil }
            flattened.subdivide(N3BezierDefaultSubdivideSegmentLength)
            flattened.flatten(N3BezierDefaultFlatness)
            let count = max(Int((Double(flattened.length()) / 0.5).rounded(.up)), 1)
            return (0...count).map { i in
                let point = flattened.vector(atRelativePosition: CGFloat(i) / CGFloat(count))
                return SIMD3(Double(point.x), Double(point.y), Double(point.z))
            }
        }
    }

    /// What the last coronary MIP kept: the voxels within the tube, and those of the volume.
    @objc public private(set) var lastMIPKeptVoxels = 0
    @objc public private(set) var lastMIPVolumeVoxels = 0
    /// The value the last coronary MIP gave the voxels outside the tube, and its volume, for a check to read.
    @objc public private(set) var lastMIPOutsideValue: Float = 0
    @objc public private(set) var lastMIPVolume: NSData?

    /// Opens a MIP of the series with only the voxels within the tube around
    /// the paths; a beep when no path has a point or the series has no volume.
    @objc(openCoronaryMIP:)
    public func openCoronaryMIP(_ sender: Any?) {
        let paths = polylines()
        guard !paths.isEmpty, let viewer = controller?.viewer() else { NSSound.beep(); return }
        var volumeData: NSData?
        var copied: NSMutableArray?
        viewer.copyVolumeData(&volumeData, andDCMPix: &copied, forMovieIndex: Int32(viewer.curMovieIndex()))
        guard let volumeData, let copied, let pixels = copied as? [DCMPix], pixels.count > 1, let first = pixels.first,
              let files = viewer.horos_fileList(at: Int(viewer.curMovieIndex())) else { NSSound.beep(); return }

        var orientation = [Float](repeating: 0, count: 9)
        first.orientation(&orientation)
        let origin = SIMD3(first.originX, first.originY, first.originZ)
        let next = SIMD3(pixels[1].originX, pixels[1].originY, pixels[1].originZ)
        let grid = VesselTube.Grid(width: first.pwidth, height: first.pheight, depth: pixels.count, origin: origin,
                                   column: SIMD3(Double(orientation[0]), Double(orientation[1]), Double(orientation[2])) * first.pixelSpacingX,
                                   row: SIMD3(Double(orientation[3]), Double(orientation[4]), Double(orientation[5])) * first.pixelSpacingY,
                                   slice: next - origin)
        let count = grid.width * grid.height * grid.depth
        guard volumeData.length >= count * MemoryLayout<Float>.size, let mask = VesselTube.mask(of: grid, around: paths, radius: tubeRadius) else { NSSound.beep(); return }
        let voxels = UnsafeMutableBufferPointer(start: UnsafeMutableRawPointer(mutating: volumeData.bytes).assumingMemoryBound(to: Float.self), count: count)
        // Outside the tube, the darkest value of the volume: nothing a projection of maxima shows.
        let outside = voxels.min() ?? -1024
        VesselTube.keep(mask, of: voxels, elsewhere: outside)
        (lastMIPKeptVoxels, lastMIPVolumeVoxels, lastMIPOutsideValue, lastMIPVolume) = (mask.reduce(0) { $0 + Int($1) }, count, outside, volumeData)

        guard let renderer = VRController(pix: copied, files, volumeData, nil, viewer, style: "standard", mode: "MIP") else { NSSound.beep(); return }
        // The window keeps itself until it closes, as every 3D window a viewer opens.
        _ = Unmanaged.passRetained(renderer)
        var (level, width): (Float, Float) = (0, 0)
        viewer.horos_imageView?.getWLWW(&level, &width)
        renderer.setWLWW(level, width)
        if let screen = viewer.window?.screen ?? NSScreen.main { renderer.window?.setFrame(screen.visibleFrame, display: false) }
        renderer.load3DState()
        renderer.showWindow(self)
        renderer.window?.title = String(format: NSLocalizedString("Coronary MIP: %@", comment: "Title of the coronary MIP window; the argument is the title of the 2D viewer"), viewer.window?.title ?? "")
    }
}
