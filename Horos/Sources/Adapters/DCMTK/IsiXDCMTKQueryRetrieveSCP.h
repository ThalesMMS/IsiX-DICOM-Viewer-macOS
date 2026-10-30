//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The DICOM listener's side of the DCMTK adapter: the network, its TLS layer,
// the loop that takes connections, one thread per association, the DIMSE
// answers to C-ECHO, C-FIND, C-MOVE, C-GET and C-STORE, and the database
// handle DCMTK's Q/R classes read. What the database holds, which requests
// are answered and what the user is told are the application's: it answers
// through the two protocols below, on the associations' threads.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKDataset.h"
#import "IsiXDCMTKMoveDestination.h"

NS_ASSUME_NONNULL_BEGIN

/// How a C-FIND, C-MOVE or C-GET starts in the database.
typedef NS_ENUM(NSInteger, IsiXDCMTKSCPRequestStart) {
    /// Nothing matches: the request ends with Success.
    IsiXDCMTKSCPRequestStartNoMatch = 0,
    /// Matches follow: Pending responses, or sub-operations.
    IsiXDCMTKSCPRequestStartMatches,
    /// The request's model is not the Study Root one.
    IsiXDCMTKSCPRequestStartSOPClassNotSupported,
    /// The identifier has no Query/Retrieve Level.
    IsiXDCMTKSCPRequestStartMissingLevel,
    /// The Query/Retrieve Level is not one the database knows.
    IsiXDCMTKSCPRequestStartUnknownLevel,
    /// The database could not be read.
    IsiXDCMTKSCPRequestStartFailed,
};

/// The database of the listener and of the C-STOREs a C-GET receives: one
/// object per association, used on that association's thread only. The
/// identifiers it is given are copies it may keep.
@protocol IsiXDCMTKSCPDatabase <NSObject>

/// A C-FIND in the model `sopClass`.
- (IsiXDCMTKSCPRequestStart)startFindWithSOPClass:(NSString *)sopClass identifier:(IsiXDCMTKDataset *)identifier;
/// Fills `response` with the next match; NO when there is none left.
- (BOOL)nextFindResponse:(IsiXDCMTKDataset *)response;

/// A C-MOVE (to the AE title `moveDestination`) or a C-GET (`moveDestination`
/// nil) in the model `sopClass`. When it matches, `retrieveCount` gives the
/// number of files to send.
- (IsiXDCMTKSCPRequestStart)startRetrieveWithSOPClass:(NSString *)sopClass identifier:(IsiXDCMTKDataset *)identifier
                                     moveDestination:(nullable NSData *)moveDestination;
@property (readonly) NSInteger retrieveCount;
/// The file to send next; nil when there is none, or the thread was cancelled.
- (nullable NSString *)nextRetrievePath;
/// The retrieve stops; nothing more is sent.
- (void)cancelRetrieve;

/// Where an incoming file is written until it is complete.
@property (readonly, copy) NSString *receivingDirectory;
/// Hands a complete received file to the database; nil, or the message of
/// why it could not be.
- (nullable NSString *)publishReceivedFileAtPath:(NSString *)path;
/// Whether received files name their sender in Source Application Entity
/// Title, and the called title in Private Information Creator UID.
@property (readonly) BOOL namesSenderInReceivedFiles;
@property (readonly) BOOL namesCalledTitleInReceivedFiles;
/// An instance was stored and published. `attributes` holds the values (as
/// DCMTK holds them) of its Specific Character Set, Patient's Name, Study
/// Description, Series Description and Series Instance UID that it has; nil
/// when the file was written as received, without a dataset to read.
- (void)didStoreInstanceWithAttributes:(nullable NSDictionary<NSNumber *, NSData *> *)attributes;
/// A C-STORE ended, stored or not, with `status`.
- (void)didEndStoreOfInstance:(NSString *)sopInstanceUID study:(NSString *)studyInstanceUID
                       series:(NSString *)seriesInstanceUID status:(uint16_t)status;

/// The association ended without the release its peer should have asked for.
- (void)associationEndedIncomplete;
/// The association is over: nothing more is asked.
- (void)close;
@end

/// The DIMSE commands the listener receives.
typedef NS_ENUM(NSInteger, IsiXDCMTKListenerCommand) {
    IsiXDCMTKListenerCommandEcho = 0,
    IsiXDCMTKListenerCommandStore,
    IsiXDCMTKListenerCommandFind,
    IsiXDCMTKListenerCommandMove,
    IsiXDCMTKListenerCommandGet,
};

/// What the listener asks the application, on the threads of its connections
/// and associations.
@protocol IsiXDCMTKListenerHost <NSObject>
/// The database of an association called by `callingAETitle`.
- (id<IsiXDCMTKSCPDatabase>)databaseForCallingAETitle:(NSString *)callingAETitle;
/// Where the sub-operations of a C-MOVE to `aeTitle` go.
- (nullable IsiXDCMTKMoveDestination *)moveDestinationForAETitle:(NSString *)aeTitle;
/// Whether `command` is answered; one that is not ends the association.
- (BOOL)answersCommand:(IsiXDCMTKListenerCommand)command;
/// The associations served at once; past it one is rejected.
@property (readonly) NSUInteger maximumConcurrentAssociations;
/// Whether `calledAETitle` names this listener; another is accepted and logged.
- (BOOL)isListenerAETitle:(NSData *)calledAETitle;
/// The final status of a C-GET whose provider proposed `proposed`.
- (uint16_t)finalStatusOfGet:(uint16_t)proposed completed:(NSUInteger)completed failed:(NSUInteger)failed
                    warnings:(NSUInteger)warnings;
/// An association ended on the DCMTK condition `error` (described by
/// `message`), not cancelled by the listener.
- (void)associationEndedWithError:(NSError *)error message:(NSString *)message;
/// Starts `thread`, which serves the association from `peer`, among the
/// application's threads.
- (void)startAssociationThread:(NSThread *)thread peer:(NSString *)peer;
/// The current association thread now serves `command` from `peer`.
- (void)association:(NSString *)peer willServe:(IsiXDCMTKListenerCommand)command secure:(BOOL)secure;
/// An association ended: what it received may be imported.
- (void)associationDidEnd;
@end

/// What the listener is opened with.
@interface IsiXDCMTKListenerSettings : NSObject
@property int port;
/// The listener's AE title, already checked and trimmed.
@property (copy) NSString *aeTitle;
/// The E_TransferSyntax incoming C-STOREs prefer.
@property NSInteger preferredTransferSyntax;
/// The ACSE and DIMSE timeout, in seconds.
@property int timeout;
/// The time a peer has to connect (DCMTK's process-wide connection timeout).
@property int connectionTimeout;
@property int maxAssociations;

@property BOOL secureConnection;
@property (nullable, copy) NSString *seedFile;
@end

/// A DICOM listener on one port. Opened in steps that each give the DCMTK
/// failure as an error naming the call (IsiXDCMTKOperationKey), then served
/// until stopped, then closed. Every call happens on the listener's thread.
@interface IsiXDCMTKListener : NSObject

/// Whether DCMTK's data dictionary is loaded.
@property (class, readonly) BOOL dataDictionaryLoaded;

/// Sets DCMTK's process-wide connection timeout and VR generation; nil when
/// DCMTK throws.
- (nullable instancetype)initWithSettings:(IsiXDCMTKListenerSettings *)settings
                                     host:(id<IsiXDCMTKListenerHost>)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Opens the port, for IPv6 and IPv4. The error's userInfo holds the errno
/// of the failure under NSUnderlyingErrorKey's code (an NSPOSIXErrorDomain error).
- (BOOL)openNetwork:(NSError **)error;

/// The TLS layer, in this order: made, its trusted certificates added, its
/// identity loaded, its cipher suites and the peer verification set, then
/// attached to the network. `file` in the error's userInfo
/// (IsiXDCMTKListenerFileKey) names a file that does not load.
- (BOOL)createTLSLayer:(NSError **)error;
- (BOOL)addTrustedCertificateFiles:(NSArray<NSString *> *)files error:(NSError **)error;
- (BOOL)setPrivateKeyFile:(NSString *)privateKeyFile certificateFile:(NSString *)certificateFile
                 password:(nullable NSString *)password error:(NSError **)error;
/// `verification`: 0 require, 1 verify, 2 ignore the peer's certificate; any other value requires it.
- (BOOL)setCipherSuites:(NSArray<NSString *> *)cipherSuites verification:(int)verification error:(NSError **)error;
- (BOOL)attachTLSLayer:(NSError **)error;

/// Reads DCMTK's Q/R configuration and the association profile of incoming
/// C-STOREs. The error describes what failed, for the user.
- (BOOL)configure:(NSError **)error;

/// Takes connections until `stop` answers YES; each association runs on a
/// thread of its own, which -close cancels and waits for.
- (void)serveUntil:(NS_NOESCAPE BOOL (^)(void))stop;

/// Ends the associations (cancels their threads and waits for them), closes
/// the port and destroys the TLS layer. Gives the condition dropping the
/// network failed on.
- (nullable NSError *)close NS_SWIFT_NAME(close());

@end

/// NSString: the file a TLS step could not load.
FOUNDATION_EXPORT NSString * const IsiXDCMTKListenerFileKey;

NS_ASSUME_NONNULL_END
