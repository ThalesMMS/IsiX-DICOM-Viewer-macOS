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

// What EndoscopyVRController.swift cannot do itself: its initializer. It writes
// VRController's instance variables before [super init], receives the volume as
// the NSData the viewer holds (Swift would see a Data, another object), and the
// endoscopy viewer sends it again to the controller its nib made. It is this
// category's method, which takes the place of the initializer Swift inherits
// from VRController, as the former class's did.
//
// The receiver is always the controller of Endoscopy.xib, which the nib and the
// viewer keep. When the initializer fails, it does not release it: it returns
// nil with the controller back to the state it had before, and the viewer does
// not open.

#import "HorosAlertPanel.h"
#import "EndoscopyVRController.h"
#import "Horos-Swift.h"
//#import "EndoscopyFlyThruController.h"
#import "DCMView.h"
#import "ROI.h"
#import "VRView.h"
#import "BrowserController.h"
#import "DicomDatabase.h"
#import "Notifications.h"

@interface EndoscopyVRController (Dummy)

- (void)add3DPoint:(id)dummy;
- (void)UpdateWLWWMenu:(id)dummy;
- (void)updateVolumeData:(id)dummy;
- (void)UpdateOpacityMenu:(id)dummy;

@end

@interface VRController (HorosShadingSelection)
// Implemented in VRController.mm.
- (void) horosObserveShadingSelection;
@end

@interface EndoscopyVRController (InitCAPI)
@end

@implementation EndoscopyVRController (InitCAPI)

// What -initWithPix::::: took before it failed, given back: the file list it
// retained, and the pixel list and volume, retained only once the checks passed.
// -[VRController dealloc] then releases nothing it does not hold, and
// -save3DState, without a file list, writes no state.
- (void) horosAbandonInitWithPix: (BOOL) volumeRetained
{
    if( volumeRetained)
    {
        [pixList[0] release];
        [volumeData[0] release];
    }
    pixList[0] = nil;
    volumeData[0] = nil;
    
    [fileList release];
    fileList = nil;
}

-(id) initWithPix:(NSMutableArray*) pix :(NSArray*) f :(NSData*) vData :(ViewerController*) bC :(ViewerController*) vC
{
    unsigned long   i;
    short           err = 0;
	BOOL			testInterval = YES;
	
	for( i = 0; i < 100; i++) undodata[ i] = nil;
	
//	[[NSUserDefaults standardUserDefaults] setInteger: 1 forKey: @"MAPPERMODEVR"];	// texture mapping
	
	curMovieIndex = 0;
	maxMovieIndex = 1;
	
	fileList = f;
	[fileList retain];
	
	pixList[0] = pix;
	volumeData[0] = vData;
	
    DCMPix  *firstObject = [pixList[0] objectAtIndex:0];
    float sliceThickness = fabs( [firstObject sliceInterval]);
	
	// Find Minimum Value
	if( [firstObject isRGB] == NO) [self computeMinMax];
	else minimumValue = 0;
    
    if( sliceThickness == 0)
    {
		sliceThickness = [firstObject sliceThickness];
		
		testInterval = NO;
		
		if( sliceThickness > 0) HorosRunCriticalAlertPanel( NSLocalizedString(@"Slice interval",nil), NSLocalizedString( @"I'm not able to find the slice interval. Slice interval will be equal to slice thickness.",nil), NSLocalizedString(@"OK",nil), nil, nil);
		else
		{
			HorosRunCriticalAlertPanel(NSLocalizedString( @"Slice interval/thickness",nil), NSLocalizedString( @"Problems with slice thickness/interval to do a 3D reconstruction.",nil),NSLocalizedString( @"OK",nil), nil, nil);
            [self horosAbandonInitWithPix: NO];
			return nil;
		}
    }
    
	err = 0;
    // CHECK IMAGE SIZE
    for( i =0 ; i < [pixList[0] count]; i++)
    {
        if( [firstObject pwidth] != [[pixList[0] objectAtIndex:i] pwidth]) err = -1;
        if( [firstObject pheight] != [[pixList[0] objectAtIndex:i] pheight]) err = -1;
    }
    if( err)
    {
        HorosRunCriticalAlertPanel(NSLocalizedString( @"Images size",nil),  NSLocalizedString(@"These images don't have the same height and width to allow a 3D reconstruction...",nil),NSLocalizedString( @"OK",nil), nil, nil);
        [self horosAbandonInitWithPix: NO];
        return nil;
    }

	[pixList[0] retain];
	[volumeData[0] retain];


    self = [super init];
    
    //[[self window] setDelegate:self];
    
	[view setViewportResizable: NO];
	
    err = [view setPixSource:pixList[0] :(float*) [volumeData[0] bytes]];
    if( err != 0)
    {
        [self horosAbandonInitWithPix: YES];
        return nil;
    }
	
	blendingController = bC;
//	if( blendingController) // Blending! Activate image fusion
//	{
//		[view setBlendingPixSource: blendingController];
//		
//		[blendingSlider setEnabled:YES];
//		[blendingPercentage setStringValue:[NSString stringWithFormat:@"%0.0f%%", (float) ([blendingSlider floatValue] + 256.) / 5.12]];
//		
//		//[self updateBlendingImage];
//	}
	
	curWLWWMenu = [NSLocalizedString(@"Other", nil) retain];
	
	roi2DPointsArray = [[NSMutableArray alloc] initWithCapacity:0];
	sliceNumber2DPointsArray = [[NSMutableArray alloc] initWithCapacity:0];
	x2DPointsArray = [[NSMutableArray alloc] initWithCapacity:0];
	y2DPointsArray = [[NSMutableArray alloc] initWithCapacity:0];
	z2DPointsArray = [[NSMutableArray alloc] initWithCapacity:0];

	viewer2D = [vC retain];
	if (viewer2D)
	{		
		long i;
		float x, y, z;
		NSMutableArray	*curRoiList;
		ROI	*curROI;
		
		for(i=0; i<[[[viewer2D imageView] dcmPixList] count]; i++)
		{
			curRoiList = [[viewer2D roiList] objectAtIndex: i];
			for(curROI in curRoiList)
			{
				if ([curROI type] == t2DPoint)
				{
					float location[ 3 ];
					
					[[[viewer2D pixList] objectAtIndex: i] convertPixX: [[[curROI points] objectAtIndex:0] x] pixY: [[[curROI points] objectAtIndex:0] y] toDICOMCoords: location pixelCenter: YES];
					
					x = location[ 0 ];
					y = location[ 1 ];
					z = location[ 2 ];

					// add the 3D Point to the SR view
					[[self view] add3DPoint:  x : y : z];
					// add the 2D Point to our list
					[roi2DPointsArray addObject:curROI];
					[sliceNumber2DPointsArray addObject:[NSNumber numberWithLong:i]];
					[x2DPointsArray addObject:[NSNumber numberWithFloat:x]];
					[y2DPointsArray addObject:[NSNumber numberWithFloat:y]];
					[z2DPointsArray addObject:[NSNumber numberWithFloat:z]];
				}
			}
		}
	}

	NSNotificationCenter *nc;
	nc = [NSNotificationCenter defaultCenter];
	
	[nc addObserver: self
		selector: @selector(remove3DPoint:)
		name: OsirixRemoveROINotification
		object: nil];
	[nc addObserver: self
		selector: @selector(add3DPoint:)
		//name: OsirixROIChangeNotification
		name: OsirixROISelectedNotification
		object: nil];

    [nc addObserver: self
           selector: @selector(UpdateWLWWMenu:)
               name: OsirixUpdateWLWWMenuNotification
             object: nil];
	
	[nc addObserver: self
           selector: @selector(updateVolumeData:)
               name: OsirixUpdateVolumeDataNotification
             object: nil];
	
	[[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateWLWWMenuNotification object: curWLWWMenu userInfo: nil];
	
	curCLUTMenu = [NSLocalizedString(@"No CLUT", nil) retain];
	
    [nc addObserver: self
           selector: @selector(UpdateCLUTMenu:)
               name: OsirixUpdateCLUTMenuNotification
             object: nil];
	
	[[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateCLUTMenuNotification object: curCLUTMenu userInfo: nil];
	
	curOpacityMenu = [NSLocalizedString(@"Linear Table", nil) retain];
	
    [nc addObserver: self
           selector: @selector(UpdateOpacityMenu:)
               name: OsirixUpdateOpacityMenuNotification
             object: nil];
	
	[[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateOpacityMenuNotification object: curOpacityMenu userInfo: nil];
	
	[nc addObserver: self
           selector: @selector(CLUTChanged:)
               name: OsirixCLUTChangedNotification
             object: nil];
	
	[[self window] performZoom:self];

	[movieRateSlider setEnabled: NO];
	[moviePosSlider setEnabled: NO];
	[moviePlayStop setEnabled: NO];
	
//    [shadingsPresetsController setWindowController: self];
    // The superclass's initializer, which observes the shading presets'
    // selection, is not the one this controller runs: its shading panel's
    // popup applies the chosen preset only through that observer.
    [self horosObserveShadingSelection];
    
    return self;
}

@end
