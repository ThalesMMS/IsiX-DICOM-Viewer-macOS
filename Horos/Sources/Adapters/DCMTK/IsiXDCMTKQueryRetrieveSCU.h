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
#import "IsiXDCMTKDataset.h"
#import "IsiXDCMTKQueryRetrieveSCP.h"

NS_ASSUME_NONNULL_BEGIN

/// One presentation context to propose: an odd identifier, an abstract
/// syntax and its transfer syntaxes in order of preference.
@interface IsiXDCMTKPresentationContext : NSObject
- (instancetype)initWithIdentifier:(uint8_t)identifier abstractSyntax:(NSString *)abstractSyntax
                  transferSyntaxes:(NSArray<NSString *> *)transferSyntaxes NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (readonly) uint8_t identifier;
@property (readonly, copy) NSString *abstractSyntax;
@property (readonly, copy) NSArray<NSString *> *transferSyntaxes;
@end

/// What an association of the query nodes or of a send is opened with: the
/// titles, the peer, the timeouts, the presentation contexts and, for TLS,
/// the files the caller has written (seed, trusted certificates, key and
/// certificate).
@interface IsiXDCMTKAssociationParameters : NSObject
/// nil: "FINDSCU" and "ANY-SCP".
@property (nullable, copy) NSString *callingAETitle;
@property (nullable, copy) NSString *calledAETitle;
@property (copy) NSString *peerHost;
@property int peerPort;
/// The service asked for, a UID such as the Study Root C-FIND model's; its
/// presentation contexts follow preferredTransferSyntax. Unused when
/// presentationContexts is set.
@property (copy) NSString *abstractSyntax;
/// The presentation contexts to propose as they are, in place of those of
/// abstractSyntax (a send's storage classes).
@property (nullable, copy) NSArray<IsiXDCMTKPresentationContext *> *presentationContexts;
/// The caller could not fit its presentation contexts in one association:
/// the association fails where they would be added, with DCMTK's
/// ASC_BADPRESENTATIONCONTEXTID.
@property BOOL presentationContextsRefused;
/// The E_TransferSyntax the presentation contexts prefer.
@property NSInteger preferredTransferSyntax;
@property int acseTimeout;
@property int dimseTimeout;
/// When positive, the time allowed to connect, in place of acseTimeout.
@property NSInteger connectionTimeout;
/// 0: DCMTK's default.
@property unsigned long maxReceivePDULength;
/// Dumps the requests, responses and negotiation to the standard output.
@property BOOL verbose;
/// Prints the conditions the association fails on, and a rejection's
/// reasons, to the standard error even when not verbose, as a send does.
@property BOOL reportsFailures;
/// The name those diagnostics start with; nil: "DCMTKQueryNode".
@property (nullable, copy) NSString *consoleApplication;

@property BOOL secureConnection;
@property (nullable, copy) NSString *seedFile;
@property (copy) NSArray<NSString *> *trustedCertificateFiles;
/// 0 require, 1 verify, 2 ignore the peer's certificate (TLSCertificateVerificationType).
@property int certificateVerification;
@property (nullable, copy) NSString *dhParameterFile;
/// Set to authenticate this end: the PEM files and the key's password.
@property (nullable, copy) NSString *privateKeyFile;
@property (nullable, copy) NSString *certificateFile;
@property (nullable, copy) NSString *privateKeyPassword;
/// The cipher suites chosen in Locations; empty: the DICOM TLS profile.
@property (copy) NSArray<NSString *> *cipherSuites;
@end

/// How a C-FIND ended.
@interface IsiXDCMTKFindResult : NSObject
/// The condition it ended on, nil for EC_Normal.
@property (readonly, nullable) NSError *condition;
@property (readonly) BOOL conditionGood;
@property (readonly) uint16_t status;
/// DCMTK's name for the status.
@property (readonly, copy) NSString *statusText;
/// The status detail the peer sent, as DCMTK prints it.
@property (readonly, nullable, copy) NSString *statusDetail;
@end

/// How a C-MOVE or C-GET ended: its final response, zero where none came.
@interface IsiXDCMTKRetrieveResult : NSObject
/// The condition it ended on, nil for EC_Normal.
@property (readonly, nullable) NSError *condition;
@property (readonly) BOOL conditionGood;
@property (readonly) uint16_t status;
@property (readonly) unsigned completed;
@property (readonly) unsigned failed;
@property (readonly) unsigned warnings;
@property (readonly) unsigned remaining;
/// DCMTK's name for a C-MOVE status.
@property (readonly, copy) NSString *moveStatusText;
/// The Failed SOP Instance UID List of the response identifier, when it has one.
@property (readonly, nullable, copy) NSString *failedSOPInstanceUIDs;
/// Prints the final response as DCMTK does.
- (void)printResponse;
@end

/// One association with a peer: opened, requested, used for one C-ECHO,
/// C-FIND, C-MOVE or C-GET of a query node, or for the C-STOREs of a send,
/// then released or aborted. Its DCMTK network, association and TLS layer are
/// destroyed two minutes after it is released, or at once if the global abort
/// is asked for, as other threads may still be using them; -invalidate
/// destroys them at once.
///
/// Every method gives the DCMTK condition it ended on as an error, nil for
/// EC_Normal, and a C++ exception as an error of IsiXDCMTKErrorCodeException.
/// The errors of the set-up name the call that failed (IsiXDCMTKOperationKey).
@interface IsiXDCMTKAssociation : NSObject

/// Initializes the network, the TLS layer if asked for, and the association
/// parameters with the presentation contexts asked for.
- (nullable instancetype)initWithParameters:(IsiXDCMTKAssociationParameters *)parameters
                                      error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Asks the peer for the association; blocks until it answers or times out.
- (nullable NSError *)request NS_SWIFT_NAME(request());
@property (readonly) BOOL hasAssociation;
/// Closes the connection without the A-ABORT handshake.
- (nullable NSError *)closeTransportConnection NS_SWIFT_NAME(closeTransportConnection());
- (nullable NSError *)releaseAssociation NS_SWIFT_NAME(releaseAssociation());

/// Destroys the association, the network and the TLS layer now rather than
/// two minutes after; the association is then unusable. Gives the last
/// condition DCMTK failed on (ASC_destroyAssociation, ASC_dropNetwork).
- (nullable NSError *)invalidate NS_SWIFT_NAME(invalidate());

@property (readonly) NSUInteger acceptedPresentationContextCount;
- (BOOL)acceptsAbstractSyntax:(NSString *)abstractSyntax NS_SWIFT_NAME(acceptsAbstractSyntax(_:));
/// The identifier of a presentation context the peer accepted for
/// `abstractSyntax`, in `transferSyntax` when given; 0 when there is none.
- (uint8_t)acceptedPresentationContextForAbstractSyntax:(NSString *)abstractSyntax
                                         transferSyntax:(nullable NSString *)transferSyntax
    NS_SWIFT_NAME(acceptedPresentationContext(forAbstractSyntax:transferSyntax:));
/// The transfer syntax the peer accepted in the presentation context
/// `identifier`; nil when it accepted none there.
- (nullable NSString *)acceptedTransferSyntaxOfPresentationContext:(uint8_t)identifier
    NS_SWIFT_NAME(acceptedTransferSyntax(ofPresentationContext:));

/// C-ECHO.
- (nullable NSError *)echoWithStatus:(uint16_t *)status NS_SWIFT_NAME(echo(withStatus:));

/// C-FIND in the Study Root model; `response` receives a copy of each match.
- (IsiXDCMTKFindResult *)findWithIdentifier:(IsiXDCMTKDataset *)identifier
                                   response:(NS_NOESCAPE void (^)(IsiXDCMTKDataset *match))response
    NS_SWIFT_NAME(find(withIdentifier:response:));

/// C-FIND in the information model `abstractSyntax` (Study Root, or the
/// Modality Worklist); `response` receives a copy of each match.
- (IsiXDCMTKFindResult *)findWithIdentifier:(IsiXDCMTKDataset *)identifier
                             abstractSyntax:(NSString *)abstractSyntax
                                   response:(NS_NOESCAPE void (^)(IsiXDCMTKDataset *match))response
    NS_SWIFT_NAME(find(withIdentifier:abstractSyntax:response:));

/// C-MOVE in the Study Root model to `destination`, or to this end's title.
/// `progress` receives each pending response's counts (`counted`), and is
/// called with none (`counted` NO) when a wait brought nothing.
- (IsiXDCMTKRetrieveResult *)moveWithIdentifier:(IsiXDCMTKDataset *)identifier
                                    destination:(nullable NSString *)destination
                                       progress:(NS_NOESCAPE void (^)(BOOL counted, NSUInteger accounted, NSUInteger finished))progress
    NS_SWIFT_NAME(move(withIdentifier:destination:progress:));

/// C-GET in the Study Root model, its C-STORE sub-operations on this
/// association, stored as the listener stores what it receives, in the
/// database `storage` gives for the AE title this end called. `incoming` is
/// called when what arrived is worth importing: after the first
/// sub-operation is stored, and when the C-GET ends other than on an error of
/// its own messages.
- (IsiXDCMTKRetrieveResult *)getWithIdentifier:(IsiXDCMTKDataset *)identifier
                                       storage:(NS_NOESCAPE id<IsiXDCMTKSCPDatabase> (^)(NSString *calledAETitle))storage
                                      progress:(NS_NOESCAPE void (^)(BOOL counted, NSUInteger accounted, NSUInteger finished))progress
                                      incoming:(NS_NOESCAPE void (^)(void))incoming
    NS_SWIFT_NAME(get(withIdentifier:storage:progress:incoming:));

/// The storage SOP classes a C-GET offers to receive (DCMTK's long list of
/// storage SOP classes).
@property (class, readonly, copy) NSArray<NSString *> *storageSOPClassesOfferedByGet;

/// The TLS cipher suites DCMTK knows, by name.
@property (class, readonly, copy) NSArray<NSString *> *availableCipherSuites;

@end

NS_ASSUME_NONNULL_END
