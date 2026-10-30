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

/// The series a viewer shows: per movie frame (up to MAX4D) its slices, files, ROIs, ROI copies and volume, which frame is shown and how many there are, and the series-level flags of the volumic checks, the key images and the status to apply.
final class ViewerSeriesState: @unchecked Sendable {
    /// fileList[MAX4D]: retained by -set, stored as given by -assign.
    let fileList = ManuallyRetainedSlots<NSMutableArray>(count: Int(MAX4D))
    /// pixList[MAX4D]: retained by -set, stored as given by -assign.
    let pixList = ManuallyRetainedSlots<NSMutableArray>(count: Int(MAX4D))
    /// roiList[MAX4D]: retained by -set, stored as given by -assign.
    let roiList = ManuallyRetainedSlots<NSMutableArray>(count: Int(MAX4D))
    /// copyRoiList[MAX4D]: retained by -set, stored as given by -assign.
    let copyRoiList = ManuallyRetainedSlots<NSMutableArray>(count: Int(MAX4D))
    /// volumeData[MAX4D]: retained by -set, stored as given by -assign.
    let volumeData = ManuallyRetainedSlots<NSObject>(count: Int(MAX4D))
    var curMovieIndex: Int16 = 0
    var maxMovieIndex: Int16 = 0
    var isDataVolumicIn4DLevel: Int32 = 0
    var nonVolumicDataWarningDisplayed: Bool = false
    var displayOnlyKeyImages: Bool = false
    var statusValueToApply: Int32 = 0
}

extension ViewerController {
    nonisolated func horos_fileList(at index: Int) -> NSMutableArray? { seriesState.fileList[index] }
    func horos_setFileList(_ value: NSMutableArray?, at index: Int) { seriesState.fileList.set(value, at: index) }
    func horos_assignFileList(_ value: NSMutableArray?, at index: Int) { seriesState.fileList.assign(value, at: index) }
    nonisolated func horos_pixList(at index: Int) -> NSMutableArray? { seriesState.pixList[index] }
    func horos_setPixList(_ value: NSMutableArray?, at index: Int) { seriesState.pixList.set(value, at: index) }
    func horos_assignPixList(_ value: NSMutableArray?, at index: Int) { seriesState.pixList.assign(value, at: index) }
    func horos_roiList(at index: Int) -> NSMutableArray? { seriesState.roiList[index] }
    func horos_setRoiList(_ value: NSMutableArray?, at index: Int) { seriesState.roiList.set(value, at: index) }
    func horos_assignRoiList(_ value: NSMutableArray?, at index: Int) { seriesState.roiList.assign(value, at: index) }
    func horos_copyRoiList(at index: Int) -> NSMutableArray? { seriesState.copyRoiList[index] }
    func horos_setCopyRoiList(_ value: NSMutableArray?, at index: Int) { seriesState.copyRoiList.set(value, at: index) }
    func horos_assignCopyRoiList(_ value: NSMutableArray?, at index: Int) { seriesState.copyRoiList.assign(value, at: index) }
    func horos_volumeData(at index: Int) -> NSObject? { seriesState.volumeData[index] }
    func horos_setVolumeData(_ value: NSObject?, at index: Int) { seriesState.volumeData.set(value, at: index) }
    func horos_assignVolumeData(_ value: NSObject?, at index: Int) { seriesState.volumeData.assign(value, at: index) }
    nonisolated var horos_curMovieIndex: Int16 {
        get { seriesState.curMovieIndex }
        set { seriesState.curMovieIndex = newValue }
    }
    nonisolated var horos_maxMovieIndex: Int16 {
        get { seriesState.maxMovieIndex }
        set { seriesState.maxMovieIndex = newValue }
    }
    var horos_isDataVolumicIn4DLevel: Int32 {
        get { seriesState.isDataVolumicIn4DLevel }
        set { seriesState.isDataVolumicIn4DLevel = newValue }
    }
    var horos_nonVolumicDataWarningDisplayed: Bool {
        get { seriesState.nonVolumicDataWarningDisplayed }
        set { seriesState.nonVolumicDataWarningDisplayed = newValue }
    }
    var horos_displayOnlyKeyImages: Bool {
        get { seriesState.displayOnlyKeyImages }
        set { seriesState.displayOnlyKeyImages = newValue }
    }
    var horos_statusValueToApply: Int32 {
        get { seriesState.statusValueToApply }
        set { seriesState.statusValueToApply = newValue }
    }

    /// The number of slices of the movie frame shown.
    @objc(getNumberOfImages)
    func getNumberOfImages() -> Int {
        return horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0
    }

    /// The number of movie frames.
    @objc(maxMovieIndex)
    nonisolated func maxMovieIndex() -> Int16 {
        return horos_maxMovieIndex
    }
}
