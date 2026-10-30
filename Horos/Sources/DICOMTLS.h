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

// The constants of secure DICOM connections. The class DICOMTLS is Swift
// (DICOMTLS.swift): Objective-C reaches it through Horos-Swift.h, which the
// path macros below need where they are used.

#import <Foundation/Foundation.h>

typedef enum
{
	RequirePeerCertificate = 0,
	VerifyPeerCertificate,
	IgnorePeerCertificate
} TLSCertificateVerificationType;

// In the user's own temporary folder (+[DICOMTLS temporaryFolder]). They were in
// /tmp under fixed names, where another user could put a trusted certificate or
// a link in place first.
#define TLS_SEED_FILE [[DICOMTLS temporaryFolder] stringByAppendingPathComponent: @"OsiriXTLSSeed"]
#define TLS_PRIVATE_KEY_FILE [[DICOMTLS temporaryFolder] stringByAppendingPathComponent: @"TLSKey"]
#define TLS_CERTIFICATE_FILE [[DICOMTLS temporaryFolder] stringByAppendingPathComponent: @"TLSCert"]
#define TLS_TRUSTED_CERTIFICATES_DIR [[DICOMTLS temporaryFolder] stringByAppendingPathComponent: @"TLSTrustedCert"]
#define TLS_KEYCHAIN_IDENTITY_NAME_CLIENT @"com.osirixviewer.dicomtlsclient"
#define TLS_KEYCHAIN_IDENTITY_NAME_SERVER @"com.osirixviewer.dicomtlsserver"
