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

// What DicomStudy (Swift since #721) keeps in Objective-C, declared in
// DicomStudy.h for the Swift class only:
// - soundex4, exported under its C name as the former DicomStudy.m did;
// - the calendar difference behind the ages, NSCalendarDate being unavailable
//   in Swift;
// - random(), unavailable in Swift, for the letters +scrambleString: shuffles.

#import <DCM/DCMCalendarDate.h>
#import "DicomStudy.h"

// The header declares them only for Swift.
NSString* soundex4( NSString *inString);
void HorosDicomStudyYearsMonthsDays(NSDate *later, NSDate *sinceDate, NSInteger *years, NSInteger *months, NSInteger *days);
long HorosDicomStudyRandom(void);

#define WBUFSIZE 512

NSString* soundex4( NSString *inString)
{
    char *p, *p1;
    int i;
    char workbuf[WBUFSIZE + 1];
    char priorletter;
    
    if( inString == nil) return nil;
    
    /* Make a working copy  */
    
    strncpy(workbuf, [[inString uppercaseString] UTF8String], WBUFSIZE);
    workbuf[WBUFSIZE] = 0;
    
    /* Convert all vowels to 'A'  */
    
    for (p = workbuf; *p; ++p)
    {
        if (strchr("AEIOUY", *p))
            *p = 'A';
    }
    
    /* Prefix transformations: done only once on the front of a name */
    
    if ( 0 == strncmp(workbuf, "MAC", 3))     /* MAC to MCC    */
        workbuf[1] = 'C';
    else if ( 0 == strncmp(workbuf, "KN", 2)) /* KN to NN      */
        workbuf[0] = 'N';
    else if ('K' == workbuf[0])                     /* K to C        */
        workbuf[0] = 'C';
    else if ( 0 == strncmp(workbuf, "PF", 2)) /* PF to FF      */
        workbuf[0] = 'F';
    else if ( 0 == strncmp(workbuf, "SCH", 3))/* SCH to SSS    */
        workbuf[1] = workbuf[2] = 'S';
    
    /*
     ** Infix transformations: done after the first letter,
     ** left to right
     */
    
    while ((p = strstr(workbuf, "DG")) > workbuf)   /* DG to GG      */
        p[0] = 'G';
    while ((p = strstr(workbuf, "CAAN")) > workbuf) /* CAAN to TAAN  */
        p[0] = 'T';
    while ((p = strchr(workbuf, 'D')) > workbuf)    /* D to T        */
        p[0] = 'T';
    while ((p = strstr(workbuf, "NST")) > workbuf)  /* NST to NSS    */
        p[2] = 'S';
    while ((p = strstr(workbuf, "AV")) > workbuf)   /* AV to AF      */
        p[1] = 'F';
    while ((p = strchr(workbuf, 'Q')) > workbuf)    /* Q to G        */
        p[0] = 'G';
    while ((p = strchr(workbuf, 'Z')) > workbuf)    /* Z to S        */
        p[0] = 'S';
    while ((p = strchr(workbuf, 'M')) > workbuf)    /* M to N        */
        p[0] = 'N';
    while ((p = strstr(workbuf, "KN")) > workbuf)   /* KN to NN      */
        p[0] = 'N';
    while ((p = strchr(workbuf, 'K')) > workbuf)    /* K to C        */
        p[0] = 'C';
    while ((p = strstr(workbuf, "AH")) > workbuf)   /* AH to AA      */
        p[1] = 'A';
    while ((p = strstr(workbuf, "HA")) > workbuf)   /* HA to AA      */
        p[0] = 'A';
    while ((p = strstr(workbuf, "AW")) > workbuf)   /* AW to AA      */
        p[1] = 'A';
    while ((p = strstr(workbuf, "PH")) > workbuf)   /* PH to FF      */
        p[0] = p[1] = 'F';
    while ((p = strstr(workbuf, "SCH")) > workbuf)  /* SCH to SSS    */
        p[0] = p[1] = 'S';
    
    /*
     ** Suffix transformations: done on the end of the word,
     ** right to left
     */
    
    /* (1) remove terminal 'A's and 'S's      */
    
    for (i = strlen(workbuf) - 1;
         (i > 0) && ('A' == workbuf[i] || 'S' == workbuf[i]);
         --i)
    {
        workbuf[i] = 0;
    }
    
    /* (2) terminal NT to TT      */
    
    for (i = strlen(workbuf) - 1;
         (i > 1) && ('N' == workbuf[i - 1] || 'T' == workbuf[i]);
         --i)
    {
        workbuf[i - 1] = 'T';
    }
    
    /* Now strip out all the vowels except the first     */
    
    p = p1 = workbuf;
    while ( 0 != (*p1++ = *p++))
    {
        while ('A' == *p)
            ++p;
    }
    
    /* Remove all duplicate letters     */
    
    p = p1 = workbuf;
    priorletter = 0;
    do {
        while (*p == priorletter)
            ++p;
        priorletter = *p;
    } while (0 != (*p1++ = *p++));
    
    /* Finish up */
    
    return [NSString stringWithUTF8String: workbuf];
}

void HorosDicomStudyYearsMonthsDays(NSDate *later, NSDate *sinceDate, NSInteger *years, NSInteger *months, NSInteger *days)
{
    DCMCalendarDate *momsBDay = [DCMCalendarDate dateWithTimeIntervalSinceReferenceDate: [sinceDate timeIntervalSinceReferenceDate]];
    DCMCalendarDate *dateOfBirth = later ? [DCMCalendarDate dateWithTimeIntervalSinceReferenceDate: [later timeIntervalSinceReferenceDate]] : [DCMCalendarDate date];
    
    [dateOfBirth years:years months:months days:days hours:NULL minutes:NULL seconds:NULL sinceDate:momsBDay];
}


long HorosDicomStudyRandom(void)
{
    return random();
}
