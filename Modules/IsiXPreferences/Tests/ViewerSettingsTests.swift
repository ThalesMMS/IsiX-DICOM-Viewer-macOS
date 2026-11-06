//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
@testable import IsiXPreferences

/// The value of `snapshot`, read by a detached task, and whether it ran on the main thread.
private func readElsewhere<Value: Sendable>(_ snapshot: PreferenceSnapshot<Value>) async -> (Value, Bool) {
    await Task.detached { (snapshot.value, pthread_main_np() != 0) }.value
}

/// Preferences in memory with the application's registered values beneath them.
private func registeredPreferences() -> MemoryPreferences {
    MemoryPreferences(registered: DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:])
}

/// What the image loading, the image views and the ROIs keep of the preferences: read from the catalog's keys,
/// kept in a PreferenceSnapshot, read from another thread, and read again when the preferences change.
@Suite struct ViewerSettingsTests {
    @Test func imageLoadingSettingsAreReadAgainWhenThePreferencesChange() async {
        let store = registeredPreferences()
        let snapshot = PreferenceSnapshot(ImageLoadingSettings())
        #expect(snapshot.value == ImageLoadingSettings())
        snapshot.replace(ImageLoadingSettings(preferences: store))
        let (first, onMain) = await readElsewhere(snapshot)
        #expect(!onMain)
        #expect(!first.usesShutter && first.displaysDICOMOverlays && first.usesVOILUT && first.suvAcquisitionTimeField == 0)

        store.set(true, for: ViewerPreferences.useShutter)
        store.set(false, for: ViewerPreferences.displayDICOMOverlays)
        store.set("0", forKey: ViewerPreferences.useVOILUT.name)
        store.set(2, for: ViewerPreferences.suvAcquisitionTimeField)
        let templates: [String: PropertyListValue] = ["CT": .array([.string("PatientName")])]
        store.set(templates, for: ViewerPreferences.customImageAnnotations)
        #expect(await readElsewhere(snapshot).0 == first, "kept until the owner reads again")
        snapshot.replace(ImageLoadingSettings(preferences: store))
        let (second, _) = await readElsewhere(snapshot)
        #expect(second.usesShutter && !second.displaysDICOMOverlays && !second.usesVOILUT)
        #expect(second.suvAcquisitionTimeField == 2)
        #expect(second.customImageAnnotations == templates)
    }

    @Test func imageViewSettingsAreReadAgainWhenThePreferencesChange() async {
        let store = registeredPreferences()
        let snapshot = PreferenceSnapshot(ImageViewSettings(preferences: store))
        let (first, onMain) = await readElsewhere(snapshot)
        #expect(!onMain)
        #expect(!first.noInterpolation && first.softwareInterpolation && !first.independentCRWLWW)
        #expect(first.maximumThirtyTwoBitViewers == 4 && first.softwareInterpolationMaximum == 512 && first.clutBars == 0)
        #expect(first.overflowLines && first.displaysCrossReferenceLines)
        #expect(first.hotKeys?.isEmpty == false)

        store.set(true, for: ViewerPreferences.noInterpolation)
        store.set(false, for: ViewerPreferences.softwareInterpolation)
        store.set(true, for: ViewerPreferences.independentCRWLWW)
        let hotKeys: [String: PropertyListValue] = ["q": .integer(3)]
        store.set(hotKeys, for: ViewerPreferences.hotKeys)
        store.set(2, for: ViewerPreferences.clutBars)
        snapshot.replace(ImageViewSettings(preferences: store))
        let (second, _) = await readElsewhere(snapshot)
        #expect(second.noInterpolation && !second.softwareInterpolation && second.independentCRWLWW)
        #expect(second.hotKeys == hotKeys && second.clutBars == 2)
    }

    @Test func windowLevelSettingsReadWhatTheViewsReadByName() {
        let store = registeredPreferences()
        let registered = WindowLevelSettings(preferences: store)
        #expect(registered.petWindowingMode == 1 && registered.petMinimumValue == 0 && !registered.mouseWindowingNM)
        #expect(registered.defaultPETWindowLevel == 0)
        #expect(registered.petWindowFrom == 0 && registered.petWindowTo == 100)
        #expect(registered.petWindowFromSUV == 0 && registered.petWindowToSUV == 6)
        #expect(registered.windowsAsPET(modality: "PT") && !registered.windowsAsPET(modality: "NM"))
        #expect(!registered.windowsAsPET(modality: "CT") && !registered.windowsAsPET(modality: nil))

        // Written under the keys' names in the forms the panes and the defaults command write: text, integers, doubles.
        store.set("2", forKey: ViewerPreferences.petWindowingMode.name)
        store.set(15, forKey: ViewerPreferences.petMinimumValue.name)
        store.set(true, forKey: VolumeRenderingPreferences.mouseWindowingNM.name)
        store.set("1", forKey: ViewerPreferences.defaultPETWindowLevel.name)
        store.set(Float(10), forKey: ViewerPreferences.petWindowFrom.name)
        store.set("70", forKey: ViewerPreferences.petWindowTo.name)
        store.set(Double(0.5), forKey: ViewerPreferences.petWindowFromSUV.name)
        store.set(Float(8), forKey: ViewerPreferences.petWindowToSUV.name)
        let changed = WindowLevelSettings(preferences: store)
        #expect(changed.petWindowingMode == 2 && changed.petMinimumValue == 15 && changed.mouseWindowingNM)
        #expect(changed.defaultPETWindowLevel == 1)
        #expect(changed.petWindowFrom == 10 && changed.petWindowTo == 70)
        #expect(changed.petWindowFromSUV == 0.5 && changed.petWindowToSUV == 8)
        #expect(changed.windowsAsPET(modality: "NM") && !changed.windowsAsPET(modality: "MR"))
        #expect(WindowLevelSettings(preferences: MemoryPreferences()) == WindowLevelSettings(), "absent is 0 and false")
    }

    @Test func roiSettingsAreReadAgainAndWrittenBack() async {
        let store = registeredPreferences()
        let snapshot = PreferenceSnapshot(ROISettings())
        #expect(!snapshot.value.loaded)
        snapshot.replace(ROISettings(preferences: store))
        let (first, onMain) = await readElsewhere(snapshot)
        #expect(!onMain)
        #expect(first.loaded && first.thickness == 2 && first.regionOpacity == 0.5 && first.colorG == 65535)
        #expect(first.spline && first.drawPlainEdge && !first.textNameOnly && !first.textIfMouseIsOver)

        // An opacity or a thickness below 0.3 is read as 0.3.
        store.set(Float(0.1), for: ViewerPreferences.roiOpacity)
        store.set(Float(0), for: ViewerPreferences.roiThickness)
        store.set(true, for: ViewerPreferences.roiTextNameOnly)
        snapshot.replace(ROISettings(preferences: store))
        let (second, _) = await readElsewhere(snapshot)
        #expect(second.opacity == 0.3 && second.thickness == 0.3 && second.textNameOnly)

        // A ROI changed "globally" changes the settings, which are written back as the panes write them.
        snapshot.update { $0.regionThickness = 9 }
        let written = MemoryPreferences()
        snapshot.value.write(to: written)
        #expect(written[ViewerPreferences.roiRegionThickness] == 9)
        #expect(written.writes.count == 15)
        #expect(written.object(forKey: ViewerPreferences.roiOpacity.name) as? NSNumber == NSNumber(value: Float(0.3)))
    }

    @Test func theKeyFamiliesNameTheCatalogsKeys() {
        #expect(ViewerPreferences.annotationsCustomHide.map(\.name) == [
            "AnnotationsCustomHideROIs", "AnnotationsCustomHideColorBar", "AnnotationsCustomHideScaleRuler",
            "AnnotationsCustomHideReferenceLines", "AnnotationsCustomHideOrientation", "AnnotationsCustomHidePatientName",
            "AnnotationsCustomHideImageInfo", "AnnotationsCustomHideWindowLevel", "AnnotationsCustomHideMousePosition",
            "AnnotationsCustomHideOtherFields",
        ])
        let catalogued = Set(DefaultPreferences.catalog.map(\.name))
        for key in ViewerPreferences.annotationsCustomHide { #expect(catalogued.contains(key.name)) }
        for kind in ["Area", "WH", "Mean", "SDev", "Sum", "Median", "Min", "Max"] {
            let key = ViewerPreferences.roiLabelShows(statistic: kind)
            #expect(key?.name == "ROILabelShow" + kind && catalogued.contains("ROILabelShow" + kind))
        }
        #expect(ViewerPreferences.roiLabelShows(statistic: "Prefix") == nil)
        for modality in ["CR", "DR", "DX", "RF", "XA"] {
            let key = ViewerPreferences.noPropagateInSeries(forModality: modality)
            #expect(key.name == "noPropagateInSeriesFor" + modality && key.registration != nil)
        }
        #expect(ViewerPreferences.noPropagateInSeries(forModality: "CT").name == "noPropagateInSeriesForCT")
        #expect(ViewerPreferences.noPropagateInSeries(forModality: "CT").registration == nil)
        #expect(ViewerPreferences.splitViewPosition(named: "MPR").name == "KFSplitView Position MPR")
        let store = MemoryPreferences(["KFSplitView Position MPR": ["a": 1]])
        #expect(store[ViewerPreferences.splitViewPosition(named: "MPR")] == .dictionary(["a": .integer(1)]))
    }
}
