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

#import <Cocoa/Cocoa.h>

/** \brief  Finds the appropriate study/series/image for Q/R
*
* Finds the appropriate study/series/image for Q/R
* Interface between server and database 
*
* The class of the Horos and OsiriX plugin SDK through which the DICOM
* listener read the database: a plugin built for either looks it up by name.
* The listener's rules are the application's own now, behind the DCMTK
* adapter, and no handler of this class takes part in a request: it keeps its
* calling AE title, answers the bounds of a day as it did, and finds and moves
* nothing.
*
* The SDK declared eight more messages with DCMTK's C++ types, which this
* header leaves out so that it carries no C++:
* -predicateForDataset:compressedSOPInstancePredicate:seriesLevelPredicate:,
* -studyDatasetForFetchedObject:dataset:, -seriesDatasetForFetchedObject:dataset:,
* -imageDatasetForFetchedObject:dataset:, -prepareFindForDataSet:,
* -prepareMoveForDataSet:, -nextFindObject:isComplete: and -nextMoveObject:.
* A plugin built with DCMTK's headers still sends them; the class answers
* each in the DCMTK adapter with the same calling convention, reads no
* dataset of the plugin's DCMTK, and finds nothing.
*
* OsiriXSCPDataHandler.swift implements the class (@objc @implementation),
* with the instance variables the SDK declared: callingAET is the title the
* handler keeps, and those of the find and of the move stay nil and zero.
*/

@interface OsiriXSCPDataHandler : NSObject

@property (retain) NSString *callingAET;

/// A new handler, owned by the caller, who releases it.
+ (id)allocRequestDataHandler NS_RETURNS_RETAINED;

// The SDK declared the day of these two as an NSCalendarDate *, which Swift
// cannot name: the same object is taken as id. The day is the one the date
// falls on in its own time zone; its bounds are midnight and 24 hours later
// in the default time zone, as seconds since the reference date.
-(NSTimeInterval)endOfDay:(id)day;
-(NSTimeInterval)startOfDay:(id)day;

/// NO: no find is prepared through this class.
- (BOOL)findMatchFound;
/// 0: no move is prepared through this class.
- (int)moveMatchFound;
/// Does nothing: there is no move to cancel.
- (void)cancelMove;
@end
