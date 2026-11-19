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

enum
{
	CMOVERetrieveMode = 0,
	CGETRetrieveMode = 1,
	WADORetrieveMode = 2
};

#import <Cocoa/Cocoa.h>

/** \brief The DICOM node list and DICOM Bonjour

The class of the DCM framework of the Horos and OsiriX plugin SDK that lists
the DICOM nodes: a plugin built for either looks it up by name. The lists and
the Bonjour search are the application's own (the node service); this class
answers with them, each node a dictionary with the keys the SDK gave it
(Address, AETitle, Port, Description, TransferSyntax, QR, Send, retrieveMode,
Activated, and what else the node was saved with). Only DIMSE nodes are
listed: the DICOMweb nodes have a list of their own.

The shared delegate no longer browses by itself: it adopts the two delegate
protocols as it did, and the services it answers are those the application's
search found.

DCMNetServiceDelegate.swift implements the class (@objc @implementation), with
the instance variables the SDK declared: publisher is what -setPublisher: was
given, and the browser and the list of services it found stay nil.
*/
NS_SWIFT_SENDABLE
@interface DCMNetServiceDelegate : NSObject <NSNetServiceDelegate, NSNetServiceBrowserDelegate>

/// The numeric address a resolved service answers at, IPv4 first, and its
/// port in *port (0 when none); port may be NULL.
+ (NSString*) gethostnameAndPort: (int*) port forService:(NSNetService*) sender;
+ (NSArray *) DICOMServersList;
+(NSMutableDictionary*)DICOMNodeInfoFromTXTRecordData:(NSData*)data;
/// The nodes that are activated; only those that can be sent to, or queried,
/// when asked.
+ (NSArray *) DICOMServersListSendOnly: (BOOL) send QROnly:(BOOL) QR;
/// The SDK of OsiriX has this message and that of Horos has not; a plugin
/// written for both sends it. The list is read each time: cached is ignored.
+ (NSArray *) DICOMServersListSendOnly: (BOOL) send QROnly:(BOOL) QR cached:(BOOL) cached;
/// The IPv4 address of a host name or of a dotted address; nil for what is
/// not a string, as the SDK answered (it declared the argument NSString *).
+ (NSString*) getIPAddress: (id) address;
+ (id)sharedNetServiceDelegate;
/// Keeps p, without retaining it and without publishing anything: the
/// application advertises its own listener.
- (void) setPublisher: (NSNetService*) p;
/// Searches again when the DICOM Bonjour search is on.
- (void)update;
- (NSArray *)dicomServices;
- (int)portForNetService:(NSNetService *)netService;

@end
