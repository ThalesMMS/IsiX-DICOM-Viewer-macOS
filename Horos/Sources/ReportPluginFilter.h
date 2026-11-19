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


#import <Cocoa/Cocoa.h>
#import "PluginFilter.h"

/** \brief  Report Plugin Filter base class

The base class the Horos and OsiriX SDK gave the principal class of a report
plugin (pluginType "Report"): a PluginFilter whose three report messages answer
that it made, deleted and dated no report, for the plugin to override. A plugin
built for Horos or OsiriX subclasses it in Objective-C and its binary looks the
class up by name in the application.

ReportPluginFilter.swift implements the class (@objc @implementation), so the
runtime sees an Objective-C class of this name that such a subclass can inherit
from.
*/
@interface ReportPluginFilter : PluginFilter

// The former SDK declared these with a study of type id and a date of type
// NSDate *; they are declared here as PluginFilter declares the messages they
// override, which the same selectors and the same values satisfy.
- (BOOL)createReportForStudy:(NSManagedObject *)study;
- (BOOL)deleteReportForStudy:(NSManagedObject *)study;
- (id)reportDateForStudy:(NSManagedObject *)study;

@end
