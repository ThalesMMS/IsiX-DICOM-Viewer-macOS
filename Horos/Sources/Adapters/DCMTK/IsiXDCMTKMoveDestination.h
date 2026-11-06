//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where the sub-operations of a C-MOVE the listener received go: the
/// destination's address, and the transfer syntaxes they offer it for every
/// storage SOP class. The application finds it (MoveDestinations.swift);
/// the move context of the DCMTK adapter (IsiXDCMTKMoveContext.hpp) asks.
@interface IsiXDCMTKMoveDestination : NSObject
- (instancetype)initWithHost:(NSString *)host port:(int)port
            transferSyntaxes:(NSArray<NSString *> *)transferSyntaxes NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (readonly, copy) NSString *host;
@property (readonly) int port;
@property (readonly, copy) NSArray<NSString *> *transferSyntaxes;
@end

/// The destination of the move destination AE title `aeTitle`; nil when no
/// node of Locations has that title.
typedef IsiXDCMTKMoveDestination * _Nullable (^IsiXDCMTKMoveDestinationLookup)(NSString *aeTitle);

NS_ASSUME_NONNULL_END
