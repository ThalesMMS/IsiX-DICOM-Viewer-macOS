//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC.

#import "IsiXDCMTKDictionary.h"
#import "IsiXDCMTKInternal.hpp"

#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcdicent.h>
#include <dcmtk/dcmdata/dchashdi.h>
#include <dcmtk/dcmdata/dctag.h>
#include <dcmtk/dcmdata/dcvr.h>
#include "HorosDictionaryLookup.hpp"

#if !__has_feature(objc_arc)
#error "IsiXDCMTKDictionary.mm is compiled with ARC (-fobjc-arc)"
#endif

namespace {
// The global dictionary stays write-locked from the first entry read to the
// last; an exception in between must not leave it locked.
struct IsiXDCMTKDictionaryWriteLock {
    DcmDataDictionary &dictionary;
    IsiXDCMTKDictionaryWriteLock() : dictionary(dcmDataDict.wrlock()) {}
    ~IsiXDCMTKDictionaryWriteLock() { dcmDataDict.wrunlock(); }
};
}

BOOL HorosLoadVendoredDicomDictionary(NSString *path)
{
    if (path.length == 0 || ![[NSFileManager defaultManager] isReadableFileAtPath:path]) return NO;
    const char *fileSystemPath = IsiXDCMTKFileSystemPath(path);
    if (fileSystemPath == NULL) return NO;
    BOOL loaded = NO;
    IsiXDCMTKGuard(NULL, "DcmDataDictionary::loadDictionary", [&]() -> NSError * {
        IsiXDCMTKDictionaryWriteLock lock;
        loaded = lock.dictionary.loadDictionary(fileSystemPath, OFTrue);
        return nil;
    });
    return loaded;
}

NSString *HorosVendoredDicomDictionaryPath(void)
{
    NSString *bundled = [[NSBundle mainBundle] pathForResource: @"dicom" ofType: @"dic"];
    if (bundled.length && [[NSFileManager defaultManager] isReadableFileAtPath: bundled])
        return bundled;

    NSString *executable = [[[NSProcessInfo processInfo] arguments] firstObject];
    if (executable.length)
    {
        NSString *beside = [[executable stringByDeletingLastPathComponent] stringByAppendingPathComponent: @"dicom.dic"];
        if ([[NSFileManager defaultManager] isReadableFileAtPath: beside])
            return beside;
    }
    return nil;
}

static void HorosEnsureVendoredDicomDictionary(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = HorosVendoredDicomDictionaryPath();
        if (path)
            HorosLoadVendoredDicomDictionary(path);
    });
}

@implementation IsiXDCMTKDictionary

+ (NSString *)keywordForTag:(uint32_t)tag error:(NSError **)error
{
    NSString *keyword = nil;
    BOOL read = IsiXDCMTKGuard(error, "DcmTag::getTagName", [&]() -> NSError * {
        DcmTag dicomTag((Uint16)(tag >> 16), (Uint16)(tag & 0xffff));
        const char *name = dicomTag.getTagName();
        keyword = name ? [NSString stringWithUTF8String:name] : nil;
        return keyword ? nil : IsiXDCMTKFailure(@"DCMTK gave no keyword for the tag");
    });
    return read ? keyword : nil;
}

+ (BOOL)enumeratePublicAttributesUsingBlock:(NS_NOESCAPE void (^)(uint32_t, NSString *))block error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmDataDictionary::normalBegin", [&]() -> NSError * {
        if (!dcmDataDict.isDictionaryLoaded())
            return IsiXDCMTKFailure(@"The DICOM data dictionary is not loaded");

        // The entries are copied into a list that orders them by tag and owns
        // the copies, then given out with the dictionary still locked.
        DcmDictEntryList list;
        IsiXDCMTKDictionaryWriteLock lock;
        DcmHashDictIterator iterator(lock.dictionary.normalBegin());
        for (int index = 0; index < lock.dictionary.numberOfNormalTagEntries(); ++iterator, index++) {
            if ((*iterator)->getPrivateCreator() == NULL)
                list.insertAndReplace(new DcmDictEntry(*(*iterator)));
        }
        for (DcmDictEntryListIterator entry(list.begin()), last(list.end()); entry != last; ++entry) {
            if ((*entry)->getGroup() > 0)
                block(((uint32_t)(*entry)->getGroup() << 16) | (*entry)->getElement(),
                      [NSString stringWithFormat:@"%s", (*entry)->getTagName()]);
        }
        return nil;
    });
}

+ (BOOL)getStandardTag:(uint32_t *)tag forKeyword:(NSString *)keyword
{
    if (keyword.length == 0 || tag == NULL)
        return NO;
    HorosEnsureVendoredDicomDictionary();
    BOOL found = NO;
    IsiXDCMTKGuard(NULL, "HorosFindStandardDicomEntry", [&]() -> NSError * {
        IsiXDCMTKDictionaryWriteLock lock;
        const DcmDictEntry *entry = HorosFindStandardDicomEntry(lock.dictionary, keyword.UTF8String);
        if (entry == NULL || (entry->getGroup() % 2) != 0)
            return nil;
        *tag = ((uint32_t)entry->getGroup() << 16) | entry->getElement();
        found = YES;
        return nil;
    });
    return found;
}

+ (NSString *)valueRepresentationForTag:(uint32_t)tag
{
    NSString *name = @"UN";
    IsiXDCMTKGuard(NULL, "DcmTag::getEVR", [&]() -> NSError * {
        DcmTag dicomTag((Uint16)(tag >> 16), (Uint16)(tag & 0xffff));
        const char *vr = DcmVR(dicomTag.getEVR()).getVRName();
        if (vr && *vr) name = [NSString stringWithUTF8String:vr];
        return nil;
    });
    return name;
}

@end

// ---- The DCM Framework's tag dictionaries, from DCMTK ---------------------
//
// IsiXDICOMAttributeTag names and types every element through two dictionaries that
// used to be read from tagDictionary.plist and nameDictionary.plist: tag
// ("GGGG,EEEE") to {Description, VR, VM}, and name to tag. They are built here
// from the DCMTK dictionary the process loads. The names stay the ones the DCM
// Framework used, because they are keys elsewhere - smart-album predicates
// store them as key paths, anonymization templates and code-string tables are
// keyed by them - so where DCMTK spells a keyword differently the former
// spelling is taken from HorosDICOMLegacyNames.hpp, which lists only those. The
// DCMTK keyword is accepted as a name as well.

#include "HorosDICOMLegacyNames.hpp"

// The DCM Framework spelled DCMTK's internal VRs the way its parser reads them.
static NSString *HorosDCMVRName(DcmEVR evr)
{
    switch (evr)
    {
        case EVR_xs: return @"US/SS";
        case EVR_ox: return @"OB/OW";
        case EVR_lt: return @"US/SS/OW";
        case EVR_up: return @"UL";
        case EVR_px: return @"ox";
        default: return [NSString stringWithUTF8String: DcmVR(evr).getVRName()];
    }
}

static NSString *HorosVMString(const DcmDictEntry *entry)
{
    const int low = entry->getVMMin(), high = entry->getVMMax();
    if (high == DcmVariableVM)
        return [NSString stringWithFormat: @"%d-n", low];
    if (low == high)
        return [NSString stringWithFormat: @"%d", low];
    return [NSString stringWithFormat: @"%d-%d", low, high];
}

@implementation HorosDICOMDictionaries

static NSDictionary *HorosTagDictionary, *HorosTagForNameDictionary;

+ (void)build
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        IsiXDCMTKGuard(NULL, "DcmDataDictionary::normalBegin", [&]() -> NSError * {
            [self buildFromDCMTK];
            return nil;
        });
        // A dictionary that could not be read leaves the tags without
        // names, as a process without DCMTK's dictionary would be.
        if (HorosTagDictionary == nil) HorosTagDictionary = @{};
        if (HorosTagForNameDictionary == nil) HorosTagForNameDictionary = @{};
    });
}

+ (void)buildFromDCMTK
{
    {
        HorosEnsureVendoredDicomDictionary();
        NSMutableDictionary *tags = [NSMutableDictionary dictionaryWithCapacity: 6000];
        NSMutableDictionary *names = [NSMutableDictionary dictionaryWithCapacity: 6000];
        void (^add)(unsigned, unsigned, const DcmDictEntry *) = ^(unsigned group, unsigned element, const DcmDictEntry *entry) {
            NSString *key = [NSString stringWithFormat: @"%04X,%04X", group, element];
            if (tags[key] || entry->getTagName() == NULL)
                return;
            NSString *name = [NSString stringWithUTF8String: entry->getTagName()];
            tags[key] = @{@"Description": name, @"VR": HorosDCMVRName(entry->getEVR()), @"VM": HorosVMString(entry)};
            if (names[name] == nil)
                names[name] = key;
        };
        // Its iterators are not const, so iterate under the write lock, as above.
        IsiXDCMTKDictionaryWriteLock lock;
        DcmDataDictionary &dictionary = lock.dictionary;
        for (auto i = dictionary.normalBegin(); i != dictionary.normalEnd(); ++i)
            if ((*i)->getGroup() % 2 == 0 && (*i)->getPrivateCreator() == NULL)
                add((*i)->getGroup(), (*i)->getElement(), *i);
        // Repeating groups (curves 50xx, overlays 60xx) and element ranges are
        // spelled out; a range over every group (group lengths) is not.
        for (auto i = dictionary.repeatingBegin(); i != dictionary.repeatingEnd(); ++i)
        {
            const DcmDictEntry *entry = *i;
            if (entry->getPrivateCreator() || entry->getUpperGroup() - entry->getGroup() > 0x100 ||
                entry->getUpperElement() - entry->getElement() > 0x100)
                continue;
            const unsigned groupStep = entry->getGroupRangeRestriction() == DcmDictRange_Unspecified ? 1 : 2;
            const unsigned elementStep = entry->getElementRangeRestriction() == DcmDictRange_Unspecified ? 1 : 2;
            for (unsigned group = entry->getGroup(); group <= entry->getUpperGroup(); group += groupStep)
                for (unsigned element = entry->getElement(); element <= entry->getUpperElement(); element += elementStep)
                    if (group % 2 == 0)
                        add(group, element, entry);
        }

        for (const HorosLegacyDICOMName &legacy : HorosLegacyDICOMNames)
        {
            NSString *key = [NSString stringWithUTF8String: legacy.tag];
            NSString *name = [NSString stringWithUTF8String: legacy.name];
            if (legacy.kind == 'T')
            {
                NSDictionary *entry = tags[key];
                tags[key] = entry ? @{@"Description": name, @"VR": entry[@"VR"], @"VM": entry[@"VM"]}
                                  : @{@"Description": name, @"VR": [NSString stringWithUTF8String: legacy.vr],
                                      @"VM": [NSString stringWithUTF8String: legacy.vm]};
            }
            names[name] = key;
        }
        HorosTagDictionary = [tags copy];
        HorosTagForNameDictionary = [names copy];
    }
}

+ (NSDictionary *)tagDictionary
{
    [self build];
    return HorosTagDictionary;
}

+ (NSDictionary *)tagForNameDictionary
{
    [self build];
    return HorosTagForNameDictionary;
}

@end
