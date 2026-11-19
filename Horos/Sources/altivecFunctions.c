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

#include "altivecFunctions.h"
#include <math.h>
#include <string.h>
#include <simd/simd.h>

#define FORMER_SDK __attribute__((used))

FORMER_SDK short Altivec = 0;

// Vectors of 16 bytes, read and written without assuming their alignment.
static void floats4(const vFloat *a, const vFloat *b, vFloat *r, long size, int maximum)
{
	long i = size/4;

	while(i-- > 0)
	{
		simd_float4 x, y, z;
		memcpy(&x, a++, sizeof x);
		memcpy(&y, b++, sizeof y);
		z = maximum ? simd_max(x, y) : simd_min(x, y);
		memcpy(r++, &z, sizeof z);
	}
}

static void bytes16(const vUInt8 *a, const vUInt8 *b, vUInt8 *r, long size, int maximum)
{
	long i = size/4;

	while(i-- > 0)
	{
		simd_uchar16 x, y, z;
		memcpy(&x, a++, sizeof x);
		memcpy(&y, b++, sizeof y);
		z = maximum ? simd_max(x, y) : simd_min(x, y);
		memcpy(r++, &z, sizeof z);
	}

	// The size counts pixels of four bytes and a vector holds four of them:
	// the one to three pixels the vectors do not cover are reduced byte by
	// byte, so that a result buffer of exactly that size is written whole.
	const unsigned char *x = (const unsigned char *) a, *y = (const unsigned char *) b;
	unsigned char *z = (unsigned char *) r;
	for (long rest = (size > 0 ? size % 4 : 0) * 4; rest-- > 0; x++, y++)
		*z++ = maximum ? (*x > *y ? *x : *y) : (*x < *y ? *x : *y);
}

FORMER_SDK void vmaxIntel( vFloat *a, vFloat *b, vFloat *r, long size) { floats4(a, b, r, size, 1); }
FORMER_SDK void vminIntel( vFloat *a, vFloat *b, vFloat *r, long size) { floats4(a, b, r, size, 0); }
FORMER_SDK void vmax8Intel( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size) { bytes16(a, b, r, size, 1); }
FORMER_SDK void vmin8Intel( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size) { bytes16(a, b, r, size, 0); }
FORMER_SDK void vmax8ARM( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size) { bytes16(a, b, r, size, 1); }
FORMER_SDK void vmin8ARM( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size) { bytes16(a, b, r, size, 0); }

FORMER_SDK void vmultiplyNoAltivec( float *a,  float *b,  float *r, long size)
{
	long i = size;

	while(i-- > 0)
	{
		*r++ = *a++ * *b++;
	}
}

FORMER_SDK void vsubtractNoAltivec( float *a,  float *b,  float *r, long size)
{
	long i = size;

	while(i-- > 0)
	{
		*r++ = *a++ - *b++;
	}
}

FORMER_SDK void vsubtractNoAltivecAbs( float *a,  float *b,  float *r, long size)
{
	long i = size;

	while(i-- > 0)
	{
		*r++ = fabsf(*a++ - *b++);
	}
}

FORMER_SDK void vmaxNoAltivec(float *a, float *b, float *r, long size)
{
	long i = size;

	while(i-- > 0)
	{
		if( *a > *b) { *r++ = *a++; b++; }
		else { *r++ = *b++; a++; }
	}
}

FORMER_SDK void vminNoAltivec( float *a,  float *b,  float *r, long size)
{
	long i = size;

	while(i-- > 0)
	{
		if( *a < *b) { *r++ = *a++; b++; }
		else { *r++ = *b++; a++; }
	}
}
