//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The selectors of OsiriXSCPDataHandler in the plug-in SDK of Horos and OsiriX
// that take a DcmDataset or answer an OFCondition, C++ classes of DCMTK that
// the class's header and Swift cannot name. A plug-in built with DCMTK's
// headers sends them without being rebuilt.
//
// In that SDK they were the listener's side of a C-FIND and of a C-MOVE: the
// predicate of an identifier, the response for each match, and the files to
// send. The listener asks the application's own rules now, and a handler of
// this class takes part in no request. Each selector keeps the calling
// convention it had and finds nothing:
// - a DcmDataset is taken by its address, which is never read: it is an
//   object of the plug-in's own DCMTK;
// - OFCondition is returned in memory the caller gives, and has here the
//   layout it had in the DCMTK of that SDK. The condition answered is made
//   from a constant, whose text the condition does not own: the plug-in's
//   destructor frees nothing.

#import <Foundation/Foundation.h>

#include "dcmtk/config/osconfig.h"
#include "dcmtk/ofstd/ofcond.h"

#import "OsiriXSCPDataHandler.h"

// The application's notice of a selector answered only for plug-ins of that
// SDK, a Swift class: named here by the one message sent to it, so that the
// adapter does not read the application's generated header.
@interface IsiXFormerSDKFacade : NSObject
+ (void)inert:(NSString *)type selector:(NSString *)selector because:(NSString *)reason;
@end

static void IsiXFormerSDKHandlerInert(SEL selector)
{
    [IsiXFormerSDKFacade inert:@"OsiriXSCPDataHandler" selector:[@"-" stringByAppendingString:NSStringFromSelector(selector)]
                       because:@"the DICOM listener reads the database through the application's own rules"];
}

// What the SDK's handler answered when it had nothing to find or to send.
static OFCondition IsiXFormerSDKHandlerNothing(SEL selector)
{
    IsiXFormerSDKHandlerInert(selector);
    return EC_IllegalParameter;
}

@interface OsiriXSCPDataHandler (FormerSDKDatasets)
- (NSPredicate *)predicateForDataset:(void *)dataset compressedSOPInstancePredicate:(NSPredicate **)csopPredicate
                seriesLevelPredicate:(NSPredicate **)SLPredicate;
- (void)studyDatasetForFetchedObject:(id)fetchedObject dataset:(void *)dataset;
- (void)seriesDatasetForFetchedObject:(id)fetchedObject dataset:(void *)dataset;
- (void)imageDatasetForFetchedObject:(id)fetchedObject dataset:(void *)dataset;
- (OFCondition)prepareFindForDataSet:(void *)dataset;
- (OFCondition)prepareMoveForDataSet:(void *)dataset;
- (OFCondition)nextFindObject:(void *)dataset isComplete:(BOOL *)isComplete;
- (OFCondition)nextMoveObject:(char *)imageFileName;
@end

@implementation OsiriXSCPDataHandler (FormerSDKDatasets)

// No predicate, at any level.
- (NSPredicate *)predicateForDataset:(void *)dataset compressedSOPInstancePredicate:(NSPredicate **)csopPredicate
                seriesLevelPredicate:(NSPredicate **)SLPredicate
{
    IsiXFormerSDKHandlerInert(_cmd);
    if (csopPredicate) *csopPredicate = nil;
    if (SLPredicate) *SLPredicate = nil;
    return nil;
}

// The dataset is left as it was given.
- (void)studyDatasetForFetchedObject:(id)fetchedObject dataset:(void *)dataset
{
    IsiXFormerSDKHandlerInert(_cmd);
}

- (void)seriesDatasetForFetchedObject:(id)fetchedObject dataset:(void *)dataset
{
    IsiXFormerSDKHandlerInert(_cmd);
}

- (void)imageDatasetForFetchedObject:(id)fetchedObject dataset:(void *)dataset
{
    IsiXFormerSDKHandlerInert(_cmd);
}

- (OFCondition)prepareFindForDataSet:(void *)dataset
{
    return IsiXFormerSDKHandlerNothing(_cmd);
}

- (OFCondition)prepareMoveForDataSet:(void *)dataset
{
    return IsiXFormerSDKHandlerNothing(_cmd);
}

// There is no match to give: the find is complete.
- (OFCondition)nextFindObject:(void *)dataset isComplete:(BOOL *)isComplete
{
    if (isComplete) *isComplete = YES;
    return IsiXFormerSDKHandlerNothing(_cmd);
}

// There is no file to send: the name is left as it was given.
- (OFCondition)nextMoveObject:(char *)imageFileName
{
    return IsiXFormerSDKHandlerNothing(_cmd);
}

@end
