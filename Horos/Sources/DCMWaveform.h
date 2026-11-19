/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/


#import <Foundation/Foundation.h>

// The waveform of a DICOM file (an electrocardiogram, a pressure curve, a
// sound) as the plugin SDK of Horos and OsiriX described it: a waveform has
// multiplex groups (DCMWaveformSequence), each with its samples and the
// definition of each of its channels, and the code sequence and SOP instance
// reference macros those definitions use. They are objects of values: what is
// set is what is answered, and -[DCMWaveformSequence getValues:] turns the
// samples into numbers. Nothing in the application reads a waveform from a
// file, and -[DCMPix waveform] is nil.
//
// The properties are atomic, as they were: an object may be read and written
// from several threads.
//
// The SDK's -new... methods answered an object that the receiver keeps and
// that the caller does not own, though their names say otherwise to the
// compiler. They are declared in the categories FormerSDKOwnership, as not
// retained, and answer as they did: a plugin built without automatic
// reference counting does not release what they answer.
//
// DCMWaveform.swift implements the nine classes (@objc @implementation), with
// the instance variables the SDK declared, which keep the values.

#ifdef __cplusplus
extern "C" {
#endif

@class DCMWaveformSequence;

@interface DCMWaveform : NSObject

/// The multiplex groups made so far, in the order they were made.
- (NSArray*)sequences;

@end

@interface DCMWaveform (FormerSDKOwnership)
/// A new multiplex group, added to -sequences.
- (DCMWaveformSequence*)newSequence NS_RETURNS_NOT_RETAINED;
@end

typedef enum {
    DCMWaveformOriginalityOriginal,
    DCMWaveformOriginalityDerived
} DCMWaveformOriginality;

@class DCMWaveformChannelDefinition;

typedef enum {
    DCMWaveformSampleInterpretationSB,
    DCMWaveformSampleInterpretationUB,
    DCMWaveformSampleInterpretationMB,
    DCMWaveformSampleInterpretationAB,
    DCMWaveformSampleInterpretationSS,
    DCMWaveformSampleInterpretationUS
} DCMWaveformSampleInterpretation;

@interface DCMWaveformSequence : NSObject

@property CGFloat multiplexgroupTimeOffset;                              // (0018,1068) MultiplexgroupTimeOffset 1C DS [1]
@property CGFloat triggerTimeOffset;                                     // (0018,1069) TriggerTimeOffset 1C DS [1]
@property unsigned int triggerSamplePosition;                            // (0018,106E) TriggerSamplePosition 3 UL [1]
@property DCMWaveformOriginality waveformOriginality;                    // (003A,0004) WaveformOriginality 1 CS [1]
@property unsigned short numberOfWaveformChannels;                       // (003A,0005) NumberOfWaveformChannels 1 US [1]
@property unsigned int numberOfWaveformSamples;                          // (003A,0010) NumberOfWaveformSamples 1 UL [1]
@property CGFloat samplingFrequency;                                     // (003A,001A) SamplingFrequency 1 DS [1]
@property(retain) NSString* multiplexGroupLabel;                         // (003A,0020) MultiplexGroupLabel 3 SH [1]
@property(retain,readonly) NSArray* channelDefinitions;                  // (003A,0200) ChannelDefinitionSequence 1 SQ [1] (1+)
@property unsigned short waveformBitsAllocated;                          // (5400,1004) WaveformBitsAllocated 1 US [1]
@property DCMWaveformSampleInterpretation waveformSampleInterpretation;  // (5400,1006) WaveformSampleInterpretation 1 CS [1]

// The value as the file writes it ("ORIGINAL", "DERIVED"; "SB", "UB", "MB",
// "AB", "SS", "US"). Another value raises NSGenericException.
- (void)setWaveformOriginalityCS:(char*)cs;
- (void)setWaveformSampleInterpretationCS:(char*)cs;
// A copy of the bytes is kept.
- (void)setWaveformPaddingValue:(void*)data length:(size_t)length;       // (5400,100A) WaveformPaddingValue 1C OB/OW [1]
- (void)setWaveformData:(void*)data length:(size_t)length;               // (5400,1010) WaveformData 1 OB/OW [1]

/// The samples as numbers, one after the other as the file has them (the
/// first of each channel, then the second of each), and how many they are;
/// they belong to the receiver and last as long as it does. They are computed
/// at the first call that succeeds, which also gives each channel definition
/// there is the least and the greatest of its values, and kept. NULL, with
/// `numberOfValues` untouched, when the waveform data has not the length the
/// channels, the samples and the bits allocated give, or when the bits
/// allocated are fewer than a sample of that interpretation takes.
/// The SDK's method answered 0 values with the same numbers, having never set
/// the length of what it kept; a caller that read them by the counts of
/// channels and samples reads the same ones.
- (CGFloat*)getValues:(NSUInteger*)numberOfValues;

@end

@interface DCMWaveformSequence (FormerSDKOwnership)
/// A new channel definition, added to channelDefinitions.
- (DCMWaveformChannelDefinition*)newChannelDefinition NS_RETURNS_NOT_RETAINED;
@end

typedef enum {
    DCMWaveformChannelStatusOk,
    DCMWaveformChannelStatusTestData,
    DCMWaveformChannelStatusDisconnected,
    DCMWaveformChannelStatusQuestionable,
    DCMWaveformChannelStatusInvalid,
    DCMWaveformChannelStatusUncalibrated,
    DCMWaveformChannelStatusUnzeroed
} DCMWaveformChannelStatus;

@class DCMWaveformChannelSource;
@class DCMWaveformChannelSourceModifier;
@class DCMWaveformSourceWaveform;
@class DCMWaveformChannelSensitivityUnit;

@interface DCMWaveformChannelDefinition : NSObject

@property NSInteger waveformChannelNumber;                                              // (003A,0202) WaveformChannelNumber 3 IS [1]
@property(retain) NSString* channelLabel;                                               // (003A,0203) ChannelLabel 3 SH [1]
@property DCMWaveformChannelStatus channelStatus;                                       // (003A,0205) ChannelStatus 3 CS [1-n]
@property(retain,readonly) DCMWaveformChannelSource* channelSource;                     // (003A,0208) ChannelSourceSequence 1 SQ [1] (1)
@property(retain,readonly) NSArray* channelSourceModifiers;                             // (003A,0209) ChannelSourceModifiersSequence 1C SQ [1] (1+)
@property(retain,readonly) NSArray* sourceWaveforms;                                    // (003A,020A) SourceWaveformSequence 3 SQ [1] (1+)
@property(retain) NSString* channelDerivationDescription;                               // (003A,020C) ChannelDerivationDescription 3 LO [1]
@property CGFloat channelSensitivity;                                                   // (003A,0210) ChannelSensitivity 1C DS [1]
@property(retain,readonly) DCMWaveformChannelSensitivityUnit* channelSensitivityUnit;   // (003A,0211) ChannelSensitivityUnitsSequence 1C SQ [1] (1)
@property CGFloat channelSensitivityCorrectionFactor;                                   // (003A,0212) ChannelSensitivityCorrectionFactor 1C DS [1]
@property CGFloat channelBaseline;                                                      // (003A,0213) ChannelBaseline 1C DS [1]
@property CGFloat channelTimeSkew;                                                      // (003A,0214) ChannelTimeSkew 1C DS [1]
@property CGFloat channelSampleSkew;                                                    // (003A,0215) ChannelSampleSkew 1C DS [1]
@property CGFloat channelOffset;                                                        // (003A,0218) ChannelOffset 3 DS [1]
@property unsigned short waveformBitsStored;                                            // (003A,021A) WaveformBitsStored 1 US [1]
@property CGFloat filterLowFrequency;                                                   // (003A,0220) FilterLowFrequency 3 DS [1]
@property CGFloat filterHighFrequency;                                                  // (003A,0221) FilterHighFrequency 3 DS [1]
@property CGFloat notchFilterFrequency;                                                 // (003A,0222) NotchFilterFrequency 3 DS [1]
@property CGFloat notchFilterBandwidth;                                                 // (003A,0223) NotchFilterBandwidth 3 DS [1]

// The value as the file writes it ("OK", "TEST DATA", "DISCONNECTED",
// "QUESTIONABLE", "INVALID", "UNCALIBRATED", "UNZEROED"). Another value
// raises NSGenericException.
- (void)setChannelStatusCS:(char*)cs;
// A copy of the bytes is kept.
- (void)setChannelMinimumValue:(void*)data length:(size_t)length;                       // (5400,0110) ChannelMinimumValue 3 OB/OW [1]
- (void)setChannelMaximumValue:(void*)data length:(size_t)length;                       // (5400,0112) ChannelMaximumValue 3 OB/OW [1]

// The least and the greatest of the channel's values, which
// -[DCMWaveformSequence getValues:] sets.
- (void)getValuesMin:(CGFloat*)min max:(CGFloat*)max;
- (void)setValuesMin:(CGFloat)min max:(CGFloat)max;

@end

@interface DCMWaveformChannelDefinition (FormerSDKOwnership)
// The definition has one channel source and one sensitivity unit: asking for
// a second raises NSGenericException.
- (DCMWaveformChannelSource*)newChannelSource NS_RETURNS_NOT_RETAINED; // 1
- (DCMWaveformChannelSourceModifier*)newChannelSourceModifier NS_RETURNS_NOT_RETAINED;
- (DCMWaveformSourceWaveform*)newSourceWaveform NS_RETURNS_NOT_RETAINED;
- (DCMWaveformChannelSensitivityUnit*)newChannelSensitivityUnit NS_RETURNS_NOT_RETAINED; // 1
@end

typedef enum {
    DCMMappingResourceDCMR, // DICOM Content Mapping Resource
    DCMMappingResourceSDM // SNOMED DICOM Microglossary (Retired)
} DCMMappingResource;

typedef enum {
    DCMContextGroupExtensionFlagY,
    DCMContextGroupExtensionFlagN
} DCMContextGroupExtensionFlag;

@interface DCMCodeSequenceMacro : NSObject

@property(retain) NSString* codeValue;                              // (0008,0100) CodeValue 1 SH [1]
@property(retain) NSString* codingSchemeDesignator;                 // (0008,0102) CodingSchemeDesignator 1 SH [1]
@property(retain) NSString* codingSchemeVersion;                    // (0008,0103) CodingSchemeVersion 1C SH [1]
@property(retain) NSString* codeMeaning;                            // (0008,0104) CodeMeaning 1  LO [1]
@property(retain) NSString* contextIdentifier;                      // (0008,010F) ContextIdentifier 3 CS [1]
@property(retain) NSString* contextUID;                             // (0008,0117) ContextUID 3 UI [1]
@property DCMMappingResource mappingResource;                       // (0008,0105) MappingResource 1C CS [1]
@property(retain) NSDate* contextGroupVersion;                      // (0008,0106) ContextGroupVersion 1C DT [1]
@property DCMContextGroupExtensionFlag contextGroupExtensionFlag;   // (0008,010B) ContextGroupExtensionFlag 3 CS [1]
@property(retain) NSDate* contextGroupLocalVersion;                 // (0008,0107) ContextGroupLocalVersion 1C DT [1]
@property(retain) NSString* contextGroupExtensionCreatorUID;        // (0008,010D) ContextGroupExtensionCreatorUID 1C UI [1]

// The value as the file writes it ("DCMR", "SDM"; "Y", "N"). Another value
// raises NSGenericException.
- (void)setMappingResourceCS:(char*)cs;
- (void)setContextGroupExtensionFlagCS:(char*)cs;

@end

@interface DCMSOPInstanceReferenceMacro : NSObject

@property(retain) NSString* referencedSOPClassUID;      // (0008,1150) ReferencedSOPClassUID 1 UI [1]
@property(retain) NSString* referencedSOPInstanceUID;   // (0008,1155) ReferencedSOPInstanceUID 1 UI [1]

@end

@interface DCMWaveformChannelSource : DCMCodeSequenceMacro

@end

@interface DCMWaveformChannelSourceModifier : DCMCodeSequenceMacro

@end

@interface DCMWaveformSourceWaveform : DCMSOPInstanceReferenceMacro

@property unsigned short referencedWaveformChannels; // (0040,A0B0) ReferencedWaveformChannels 1 US [2-2n]

@end

@interface DCMWaveformChannelSensitivityUnit : DCMCodeSequenceMacro

@end

#ifdef __cplusplus
}
#endif
