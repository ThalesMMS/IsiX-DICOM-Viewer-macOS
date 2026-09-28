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
 ============================================================================*/

#import "HorosObjCException.h"

NSErrorDomain const HorosObjCExceptionErrorDomain = @"HorosObjCExceptionErrorDomain";
NSString * const HorosObjCExceptionKey = @"HorosObjCException";

@implementation HorosObjCException

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error
{
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        if (error)
            *error = [NSError errorWithDomain: HorosObjCExceptionErrorDomain code: 1
                                     userInfo: @{NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                                                 NSLocalizedFailureReasonErrorKey: exception.name,
                                                 HorosObjCExceptionKey: exception}];
        return NO;
    }
}

@end
