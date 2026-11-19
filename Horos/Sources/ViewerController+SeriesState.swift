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

/// pixList[MAX4D], the slices of each movie frame, which is the viewer's field
/// _pixList, where a plugin of the former SDK reads and writes it: retained by
/// -set, stored as given by -assign, as the other lists are.
enum ViewerPixListField {
    private static let offset: Int = {
        guard let field = class_getInstanceVariable(ViewerController.self, "_pixList") else {
            preconditionFailure("ViewerController keeps pixList in its field _pixList")
        }
        return ivar_getOffset(field)
    }()

    static func slots(of viewer: ViewerController) -> ManuallyRetainedSlotArray<NSMutableArray> {
        ManuallyRetainedSlotArray(fieldAt: offset, of: viewer)
    }
}

/// fileList, roiList, copyRoiList and volumeData [MAX4D], the files, the ROIs,
/// the ROI copies and the volume of each movie frame, kept as pixList is: each
/// in the viewer's field of its name, retained by -set, stored as given by
/// -assign.
enum ViewerFrameListFields {
    private static func offset(of name: String) -> Int {
        guard let field = class_getInstanceVariable(ViewerController.self, name) else {
            preconditionFailure("ViewerController keeps a list per movie frame in its field \(name)")
        }
        return ivar_getOffset(field)
    }

    private static let fileListOffset = offset(of: "_fileList"), roiListOffset = offset(of: "_roiList")
    private static let copyRoiListOffset = offset(of: "_copyRoiList"), volumeDataOffset = offset(of: "_volumeData")

    static func fileList(of viewer: ViewerController) -> ManuallyRetainedSlotArray<NSMutableArray> { ManuallyRetainedSlotArray(fieldAt: fileListOffset, of: viewer) }
    static func roiList(of viewer: ViewerController) -> ManuallyRetainedSlotArray<NSMutableArray> { ManuallyRetainedSlotArray(fieldAt: roiListOffset, of: viewer) }
    static func copyRoiList(of viewer: ViewerController) -> ManuallyRetainedSlotArray<NSMutableArray> { ManuallyRetainedSlotArray(fieldAt: copyRoiListOffset, of: viewer) }
    static func volumeData(of viewer: ViewerController) -> ManuallyRetainedSlotArray<NSObject> { ManuallyRetainedSlotArray(fieldAt: volumeDataOffset, of: viewer) }
}

extension ViewerController {
    nonisolated func horos_fileList(at index: Int) -> NSMutableArray? { ViewerFrameListFields.fileList(of: self)[index] }
    func horos_setFileList(_ value: NSMutableArray?, at index: Int) { ViewerFrameListFields.fileList(of: self).set(value, at: index) }
    func horos_assignFileList(_ value: NSMutableArray?, at index: Int) { ViewerFrameListFields.fileList(of: self).assign(value, at: index) }
    nonisolated func horos_pixList(at index: Int) -> NSMutableArray? { ViewerPixListField.slots(of: self)[index] }
    func horos_setPixList(_ value: NSMutableArray?, at index: Int) { ViewerPixListField.slots(of: self).set(value, at: index) }
    func horos_assignPixList(_ value: NSMutableArray?, at index: Int) { ViewerPixListField.slots(of: self).assign(value, at: index) }
    func horos_roiList(at index: Int) -> NSMutableArray? { ViewerFrameListFields.roiList(of: self)[index] }
    func horos_setRoiList(_ value: NSMutableArray?, at index: Int) { ViewerFrameListFields.roiList(of: self).set(value, at: index) }
    func horos_assignRoiList(_ value: NSMutableArray?, at index: Int) { ViewerFrameListFields.roiList(of: self).assign(value, at: index) }
    func horos_copyRoiList(at index: Int) -> NSMutableArray? { ViewerFrameListFields.copyRoiList(of: self)[index] }
    func horos_setCopyRoiList(_ value: NSMutableArray?, at index: Int) { ViewerFrameListFields.copyRoiList(of: self).set(value, at: index) }
    func horos_assignCopyRoiList(_ value: NSMutableArray?, at index: Int) { ViewerFrameListFields.copyRoiList(of: self).assign(value, at: index) }
    func horos_volumeData(at index: Int) -> NSObject? { ViewerFrameListFields.volumeData(of: self)[index] }
    func horos_setVolumeData(_ value: NSObject?, at index: Int) { ViewerFrameListFields.volumeData(of: self).set(value, at: index) }
    func horos_assignVolumeData(_ value: NSObject?, at index: Int) { ViewerFrameListFields.volumeData(of: self).assign(value, at: index) }
    nonisolated var horos_curMovieIndex: Int16 {
        get { _curMovieIndex }
        set { _curMovieIndex = newValue }
    }
    var horos_isDataVolumicIn4DLevel: Int32 {
        get { _isDataVolumicIn4DLevel }
        set { _isDataVolumicIn4DLevel = newValue }
    }
    var horos_nonVolumicDataWarningDisplayed: Bool {
        get { _nonVolumicDataWarningDisplayed }
        set { (_nonVolumicDataWarningDisplayed, _nonContinuousWarningDisplayed) = (newValue, newValue) }
    }
    var horos_displayOnlyKeyImages: Bool {
        get { _displayOnlyKeyImages }
        set { _displayOnlyKeyImages = newValue }
    }
    var horos_statusValueToApply: Int32 {
        get { _statusValueToApply }
        set { _statusValueToApply = newValue }
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
