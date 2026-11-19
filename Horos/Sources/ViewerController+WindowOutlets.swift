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
    @objc(setActivatedFusion:) private func connectActivatedFusion(_ outlet: NSButton?) { _activatedFusion = outlet }
    @objc(setAnnotations:) private func connectAnnotations(_ outlet: NSView?) { _annotations = outlet }
    @objc(setBlendingPercentage:) private func connectBlendingPercentage(_ outlet: NSTextField?) { _blendingPercentage = outlet }
    @objc(setBlendingPopupMenu:) private func connectBlendingPopupMenu(_ outlet: NSPopUpButton?) { _blendingPopupMenu = outlet }
    @objc(setBlendingSlider:) private func connectBlendingSlider(_ outlet: NSSlider?) { _blendingSlider = outlet }
    @objc(setBlendingView:) private func connectBlendingView(_ outlet: NSView?) { _BlendingView = outlet }
    @objc(setButtonToolMatrix:) private func connectButtonToolMatrix(_ outlet: NSMatrix?) { _buttonToolMatrix = outlet }
    @objc(setClutPopup:) private func connectClutPopup(_ outlet: NSPopUpButton?) { _clutPopup = outlet }
    @objc(setCommentsField:) private func connectCommentsField(_ outlet: NSButton?) { _CommentsField = outlet }
    @objc(setComparativesButton:) private func connectComparativesButton(_ outlet: NSButton?) { _comparativesButton = outlet }
    @objc(setConvPopup:) private func connectConvPopup(_ outlet: NSPopUpButton?) { _convPopup = outlet }
    @objc(setConvView:) private func connectConvView(_ outlet: NSView?) { _ConvView = outlet }
    @objc(setDisplay12bitToolbarItemMatrix:) private func connectDisplay12bitToolbarItemMatrix(_ outlet: NSMatrix?) { _display12bitToolbarItemMatrix = outlet }
    @objc(setDisplay12bitToolbarItemView:) private func connectDisplay12bitToolbarItemView(_ outlet: NSView?) { _display12bitToolbarItemView = outlet }
    @objc(setFusionView:) private func connectFusionView(_ outlet: NSView?) { _FusionView = outlet }
    @objc(setKeyImageCheck:) private func connectKeyImageCheck(_ outlet: NSButton?) { _keyImageCheck = outlet }
    @objc(setKeyImagePopUpButton:) private func connectKeyImagePopUpButton(_ outlet: NSPopUpButton?) { _keyImagePopUpButton = outlet }
    @objc(setKeyImages:) private func connectKeyImages(_ outlet: NSView?) { _keyImages = outlet }
    @objc(setLoopButton:) private func connectLoopButton(_ outlet: NSButton?) { _loopButton = outlet }
    @objc(setMoviePlayStop:) private func connectMoviePlayStop(_ outlet: NSButton?) { _moviePlayStop = outlet }
    @objc(setMoviePosSlider:) private func connectMoviePosSlider(_ outlet: NSSlider?) { _moviePosSlider = outlet }
    @objc(setMovieRateSlider:) private func connectMovieRateSlider(_ outlet: NSSlider?) { _movieRateSlider = outlet }
    @objc(setMovieTextSlide:) private func connectMovieTextSlide(_ outlet: NSTextField?) { _movieTextSlide = outlet }
    @objc(setMovieView:) private func connectMovieView(_ outlet: NSView?) { _movieView = outlet }
    @objc(setOpacityPopup:) private func connectOpacityPopup(_ outlet: NSPopUpButton?) { _OpacityPopup = outlet }
    @objc(setOrientationMatrix:) private func connectOrientationMatrix(_ outlet: NSMatrix?) { _orientationMatrix = outlet }
    @objc(setOrientationView:) private func connectOrientationView(_ outlet: NSView?) { _orientationView = outlet }
    @objc(setPagePad:) private func connectPagePad(_ outlet: NSView?) { _PagePad = outlet }
    @objc(setPatientView:) private func connectPatientView(_ outlet: NSView?) { _patientView = outlet }
    @objc(setPopFusion:) private func connectPopFusion(_ outlet: NSPopUpButton?) { _popFusion = outlet }
    @objc(setPopupRoi:) private func connectPopupRoi(_ outlet: NSPopUpButton?) { _popupRoi = outlet }
    @objc(setPreviewMatrix:) private func connectPreviewMatrix(_ outlet: NSMatrix?) { _previewMatrix = outlet }
    @objc(setPreviewMatrixScrollView:) private func connectPreviewMatrixScrollView(_ outlet: NSScrollView?) { _previewMatrixScrollView = outlet }
    @objc(setPreviewRootView:) private func connectPreviewRootView(_ outlet: NSView?) { _previewRootView = outlet }
    @objc(setPropagateSettingsView:) private func connectPropagateSettingsView(_ outlet: NSView?) { _propagateSettingsView = outlet }
    @objc(setReconstructionRoi:) private func connectReconstructionRoi(_ outlet: NSPopUpButton?) { _ReconstructionRoi = outlet }
    @objc(setReconstructionView:) private func connectReconstructionView(_ outlet: NSView?) { _ReconstructionView = outlet }
    @objc(setReportTemplatesImageView:) private func connectReportTemplatesImageView(_ outlet: NSImageView?) { _reportTemplatesImageView = outlet }
    @objc(setReportTemplatesListPopUpButton:) private func connectReportTemplatesListPopUpButton(_ outlet: NSPopUpButton?) { _reportTemplatesListPopUpButton = outlet }
    @objc(setReportTemplatesView:) private func connectReportTemplatesView(_ outlet: NSView?) { _reportTemplatesView = outlet }
    @objc(setRGBFactorsView:) private func connectRGBFactorsView(_ outlet: NSView?) { _RGBFactorsView = outlet }
    @objc(setSc1:) private func connectSc1(_ outlet: NSButton?) { _sc1 = outlet }
    @objc(setSc2:) private func connectSc2(_ outlet: NSButton?) { _sc2 = outlet }
    @objc(setSc3:) private func connectSc3(_ outlet: NSButton?) { _sc3 = outlet }
    @objc(setSc4:) private func connectSc4(_ outlet: NSButton?) { _sc4 = outlet }
    @objc(setSc5:) private func connectSc5(_ outlet: NSButton?) { _sc5 = outlet }
    @objc(setSc6:) private func connectSc6(_ outlet: NSButton?) { _sc6 = outlet }
    @objc(setSc7:) private func connectSc7(_ outlet: NSButton?) { _sc7 = outlet }
    @objc(setSc8:) private func connectSc8(_ outlet: NSButton?) { _sc8 = outlet }
    @objc(setSc9:) private func connectSc9(_ outlet: NSButton?) { _sc9 = outlet }
    @objc(setSeriesPopupMenu:) private func connectSeriesPopupMenu(_ outlet: NSPopUpButton?) { _seriesPopupMenu = outlet }
    @objc(setSeriesPopupView:) private func connectSeriesPopupView(_ outlet: NSView?) { _seriesPopupView = outlet }
    @objc(setSerieView:) private func connectSerieView(_ outlet: NSView?) { _serieView = outlet }
    @objc(setShutterOnOff:) private func connectShutterOnOff(_ outlet: NSButton?) { _shutterOnOff = outlet }
    @objc(setShutterView:) private func connectShutterView(_ outlet: NSView?) { _shutterView = outlet }
    @objc(setSlider:) private func connectSlider(_ outlet: NSSlider?) { _slider = outlet }
    @objc(setSliderFusion:) private func connectSliderFusion(_ outlet: NSSlider?) { _sliderFusion = outlet }
    @objc(setSpeedSlider:) private func connectSpeedSlider(_ outlet: NSSlider?) { _speedSlider = outlet }
    @objc(setSpeedText:) private func connectSpeedText(_ outlet: NSTextField?) { _speedText = outlet }
    @objc(setSpeedView:) private func connectSpeedView(_ outlet: NSView?) { _speedView = outlet }
    @objc(setSplitView:) private func connectSplitView(_ outlet: NSSplitView?) { _splitView = outlet }
    @objc(setStacksFusion:) private func connectStacksFusion(_ outlet: NSTextField?) { _stacksFusion = outlet }
    @objc(setStatusPopup:) private func connectStatusPopup(_ outlet: NSPopUpButton?) { _StatusPopup = outlet }
    @objc(setStatusView:) private func connectStatusView(_ outlet: NSView?) { _StatusView = outlet }
    @objc(setStudyView:) private func connectStudyView(_ outlet: StudyView?) { _studyView = outlet }
    @objc(setSubCtrlMaskText:) private func connectSubCtrlMaskText(_ outlet: NSTextField?) { _subCtrlMaskText = outlet }
    @objc(setSubCtrlOnOff:) private func connectSubCtrlOnOff(_ outlet: NSButton?) { _subCtrlOnOff = outlet }
    @objc(setSubCtrlPercent:) private func connectSubCtrlPercent(_ outlet: NSSlider?) { _subCtrlPercent = outlet }
    @objc(setSubCtrlSharpenButton:) private func connectSubCtrlSharpenButton(_ outlet: NSButton?) { _subCtrlSharpenButton = outlet }
    @objc(setSubCtrlSum:) private func connectSubCtrlSum(_ outlet: NSSlider?) { _subCtrlSum = outlet }
    @objc(setSubCtrlView:) private func connectSubCtrlView(_ outlet: NSView?) { _subCtrlView = outlet }
    @objc(setToolsMatrix:) private func connectToolsMatrix(_ outlet: NSMatrix?) { _toolsMatrix = outlet }
    @objc(setToolsView:) private func connectToolsView(_ outlet: NSView?) { _toolsView = outlet }
    @objc(setViewerView:) private func connectViewerView(_ outlet: NSView?) { _viewerView = outlet }
    @objc(setWindowsTiling:) private func connectWindowsTiling(_ outlet: NSView?) { _windowsTiling = outlet }
    @objc(setWindowsTilingMenu:) private func connectWindowsTilingMenu(_ outlet: NSPopUpButton?) { _windowsTilingMenu = outlet }
    @objc(setWlwwPopup:) private func connectWlwwPopup(_ outlet: NSPopUpButton?) { _wlwwPopup = outlet }
    @objc(setWLWWView:) private func connectWLWWView(_ outlet: NSView?) { _WLWWView = outlet }
}

extension ViewerController {
    var horos_activatedFusion: NSButton? { _activatedFusion }
    var horos_annotations: NSView? { _annotations }
    var horos_blendingPercentage: NSTextField? { _blendingPercentage }
    var horos_blendingPopupMenu: NSPopUpButton? { _blendingPopupMenu }
    var horos_blendingSlider: NSSlider? { _blendingSlider }
    var horos_BlendingView: NSView? { _BlendingView }
    var horos_buttonToolMatrix: NSMatrix? { _buttonToolMatrix }
    var horos_clutPopup: NSPopUpButton? { _clutPopup }
    var horos_CommentsField: NSButton? { _CommentsField }
    var horos_comparativesButton: NSButton? { _comparativesButton }
    var horos_convPopup: NSPopUpButton? { _convPopup }
    var horos_ConvView: NSView? { _ConvView }
    var horos_display12bitToolbarItemMatrix: NSMatrix? { _display12bitToolbarItemMatrix }
    var horos_display12bitToolbarItemView: NSView? { _display12bitToolbarItemView }
    var horos_FusionView: NSView? { _FusionView }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var keyImageCheck: NSButton! { _keyImageCheck }
    var horos_keyImagePopUpButton: NSPopUpButton? { _keyImagePopUpButton }
    var horos_keyImages: NSView? { _keyImages }
    var horos_loopButton: NSButton? { _loopButton }
    var horos_moviePlayStop: NSButton? { _moviePlayStop }
    var horos_moviePosSlider: NSSlider? { _moviePosSlider }
    var horos_movieRateSlider: NSSlider? { _movieRateSlider }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var movieRateSlider: NSSlider! { _movieRateSlider }
    var horos_movieTextSlide: NSTextField? { _movieTextSlide }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var movieTextSlide: NSTextField! { _movieTextSlide }
    var horos_movieView: NSView? { _movieView }
    var horos_OpacityPopup: NSPopUpButton? { _OpacityPopup }
    var horos_orientationMatrix: NSMatrix? { _orientationMatrix }
    var horos_orientationView: NSView? { _orientationView }
    var horos_patientView: NSView? { _patientView }
    var horos_popFusion: NSPopUpButton? { _popFusion }
    var horos_popupRoi: NSPopUpButton? { _popupRoi }
    var horos_previewMatrix: NSMatrix? { _previewMatrix }
    var horos_previewMatrixScrollView: NSScrollView? { _previewMatrixScrollView }
    var horos_previewRootView: NSView? { _previewRootView }
    var horos_propagateSettingsView: NSView? { _propagateSettingsView }
    var horos_ReconstructionRoi: NSPopUpButton? { _ReconstructionRoi }
    var horos_ReconstructionView: NSView? { _ReconstructionView }
    var horos_reportTemplatesImageView: NSImageView? { _reportTemplatesImageView }
    var horos_reportTemplatesListPopUpButton: NSPopUpButton? { _reportTemplatesListPopUpButton }
    var horos_reportTemplatesView: NSView? { _reportTemplatesView }
    var horos_RGBFactorsView: NSView? { _RGBFactorsView }
    var horos_sc1: NSButton? { _sc1 }
    var horos_sc2: NSButton? { _sc2 }
    var horos_sc3: NSButton? { _sc3 }
    var horos_sc4: NSButton? { _sc4 }
    var horos_sc5: NSButton? { _sc5 }
    var horos_sc6: NSButton? { _sc6 }
    var horos_sc7: NSButton? { _sc7 }
    var horos_sc8: NSButton? { _sc8 }
    var horos_sc9: NSButton? { _sc9 }
    var horos_seriesPopupMenu: NSPopUpButton? { _seriesPopupMenu }
    var horos_seriesPopupView: NSView? { _seriesPopupView }
    var horos_serieView: NSView? { _serieView }
    var horos_shutterOnOff: NSButton? { _shutterOnOff }
    var horos_shutterView: NSView? { _shutterView }
    var horos_slider: NSSlider? { _slider }
    var horos_sliderFusion: NSSlider? { _sliderFusion }
    var horos_speedSlider: NSSlider? { _speedSlider }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var speedSlider: NSSlider! { _speedSlider }
    var horos_speedText: NSTextField? { _speedText }
    /// The getter the former @synthesize made: the outlet as the nib left it.
    @objc public var speedText: NSTextField! { _speedText }
    var horos_speedView: NSView? { _speedView }
    var horos_splitView: NSSplitView? { _splitView }
    /// Stores the split view -awakeFromNib made, which the viewer released
    /// itself, when an older nib had none.
    func horos_assignSplitView(_ split: NSSplitView?) { _splitView = split }
    var horos_stacksFusion: NSTextField? { _stacksFusion }
    var horos_StatusPopup: NSPopUpButton? { _StatusPopup }
    var horos_StatusView: NSView? { _StatusView }
    var horos_studyView: StudyView? { _studyView }
    var horos_subCtrlMaskText: NSTextField? { _subCtrlMaskText }
    var horos_subCtrlOnOff: NSButton? { _subCtrlOnOff }
    var horos_subCtrlPercent: NSSlider? { _subCtrlPercent }
    var horos_subCtrlSharpenButton: NSButton? { _subCtrlSharpenButton }
    var horos_subCtrlSum: NSSlider? { _subCtrlSum }
    var horos_subCtrlView: NSView? { _subCtrlView }
    var horos_toolsMatrix: NSMatrix? { _toolsMatrix }
    var horos_toolsView: NSView? { _toolsView }
    var horos_windowsTiling: NSView? { _windowsTiling }
    var horos_wlwwPopup: NSPopUpButton? { _wlwwPopup }
    var horos_WLWWView: NSView? { _WLWWView }
}

// MARK: - Binding teardown

enum ViewerWindowOutletRoots {
    /// Every outlet, nil ones included: the views, windows and toolbars among
    /// them are where the nib's File's Owner bindings live.
    @MainActor static func roots(of viewer: ViewerController) -> [AnyObject?] {
        [
            viewer._activatedFusion,
            viewer._annotations,
            viewer._BlendingView,
            viewer._buttonToolMatrix,
            viewer._CommentsField,
            viewer._comparativesButton,
            viewer._ConvView,
            viewer._display12bitToolbarItemMatrix,
            viewer._display12bitToolbarItemView,
            viewer._FusionView,
            viewer._keyImageCheck,
            viewer._keyImagePopUpButton,
            viewer._keyImages,
            viewer._loopButton,
            viewer._moviePlayStop,
            viewer._moviePosSlider,
            viewer._movieRateSlider,
            viewer._movieTextSlide,
            viewer._movieView,
            viewer._orientationMatrix,
            viewer._orientationView,
            viewer._PagePad,
            viewer._patientView,
            viewer._popFusion,
            viewer._popupRoi,
            viewer._previewMatrix,
            viewer._previewMatrixScrollView,
            viewer._previewRootView,
            viewer._propagateSettingsView,
            viewer._ReconstructionRoi,
            viewer._ReconstructionView,
            viewer._reportTemplatesImageView,
            viewer._reportTemplatesListPopUpButton,
            viewer._reportTemplatesView,
            viewer._RGBFactorsView,
            viewer._sc1,
            viewer._sc2,
            viewer._sc3,
            viewer._sc4,
            viewer._sc5,
            viewer._sc6,
            viewer._sc7,
            viewer._sc8,
            viewer._sc9,
            viewer._seriesPopupMenu,
            viewer._seriesPopupView,
            viewer._serieView,
            viewer._shutterOnOff,
            viewer._shutterView,
            viewer._slider,
            viewer._sliderFusion,
            viewer._speedSlider,
            viewer._speedText,
            viewer._speedView,
            viewer._splitView,
            viewer._stacksFusion,
            viewer._StatusPopup,
            viewer._StatusView,
            viewer._studyView,
            viewer._subCtrlMaskText,
            viewer._subCtrlOnOff,
            viewer._subCtrlPercent,
            viewer._subCtrlSharpenButton,
            viewer._subCtrlSum,
            viewer._subCtrlView,
            viewer._toolsMatrix,
            viewer._toolsView,
            viewer._viewerView,
            viewer._windowsTiling,
            viewer._windowsTilingMenu,
            viewer._WLWWView,
        ]
    }
}
