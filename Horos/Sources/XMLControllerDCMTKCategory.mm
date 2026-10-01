/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ùversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ùSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ùIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ù OsiriX
 ùCopyright (c) OsiriX Team
 ùAll rights reserved.
 ùDistributed under GNU - LGPL
 ù
 ùSee http://www.osirix-viewer.com/copyright.html for details.
 ù ù This software is distributed WITHOUT ANY WARRANTY; without even
 ù ù the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ù ù PURPOSE.
 ============================================================================*/

#import "XMLControllerDCMTKCategory.h"
#import "BrowserController.h"
#import "HorosAtomicFileWriter.h"
#undef verify

#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#import "HorosDICOMCLI.h"
#import "N2Debug.h"

#include <dcmtk/dcmdata/dcvrsl.h>
#include <dcmtk/ofstd/ofcast.h>
#include <dcmtk/ofstd/ofstd.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmdata/dcuid.h>

#include <cstdio>
#include <dcmtk/ofstd/ofstdinc.h>


#import "DicomFile.h"
#import "DICOMToNSString.h"
#import "DicomFileDCMTKCategory.h"
#import "DICOMDataDictionary.h"
#import "DCMAttributeTag.h"
#import "DCMCharacterSet.h"
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "HorosDCMTKTagEditing.h"
#include "HorosDICOMEditingStorage.h"
#include "HorosDCMTKSeekableInput.h"

// XMLController is Swift: -prepareDictionaryArray fills its array
// through this accessor, which the Swift class implements.
@interface XMLController (HorosDictionaryArray)
- (NSMutableArray*) horos_dictionaryArray;
@end

// One requested change to one element. Removing an element and emptying it are
// different requests and were not distinguished before: everything became a
// replacement, so a request to delete a tag left it present and empty.
typedef struct
{
    unsigned short group;
    unsigned short element;
    bool removes;
    std::string value; // UTF-8 until the destination leaf is resolved.
    // Empty for a top-level element. Otherwise the sequences to descend,
    // outermost first, before group/element names an element inside the last
    // item.
    std::vector<HorosTagPathStep> path;
} HorosTagEdit;

// KVC paths are an Objective-C boundary: reject nonintegral or out-of-range
// numbers before narrowing them to a tag or sequence item index.
static bool HorosReadEditNumber(id number, uint64_t maximum, uint64_t *result)
{
    if (![number isKindOfClass:[NSNumber class]]) return false;
    uint64_t value = [number unsignedLongLongValue];
    if ([number compare:@0] == NSOrderedAscending || value > maximum ||
        [number compare:@(value)] != NSOrderedSame) return false;
    *result = value;
    return true;
}

// Use the complete address in diagnostics, including zero-based item indices.
static NSString *HorosTagEditAddress(const HorosTagEdit &edit)
{
    NSMutableString *address = [NSMutableString string];
    for (const HorosTagPathStep &step : edit.path)
        [address appendFormat:@"(%04x,%04x)[%u].", step.group, step.element, step.item];
    [address appendFormat:@"(%04x,%04x)", edit.group, edit.element];
    return address;
}

// Reads the loosely typed argument several callers build: an entry of one
// element removes that tag, an entry of two replaces it with the second, and an
// empty string is a legitimate replacement value. NSNull in the second position
// is a removal too, because that is how the metadata editor already marks a row
// as "to be deleted". Entries that are not shaped like that are counted and
// skipped rather than raising, because the argument arrives from callers that
// assemble it by hand.
static std::vector<HorosTagEdit> HorosTagEditsFromEntries( NSArray *entries, NSUInteger *rejected, NSMutableArray *refusals = nil)
{
    std::vector<HorosTagEdit> edits;
    
    for( id entry in entries)
    {
        @try
        {
            if( [entry isKindOfClass: [NSArray class]] == NO || [(NSArray*) entry count] == 0)
            {
                if( rejected) (*rejected)++;
                [refusals addObject:@"An edit has no readable element address."];
                continue;
            }
        
            NSArray *fields = (NSArray*) entry;
            id first = [fields objectAtIndex: 0];
        
            HorosTagEdit edit = {};
        
            // A tag names an element at the top level. A path names one inside a
            // sequence, which the metadata editor addresses as
            // (0054,0016)[0].(0018,1074): reading only its first tag sent the edit
            // to the sequence element instead of to the value.
            if( [first respondsToSelector: @selector(steps)] && [first respondsToSelector: @selector(group)])
            {
                id path = first;
                uint64_t group = 0, element = 0;
                id steps = [path valueForKey:@"steps"];
                bool readable = [steps isKindOfClass:[NSArray class]] &&
                    HorosReadEditNumber([path valueForKey:@"group"], UINT16_MAX, &group) &&
                    HorosReadEditNumber([path valueForKey:@"element"], UINT16_MAX, &element);
                edit.group = (unsigned short)group;
                edit.element = (unsigned short)element;
                if (readable) for (id step in steps)
                {
                    uint64_t item = 0;
                    if (!HorosReadEditNumber([step valueForKey:@"item"], UINT32_MAX, &item) ||
                        !HorosReadEditNumber([step valueForKey:@"group"], UINT16_MAX, &group) ||
                        !HorosReadEditNumber([step valueForKey:@"element"], UINT16_MAX, &element))
                    {
                        readable = false;
                        break;
                    }
                    HorosTagPathStep descent;
                    descent.group = (unsigned short)group;
                    descent.element = (unsigned short)element;
                    descent.item = (unsigned int)item;
                    edit.path.push_back(descent);
                }

                if( !readable)
                {
                    if( rejected) (*rejected)++;
                    [refusals addObject:[NSString stringWithFormat:@"%@: the address or value could not be read.", HorosTagEditAddress(edit)]];
                    continue;
                }
            }
            else if( [first isKindOfClass: [DCMAttributeTag class]])
            {
                DCMAttributeTag *tag = (DCMAttributeTag*) first;
                edit.group = tag.group;
                edit.element = tag.element;
            }
            else
            {
                if( rejected) (*rejected)++;
                [refusals addObject:@"An edit has no readable element address."];
                continue;
            }

            edit.removes = (fields.count < 2) || [[fields objectAtIndex: 1] isKindOfClass: [NSNull class]];
        
            if( edit.removes == false)
            {
                id value = [fields objectAtIndex: 1];
            
                if( [value isKindOfClass: [NSString class]] == NO)
                {
                    if( rejected) (*rejected)++;
                    [refusals addObject:[NSString stringWithFormat:@"%@: the address or value could not be read.", HorosTagEditAddress(edit)]];
                    continue;
                }

                // Preserve the Unicode value until the file/item charset is known.
                // A C string would silently truncate an embedded NUL.
                NSData *bytes = [(NSString*) value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
                if (!bytes || bytes.length > UINT32_MAX - 1 ||
                    (bytes.length && memchr(bytes.bytes, 0, bytes.length)))
                {
                    if (rejected) (*rejected)++;
                    [refusals addObject:[NSString stringWithFormat:@"%@: the value contains NUL, invalid Unicode, or exceeds the DICOM value length.", HorosTagEditAddress(edit)]];
                    continue;
                }
                if (bytes.length) edit.value.assign((const char *)bytes.bytes, bytes.length);

            }
        
            edits.push_back( edit);
        }
        @catch (NSException *exception)
        {
            if (rejected) (*rejected)++;
            [refusals addObject:@"An edit has no readable element address or value."];
        }
    }
    
    return edits;
}

// An item's declaration overrides its parent; an absent declaration inherits.
// Only the root's absence uses the same preference and Latin-1 fallback as the
// reader. Read the already loaded dataset rather than opening another file.
static NSString *HorosEffectiveCharacterSet(DcmItem &dataset, NSString *inherited)
{
    DcmElement *element = nullptr;
    if (dataset.findAndGetElement(DCM_SpecificCharacterSet, element, OFFalse).bad() || !element)
    {
        if (inherited) return inherited;
        NSString *chosen = [DCMCharacterSet characterSetWhenAbsent];
        return chosen.length ? chosen : @"ISO_IR 100";
    }
    OFString bytes;
    if (element->getOFStringArray(bytes).bad()) return @"<invalid charset>";
    NSString *charset = [[[NSString alloc] initWithBytes:bytes.data() length:bytes.size()
                                               encoding:NSASCIIStringEncoding] autorelease];
    return charset ? [charset stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"<invalid charset>";
}

// Foundation's single-code-page table is not an ISO 2022 DICOM encoder. Never
// select just the first term of a declaration with code extensions. ASCII VRs
// are independent of (0008,0005); emptying/removing needs no encoder.
static bool HorosEncodeEditValue(const std::string &utf8, DcmEVR vr, NSString *charset,
                                 std::string *encoded, std::string *reason)
{
    if (utf8.empty()) { encoded->clear(); return true; }
    NSString *value = [[[NSString alloc] initWithBytes:utf8.data() length:utf8.size()
                                             encoding:NSUTF8StringEncoding] autorelease];
    if (!value || utf8.find('\0') != std::string::npos)
    {
        if (reason) *reason = "the value contains NUL or invalid Unicode";
        return false;
    }
    NSStringEncoding encoding = NSASCIIStringEncoding;
    const bool usesCharset = vr == EVR_PN || vr == EVR_LO || vr == EVR_LT ||
        vr == EVR_SH || vr == EVR_ST || vr == EVR_UC || vr == EVR_UT || vr == EVR_UN;
    if (usesCharset)
    {
        NSString *normalized = [[[charset stringByReplacingOccurrencesOfString:@"_" withString:@" "]
                                 stringByReplacingOccurrencesOfString:@"-" withString:@" "] uppercaseString];
        NSArray *safe = @[@"ISO IR 6", @"ISO IR 100", @"ISO IR 101", @"ISO IR 109", @"ISO IR 110",
                          @"ISO IR 144", @"ISO IR 127", @"ISO IR 126", @"ISO IR 138", @"ISO IR 148",
                          @"ISO IR 166", @"ISO IR 192", @"UTF 8", @"GB18030",
                          @"WINDOWS 1250", @"WINDOWS 1251", @"WINDOWS 1252", @"WINDOWS 1253",
                          @"WINDOWS 1254", @"WINDOWS 1255", @"WINDOWS 1256", @"WINDOWS 1257", @"WINDOWS 1258",
                          @"CP1250", @"CP1251", @"CP1252", @"CP1253", @"CP1254", @"CP1255", @"CP1256", @"CP1257", @"CP1258"];
        if ([normalized containsString:@"\\"] || [normalized containsString:@"ISO 2022"] ||
            (normalized.length && ![safe containsObject:normalized]))
        {
            if (reason) *reason = std::string("no safe text encoder for effective character set ") + charset.UTF8String;
            return false;
        }
        if (normalized.length && ![normalized isEqualToString:@"ISO IR 6"])
            encoding = [NSString encodingForDICOMCharacterSet:charset];
    }
    NSData *bytes = [value dataUsingEncoding:encoding allowLossyConversion:NO];
    if (!bytes)
    {
        if (reason) *reason = std::string("the value is not representable in effective character set ") +
            (usesCharset ? charset.UTF8String : "ASCII (this VR does not use Specific Character Set)");
        return false;
    }
    // Leave room for even-length padding, and for the explicit VR length field.
    const NSUInteger maximum = DcmVR(vr).usesExtendedLengthEncoding() ? UINT32_MAX - 1 : UINT16_MAX - 1;
    if (bytes.length > maximum || (bytes.length && memchr(bytes.bytes, 0, bytes.length)))
    {
        if (reason) *reason = "the encoded value contains NUL or exceeds the DICOM value length";
        return false;
    }
    encoded->assign((const char *)bytes.bytes, bytes.length);
    return true;
}

// Resolve only existing sequence items, then encode for the destination leaf.
// Cloning/replacing that leaf belongs to the dcmdata adapter; no dictionary
// path creation or recursive search for the final tag is used here.
static bool HorosWriteInDataSet(DcmItem &dataset, const HorosTagEdit &edit,
                                bool *existed, std::string *reason)
{
    std::vector<DcmItem *> ancestors;
    DcmItem *item = HorosDICOMEditingResolveItem(dataset, edit.path, ancestors, reason);
    if (!item) return false;
    const DcmTagKey key(edit.group, edit.element);
    DcmElement *element = nullptr;
    item->findAndGetElement(key, element, OFFalse);
    if (existed) *existed = element != nullptr;
    if (edit.removes)
        return HorosDICOMEditingWriteElement(*item, key, true, "", !edit.path.empty(), reason);
    DcmEVR vr = element ? element->getVR() : DcmTag(key).getEVR();
    if (!element && (key.getGroup() & 1) && key.getElement() >= 0x0010 && key.getElement() <= 0x00ff)
        vr = EVR_LO;
    NSString *charset = nil;
    for (DcmItem *ancestor : ancestors)
        charset = HorosEffectiveCharacterSet(*ancestor, charset);
    std::string encoded;
    if (!HorosEncodeEditValue(edit.value, vr, charset, &encoded, reason)) return false;
    return HorosDICOMEditingWriteElement(*item, key, false, encoded, !edit.path.empty(), reason);
}

@implementation XMLController (XMLControllerDCMTKCategory)


+ (BOOL) modifyDicom:(NSArray*) tagAndValues dicomFiles:(NSArray*) dicomFiles
{
    return [XMLController modifyDicom: tagAndValues dicomFiles: dicomFiles reasons: NULL];
}

+ (BOOL) modifyDicom:(NSArray*) tagAndValues dicomFiles:(NSArray*) dicomFiles reasons:(NSArray**) reasons
{
    BOOL modifySuccess = YES;
    NSUInteger savedEdits = 0, savedFiles = 0;
    NSMutableArray *refusals = reasons ? [NSMutableArray array] : nil;

    // Bound parser/charset/staging temporaries to one file even when a caller
    // applies many files or calls repeatedly in the same pool. The outer array
    // retains diagnostics until the caller reads them.
    for (NSString *f in dicomFiles) @autoreleasepool
    {
        // The owner keeps deferred values (including deflated backing) alive
        // until saveFile has finished and closed the staged output.
        HorosDCMTKSeekableInput input;
        OFCondition loaded = input.load(f.fileSystemRepresentation, NSTemporaryDirectory().fileSystemRepresentation);
        if (loaded.bad())
        {
            [refusals addObject:[NSString stringWithFormat:NSLocalizedString(@"%@: the file could not be read (%s); no edits were saved.", nil), f.lastPathComponent, loaded.text()]];
            modifySuccess = NO;
            continue;
        }
        DcmFileFormat &file = input.fileFormat();
        DcmDataset &dataset = *file.getDataset();
        const bool hasMeta = file.getMetaInfo()->card() != 0;
        OFString storage;
        dataset.findAndGetOFStringArray(DCM_SOPClassUID, storage, OFFalse);
        if (storage.empty())
        {
            OFString metaStorage;
            file.getMetaInfo()->findAndGetOFStringArray(DCM_MediaStorageSOPClassUID, metaStorage, OFFalse);
            if (metaStorage == UID_MediaStorageDirectoryStorage) storage = metaStorage;
        }
        if (!dataset.card() || !HorosDICOMEditingSupportsStorage(storage.c_str()))
        {
            [refusals addObject:[NSString stringWithFormat:NSLocalizedString(@"%@: invalid or unsupported media storage (%s); no edits were saved.", nil), f.lastPathComponent, storage.c_str()]];
            modifySuccess = NO;
            continue;
        }
        // Deflated input is parsed from Explicit LE backing but retains the
        // source's meta header. Use its declared syntax, never a fallback.
        OFString syntaxUID;
        file.getMetaInfo()->findAndGetOFStringArray(DCM_TransferSyntaxUID, syntaxUID, OFFalse);
        E_TransferSyntax syntax = syntaxUID.empty() ? dataset.getOriginalXfer() : DcmXfer(syntaxUID.c_str()).getXfer();
        if (syntax == EXS_Unknown || !file.canWriteXfer(syntax))
        {
            [refusals addObject:[NSString stringWithFormat:NSLocalizedString(@"%@: the original transfer syntax cannot be preserved; no edits were saved.", nil), f.lastPathComponent]];
            modifySuccess = NO;
            continue;
        }

        NSUInteger rejected = 0;
        NSMutableArray *fileRefusals = [NSMutableArray array];
        std::vector<HorosTagEdit> edits = HorosTagEditsFromEntries(tagAndValues, &rejected, fileRefusals);
        NSUInteger changed = 0;
        bool changedClass = false, changedInstance = false;
        for (const HorosTagEdit &edit : edits)
        {
            std::string reason;
            bool existed = false;
            bool applied = HorosWriteInDataSet(dataset, edit, &existed, &reason);
            if (!applied)
                [fileRefusals addObject:[NSString stringWithFormat:@"%@: %s", HorosTagEditAddress(edit), reason.c_str()]];
            else if (!edit.removes || existed || !edit.path.empty())
            {
                ++changed;
                if (edit.path.empty())
                {
                    const DcmTagKey key(edit.group, edit.element);
                    changedClass |= key == DCM_SOPClassUID;
                    changedInstance |= key == DCM_SOPInstanceUID;
                }
            }
        }
        if (rejected || fileRefusals.count) modifySuccess = NO;
        for (NSString *refusal in fileRefusals)
            [refusals addObject:[NSString stringWithFormat:@"%@: %@", f.lastPathComponent, refusal]];

        // Refusals alone must not normalize or rewrite an otherwise untouched file.
        if (!changed) continue;
        std::string identityReason;
        if ((changedClass && !HorosDICOMEditingSynchronizeUID(file, DCM_SOPClassUID, &identityReason)) ||
            (changedInstance && !HorosDICOMEditingSynchronizeUID(file, DCM_SOPInstanceUID, &identityReason)) ||
            !file.canWriteXfer(syntax))
        {
            [refusals addObject:[NSString stringWithFormat:NSLocalizedString(@"%@: identity or original transfer syntax could not be preserved (%s); no edits were saved.", nil), f.lastPathComponent, identityReason.c_str()]];
            modifySuccess = NO;
            continue;
        }
        __block OFCondition written = EC_Normal;
        BOOL published = HorosWriteFileAtomically(f, ^BOOL(NSString *prepared) {
            // saveFile propagates write and fclose errors. Do not choose a
            // pixel representation, decode/re-encode, or load all data eagerly.
            written = file.saveFile(prepared.fileSystemRepresentation, syntax,
                EET_UndefinedLength, EGL_recalcGL, EPD_noChange, 0, 0,
                hasMeta ? EWM_dontUpdateMeta : EWM_dataset);
            return written.good();
        });
        if (!published)
        {
            [refusals addObject:[NSString stringWithFormat:NSLocalizedString(@"%@: writing or publishing failed (%s); the original file is unchanged and no edits were saved.", nil), f.lastPathComponent, written.text()]];
            modifySuccess = NO;
        }
        else
        {
            savedEdits += changed;
            ++savedFiles;
        }
    }
    if (reasons)
    {
        if (!modifySuccess)
            [refusals insertObject:[NSString stringWithFormat:NSLocalizedString(@"Saved %lu edits in %lu files. Refused fields retain their original values; files that could not be written retain their original bytes.", nil), (unsigned long)savedEdits, (unsigned long)savedFiles] atIndex:0];
        *reasons = refusals;
    }
    return modifySuccess;
}

+ (int) modifyDicom:(NSArray*) params encoding: (NSStringEncoding) encoding
{
    return HorosModifyDICOMCLI(params, encoding);
}

-(int) getGroupAndElementForName:(NSString*) name group:(int*) gp element:(int*) el
{
    unsigned group = 0xffff, element = 0xffff;
    if( !HorosResolveDicomKeyword( name, &group, &element))
        return -1;
    *gp = (int) group;
    *el = (int) element;
    return 0;
}

- (void) prepareDictionaryArray
{
	DcmDictEntry* e = NULL;
	DcmDataDictionary& globalDataDict = dcmDataDict.wrlock();
	
	DcmDictEntryList list;
    DcmHashDictIterator iter(globalDataDict.normalBegin());
    for( int x = 0; x < globalDataDict.numberOfNormalTagEntries(); ++iter, x++)
    {
        if ((*iter)->getPrivateCreator() == NULL) // exclude private tags
        {
          e = new DcmDictEntry(*(*iter));
          list.insertAndReplace(e);
        }
    }
	
    /* output the list contents */
    DcmDictEntryListIterator listIter(list.begin());
    DcmDictEntryListIterator listLast(list.end());
    for (; listIter != listLast; ++listIter)
    {
		e = *listIter;
		
		if( e->getGroup() > 0)
		{
			NSString	*s = [NSString stringWithFormat:@"(0x%04x,0x%04x) %s", e->getGroup(), e->getElement(), e->getTagName()];
		
			[[self horos_dictionaryArray] addObject: s];
		}
    }
	
	dcmDataDict.wrunlock();
}
@end
