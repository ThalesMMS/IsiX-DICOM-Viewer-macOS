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


#import <Cocoa/Cocoa.h>

/** \brief One C-STORE association of a send, as an operation of a queue

The operation the Send window of Horos and OsiriX put in its queue for each
part of the files it sent: -main opens one association with the node and
stores the files through DCMTKStoreSCU. The class was private to SendController.m; a plugin built for either
finds it by name.

server is the node as the DICOM locations describe it: AETitle, Address and
Port are read from it, and the whole dictionary is given to the send for its
TLS settings. The calling AE title and the transfer syntax are those of the
preferences. -main sets thread to the thread it runs on and progress to zero
on it; a cancelled operation starts nothing, and one cancelled while it sends
stops between two files. A send that fails is told to the user by
-showErrorMessage:, on the main thread, with an exception that has the name
and the reason -[DCMTKStoreSCU run:] raises for it.

The application's own sends do not go through this class: they are parts of
the send queue, which stores each through DCMTKStoreSCU as this does.

DCMTKStoreSCUOperation.swift implements the class (@objc @implementation).
*/
@interface DCMTKStoreSCUOperation : NSOperation

@property (retain) NSArray *files;
@property (retain) NSDictionary *server;
@property (retain) NSThread *thread;

- (id)initWithFiles:(NSArray *)a server:(NSDictionary *)s;

// Shows the alert of a send that failed. Sent on the main thread.
- (void)showErrorMessage:(NSException *)ne;

@end
