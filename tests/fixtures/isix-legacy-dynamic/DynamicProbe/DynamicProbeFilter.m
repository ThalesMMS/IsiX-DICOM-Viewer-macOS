//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A legacy plugin that reaches the application by name, the way Horos plugins
// did: classes by NSClassFromString() and objc_getClass(), messages by
// performSelector: and objc_msgSend(), values by key-value coding. It writes
// what it got to the property list named by ISIX_LEGACY_DYNAMIC_OUTPUT. The
// test compiles it with manual reference counting and with ARC, and runs it
// in a host that has classes named as the application's.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "PluginFilter.h"

// The selectors without an equivalent are named at run time, as a legacy
// plugin named the application's; ARC cannot know what they return.
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

@interface DynamicProbeFilter : PluginFilter
@end

static NSString *DynamicProbeName(Class cls)
{
    return cls ? NSStringFromClass(cls) : @"nil";
}

@implementation DynamicProbeFilter

- (long) filterImage: (NSString*) menuName
{
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    report[@"arc"] = @(__has_feature(objc_arc) ? YES : NO);
    @try {
        // Classes by name.
        NSMutableDictionary *classes = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"PluginFilter", @"ViewerController", @"DCMView", @"DCMPix", @"ROI", @"MyPoint",
                                 @"BrowserController", @"DicomStudy", @"AppController", @"ThumbnailsListPanel",
                                 @"NSString", @"DynamicProbeFilter", @"NoSuchLegacyClass"])
            classes[name] = DynamicProbeName(NSClassFromString(name));
        NSString *none = nil;
        classes[@"(nil)"] = DynamicProbeName(NSClassFromString(none));
        report[@"classes"] = classes;
        report[@"sameAsKit"] = @[@(NSClassFromString(@"ViewerController") == [ViewerController class]),
                                 @(NSClassFromString(@"DCMPix") == [DCMPix class]),
                                 @(NSClassFromString(@"ROI") == [ROI class]),
                                 @(NSClassFromString(@"DynamicProbeFilter") == [self class])];
        report[@"objcGetClass"] = DynamicProbeName(objc_getClass("ViewerController"));
        report[@"objcLookUpClass"] = DynamicProbeName(objc_lookUpClass("AppController"));
        // The real lookup, written so that it is not diverted, finds the host's class.
        Class application = (NSClassFromString)(@"ViewerController");
        report[@"undiverted"] = DynamicProbeName(application);
        report[@"undivertedImage"] = application && class_getImageName(application)
            ? @(class_getImageName(application)) : @"";

        // Messages by name to the kit's objects. The selectors and keys without an
        // equivalent are made up, so that the kit can never come to have them.
        id viewer = viewerController;
        Class viewerClass = NSClassFromString(@"ViewerController");
        report[@"performPixList"] = @([[viewer performSelector: @selector(pixList)] count]);
        report[@"performFront"] = @([viewerClass performSelector: @selector(frontMostDisplayed2DViewer)] == viewer);
        report[@"performUnknown"] = @([viewer performSelector: NSSelectorFromString(@"probeSelectorWithoutEquivalent")] == nil);
        report[@"performUnknownWithObject"] =
            @([viewer performSelector: NSSelectorFromString(@"probeSelectorWithoutEquivalent:") withObject: self] == nil);
        report[@"performUnknownClass"] =
            @([viewerClass performSelector: NSSelectorFromString(@"legacyClassMethodWithoutEquivalent")] == nil);
        report[@"respondsToUnknown"] = @([viewer respondsToSelector: NSSelectorFromString(@"probeSelectorWithoutEquivalent")]);
        id pixList = ((id (*)(id, SEL))objc_msgSend)(viewer, @selector(pixList));
        report[@"msgSendPixList"] = @([pixList count]);
        report[@"msgSendUnknown"] =
            @(((id (*)(id, SEL, id))objc_msgSend)(viewer, NSSelectorFromString(@"probeMessageWithoutEquivalent:"), @0) == nil);

        // Key-value coding on the kit's objects.
        long current = [[viewerController imageView] curImage];
        DCMPix *pix = [[viewerController pixList] objectAtIndex: current];
        ROI *roi = [[[viewerController roiList] objectAtIndex: current] firstObject];
        report[@"kvc"] = @{
            @"pwidth": [pix valueForKey: @"pwidth"],
            @"pheight": [pix valueForKey: @"pheight"],
            @"pixelSpacingX": [pix valueForKey: @"pixelSpacingX"],
            @"pixelSpacingY": [pix valueForKey: @"pixelSpacingY"],
            @"pixListCount": [viewerController valueForKeyPath: @"pixList.@count"],
            @"curImage": [viewerController valueForKeyPath: @"imageView.curImage"],
            @"roiNames": [[[viewerController roiList] objectAtIndex: current] valueForKey: @"name"],
            @"roiType": [roi valueForKey: @"type"],
            @"viewerControllerIvar": @([self valueForKey: @"viewerController"] == viewerController),
            // Through the kit's database objects.
            @"studyUID": [viewerController valueForKeyPath: @"currentStudy.studyInstanceUID"] ?: @"",
        };
        report[@"sameStudy"] = @([viewerController valueForKey: @"currentStudy"] == [viewerController currentStudy]
                                 && [viewerController currentStudy] != nil);
        report[@"kvcUnknown"] = @([viewerController valueForKey: @"probeKeyWithoutEquivalent"] == nil
                                  && [viewerController valueForKeyPath: @"probeKeyWithoutEquivalent.date"] == nil);
        [roi setValue: @"renamed by key" forKey: @"name"];
        [viewerController setValue: @1 forKey: @"probeSetKeyWithoutEquivalent"];
        report[@"renamed"] = roi.name ?: @"";
    } @catch (NSException *exception) {
        report[@"exception"] = [NSString stringWithFormat: @"%@: %@", exception.name, exception.reason];
    }
    NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey: @"ISIX_LEGACY_DYNAMIC_OUTPUT"];
    if (path) [report writeToFile: [path stringByAppendingFormat: @"-%@.plist", report[@"arc"]] atomically: YES];
    return 0;
}

@end
