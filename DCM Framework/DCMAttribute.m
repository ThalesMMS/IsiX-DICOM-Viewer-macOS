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

#import "DCMAttribute.h"
#import "DCM.h"

@implementation DCMAttribute

@synthesize vr = _vr;
@synthesize values = _values;
@synthesize attrTag = _tag;
@synthesize characterSet;

+ (id)attributeWithAttribute:(DCMAttribute *)attr{
	return [[[DCMAttribute alloc] initWithAttribute:attr] autorelease];
}

+ (id)attributeWithAttributeTag:(DCMAttributeTag *)tag{
	return [[[DCMAttribute alloc] initWithAttributeTag:(DCMAttributeTag *)tag] autorelease];
}
+ (id)attributeWithAttributeTag:(DCMAttributeTag *)tag  vr:(NSString *)vr{
	return [[[DCMAttribute alloc] initWithAttributeTag:tag  vr:vr] autorelease];
}
+ (id)attributeWithAttributeTag:(DCMAttributeTag *)tag  vr:(NSString *)vr  values:(NSMutableArray *)values{
	return [[[DCMAttribute alloc] initWithAttributeTag:tag  vr:vr  values:values] autorelease];
}

- (id)initWithAttributeTag:(DCMAttributeTag *)tag{
	return [self initWithAttributeTag:tag  vr:nil];

}

- (id)initWithAttributeTag:(DCMAttributeTag *)tag  vr:(NSString *)vr{
	if (self = [super init]) {
			_tag = [tag retain];
			_valueLength =0;
			_values = [[NSMutableArray array] retain];
		if (vr != nil)
			_vr = [vr retain];
		else
			_vr = [[tag vr] retain];
			
		_dataPtr = nil;

	}

	return self;
}

- (id)initWithAttributeTag:(DCMAttributeTag *)tag  vr:(NSString *)vr  values:(NSMutableArray *)values{
	if (self = [super init]) {
		_tag = [tag retain];
		_valueLength =0;
		_values = [values retain];
		if (vr != nil)
			_vr = [vr retain];
		else
			_vr = [[tag vr] retain];
		_dataPtr = nil;
	}
	
	return self;
}

- (id)initWithAttribute:(DCMAttribute *)attr{
	if (self = [super init]) {
		_tag = [[DCMAttributeTag  alloc] initWithTag:(DCMAttributeTag *)attr.attrTag];
		_values = [attr.values mutableCopy];
		_vr = [attr.vr copy];
		_dataPtr = nil;
	}
	return self;
}

- (id) initWithAttributeTag:(DCMAttributeTag *)tag 
			vr:(NSString *)vr 
			length:(long) vl 
			dataPtr: (unsigned char *)dataPtr{
	if (self = [super init]) {
		_tag = [tag retain];
		_valueLength = vl;
		if (vr != nil)
			_vr = [vr retain];
		else
			_vr = [tag.vr retain];
		_dataPtr = dataPtr;
	}

	return self;
}
	
- (id)copyWithZone:(NSZone *)zone{
	return [[DCMAttribute allocWithZone:zone] initWithAttribute:self];
}

- (void)dealloc
{
	[characterSet release];
	[_vr release];
	[_tag release];
	[_values release];
	//if (_dataPtr != nil)
	//	free(_dataPtr);
	[super dealloc];
}
		
- (int)group
{
	return _tag.group;
}

- (int)element
{
	return _tag.element;
}

- (long)valueLength
{
	const char *chars = [_vr UTF8String];
	int vr = chars[0]<<8 | chars[1];
	long length = 0;
	int vm = self.valueMultiplicity;
	NSString *string;
	switch (vr) {
		// unsigned Short
		case DCM_US:   //unsigned short
		case DCM_SS:	//signed short
			length = vm * 2;
			break;
		case DCM_DA:	//Date String yyyymmdd 8bytes old format was yyyy.mm.dd for 10 bytes. May need to implement old format
			if ([_values count] && 
				[[_values objectAtIndex:0] isKindOfClass:[DCMCalendarDate class]] && 
				[[_values objectAtIndex:0] isQuery]) {
				string = [_values componentsJoinedByString:@"\\"];
				length = (long) [string length];
			}	
			else
				length = vm * 8 + (vm - 1);  //add (vm - 1) for between values.

                break;
		case DCM_TM:
			if ([_values count] && 
				[[_values objectAtIndex:0] isKindOfClass:[DCMCalendarDate class]] && 
				[[_values objectAtIndex:0] isQuery]) {
				string = [_values componentsJoinedByString:@"\\"];
				length = (long) [string length];
			}	
			else
			//length is 13 if we use microseconds
				length = vm * 13 + (vm - 1);
                break;
		case DCM_DT:
			if ([_values count] && 
				[[_values objectAtIndex:0] isKindOfClass:[DCMCalendarDate class]] && 
				[[_values objectAtIndex:0] isQuery]) {
				string = [_values componentsJoinedByString:@"\\"];
				length = (long) [string length];
			}	
			else
		//Date Time YYYYMMDDHHMMSS.FFFFFF&ZZZZ FFFFFF= fractional Sec. ZZZZ=offset from Hr and min offset from universal time
                // By default, we don't add the timezone = 21
				length = vm * 21 + (vm - 1);
                break;
				
		//case DCM_SQ:	//Sequence of items
		//		//shouldn't get here
        //        break;
		
		case DCM_UN:	//unknown
		case DCM_OB:	//other Byte byte string not little/big endian sensitive
		case DCM_OW:	//other word 16bit word
				length = 0;
				for ( NSData *data in _values )
					length += (long) [data length];
				//length = [(NSData *)[_values objectAtIndex:0] length];
                break;
		case DCM_AT:	//Attribute Tag 16bit unsigned integer
		case DCM_UL:	//unsigned Long
		case DCM_SL:	//signed long
		case DCM_FL:	//floating point Single 4 bytes fixed
			length = vm * 4;
			if (length%2)
			 length++;
			break;
		case DCM_FD:	//double floating point 8 bytes fixed
			length = vm * 8;
			break;           
			
		case DCM_AE:	//Application Entity  String 16bytes max
		case DCM_AS:	//Age String Format mmmM,dddD,nnnY ie 018Y
		case DCM_CS:	//Code String   !6 byte max
		case DCM_DS:	//Decimal String  representing floating point number 16 byte max
				  
		case DCM_IS:	//Integer String 12 bytes max
		case DCM_LO:	//Character String 64 char max
		case DCM_LT:	//Long Text 10240 char Max
		case DCM_PN:	//Person Name string
		case DCM_SH:	//short string
		case DCM_ST:	//short Text 1024 char max
		case DCM_UI:    //String for UID
		case DCM_UT:	//unlimited text
		case DCM_QQ:
					//length may be different with different Character Sets
			string = [_values componentsJoinedByString:@"\\"];
			
			if( characterSet == nil)
				characterSet = [[DCMCharacterSet alloc] initWithCode: @"ISO_IR 100"];
			
			length = (long) [string lengthOfBytesUsingEncoding: [characterSet encoding]];
			break;
		default: 
			length = (long) [(NSData *)[_values objectAtIndex:0] length];
			break;
		}
		
	if (length < 0)
		length = 0;
		
	return length;
}

- (long)paddedLength {

	long paddedLength = self.valueLength;
	if (paddedLength%2)
		paddedLength++;
	return paddedLength;
}

- (int) valueMultiplicity {
	return (int) [_values count];
}

- (NSString *)vrStringValue{
	return _tag.stringValue;
}

- (long)paddedValueLength{
	return 0;
}

- (void)addValue:(id)value{
	[_values addObject:value];
}

- (id)value
{
	if ([_values count] > 0)
		return [_values objectAtIndex:0];
	
	return nil;
}

- (NSString *)valueAsString{
	return nil;
}

- (NSString *)valuesAsString{
	if ([_values count] > 0)
		//return [_values componentsJoinedByString:@"\\"];
		return [_values description];
	else
		return @"";
}

- (NSString *)description{
	if (self.valueLength < 100)
		return  [NSString stringWithFormat:@"%@\t %@\t vl:%d\t vm:%d\t %@", _tag.description, _tag.vr, (int)self.valueLength, self.valueMultiplicity, [self valuesAsString]];
	return  [NSString stringWithFormat:@"%@\t vl:%d\t vm:%d", _tag.description, (int) self.valueLength, self.valueMultiplicity];
}
	
- (NSString *)readableDescription{
	if (self.valueLength < 100)
		return  [NSString stringWithFormat:@"%@ : %@", _tag.readableDescription, [_values componentsJoinedByString:@","]];
	return @"";
}

- (void)swapBytes:(NSMutableData *)data{
}

- (NSXMLNode *)xmlNode{
	NSXMLNode *myNode;
	NSXMLNode *groupAttr = [NSXMLNode attributeWithName:@"group" stringValue:[NSString stringWithFormat:@"%04x", self.attrTag.group]];
	NSXMLNode *elementAttr = [NSXMLNode attributeWithName:@"element" stringValue:[NSString stringWithFormat:@"%04x", self.attrTag.element]];
	NSXMLNode *tagNode = [NSXMLNode attributeWithName:@"attributeTag" stringValue: self.attrTag.stringValue];
	NSXMLNode *vrAttr = [NSXMLNode attributeWithName:@"vr" stringValue: self.attrTag.vr];
	NSArray *attrs = [NSArray arrayWithObjects:groupAttr,elementAttr, vrAttr,tagNode, nil];
	NSMutableString *aName = [NSMutableString stringWithString: self.attrTag.name];
	[aName replaceOccurrencesOfString:@"/" withString:@"_" options:0 range:NSMakeRange(0, [aName length])];
	NSMutableArray *elements = [NSMutableArray array];
	int i = 0;
    
	for ( id value in self.values ) {
		NSString *string = nil;
		if ([value isKindOfClass:[NSString class]])
			string = value;
		else if ([value isKindOfClass:[NSNumber class]])
			string = [value stringValue];
		else if ([value isKindOfClass:[NSDate class]])
			string = [value description];
		else if ([value isKindOfClass:[NSData class]])
        {
            @try {
                
                BOOL subData = NO;
                if( [value length] >= 256)
                {
                    value = [value subdataWithRange: NSMakeRange( 0, 256)];
                    subData = YES;
                }
                
                if( [value length] <= 256 && [value length] > 0)
                {
                    BOOL containStrangeCharacter = NO;
                    unsigned char *c = (unsigned char*) [value bytes];
                    
                    for( long x = 0; x < [value length]-1; x++)
                    {
                        if( c[ x] < 32 || c[ x] > 125)
                        {
                            containStrangeCharacter = YES;
                            break;
                        }
                    }
                    
                    if( containStrangeCharacter == NO)
                        string = [[[NSString alloc] initWithBytes: [value bytes] length: [value length] encoding: NSASCIIStringEncoding] autorelease];
                    else
                    {
                        NSUInteger capacity = [value length] * 2;
                        NSMutableString *stringBuffer = [NSMutableString stringWithCapacity:capacity];
                        [stringBuffer appendString: @"0x"];
                        const unsigned char *dataBuffer = [value bytes];
                        for (long x=0; x<[value length]; x++) {
                            [stringBuffer appendFormat:@"%02lX", (unsigned long)dataBuffer[x]];
                        }
                        string = stringBuffer;
                    }
                }
                
                if( subData)
                    string = [string stringByAppendingString: @"..."];
            }
            @catch (NSException *exception) {
                string = @"Unknown";
            }
        }
        else
			string = @"Unknown";
        
        if( string.length == 0)
            string = @"";
        
		NSXMLNode *number = [NSXMLNode attributeWithName:@"number" stringValue:[NSString stringWithFormat:@"%d",i++]];		
		NSXMLNode *element = [NSXMLNode elementWithName:@"value" children:nil attributes:[NSArray arrayWithObject:number]];
		
        if( string) {
			[element setStringValue:string];
			[elements addObject:element];
		}
	}
    
	myNode = [NSXMLNode elementWithName:aName children:elements attributes:attrs];
    
	return myNode;
}

@end
