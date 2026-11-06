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

/// The preferences of the database, the import, the anonymization and the automatic cleanup. Each key is
/// declared once, with the type it is read as and the value the application registers; `catalog` lists them
/// for DefaultPreferences.
public enum DatabasePreferences {
    /// MR Spectroscopy Storage.
    public static let additionalImageSOPClasses = PreferenceKey<[PropertyListValue]?>("additionalDisplayedStorageSOPClassUIDArray", registered: .value(["1.2.840.10008.5.1.4.1.1.4.2"]))
    public static let albumName = PreferenceKey<String?>("ALBUMNAME", registered: "IsiX DICOM Viewer")
    public static let allowsDICOMEditing = PreferenceKey<Bool>("ALLOWDICOMEDITING", registered: "0")
    public static let archiveReportsAndAnnotationsAsDICOMSR = PreferenceKey<Bool>("archiveReportsAndAnnotationsAsDICOMSR", registered: "1")
    public static let autoCleanCommentFilter = PreferenceKey<Bool>("AUTOCLEANINGCOMMENTS", registered: "0")
    public static let autoCleanCommentText = PreferenceKey<String?>("AUTOCLEANINGCOMMENTSTEXT", registered: "")
    public static let autoCleanByDate = PreferenceKey<Bool>("AUTOCLEANINGDATE", registered: "0")
    public static let autoCleanByDateOpened = PreferenceKey<Bool>("AUTOCLEANINGDATEOPENED", registered: "0")
    public static let autoCleanOpenedDays = PreferenceKey<String?>("AUTOCLEANINGDATEOPENEDDAYS", registered: "90")
    public static let autoCleanByDateProduced = PreferenceKey<Bool>("AUTOCLEANINGDATEPRODUCED", registered: "0")
    public static let autoCleanProducedDays = PreferenceKey<String?>("AUTOCLEANINGDATEPRODUCEDDAYS", registered: "90")
    public static let autoCleanDeletesOriginals = PreferenceKey<Bool>("AUTOCLEANINGDELETEORIGINAL", registered: "0")
    public static let autoCleanCommentMode = PreferenceKey<Int>("AUTOCLEANINGDONTCONTAIN", registered: "0")
    public static let autoCleanBySpace = PreferenceKey<Bool>("AUTOCLEANINGSPACE", registered: "1")
    public static let autoCleanSpaceSize = PreferenceKey<String?>("AUTOCLEANINGSPACESIZE", registered: "1024")
    public static let autocleanSpaceMode = PreferenceKey<Int>("AutocleanSpaceMode", registered: "2")
    /// The switches of the cleaning by free space of earlier versions, which AutocleanSpaceMode replaced:
    /// the oldest studies, the oldest unopened ones.
    public static let formerAutoCleanBySpaceProduced = PreferenceKey<Bool>("AUTOCLEANINGSPACEPRODUCED")
    public static let formerAutoCleanBySpaceOpened = PreferenceKey<Bool>("AUTOCLEANINGSPACEOPENED")
    public static let autoSelectSourceCDDVD = PreferenceKey<Bool>("autoSelectSourceCDDVD", registered: "1")
    public static let capitalizedString = PreferenceKey<Bool>("CapitalizedString", registered: "1")
    public static let ejectsMediaAfterAutoCopy = PreferenceKey<Bool>("CDDVDEjectAfterAutoCopy", registered: "1")
    /// Once a validated report's DICOM PDF is in the study, the report open in Pages is closed.
    public static let closePagesReportWhenValidated = PreferenceKey<Bool>("closePagesReportWhenValidated", registered: "1")
    public static let databaseColumns = PreferenceKey<[String: PropertyListValue]?>("COLUMNSDATABASE", registered: PreferenceDefault { _ in [String: Any]() })
    public static let combineProjectionSeries = PreferenceKey<Bool>("combineProjectionSeries", registered: "1")
    public static let combineProjectionSeriesMode = PreferenceKey<Bool>("combineProjectionSeriesMode", registered: "1")
    public static let commentFieldForAutoFill = PreferenceKey<String?>("commentFieldForAutoFill", registered: "comment")
    public static let commentsAutoFill = PreferenceKey<Bool>("COMMENTSAUTOFILL", registered: "0")
    public static let commentsAutoFillStudyLevel = PreferenceKey<Bool>("COMMENTSAUTOFILLStudyLevel", registered: "1")
    public static let commentsFromDICOMFiles = PreferenceKey<Bool>("CommentsFromDICOMFiles", registered: "1")
    public static let compressionResolutionLimit = PreferenceKey<Int>("CompressionResolutionLimit", registered: "512")
    public static let compressionSettings = PreferenceKey<[PropertyListValue]?>("CompressionSettings", registered: PreferenceDefault { _ in DatabasePreferences.factoryCompression(quality: "1") })
    public static let compressionSettingsLowRes = PreferenceKey<[PropertyListValue]?>("CompressionSettingsLowRes", registered: PreferenceDefault { _ in DatabasePreferences.factoryCompression(quality: "0") })
    public static let copyToDatabase = PreferenceKey<Bool>("COPYDATABASE", registered: PreferenceDefault { environment in environment.viewer ? "1" : "0" })
    public static let copyToDatabaseMode = PreferenceKey<Int>("COPYDATABASEMODE", registered: "3")
    public static let databaseIndex = PreferenceKey<Int>("DATABASEINDEX", registered: "0")
    public static let databaseLocation = PreferenceKey<Int>("DATABASELOCATION", registered: "0")
    public static let databaseLocationURL = PreferenceKey<String?>("DATABASELOCATIONURL", registered: "")
    public static let databaseRefreshInterval = PreferenceKey<Int>("DatabaseRefreshInterval", registered: "120")
    public static let databaseDateFormat = PreferenceKey<String?>("DBDateFormat2", registered: PreferenceDefault { _ in
        // The short date and time format of the user's locale.
        let format = DateFormatter()
        format.dateStyle = .short
        format.timeStyle = .short
        return format.dateFormat
    })
    public static let databaseBirthDateFormat = PreferenceKey<String?>("DBDateOfBirthFormat2", registered: PreferenceDefault { _ in
        // The short date format of the user's locale.
        let format = DateFormatter()
        format.dateStyle = .short
        return format.dateFormat
    })
    public static let defaultDatabaseLocation = PreferenceKey<Int>("DEFAULT_DATABASELOCATION", registered: "0")
    public static let defaultDatabaseLocationURL = PreferenceKey<String?>("DEFAULT_DATABASELOCATIONURL", registered: "")
    /// The name the Database pane shows for the default location, written by each launch in its language.
    public static let defaultDatabasePathDescription = PreferenceKey<String?>("DefaultDatabasePath")
    /// The files the listener received stay in the incoming folder when the application quits.
    public static let keepsIncomingFolderFiles = PreferenceKey<Bool>("DoNotEmptyIncomingDir")
    /// The files received go to the default database only, whichever database is open.
    public static let addsIncomingFilesToDefaultDatabaseOnly = PreferenceKey<Bool>("addNewIncomingFilesToDefaultDBOnly")
    /// Empty means the standard's default. A DICOM term or a code page name here is what a file that states
    /// no Specific Character Set is read as; a file that states one is unaffected.
    public static let defaultCharacterSetWhenAbsent = PreferenceKey<String?>("DefaultCharacterSetWhenAbsent", registered: "")
    public static let defaultFolderSizeForDB = PreferenceKey<Int>("DefaultFolderSizeForDB", registered: "10000")
    public static let deletesListenerFiles = PreferenceKey<Bool>("DELETEFILELISTENER", registered: "1")
    public static let dicomImageScreenCaptureHeight = PreferenceKey<Int>("DicomImageScreenCaptureHeight", registered: "1024")
    public static let dicomImageScreenCaptureWidth = PreferenceKey<Int>("DicomImageScreenCaptureWidth", registered: "1024")
    public static let displaySamePatientWithColorBackground = PreferenceKey<Bool>("displaySamePatientWithColorBackground", registered: "1")
    public static let dontDeleteStudiesWithComments = PreferenceKey<Bool>("dontDeleteStudiesWithComments", registered: "1")
    /// NSDrawerOpenState.
    public static let drawerState = PreferenceKey<Int>("drawerState", registered: "2")
    public static let ejectsMedia = PreferenceKey<Bool>("EJECTCDDVD", registered: "1")
    public static let hidesPatientName = PreferenceKey<Bool>("HIDEPATIENTNAME", registered: "0")
    public static let keepStudiesOfSamePatientTogether = PreferenceKey<Bool>("KeepStudiesOfSamePatientTogether", registered: "1")
    public static let keepStudiesOfSamePatientTogetherAndGrouped = PreferenceKey<Bool>("KeepStudiesOfSamePatientTogetherAndGrouped", registered: "1")
    public static let logRetentionDays = PreferenceKey<Int>("LOGCLEANINGDAYS", registered: "7")
    public static let maxNumberOfFilesForCheckIncoming = PreferenceKey<Int>("maxNumberOfFilesForCheckIncoming", registered: "10000")
    public static let maxNumberOfRecentStudies = PreferenceKey<Int>("MaxNumberOfRecentStudies", registered: "20")
    public static let mountAction = PreferenceKey<Int>("MOUNT", registered: "-1")
    public static let noLocalizer = PreferenceKey<Bool>("NOLOCALIZER", registered: "1")
    public static let localizerNames = PreferenceKey<String?>("NOLOCALIZER_Strings", registered: "localizer,scout,survey,locator,tracker")
    public static let onlyDICOM = PreferenceKey<Bool>("onlyDICOM", registered: "1")
    public static let recomputePatientUID = PreferenceKey<Bool>("recomputePatientUID", registered: "0")
    public static let replaceAnonymize = PreferenceKey<Bool>("replaceAnonymize", registered: "0")
    public static let reportsMode = PreferenceKey<Int>("REPORTSMODE", registered: "2")
    /// The name of the report plugin the Database pane chose, which writes the new reports when
    /// `reportsMode` is 3 and gives the date of the study list's report column.
    public static let reportsPlugin = PreferenceKey<String?>("REPORTSPLUGIN")
    /// Selecting an album, or showing another database, also clears the search field and the time
    /// interval; selecting "Database" keeps them.
    public static let clearsSearchWhenSelectingAlbum = PreferenceKey<Bool>("clearSearchAndTimeIntervalWhenSelectingAlbum")
    public static let savedCommentsAndStatusInDICOMFiles = PreferenceKey<Bool>("savedCommentsAndStatusInDICOMFiles", registered: "1")
    /// A DICOMDIR is supposed to name every instance on the medium; some name fewer, and what it leaves out
    /// is on the disc all the same. Reading the disc as well costs time and is the only way to be sure
    /// nothing is left behind.
    public static let scanDiskBeyondDICOMDIR = PreferenceKey<Bool>("ScanDiskBeyondDICOMDIR", registered: "YES")
    public static let scanDiskIfDICOMDIRZero = PreferenceKey<Bool>("ScanDiskIfDICOMDIRZero", registered: "1")
    public static let separateCardiac4D = PreferenceKey<Bool>("SEPARATECARDIAC4D", registered: "1")
    public static let seriesOrder = PreferenceKey<Int>("SERIESORDER", registered: "0")
    public static let showAlbumOnlyIfNotEmpty = PreferenceKey<Bool>("ShowAlbumOnlyIfNotEmpty", registered: "1")
    public static let splitMultiEchoMR = PreferenceKey<Bool>("splitMultiEchoMR", registered: "1")
    public static let storeThumbnailsInDB = PreferenceKey<Bool>("StoreThumbnailsInDB", registered: "1")
    public static let syncPreviewList = PreferenceKey<Bool>("syncPreviewList", registered: "1")
    /// Its presence says the defaults are registered (DicomFile.setDefaults); DCMTK is the only parser.
    public static let toolkitParser = PreferenceKey<Int>("TOOLKITPARSER4", registered: "2")
    public static let useDCMTKForAnonymization = PreferenceKey<Bool>("useDCMTKForAnonymization", registered: "1")
    public static let usesDICOMDIRFile = PreferenceKey<Bool>("UseDICOMDIRFileCD", registered: "1")
    public static let useJPEGColorSpace = PreferenceKey<Bool>("UseJPEGColorSpace", registered: "1")
    public static let usePatientBirthDateForUID = PreferenceKey<Bool>("UsePatientBirthDateForUID", registered: "1")
    public static let usePatientIDForUID = PreferenceKey<Bool>("UsePatientIDForUID", registered: "1")
    public static let usePatientNameForUID = PreferenceKey<Bool>("UsePatientNameForUID", registered: "1")
    public static let useSeriesDescription = PreferenceKey<Bool>("useSeriesDescription", registered: "0")
    public static let useSoundexForName = PreferenceKey<Bool>("useSoundexForName", registered: "0")
    public static let validateFilesBeforeImporting = PreferenceKey<Bool>("validateFilesBeforeImporting", registered: "0")
    public static let yearOldDatabaseDisplay = PreferenceKey<Int>("yearOldDatabaseDisplay", registered: "2")
    public static let commentsGroup = PreferenceKey<Int>("COMMENTSGROUP")
    public static let commentsElement = PreferenceKey<Int>("COMMENTSELEMENT")
    public static let commentsGroup2 = PreferenceKey<Int>("COMMENTSGROUP2")
    public static let commentsElement2 = PreferenceKey<Int>("COMMENTSELEMENT2")
    public static let commentsGroup3 = PreferenceKey<Int>("COMMENTSGROUP3")
    public static let commentsElement3 = PreferenceKey<Int>("COMMENTSELEMENT3")
    public static let commentsGroup4 = PreferenceKey<Int>("COMMENTSGROUP4")
    public static let commentsElement4 = PreferenceKey<Int>("COMMENTSELEMENT4")
    public static let oneFileOnSeriesForUS = PreferenceKey<Bool>("oneFileOnSeriesForUS")
    public static let hiddenImageSOPClasses = PreferenceKey<[PropertyListValue]?>("hiddenDisplayedStorageSOPClassUIDArray")
    public static let generatesDICOMPDFWhenValidated = PreferenceKey<Bool>("generateDICOMPDFWhenValidated")
    /// The series description of a report's DICOM PDF, put in the file as it is stored; "Report PDF" when absent.
    public static let reportName = PreferenceKey<PropertyListValue?>("ReportName")
    public static let sortSeriesBySliceLocation = PreferenceKey<Int>("sortSeriesBySliceLocation")
    public static let erasesEntireDatabaseAtStartup = PreferenceKey<Bool>("eraseEntireDBAtStartup")
    /// The local databases the browser lists beside the default one.
    public static let localDatabaseSources = PreferenceKey<LocalDatabaseSources?>("localDatabasePaths")
    /// The model version of the last index saved.
    public static let databaseVersion = PreferenceKey<String?>("DATABASEVERSION")
    /// On when `-integerValue` of the number or the text stored is not 0, as it was always read.
    public static let iCloudDriveSyncRiskIgnored = PreferenceKey<PropertyListValue?>("ICLOUD_DRIVE_SYNC_RISK_USER_IGNORED")
    public static let cloudActiveDatabaseWarningIgnored = PreferenceKey<Bool>("CLOUD_ACTIVE_DATABASE_WARNING_IGNORED")
    /// The security-scoped bookmark of each folder the App Store build was given, by its path.
    public static let sandboxFolderBookmarks = PreferenceKey<[String: PropertyListValue]?>("SandboxFolderBookmarks")
    /// The base directories of the databases whose MONOCHROME1 thumbnails were rebuilt.
    public static let monochrome1ThumbnailsRebuiltDatabases = PreferenceKey<[String]?>("MONOCHROME1ThumbnailsRebuiltDatabases")
    public static let databaseHistoryWidth = PreferenceKey<Double>("DatabaseHistoryWidth")
    /// The answer to the OsiriX migration, an integer number; text is not an answer.
    public static let o2hMigrationUserAction = PreferenceKey<PropertyListValue?>("O2H_MIGRATION_USER_ACTION")
    /// The accounts database of the Web Portal, when it is not the default one.
    public static let webPortalDatabasePath = PreferenceKey<String?>("WebPortalDatabasePath")
    public static let commentsAutoFillSeriesLevel = PreferenceKey<Bool>("COMMENTSAUTOFILLSeriesLevel")
    public static let acceptsUnsupportedSOPClassUID = PreferenceKey<Bool>("acceptUnsupportedSOPClassUID")
    public static let replacesWithNewIncomingFile = PreferenceKey<Bool>("REPLACE_WITH_NEW_INCOMING_FILE")
    public static let decompressMovesUnreadableFiles = PreferenceKey<Bool>("DecompressMoveIfFail")
    public static let hidesFreeSpaceLimitSoonReachedWarning = PreferenceKey<Bool>("hideCleanForFreeSpaceLimitSoonReachedWarning")
    public static let patientListIdentifierPattern = PreferenceKey<String?>("PatientListIdentifierPattern")
    public static let patientListIgnoredLines = PreferenceKey<[String]?>("PatientListIgnoredLines")
    /// What becomes of a series a viewer generated once it is in the database.
    public static let afterExportSendsToDICOMNode = PreferenceKey<Bool>("afterExportSendToDICOMNode")
    public static let afterExportMarksKeyImages = PreferenceKey<Bool>("afterExportMarkThemAsKeyImages")
    public static let databaseLocationChoiceCompleted = PreferenceKey<Bool>("DatabaseLocationChoiceCompleted")
    public static let databaseLocationChoicePending = PreferenceKey<Bool>("DatabaseLocationChoicePending")
    /// The `Horos Data` directories this installation opens as its own database.
    public static let adoptedHorosDirectories = PreferenceKey<[String]?>("AdoptedHorosDataDirectories")
    /// The `Horos Data` directories whose user chose to keep them without being asked again.
    public static let keptHorosDirectories = PreferenceKey<[String]?>("KeptHorosDataDirectories")
    /// What the anonymization panel of the database window and of the burner saves.
    public static let anonymizationFields = anonymizationFields(forPanel: "AnonymizationFields")
    public static let anonymizationFieldList = anonymizationFieldList(forPanel: "AnonymizationFields")
    /// The saved templates of the anonymization panel, by name.
    public static let anonymizationTemplates = PreferenceKey<AnonymizationTemplates?>("anonymizeTemplate")

    /// The location the application opens.
    public static let location = DatabaseLocationKeys(mode: databaseLocation, folder: databaseLocationURL)
    /// The location the user chose, which the next start copies into `location`.
    public static let defaultLocation = DatabaseLocationKeys(mode: defaultDatabaseLocation, folder: defaultDatabaseLocationURL)

    /// The fields and values an anonymization panel saves under `defaultsKey`, the key its caller names
    /// (a former plugin may name its own).
    public static func anonymizationFields(forPanel defaultsKey: String) -> PreferenceKey<AnonymizationFieldValues?> {
        PreferenceKey(defaultsKey)
    }

    /// The fields an anonymization panel shows, saved under `defaultsKey` followed by "All".
    public static func anonymizationFieldList(forPanel defaultsKey: String) -> PreferenceKey<AnonymizationFieldList?> {
        PreferenceKey(defaultsKey + "All")
    }

    /// Every key of this file.
    static let catalog: [any CataloguedPreference] = [
        additionalImageSOPClasses, albumName, allowsDICOMEditing, archiveReportsAndAnnotationsAsDICOMSR,
        autoCleanCommentFilter, autoCleanCommentText, autoCleanByDate, autoCleanByDateOpened, autoCleanOpenedDays,
        autoCleanByDateProduced, autoCleanProducedDays, autoCleanDeletesOriginals, autoCleanCommentMode,
        autoCleanBySpace, autoCleanSpaceSize, autocleanSpaceMode, autoSelectSourceCDDVD, capitalizedString,
        ejectsMediaAfterAutoCopy, closePagesReportWhenValidated, databaseColumns, combineProjectionSeries,
        combineProjectionSeriesMode, commentFieldForAutoFill, commentsAutoFill, commentsAutoFillStudyLevel,
        commentsFromDICOMFiles, compressionResolutionLimit, compressionSettings, compressionSettingsLowRes,
        copyToDatabase, copyToDatabaseMode, databaseIndex, databaseLocation, databaseLocationURL,
        databaseRefreshInterval, databaseDateFormat, databaseBirthDateFormat, defaultDatabaseLocation,
        defaultDatabaseLocationURL, defaultCharacterSetWhenAbsent, defaultFolderSizeForDB, deletesListenerFiles,
        dicomImageScreenCaptureHeight, dicomImageScreenCaptureWidth, displaySamePatientWithColorBackground,
        dontDeleteStudiesWithComments, drawerState, ejectsMedia, hidesPatientName, keepStudiesOfSamePatientTogether,
        keepStudiesOfSamePatientTogetherAndGrouped, logRetentionDays, maxNumberOfFilesForCheckIncoming,
        maxNumberOfRecentStudies, mountAction, noLocalizer, localizerNames, onlyDICOM, recomputePatientUID,
        replaceAnonymize, reportsMode, reportsPlugin, clearsSearchWhenSelectingAlbum, savedCommentsAndStatusInDICOMFiles, scanDiskBeyondDICOMDIR,
        scanDiskIfDICOMDIRZero, separateCardiac4D, seriesOrder, showAlbumOnlyIfNotEmpty, splitMultiEchoMR,
        storeThumbnailsInDB, syncPreviewList, toolkitParser, useDCMTKForAnonymization, usesDICOMDIRFile,
        useJPEGColorSpace, usePatientBirthDateForUID, usePatientIDForUID, usePatientNameForUID, useSeriesDescription,
        useSoundexForName, validateFilesBeforeImporting, yearOldDatabaseDisplay, commentsGroup, commentsElement,
        commentsGroup2, commentsElement2, commentsGroup3, commentsElement3, commentsGroup4, commentsElement4,
        oneFileOnSeriesForUS, hiddenImageSOPClasses, generatesDICOMPDFWhenValidated, reportName,
        sortSeriesBySliceLocation, erasesEntireDatabaseAtStartup, localDatabaseSources, databaseVersion,
        iCloudDriveSyncRiskIgnored, cloudActiveDatabaseWarningIgnored, sandboxFolderBookmarks,
        monochrome1ThumbnailsRebuiltDatabases, databaseHistoryWidth, o2hMigrationUserAction, webPortalDatabasePath,
        commentsAutoFillSeriesLevel, acceptsUnsupportedSOPClassUID, replacesWithNewIncomingFile,
        decompressMovesUnreadableFiles, hidesFreeSpaceLimitSoonReachedWarning, patientListIdentifierPattern,
        patientListIgnoredLines, afterExportSendsToDICOMNode, afterExportMarksKeyImages, databaseLocationChoiceCompleted,
        databaseLocationChoicePending, adoptedHorosDirectories, keptHorosDirectories, anonymizationFields,
        anonymizationFieldList, anonymizationTemplates, formerAutoCleanBySpaceProduced, formerAutoCleanBySpaceOpened,
        defaultDatabasePathDescription, keepsIncomingFolderFiles, addsIncomingFilesToDefaultDatabaseOnly,
    ]
}
