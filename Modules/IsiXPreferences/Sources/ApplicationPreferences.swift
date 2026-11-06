/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The preferences of the export, the burning of media and the windows of the application. Each key is
/// declared once, with the type it is read as and the value the application registers; `catalog` lists them
/// for DefaultPreferences. A key with no registered value is read as the reader always read it: absent is false,
/// 0 or nil.
public enum ApplicationPreferences {
    public static let addDICOMDIRForExport = PreferenceKey<Bool>("AddDICOMDIRForExport")
    /// The export to a folder keeps the private SR series of ROIs, reports and annotations.
    public static let addROIsForExport = PreferenceKey<Bool>("AddROIsForExport")
    public static let anonymizedBeforeBurning = PreferenceKey<Bool>("anonymizedBeforeBurning", registered: "0")
    public static let authentication = PreferenceKey<Bool>("AUTHENTICATION", registered: "0")
    /// Where a burn writes: the tag of the burn window's destination (CD/DVD, USB key, disc image).
    public static let burnDestination = PreferenceKey<Int>("burnDestination")
    public static let burnHtml = PreferenceKey<Bool>("BurnHtml", registered: "1")
    public static let burnSupplementaryFolder = PreferenceKey<Bool>("BurnSupplementaryFolder", registered: "0")
    public static let burnWeasis = PreferenceKey<Bool>("BurnWeasis")
    public static let checkForUpdatesPlugins = PreferenceKey<Bool>("checkForUpdatesPlugins", registered: "0")
    public static let checkHorosUpdates = PreferenceKey<Bool>("CheckHorosUpdates", registered: "1")
    /// The tag of the burn window's compression choice when it last closed: none, compress, decompress.
    public static let burnCompressionMode = PreferenceKey<Int>("Compression Mode for Burning")
    public static let exportCompressionMode = PreferenceKey<Int>("Compression Mode for Export", registered: "0")
    public static let copyReportsToMedia = PreferenceKey<Bool>("copyReportsToCD")
    public static let dcmExportFormat = PreferenceKey<Int>("dcmExportFormat", registered: "1")
    /// The warning that DICOM editing is now on is not shown again.
    public static let dicomEditingWarningSuppressed = PreferenceKey<Bool>("DICOM Editing Warning")
    /// The folder names of the last export to a folder the person accepted.
    public static let exportFolderFields = PreferenceKey<ExportFolderFields?>("DICOMExportFolderFields")
    public static let doNotDeleteCrashingPlugins = PreferenceKey<Bool>("DoNotDeleteCrashingPlugins", registered: "0")
    public static let editingLevel = PreferenceKey<Int>("editingLevel", registered: "1")
    public static let encryptsBurnedMedia = PreferenceKey<Bool>("EncryptCD")
    /// The export to a folder packs its folders into a ZIP archive protected by the export's password.
    public static let encryptsExport = PreferenceKey<Bool>("encryptForExport")
    /// The password of the archive "Send by e-mail" attaches, typed in its sheet, which binds this key.
    public static let emailZIPPassword = PreferenceKey<String?>("defaultZIPPasswordForEmail")
    /// Whether a burn that compresses writes JPEG instead of JPEG 2000.
    public static let burnsJPEGInsteadOfJPEG2000 = PreferenceKey<Bool>("JPEGinsteadJPEG2000")
    /// The detached toolbar of the viewers is hidden while no viewer is the active window.
    public static let hidesToolbarIfNotActive = PreferenceKey<Bool>("hideToolbarIfNotActive")
    public static let lastURL = PreferenceKey<String?>("LASTURL", registered: "http://www.horosproject.org/internet.dcm")
    public static let macAppStore = PreferenceKey<Bool>("MACAPPSTORE", registered: PreferenceDefault { environment in environment.appStore ? "1" : "0" })
    public static let magneticWindows = PreferenceKey<Bool>("MagneticWindows", registered: "1")
    /// The offer to move the application to an Applications folder is not made again.
    public static let moveToApplicationsFolderAlertSuppressed = PreferenceKey<Bool>("moveToApplicationsFolderAlertSuppress")
    public static let animatesWindowFrames = PreferenceKey<Bool>("NSWindowsSetFrameAnimate", registered: "1")
    public static let originalSize = PreferenceKey<Bool>("ORIGINALSIZE", registered: "0")
    /// The plugin environment (OSIEnvironment) is made; the application turns it off when it fails.
    public static let osiEnvironmentActivated = PreferenceKey<Bool>("OSIEnvironmentActivated")
    public static let preferencesModificationsEnabled = PreferenceKey<Bool>("preferencesModificationsEnabled", registered: "1")
    public static let quicktimeExportRateValue = PreferenceKey<Int>("quicktimeExportRateValue", registered: "10")
    /// The name of the series key images captured from the screen go to; the default name when absent.
    public static let screenCaptureSeriesName = PreferenceKey<String?>("screenCaptureKeyImageSeriesName")
    /// AVVideoCodecTypeJPEG, written out: the module does not link AVFoundation for one string.
    public static let selectedMenuAVFoundationExport = PreferenceKey<String?>("selectedMenuAVFoundationExport", registered: "jpeg")
    public static let startCount = PreferenceKey<Int>("STARTCOUNT", registered: "1")
    /// The columns of the last study metadata export, one per line, as typed in its panel.
    public static let studyMetadataCSVColumns = PreferenceKey<String?>("StudyMetadataCSVColumns")
    public static let supplementaryBurnPath = PreferenceKey<String?>("SupplementaryBurnPath", registered: "/~Documents/FolderToBurn")
    public static let surveyDone = PreferenceKey<Bool>("SURVEYDONE3", registered: "0")
    public static let useDCMTKForDicomExport = PreferenceKey<Bool>("useDCMTKForDicomExport", registered: "1")
    /// The survey of the 5.x versions was answered.
    public static let surveyDone5 = PreferenceKey<Bool>("SURVEYDONE5")

    // What each launch writes, and what the application keeps of the last run.
    /// AppKit's own key: the milliseconds before a tool tip shows.
    public static let initialToolTipDelay = PreferenceKey<Int>("NSInitialToolTipDelay")
    /// The offset from GMT, in seconds, of the first launch.
    public static let timeZone = PreferenceKey<Int>("timeZone")
    /// Written by each launch for the former plugins, which read them: the application is 64-bit, it runs on
    /// a system later than Mac OS X 10.6, and no 12-bit display plugin is loaded yet.
    public static let is64Bit = PreferenceKey<Bool>("LP64bit")
    public static let hasMacOSXSnowLeopard = PreferenceKey<Bool>("hasMacOSXSnowLeopard")
    public static let is12BitPluginAvailable = PreferenceKey<Bool>("is12bitPluginAvailable")
    /// The Query window was open at the last quit: the next launch opens it again.
    public static let isQueryWindowVisible = PreferenceKey<Bool>("isQueryControllerVisible")
    /// The preferences are read from a URL at each launch, and that URL.
    public static let syncsPreferencesFromURL = PreferenceKey<Bool>("SyncPreferencesFromURL")
    public static let preferencesSyncURL = PreferenceKey<String?>("SyncPreferencesURL")

    /// The frames of the subviews of a split view, saved under the name its window gives it: one
    /// NSStringFromRect text per subview. A plugin may save a split view of its own under any name.
    public static func splitViewFrames(_ name: String) -> PreferenceKey<[PropertyListValue]?> {
        PreferenceKey(name)
    }

    /// The split views of the database window.
    public static let splitViewNames = ["SplitAlbums", "SplitComparative", "SplitDrawer", "SplitHorz2", "SplitVert2"]

    /// Every key of this file.
    static let catalog: [any CataloguedPreference] = [
        addDICOMDIRForExport, addROIsForExport, anonymizedBeforeBurning, authentication, burnDestination, burnHtml,
        burnSupplementaryFolder, burnWeasis, checkForUpdatesPlugins, checkHorosUpdates, burnCompressionMode,
        exportCompressionMode, copyReportsToMedia, dcmExportFormat, dicomEditingWarningSuppressed, exportFolderFields,
        doNotDeleteCrashingPlugins, editingLevel, encryptsBurnedMedia, encryptsExport, emailZIPPassword, burnsJPEGInsteadOfJPEG2000,
        hidesToolbarIfNotActive, lastURL, macAppStore, magneticWindows, moveToApplicationsFolderAlertSuppressed,
        animatesWindowFrames, originalSize, osiEnvironmentActivated, preferencesModificationsEnabled,
        quicktimeExportRateValue, screenCaptureSeriesName, selectedMenuAVFoundationExport, startCount,
        studyMetadataCSVColumns, supplementaryBurnPath, surveyDone, useDCMTKForDicomExport,
        surveyDone5, initialToolTipDelay, timeZone, is64Bit, hasMacOSXSnowLeopard, is12BitPluginAvailable,
        isQueryWindowVisible, syncsPreferencesFromURL, preferencesSyncURL,
    ] + splitViewNames.map(splitViewFrames)
}
