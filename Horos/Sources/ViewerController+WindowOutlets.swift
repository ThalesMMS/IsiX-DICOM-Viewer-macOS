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

/// The outlets of Viewer.nib, which the viewer owns: kept as the nib sets them, without a retain (the window and its views keep them).
final class ViewerWindowOutlets: @unchecked Sendable {
    unowned(unsafe) var activatedFusion: NSButton?
    unowned(unsafe) var annotations: NSView?
    unowned(unsafe) var blendingPercentage: NSTextField?
    unowned(unsafe) var blendingPopupMenu: NSPopUpButton?
    unowned(unsafe) var blendingSlider: NSSlider?
    unowned(unsafe) var BlendingView: NSView?
    unowned(unsafe) var buttonToolMatrix: NSMatrix?
    unowned(unsafe) var clutPopup: NSPopUpButton?
    unowned(unsafe) var CommentsField: NSButton?
    unowned(unsafe) var comparativesButton: NSButton?
    unowned(unsafe) var convPopup: NSPopUpButton?
    unowned(unsafe) var ConvView: NSView?
    unowned(unsafe) var display12bitToolbarItemMatrix: NSMatrix?
    unowned(unsafe) var display12bitToolbarItemView: NSView?
    unowned(unsafe) var FusionView: NSView?
    unowned(unsafe) var keyImageCheck: NSButton?
    unowned(unsafe) var keyImagePopUpButton: NSPopUpButton?
    unowned(unsafe) var keyImages: NSView?
    unowned(unsafe) var loopButton: NSButton?
    unowned(unsafe) var moviePlayStop: NSButton?
    unowned(unsafe) var moviePosSlider: NSSlider?
    unowned(unsafe) var movieRateSlider: NSSlider?
    unowned(unsafe) var movieTextSlide: NSTextField?
    unowned(unsafe) var movieView: NSView?
    unowned(unsafe) var OpacityPopup: NSPopUpButton?
    unowned(unsafe) var orientationMatrix: NSMatrix?
    unowned(unsafe) var orientationView: NSView?
    unowned(unsafe) var PagePad: NSView?
    unowned(unsafe) var patientView: NSView?
    unowned(unsafe) var popFusion: NSPopUpButton?
    unowned(unsafe) var popupRoi: NSPopUpButton?
    unowned(unsafe) var previewMatrix: NSMatrix?
    unowned(unsafe) var previewMatrixScrollView: NSScrollView?
    unowned(unsafe) var previewRootView: NSView?
    unowned(unsafe) var propagateSettingsView: NSView?
    unowned(unsafe) var ReconstructionRoi: NSPopUpButton?
    unowned(unsafe) var ReconstructionView: NSView?
    unowned(unsafe) var reportTemplatesImageView: NSImageView?
    unowned(unsafe) var reportTemplatesListPopUpButton: NSPopUpButton?
    unowned(unsafe) var reportTemplatesView: NSView?
    unowned(unsafe) var RGBFactorsView: NSView?
    unowned(unsafe) var sc1: NSButton?
    unowned(unsafe) var sc2: NSButton?
    unowned(unsafe) var sc3: NSButton?
    unowned(unsafe) var sc4: NSButton?
    unowned(unsafe) var sc5: NSButton?
    unowned(unsafe) var sc6: NSButton?
    unowned(unsafe) var sc7: NSButton?
    unowned(unsafe) var sc8: NSButton?
    unowned(unsafe) var sc9: NSButton?
    unowned(unsafe) var seriesPopupMenu: NSPopUpButton?
    unowned(unsafe) var seriesPopupView: NSView?
    unowned(unsafe) var serieView: NSView?
    unowned(unsafe) var shutterOnOff: NSButton?
    unowned(unsafe) var shutterView: NSView?
    unowned(unsafe) var slider: NSSlider?
    unowned(unsafe) var sliderFusion: NSSlider?
    unowned(unsafe) var speedSlider: NSSlider?
    unowned(unsafe) var speedText: NSTextField?
    unowned(unsafe) var speedView: NSView?
    unowned(unsafe) var splitView: NSSplitView?
    unowned(unsafe) var stacksFusion: NSTextField?
    unowned(unsafe) var StatusPopup: NSPopUpButton?
    unowned(unsafe) var StatusView: NSView?
    unowned(unsafe) var studyView: StudyView?
    unowned(unsafe) var subCtrlMaskText: NSTextField?
    unowned(unsafe) var subCtrlOnOff: NSButton?
    unowned(unsafe) var subCtrlPercent: NSSlider?
    unowned(unsafe) var subCtrlSharpenButton: NSButton?
    unowned(unsafe) var subCtrlSum: NSSlider?
    unowned(unsafe) var subCtrlView: NSView?
    unowned(unsafe) var toolsMatrix: NSMatrix?
    unowned(unsafe) var toolsView: NSView?
    unowned(unsafe) var viewerView: NSView?
    unowned(unsafe) var windowsTiling: NSView?
    unowned(unsafe) var windowsTilingMenu: NSPopUpButton?
    unowned(unsafe) var wlwwPopup: NSPopUpButton?
    unowned(unsafe) var WLWWView: NSView?
}

// The connections of the nib, which sets each outlet through -set<Outlet>:.
extension ViewerController {
    @objc(setActivatedFusion:) private func connectActivatedFusion(_ outlet: NSButton?) { windowOutlets.activatedFusion = outlet }
    @objc(setAnnotations:) private func connectAnnotations(_ outlet: NSView?) { windowOutlets.annotations = outlet }
    @objc(setBlendingPercentage:) private func connectBlendingPercentage(_ outlet: NSTextField?) { windowOutlets.blendingPercentage = outlet }
    @objc(setBlendingPopupMenu:) private func connectBlendingPopupMenu(_ outlet: NSPopUpButton?) { windowOutlets.blendingPopupMenu = outlet }
    @objc(setBlendingSlider:) private func connectBlendingSlider(_ outlet: NSSlider?) { windowOutlets.blendingSlider = outlet }
    @objc(setBlendingView:) private func connectBlendingView(_ outlet: NSView?) { windowOutlets.BlendingView = outlet }
    @objc(setButtonToolMatrix:) private func connectButtonToolMatrix(_ outlet: NSMatrix?) { windowOutlets.buttonToolMatrix = outlet }
    @objc(setClutPopup:) private func connectClutPopup(_ outlet: NSPopUpButton?) { windowOutlets.clutPopup = outlet }
    @objc(setCommentsField:) private func connectCommentsField(_ outlet: NSButton?) { windowOutlets.CommentsField = outlet }
    @objc(setComparativesButton:) private func connectComparativesButton(_ outlet: NSButton?) { windowOutlets.comparativesButton = outlet }
    @objc(setConvPopup:) private func connectConvPopup(_ outlet: NSPopUpButton?) { windowOutlets.convPopup = outlet }
    @objc(setConvView:) private func connectConvView(_ outlet: NSView?) { windowOutlets.ConvView = outlet }
    @objc(setDisplay12bitToolbarItemMatrix:) private func connectDisplay12bitToolbarItemMatrix(_ outlet: NSMatrix?) { windowOutlets.display12bitToolbarItemMatrix = outlet }
    @objc(setDisplay12bitToolbarItemView:) private func connectDisplay12bitToolbarItemView(_ outlet: NSView?) { windowOutlets.display12bitToolbarItemView = outlet }
    @objc(setFusionView:) private func connectFusionView(_ outlet: NSView?) { windowOutlets.FusionView = outlet }
    @objc(setKeyImageCheck:) private func connectKeyImageCheck(_ outlet: NSButton?) { windowOutlets.keyImageCheck = outlet }
    @objc(setKeyImagePopUpButton:) private func connectKeyImagePopUpButton(_ outlet: NSPopUpButton?) { windowOutlets.keyImagePopUpButton = outlet }
    @objc(setKeyImages:) private func connectKeyImages(_ outlet: NSView?) { windowOutlets.keyImages = outlet }
    @objc(setLoopButton:) private func connectLoopButton(_ outlet: NSButton?) { windowOutlets.loopButton = outlet }
    @objc(setMoviePlayStop:) private func connectMoviePlayStop(_ outlet: NSButton?) { windowOutlets.moviePlayStop = outlet }
    @objc(setMoviePosSlider:) private func connectMoviePosSlider(_ outlet: NSSlider?) { windowOutlets.moviePosSlider = outlet }
    @objc(setMovieRateSlider:) private func connectMovieRateSlider(_ outlet: NSSlider?) { windowOutlets.movieRateSlider = outlet }
    @objc(setMovieTextSlide:) private func connectMovieTextSlide(_ outlet: NSTextField?) { windowOutlets.movieTextSlide = outlet }
    @objc(setMovieView:) private func connectMovieView(_ outlet: NSView?) { windowOutlets.movieView = outlet }
    @objc(setOpacityPopup:) private func connectOpacityPopup(_ outlet: NSPopUpButton?) { windowOutlets.OpacityPopup = outlet }
    @objc(setOrientationMatrix:) private func connectOrientationMatrix(_ outlet: NSMatrix?) { windowOutlets.orientationMatrix = outlet }
    @objc(setOrientationView:) private func connectOrientationView(_ outlet: NSView?) { windowOutlets.orientationView = outlet }
    @objc(setPagePad:) private func connectPagePad(_ outlet: NSView?) { windowOutlets.PagePad = outlet }
    @objc(setPatientView:) private func connectPatientView(_ outlet: NSView?) { windowOutlets.patientView = outlet }
    @objc(setPopFusion:) private func connectPopFusion(_ outlet: NSPopUpButton?) { windowOutlets.popFusion = outlet }
    @objc(setPopupRoi:) private func connectPopupRoi(_ outlet: NSPopUpButton?) { windowOutlets.popupRoi = outlet }
    @objc(setPreviewMatrix:) private func connectPreviewMatrix(_ outlet: NSMatrix?) { windowOutlets.previewMatrix = outlet }
    @objc(setPreviewMatrixScrollView:) private func connectPreviewMatrixScrollView(_ outlet: NSScrollView?) { windowOutlets.previewMatrixScrollView = outlet }
    @objc(setPreviewRootView:) private func connectPreviewRootView(_ outlet: NSView?) { windowOutlets.previewRootView = outlet }
    @objc(setPropagateSettingsView:) private func connectPropagateSettingsView(_ outlet: NSView?) { windowOutlets.propagateSettingsView = outlet }
    @objc(setReconstructionRoi:) private func connectReconstructionRoi(_ outlet: NSPopUpButton?) { windowOutlets.ReconstructionRoi = outlet }
    @objc(setReconstructionView:) private func connectReconstructionView(_ outlet: NSView?) { windowOutlets.ReconstructionView = outlet }
    @objc(setReportTemplatesImageView:) private func connectReportTemplatesImageView(_ outlet: NSImageView?) { windowOutlets.reportTemplatesImageView = outlet }
    @objc(setReportTemplatesListPopUpButton:) private func connectReportTemplatesListPopUpButton(_ outlet: NSPopUpButton?) { windowOutlets.reportTemplatesListPopUpButton = outlet }
    @objc(setReportTemplatesView:) private func connectReportTemplatesView(_ outlet: NSView?) { windowOutlets.reportTemplatesView = outlet }
    @objc(setRGBFactorsView:) private func connectRGBFactorsView(_ outlet: NSView?) { windowOutlets.RGBFactorsView = outlet }
    @objc(setSc1:) private func connectSc1(_ outlet: NSButton?) { windowOutlets.sc1 = outlet }
    @objc(setSc2:) private func connectSc2(_ outlet: NSButton?) { windowOutlets.sc2 = outlet }
    @objc(setSc3:) private func connectSc3(_ outlet: NSButton?) { windowOutlets.sc3 = outlet }
    @objc(setSc4:) private func connectSc4(_ outlet: NSButton?) { windowOutlets.sc4 = outlet }
    @objc(setSc5:) private func connectSc5(_ outlet: NSButton?) { windowOutlets.sc5 = outlet }
    @objc(setSc6:) private func connectSc6(_ outlet: NSButton?) { windowOutlets.sc6 = outlet }
    @objc(setSc7:) private func connectSc7(_ outlet: NSButton?) { windowOutlets.sc7 = outlet }
    @objc(setSc8:) private func connectSc8(_ outlet: NSButton?) { windowOutlets.sc8 = outlet }
    @objc(setSc9:) private func connectSc9(_ outlet: NSButton?) { windowOutlets.sc9 = outlet }
    @objc(setSeriesPopupMenu:) private func connectSeriesPopupMenu(_ outlet: NSPopUpButton?) { windowOutlets.seriesPopupMenu = outlet }
    @objc(setSeriesPopupView:) private func connectSeriesPopupView(_ outlet: NSView?) { windowOutlets.seriesPopupView = outlet }
    @objc(setSerieView:) private func connectSerieView(_ outlet: NSView?) { windowOutlets.serieView = outlet }
    @objc(setShutterOnOff:) private func connectShutterOnOff(_ outlet: NSButton?) { windowOutlets.shutterOnOff = outlet }
    @objc(setShutterView:) private func connectShutterView(_ outlet: NSView?) { windowOutlets.shutterView = outlet }
    @objc(setSlider:) private func connectSlider(_ outlet: NSSlider?) { windowOutlets.slider = outlet }
    @objc(setSliderFusion:) private func connectSliderFusion(_ outlet: NSSlider?) { windowOutlets.sliderFusion = outlet }
    @objc(setSpeedSlider:) private func connectSpeedSlider(_ outlet: NSSlider?) { windowOutlets.speedSlider = outlet }
    @objc(setSpeedText:) private func connectSpeedText(_ outlet: NSTextField?) { windowOutlets.speedText = outlet }
    @objc(setSpeedView:) private func connectSpeedView(_ outlet: NSView?) { windowOutlets.speedView = outlet }
    @objc(setSplitView:) private func connectSplitView(_ outlet: NSSplitView?) { windowOutlets.splitView = outlet }
    @objc(setStacksFusion:) private func connectStacksFusion(_ outlet: NSTextField?) { windowOutlets.stacksFusion = outlet }
    @objc(setStatusPopup:) private func connectStatusPopup(_ outlet: NSPopUpButton?) { windowOutlets.StatusPopup = outlet }
    @objc(setStatusView:) private func connectStatusView(_ outlet: NSView?) { windowOutlets.StatusView = outlet }
    @objc(setStudyView:) private func connectStudyView(_ outlet: StudyView?) { windowOutlets.studyView = outlet }
    @objc(setSubCtrlMaskText:) private func connectSubCtrlMaskText(_ outlet: NSTextField?) { windowOutlets.subCtrlMaskText = outlet }
    @objc(setSubCtrlOnOff:) private func connectSubCtrlOnOff(_ outlet: NSButton?) { windowOutlets.subCtrlOnOff = outlet }
    @objc(setSubCtrlPercent:) private func connectSubCtrlPercent(_ outlet: NSSlider?) { windowOutlets.subCtrlPercent = outlet }
    @objc(setSubCtrlSharpenButton:) private func connectSubCtrlSharpenButton(_ outlet: NSButton?) { windowOutlets.subCtrlSharpenButton = outlet }
    @objc(setSubCtrlSum:) private func connectSubCtrlSum(_ outlet: NSSlider?) { windowOutlets.subCtrlSum = outlet }
    @objc(setSubCtrlView:) private func connectSubCtrlView(_ outlet: NSView?) { windowOutlets.subCtrlView = outlet }
    @objc(setToolsMatrix:) private func connectToolsMatrix(_ outlet: NSMatrix?) { windowOutlets.toolsMatrix = outlet }
    @objc(setToolsView:) private func connectToolsView(_ outlet: NSView?) { windowOutlets.toolsView = outlet }
    @objc(setViewerView:) private func connectViewerView(_ outlet: NSView?) { windowOutlets.viewerView = outlet }
    @objc(setWindowsTiling:) private func connectWindowsTiling(_ outlet: NSView?) { windowOutlets.windowsTiling = outlet }
    @objc(setWindowsTilingMenu:) private func connectWindowsTilingMenu(_ outlet: NSPopUpButton?) { windowOutlets.windowsTilingMenu = outlet }
    @objc(setWlwwPopup:) private func connectWlwwPopup(_ outlet: NSPopUpButton?) { windowOutlets.wlwwPopup = outlet }
    @objc(setWLWWView:) private func connectWLWWView(_ outlet: NSView?) { windowOutlets.WLWWView = outlet }
}

extension ViewerController {
    var horos_activatedFusion: NSButton? { windowOutlets.activatedFusion }
    var horos_annotations: NSView? { windowOutlets.annotations }
    var horos_blendingPercentage: NSTextField? { windowOutlets.blendingPercentage }
    var horos_blendingPopupMenu: NSPopUpButton? { windowOutlets.blendingPopupMenu }
    var horos_blendingSlider: NSSlider? { windowOutlets.blendingSlider }
    var horos_BlendingView: NSView? { windowOutlets.BlendingView }
    var horos_buttonToolMatrix: NSMatrix? { windowOutlets.buttonToolMatrix }
    var horos_clutPopup: NSPopUpButton? { windowOutlets.clutPopup }
    var horos_CommentsField: NSButton? { windowOutlets.CommentsField }
    var horos_comparativesButton: NSButton? { windowOutlets.comparativesButton }
    var horos_convPopup: NSPopUpButton? { windowOutlets.convPopup }
    var horos_ConvView: NSView? { windowOutlets.ConvView }
    var horos_display12bitToolbarItemMatrix: NSMatrix? { windowOutlets.display12bitToolbarItemMatrix }
    var horos_display12bitToolbarItemView: NSView? { windowOutlets.display12bitToolbarItemView }
    var horos_FusionView: NSView? { windowOutlets.FusionView }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var keyImageCheck: NSButton! { windowOutlets.keyImageCheck }
    var horos_keyImagePopUpButton: NSPopUpButton? { windowOutlets.keyImagePopUpButton }
    var horos_keyImages: NSView? { windowOutlets.keyImages }
    var horos_loopButton: NSButton? { windowOutlets.loopButton }
    var horos_moviePlayStop: NSButton? { windowOutlets.moviePlayStop }
    var horos_moviePosSlider: NSSlider? { windowOutlets.moviePosSlider }
    var horos_movieRateSlider: NSSlider? { windowOutlets.movieRateSlider }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var movieRateSlider: NSSlider! { windowOutlets.movieRateSlider }
    var horos_movieTextSlide: NSTextField? { windowOutlets.movieTextSlide }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var movieTextSlide: NSTextField! { windowOutlets.movieTextSlide }
    var horos_movieView: NSView? { windowOutlets.movieView }
    var horos_OpacityPopup: NSPopUpButton? { windowOutlets.OpacityPopup }
    var horos_orientationMatrix: NSMatrix? { windowOutlets.orientationMatrix }
    var horos_orientationView: NSView? { windowOutlets.orientationView }
    var horos_patientView: NSView? { windowOutlets.patientView }
    var horos_popFusion: NSPopUpButton? { windowOutlets.popFusion }
    var horos_popupRoi: NSPopUpButton? { windowOutlets.popupRoi }
    var horos_previewMatrix: NSMatrix? { windowOutlets.previewMatrix }
    var horos_previewMatrixScrollView: NSScrollView? { windowOutlets.previewMatrixScrollView }
    var horos_previewRootView: NSView? { windowOutlets.previewRootView }
    var horos_propagateSettingsView: NSView? { windowOutlets.propagateSettingsView }
    var horos_ReconstructionRoi: NSPopUpButton? { windowOutlets.ReconstructionRoi }
    var horos_ReconstructionView: NSView? { windowOutlets.ReconstructionView }
    var horos_reportTemplatesImageView: NSImageView? { windowOutlets.reportTemplatesImageView }
    var horos_reportTemplatesListPopUpButton: NSPopUpButton? { windowOutlets.reportTemplatesListPopUpButton }
    var horos_reportTemplatesView: NSView? { windowOutlets.reportTemplatesView }
    var horos_RGBFactorsView: NSView? { windowOutlets.RGBFactorsView }
    var horos_sc1: NSButton? { windowOutlets.sc1 }
    var horos_sc2: NSButton? { windowOutlets.sc2 }
    var horos_sc3: NSButton? { windowOutlets.sc3 }
    var horos_sc4: NSButton? { windowOutlets.sc4 }
    var horos_sc5: NSButton? { windowOutlets.sc5 }
    var horos_sc6: NSButton? { windowOutlets.sc6 }
    var horos_sc7: NSButton? { windowOutlets.sc7 }
    var horos_sc8: NSButton? { windowOutlets.sc8 }
    var horos_sc9: NSButton? { windowOutlets.sc9 }
    var horos_seriesPopupMenu: NSPopUpButton? { windowOutlets.seriesPopupMenu }
    var horos_seriesPopupView: NSView? { windowOutlets.seriesPopupView }
    var horos_serieView: NSView? { windowOutlets.serieView }
    var horos_shutterOnOff: NSButton? { windowOutlets.shutterOnOff }
    var horos_shutterView: NSView? { windowOutlets.shutterView }
    var horos_slider: NSSlider? { windowOutlets.slider }
    var horos_sliderFusion: NSSlider? { windowOutlets.sliderFusion }
    var horos_speedSlider: NSSlider? { windowOutlets.speedSlider }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var speedSlider: NSSlider! { windowOutlets.speedSlider }
    var horos_speedText: NSTextField? { windowOutlets.speedText }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var speedText: NSTextField! { windowOutlets.speedText }
    var horos_speedView: NSView? { windowOutlets.speedView }
    var horos_splitView: NSSplitView? { windowOutlets.splitView }
    /// Stores the split view -awakeFromNib made, which the viewer released
    /// itself, when an older nib had none.
    func horos_assignSplitView(_ split: NSSplitView?) { windowOutlets.splitView = split }
    var horos_stacksFusion: NSTextField? { windowOutlets.stacksFusion }
    var horos_StatusPopup: NSPopUpButton? { windowOutlets.StatusPopup }
    var horos_StatusView: NSView? { windowOutlets.StatusView }
    var horos_studyView: StudyView? { windowOutlets.studyView }
    var horos_subCtrlMaskText: NSTextField? { windowOutlets.subCtrlMaskText }
    var horos_subCtrlOnOff: NSButton? { windowOutlets.subCtrlOnOff }
    var horos_subCtrlPercent: NSSlider? { windowOutlets.subCtrlPercent }
    var horos_subCtrlSharpenButton: NSButton? { windowOutlets.subCtrlSharpenButton }
    var horos_subCtrlSum: NSSlider? { windowOutlets.subCtrlSum }
    var horos_subCtrlView: NSView? { windowOutlets.subCtrlView }
    var horos_toolsMatrix: NSMatrix? { windowOutlets.toolsMatrix }
    var horos_toolsView: NSView? { windowOutlets.toolsView }
    var horos_windowsTiling: NSView? { windowOutlets.windowsTiling }
    var horos_wlwwPopup: NSPopUpButton? { windowOutlets.wlwwPopup }
    var horos_WLWWView: NSView? { windowOutlets.WLWWView }
}

// MARK: - Binding teardown

extension ViewerWindowOutlets {
    /// Every outlet, nil ones included: the views, windows and toolbars among
    /// them are where the nib's File's Owner bindings live.
    var bindingTeardownRoots: [AnyObject?] {
        [
            activatedFusion,
            annotations,
            blendingPercentage,
            blendingPopupMenu,
            blendingSlider,
            BlendingView,
            buttonToolMatrix,
            clutPopup,
            CommentsField,
            comparativesButton,
            convPopup,
            ConvView,
            display12bitToolbarItemMatrix,
            display12bitToolbarItemView,
            FusionView,
            keyImageCheck,
            keyImagePopUpButton,
            keyImages,
            loopButton,
            moviePlayStop,
            moviePosSlider,
            movieRateSlider,
            movieTextSlide,
            movieView,
            OpacityPopup,
            orientationMatrix,
            orientationView,
            PagePad,
            patientView,
            popFusion,
            popupRoi,
            previewMatrix,
            previewMatrixScrollView,
            previewRootView,
            propagateSettingsView,
            ReconstructionRoi,
            ReconstructionView,
            reportTemplatesImageView,
            reportTemplatesListPopUpButton,
            reportTemplatesView,
            RGBFactorsView,
            sc1,
            sc2,
            sc3,
            sc4,
            sc5,
            sc6,
            sc7,
            sc8,
            sc9,
            seriesPopupMenu,
            seriesPopupView,
            serieView,
            shutterOnOff,
            shutterView,
            slider,
            sliderFusion,
            speedSlider,
            speedText,
            speedView,
            splitView,
            stacksFusion,
            StatusPopup,
            StatusView,
            studyView,
            subCtrlMaskText,
            subCtrlOnOff,
            subCtrlPercent,
            subCtrlSharpenButton,
            subCtrlSum,
            subCtrlView,
            toolsMatrix,
            toolsView,
            viewerView,
            windowsTiling,
            windowsTilingMenu,
            wlwwPopup,
            WLWWView,
        ]
    }
}
