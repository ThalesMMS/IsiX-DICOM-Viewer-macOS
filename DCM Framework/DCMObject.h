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


#import <Foundation/Foundation.h>

@class DCMAttribute;
@class DCMAttributeTag;
@class DCMCharacterSet;
@class DCMTagDictionary ;
@class DCMTagForNameDictionary;
@class DCMTransferSyntax;

/** \brief This is the main object representaing a Dicom File or as a list of Attributes for networking
*
*	DCMObject is the main representation of a DICOM file or attribute list for networking. The object can be 
*	an image, Structured Report, Presentation State, etc
*
*	The framework parses and writes nothing itself (#742): reading goes to the host
*	application's DCMTK reader, which returns an object answering these same messages,
*	and writing to its DCMTK writer. A process without the host reads and writes nothing.
*/

@interface DCMObject : NSObject {

	NSMutableDictionary *attributes;
	NSDictionary *dicomDict;
	DCMTagDictionary *sharedTagDictionary;
	DCMTagForNameDictionary *sharedTagForNameDictionary;
	DCMCharacterSet *specificCharacterSet;
	DCMTransferSyntax *transferSyntax;
	BOOL _decodePixelData;
	BOOL isSequence;
}

@property(readonly) NSMutableDictionary *attributes; /**< Attributes as an NSDictionary */
@property(readonly) BOOL pixelDataIsDecoded; /**< Returns whether the pixel data has been converted to host endian transfer syntax */
@property(readonly) DCMTransferSyntax *transferSyntax;/**< The current transferSyntax */
@property(readonly) DCMCharacterSet *specificCharacterSet; /**< Encoding character set */
@property(readonly) NSXMLDocument *xmlDocument; /**< The object as an xml document */
@property(readonly) NSXMLNode *xmlNode; /**< The object as an xml node */
@property(readonly) NSString *description; /**< Human readable description */
@property BOOL isSequence;

+ (NSString*) globallyUniqueString;

/** Quick test to see if data is a DICOM/ACR file.  First looks for the DICM at 128. If that isn't there looks for valid DICOM 3  elements at the start */
+ (BOOL)isDICOM:(NSData *)data;

/** Returns to rootUID for files created used by Horos */
+ (NSString *)rootUID;

/** Returns the MACAddress of the computer which generated the image */
+ (NSString*) MACAddress;

/** Returns to implementationClassUID for files created used by Horos */
+ (NSString *)implementationClassUID;

/** Returns to implementationClassUID for files created used by Horos */
+ (NSString *)implementationVersionName;

+ (NSString*) newStudyInstanceUID;
+ (NSString*) newSeriesInstanceUID;

/** Create an empty DICOM object */
+ (id)dcmObject;

/** Anonymize a DICOM file
* @param file Path to the file to anonymize
* @param tags Array of tags to anonymize with the replacement values. Each object in tags is an array.
* The first object is a DCMAttributeTag..
* The second object is the replacement value if there is one.
* @param destination  Path to save the anonymized file at
*/
+ (BOOL)anonymizeContentsOfFile:(NSString *)file  tags:(NSArray *)tags  writingToFile:(NSString *)destination;

/** Create a secondary caputure object.  
* The patient name, patient ID, Study ID, and other necessary information us extracted from the template object
* @param object  The template object to extract information from
*/
+ (id)secondaryCaptureObjectFromTemplate:(DCMObject *)object;

/** Create a seocndary capture object
* @param bitDepth Bit depth of object ususally 8 or 16
* @param spp Samples per pixel is the number of color channels. 1 for monochrome. 3 for RGB
* @param nff Number of frames
*/
+ (id)secondaryCaptureObjectWithBitDepth:(int)bitDepth  samplesPerPixel:(int)spp numberOfFrames:(int)nff;

/** Create a DICOM object with data
* @param data Data to create the object with.
* @param decodePixelData  If YES the pixel data will be  decompressed if needed and converted to host byte order.
*/
+ (id)objectWithData:(NSData *)data decodingPixelData:(BOOL)decodePixelData;


/** Create a DICOM object from a file
* @param file Path to the file.
* @param decodePixelData  If YES the pixel data will be  decompressed if needed and converted to host byte order.
*/
+ (id)objectWithContentsOfFile:(NSString *)file decodingPixelData:(BOOL)decodePixelData;

/** Create a DICOM object from a URL
* @param aURL Absolute URL to the file.
* @param decodePixelData  If YES the pixel data will be  decompressed if needed and converted to host byte order.
*/
+ (id)objectWithContentsOfURL:(NSURL *)aURL decodingPixelData:(BOOL)decodePixelData;

/** Create a copy of a DICOM object
* @param object Original object.
*/
+ (id)objectWithObject:(DCMObject *)object;



/** Initialize a DICOM object with data
* @param data Data to create the object with.
* @param decodePixelData  If YES the pixel data will be  decompressed if needed and converted to host byte order.
*/
- (id)initWithData:(NSData *)data decodingPixelData:(BOOL)decodePixelData;


/** Initialize a DICOM object with data
* @param data Data to create the object with.
* @param syntax The encoding transfer syntax.
*/
- (id)initWithData:(NSData *)data transferSyntax:(DCMTransferSyntax *)syntax;

/** Initialize a DICOM object from a file
* @param file Path to the file.
* @param decodePixelData  If YES the pixel data will be  decompressed if needed and converted to host byte order.
*/
- (id)initWithContentsOfFile:(NSString *)file decodingPixelData:(BOOL)decodePixelData;

/** Initialize a DICOM object from a URL
* @param aURL Absolute URL to the file.
* @param decodePixelData  If YES the pixel data will be  decompressed if needed and converted to host byte order.
*/
- (id)initWithContentsOfURL:(NSURL *)aURL decodingPixelData:(BOOL)decodePixelData;

/** Initialize a copy of a DICOM object
* @param object Original object.
*/
- (id)initWithObject:(DCMObject *)object;

/** Empty initializer */
- (id)init;

/** Remove the metainformation. This is all elements for group 0x0002*/		
- (void)removeMetaInformation;

/** Update the metainformation\n
*	mandatory attributes:\n
*		FileMetaInformationVersion\n
*		MediaStorageSOPClassUID\n
*		MediaStorageSOPInstanceUID\n
*		TransferSyntaxUID\n
*		ImplementationClassUID\n
*		SourceApplicationEntityTitle\n
*		groupLengthTag\n
*/
- (void)updateMetaInformationWithTransferSyntax: (DCMTransferSyntax *)ts aet:(NSString *)aet;

/** Remove group lengths */
- (void)removeGroupLengths;

/** Remove private tags */
- (void)removePrivateTags;

/** Remove planar and rescale attributes.\n
*  Used when changing the pixelData encapsulation or rescaling pixelData
*/
- (void)removePlanarAndRescaleAttributes;

/** Anonymize DCMAttributeTag or replace with aValue if present */
- (void)anonymizeAttributeForTag:(DCMAttributeTag *)tag replacingWith:(id)aValue;

/** Create a new study instance UID */
- (void)newStudyInstanceUID;

/** Create a new series instance UID */
- (void)newSeriesInstanceUID;

/** Create a new SOP Instance UID */
- (void)newSOPInstanceUID;

/** Anonymize the given string */
- (NSString *)anonymizeString:(NSString *)string;

/** Set the Specific character set
* @param characterSet The new DCMCharacterSet
*/
- (void)setCharacterSet:(DCMCharacterSet *)characterSet;

/** Return the DCMAttribute for the given DCMAttributeTag */
- (DCMAttribute *)attributeForTag:(DCMAttributeTag *)tag;

/** Return the first value for the  named attribute. */
- (id)attributeValueWithName:(NSString *)name;

/** Return the first value for the attribute with the key
* @param key The element as a string 0XGGGGWWWW */
- (id)attributeValueForKey:(NSString *)key;

/** Return the named attribute . */
- (DCMAttribute *)attributeWithName:(NSString *)name;

/** Return the array of values for the attribute with the key
 * @param key The element as a string 0XGGGGWWWW */
- (NSArray *)attributeArrayForKey:(NSString *)key;

/** Return the array of values for the named attribute */
- (NSArray *)attributeArrayWithName:(NSString *)name;

/** Set the DCMAttribute */
- (void)setAttribute:(DCMAttribute *)attr;

/** add a value to the named attribute*/
- (void)addAttributeValue:(id)value   forName:(NSString *)name;

/** Set the array of values for the named attribute */
- (void)setAttributeValues:(NSMutableArray *)values forName:(NSString *)name;


/** Write to a file
* @param path Path to the file
* @param ts DCMTransferSyntax for writing
* @param quality The quality for lossy syntaxes
* @param aet Application Entity Title for the device doing the writing
* @param atomically  If YES, the data is written to a backup file, and thenÑassuming no errors occurÑthe backup file is renamed to the name specified by path; otherwise, the data is written directly to path.
*/		
- (BOOL)writeToFile:(NSString *)path withTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality AET:(NSString *)aet atomically:(BOOL)atomically;

/** Write to a url
* @param aURL URL to the file
* @param ts DCMTransferSyntax for writing
* @param quality The quality for lossy syntaxes
* @param aet Application Entity Title for the device doing the writing
* @param atomically  If YES, the data is written to a backup file, and thenÑassuming no errors occurÑthe backup file is renamed to the name specified by path; otherwise, the data is written directly to path.
* If YES, the data is written to a backup location, and thenÑassuming no errors occurÑthe backup location is renamed to the name specified by aURL; otherwise, the data is written directly to aURL. atomically is ignored if aURL is not of a type the supports atomic writes.
*/
- (BOOL)writeToURL:(NSURL *)aURL withTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality AET:(NSString *)aet atomically:(BOOL)atomically;


/** Write to NSData, dataset only (no preamble or meta header)
* @param ts DCMTransferSyntax for writing
* @param quality The quality for lossy syntaxes
*/
- (NSData *)writeDatasetWithTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality;

/** Returns YES if the tag string is a needed attribute. No longer consulted: DCMTK reads every attribute (#742). */
- (BOOL)isNeededAttribute:(char *)tagString;

/** Deprecated */
- (BOOL)writeToFile:(NSString *)path withTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality atomically:(BOOL)flag;

/** Deprecated */
- (BOOL)writeToURL:(NSURL *)aURL withTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality atomically:(BOOL)flag;

//sequences
/** return a sequence as an NSArray */
- (NSArray *)referencedSeriesSequence;

/** returns the referenced Image Sequence for object */
- (NSArray *)referencedImageSequenceForObject:(DCMObject *)object;

/** Create a Structured Report Object */
+ (id)objectWithCodeValue:(NSString *)codeValue  
			codingSchemeDesignator:(NSString *)codingSchemeDesignator  
			codeMeaning:(NSString *)codeMeaning;

@end
