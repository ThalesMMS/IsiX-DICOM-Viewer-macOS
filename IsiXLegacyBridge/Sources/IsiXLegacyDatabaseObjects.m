//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting.
//
// The database's objects keep a record of the plugin API under the legacy
// attribute names. The same study, series, image or album is the same object
// for as long as the plugin holds it: reading it again refreshes its record.
// Relationships (a study's series, a series' images...) are read from the
// application each time they are asked for.

#import "IsiXLegacyBridgeInternal.h"

#define ISIX_GET(type, name) - (type) name { return [self isixValueForKey: @#name]; }
#define ISIX_SET(name, Name) - (void) set##Name: (id) value { [self setValue: value forKey: @#name]; }

static IsiXLegacyDatabaseBridge *Bridge(void) { return [IsiXLegacyDatabaseBridge shared]; }

@implementation IsiXLegacyDatabaseObject
{
    @protected
    NSDictionary *record;
    IsiXLegacyEntity entity;
}

/// The objects handed out, by kind and identity; released when the plugin lets them go.
static NSMapTable<NSString*, IsiXLegacyDatabaseObject*> *Identities(void)
{
    static NSMapTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSMapTable strongToWeakObjectsMapTable]; });
    return table;
}

+ (NSString*) isixIdentityOfRecord: (NSDictionary*) record entity: (IsiXLegacyEntity) entity
{
    switch (entity)
    {
        case IsiXLegacyEntityStudy: return [@"Study:" stringByAppendingString: record[@"studyInstanceUID"] ?: @""];
        case IsiXLegacyEntitySeries: return [@"Series:" stringByAppendingString: record[@"seriesDICOMUID"] ?: @""];
        case IsiXLegacyEntityImage: return [NSString stringWithFormat: @"Image:%@:%@", record[@"sopInstanceUID"] ?: @"", record[@"frameID"] ?: @0];
        case IsiXLegacyEntityAlbum: return [@"Album:" stringByAppendingString: record[@"name"] ?: @""];
    }
    return @"";
}

+ (id) isixObjectWithRecord: (NSDictionary*) record entity: (IsiXLegacyEntity) entity
{
    if (!record) return nil;
    NSString *identity = [self isixIdentityOfRecord: record entity: entity];
    @synchronized (Identities())
    {
        IsiXLegacyDatabaseObject *known = [Identities() objectForKey: identity];
        if (known)
        {
            known->record = record;
            return known;
        }
        Class class = entity == IsiXLegacyEntityStudy ? [IsiXLegacyDicomStudy class]
                    : entity == IsiXLegacyEntitySeries ? [IsiXLegacyDicomSeries class]
                    : entity == IsiXLegacyEntityImage ? [IsiXLegacyDicomImage class] : [IsiXLegacyDicomAlbum class];
        IsiXLegacyDatabaseObject *object = [[class alloc] init];
        object->record = record;
        object->entity = entity;
        [Identities() setObject: object forKey: identity];
        return object;
    }
}

+ (NSArray*) isixObjectsWithRecords: (NSArray<NSDictionary*>*) records entity: (IsiXLegacyEntity) entity
{
    NSMutableArray *objects = [NSMutableArray arrayWithCapacity: records.count];
    for (NSDictionary *one in records) [objects addObject: [self isixObjectWithRecord: one entity: entity]];
    return objects;
}

- (NSDictionary*) isixRecord { return record; }
- (IsiXLegacyEntity) isixEntity { return entity; }

- (void) isixAdoptRecord: (NSDictionary*) newRecord
{
    if (newRecord) record = newRecord;
}

- (NSString*) type { return record[@"type"]; }

- (NSEntityDescription*) entity
{
    return [IsiXLegacyDicomDatabase defaultDatabase].managedObjectModel.entitiesByName[self.type];
}

- (id) objectID { return self; }
- (NSManagedObjectContext*) managedObjectContext { return [IsiXLegacyDicomDatabase defaultDatabase].managedObjectContext; }
- (BOOL) isFault { return NO; }
- (BOOL) isDeleted { return NO; }
- (BOOL) isInserted { return NO; }
- (BOOL) hasChanges { return NO; }
- (void) willAccessValueForKey: (NSString*) key {}
- (void) didAccessValueForKey: (NSString*) key {}
- (id) primitiveValueForKey: (NSString*) key { return record[key]; }

- (id) isixValueForKey: (NSString*) key
{
    id value = record[key];
    return value == [NSNull null] ? nil : value;
}

- (NSString*) description
{
    return [NSString stringWithFormat: @"<%@ %@>", self.type, [IsiXLegacyDatabaseObject isixIdentityOfRecord: record entity: entity]];
}

- (BOOL) isEqual: (id) other
{
    if (other == self) return YES;
    if (![other isKindOfClass: [IsiXLegacyDatabaseObject class]]) return NO;
    IsiXLegacyDatabaseObject *object = other;
    return object->entity == entity && [[IsiXLegacyDatabaseObject isixIdentityOfRecord: object->record entity: entity]
                                        isEqualToString: [IsiXLegacyDatabaseObject isixIdentityOfRecord: record entity: entity]];
}

- (NSUInteger) hash { return [IsiXLegacyDatabaseObject isixIdentityOfRecord: record entity: entity].hash; }

#pragma mark Key-value coding

+ (BOOL) accessInstanceVariablesDirectly { return NO; }

/// Relationships and computed values have accessors; attributes are in the record.
- (id) valueForKey: (NSString*) key
{
    id value = record[key];
    if (value) return value == [NSNull null] ? nil : value;
    if ([self respondsToSelector: NSSelectorFromString(key)]) return [super valueForKey: key];
    // An attribute of the entity the record has no value for.
    if (self.entity.attributesByName[key]) return nil;
    return [self valueForUndefinedKey: key];
}

- (id) valueForUndefinedKey: (NSString*) key
{
    [Bridge() fail: [NSString stringWithFormat: @"A %@ of the database has no attribute %@.", self.type, key]];
    return nil;
}

- (void) setValue: (id) value forKey: (NSString*) key
{
    if (![IsiXLegacyDatabaseBridge isEditable: key of: entity])
    {
        [Bridge() refuseWithKey: key of: entity];
        return;
    }
    NSDictionary *updated = [Bridge() set: value forKey: key of: entity record: record];
    if (updated) record = updated;
}

- (void) setValue: (id) value forUndefinedKey: (NSString*) key { [Bridge() refuseWithKey: key of: entity]; }
- (void) setNilValueForKey: (NSString*) key { [self setValue: [NSNull null] forKey: key]; }

@end

#pragma mark - DicomStudy

@implementation IsiXLegacyDicomStudy

ISIX_GET(NSString*, accessionNumber)
ISIX_GET(NSString*, comment)
ISIX_GET(NSString*, comment2)
ISIX_GET(NSString*, comment3)
ISIX_GET(NSString*, comment4)
ISIX_GET(NSDate*, date)
ISIX_GET(NSDate*, dateAdded)
ISIX_GET(NSDate*, dateOfBirth)
ISIX_GET(NSNumber*, hasDICOM)
ISIX_GET(NSString*, id)
ISIX_GET(NSString*, institutionName)
ISIX_GET(NSNumber*, lockedStudy)
ISIX_GET(NSString*, modality)
ISIX_GET(NSString*, name)
ISIX_GET(NSNumber*, numberOfImages)
ISIX_GET(NSString*, patientID)
ISIX_GET(NSString*, patientSex)
ISIX_GET(NSString*, patientUID)
ISIX_GET(NSString*, performingPhysician)
ISIX_GET(NSString*, referringPhysician)
ISIX_GET(NSString*, reportURL)
ISIX_GET(NSNumber*, stateText)
ISIX_GET(NSString*, studyInstanceUID)
ISIX_GET(NSString*, studyName)
ISIX_SET(comment, Comment)
ISIX_SET(comment2, Comment2)
ISIX_SET(comment3, Comment3)
ISIX_SET(comment4, Comment4)
ISIX_SET(lockedStudy, LockedStudy)
ISIX_SET(reportURL, ReportURL)
ISIX_SET(stateText, StateText)

- (NSSet*) series
{
    return [NSSet setWithArray: [IsiXLegacyDatabaseObject isixObjectsWithRecords: [Bridge() seriesInStudy: self.studyInstanceUID]
                                                                           entity: IsiXLegacyEntitySeries]];
}

- (NSSet*) albums
{
    NSMutableSet *albums = [NSMutableSet set];
    for (IsiXLegacyDicomAlbum *album in [[IsiXLegacyDicomDatabase defaultDatabase] albums])
        if ([album.studies containsObject: self]) [albums addObject: album];
    return albums;
}

+ (BOOL) displaySeriesWithSOPClassUID: (NSString*) uid andSeriesDescription: (NSString*) description
{
    // The application's own series: annotations, ROIs, reports and windows
    // states as structured reports, and the series it keeps aside.
    for (NSString *own in @[@"OsiriX ROI SR", @"OsiriX Annotations SR", @"OsiriX Report SR", @"OsiriX WindowsState SR"])
        if ([description hasPrefix: own]) return NO;
    return ![description isEqualToString: @"OsiriX No Autodeletion"];
}

- (NSSet*) images
{
    NSMutableSet *images = [NSMutableSet set];
    for (IsiXLegacyDicomSeries *series in self.series) [images unionSet: series.images];
    return images;
}

- (NSSet*) keyImages
{
    return [self.images filteredSetUsingPredicate: [NSPredicate predicateWithFormat: @"isKeyImage == YES"]];
}

- (NSSet*) paths { return [self.images valueForKey: @"completePath"]; }
- (NSNumber*) noFiles { return self.numberOfImages; }
- (NSString*) modalities { return self.modality; }

- (NSArray*) imageSeries
{
    NSMutableArray *series = [NSMutableArray array];
    for (IsiXLegacyDicomSeries *one in self.series)
        if ([IsiXLegacyDicomStudy displaySeriesWithSOPClassUID: one.seriesSOPClassUID andSeriesDescription: one.name]) [series addObject: one];
    return [series sortedArrayUsingDescriptors: @[[NSSortDescriptor sortDescriptorWithKey: @"id" ascending: YES]]];
}

- (NSComparisonResult) compareName: (IsiXLegacyDicomStudy*) study
{
    return [self.name ?: @"" caseInsensitiveCompare: study.name ?: @""];
}

@end

#pragma mark - DicomSeries

@implementation IsiXLegacyDicomSeries

ISIX_GET(NSString*, comment)
ISIX_GET(NSString*, comment2)
ISIX_GET(NSString*, comment3)
ISIX_GET(NSString*, comment4)
ISIX_GET(NSDate*, date)
ISIX_GET(NSNumber*, id)
ISIX_GET(NSString*, modality)
ISIX_GET(NSString*, name)
ISIX_GET(NSNumber*, numberOfImages)
ISIX_GET(NSString*, seriesDescription)
ISIX_GET(NSString*, seriesDICOMUID)
ISIX_GET(NSString*, seriesInstanceUID)
ISIX_GET(NSString*, seriesSOPClassUID)
ISIX_GET(NSNumber*, stateText)
ISIX_SET(comment, Comment)
ISIX_SET(comment2, Comment2)
ISIX_SET(comment3, Comment3)
ISIX_SET(comment4, Comment4)
ISIX_SET(stateText, StateText)

- (NSSet*) images { return [NSSet setWithArray: self.sortedImages]; }

- (NSArray*) sortedImages
{
    return [IsiXLegacyDatabaseObject isixObjectsWithRecords: [Bridge() imagesInSeries: self.seriesDICOMUID] entity: IsiXLegacyEntityImage];
}

- (IsiXLegacyDicomStudy*) study
{
    return [IsiXLegacyDatabaseObject isixObjectWithRecord: [Bridge() studyWithInstanceUID: record[@"isixStudyInstanceUID"]]
                                                   entity: IsiXLegacyEntityStudy];
}

- (NSSet*) paths { return [self.images valueForKey: @"completePath"]; }

- (NSSet*) keyImages
{
    return [self.images filteredSetUsingPredicate: [NSPredicate predicateWithFormat: @"isKeyImage == YES"]];
}

- (NSArray*) sortDescriptorsForImages
{
    return @[[NSSortDescriptor sortDescriptorWithKey: @"instanceNumber" ascending: YES],
             [NSSortDescriptor sortDescriptorWithKey: @"frameID" ascending: YES]];
}

- (NSNumber*) noFilesExcludingMultiFrames { return @([[self.sortedImages valueForKey: @"completePath"] count] ? [[NSSet setWithArray: [self.sortedImages valueForKey: @"completePath"]] count] : 0); }
- (NSNumber*) rawNoFiles { return @(self.sortedImages.count); }

- (NSComparisonResult) compareName: (IsiXLegacyDicomSeries*) series
{
    return [self.name ?: @"" caseInsensitiveCompare: series.name ?: @""];
}

@end

#pragma mark - DicomImage

@implementation IsiXLegacyDicomImage

ISIX_GET(NSNumber*, numberOfFrames)
ISIX_GET(NSString*, comment)
ISIX_GET(NSString*, comment2)
ISIX_GET(NSString*, comment3)
ISIX_GET(NSString*, comment4)
ISIX_GET(NSDate*, date)
ISIX_GET(NSNumber*, frameID)
ISIX_GET(NSNumber*, instanceNumber)
ISIX_GET(NSNumber*, sliceLocation)
ISIX_GET(NSNumber*, storedIsKeyImage)
ISIX_GET(NSString*, modality)
ISIX_GET(NSString*, sopInstanceUID)
ISIX_GET(NSString*, path)
ISIX_GET(NSString*, extension)
ISIX_GET(NSNumber*, height)
ISIX_GET(NSNumber*, width)
ISIX_GET(NSNumber*, isKeyImage)
ISIX_SET(comment, Comment)
ISIX_SET(comment2, Comment2)
ISIX_SET(comment3, Comment3)
ISIX_SET(comment4, Comment4)
ISIX_SET(storedIsKeyImage, StoredIsKeyImage)
ISIX_SET(isKeyImage, IsKeyImage)

- (NSString*) completePath
{
    NSString *path = record[@"completePath"];
    if (path) [IsiXLegacyDICOMExport isixRememberFile: path image: self];
    return path;
}

- (NSString*) completePathResolved { return [self.completePath stringByResolvingSymlinksInPath]; }

- (NSSet*) paths { return self.completePath ? [NSSet setWithObject: self.completePath] : [NSSet set]; }

- (IsiXLegacyDicomSeries*) series
{
    return [IsiXLegacyDatabaseObject isixObjectWithRecord: [Bridge() seriesWithInstanceUID: record[@"isixSeriesInstanceUID"]]
                                                   entity: IsiXLegacyEntitySeries];
}

- (NSString*) isixStudyInstanceUID { return record[@"isixStudyInstanceUID"]; }

+ (NSMutableArray*) dicomImagesInObjects: (NSArray*) objects
{
    NSMutableArray *images = [NSMutableArray array];
    for (id object in objects)
    {
        if ([object isKindOfClass: [IsiXLegacyDicomImage class]]) [images addObject: object];
        else if ([object isKindOfClass: [IsiXLegacyDicomSeries class]]) [images addObjectsFromArray: [object sortedImages]];
        else if ([object isKindOfClass: [IsiXLegacyDicomStudy class]])
            for (IsiXLegacyDicomSeries *series in [object imageSeries]) [images addObjectsFromArray: series.sortedImages];
    }
    return images;
}

+ (IsiXLegacyDicomImage*) isixImageWithSOPInstanceUID: (NSString*) uid frame: (long) frame
{
    if (!uid || ![Bridge() isAvailable]) return nil;
    return [IsiXLegacyDatabaseObject isixObjectWithRecord: [Bridge() imageWithSOPInstanceUID: uid frame: frame] entity: IsiXLegacyEntityImage];
}

@end

#pragma mark - DicomAlbum

@implementation IsiXLegacyDicomAlbum

ISIX_GET(NSString*, name)
ISIX_GET(NSNumber*, smartAlbum)

- (NSSet*) studies
{
    return [NSSet setWithArray: [IsiXLegacyDatabaseObject isixObjectsWithRecords: [Bridge() studiesInAlbum: self.name]
                                                                           entity: IsiXLegacyEntityStudy]];
}

- (void) isixChangeStudies: (id<NSFastEnumeration>) studies add: (BOOL) add
{
    NSMutableArray *uids = [NSMutableArray array];
    for (IsiXLegacyDicomStudy *study in studies)
        if ([study isKindOfClass: [IsiXLegacyDicomStudy class]] && study.studyInstanceUID) [uids addObject: study.studyInstanceUID];
    if (uids.count) (void) [Bridge() addStudies: uids toAlbum: self.name add: add];
}

- (void) addStudiesObject: (IsiXLegacyDicomStudy*) study { if (study) [self isixChangeStudies: @[study] add: YES]; }
- (void) removeStudiesObject: (IsiXLegacyDicomStudy*) study { if (study) [self isixChangeStudies: @[study] add: NO]; }
- (void) addStudies: (NSSet*) studies { [self isixChangeStudies: studies add: YES]; }
- (void) removeStudies: (NSSet*) studies { [self isixChangeStudies: studies add: NO]; }

@end
