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
import ObjectiveC

/// The selectors of the 2D viewer and of its image view that only later
/// headers of the plugin SDK declare and the application has something
/// behind, added to the two classes when the application starts, as
/// LaterPluginSDKAnswers adds those that have nothing behind them.
///
/// A plugin built with those headers sends them by name, from any thread:
/// each does its work on the main thread, and the caller waits for it. They
/// are added here and not written in the two classes, which hold enough.
enum LaterPluginSDKViewerAnswers {

    /// The types of a selector, "-selector" or "+selector", of a class, as the table of the bundle gives them.
    typealias Types = (_ className: String, _ key: String) -> String?

    /// Adds the answers to ViewerController and DCMView, each with the types
    /// `types` gives it. A selector a class answers already is left alone,
    /// and one the table does not have is not added. Returns how many it added.
    static func install(types: Types) -> Int {
        viewer(types) + view(types)
    }

    /// Adds `block` to `cls` as the method of `key`, "-selector" or "+selector".
    private static func add(_ block: Any, as key: String, to cls: AnyClass, _ types: Types) -> Int {
        let selector = NSSelectorFromString(String(key.dropFirst()))
        guard let target: AnyClass = key.hasPrefix("+") ? object_getClass(cls) : cls, !class_respondsToSelector(target, selector),
              let encoding = types(NSStringFromClass(cls), key) else { return 0 }
        return class_addMethod(target, selector, imp_implementationWithBlock(block), encoding) ? 1 : 0
    }

    // MARK: The viewer

    /// The viewer `allocated` holds, started by -initWithPix:withFiles:withVolume:,
    /// which later headers give more arguments: a series is shown as a movie
    /// by its own images, its images are flipped when they are shown, and
    /// each viewer is a new one. As any initializer, it takes the object it
    /// is sent to and answers one its caller owns: the two pass through as
    /// they are.
    private static func started(_ allocated: UnsafeMutableRawPointer, _ images: AnyObject?, _ files: AnyObject?, _ volume: AnyObject?) -> UnsafeMutableRawPointer? {
        typealias Initializer = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject?, AnyObject?, AnyObject?) -> UnsafeMutableRawPointer?
        let selector = NSSelectorFromString("initWithPix:withFiles:withVolume:")
        guard let implementation = class_getMethodImplementation(object_getClass(Unmanaged<AnyObject>.fromOpaque(allocated).takeUnretainedValue()), selector) else { return nil }
        return unsafeBitCast(implementation, to: Initializer.self)(allocated, selector, images, files, volume)
    }

    private static func viewer(_ types: Types) -> Int {
        let cls: AnyClass = ViewerController.self
        var added = 0
        added += add({ allocated, images, files, volume, _ in started(allocated, images, files, volume) } as @convention(block) (UnsafeMutableRawPointer, AnyObject?, AnyObject?, AnyObject?, Bool) -> UnsafeMutableRawPointer?,
            as: "-initWithPix:withFiles:withVolume:movie:", to: cls, types)
        added += add({ allocated, images, files, volume, _, _ in started(allocated, images, files, volume) } as @convention(block) (UnsafeMutableRawPointer, AnyObject?, AnyObject?, AnyObject?, Bool, Bool) -> UnsafeMutableRawPointer?,
            as: "-initWithPix:withFiles:withVolume:movie:preFlipped:", to: cls, types)
        added += add({ allocated, images, files, volume, _, _, _ in started(allocated, images, files, volume) } as @convention(block) (UnsafeMutableRawPointer, AnyObject?, AnyObject?, AnyObject?, Bool, Bool, Bool) -> UnsafeMutableRawPointer?,
            as: "-initWithPix:withFiles:withVolume:movie:preFlipped:usePoolIfAvailable:", to: cls, types)

        // The number of 2D viewers: +numberOf2DViewer by another name.
        added += add({ _ in ViewerController.numberOf2DViewer() } as @convention(block) (AnyObject) -> Int32, as: "+countOf2DViewers", to: cls, types)

        // Puts the ROI on the image the viewer shows, and announces it as the
        // view announces a ROI the user drew.
        added += add({ viewer, new in
            let handed = Handed(value: (viewer, new))
            onMainActorSync {
                let (viewer, new) = handed.value
                guard let roi = new, let view = viewer.imageView(), let list = view.curRoiList, list.indexOfObjectIdentical(to: roi) == NSNotFound else { return }
                if let image = view.curDCM { roi.pix = image }
                view.roiSet(roi)
                list.add(roi)
                postViewerNotification(.OsirixAddROI, view, ["ROI": roi, "sliceNumber": NSNumber(value: view.curImage)])
                postViewerNotification(.OsirixROIChange, roi)
                viewer.needsDisplayUpdate()
            }
        } as @convention(block) (ViewerController, ROI?) -> Void, as: "-addROI:", to: cls, types)

        // Takes the ROIs out of the image the viewer shows, as -[DCMView deleteROIs:] does: a locked ROI stays.
        added += add({ viewer, removed in
            let handed = Handed(value: (viewer, removed))
            onMainActorSync { handed.value.0.imageView()?.deleteROIs(handed.value.1 as? [Any]) }
        } as @convention(block) (ViewerController, AnyObject?) -> Void, as: "-deleteROIs:", to: cls, types)
        return added
    }

    // MARK: The view

    private static func view(_ types: Types) -> Int {
        let cls: AnyClass = DCMView.self
        var added = 0

        // The 2D viewer the view is in, or nil in any other window.
        added += add({ view in
            let handed = Handed(value: view)
            return onMainActorSync { handed.value.window?.windowController as? ViewerController }
        } as @convention(block) (DCMView) -> AnyObject?, as: "-viewer", to: cls, types)

        // The ROIs of the image the view shows that have that name.
        added += add({ view, name in
            let handed = Handed(value: view)
            let found = onMainActorSync { (handed.value.curRoiList as? [ROI] ?? []).filter { $0.name == name } }
            return found as AnyObject
        } as @convention(block) (DCMView, String?) -> AnyObject?, as: "-roisWithName:", to: cls, types)

        // The names of the ROIs of the image the view shows, each once, in their order.
        added += add({ view in
            let handed = Handed(value: view)
            let names: [String] = onMainActorSync {
                var names: [String] = []
                for roi in handed.value.curRoiList as? [ROI] ?? [] {
                    if let name = roi.name, !names.contains(name) { names.append(name) }
                }
                return names
            }
            return names as AnyObject
        } as @convention(block) (DCMView) -> AnyObject?, as: "-arrayOfROIsNames", to: cls, types)

        // What -setSyncOnLocationImpossible: set.
        added += add({ view in
            let handed = Handed(value: view)
            return onMainActorSync { handed.value.horos_syncOnLocationImpossible }
        } as @convention(block) (DCMView) -> Bool, as: "-syncOnLocationImpossible", to: cls, types)

        // -setWLWW::, which keeps the window with the image it is set on.
        added += add({ view, level, width, _ in
            let handed = Handed(value: view)
            onMainActorSync { handed.value.setWLWW(level, width) }
        } as @convention(block) (DCMView, Float, Float, Bool) -> Void, as: "-setWLWW::saveChanges:", to: cls, types)
        return added
    }
}
