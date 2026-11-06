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

/// The outlets of ViewerPanels.nib, loaded on demand with the viewer as owner: kept as the nib sets them, without a retain (the panels the viewer keeps keep them). Reading one through its horos_ accessor loads the panels first.
final class ViewerPanelOutlets: @unchecked Sendable {
    unowned(unsafe) var addCLUTWindow: NSWindow?
    unowned(unsafe) var addConvWindow: NSWindow?
    unowned(unsafe) var addOpacityWindow: NSWindow?
    unowned(unsafe) var addWLWWWindow: NSWindow?
    unowned(unsafe) var AllROIsRadio: NSMatrix?
    unowned(unsafe) var blendingPlugins: NSPopUpButton?
    unowned(unsafe) var blendingResample: NSButton?
    unowned(unsafe) var blendingTypeMultiply: NSButton?
    unowned(unsafe) var blendingTypeRGB: NSSegmentedControl?
    unowned(unsafe) var blendingTypeSubtract: NSButton?
    unowned(unsafe) var blendingTypeWindow: NSWindow?
    unowned(unsafe) var brushROIFilterOptionsAllWithSameName: NSButton?
    unowned(unsafe) var brushROIFilterOptionsOKButton: NSButton?
    unowned(unsafe) var brushROIFilterOptionsWindow: NSWindow?
    unowned(unsafe) var checkMaxValue: NSButton?
    unowned(unsafe) var checkMinValue: NSButton?
    unowned(unsafe) var clutName: NSTextField?
    unowned(unsafe) var clutView: ColorTransferView?
    unowned(unsafe) var CommentsEditField: NSTextField?
    unowned(unsafe) var CommentsWindow: NSWindow?
    unowned(unsafe) var convMatrix: NSMatrix?
    unowned(unsafe) var customInterval: NSTextField?
    unowned(unsafe) var customOrigin: NSMatrix?
    unowned(unsafe) var customVectors: NSMatrix?
    unowned(unsafe) var customXSpacing: NSTextField?
    unowned(unsafe) var customYSpacing: NSTextField?
    unowned(unsafe) var dcmAllViewers: NSButton?
    unowned(unsafe) var dcmBox: NSBox?
    unowned(unsafe) var dcmExportWindow: NSWindow?
    unowned(unsafe) var dcmFormat: NSMatrix?
    unowned(unsafe) var dcmFrom: NSSlider?
    unowned(unsafe) var dcmFromText: NSTextField?
    unowned(unsafe) var dcmInterval: NSSlider?
    unowned(unsafe) var dcmIntervalText: NSTextField?
    unowned(unsafe) var dcmNumber: NSTextField?
    unowned(unsafe) var dcmSelection: NSMatrix?
    unowned(unsafe) var dcmSeriesName: NSTextField?
    unowned(unsafe) var dcmTo: NSSlider?
    unowned(unsafe) var dcmToText: NSTextField?
    unowned(unsafe) var displaySUVWindow: NSWindow?
    unowned(unsafe) var fromset: NSTextField?
    unowned(unsafe) var imageAllViewers: NSButton?
    unowned(unsafe) var imageExportWindow: NSWindow?
    unowned(unsafe) var imageFormat: NSMatrix?
    unowned(unsafe) var imageSelection: NSMatrix?
    unowned(unsafe) var injectionTimeWindow: NSWindow?
    unowned(unsafe) var InOutROI: NSMatrix?
    unowned(unsafe) var matrixName: NSTextField?
    unowned(unsafe) var matrixNorm: NSTextField?
    unowned(unsafe) var maxValueText: NSTextField?
    unowned(unsafe) var minValueText: NSTextField?
    unowned(unsafe) var newName: NSTextField?
    unowned(unsafe) var newValueMatrix: NSMatrix?
    unowned(unsafe) var newValueText: NSTextField?
    unowned(unsafe) var OpacityName: NSTextField?
    unowned(unsafe) var OpacityView: OpacityTransferView?
    unowned(unsafe) var printBox: NSBox?
    unowned(unsafe) var printFormat: NSMatrix?
    unowned(unsafe) var printFrom: NSSlider?
    unowned(unsafe) var printFromText: NSTextField?
    unowned(unsafe) var printInterval: NSSlider?
    unowned(unsafe) var printIntervalText: NSTextField?
    unowned(unsafe) var printLayout: NSPopUpButton?
    unowned(unsafe) var printPagesToPrint: NSTextField?
    unowned(unsafe) var printSelection: NSMatrix?
    unowned(unsafe) var printSettings: NSMatrix?
    unowned(unsafe) var printText: NSTextField?
    unowned(unsafe) var printTo: NSSlider?
    unowned(unsafe) var printToText: NSTextField?
    unowned(unsafe) var printWindow: NSWindow?
    unowned(unsafe) var quicktimeAllViewers: NSButton?
    unowned(unsafe) var quicktimeBox: NSBox?
    unowned(unsafe) var quicktimeFrom: NSSlider?
    unowned(unsafe) var quicktimeFromText: NSTextField?
    unowned(unsafe) var quicktimeInterval: NSSlider?
    unowned(unsafe) var quicktimeIntervalText: NSTextField?
    unowned(unsafe) var quicktimeMode: NSMatrix?
    unowned(unsafe) var quicktimeNumber: NSTextField?
    unowned(unsafe) var quicktimeTo: NSSlider?
    unowned(unsafe) var quicktimeToText: NSTextField?
    unowned(unsafe) var quicktimeWindow: NSWindow?
    unowned(unsafe) var roiApplyMatrix: NSMatrix?
    unowned(unsafe) var roiApplyWindow: NSWindow?
    unowned(unsafe) var roiPropaCopy: NSMatrix?
    unowned(unsafe) var roiPropaDest: NSTextField?
    unowned(unsafe) var roiPropaDim: NSMatrix?
    unowned(unsafe) var roiPropaMode: NSMatrix?
    unowned(unsafe) var roiPropaWindow: NSWindow?
    unowned(unsafe) var roiRenameMatrix: NSMatrix?
    unowned(unsafe) var roiRenameName: NSTextField?
    unowned(unsafe) var roiRenameWindow: NSWindow?
    unowned(unsafe) var roiSetPixWindow: NSWindow?
    unowned(unsafe) var saveWindowsStateWindow: NSWindow?
    unowned(unsafe) var setROI4DSeries: NSButton?
    unowned(unsafe) var setWLWWWindow: NSWindow?
    unowned(unsafe) var sizeMatrix: NSMatrix?
    unowned(unsafe) var structuringElementRadiusSlider: NSSlider?
    unowned(unsafe) var structuringElementRadiusTextField: NSTextField?
    unowned(unsafe) var suvConversion: NSMatrix?
    unowned(unsafe) var suvForm: HorosFormView?
    unowned(unsafe) var ThickIntervalWindow: NSWindow?
    unowned(unsafe) var toset: NSTextField?
    unowned(unsafe) var wl: NSTextField?
    unowned(unsafe) var wlset: NSTextField?
    unowned(unsafe) var ww: NSTextField?
    unowned(unsafe) var wwset: NSTextField?
}

// The connections of the nib, which sets each outlet through -set<Outlet>:.
extension ViewerController {
    @objc(setAddCLUTWindow:) private func connectAddCLUTWindow(_ outlet: NSWindow?) { panelOutlets.addCLUTWindow = outlet }
    @objc(setAddConvWindow:) private func connectAddConvWindow(_ outlet: NSWindow?) { panelOutlets.addConvWindow = outlet }
    @objc(setAddOpacityWindow:) private func connectAddOpacityWindow(_ outlet: NSWindow?) { panelOutlets.addOpacityWindow = outlet }
    @objc(setAddWLWWWindow:) private func connectAddWLWWWindow(_ outlet: NSWindow?) { panelOutlets.addWLWWWindow = outlet }
    @objc(setAllROIsRadio:) private func connectAllROIsRadio(_ outlet: NSMatrix?) { panelOutlets.AllROIsRadio = outlet }
    @objc(setBlendingPlugins:) private func connectBlendingPlugins(_ outlet: NSPopUpButton?) { panelOutlets.blendingPlugins = outlet }
    @objc(setBlendingResample:) private func connectBlendingResample(_ outlet: NSButton?) { panelOutlets.blendingResample = outlet }
    @objc(setBlendingTypeMultiply:) private func connectBlendingTypeMultiply(_ outlet: NSButton?) { panelOutlets.blendingTypeMultiply = outlet }
    @objc(setBlendingTypeRGB:) private func connectBlendingTypeRGB(_ outlet: NSSegmentedControl?) { panelOutlets.blendingTypeRGB = outlet }
    @objc(setBlendingTypeSubtract:) private func connectBlendingTypeSubtract(_ outlet: NSButton?) { panelOutlets.blendingTypeSubtract = outlet }
    @objc(setBlendingTypeWindow:) private func connectBlendingTypeWindow(_ outlet: NSWindow?) { panelOutlets.blendingTypeWindow = outlet }
    @objc(setBrushROIFilterOptionsAllWithSameName:) private func connectBrushROIFilterOptionsAllWithSameName(_ outlet: NSButton?) { panelOutlets.brushROIFilterOptionsAllWithSameName = outlet }
    @objc(setBrushROIFilterOptionsOKButton:) private func connectBrushROIFilterOptionsOKButton(_ outlet: NSButton?) { panelOutlets.brushROIFilterOptionsOKButton = outlet }
    @objc(setBrushROIFilterOptionsWindow:) private func connectBrushROIFilterOptionsWindow(_ outlet: NSWindow?) { panelOutlets.brushROIFilterOptionsWindow = outlet }
    @objc(setCheckMaxValue:) private func connectCheckMaxValue(_ outlet: NSButton?) { panelOutlets.checkMaxValue = outlet }
    @objc(setCheckMinValue:) private func connectCheckMinValue(_ outlet: NSButton?) { panelOutlets.checkMinValue = outlet }
    @objc(setClutName:) private func connectClutName(_ outlet: NSTextField?) { panelOutlets.clutName = outlet }
    @objc(setClutView:) private func connectClutView(_ outlet: ColorTransferView?) { panelOutlets.clutView = outlet }
    @objc(setCommentsEditField:) private func connectCommentsEditField(_ outlet: NSTextField?) { panelOutlets.CommentsEditField = outlet }
    @objc(setCommentsWindow:) private func connectCommentsWindow(_ outlet: NSWindow?) { panelOutlets.CommentsWindow = outlet }
    @objc(setConvMatrix:) private func connectConvMatrix(_ outlet: NSMatrix?) { panelOutlets.convMatrix = outlet }
    @objc(setCustomInterval:) private func connectCustomInterval(_ outlet: NSTextField?) { panelOutlets.customInterval = outlet }
    @objc(setCustomOrigin:) private func connectCustomOrigin(_ outlet: NSMatrix?) { panelOutlets.customOrigin = outlet }
    @objc(setCustomVectors:) private func connectCustomVectors(_ outlet: NSMatrix?) { panelOutlets.customVectors = outlet }
    @objc(setCustomXSpacing:) private func connectCustomXSpacing(_ outlet: NSTextField?) { panelOutlets.customXSpacing = outlet }
    @objc(setCustomYSpacing:) private func connectCustomYSpacing(_ outlet: NSTextField?) { panelOutlets.customYSpacing = outlet }
    @objc(setDcmAllViewers:) private func connectDcmAllViewers(_ outlet: NSButton?) { panelOutlets.dcmAllViewers = outlet }
    @objc(setDcmBox:) private func connectDcmBox(_ outlet: NSBox?) { panelOutlets.dcmBox = outlet }
    @objc(setDcmExportWindow:) private func connectDcmExportWindow(_ outlet: NSWindow?) { panelOutlets.dcmExportWindow = outlet }
    @objc(setDcmFormat:) private func connectDcmFormat(_ outlet: NSMatrix?) { panelOutlets.dcmFormat = outlet }
    @objc(setDcmFrom:) private func connectDcmFrom(_ outlet: NSSlider?) { panelOutlets.dcmFrom = outlet }
    @objc(setDcmFromText:) private func connectDcmFromText(_ outlet: NSTextField?) { panelOutlets.dcmFromText = outlet }
    @objc(setDcmInterval:) private func connectDcmInterval(_ outlet: NSSlider?) { panelOutlets.dcmInterval = outlet }
    @objc(setDcmIntervalText:) private func connectDcmIntervalText(_ outlet: NSTextField?) { panelOutlets.dcmIntervalText = outlet }
    @objc(setDcmNumber:) private func connectDcmNumber(_ outlet: NSTextField?) { panelOutlets.dcmNumber = outlet }
    @objc(setDcmSelection:) private func connectDcmSelection(_ outlet: NSMatrix?) { panelOutlets.dcmSelection = outlet }
    @objc(setDcmSeriesName:) private func connectDcmSeriesName(_ outlet: NSTextField?) { panelOutlets.dcmSeriesName = outlet }
    @objc(setDcmTo:) private func connectDcmTo(_ outlet: NSSlider?) { panelOutlets.dcmTo = outlet }
    @objc(setDcmToText:) private func connectDcmToText(_ outlet: NSTextField?) { panelOutlets.dcmToText = outlet }
    @objc(setDisplaySUVWindow:) private func connectDisplaySUVWindow(_ outlet: NSWindow?) { panelOutlets.displaySUVWindow = outlet }
    @objc(setFromset:) private func connectFromset(_ outlet: NSTextField?) { panelOutlets.fromset = outlet }
    @objc(setImageAllViewers:) private func connectImageAllViewers(_ outlet: NSButton?) { panelOutlets.imageAllViewers = outlet }
    @objc(setImageExportWindow:) private func connectImageExportWindow(_ outlet: NSWindow?) { panelOutlets.imageExportWindow = outlet }
    @objc(setImageFormat:) private func connectImageFormat(_ outlet: NSMatrix?) { panelOutlets.imageFormat = outlet }
    @objc(setImageSelection:) private func connectImageSelection(_ outlet: NSMatrix?) { panelOutlets.imageSelection = outlet }
    @objc(setInjectionTimeWindow:) private func connectInjectionTimeWindow(_ outlet: NSWindow?) { panelOutlets.injectionTimeWindow = outlet }
    @objc(setInOutROI:) private func connectInOutROI(_ outlet: NSMatrix?) { panelOutlets.InOutROI = outlet }
    @objc(setMatrixName:) private func connectMatrixName(_ outlet: NSTextField?) { panelOutlets.matrixName = outlet }
    @objc(setMatrixNorm:) private func connectMatrixNorm(_ outlet: NSTextField?) { panelOutlets.matrixNorm = outlet }
    @objc(setMaxValueText:) private func connectMaxValueText(_ outlet: NSTextField?) { panelOutlets.maxValueText = outlet }
    @objc(setMinValueText:) private func connectMinValueText(_ outlet: NSTextField?) { panelOutlets.minValueText = outlet }
    @objc(setNewName:) private func connectNewName(_ outlet: NSTextField?) { panelOutlets.newName = outlet }
    @objc(setNewValueMatrix:) private func connectNewValueMatrix(_ outlet: NSMatrix?) { panelOutlets.newValueMatrix = outlet }
    @objc(setNewValueText:) private func connectNewValueText(_ outlet: NSTextField?) { panelOutlets.newValueText = outlet }
    @objc(setOpacityName:) private func connectOpacityName(_ outlet: NSTextField?) { panelOutlets.OpacityName = outlet }
    @objc(setOpacityView:) private func connectOpacityView(_ outlet: OpacityTransferView?) { panelOutlets.OpacityView = outlet }
    @objc(setPrintBox:) private func connectPrintBox(_ outlet: NSBox?) { panelOutlets.printBox = outlet }
    @objc(setPrintFormat:) private func connectPrintFormat(_ outlet: NSMatrix?) { panelOutlets.printFormat = outlet }
    @objc(setPrintFrom:) private func connectPrintFrom(_ outlet: NSSlider?) { panelOutlets.printFrom = outlet }
    @objc(setPrintFromText:) private func connectPrintFromText(_ outlet: NSTextField?) { panelOutlets.printFromText = outlet }
    @objc(setPrintInterval:) private func connectPrintInterval(_ outlet: NSSlider?) { panelOutlets.printInterval = outlet }
    @objc(setPrintIntervalText:) private func connectPrintIntervalText(_ outlet: NSTextField?) { panelOutlets.printIntervalText = outlet }
    @objc(setPrintLayout:) private func connectPrintLayout(_ outlet: NSPopUpButton?) { panelOutlets.printLayout = outlet }
    @objc(setPrintPagesToPrint:) private func connectPrintPagesToPrint(_ outlet: NSTextField?) { panelOutlets.printPagesToPrint = outlet }
    @objc(setPrintSelection:) private func connectPrintSelection(_ outlet: NSMatrix?) { panelOutlets.printSelection = outlet }
    @objc(setPrintSettings:) private func connectPrintSettings(_ outlet: NSMatrix?) { panelOutlets.printSettings = outlet }
    @objc(setPrintText:) private func connectPrintText(_ outlet: NSTextField?) { panelOutlets.printText = outlet }
    @objc(setPrintTo:) private func connectPrintTo(_ outlet: NSSlider?) { panelOutlets.printTo = outlet }
    @objc(setPrintToText:) private func connectPrintToText(_ outlet: NSTextField?) { panelOutlets.printToText = outlet }
    @objc(setPrintWindow:) private func connectPrintWindow(_ outlet: NSWindow?) { panelOutlets.printWindow = outlet }
    @objc(setQuicktimeAllViewers:) private func connectQuicktimeAllViewers(_ outlet: NSButton?) { panelOutlets.quicktimeAllViewers = outlet }
    @objc(setQuicktimeBox:) private func connectQuicktimeBox(_ outlet: NSBox?) { panelOutlets.quicktimeBox = outlet }
    @objc(setQuicktimeFrom:) private func connectQuicktimeFrom(_ outlet: NSSlider?) { panelOutlets.quicktimeFrom = outlet }
    @objc(setQuicktimeFromText:) private func connectQuicktimeFromText(_ outlet: NSTextField?) { panelOutlets.quicktimeFromText = outlet }
    @objc(setQuicktimeInterval:) private func connectQuicktimeInterval(_ outlet: NSSlider?) { panelOutlets.quicktimeInterval = outlet }
    @objc(setQuicktimeIntervalText:) private func connectQuicktimeIntervalText(_ outlet: NSTextField?) { panelOutlets.quicktimeIntervalText = outlet }
    @objc(setQuicktimeMode:) private func connectQuicktimeMode(_ outlet: NSMatrix?) { panelOutlets.quicktimeMode = outlet }
    @objc(setQuicktimeNumber:) private func connectQuicktimeNumber(_ outlet: NSTextField?) { panelOutlets.quicktimeNumber = outlet }
    @objc(setQuicktimeTo:) private func connectQuicktimeTo(_ outlet: NSSlider?) { panelOutlets.quicktimeTo = outlet }
    @objc(setQuicktimeToText:) private func connectQuicktimeToText(_ outlet: NSTextField?) { panelOutlets.quicktimeToText = outlet }
    @objc(setQuicktimeWindow:) private func connectQuicktimeWindow(_ outlet: NSWindow?) { panelOutlets.quicktimeWindow = outlet }
    @objc(setRoiApplyMatrix:) private func connectRoiApplyMatrix(_ outlet: NSMatrix?) { panelOutlets.roiApplyMatrix = outlet }
    @objc(setRoiApplyWindow:) private func connectRoiApplyWindow(_ outlet: NSWindow?) { panelOutlets.roiApplyWindow = outlet }
    @objc(setRoiPropaCopy:) private func connectRoiPropaCopy(_ outlet: NSMatrix?) { panelOutlets.roiPropaCopy = outlet }
    @objc(setRoiPropaDest:) private func connectRoiPropaDest(_ outlet: NSTextField?) { panelOutlets.roiPropaDest = outlet }
    @objc(setRoiPropaDim:) private func connectRoiPropaDim(_ outlet: NSMatrix?) { panelOutlets.roiPropaDim = outlet }
    @objc(setRoiPropaMode:) private func connectRoiPropaMode(_ outlet: NSMatrix?) { panelOutlets.roiPropaMode = outlet }
    @objc(setRoiPropaWindow:) private func connectRoiPropaWindow(_ outlet: NSWindow?) { panelOutlets.roiPropaWindow = outlet }
    @objc(setRoiRenameMatrix:) private func connectRoiRenameMatrix(_ outlet: NSMatrix?) { panelOutlets.roiRenameMatrix = outlet }
    @objc(setRoiRenameName:) private func connectRoiRenameName(_ outlet: NSTextField?) { panelOutlets.roiRenameName = outlet }
    @objc(setRoiRenameWindow:) private func connectRoiRenameWindow(_ outlet: NSWindow?) { panelOutlets.roiRenameWindow = outlet }
    @objc(setRoiSetPixWindow:) private func connectRoiSetPixWindow(_ outlet: NSWindow?) { panelOutlets.roiSetPixWindow = outlet }
    @objc(setSaveWindowsStateWindow:) private func connectSaveWindowsStateWindow(_ outlet: NSWindow?) { panelOutlets.saveWindowsStateWindow = outlet }
    @objc(setSetROI4DSeries:) private func connectSetROI4DSeries(_ outlet: NSButton?) { panelOutlets.setROI4DSeries = outlet }
    @objc(setSetWLWWWindow:) private func connectSetWLWWWindow(_ outlet: NSWindow?) { panelOutlets.setWLWWWindow = outlet }
    @objc(setSizeMatrix:) private func connectSizeMatrix(_ outlet: NSMatrix?) { panelOutlets.sizeMatrix = outlet }
    @objc(setStructuringElementRadiusSlider:) private func connectStructuringElementRadiusSlider(_ outlet: NSSlider?) { panelOutlets.structuringElementRadiusSlider = outlet }
    @objc(setStructuringElementRadiusTextField:) private func connectStructuringElementRadiusTextField(_ outlet: NSTextField?) { panelOutlets.structuringElementRadiusTextField = outlet }
    @objc(setSuvConversion:) private func connectSuvConversion(_ outlet: NSMatrix?) { panelOutlets.suvConversion = outlet }
    @objc(setSuvForm:) private func connectSuvForm(_ outlet: HorosFormView?) { panelOutlets.suvForm = outlet }
    @objc(setThickIntervalWindow:) private func connectThickIntervalWindow(_ outlet: NSWindow?) { panelOutlets.ThickIntervalWindow = outlet }
    @objc(setToset:) private func connectToset(_ outlet: NSTextField?) { panelOutlets.toset = outlet }
    @objc(setWl:) private func connectWl(_ outlet: NSTextField?) { panelOutlets.wl = outlet }
    @objc(setWlset:) private func connectWlset(_ outlet: NSTextField?) { panelOutlets.wlset = outlet }
    @objc(setWw:) private func connectWw(_ outlet: NSTextField?) { panelOutlets.ww = outlet }
    @objc(setWwset:) private func connectWwset(_ outlet: NSTextField?) { panelOutlets.wwset = outlet }
}

extension ViewerController {
    var horos_addCLUTWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.addCLUTWindow
    }
    var horos_addConvWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.addConvWindow
    }
    var horos_addOpacityWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.addOpacityWindow
    }
    var horos_addWLWWWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.addWLWWWindow
    }
    var horos_AllROIsRadio: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.AllROIsRadio
    }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingPlugins: NSPopUpButton! { panelOutlets.blendingPlugins }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingResample: NSButton! { panelOutlets.blendingResample }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingTypeMultiply: NSButton! { panelOutlets.blendingTypeMultiply }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingTypeRGB: NSSegmentedControl! { panelOutlets.blendingTypeRGB }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingTypeSubtract: NSButton! { panelOutlets.blendingTypeSubtract }
    var horos_blendingTypeWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.blendingTypeWindow
    }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var blendingTypeWindow: NSWindow! { panelOutlets.blendingTypeWindow }
    var horos_brushROIFilterOptionsAllWithSameName: NSButton? {
        horosLoadViewerPanels()
        return panelOutlets.brushROIFilterOptionsAllWithSameName
    }
    var horos_brushROIFilterOptionsWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.brushROIFilterOptionsWindow
    }
    var horos_checkMaxValue: NSButton? {
        horosLoadViewerPanels()
        return panelOutlets.checkMaxValue
    }
    var horos_checkMinValue: NSButton? {
        horosLoadViewerPanels()
        return panelOutlets.checkMinValue
    }
    var horos_clutName: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.clutName
    }
    var horos_clutView: ColorTransferView? {
        horosLoadViewerPanels()
        return panelOutlets.clutView
    }
    var horos_CommentsEditField: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.CommentsEditField
    }
    var horos_CommentsWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.CommentsWindow
    }
    var horos_convMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.convMatrix
    }
    var horos_customInterval: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.customInterval
    }
    var horos_customOrigin: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.customOrigin
    }
    var horos_customVectors: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.customVectors
    }
    var horos_customXSpacing: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.customXSpacing
    }
    var horos_customYSpacing: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.customYSpacing
    }
    var horos_dcmAllViewers: NSButton? {
        horosLoadViewerPanels()
        return panelOutlets.dcmAllViewers
    }
    var horos_dcmBox: NSBox? {
        horosLoadViewerPanels()
        return panelOutlets.dcmBox
    }
    var horos_dcmExportWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.dcmExportWindow
    }
    var horos_dcmFormat: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.dcmFormat
    }
    var horos_dcmFrom: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.dcmFrom
    }
    var horos_dcmFromText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.dcmFromText
    }
    var horos_dcmInterval: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.dcmInterval
    }
    var horos_dcmIntervalText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.dcmIntervalText
    }
    var horos_dcmNumber: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.dcmNumber
    }
    var horos_dcmSelection: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.dcmSelection
    }
    var horos_dcmSeriesName: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.dcmSeriesName
    }
    var horos_dcmTo: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.dcmTo
    }
    var horos_dcmToText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.dcmToText
    }
    var horos_displaySUVWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.displaySUVWindow
    }
    var horos_fromset: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.fromset
    }
    var horos_imageAllViewers: NSButton? {
        horosLoadViewerPanels()
        return panelOutlets.imageAllViewers
    }
    var horos_imageExportWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.imageExportWindow
    }
    var horos_imageFormat: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.imageFormat
    }
    var horos_imageSelection: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.imageSelection
    }
    var horos_injectionTimeWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.injectionTimeWindow
    }
    var horos_InOutROI: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.InOutROI
    }
    var horos_matrixName: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.matrixName
    }
    var horos_matrixNorm: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.matrixNorm
    }
    var horos_maxValueText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.maxValueText
    }
    var horos_minValueText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.minValueText
    }
    var horos_newName: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.newName
    }
    var horos_newValueMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.newValueMatrix
    }
    var horos_newValueText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.newValueText
    }
    var horos_OpacityName: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.OpacityName
    }
    var horos_OpacityView: OpacityTransferView? {
        horosLoadViewerPanels()
        return panelOutlets.OpacityView
    }
    var horos_printBox: NSBox? {
        horosLoadViewerPanels()
        return panelOutlets.printBox
    }
    var horos_printFormat: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.printFormat
    }
    var horos_printFrom: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.printFrom
    }
    var horos_printFromText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.printFromText
    }
    var horos_printInterval: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.printInterval
    }
    var horos_printIntervalText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.printIntervalText
    }
    var horos_printLayout: NSPopUpButton? {
        horosLoadViewerPanels()
        return panelOutlets.printLayout
    }
    var horos_printPagesToPrint: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.printPagesToPrint
    }
    var horos_printSelection: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.printSelection
    }
    var horos_printSettings: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.printSettings
    }
    var horos_printText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.printText
    }
    var horos_printTo: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.printTo
    }
    var horos_printToText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.printToText
    }
    var horos_printWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.printWindow
    }
    var horos_quicktimeAllViewers: NSButton? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeAllViewers
    }
    var horos_quicktimeBox: NSBox? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeBox
    }
    var horos_quicktimeFrom: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeFrom
    }
    var horos_quicktimeFromText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeFromText
    }
    var horos_quicktimeInterval: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeInterval
    }
    var horos_quicktimeIntervalText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeIntervalText
    }
    var horos_quicktimeMode: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeMode
    }
    var horos_quicktimeNumber: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeNumber
    }
    var horos_quicktimeTo: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeTo
    }
    var horos_quicktimeToText: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeToText
    }
    var horos_quicktimeWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.quicktimeWindow
    }
    var horos_roiApplyMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.roiApplyMatrix
    }
    var horos_roiApplyWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.roiApplyWindow
    }
    var horos_roiPropaCopy: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.roiPropaCopy
    }
    var horos_roiPropaDest: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.roiPropaDest
    }
    var horos_roiPropaDim: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.roiPropaDim
    }
    var horos_roiPropaMode: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.roiPropaMode
    }
    var horos_roiPropaWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.roiPropaWindow
    }
    var horos_roiRenameMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.roiRenameMatrix
    }
    var horos_roiRenameName: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.roiRenameName
    }
    var horos_roiRenameWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.roiRenameWindow
    }
    var horos_roiSetPixWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.roiSetPixWindow
    }
    var horos_saveWindowsStateWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.saveWindowsStateWindow
    }
    var horos_setROI4DSeries: NSButton? {
        horosLoadViewerPanels()
        return panelOutlets.setROI4DSeries
    }
    var horos_setWLWWWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.setWLWWWindow
    }
    var horos_sizeMatrix: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.sizeMatrix
    }
    var horos_structuringElementRadiusSlider: NSSlider? {
        horosLoadViewerPanels()
        return panelOutlets.structuringElementRadiusSlider
    }
    var horos_structuringElementRadiusTextField: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.structuringElementRadiusTextField
    }
    var horos_suvConversion: NSMatrix? {
        horosLoadViewerPanels()
        return panelOutlets.suvConversion
    }
    var horos_suvForm: HorosFormView? {
        horosLoadViewerPanels()
        return panelOutlets.suvForm
    }
    var horos_ThickIntervalWindow: NSWindow? {
        horosLoadViewerPanels()
        return panelOutlets.ThickIntervalWindow
    }
    var horos_toset: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.toset
    }
    var horos_wl: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.wl
    }
    var horos_wlset: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.wlset
    }
    var horos_ww: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.ww
    }
    var horos_wwset: NSTextField? {
        horosLoadViewerPanels()
        return panelOutlets.wwset
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

extension ViewerPanelOutlets {
    /// Every outlet, nil ones included: the views, windows and toolbars among
    /// them are where the nib's File's Owner bindings live.
    var bindingTeardownRoots: [AnyObject?] {
        [
            addCLUTWindow,
            addConvWindow,
            addOpacityWindow,
            addWLWWWindow,
            AllROIsRadio,
            blendingPlugins,
            blendingResample,
            blendingTypeMultiply,
            blendingTypeRGB,
            blendingTypeSubtract,
            blendingTypeWindow,
            brushROIFilterOptionsAllWithSameName,
            brushROIFilterOptionsOKButton,
            brushROIFilterOptionsWindow,
            checkMaxValue,
            checkMinValue,
            clutName,
            clutView,
            CommentsEditField,
            CommentsWindow,
            convMatrix,
            customInterval,
            customOrigin,
            customVectors,
            customXSpacing,
            customYSpacing,
            dcmAllViewers,
            dcmBox,
            dcmExportWindow,
            dcmFormat,
            dcmFrom,
            dcmFromText,
            dcmInterval,
            dcmIntervalText,
            dcmNumber,
            dcmSelection,
            dcmSeriesName,
            dcmTo,
            dcmToText,
            displaySUVWindow,
            fromset,
            imageAllViewers,
            imageExportWindow,
            imageFormat,
            imageSelection,
            injectionTimeWindow,
            InOutROI,
            matrixName,
            matrixNorm,
            maxValueText,
            minValueText,
            newName,
            newValueMatrix,
            newValueText,
            OpacityName,
            OpacityView,
            printBox,
            printFormat,
            printFrom,
            printFromText,
            printInterval,
            printIntervalText,
            printLayout,
            printPagesToPrint,
            printSelection,
            printSettings,
            printText,
            printTo,
            printToText,
            printWindow,
            quicktimeAllViewers,
            quicktimeBox,
            quicktimeFrom,
            quicktimeFromText,
            quicktimeInterval,
            quicktimeIntervalText,
            quicktimeMode,
            quicktimeNumber,
            quicktimeTo,
            quicktimeToText,
            quicktimeWindow,
            roiApplyMatrix,
            roiApplyWindow,
            roiPropaCopy,
            roiPropaDest,
            roiPropaDim,
            roiPropaMode,
            roiPropaWindow,
            roiRenameMatrix,
            roiRenameName,
            roiRenameWindow,
            roiSetPixWindow,
            saveWindowsStateWindow,
            setROI4DSeries,
            setWLWWWindow,
            sizeMatrix,
            structuringElementRadiusSlider,
            structuringElementRadiusTextField,
            suvConversion,
            suvForm,
            ThickIntervalWindow,
            toset,
            wl,
            wlset,
            ww,
            wwset,
        ]
    }
}
