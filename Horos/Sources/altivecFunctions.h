/*=========================================================================
  Program:   OsiriX

  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.

     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ---------------------------------------------------------------------------
 
 This file is part of the Horos Project.
 
 Current contributors to the project include Alex Bettarini and Danny Weissman.
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 Horos is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with Horos.  If not, see <http://www.gnu.org/licenses/>.

 

 
 ---------------------------------------------------------------------------
 
 This file is part of the Horos Project.
 
 Current contributors to the project include Alex Bettarini and Danny Weissman.
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 Horos is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with Horos.  If not, see <http://www.gnu.org/licenses/>.

=========================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// The element-wise vector functions of the Horos and OsiriX plugin SDK. The
// application no longer calls them; plugins built for that SDK do, by name,
// without being rebuilt. The ones named for a processor exist on every
// architecture the application is built for, with the same arithmetic.

#import <Accelerate/Accelerate.h>

#ifdef __cplusplus
extern "C"
{
#endif /*cplusplus*/
	// `size` counts the elements of the four vectors of 16 bytes handled at a
	// time: size/4 vectors are read from a and b and written to r.
	extern void vmaxIntel( vFloat *a, vFloat *b, vFloat *r, long size);
	extern void vminIntel( vFloat *a, vFloat *b, vFloat *r, long size);
	extern void vmax8Intel( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size);
	extern void vmin8Intel( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size);
	extern void vmax8ARM( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size);
	extern void vmin8ARM( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size);

	// One float at a time: `size` floats.
	extern void vmultiplyNoAltivec( float *a,  float *b,  float *r, long size);
	extern void vminNoAltivec( float *a,  float *b,  float *r, long size);
	extern void vmaxNoAltivec(float *a, float *b, float *r, long size);
	extern void vsubtractNoAltivec( float *a,  float *b,  float *r, long size);
	extern void vsubtractNoAltivecAbs( float *a,  float *b,  float *r, long size);

	// Whether the AltiVec functions were to be used: always 0.
	extern short Altivec;

#ifdef __cplusplus
}
#endif /*cplusplus*/
