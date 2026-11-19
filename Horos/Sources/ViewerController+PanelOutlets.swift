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

// The connections of the nib, which sets each outlet through -set<Outlet>:.
extension ViewerController {
    @objc(setAddCLUTWindow:) private func connectAddCLUTWindow(_ outlet: NSWindow?) { _addCLUTWindow = outlet }
    @objc(setAddConvWindow:) private func connectAddConvWindow(_ outlet: NSWindow?) { _addConvWindow = outlet }
    @objc(setAddOpacityWindow:) private func connectAddOpacityWindow(_ outlet: NSWindow?) { _addOpacityWindow = outlet }
    @objc(setAddWLWWWindow:) private func connectAddWLWWWindow(_ outlet: NSWindow?) { _addWLWWWindow = outlet }
    @objc(setAllROIsRadio:) private func connectAllROIsRadio(_ outlet: NSMatrix?) { _AllROIsRadio = outlet }
    @objc(setBlendingPlugins:) private func connectBlendingPlugins(_ outlet: NSPopUpButton?) { _blendingPlugins = outlet }
    @objc(setBlendingResample:) private func connectBlendingResample(_ outlet: NSButton?) { _blendingResample = outlet }
    @objc(setBlendingTypeMultiply:) private func connectBlendingTypeMultiply(_ outlet: NSButton?) { _blendingTypeMultiply = outlet }
    @objc(setBlendingTypeRGB:) private func connectBlendingTypeRGB(_ outlet: NSSegmentedControl?) { _blendingTypeRGB = outlet }
    @objc(setBlendingTypeSubtract:) private func connectBlendingTypeSubtract(_ outlet: NSButton?) { _blendingTypeSubtract = outlet }
    @objc(setBlendingTypeWindow:) private func connectBlendingTypeWindow(_ outlet: NSWindow?) { _blendingTypeWindow = outlet }
    @objc(setBrushROIFilterOptionsAllWithSameName:) private func connectBrushROIFilterOptionsAllWithSameName(_ outlet: NSButton?) { _brushROIFilterOptionsAllWithSameName = outlet }
    @objc(setBrushROIFilterOptionsOKButton:) private func connectBrushROIFilterOptionsOKButton(_ outlet: NSButton?) { _brushROIFilterOptionsOKButton = outlet }
    @objc(setBrushROIFilterOptionsWindow:) private func connectBrushROIFilterOptionsWindow(_ outlet: NSWindow?) { _brushROIFilterOptionsWindow = outlet }
    @objc(setCheckMaxValue:) private func connectCheckMaxValue(_ outlet: NSButton?) { _checkMaxValue = outlet }
    @objc(setCheckMinValue:) private func connectCheckMinValue(_ outlet: NSButton?) { _checkMinValue = outlet }
    @objc(setClutName:) private func connectClutName(_ outlet: NSTextField?) { _clutName = outlet }
    @objc(setClutView:) private func connectClutView(_ outlet: ColorTransferView?) { _clutView = outlet }
    @objc(setCommentsEditField:) private func connectCommentsEditField(_ outlet: NSTextField?) { _CommentsEditField = outlet }
    @objc(setCommentsWindow:) private func connectCommentsWindow(_ outlet: NSWindow?) { _CommentsWindow = outlet }
    @objc(setConvMatrix:) private func connectConvMatrix(_ outlet: NSMatrix?) { _convMatrix = outlet }
    @objc(setCustomInterval:) private func connectCustomInterval(_ outlet: NSTextField?) { _customInterval = outlet }
    @objc(setCustomOrigin:) private func connectCustomOrigin(_ outlet: NSMatrix?) { _customOrigin = outlet }
    @objc(setCustomVectors:) private func connectCustomVectors(_ outlet: NSMatrix?) { _customVectors = outlet }
    @objc(setCustomXSpacing:) private func connectCustomXSpacing(_ outlet: NSTextField?) { _customXSpacing = outlet }
    @objc(setCustomYSpacing:) private func connectCustomYSpacing(_ outlet: NSTextField?) { _customYSpacing = outlet }
    @objc(setDcmAllViewers:) private func connectDcmAllViewers(_ outlet: NSButton?) { _dcmAllViewers = outlet }
    @objc(setDcmBox:) private func connectDcmBox(_ outlet: NSBox?) { _dcmBox = outlet }
    @objc(setDcmExportWindow:) private func connectDcmExportWindow(_ outlet: NSWindow?) { _dcmExportWindow = outlet }
    @objc(setDcmFormat:) private func connectDcmFormat(_ outlet: NSMatrix?) { _dcmFormat = outlet }
    @objc(setDcmFrom:) private func connectDcmFrom(_ outlet: NSSlider?) { _dcmFrom = outlet }
    @objc(setDcmFromText:) private func connectDcmFromText(_ outlet: NSTextField?) { _dcmFromText = outlet }
    @objc(setDcmInterval:) private func connectDcmInterval(_ outlet: NSSlider?) { _dcmInterval = outlet }
    @objc(setDcmIntervalText:) private func connectDcmIntervalText(_ outlet: NSTextField?) { _dcmIntervalText = outlet }
    @objc(setDcmNumber:) private func connectDcmNumber(_ outlet: NSTextField?) { _dcmNumber = outlet }
    @objc(setDcmSelection:) private func connectDcmSelection(_ outlet: NSMatrix?) { _dcmSelection = outlet }
    @objc(setDcmSeriesName:) private func connectDcmSeriesName(_ outlet: NSTextField?) { _dcmSeriesName = outlet }
    @objc(setDcmTo:) private func connectDcmTo(_ outlet: NSSlider?) { _dcmTo = outlet }
    @objc(setDcmToText:) private func connectDcmToText(_ outlet: NSTextField?) { _dcmToText = outlet }
    @objc(setDisplaySUVWindow:) private func connectDisplaySUVWindow(_ outlet: NSWindow?) { _displaySUVWindow = outlet }
    @objc(setFromset:) private func connectFromset(_ outlet: NSTextField?) { _fromset = outlet }
    @objc(setImageAllViewers:) private func connectImageAllViewers(_ outlet: NSButton?) { _imageAllViewers = outlet }
    @objc(setImageExportWindow:) private func connectImageExportWindow(_ outlet: NSWindow?) { _imageExportWindow = outlet }
    @objc(setImageFormat:) private func connectImageFormat(_ outlet: NSMatrix?) { _imageFormat = outlet }
    @objc(setImageSelection:) private func connectImageSelection(_ outlet: NSMatrix?) { _imageSelection = outlet }
    @objc(setInjectionTimeWindow:) private func connectInjectionTimeWindow(_ outlet: NSWindow?) { _injectionTimeWindow = outlet }
    @objc(setInOutROI:) private func connectInOutROI(_ outlet: NSMatrix?) { _InOutROI = outlet }
    @objc(setMatrixName:) private func connectMatrixName(_ outlet: NSTextField?) { _matrixName = outlet }
    @objc(setMatrixNorm:) private func connectMatrixNorm(_ outlet: NSTextField?) { _matrixNorm = outlet }
    @objc(setMaxValueText:) private func connectMaxValueText(_ outlet: NSTextField?) { _maxValueText = outlet }
    @objc(setMinValueText:) private func connectMinValueText(_ outlet: NSTextField?) { _minValueText = outlet }
    @objc(setNewName:) private func connectNewName(_ outlet: NSTextField?) { _newName = outlet }
    @objc(setNewValueMatrix:) private func connectNewValueMatrix(_ outlet: NSMatrix?) { _newValueMatrix = outlet }
    @objc(setNewValueText:) private func connectNewValueText(_ outlet: NSTextField?) { _newValueText = outlet }
    @objc(setOpacityName:) private func connectOpacityName(_ outlet: NSTextField?) { _OpacityName = outlet }
    @objc(setOpacityView:) private func connectOpacityView(_ outlet: OpacityTransferView?) { _OpacityView = outlet }
    @objc(setPrintBox:) private func connectPrintBox(_ outlet: NSBox?) { _printBox = outlet }
    @objc(setPrintFormat:) private func connectPrintFormat(_ outlet: NSMatrix?) { _printFormat = outlet }
    @objc(setPrintFrom:) private func connectPrintFrom(_ outlet: NSSlider?) { _printFrom = outlet }
    @objc(setPrintFromText:) private func connectPrintFromText(_ outlet: NSTextField?) { _printFromText = outlet }
    @objc(setPrintInterval:) private func connectPrintInterval(_ outlet: NSSlider?) { _printInterval = outlet }
    @objc(setPrintIntervalText:) private func connectPrintIntervalText(_ outlet: NSTextField?) { _printIntervalText = outlet }
    @objc(setPrintLayout:) private func connectPrintLayout(_ outlet: NSPopUpButton?) { _printLayout = outlet }
    @objc(setPrintPagesToPrint:) private func connectPrintPagesToPrint(_ outlet: NSTextField?) { _printPagesToPrint = outlet }
    @objc(setPrintSelection:) private func connectPrintSelection(_ outlet: NSMatrix?) { _printSelection = outlet }
    @objc(setPrintSettings:) private func connectPrintSettings(_ outlet: NSMatrix?) { _printSettings = outlet }
    @objc(setPrintText:) private func connectPrintText(_ outlet: NSTextField?) { _printText = outlet }
    @objc(setPrintTo:) private func connectPrintTo(_ outlet: NSSlider?) { _printTo = outlet }
    @objc(setPrintToText:) private func connectPrintToText(_ outlet: NSTextField?) { _printToText = outlet }
    @objc(setPrintWindow:) private func connectPrintWindow(_ outlet: NSWindow?) { _printWindow = outlet }
    @objc(setQuicktimeAllViewers:) private func connectQuicktimeAllViewers(_ outlet: NSButton?) { _quicktimeAllViewers = outlet }
    @objc(setQuicktimeBox:) private func connectQuicktimeBox(_ outlet: NSBox?) { _quicktimeBox = outlet }
    @objc(setQuicktimeFrom:) private func connectQuicktimeFrom(_ outlet: NSSlider?) { _quicktimeFrom = outlet }
    @objc(setQuicktimeFromText:) private func connectQuicktimeFromText(_ outlet: NSTextField?) { _quicktimeFromText = outlet }
    @objc(setQuicktimeInterval:) private func connectQuicktimeInterval(_ outlet: NSSlider?) { _quicktimeInterval = outlet }
    @objc(setQuicktimeIntervalText:) private func connectQuicktimeIntervalText(_ outlet: NSTextField?) { _quicktimeIntervalText = outlet }
    @objc(setQuicktimeMode:) private func connectQuicktimeMode(_ outlet: NSMatrix?) { _quicktimeMode = outlet }
    @objc(setQuicktimeNumber:) private func connectQuicktimeNumber(_ outlet: NSTextField?) { _quicktimeNumber = outlet }
    @objc(setQuicktimeTo:) private func connectQuicktimeTo(_ outlet: NSSlider?) { _quicktimeTo = outlet }
    @objc(setQuicktimeToText:) private func connectQuicktimeToText(_ outlet: NSTextField?) { _quicktimeToText = outlet }
    @objc(setQuicktimeWindow:) private func connectQuicktimeWindow(_ outlet: NSWindow?) { _quicktimeWindow = outlet }
    @objc(setRoiApplyMatrix:) private func connectRoiApplyMatrix(_ outlet: NSMatrix?) { _roiApplyMatrix = outlet }
    @objc(setRoiApplyWindow:) private func connectRoiApplyWindow(_ outlet: NSWindow?) { _roiApplyWindow = outlet }
    @objc(setRoiPropaCopy:) private func connectRoiPropaCopy(_ outlet: NSMatrix?) { _roiPropaCopy = outlet }
    @objc(setRoiPropaDest:) private func connectRoiPropaDest(_ outlet: NSTextField?) { _roiPropaDest = outlet }
    @objc(setRoiPropaDim:) private func connectRoiPropaDim(_ outlet: NSMatrix?) { _roiPropaDim = outlet }
    @objc(setRoiPropaMode:) private func connectRoiPropaMode(_ outlet: NSMatrix?) { _roiPropaMode = outlet }
    @objc(setRoiPropaWindow:) private func connectRoiPropaWindow(_ outlet: NSWindow?) { _roiPropaWindow = outlet }
    @objc(setRoiRenameMatrix:) private func connectRoiRenameMatrix(_ outlet: NSMatrix?) { _roiRenameMatrix = outlet }
    @objc(setRoiRenameName:) private func connectRoiRenameName(_ outlet: NSTextField?) { _roiRenameName = outlet }
    @objc(setRoiRenameWindow:) private func connectRoiRenameWindow(_ outlet: NSWindow?) { _roiRenameWindow = outlet }
    @objc(setRoiSetPixWindow:) private func connectRoiSetPixWindow(_ outlet: NSWindow?) { _roiSetPixWindow = outlet }
    @objc(setSaveWindowsStateWindow:) private func connectSaveWindowsStateWindow(_ outlet: NSWindow?) { _saveWindowsStateWindow = outlet }
    @objc(setSetROI4DSeries:) private func connectSetROI4DSeries(_ outlet: NSButton?) { _setROI4DSeries = outlet }
    @objc(setSetWLWWWindow:) private func connectSetWLWWWindow(_ outlet: NSWindow?) { _setWLWWWindow = outlet }
    @objc(setSizeMatrix:) private func connectSizeMatrix(_ outlet: NSMatrix?) { _sizeMatrix = outlet }
    @objc(setStructuringElementRadiusSlider:) private func connectStructuringElementRadiusSlider(_ outlet: NSSlider?) { _structuringElementRadiusSlider = outlet }
    @objc(setStructuringElementRadiusTextField:) private func connectStructuringElementRadiusTextField(_ outlet: NSTextField?) { _structuringElementRadiusTextField = outlet }
    @objc(setSuvConversion:) private func connectSuvConversion(_ outlet: NSMatrix?) { _suvConversion = outlet }
    @objc(setSuvForm:) private func connectSuvForm(_ outlet: HorosFormView?) { _suvFormView = outlet }
    @objc(setThickIntervalWindow:) private func connectThickIntervalWindow(_ outlet: NSWindow?) { _ThickIntervalWindow = outlet }
    @objc(setToset:) private func connectToset(_ outlet: NSTextField?) { _toset = outlet }
    @objc(setWl:) private func connectWl(_ outlet: NSTextField?) { _wl = outlet }
    @objc(setWlset:) private func connectWlset(_ outlet: NSTextField?) { _wlset = outlet }
    @objc(setWw:) private func connectWw(_ outlet: NSTextField?) { _ww = outlet }
    @objc(setWwset:) private func connectWwset(_ outlet: NSTextField?) { _wwset = outlet }
}

extension ViewerController {
    var horos_addCLUTWindow: NSWindow? {
        horosLoadViewerPanels()
        return _addCLUTWindow
    }
    var horos_addConvWindow: NSWindow? {
        horosLoadViewerPanels()
        return _addConvWindow
    }
    var horos_addOpacityWindow: NSWindow? {
        horosLoadViewerPanels()
        return _addOpacityWindow
    }
    var horos_addWLWWWindow: NSWindow? {
        horosLoadViewerPanels()
        return _addWLWWWindow
    }
    var horos_AllROIsRadio: NSMatrix? {
        horosLoadViewerPanels()
        return _AllROIsRadio
    }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingPlugins: NSPopUpButton! { _blendingPlugins }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingResample: NSButton! { _blendingResample }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingTypeMultiply: NSButton! { _blendingTypeMultiply }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingTypeRGB: NSSegmentedControl! { _blendingTypeRGB }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingTypeSubtract: NSButton! { _blendingTypeSubtract }
    var horos_blendingTypeWindow: NSWindow? {
        horosLoadViewerPanels()
        return _blendingTypeWindow
    }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingTypeWindow: NSWindow! { _blendingTypeWindow }
    var horos_brushROIFilterOptionsAllWithSameName: NSButton? {
        horosLoadViewerPanels()
        return _brushROIFilterOptionsAllWithSameName
    }
    var horos_brushROIFilterOptionsWindow: NSWindow? {
        horosLoadViewerPanels()
        return _brushROIFilterOptionsWindow
    }
    var horos_checkMaxValue: NSButton? {
        horosLoadViewerPanels()
        return _checkMaxValue
    }
    var horos_checkMinValue: NSButton? {
        horosLoadViewerPanels()
        return _checkMinValue
    }
    var horos_clutName: NSTextField? {
        horosLoadViewerPanels()
        return _clutName
    }
    var horos_clutView: ColorTransferView? {
        horosLoadViewerPanels()
        return _clutView
    }
    var horos_CommentsEditField: NSTextField? {
        horosLoadViewerPanels()
        return _CommentsEditField
    }
    var horos_CommentsWindow: NSWindow? {
        horosLoadViewerPanels()
        return _CommentsWindow
    }
    var horos_convMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return _convMatrix
    }
    var horos_customInterval: NSTextField? {
        horosLoadViewerPanels()
        return _customInterval
    }
    var horos_customOrigin: NSMatrix? {
        horosLoadViewerPanels()
        return _customOrigin
    }
    var horos_customVectors: NSMatrix? {
        horosLoadViewerPanels()
        return _customVectors
    }
    var horos_customXSpacing: NSTextField? {
        horosLoadViewerPanels()
        return _customXSpacing
    }
    var horos_customYSpacing: NSTextField? {
        horosLoadViewerPanels()
        return _customYSpacing
    }
    var horos_dcmAllViewers: NSButton? {
        horosLoadViewerPanels()
        return _dcmAllViewers
    }
    var horos_dcmBox: NSBox? {
        horosLoadViewerPanels()
        return _dcmBox
    }
    var horos_dcmExportWindow: NSWindow? {
        horosLoadViewerPanels()
        return _dcmExportWindow
    }
    var horos_dcmFormat: NSMatrix? {
        horosLoadViewerPanels()
        return _dcmFormat
    }
    var horos_dcmFrom: NSSlider? {
        horosLoadViewerPanels()
        return _dcmFrom
    }
    var horos_dcmFromText: NSTextField? {
        horosLoadViewerPanels()
        return _dcmFromText
    }
    var horos_dcmInterval: NSSlider? {
        horosLoadViewerPanels()
        return _dcmInterval
    }
    var horos_dcmIntervalText: NSTextField? {
        horosLoadViewerPanels()
        return _dcmIntervalText
    }
    var horos_dcmNumber: NSTextField? {
        horosLoadViewerPanels()
        return _dcmNumber
    }
    var horos_dcmSelection: NSMatrix? {
        horosLoadViewerPanels()
        return _dcmSelection
    }
    var horos_dcmSeriesName: NSTextField? {
        horosLoadViewerPanels()
        return _dcmSeriesName
    }
    var horos_dcmTo: NSSlider? {
        horosLoadViewerPanels()
        return _dcmTo
    }
    var horos_dcmToText: NSTextField? {
        horosLoadViewerPanels()
        return _dcmToText
    }
    var horos_displaySUVWindow: NSWindow? {
        horosLoadViewerPanels()
        return _displaySUVWindow
    }
    var horos_fromset: NSTextField? {
        horosLoadViewerPanels()
        return _fromset
    }
    var horos_imageAllViewers: NSButton? {
        horosLoadViewerPanels()
        return _imageAllViewers
    }
    var horos_imageExportWindow: NSWindow? {
        horosLoadViewerPanels()
        return _imageExportWindow
    }
    var horos_imageFormat: NSMatrix? {
        horosLoadViewerPanels()
        return _imageFormat
    }
    var horos_imageSelection: NSMatrix? {
        horosLoadViewerPanels()
        return _imageSelection
    }
    var horos_injectionTimeWindow: NSWindow? {
        horosLoadViewerPanels()
        return _injectionTimeWindow
    }
    var horos_InOutROI: NSMatrix? {
        horosLoadViewerPanels()
        return _InOutROI
    }
    var horos_matrixName: NSTextField? {
        horosLoadViewerPanels()
        return _matrixName
    }
    var horos_matrixNorm: NSTextField? {
        horosLoadViewerPanels()
        return _matrixNorm
    }
    var horos_maxValueText: NSTextField? {
        horosLoadViewerPanels()
        return _maxValueText
    }
    var horos_minValueText: NSTextField? {
        horosLoadViewerPanels()
        return _minValueText
    }
    var horos_newName: NSTextField? {
        horosLoadViewerPanels()
        return _newName
    }
    var horos_newValueMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return _newValueMatrix
    }
    var horos_newValueText: NSTextField? {
        horosLoadViewerPanels()
        return _newValueText
    }
    var horos_OpacityName: NSTextField? {
        horosLoadViewerPanels()
        return _OpacityName
    }
    var horos_OpacityView: OpacityTransferView? {
        horosLoadViewerPanels()
        return _OpacityView
    }
    var horos_printBox: NSBox? {
        horosLoadViewerPanels()
        return _printBox
    }
    var horos_printFormat: NSMatrix? {
        horosLoadViewerPanels()
        return _printFormat
    }
    var horos_printFrom: NSSlider? {
        horosLoadViewerPanels()
        return _printFrom
    }
    var horos_printFromText: NSTextField? {
        horosLoadViewerPanels()
        return _printFromText
    }
    var horos_printInterval: NSSlider? {
        horosLoadViewerPanels()
        return _printInterval
    }
    var horos_printIntervalText: NSTextField? {
        horosLoadViewerPanels()
        return _printIntervalText
    }
    var horos_printLayout: NSPopUpButton? {
        horosLoadViewerPanels()
        return _printLayout
    }
    var horos_printPagesToPrint: NSTextField? {
        horosLoadViewerPanels()
        return _printPagesToPrint
    }
    var horos_printSelection: NSMatrix? {
        horosLoadViewerPanels()
        return _printSelection
    }
    var horos_printSettings: NSMatrix? {
        horosLoadViewerPanels()
        return _printSettings
    }
    var horos_printText: NSTextField? {
        horosLoadViewerPanels()
        return _printText
    }
    var horos_printTo: NSSlider? {
        horosLoadViewerPanels()
        return _printTo
    }
    var horos_printToText: NSTextField? {
        horosLoadViewerPanels()
        return _printToText
    }
    var horos_printWindow: NSWindow? {
        horosLoadViewerPanels()
        return _printWindow
    }
    var horos_quicktimeAllViewers: NSButton? {
        horosLoadViewerPanels()
        return _quicktimeAllViewers
    }
    var horos_quicktimeBox: NSBox? {
        horosLoadViewerPanels()
        return _quicktimeBox
    }
    var horos_quicktimeFrom: NSSlider? {
        horosLoadViewerPanels()
        return _quicktimeFrom
    }
    var horos_quicktimeFromText: NSTextField? {
        horosLoadViewerPanels()
        return _quicktimeFromText
    }
    var horos_quicktimeInterval: NSSlider? {
        horosLoadViewerPanels()
        return _quicktimeInterval
    }
    var horos_quicktimeIntervalText: NSTextField? {
        horosLoadViewerPanels()
        return _quicktimeIntervalText
    }
    var horos_quicktimeMode: NSMatrix? {
        horosLoadViewerPanels()
        return _quicktimeMode
    }
    var horos_quicktimeNumber: NSTextField? {
        horosLoadViewerPanels()
        return _quicktimeNumber
    }
    var horos_quicktimeTo: NSSlider? {
        horosLoadViewerPanels()
        return _quicktimeTo
    }
    var horos_quicktimeToText: NSTextField? {
        horosLoadViewerPanels()
        return _quicktimeToText
    }
    var horos_quicktimeWindow: NSWindow? {
        horosLoadViewerPanels()
        return _quicktimeWindow
    }
    var horos_roiApplyMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return _roiApplyMatrix
    }
    var horos_roiApplyWindow: NSWindow? {
        horosLoadViewerPanels()
        return _roiApplyWindow
    }
    var horos_roiPropaCopy: NSMatrix? {
        horosLoadViewerPanels()
        return _roiPropaCopy
    }
    var horos_roiPropaDest: NSTextField? {
        horosLoadViewerPanels()
        return _roiPropaDest
    }
    var horos_roiPropaDim: NSMatrix? {
        horosLoadViewerPanels()
        return _roiPropaDim
    }
    var horos_roiPropaMode: NSMatrix? {
        horosLoadViewerPanels()
        return _roiPropaMode
    }
    var horos_roiPropaWindow: NSWindow? {
        horosLoadViewerPanels()
        return _roiPropaWindow
    }
    var horos_roiRenameMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return _roiRenameMatrix
    }
    var horos_roiRenameName: NSTextField? {
        horosLoadViewerPanels()
        return _roiRenameName
    }
    var horos_roiRenameWindow: NSWindow? {
        horosLoadViewerPanels()
        return _roiRenameWindow
    }
    var horos_roiSetPixWindow: NSWindow? {
        horosLoadViewerPanels()
        return _roiSetPixWindow
    }
    var horos_saveWindowsStateWindow: NSWindow? {
        horosLoadViewerPanels()
        return _saveWindowsStateWindow
    }
    var horos_setROI4DSeries: NSButton? {
        horosLoadViewerPanels()
        return _setROI4DSeries
    }
    var horos_setWLWWWindow: NSWindow? {
        horosLoadViewerPanels()
        return _setWLWWWindow
    }
    var horos_sizeMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return _sizeMatrix
    }
    var horos_structuringElementRadiusSlider: NSSlider? {
        horosLoadViewerPanels()
        return _structuringElementRadiusSlider
    }
    var horos_structuringElementRadiusTextField: NSTextField? {
        horosLoadViewerPanels()
        return _structuringElementRadiusTextField
    }
    var horos_suvConversion: NSMatrix? {
        horosLoadViewerPanels()
        return _suvConversion
    }
    var horos_suvForm: HorosFormView? {
        horosLoadViewerPanels()
        return _suvFormView
    }
    var horos_ThickIntervalWindow: NSWindow? {
        horosLoadViewerPanels()
        return _ThickIntervalWindow
    }
    var horos_toset: NSTextField? {
        horosLoadViewerPanels()
        return _toset
    }
    var horos_wl: NSTextField? {
        horosLoadViewerPanels()
        return _wl
    }
    var horos_wlset: NSTextField? {
        horosLoadViewerPanels()
        return _wlset
    }
    var horos_ww: NSTextField? {
        horosLoadViewerPanels()
        return _ww
    }
    var horos_wwset: NSTextField? {
        horosLoadViewerPanels()
        return _wwset
    }

    /// Enables or disables `aView`'s controls: a control itself, or every
    /// control among its subviews.
    @objc(checkView::)
    func check(_ aView: NSView!, _ OnOff: Bool) {
        if let control = aView as? NSControl {
            control.isEnabled = OnOff
            return
        }
        // Recursively check all the subviews in the view
        for view in aView?.subviews ?? [] {
            check(view, OnOff)
        }
    }
}

// MARK: - Binding teardown

enum ViewerPanelOutletRoots {
    /// Every outlet, nil ones included: the views, windows and toolbars among
    /// them are where the nib's File's Owner bindings live.
    @MainActor static func roots(of viewer: ViewerController) -> [AnyObject?] {
        [
            viewer._addCLUTWindow,
            viewer._addConvWindow,
            viewer._addOpacityWindow,
            viewer._addWLWWWindow,
            viewer._AllROIsRadio,
            viewer._blendingPlugins,
            viewer._blendingResample,
            viewer._blendingTypeMultiply,
            viewer._blendingTypeRGB,
            viewer._blendingTypeSubtract,
            viewer._blendingTypeWindow,
            viewer._brushROIFilterOptionsAllWithSameName,
            viewer._brushROIFilterOptionsOKButton,
            viewer._brushROIFilterOptionsWindow,
            viewer._checkMaxValue,
            viewer._checkMinValue,
            viewer._clutName,
            viewer._clutView,
            viewer._CommentsEditField,
            viewer._CommentsWindow,
            viewer._convMatrix,
            viewer._customInterval,
            viewer._customOrigin,
            viewer._customVectors,
            viewer._customXSpacing,
            viewer._customYSpacing,
            viewer._dcmAllViewers,
            viewer._dcmBox,
            viewer._dcmExportWindow,
            viewer._dcmFormat,
            viewer._dcmFrom,
            viewer._dcmFromText,
            viewer._dcmInterval,
            viewer._dcmIntervalText,
            viewer._dcmNumber,
            viewer._dcmSelection,
            viewer._dcmSeriesName,
            viewer._dcmTo,
            viewer._dcmToText,
            viewer._displaySUVWindow,
            viewer._fromset,
            viewer._imageAllViewers,
            viewer._imageExportWindow,
            viewer._imageFormat,
            viewer._imageSelection,
            viewer._injectionTimeWindow,
            viewer._InOutROI,
            viewer._matrixName,
            viewer._matrixNorm,
            viewer._maxValueText,
            viewer._minValueText,
            viewer._newName,
            viewer._newValueMatrix,
            viewer._newValueText,
            viewer._OpacityName,
            viewer._OpacityView,
            viewer._printBox,
            viewer._printFormat,
            viewer._printFrom,
            viewer._printFromText,
            viewer._printInterval,
            viewer._printIntervalText,
            viewer._printLayout,
            viewer._printPagesToPrint,
            viewer._printSelection,
            viewer._printSettings,
            viewer._printText,
            viewer._printTo,
            viewer._printToText,
            viewer._printWindow,
            viewer._quicktimeAllViewers,
            viewer._quicktimeBox,
            viewer._quicktimeFrom,
            viewer._quicktimeFromText,
            viewer._quicktimeInterval,
            viewer._quicktimeIntervalText,
            viewer._quicktimeMode,
            viewer._quicktimeNumber,
            viewer._quicktimeTo,
            viewer._quicktimeToText,
            viewer._quicktimeWindow,
            viewer._roiApplyMatrix,
            viewer._roiApplyWindow,
            viewer._roiPropaCopy,
            viewer._roiPropaDest,
            viewer._roiPropaDim,
            viewer._roiPropaMode,
            viewer._roiPropaWindow,
            viewer._roiRenameMatrix,
            viewer._roiRenameName,
            viewer._roiRenameWindow,
            viewer._roiSetPixWindow,
            viewer._saveWindowsStateWindow,
            viewer._setROI4DSeries,
            viewer._setWLWWWindow,
            viewer._sizeMatrix,
            viewer._structuringElementRadiusSlider,
            viewer._structuringElementRadiusTextField,
            viewer._suvConversion,
            viewer._suvFormView,
            viewer._ThickIntervalWindow,
            viewer._toset,
            viewer._wl,
            viewer._wlset,
            viewer._ww,
            viewer._wwset,
        ]
    }
}
