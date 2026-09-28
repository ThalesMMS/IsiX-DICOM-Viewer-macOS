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

#import "HorosGDCMAnonymizer.h"
#import "DCMAttributeTag.h"
#import "DicomFile.h"
#import "DICOMToNSString.h"
#import "DicomFileDCMTKCategory.h"
#include <GDCM/gdcmReader.h>
#include <GDCM/gdcmDefs.h>
#include <GDCM/gdcmAnonymizer.h>
#include <GDCM/gdcmWriter.h>

@implementation HorosGDCMAnonymizer

// Moved from the second loop of +[Anonymization anonymizeFiles:...error:] in
// Anonymization.mm (440c1c1b7), where `f` was the staged file, `continue` went
// on to the next one and every failure also set anonymationSuccess = NO.
+ (NSString *)anonymizeStagedFile:(NSString *)f withTags:(NSArray *)tags failure:(NS_NOESCAPE HorosGDCMAnonymizerFailure)failure
{
        // The file system's representation: defaultCStringEncoding gave NULL
        // for a folder name it cannot represent, and GDCM a NULL file name (#749).
        const char* filename = [f fileSystemRepresentation];
        
        gdcm::Reader reader;
        
        reader.SetFileName(filename);
        
        if( !reader.Read() )
        {
            failure(NSLocalizedString(@"An input file is not a readable DICOM file.", nil), nil);
            
            return nil;
        }
        else
        {
            gdcm::File &file = reader.GetFile();
            
            gdcm::MediaStorage ms;
            ms.SetFromFile(file);
            if( !gdcm::Defs::GetIODNameFromMediaStorage(ms) )
            {
                failure(NSLocalizedString(@"An input DICOM storage type is not supported for anonymization.", nil), nil);
                
                return nil;
            }
            else
            {
                NSStringEncoding encoding =
                [NSString encodingForDICOMCharacterSet:[[DicomFile getEncodingArrayForFile:f] objectAtIndex: 0]];
                
                std::vector< std::pair<gdcm::Tag, std::string> > replace_tags;
                for (NSArray* replacingItem in tags)
                {
                    std::string newValue = "";
                    
                    DCMAttributeTag* tag = [replacingItem objectAtIndex:0];
                    if ([replacingItem count] > 1) {
                        const char *encoded = [[[replacingItem objectAtIndex:1] description] cStringUsingEncoding:encoding];
                        if (!encoded) {
                            failure(NSLocalizedString(@"A replacement value cannot be represented in the input file's character set.", nil),
                                    [NSString stringWithFormat:@"(%04X,%04X)", tag.group, tag.element]);
                            continue;
                        }
                        newValue = std::string(encoded);
                    }
                    
                    replace_tags.push_back( std::make_pair(gdcm::Tag(tag.group,tag.element),newValue) );                    
                }
                
                /////////////////////////////
                /////////////////////////////
                /////////////////////////////
                /////////////////////////////
                /////////////////////////////
                
                gdcm::Anonymizer anon;
                anon.SetFile( file );
                
                std::vector< std::pair<gdcm::Tag, std::string> >::const_iterator it2 = replace_tags.begin();
                for(; it2 != replace_tags.end(); ++it2)
                {
                    if (!anon.Replace(it2->first, it2->second.c_str())) {
                        failure(NSLocalizedString(@"The DICOM anonymizer cannot replace one or more selected fields.", nil),
                                [NSString stringWithFormat:@"(%04X,%04X)", it2->first.GetGroup(), it2->first.GetElement()]);
                    }
                }
                
                /////////////////////////////
                /////////////////////////////
                /////////////////////////////
                /////////////////////////////
                /////////////////////////////
                
                NSString* anon_folder = [f stringByDeletingLastPathComponent];
                NSString* anon_filename = [f lastPathComponent];
                NSString* _outfilename = [NSString stringWithFormat:@"%@/anon_%@",anon_folder,anon_filename];
                const char* outfilename = [_outfilename fileSystemRepresentation];
                
                gdcm::Writer writer;
                writer.SetFileName( outfilename );
                writer.SetFile( file );
                
                if( !writer.Write() )
                {
                    failure(NSLocalizedString(@"An anonymized file could not be written. Check available space and destination permissions.", nil), nil);
                    if( strcmp(filename,outfilename) != 0 )
                    {
                        gdcm::System::RemoveFile( outfilename );
                    }
                    else
                    {
                        std::cerr << "gdcmanon just corrupted: " << filename << " (data lost)." << std::endl;
                        
                    }
                    
                    return nil;
                }
                else
                {
                    return _outfilename;
                }
            }
        }
}

@end
