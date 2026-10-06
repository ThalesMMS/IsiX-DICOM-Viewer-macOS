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

// The C part of SplashScreen, which is implemented in Swift
// (SplashScreen.swift): exported functions do not migrate. vramSize() and
// useQuartz() remain exported; no header declares them, as before.

#include "options.h"
#import "SplashScreen.h"
#import "DefaultsOsiriX.h"

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/host_info.h>
#include <mach/machine.h>
#include <sys/sysctl.h>

//BOOL IsPPC()
//
//{
//   host_basic_info_data_t hostInfo;
//   mach_msg_type_number_t infoCount;
//
//   infoCount = HOST_BASIC_INFO_COUNT;
//   host_info(mach_host_self(), HOST_BASIC_INFO, 
//(host_info_t)&hostInfo, &infoCount);
//
//	return (hostInfo.cpu_type == CPU_TYPE_POWERPC);
//} 

//int GetAltiVecTypeAvailable( void )
//{
//
//int sels[2] = { CTL_HW, HW_VECTORUNIT };
//int vType = 0; //0 == scalar only
//size_t length = sizeof(vType);
//int error = sysctl(sels, 2, &vType, &length, NULL, 0);
//if( 0 == error ) return vType;
//
//return 0;
//
//}

__attribute__((used)) long vramSize(void)
{
	// Preserve the exported byte-valued compatibility entry point. Apple Silicon
	// uses unified memory; share the current Metal budget query with app defaults.
	return [DefaultsOsiriX vramSize];
}


__attribute__((used)) BOOL useQuartz(void) {
	return NO;				// Disable quartz about screen:  DDP (060224)
	
	/*
	if (vramSize() >= 32)
		return YES;
	else 
		return NO;
		
	if (!IsPPC())
		return YES;
		
	return GetAltiVecTypeAvailable();
     */
}
