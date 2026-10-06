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

// What DicomImage.swift cannot declare: the C functions of <Horos/DicomImage.h>
// that encode and decode a compressed SOP Instance UID, exported under their C
// names as before; N2LogStackTrace, a C variadic function Swift cannot call; and
// the setters of the modelled properties date and series, whose getters stay
// the ones Core Data generates (Swift cannot leave one half of a property to
// Core Data).

#import "DicomImage.h"
#import "N2Debug.h"

static inline int charToInt( unsigned char c)
{
	switch( c)
	{
		case 0:			return 0;		break;
		case '0':		return 1;		break;
		case '1':		return 2;		break;
		case '2':		return 3;		break;
		case '3':		return 4;		break;
		case '4':		return 5;		break;
		case '5':		return 6;		break;
		case '6':		return 7;		break;
		case '7':		return 8;		break;
		case '8':		return 9;		break;
		case '9':		return 10;		break;
		case '.':		return 11;		break;
	}
	
	return c % 12;
}

static inline unsigned char intToChar( int c)
{
	switch( c)
	{
		case 0:		return 0;		break;
		case 1:		return '0';		break;
		case 2:		return '1';		break;
		case 3:		return '2';		break;
		case 4:		return '3';		break;
		case 5:		return '4';		break;
		case 6:		return '5';		break;
		case 7:		return '6';		break;
		case 8:		return '7';		break;
		case 9:		return '8';		break;
		case 10:	return '9';		break;
		case 11:	return '.';		break;
	}
	
	return '0';
}

// Both buffers are sized from the UID: they were 1024 bytes, which a UID
// of more than 2048 characters, or a compressed one of more than 511 bytes,
// overran.
void* sopInstanceUIDEncode( NSString *sopuid)
{
	NSUInteger		i, x, length = [sopuid length];
	unsigned char	*r = malloc( length / 2 + 1);
	
    if( r)
    {
        for( i = 0, x = 0; i < length;)
        {
            unsigned char c1, c2;
            
            c1 = [sopuid characterAtIndex: i];
            i++;
            if( i == length) c2 = 0;
            else c2 = [sopuid characterAtIndex: i];
            i++;
            
            r[ x] = (charToInt( c1) << 4) + charToInt( c2);
            x++;
        }
	}
    
	return r;
}

NSString* sopInstanceUIDDecode( unsigned char *r, int length)
{
	int				i, x;
	
	if( length < 0)
		length = 0;
	
	char			*str = malloc( 2 * (size_t) length + 1);
	if( str == NULL)
		return nil;
	
	for( i = 0, x = 0; i < length; i++)
	{
		unsigned char c1, c2;
		
		c1 = r[ i] >> 4;
		c2 = r[ i] & 15;
		
		str[ x] = intToChar( c1);
		x++;
		str[ x] = intToChar( c2);
		x++;
	}
	
	str[ x ] = '\0';
	
	NSString *uid = [NSString stringWithCString:str encoding: NSASCIIStringEncoding];
	free( str);
	return uid;
}

// Declared for Swift in DicomImage.h.
extern void DicomImageLogStackTrace(NSString* message);

void DicomImageLogStackTrace(NSString* message)
{
    N2LogStackTrace(@"%@", message);
}

@interface DicomImage (CoreDataCustomSetters)
@end

@implementation DicomImage (CoreDataCustomSetters)

- (void) setDate:(NSDate*) date
{
    [self horos_setDate: date];
}

- (void) setSeries:(DicomSeries *)series
{
    [self horos_setSeries: series];
}

@end
