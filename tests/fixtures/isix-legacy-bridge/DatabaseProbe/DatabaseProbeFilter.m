//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A legacy database plugin written the way Horos plugins were, for the kit's
// test: it goes through the database part of IsiXLegacyBridge - the browser's
// selection, key-value coding, NSFetchRequest and NSPredicate, the fields
// the user edits, albums, DCMObject and DICOMExport, adding files - and
// writes what it saw to the property list named by ISIX_LEGACY_PROBE_OUTPUT.
// Its second and third commands make changes the database must refuse. The
// test compiles it with manual reference counting and with ARC.

#import <Foundation/Foundation.h>
#import "PluginFilter.h"
#import "BrowserController.h"
#import "DicomDatabase.h"
#import "DicomStudy.h"
#import "DicomSeries.h"
#import "DicomImage.h"
#import "DicomAlbum.h"
#import "DICOMExport.h"
#import <OsiriX/DCMObject.h>

@interface DatabaseProbeFilter : PluginFilter
@end

@implementation DatabaseProbeFilter

- (DicomStudy*) selectedStudy
{
    return [[[BrowserController currentBrowser] databaseSelection] objectAtIndex: 0];
}

- (long) filterImage: (NSString*) menuName
{
    if ([menuName isEqualToString: @"Database Probe Refused State"])
    {
        // A state the database does not have: refused, and nothing changes.
        [[self selectedStudy] setValue: [NSNumber numberWithInt: 9] forKey: @"stateText"];
        return 0;
    }
    if ([menuName isEqualToString: @"Database Probe Read-only Attribute"])
    {
        // The patient's name is the database's to keep.
        [[self selectedStudy] setValue: @"RENAMED^PATIENT" forKey: @"name"];
        return 0;
    }

    if ([menuName isEqualToString: @"Database Probe Viewer Export"])
    {
        // The image shown, exported twice under one name (one series), then added;
        // a capture of the viewer as drawn is refused.
        BrowserController *browser = [BrowserController currentBrowser];
        NSDictionary *first = [viewerController exportDICOMFileInt: 0 withName: @"Legacy viewer export" allViewers: NO];
        NSDictionary *second = [viewerController exportDICOMFileInt: 0 withName: @"Legacy viewer export" allViewers: NO];
        [viewerController adjustSlider];
        NSArray *files = [NSArray arrayWithObjects: [first objectForKey: @"file"], [second objectForKey: @"file"], nil];
        [BrowserController addFiles: files toContext: [browser managedObjectContext] toDatabase: browser onlyDICOM: YES
                   notifyAddedFiles: YES parseExistingObject: YES dbFolder: [browser documentsDirectory] generatedByOsiriX: YES];
        return [viewerController exportDICOMFileInt: 1 withName: @"Legacy capture" allViewers: NO] == nil ? 0 : -1;
    }

    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    report[@"arc"] = @(__has_feature(objc_arc) ? YES : NO);
    BrowserController *browser = [BrowserController currentBrowser];

    // The selection and key-value coding of the legacy attribute names.
    NSArray *selection = [browser databaseSelection];
    report[@"selection"] = [selection valueForKey: @"type"];
    DicomStudy *study = [selection objectAtIndex: 0];
    report[@"patient"] = [study valueForKey: @"name"];
    report[@"studyName"] = study.studyName;
    report[@"seriesCount"] = [study valueForKeyPath: @"series.@count"];
    report[@"entity"] = [[study entity] name];
    // The study's CT series: the application adds its own SR series to a study
    // whose comments, state or report change.
    DicomSeries *series = [[[study imageSeries] filteredArrayUsingPredicate: [NSPredicate predicateWithFormat: @"modality == 'CT'"]] lastObject];
    report[@"seriesStudyIsSame"] = @([series study] == study);
    NSArray *images = [series sortedImages];
    report[@"instanceNumbers"] = [images valueForKey: @"instanceNumber"];
    report[@"imagePatientID"] = [[images objectAtIndex: 0] valueForKeyPath: @"series.study.patientID"];

    // A fetch of the kit's context, with a predicate and sort descriptors.
    NSManagedObjectContext *context = [browser managedObjectContext];
    NSFetchRequest *request = [[NSFetchRequest alloc] init];
    [request setEntity: [NSEntityDescription entityForName: @"Study" inManagedObjectContext: context]];
    [request setPredicate: [NSPredicate predicateWithFormat: @"name CONTAINS[cd] %@ AND ANY series.modality == %@", @"legacy", @"CT"]];
    NSError *error = nil;
    report[@"fetchedStudies"] = [[context executeFetchRequest: request error: &error] valueForKey: @"studyInstanceUID"];
#if !__has_feature(objc_arc)
    [request release];
#endif
    NSFetchRequest *imageRequest = [NSFetchRequest fetchRequestWithEntityName: @"Image"];
    imageRequest.predicate = [NSPredicate predicateWithFormat: @"series.study.studyInstanceUID == %@ AND instanceNumber >= 2", study.studyInstanceUID];
    imageRequest.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey: @"instanceNumber" ascending: NO]];
    report[@"fetchedImages"] = [[context executeFetchRequest: imageRequest error: &error] valueForKey: @"instanceNumber"];
    report[@"countedSeries"] = @([context countForFetchRequest: [NSFetchRequest fetchRequestWithEntityName: @"Series"] error: &error]);
    DicomDatabase *database = [DicomDatabase activeLocalDatabase];
    report[@"objectsForEntity"] = @([[database objectsForEntity: @"Series" predicate: [NSPredicate predicateWithFormat: @"modality == 'CT'"]] count]);

    // The fields the user edits.
    [study setComment: @"from a legacy plugin"];
    [study setValue: [NSNumber numberWithInt: 2] forKey: @"stateText"];
    [study setValue: @"http://reports.example/legacy" forKey: @"reportURL"];
    [series setValue: @"series note" forKey: @"comment2"];
    [[images objectAtIndex: 1] setIsKeyImage: [NSNumber numberWithBool: YES]];
    report[@"comment"] = study.comment;
    report[@"state"] = study.stateText;
    report[@"report"] = study.reportURL;
    report[@"seriesComment2"] = series.comment2;
    report[@"keyImages"] = [[[study keyImages] allObjects] valueForKey: @"instanceNumber"];

    // Albums.
    DicomAlbum *album = [database newAlbumWithName: @"Legacy album"];
    [album addStudiesObject: study];
    report[@"albumStudies"] = [[[album studies] allObjects] valueForKey: @"studyInstanceUID"];
    report[@"studyAlbums"] = [[[study albums] allObjects] valueForKey: @"name"];

    // A DICOM object written, read back and added to the database.
    DCMObject *object = [DCMObject secondaryCaptureObjectWithBitDepth: 16 samplesPerPixel: 1 numberOfFrames: 1];
    [object setAttributeValues: [NSMutableArray arrayWithObject: @"PROBE^OBJECT"] forName: @"PatientsName"];
    [object setAttributeValues: [NSMutableArray arrayWithObject: @"PROBE-1"] forName: @"PatientID"];
    [object setAttributeValues: [NSMutableArray arrayWithObject: [DCMCalendarDate dicomDate: @"20260102"]] forName: @"StudyDate"];
    [object setAttributeValues: [NSMutableArray arrayWithObjects: [NSNumber numberWithFloat: 0.5f], [NSNumber numberWithFloat: 0.75f], nil] forName: @"PixelSpacing"];
    for (NSString *name in @[@"Rows", @"Columns"]) [object setAttributeValues: [NSMutableArray arrayWithObject: [NSNumber numberWithInt: 2]] forName: name];
    for (NSString *name in @[@"BitsAllocated", @"BitsStored"]) [object setAttributeValues: [NSMutableArray arrayWithObject: [NSNumber numberWithInt: 16]] forName: name];
    [object setAttributeValues: [NSMutableArray arrayWithObject: [NSNumber numberWithInt: 15]] forName: @"HighBit"];
    [object setAttributeValues: [NSMutableArray arrayWithObject: [NSNumber numberWithInt: 1]] forName: @"SamplesperPixel"];
    [object setAttributeValues: [NSMutableArray arrayWithObject: @"MONOCHROME2"] forName: @"PhotometricInterpretation"];
    unsigned short samples[4] = {1, 2, 300, 40000};
    DCMPixelDataAttribute *pixels = [[DCMPixelDataAttribute alloc] initWithAttributeTag: [DCMAttributeTag tagWithName: @"PixelData"] vr: @"OW" length: 8 data: nil specificCharacterSet: nil transferSyntax: [DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax] dcmObject: object decodeData: NO];
    [pixels addFrame: [NSMutableData dataWithBytes: samples length: sizeof samples]];
    [object setAttribute: pixels];
#if !__has_feature(objc_arc)
    [pixels release];
#endif
    NSString *objectPath = [[DicomDatabase activeLocalDatabase] uniquePathForNewDataFileWithExtension: @"dcm"];
    report[@"objectWritten"] = @([object writeToFile: objectPath withTransferSyntax: [DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax] quality: 0 atomically: YES]);
    DCMObject *reread = [DCMObject objectWithContentsOfFile: objectPath decodingPixelData: NO];
    report[@"rereadName"] = [reread attributeValueWithName: @"PatientName"];
    report[@"rereadSpacing"] = [[reread attributeWithName: @"PixelSpacing"] values];
    report[@"rereadDate"] = [[reread attributeValueWithName: @"StudyDate"] description];
    report[@"rereadRows"] = [reread attributeValueForKey: @"0028,0010"];
    report[@"rereadPixels"] = [[[reread attributeWithName: @"PixelData"] value] isKindOfClass: [NSData class]] ? @([[[reread attributeWithName: @"PixelData"] value] length]) : @0;
    report[@"tagByString"] = [[DCMAttributeTag tagWithTagString: @"0010,0010"] name];
    NSArray *added = [browser addFilesToDatabase: [NSArray arrayWithObject: objectPath]];
    report[@"addedObjectImages"] = @([added count]);
    report[@"addedObjectPatient"] = [[added lastObject] valueForKeyPath: @"series.study.name"];

    // A derived image of the study, written by the application and added.
    DicomImage *source = [images objectAtIndex: 0];
    DICOMExport *exporter = [[DICOMExport alloc] init];
    [exporter setSourceFile: [source completePath]];
    [exporter setSeriesDescription: @"Legacy export"];
    [exporter setSeriesNumber: 7001];
    short raw[24];
    for (int i = 0; i < 24; i++) raw[i] = (short) (i * 3 - 20);
    [exporter setPixelData: (unsigned char*) raw samplesPerPixel: 1 bitsPerSample: 16 width: 6 height: 4];
    [exporter setSigned: YES];
    [exporter setSlope: 0.5f];
    [exporter setPixelSpacing: 0.5f :0.5f];
    NSString *first = [exporter writeDCMFile: nil];
    NSString *second = [exporter writeDCMFile: nil];
#if !__has_feature(objc_arc)
    [exporter release];
#endif
    // The former setter, as BullsEye and Coronary call it: three samples of 8 bits.
    DICOMExport *colour = [[DICOMExport alloc] init];
    [colour setSourceFile: [source completePath]];
    [colour setSeriesDescription: @"Legacy colour"];
    [colour setSeriesNumber: 7002];
    unsigned char rgb[2 * 2 * 3] = {255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30};
    [colour setPixelData: rgb samplePerPixel: 3 bitsPerPixel: 8 width: 2 height: 2];
    report[@"colourWritten"] = @([colour writeDCMFile: nil] != nil);
#if !__has_feature(objc_arc)
    [colour release];
#endif
    NSArray *derived = [BrowserController addFiles: [NSArray arrayWithObjects: first, second, nil] toContext: context toDatabase: browser onlyDICOM: YES notifyAddedFiles: YES parseExistingObject: YES dbFolder: [browser documentsDirectory] generatedByOsiriX: YES];
    report[@"derivedImages"] = @([derived count]);
    report[@"derivedSameSeries"] = @([[derived valueForKeyPath: @"series.seriesDICOMUID"] count] == 2 && [[NSSet setWithArray: [derived valueForKeyPath: @"series.seriesDICOMUID"]] count] == 1);
    report[@"derivedSeriesName"] = [[derived lastObject] valueForKeyPath: @"series.name"];
    report[@"kitFilesLeft"] = @([[NSFileManager defaultManager] fileExistsAtPath: first]);

    NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey: @"ISIX_LEGACY_PROBE_OUTPUT"];
    if (path) [report writeToFile: [path stringByAppendingFormat: @"-database-%@.plist", report[@"arc"]] atomically: YES];
    return 0;
}

@end
