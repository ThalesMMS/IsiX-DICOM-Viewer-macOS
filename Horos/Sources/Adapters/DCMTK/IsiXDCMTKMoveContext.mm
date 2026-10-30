#include "HorosDIMSEAssociation.h"
#include "HorosDICOMStoreSource.h"
/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
/*
 *
 *  Copyright (C) 1993-2005, OFFIS
 *
 *  This software and supporting documentation were developed by
 *
 *    Kuratorium OFFIS e.V.
 *    Healthcare Information and Communication Systems
 *    Escherweg 2
 *    D-26121 Oldenburg, Germany
 *
 *  THIS SOFTWARE IS MADE AVAILABLE,  AS IS,  AND OFFIS MAKES NO  WARRANTY
 *  REGARDING  THE  SOFTWARE,  ITS  PERFORMANCE,  ITS  MERCHANTABILITY  OR
 *  FITNESS FOR ANY PARTICULAR USE, FREEDOM FROM ANY COMPUTER DISEASES  OR
 *  ITS CONFORMITY TO ANY SPECIFICATION. THE ENTIRE RISK AS TO QUALITY AND
 *  PERFORMANCE OF THE SOFTWARE IS WITH THE USER.
 *
 *  Module:  dcmqrdb
 *
 *  Author:  Marco Eichelberg
 *
 *  Purpose: class IsiXDCMTKMoveContext
 *
 *  Last Update:      $Author: lpysher $
 *  Update Date:      $Date: 2006/03/01 20:16:07 $
 *  Source File:      $Source: /cvsroot/osirix/osirix/Binaries/dcmtk-source/dcmqrdb/dcmqrcbm.cc,v $
 *  CVS/RCS Revision: $Revision: 1.1 $
 *  Status:           $State: Exp $
 *
 *  CVS/RCS Log at end of file
 *
 */

// Part of the DCMTK adapter: the sub-association and C-STOREs of the
// listener's C-MOVE. The destination and the syntaxes it is offered come from
// the application's lookup block. Compiled without ARC, as the server that
// includes the header is.

#import <Foundation/Foundation.h>

#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>    /* make sure OS specific configuration is included first */
#include "IsiXDCMTKMoveContext.hpp"
#include <Block.h>
#include <vector>

#include <dcmtk/dcmqrdb/dcmqrcnf.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmqrdb/dcmqropt.h>
#include <dcmtk/dcmnet/diutil.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmqrdb/dcmqrdbs.h>
#include <dcmtk/dcmqrdb/dcmqrdbi.h>

#include <dcmtk/ofstd/ofstring.h>
#include <dcmtk/dcmnet/dimse.h>
#include <dcmtk/dcmnet/diutil.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcdeftag.h>

#include <dcmtk/ofstd/ofconapp.h>
#include <dcmtk/dcmdata/dcuid.h>     /* for dcmtk version name */
#include <dcmtk/dcmnet/dicom.h>     /* for DICOM_APPLICATION_REQUESTOR */
#include <dcmtk/dcmdata/dcostrmz.h>  /* for dcmZlibCompressionLevel */
#include <dcmtk/dcmnet/dcasccfg.h>  /* for class DcmAssociationConfiguration */
#include <dcmtk/dcmnet/dcasccff.h>  /* for class DcmAssociationConfigurationFile */


#include <dcmtk/dcmjpeg/djdecode.h>  /* for dcmjpeg decoders */
#include <dcmtk/dcmjpeg/djencode.h>  /* for dcmjpeg encoders */
#include <dcmtk/dcmdata/dcrledrg.h>  /* for DcmRLEDecoderRegistration */
#include <dcmtk/dcmdata/dcrleerg.h>  /* for DcmRLEEncoderRegistration */
#include <dcmtk/dcmjpeg/djrploss.h>
#include <dcmtk/dcmjpeg/djrplol.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcrlerp.h>

BEGIN_EXTERN_C
#ifdef HAVE_FCNTL_H
#include <fcntl.h>       /* needed on Solaris for O_RDONLY */
#endif
END_EXTERN_C

static void HorosDumpDIMSECondition(OFCondition condition)
{
    OFString text;
    DimseCondition::dump(text, condition);
    ofConsole.lockCerr() << text << OFendl;
    ofConsole.unlockCerr();
}

@implementation IsiXDCMTKMoveDestination

- (instancetype)initWithHost:(NSString *)host port:(int)port transferSyntaxes:(NSArray<NSString *> *)transferSyntaxes
{
    if ((self = [super init])) {
        _host = [host copy];
        _port = port;
        _transferSyntaxes = [transferSyntaxes copy];
    }
    return self;
}

- (void)dealloc
{
    [_host release];
    [_transferSyntaxes release];
    [super dealloc];
}

@end

static void moveSubOpProgressCallback(void *callbackData, 
    T_DIMSE_StoreProgress *progress,
    T_DIMSE_C_StoreRQ * /*req*/)
{
  IsiXDCMTKMoveContext *context = OFstatic_cast(IsiXDCMTKMoveContext *, callbackData);
  if (context->isVerbose())
  {
    switch (progress->state)
    {
      case DIMSE_StoreBegin:
        printf("XMIT:");
        break;
      case DIMSE_StoreEnd:
        printf("\n");
        break;
      default:
        putchar('.');
        break;
    }
    fflush(stdout);
  }
}

IsiXDCMTKMoveContext::IsiXDCMTKMoveContext(
  DcmQueryRetrieveDatabaseHandle& handle,
  const DcmQueryRetrieveOptions& options,
  const DcmQueryRetrieveConfig *cfg,
  DIC_US priorstatus,
  T_ASC_Association *assoc,
  DIC_US msgid,
  T_DIMSE_Priority pr,
  IsiXDCMTKMoveDestinationLookup lookup)
: dbHandle(handle)
, options_(options)
, priorStatus(priorstatus)
, origAssoc(assoc)
, subAssoc(NULL)
, config(cfg)
, assocStarted(OFFalse)
, origMsgId(msgid)
, priority(pr)
, failedUIDs(NULL)
, nRemaining(0)
, nCompleted(0)
, nFailed(0)
, nWarning(0)
, destinationLookup(lookup ? (void *)Block_copy(lookup) : NULL)
{
    origAETitle[0] = '\0';
    origHostName[0] = '\0';
    dstAETitle[0] = '\0';
}

IsiXDCMTKMoveContext::~IsiXDCMTKMoveContext()
{
    if (destinationLookup) Block_release(destinationLookup);
    free(failedUIDs);
}

OFBool IsiXDCMTKMoveContext::isVerbose() const 
{ 
  return DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL) ? OFTrue : OFFalse; 
}

void IsiXDCMTKMoveContext::callbackHandler(
	/* in */
	OFBool cancelled,
	T_DIMSE_C_MoveRQ *request,
	DcmDataset *requestIdentifiers,
	int responseCount,
	/* out */
	T_DIMSE_C_MoveRSP *response,
	 DcmDataset **stDetail,
	DcmDataset **responseIdentifiers)
{
    // DIMSE_moveProvider is DCMTK's C code: no C++ exception may reach it.
    try {
        handleCallback(cancelled, request, requestIdentifiers, responseCount, response, stDetail, responseIdentifiers);
    } catch (const std::exception &exception) {
        HorosDIMSEError("moveSCP: C-MOVE ended on a C++ exception: %s", exception.what());
        closeSubAssociation();
        response->DimseStatus = STATUS_MOVE_Failed_UnableToProcess;
    } catch (...) {
        HorosDIMSEError("moveSCP: C-MOVE ended on a C++ exception");
        closeSubAssociation();
        response->DimseStatus = STATUS_MOVE_Failed_UnableToProcess;
    }
}

void IsiXDCMTKMoveContext::handleCallback(
	OFBool cancelled,
	T_DIMSE_C_MoveRQ *request,
	DcmDataset *requestIdentifiers,
	int responseCount,
	T_DIMSE_C_MoveRSP *response,
	 DcmDataset **stDetail,
	DcmDataset **responseIdentifiers)
{
    OFCondition cond = EC_Normal;
    OFCondition dbcond = EC_Normal;
    DcmQueryRetrieveDatabaseStatus dbStatus(priorStatus);
    
    if (responseCount == 1) {
        /* start the database search */
	if (DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL)) {
	    printf("Move SCP Request Identifiers:\n");
	    requestIdentifiers->print(COUT);
        }
		
        dbcond = dbHandle.startMoveRequest(
	    request->AffectedSOPClassUID, requestIdentifiers, &dbStatus);
        if (dbcond.bad()) {
	    HorosDIMSEError("moveSCP: Database: startMoveRequest Failed (%s):",
		DU_cmoveStatusString(dbStatus.status()));
        }

        if (dbStatus.status() == STATUS_Pending) {
            /* If we are going to be performing sub-operations, build
             * a new association to the move destination.
             */
	    cond = buildSubAssociation(request);
	    if (cond == QR_EC_InvalidPeer) {
	        dbStatus.setStatus(STATUS_MOVE_Failed_MoveDestinationUnknown);
	    } else if (cond.bad()) {
	        /* failed to build association, must fail move */
		failAllSubOperations(&dbStatus);
	    }
        }
    }
    
    /* only cancel if we have pending status */
    if (cancelled && dbStatus.status() == STATUS_Pending) {
	dbHandle.cancelMoveRequest(&dbStatus);
    }

    if (dbStatus.status() == STATUS_Pending) {
        moveNextImage(&dbStatus);
    }

    if (dbStatus.status() != STATUS_Pending) {
	/*
	 * Tear down sub-association (if it exists).
	 */
	closeSubAssociation();

	/*
	 * Need to adjust the final status if any sub-operations failed or
	 * had warnings 
	 */
	if (dbStatus.status() == STATUS_Success && (nFailed > 0 || nWarning > 0)) {
	    dbStatus.setStatus(STATUS_MOVE_Warning_SubOperationsCompleteOneOrMoreFailures);
	}
        /*
         * if all the sub-operations failed then we need to generate a failed or refused status.
         * cf. DICOM part 4, C.4.2.3.1
         * we choose to generate a "Refused - Out of Resources - Unable to perform suboperations" status.
         */
        if (dbStatus.status() == STATUS_MOVE_Warning_SubOperationsCompleteOneOrMoreFailures &&
            (nFailed > 0) && ((nCompleted + nWarning) == 0)) {
	    dbStatus.setStatus(STATUS_MOVE_Refused_OutOfResourcesSubOperations);
	}
    }
    
    if (dbStatus.status() != STATUS_Success && 
        dbStatus.status() != STATUS_Pending) {
	/* 
	 * May only include response identifiers if not Success 
	 * and not Pending 
	 */
	buildFailedInstanceList(responseIdentifiers);
    }

    /* set response status */
    response->DimseStatus = dbStatus.status();
    response->NumberOfRemainingSubOperations = nRemaining;
    response->NumberOfCompletedSubOperations = nCompleted;
    response->NumberOfFailedSubOperations = nFailed;
    response->NumberOfWarningSubOperations = nWarning;
    *stDetail = dbStatus.extractStatusDetail();

    if (DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL)) {
        printf("Move SCP Response %d [status: %s]\n", responseCount,
	    DU_cmoveStatusString(dbStatus.status()));
    }
    if (DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL)) {
        DIMSE_printCMoveRSP(stdout, response);
        if (DICOM_PENDING_STATUS(dbStatus.status()) && (*responseIdentifiers != NULL)) {
            printf("Move SCP Response Identifiers:\n");
            (*responseIdentifiers)->print(COUT);
        }
        if (*stDetail) {
            printf("Status detail:\n");
            (*stDetail)->print(COUT);
        }
    }    
}

void IsiXDCMTKMoveContext::addFailedUIDInstance(const char *sopInstance)
{
    int len;

    if (failedUIDs == NULL) {
	if ((failedUIDs = (char*)malloc(DIC_UI_LEN+1)) == NULL) {
	    HorosDIMSEError("malloc failure: addFailedUIDInstance");
	    return;
	}
	strcpy(failedUIDs, sopInstance);
    } else {
	len = strlen(failedUIDs);
	if ((failedUIDs = (char*)realloc(failedUIDs, 
	    (len+strlen(sopInstance)+2))) == NULL) {
	    HorosDIMSEError("realloc failure: addFailedUIDInstance");
	    return;
	}
	/* tag sopInstance onto end of old with '\' between */
	strcat(failedUIDs, "\\");
	strcat(failedUIDs, sopInstance);
    }
}

OFCondition IsiXDCMTKMoveContext::performMoveSubOp(DIC_UI sopClass, DIC_UI sopInstance, char *fname)
{
    OFCondition cond = EC_Normal;
    T_DIMSE_C_StoreRQ req;
    T_DIMSE_C_StoreRSP rsp;
    DIC_US msgId;
    T_ASC_PresentationContextID presId;
    DcmDataset *stDetail = NULL;

    HorosDICOMStoreSource source(fname);
    cond = source.prepare(subAssoc, sopClass, fname, false);
    if (cond.bad())
    {
        ++nFailed;
        addFailedUIDInstance(sopInstance);
        return cond;
    }
    msgId = subAssoc->nextMsgID++;
    presId = source.presentationID;

    req.MessageID = msgId;
    strcpy(req.AffectedSOPClassUID, sopClass);
    strcpy(req.AffectedSOPInstanceUID, sopInstance);
    req.DataSetType = DIMSE_DATASET_PRESENT;
    req.Priority = priority;
    req.opts = (O_STORE_MOVEORIGINATORAETITLE | O_STORE_MOVEORIGINATORID);
    strcpy(req.MoveOriginatorApplicationEntityTitle, origAETitle);
    req.MoveOriginatorID = origMsgId;

    if (DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL)) {
	printf("Store SCU RQ: MsgID %d, (%s)\n", 
	    msgId, dcmSOPClassUIDToModality(sopClass));
    }

    cond = DIMSE_storeUser(subAssoc, presId, &req,
        source.datasetToSend ? NULL : fname, source.datasetToSend, moveSubOpProgressCallback, this, 
	options_.blockMode_, options_.dimse_timeout_, 
	&rsp, &stDetail);
	

	
    if (cond.good()) {
        if (DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL)) {
	    printf("Move SCP: Received Store SCU RSP [Status=%s]\n",
	        DU_cstoreStatusString(rsp.DimseStatus));
        }
	if (rsp.DimseStatus == STATUS_Success) {
	    /* everything ok */
	    nCompleted++;
	} else if ((rsp.DimseStatus & 0xf000) == 0xb000) {
	    /* a warning status message */
	    nWarning++;
	    HorosDIMSEError("Move SCP: Store Waring: Response Status: %s", 
		DU_cstoreStatusString(rsp.DimseStatus));
	} else {
	    nFailed++;
	    addFailedUIDInstance(sopInstance);
	    /* print a status message */
	    HorosDIMSEError("Move SCP: Store Failed: Response Status: %s", 
		DU_cstoreStatusString(rsp.DimseStatus));
	}
    } else {
	nFailed++;
	addFailedUIDInstance(sopInstance);
	HorosDIMSEError("Move SCP: storeSCU: Store Request Failed:");
	HorosDumpDIMSECondition(cond);
    }
    if (stDetail != NULL) {
        if (DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL)) {
	    printf("  Status Detail:\n");
	    stDetail->print(COUT);
	}
        delete stDetail;
    }
    return cond;
}

OFCondition IsiXDCMTKMoveContext::buildSubAssociation(T_DIMSE_C_MoveRQ *request)
{
    OFCondition cond = EC_Normal;
    OFString dstHostName;
    int dstPortNumber;
    DIC_NODENAME localHostName;
    T_ASC_Parameters *params;

    strcpy(dstAETitle, request->MoveDestination);

    /*
     * We must map the destination AE Title into a host name and port
     * address.  Further, we must make sure that the RSNA'93 demonstration
     * rules are observed regarding move destinations. 
     */

    DIC_AE aeTitle;
    aeTitle[0] = '\0';
    ASC_getAPTitles(origAssoc->params, origAETitle, sizeof(origAETitle), aeTitle, sizeof(aeTitle), NULL, 0);
    ourAETitle = aeTitle;

    ASC_getPresentationAddresses(origAssoc->params, origHostName, sizeof(origHostName), NULL, 0);
	
    if (!mapMoveDestination(origHostName, origAETitle, request->MoveDestination, dstHostName, &dstPortNumber))
	{
		return QR_EC_InvalidPeer;
    }

    if (cond.good())
	{
		cond = ASC_createAssociationParameters(&params, ASC_DEFAULTMAXPDU, options_.acse_timeout_);
		if (cond.bad())
		{
			HorosDIMSEError("moveSCP: Cannot create Association-params for sub-ops:");
			HorosDumpDIMSECondition(cond);
		}
    }
	
    if (cond.good())
	{
		gethostname(localHostName, sizeof(localHostName) - 1);
		cond = HorosDIMSESetPeerAddress(params, localHostName, dstHostName.c_str(), dstPortNumber);
        if (cond.bad()) { ASC_destroyAssociationParameters(&params); return cond; }
		ASC_setAPTitles(params, ourAETitle.c_str(), dstAETitle,NULL);
	
		cond = addAllStoragePresentationContexts(params);
		if (cond.bad())
		{
			HorosDumpDIMSECondition(cond);
		}
		if (DCM_dcmnetLogger.isEnabledFor(OFLogger::DEBUG_LOG_LEVEL))
		{
			printf("Request Parameters:\n");
			OFString parametersText;
			COUT << ASC_dumpParameters(parametersText, params, ASC_ASSOC_RQ) << OFendl;
		}
    }
	
    if (cond.good()) {
	/* create association */
	if (DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL))
	    printf("Requesting Sub-Association\n");
	cond = HorosDIMSERequestAssociation(options_.net_, params,
				      &subAssoc);
	if (cond.bad()) {
	    if (cond == DUL_ASSOCIATIONREJECTED) {
			T_ASC_RejectParameters rej;

			ASC_getRejectParameters(params, &rej);
			HorosDIMSEError("moveSCP: Sub-Association Rejected");
			OFString rejectionText;
			fprintf(stderr, "%s\n", ASC_printRejectParameters(rejectionText, &rej).c_str());
			fprintf(stderr, "\n");
	    } else {
			HorosDIMSEError("moveSCP: Sub-Association Request Failed:");
			HorosDumpDIMSECondition(cond);
		
	    }
	}
    }

    if (cond.good()) {
	assocStarted = OFTrue;
    }    
    return cond;
}

OFCondition IsiXDCMTKMoveContext::closeSubAssociation()
{
    OFCondition cond = EC_Normal;

    if (subAssoc != NULL) {
	/* release association */
	if (DCM_dcmnetLogger.isEnabledFor(OFLogger::INFO_LOG_LEVEL))
	    printf("Releasing Sub-Association\n");
	cond = ASC_releaseAssociation(subAssoc);
	if (cond.bad()) {
	    HorosDIMSEError("moveSCP: Sub-Association Release Failed:");
	    HorosDumpDIMSECondition(cond);
	}
	cond = ASC_dropAssociation(subAssoc);
	if (cond.bad()) {
	    HorosDIMSEError("moveSCP: Sub-Association Drop Failed:");
	    HorosDumpDIMSECondition(cond);
	}
	cond = ASC_destroyAssociation(&subAssoc);
	if (cond.bad()) {
	    HorosDIMSEError("moveSCP: Sub-Association Destroy Failed:");
	    HorosDumpDIMSECondition(cond);
	}

    }

    if (assocStarted) {
	assocStarted = OFFalse;
    }

    return cond;
}

void IsiXDCMTKMoveContext::moveNextImage(DcmQueryRetrieveDatabaseStatus* status)
{
    DIC_UI sopClass = {}, sopInstance = {};
    char path[MAXPATHLEN + 1] = {};
    OFCondition result = dbHandle.nextMoveResponse(sopClass, sizeof(sopClass), sopInstance, sizeof(sopInstance),
        path, sizeof(path), &nRemaining, status);
    if (result.bad())
    {
        status->setStatus(STATUS_MOVE_Refused_OutOfResourcesSubOperations);
        return;
    }
    if (status->status() != STATUS_Pending) return;
    result = performMoveSubOp(sopClass, sopInstance, path);
    if (result.bad() && result != DIMSE_NOVALIDPRESENTATIONCONTEXTID && result != EC_CannotChangeRepresentation)
    {
        DcmQueryRetrieveDatabaseStatus cleanup;
        dbHandle.cancelMoveRequest(&cleanup);
        status->setStatus(STATUS_MOVE_Refused_OutOfResourcesSubOperations);
    }
}

void IsiXDCMTKMoveContext::failAllSubOperations(DcmQueryRetrieveDatabaseStatus * dbStatus)
{
    OFCondition dbcond = EC_Normal;
    DIC_UI subImgSOPClass;	/* sub-operation image SOP Class */
    DIC_UI subImgSOPInstance;	/* sub-operation image SOP Instance */
    char subImgFileName[MAXPATHLEN + 1];	/* sub-operation image file */

    /* clear out strings */
    bzero(subImgFileName, sizeof(subImgFileName));
    bzero(subImgSOPClass, sizeof(subImgSOPClass));
    bzero(subImgSOPInstance, sizeof(subImgSOPInstance));

    while (dbStatus->status() == STATUS_Pending) {
        /* get DB response */
        dbcond = dbHandle.nextMoveResponse(
	    subImgSOPClass, sizeof(subImgSOPClass), subImgSOPInstance, sizeof(subImgSOPInstance), subImgFileName, sizeof(subImgFileName),
	    &nRemaining, dbStatus);
        if (dbcond.bad()) {
	    HorosDIMSEError("moveSCP: Database: nextMoveResponse Failed (%s):",
	        DU_cmoveStatusString(dbStatus->status()));
        }

	if (dbStatus->status() == STATUS_Pending) {
	    nFailed++;
	    addFailedUIDInstance(subImgSOPInstance);
	}
    }
    dbStatus->setStatus(STATUS_MOVE_Warning_SubOperationsCompleteOneOrMoreFailures);    
}

void IsiXDCMTKMoveContext::buildFailedInstanceList(DcmDataset ** rspIds)
{
    OFBool ok;

    if (failedUIDs != NULL) {
	*rspIds = new DcmDataset();
	ok = DU_putStringDOElement(*rspIds, DCM_FailedSOPInstanceUIDList,
	    failedUIDs);
	if (!ok) {
	    HorosDIMSEError("moveSCP: failed to build DCM_FailedSOPInstanceUIDList");
	}
	free(failedUIDs);
	failedUIDs = NULL;
    }
}

OFBool IsiXDCMTKMoveContext::mapMoveDestination(
  const char *origPeer, const char *origAE,
  const char *dstAE, OFString& dstPeer, int *dstPort)
{
    // The application finds the node of Locations with that title (or, failing
    // that, that name), and the transfer syntaxes to offer it.
    if (!destinationLookup) return OFFalse;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *moveDestination = [NSString stringWithCString:dstAE encoding:NSISOLatin1StringEncoding];
    IsiXDCMTKMoveDestination *destination =
        moveDestination ? ((IsiXDCMTKMoveDestinationLookup)destinationLookup)(moveDestination) : nil;
    const char *host = [destination.host cStringUsingEncoding:NSISOLatin1StringEncoding];
    OFBool found = destination != nil && host != NULL;
    if (found)
    {
        *dstPort = destination.port;
        dstPeer = host;
        transferSyntaxes.clear();
        for (NSString *syntax in destination.transferSyntaxes)
            transferSyntaxes.push_back(syntax.UTF8String);
    }
    [pool release];
    return found;
}

OFCondition IsiXDCMTKMoveContext::addAllStoragePresentationContexts(T_ASC_Parameters *params)
{
    OFCondition cond = EC_Normal;

    int i;
    int pid = 1;

    // The syntaxes the application chose for the destination, the same for
    // every storage SOP class.
    std::vector<const char *> syntaxes;
    for (OFListIterator(OFString) syntax = transferSyntaxes.begin(); syntax != transferSyntaxes.end(); ++syntax)
        syntaxes.push_back(syntax->c_str());

    for (i=0; i<numberOfDcmLongSCUStorageSOPClassUIDs && cond.good(); i++) {
	cond = ASC_addPresentationContext(
	    params, pid, dcmLongSCUStorageSOPClassUIDs[i],
	    syntaxes.data(), (int)syntaxes.size());
	pid += 2;	/* only odd presentation context id's */
    }
    return cond;
}


/*
 * CVS Log
 * $Log: dcmqrcbm.cc,v $
 * Revision 1.1  2006/03/01 20:16:07  lpysher
 * Added dcmtkt ocvs not in xcode  and fixed bug with multiple monitors
 *
 * Revision 1.9  2005/12/20 11:21:30  meichel
 * Removed duplicate parameter
 *
 * Revision 1.8  2005/12/08 15:47:06  meichel
 * Changed include path schema for all DCMTK header files
 *
 * Revision 1.7  2005/11/29 10:54:52  meichel
 * Added minimal support for compressed transfer syntaxes to dcmqrscp.
 *   No on-the-fly decompression is performed, but compressed images can
 *   be stored and retrieved.
 *
 * Revision 1.6  2005/11/17 13:44:40  meichel
 * Added command line options for DIMSE and ACSE timeouts
 *
 * Revision 1.5  2005/10/25 08:56:18  meichel
 * Updated list of UIDs and added support for new transfer syntaxes
 *   and storage SOP classes.
 *
 * Revision 1.4  2005/08/30 08:37:52  meichel
 * Fixed syntax error reported by Visual Studio 2003
 *
 * Revision 1.3  2005/06/16 08:02:43  meichel
 * Added system include files needed on Solaris
 *
 * Revision 1.2  2005/04/04 14:39:54  meichel
 * Fixed warning on Win32 platform
 *
 * Revision 1.1  2005/03/30 13:34:53  meichel
 * Initial release of module dcmqrdb that will replace module imagectn.
 *   It provides a clear interface between the Q/R DICOM front-end and the
 *   database back-end. The imagectn code has been re-factored into a minimal
 *   class structure.
 *
 *
 */
