#include "HorosDictionaryLookup.h"
#import "DICOMDataDictionary.h"

#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcdicent.h>

#if __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#define HOROS_KEYWORD_SPELLINGS 1
#endif

static NSString *HorosOtherDicomKeywordSpelling(NSString *keyword)
{
#ifdef HOROS_KEYWORD_SPELLINGS
    return [HorosDICOMKeyword otherSpellingFor: keyword];
#else
    static NSArray *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[@"Patient", @"Physician"];
    });
    for (NSString *word in words)
    {
        NSString *possessive = [word stringByAppendingString: @"s"];
        NSRange range = [keyword rangeOfString: possessive];
        if (range.location != NSNotFound)
        {
            NSUInteger after = NSMaxRange(range);
            if (after < keyword.length)
            {
                unichar next = [keyword characterAtIndex: after];
                if ([[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember: next])
                    return [keyword stringByReplacingCharactersInRange: range withString: word];
            }
        }
    }
    for (NSString *word in words)
    {
        NSRange range = [keyword rangeOfString: word];
        if (range.location != NSNotFound)
        {
            NSUInteger after = NSMaxRange(range);
            if (after < keyword.length)
            {
                unichar next = [keyword characterAtIndex: after];
                if ([[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember: next])
                    return [keyword stringByReplacingCharactersInRange: range
                                                           withString: [word stringByAppendingString: @"s"]];
            }
        }
    }
    return nil;
#endif
}

BOOL HorosLoadVendoredDicomDictionary(NSString *path)
{
    if (path.length == 0 || ![[NSFileManager defaultManager] isReadableFileAtPath:path]) return NO;
    DcmDataDictionary& dictionary = dcmDataDict.wrlock();
    const BOOL loaded = dictionary.loadDictionary([path fileSystemRepresentation], OFTrue);
    dcmDataDict.wrunlock();
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

static BOOL HorosStandardTagFromName(DcmDataDictionary& dictionary, const char *name,
                                    unsigned *group, unsigned *element)
{
    if (name == NULL || name[0] == 0)
        return NO;
    const DcmDictEntry *entry = HorosFindStandardDicomEntry(dictionary, name);
    if (entry == NULL || (entry->getGroup() % 2) != 0)
        return NO;
    *group = entry->getGroup();
    *element = entry->getElement();
    return YES;
}

BOOL HorosResolveDicomKeyword(NSString *keyword, unsigned *group, unsigned *element)
{
    if (keyword.length == 0 || group == NULL || element == NULL)
        return NO;

    HorosEnsureVendoredDicomDictionary();

    DcmDataDictionary& dictionary = dcmDataDict.wrlock();
    BOOL found = HorosStandardTagFromName(dictionary, [keyword UTF8String], group, element);
    if (!found)
    {
        NSString *other = HorosOtherDicomKeywordSpelling(keyword);
        if (other.length)
            found = HorosStandardTagFromName(dictionary, [other UTF8String], group, element);
    }
    dcmDataDict.wrunlock();
    return found;
}

// ---- The DCM Framework's tag dictionaries, from DCMTK (#737) ---------------------
//
// DCMAttributeTag names and types every element through two dictionaries that
// used to be read from tagDictionary.plist and nameDictionary.plist: tag
// ("GGGG,EEEE") to {Description, VR, VM}, and name to tag. They are built here
// from the DCMTK dictionary the process loads. The names stay the ones the DCM
// Framework used, because they are keys elsewhere - smart-album predicates
// store them as key paths, anonymization templates and code-string tables are
// keyed by them - so where DCMTK spells a keyword differently the former
// spelling is taken from HorosDICOMLegacyNames.h, which lists only those. The
// DCMTK keyword is accepted as a name as well.

#include "HorosDICOMLegacyNames.h"

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
        DcmDataDictionary &dictionary = dcmDataDict.wrlock();
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
        dcmDataDict.wrunlock();

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
    });
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
