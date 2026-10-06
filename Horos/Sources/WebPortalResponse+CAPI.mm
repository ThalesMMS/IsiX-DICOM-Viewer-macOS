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

// What WebPortalResponse (Swift) keeps in Objective-C.

#import "WebPortalResponse.h"
#import "NSString+N2.h"

// The former function, which the application exports with its C++ name. The
// Swift StringTransformer formats the same way.
__attribute__((used)) NSString* iPhoneCompatibleNumericalFormat(NSString* aString) { // this is to avoid numbers to be interpreted as phone numbers
	NSMutableString* newString = [NSMutableString string];
	for (int i = 0; i < aString.length; ++i) {
		[newString appendString:@"<span>"];
		[newString appendString:[[aString substringWithRange:NSMakeRange(i,1)] xmlEscapedString]];
		[newString appendString:@"</span>"];
	}
	return newString;
}

// -httpHeaders, declared in WebPortalResponse.h: Swift cannot declare it with
// the type of the former property, because HTTPDataResponse's HTTPResponse
// conformance declares it with NSDictionary. As before, it answers the mutable
// dictionary callers add headers to, and HTTPConnection sends.
@implementation WebPortalResponse (HTTPHeaders)

-(NSMutableDictionary*)httpHeaders {
	return self.mutableHTTPHeaders;
}

@end

// HTTPDataResponse sends its `data` instance variable, which Swift cannot
// reach: WebPortalResponse's -data and -setData: keep it through these, with
// the retain and release of the former -setData:.
@implementation HTTPDataResponse (WebPortalResponseData)

-(NSData*)webPortalResponseData {
	return data;
}

-(void)setWebPortalResponseData:(NSData*)d {
	if (data != d) {
		[data release];
		data = [d retain];
	}
}

@end
