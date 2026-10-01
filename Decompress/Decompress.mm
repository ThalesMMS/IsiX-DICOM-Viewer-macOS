/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/

#import <Foundation/Foundation.h>
#import "DefaultsOsiriX.h"
#import "AppController.h"
//#import "QTKit/QTMovie.h"
#import "DCMPix.h"
#import <WebKit/WebKit.h>
#import "HorosHTMLPrint.h"
#import "N2Debug.h"
#import <Quartz/Quartz.h>

#undef verify
#include "HorosDCMTKCompatibility.h"
#include "HorosDICOMRepresentation.h"
#include "HorosDCMTKSeekableInput.h"
#include <dcmtk/config/osconfig.h> /* make sure OS specific configuration is included first */
#include <dcmtk/dcmjpeg/djdecode.h>  /* for dcmjpeg decoders */
#include <dcmtk/dcmjpeg/djencode.h>  /* for dcmjpeg encoders */
#include <dcmtk/dcmdata/dcrledrg.h>  /* for DcmRLEDecoderRegistration */
#include <dcmtk/dcmdata/dcrleerg.h>  /* for DcmRLEEncoderRegistration */
#include <dcmtk/dcmjpeg/djrploss.h>
#include <dcmtk/dcmjpeg/djrplol.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcrlerp.h>
#include <dcmtk/dcmdata/dcdicdir.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmjpls/djdecode.h> //JPEG-LS
#include <dcmtk/dcmjpls/djencode.h> //JPEG-LS
// Colour support for DicomImage, which the JPEG-LS encoder reads the pixels
// through (always for near-lossless, and for lossless as it prefers). Without
// it every RGB image failed "unsupported value for 'PhotometricInterpretation'"
// and stayed uncompressed; the application links it already (#1035).
#include <dcmtk/dcmimage/diregist.h>

#include "options.h"
#include "url.h"

extern "C"
{
    void exitOsiriX(void)
    {
        [NSException raise: @"JPEG error exception raised" format: @"JPEG error exception raised - See Console.app for error message"];
    }
}

enum DCM_CompressionQuality {DCMLosslessQuality = 0, DCMHighQuality, DCMMediumQuality, DCMLowQuality};

NSLock					*PapyrusLock = 0L;
NSThread				*mainThread = 0L;
BOOL					NEEDTOREBUILD = NO;
NSMutableDictionary		*DATABASECOLUMNS = 0L;
//short					Altivec = 0;



/*
void myunlink(const char * path) {
    NSLog(@"Unlinking %s", path);
    unlink(path);
    NSLog(@"... Unlinked %s", path);
}
*/
#define myunlink unlink

// WHY THIS EXTERNAL APPLICATION FOR COMPRESS OR DECOMPRESSION?

// Because if a file is corrupted, it will not crash the OsiriX application, but only this small task.

// Always modify this function in sync with compressionForModality in Decompress.mm / BrowserController.m
int compressionForModality( NSArray *array, NSArray *arrayLow, int limit, NSString* mod, int* quality, int resolution)
{
	NSArray *s;
	if( resolution < limit)
		s = arrayLow;
	else
		s = array;
	
	if( [mod isEqualToString: @"SR"]) // No compression for DICOM SR
		return compression_none;
	
	for( NSDictionary *dict in s)
	{
		if( [mod rangeOfString: [dict valueForKey: @"modality"]].location != NSNotFound)
		{
			int compression = compression_none;
			if( [[dict valueForKey: @"compression"] intValue] == compression_sameAsDefault)
				dict = [s objectAtIndex: 0];
			
			compression = [[dict valueForKey: @"compression"] intValue];
			
			if( quality)
			{
				if( compression == compression_JPEG2000 || compression == compression_JPEGLS)
					*quality = [[dict valueForKey: @"quality"] intValue];
				else
					*quality = 0;
			}
			
			return compression;
		}
	}
	
	if( [s count] == 0)
		return compression_none;
	
	if( quality)
		*quality = [[[s objectAtIndex: 0] valueForKey: @"quality"] intValue];
	
	return [[[s objectAtIndex: 0] valueForKey: @"compression"] intValue];
}

// What this helper hands back goes into a folder other things write to - the
// incoming folder above all, where the importer puts files of the same name
// from different folders and different scans. rename() replaces whatever is
// already at the destination, so the second 1.dcm converted into INCOMING took
// the place of the first one before it was indexed, and the first was gone
// without a word (#1024). Nothing handed back takes the place of something
// already there: it goes beside it under a name of its own, the way the
// importer names what it moves into the decompression folder (#1008).
static NSString *freeNameCandidate(NSString *destination, int attempt)
{
    if (attempt == 0) return destination;
    NSString *name = [destination lastPathComponent];
    NSString *stem = [name stringByDeletingPathExtension];
    NSString *extension = [name pathExtension];
    NSString *unique = [NSString stringWithFormat:@"%@-%d", stem, attempt];
    if (extension.length) unique = [unique stringByAppendingPathExtension:extension];
    return [[destination stringByDeletingLastPathComponent] stringByAppendingPathComponent:unique];
}

// Renames `from` (beside the destination, on its volume) to the destination or,
// when that is taken, to the first free name beside it; returns where it went,
// or nil with errno set. A file system without exclusive rename gets a check
// before the rename instead.
static NSString *renameWithoutReplacing(NSString *from, NSString *destination)
{
    for (int attempt = 0; attempt < 1000; attempt++)
    {
        NSString *candidate = freeNameCandidate(destination, attempt);
        if (renamex_np([from fileSystemRepresentation], [candidate fileSystemRepresentation], RENAME_EXCL) == 0)
            return candidate;
        if (errno == EEXIST) continue;
        if (errno != ENOTSUP && errno != EINVAL) return nil;
        struct stat existing;
        if (lstat([candidate fileSystemRepresentation], &existing) == 0) continue;
        if (rename([from fileSystemRepresentation], [candidate fileSystemRepresentation]) == 0)
            return candidate;
        return nil;
    }
    errno = EEXIST;
    return nil;
}

static void reportRenamedDestination(NSString *placed, NSString *destination)
{
    if (placed && ![placed isEqualToString:destination])
        NSLog(@"---- decompress: %@ was already in %@; this one is %@", [destination lastPathComponent],
              [[destination stringByDeletingLastPathComponent] lastPathComponent], [placed lastPathComponent]);
}

typedef NS_ENUM(NSInteger, HorosArchiveExtraction)
{
    HorosArchiveExtracted,           // the contents are in place and the archive is gone
    HorosArchiveNotExpanded,         // the archive itself is at fault; nothing came out of it
    HorosArchiveNotExpandedForNow,   // the destination is at fault - no room, no permission
    HorosArchiveExpandedNotCleared   // the contents are in place; the archive itself could not be removed
};

static HorosArchiveExtraction extractDICOMArchive(NSString *source, NSString *destination)
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *staging = [[destination stringByDeletingLastPathComponent] stringByAppendingPathComponent:[@".horos-extract-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
    if (![manager createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL])
    {
        // Nothing here says the archive is bad: the place it would go is.
        NSLog(@"---- decompress: %@ could not be expanded: no working directory beside %@", [source lastPathComponent], [destination stringByDeletingLastPathComponent]);
        return HorosArchiveNotExpandedForNow;
    }
    @try
    {
        NSString *output = [staging stringByAppendingPathComponent:@"contents"];
        NSTask *task = [[[NSTask alloc] init] autorelease];
        [task setLaunchPath:@"/usr/bin/unzip"];
        [task setArguments:@[@"-o", @"-d", output, source]];
        [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
        [task launch];
        while ([task isRunning]) [NSThread sleepForTimeInterval:0.1];
        int status = [task terminationStatus];
        // 1 means unzip finished and warned about something, so the contents are
        // there and throwing them away would be the loss this is meant to avoid.
        // 50 is "the disk is (or was) full": the archive is fine and the
        // destination is not, which is a different answer. Everything else means
        // the archive itself is at fault.
        if (status != 0 && status != 1)
        {
            NSLog(@"---- decompress: %@ could not be expanded: unzip exited with %d", [source lastPathComponent], status);
            return status == 50 ? HorosArchiveNotExpandedForNow : HorosArchiveNotExpanded;
        }
        // Never over an existing destination: swapping it into staging threw
        // away what an earlier archive of the same name had put there and
        // the importer had not yet taken (#1024). Only the archive itself,
        // expanded where it is, is replaced by its contents.
        BOOL inPlace = [[source stringByStandardizingPath] isEqualToString:[destination stringByStandardizingPath]];
        NSString *placed = nil;
        if (!inPlace)
            placed = renameWithoutReplacing(output, destination);
        else if (renamex_np([output fileSystemRepresentation], [destination fileSystemRepresentation], RENAME_SWAP) == 0)
            placed = destination;
        if (placed == nil)
        {
            NSLog(@"---- decompress: %@ was expanded but its contents could not be put in place: %s", [source lastPathComponent], strerror(errno));
            return HorosArchiveNotExpandedForNow;
        }
        reportRenamedDestination(placed, destination);
        if ([[source stringByStandardizingPath] isEqualToString:[destination stringByStandardizingPath]]) return HorosArchiveExtracted;
        if ([manager removeItemAtPath:source error:NULL]) return HorosArchiveExtracted;
        NSLog(@"---- decompress: %@ was expanded but the archive itself could not be removed", [source lastPathComponent]);
        return HorosArchiveExpandedNotCleared;
    }
    @catch (NSException *exception)
    {
        NSLog(@"Archive extraction failed: %@", exception);
        return HorosArchiveNotExpanded;
    }
    @finally
    {
        [manager removeItemAtPath:staging error:NULL];
    }
}

// Nothing ever rescans the decompression folder, so an archive left in it is
// neither imported nor mentioned again. Hand it back to the folder it came from
// under a name that no longer reads as an archive - kept as it is, it would be
// sent straight back here on the next scan - and let the importer report and
// dispose of it the way it does with any other file it cannot read, which is
// also what makes DELETEFILELISTENER apply to it.
static BOOL surrenderUnreadableArchive(NSString *source, NSString *destination)
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *handBack = [destination stringByAppendingPathExtension:@"horos-unexpanded"];
    for (int attempt = 1; [manager fileExistsAtPath:handBack] && attempt < 1000; attempt++)
        handBack = [[destination stringByAppendingFormat:@"-%d", attempt] stringByAppendingPathExtension:@"horos-unexpanded"];
    if (![manager moveItemAtPath:source toPath:handBack error:NULL])
    {
        NSLog(@"---- decompress: %@ could not be handed back for import; it stays in the decompression folder", [source lastPathComponent]);
        return NO;
    }
    NSLog(@"---- decompress: %@ handed back as %@ so the import folder can report it", [source lastPathComponent], [handBack lastPathComponent]);
    return YES;
}

// An archive that could not be expanded because of the destination - no room,
// no permission - is not a bad archive, and disposing of it the way an unreadable
// file is disposed of would destroy something the next attempt could read
// perfectly well. Put it back where it came from, under its own name, so the
// next scan tries again once the cause is gone.
static BOOL returnArchiveForRetry(NSString *source, NSString *destination)
{
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([[source stringByStandardizingPath] isEqualToString:[destination stringByStandardizingPath]])
        return YES;
    // Whatever is at the destination is not a partial of this archive - the
    // expansion is staged elsewhere - but something the importer has not taken
    // yet (#1024). The move may cross volumes, and never replaces.
    for (int attempt = 0; attempt < 1000; attempt++)
    {
        NSString *candidate = freeNameCandidate(destination, attempt);
        NSError *error = nil;
        if ([manager moveItemAtPath:source toPath:candidate error:&error])
        {
            NSLog(@"---- decompress: %@ put back as %@ for another attempt once there is room for it", [source lastPathComponent], [candidate lastPathComponent]);
            return YES;
        }
        if (!([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileWriteFileExistsError))
            break;
    }
    NSLog(@"---- decompress: %@ could not be put back for another attempt; it stays in the decompression folder", [source lastPathComponent]);
    return NO;
}

// Copy beside the destination before committing, including moves across volumes.
static BOOL relocateDICOMFile(NSString *source, NSString *destination)
{
    if ([[source stringByStandardizingPath] isEqualToString:[destination stringByStandardizingPath]])
        return [[NSFileManager defaultManager] fileExistsAtPath:source];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *staging = [[destination stringByDeletingLastPathComponent] stringByAppendingPathComponent:[@".horos-move-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
    if (![manager createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL])
        return NO;
    @try
    {
        NSString *temporary = [staging stringByAppendingPathComponent:@"file"];
        if (![manager copyItemAtPath:source toPath:temporary error:NULL]) return NO;
        NSString *placed = renameWithoutReplacing(temporary, destination); // #1024
        if (placed == nil) return NO;
        reportRenamedDestination(placed, destination);
        return [manager removeItemAtPath:source error:NULL];
    }
    @finally
    {
        [manager removeItemAtPath:staging error:NULL];
    }
}

// Save beside the final destination, then replace it without removing the source first.
static BOOL saveConvertedDICOM(DcmFileFormat& fileformat, E_TransferSyntax syntax,
                               NSString *source, NSString *destination)
{
    NSString *pattern = [[destination stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".horos-codec-XXXXXX"];
    char *temporary = strdup([pattern fileSystemRepresentation]);
    if (!temporary) return NO;
    int descriptor = mkstemp(temporary);
    if (descriptor < 0) { free(temporary); return NO; }
    close(descriptor);
    BOOL succeeded = NO;
    try
    {
        OFCondition condition = fileformat.saveFile(temporary, syntax);
        // In place, the converted file replaces its source; anywhere else it
        // never replaces what is already there (#1024).
        BOOL inPlace = [source isEqualToString:destination];
        NSString *placed = nil;
        if (condition.good() && inPlace && rename(temporary, [destination fileSystemRepresentation]) == 0)
            placed = destination;
        else if (condition.good() && !inPlace)
            placed = renameWithoutReplacing([[NSFileManager defaultManager] stringWithFileSystemRepresentation:temporary length:strlen(temporary)], destination);
        if (placed)
        {
            reportRenamedDestination(placed, destination);
            succeeded = YES;
            if (![source isEqualToString:destination] && unlink([source fileSystemRepresentation]) != 0)
                succeeded = NO;
        }
    }
    catch (...)
    {
        unlink(temporary);
        free(temporary);
        throw;
    }
    unlink(temporary);
    free(temporary);
    return succeeded;
}

// The preferences domain of the application this helper belongs to: the
// nearest .app above it (Horos.app/Contents/Resources/Decompress). A copy of
// the application under another identifier, such as the development bundle,
// then converts with its own CompressionSettings rather than those of the
// Horos installed on the computer (#1032). BUNDLE_IDENTIFIER, the domain the
// installed application uses, when the helper runs outside an application.
static NSString *HorosHostApplicationDefaultsDomain(void)
{
	NSString *folder = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
	for (; folder.length > 1; folder = [folder stringByDeletingLastPathComponent])
	{
		if ([folder.pathExtension caseInsensitiveCompare: @"app"] != NSOrderedSame)
			continue;
		NSString *identifier = [[NSBundle bundleWithPath: folder] bundleIdentifier];
		if (identifier.length)
			return identifier;
		break;
	}
	return @BUNDLE_IDENTIFIER;
}

int main(int argc, const char *argv[])
{
	[[NSAutoreleasePool alloc] init]; // yes, the Decompress tool will exit anyway
    
	// To avoid:
	// http://lists.apple.com/archives/quicktime-api/2007/Aug/msg00008.html
	// _NXCreateWindow: error setting window property (1002)
	// _NXTermWindow: error releasing window (1002)
	[NSApplication sharedApplication];
	

	//	argv[ 1] : in path
	//	argv[ 2] : what
	
	if( argv[ 1] && argv[ 2])
	{
		// register global JPEG decompression codecs
		// The DICOM Photometric Interpretation decides the colour model, as in the
		// application (+[AppController registerDCMTKCodecs]), so that what this
		// helper writes has the pixels the viewer shows for the original. The
		// IJG guess (EDC_guess, formerly chosen by UseJPEGColorSpace) reads three
		// components numbered 1, 2, 3 without a JFIF or Adobe marker as YCbCr,
		// and converted lossless RGB (.57, .70) as though it were; and it labels
		// every one-component stream MONOCHROME2, inverting MONOCHROME1 (#1028).
		// UseJPEGColorSpace now only lets a JFIF or Adobe marker of a lossy
		// three-component stream correct the interpretation, below (#1031).
		DJDecoderRegistration::registerCodecs(EDC_photometricInterpretation, EUC_never);
        DJLSDecoderRegistration::registerCodecs();
        
		// register global JPEG compression codecs
		DJEncoderRegistration::registerCodecs(
			ECC_lossyRGB,
			EUC_never,
			OFFalse,
			0,
			0,
			0,
			OFTrue,
			ESS_444,
			OFFalse,
			OFFalse,
			0,
			0,
			0.0,
			0.0,
			0,
			0,
			0,
			0,
			OFTrue,
			OFTrue,
			OFFalse,
			OFFalse,
			OFTrue);
        
        DJLSEncoderRegistration::registerCodecs();
        
		// register RLE compression codec
		DcmRLEEncoderRegistration::registerCodecs();

		// register RLE decompression codec
		DcmRLEDecoderRegistration::registerCodecs();

		// JPEG 2000, which upstream DCMTK does not provide
		HorosJPEG2000Registration::registerCodecs();
		
		NSString	*path = [NSString stringWithUTF8String:argv[1]];
		NSString	*what = [NSString stringWithUTF8String:argv[2]];
		NSInteger fileListFirstItemIndex = 3;
		
		NSMutableDictionary* dict = [DefaultsOsiriX getDefaults];
		[dict addEntriesFromDictionary: [[NSUserDefaults standardUserDefaults] persistentDomainForName: HorosHostApplicationDefaultsDomain()]];
		
		if ([what isEqualToString:@"SettingsPlist"])
		{
			@try
			{
				[dict addEntriesFromDictionary:[NSMutableDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:argv[fileListFirstItemIndex]]]];
				what = [NSString stringWithUTF8String:argv[4]];
				fileListFirstItemIndex += 2;
			}
			@catch (NSException* e)
			{ // ignore evtl failures
				NSLog(@"Decompress failed reading settings plist at %s: %@", argv[fileListFirstItemIndex], e);
			}
		}
		
		// The application's UseJPEGColorSpace, for the one colour policy the
		// viewer applies too (HorosJPEGColourModel.h, #1031).
		id useJPEGColorSpace = [dict objectForKey: @"UseJPEGColorSpace"];
		HorosJPEGMarkersDecideColour().store(useJPEGColorSpace == nil || [useJPEGColorSpace boolValue]);
		
#pragma mark compress
		if( [what isEqualToString:@"compress"])
		{
            BOOL conversionSucceeded = YES;
			
			NSArray *compressionSettings = [dict valueForKey: @"CompressionSettings"];
			NSArray *compressionSettingsLowRes = [dict valueForKey: @"CompressionSettingsLowRes"];
			
			int limit = [[dict objectForKey: @"CompressionResolutionLimit"] intValue];
			
			NSString *destDirec;
			if( [path isEqualToString: @"sameAsDestination"])
				destDirec = nil;
			else
				destDirec = path;
			
			for (int i = (int)fileListFirstItemIndex; i < argc; i++)
			{
				NSString *curFile = [NSString stringWithUTF8String:argv[ i]];
				OFBool status = YES;
				NSString *curFileDest;
				
				if( destDirec)
					curFileDest = [destDirec stringByAppendingPathComponent: [curFile lastPathComponent]];
				else
					curFileDest = [curFile stringByAppendingString: @" temp"];
				
				if( [[curFile pathExtension] isEqualToString: @"zip"] ||
                [[curFile pathExtension] isEqualToString: @"osirixzip"])
                {
                    HorosArchiveExtraction outcome = extractDICOMArchive(curFile, curFileDest);
                    if (outcome != HorosArchiveExtracted)
                    {
                        conversionSucceeded = NO;
                        if (outcome == HorosArchiveNotExpanded)
                            surrenderUnreadableArchive(curFile, curFileDest);
                        else if (outcome == HorosArchiveNotExpandedForNow)
                            returnArchiveForRetry(curFile, curFileDest);
                    }
				}
				else
				{
					HorosDCMTKSeekableInput input;
                    DcmFileFormat &fileformat = input.fileFormat();
					OFCondition cond = input.load([curFile fileSystemRepresentation], [NSTemporaryDirectory() fileSystemRepresentation]);
                    if (!cond.good())
                        conversionSucceeded = NO;
					// if we can't read it stop
					if( cond.good())
					{
						DcmDataset *dataset = fileformat.getDataset();
//						DcmItem *metaInfo = fileformat.getMetaInfo();
						DcmXfer original_xfer(dataset->getOriginalXfer());
						
						const char *string = NULL;
						
//						NSString *sopClassUID = nil;
//						if (dataset->findAndGetString(DCM_SOPClassUID, string, OFFalse).good() && string != NULL)
//							sopClassUID = [NSString stringWithCString:string encoding: NSASCIIStringEncoding];
						
                        
						{
                            delete dataset->remove( DcmTagKey( 0x0009, 0x1110)); // "GEIIS" The problematic private group, containing a *always* JPEG compressed PixelData
                            
							NSString *modality;
							if (dataset->findAndGetString(DCM_Modality, string, OFFalse).good() && string != NULL)
								modality = [NSString stringWithCString:string encoding: NSASCIIStringEncoding];
							else
								modality = @"OT";
							
							int resolution = 0;
							unsigned short rows = 0;
							if (dataset->findAndGetUint16( DCM_Rows, rows, OFFalse).good())
							{
								if( resolution == 0 || resolution > rows)
									resolution = rows;
							}
							unsigned short columns = 0;
							if (dataset->findAndGetUint16( DCM_Columns, columns, OFFalse).good())
							{
								if( resolution == 0 || resolution > columns)
									resolution = columns;
							}
							
							int quality, compression = compressionForModality( compressionSettings, compressionSettingsLowRes, limit, modality, &quality, resolution);
							
                            BOOL alreadyCompressed = NO;
                            
                            if (original_xfer.usesEncapsulatedFormat() && original_xfer.isPixelDataCompressed())
                            {
                                switch( compression)
                                {
                                    case compression_JPEGLS:
                                        if( original_xfer.getXfer() == EXS_JPEGLSLossless ||
                                           original_xfer.getXfer() == EXS_JPEGLSLossy)
                                            alreadyCompressed = YES;
                                    break;
                                    
                                    case compression_JPEG2000:
                                        if( original_xfer.getXfer() == EXS_JPEG2000 ||
                                           original_xfer.getXfer() == EXS_JPEG2000LosslessOnly)
                                            alreadyCompressed = YES;
                                    break;
                                    
                                    case compression_JPEG:
                                        if( original_xfer.getXfer() == EXS_JPEGProcess14SV1TransferSyntax)
                                            alreadyCompressed = YES;
                                    break;
                                }
                            }
                            
                            if( alreadyCompressed == NO)
                            {
                                    if( compression == compression_JPEG ||
                                       compression == compression_JPEG2000 ||
                                       compression == compression_JPEGLS)
                                {
                                    DcmRepresentationParameter *params = nil;
                                    E_TransferSyntax tSyntax;
                                    DJ_RPLossless losslessParams(6,0);
                                    DJ_RPLossy JP2KParams( quality);
                                    DJ_RPLossy JP2KParamsLossLess( DCMLosslessQuality);
                                    
                                    if( compression == compression_JPEG)
                                    {
                                        params = &losslessParams;
                                        tSyntax = EXS_JPEGProcess14SV1TransferSyntax;
                                    }
                                    else if( compression == compression_JPEGLS)
                                    {
                                        if( quality == DCMLosslessQuality)
                                        {
                                            params = &JP2KParamsLossLess;
                                            tSyntax = EXS_JPEGLSLossless;
                                        }
                                        else
                                        {
                                            params = &JP2KParams;
                                            tSyntax = EXS_JPEGLSLossy;
                                        }
                                    }
                                    else if( compression == compression_JPEG2000)
                                    {
                                        if( quality == DCMLosslessQuality)
                                        {
                                            params = &JP2KParamsLossLess;
                                            tSyntax = EXS_JPEG2000LosslessOnly;
                                        }
                                        else
                                        {
                                            params = &JP2KParams;
                                            tSyntax = EXS_JPEG2000;
                                        }
                                    }
                                    else
                                    {
                                        params = &JP2KParamsLossLess;
                                        tSyntax = EXS_JPEG2000LosslessOnly;
                                        
                                        NSLog( @" ****** UNKNOW compression Decompress.mm");
                                    }
                                    
                                    // this causes the lossless JPEG version of the dataset to be created
                                    DcmXfer oxferSyn( tSyntax);
                                    HorosChooseDICOMRepresentation(fileformat, tSyntax, params, quality);
                                    
                                    // check if everything went well
                                    if (dataset->canWriteXfer(tSyntax))
                                    {
                                        // force the meta-header UIDs to be re-generated when storing the file 
                                        // since the UIDs in the data set may have changed 
                                        
                                        //only need to do this for lossy
                                        //delete metaInfo->remove(DCM_MediaStorageSOPClassUID);
                                        //delete metaInfo->remove(DCM_MediaStorageSOPInstanceUID);
                                        
                                        // store in lossless JPEG format
                                        // Source/backing remains alive through the staged save.
                                        
                                        status = saveConvertedDICOM(fileformat, tSyntax, curFile, destDirec ? curFileDest : curFile);
                                        if (!status) conversionSucceeded = NO;
                                    }
                                    else conversionSucceeded = NO;
                                }
                                else
                                {
                                    if( destDirec)
                                    {
                                        if (!relocateDICOMFile(curFile, curFileDest))
                                            conversionSucceeded = NO;
                                    }
                                }
                            }
                            else
                            {
                                if( destDirec)
                                {
                                    if (!relocateDICOMFile(curFile, curFileDest))
                                        conversionSucceeded = NO;
                                }
                            }
						}
					}
					else if ([[dict objectForKey: @"DecompressMoveIfFail"] boolValue])
                    {
                        if (!relocateDICOMFile(curFile, curFileDest))
                            conversionSucceeded = NO;
                    }
                    else NSLog( @"compress : cannot read file: %@", curFile);
				}
			}
            return conversionSucceeded ? EXIT_SUCCESS : EXIT_FAILURE;
		}
		
        if( [what isEqualToString: @"testDICOMDIR"])
        {
            NSLog( @"-- Testing DICOMDIR: %@", [NSString stringWithUTF8String: argv[ 1]]);
            
            DcmDicomDir dcmdir( [[NSString stringWithUTF8String: argv[ 1]] fileSystemRepresentation]);
            DcmDirectoryRecord& record = dcmdir.getRootRecord();
            
            for (unsigned int i = 0; i < record.card();)
            {
                DcmElement* element = record.getElement(i);
                OFString ofstr;
                element->getOFStringArray(ofstr).good();
                
                i += 10;
            }
            
            NSLog( @"-- Testing DICOMDIR done");
                  
//            *(long*) 0x00 = 0xDEADBEEF;
        }
        
# pragma mark testFiles
		if( [what isEqualToString: @"testFiles"])
		{			
			
			
			for(int i = (int)fileListFirstItemIndex; i < argc ; i++)
			{
				NSString *curFile = [NSString stringWithUTF8String: argv[ i]];
				
				// Simply try to load and generate the image... will it crash?
				
				DCMPix *dcmPix = [[DCMPix alloc] initWithPath: curFile :0 :1 :nil :0 :0 isBonjour: NO imageObj: nil];
				
				if( dcmPix)
				{
					[dcmPix CheckLoad];
					
					//*(long*)0 = 0xDEADBEEF; // Dead Beef ? WTF ??? Will it unlock the matrix....
					
					[dcmPix release];
				}
				else NSLog( @"dcmPix == nil");
			}
		}
		
# pragma mark decompressList
		if( [what isEqualToString:@"decompressList"])
		{
            BOOL conversionSucceeded = YES;
			NSString *destDirec;
			if( [path isEqualToString: @"sameAsDestination"])
				destDirec = nil;
			else
				destDirec = path;
			
			
			for(int i = (int)fileListFirstItemIndex; i < argc ; i++)
			{
				NSString *curFile = [NSString stringWithUTF8String:argv[ i]];
				NSString *curFileDest;
				
				if( destDirec)
					curFileDest = [destDirec stringByAppendingPathComponent: [curFile lastPathComponent]];
				else
					curFileDest = [curFile stringByAppendingString: @" temp"];
				
				OFBool status = NO;
				
				if( [[curFile pathExtension] isEqualToString: @"zip"] || [[curFile pathExtension] isEqualToString: @"osirixzip"])
				{
                    HorosArchiveExtraction outcome = extractDICOMArchive(curFile, curFileDest);
                    if (outcome != HorosArchiveExtracted)
                    {
                        conversionSucceeded = NO;
                        if (outcome == HorosArchiveNotExpanded)
                            surrenderUnreadableArchive(curFile, curFileDest);
                        else if (outcome == HorosArchiveNotExpandedForNow)
                            returnArchiveForRetry(curFile, curFileDest);
                    }
				}
                else
                {
                    HorosDCMTKSeekableInput input;
                    DcmFileFormat &fileformat = input.fileFormat();
                    OFCondition condition = input.load([curFile fileSystemRepresentation], [NSTemporaryDirectory() fileSystemRepresentation]);
                    if (condition.good())
                    {
                        DcmDataset *dataset = fileformat.getDataset();
                        // GEIIS may contain JPEG PixelData in this private group.
                        delete dataset->remove(DcmTagKey(0x0009, 0x1110));
                        HorosChooseDICOMRepresentation(fileformat, EXS_LittleEndianExplicit);
                        if (dataset->canWriteXfer(EXS_LittleEndianExplicit))
                        {
                            // Source/backing remains alive through the staged save.
                            status = saveConvertedDICOM(fileformat, EXS_LittleEndianExplicit, curFile, destDirec ? curFileDest : curFile);
                        }
                    }
                    if (!status) conversionSucceeded = NO;
                }
            }
            return conversionSucceeded ? EXIT_SUCCESS : EXIT_FAILURE;
		}
		
# pragma mark pdfFromURL
        if ([what isEqualToString:@"pdfFromURL"])
        {
            @try
            {
                return HorosUpdateHTMLReportPDF(path, 25) ? 0 : 1;
            }
            @catch (NSException *exception)
            {
                N2LogExceptionWithStackTrace(exception);
                return 1;
            }
        }

	    // deregister JPEG codecs
		//DJDecoderRegistration::cleanup();	We dont care: we are just a small app : our memory will be killed by the system. Dont loose time here !
		//DJEncoderRegistration::cleanup();	We dont care: we are just a small app : our memory will be killed by the system. Dont loose time here !

		// deregister RLE codecs
		//DcmRLEDecoderRegistration::cleanup();	We dont care: we are just a small app : our memory will be killed by the system. Dont loose time here !
		//DcmRLEEncoderRegistration::cleanup();	We dont care: we are just a small app : our memory will be killed by the system. Dont loose time here !
	}
	
//	[pool release]; We dont care: we are just a small app : our memory will be killed by the system. Dont loose time here !
	
	return 0;
}
