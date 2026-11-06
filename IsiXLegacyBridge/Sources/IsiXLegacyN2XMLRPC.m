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
// XML-RPC values (http://xmlrpc.com/spec.md) to and from their XML, for the
// plugins that read the request document of OsirixXMLRPCMessageNotification
// or answered it with one.

#import "IsiXLegacyBridgeInternal.h"

@implementation IsiXLegacyN2XMLRPC

static NSDateFormatter *IsiXLegacyXMLRPCDateFormatter(void)
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier: @"en_US_POSIX"];
    formatter.calendar = [NSCalendar calendarWithIdentifier: NSCalendarIdentifierGregorian];
    formatter.dateFormat = @"yyyyMMdd'T'HH:mm:ss";
    return formatter;
}

static NSString *IsiXLegacyXMLEscaped(NSString *text)
{
    NSMutableString *escaped = [NSMutableString stringWithString: text ?: @""];
    [escaped replaceOccurrencesOfString: @"&" withString: @"&amp;" options: 0 range: NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString: @"<" withString: @"&lt;" options: 0 range: NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString: @">" withString: @"&gt;" options: 0 range: NSMakeRange(0, escaped.length)];
    return escaped;
}

+ (NSObject*) ParseElement: (NSXMLNode*) n
{
    if (![n isKindOfClass: [NSXMLElement class]]) return n.stringValue;
    NSXMLElement *element = (NSXMLElement*) n;
    if ([element.name isEqualToString: @"value"])
    {
        NSXMLElement *typed = nil;
        for (NSXMLNode *child in element.children)
            if (child.kind == NSXMLElementKind) { typed = (NSXMLElement*) child; break; }
        // A value without a type is a string.
        return typed ? [self ParseElement: typed] : (element.stringValue ?: @"");
    }
    NSString *type = element.name;
    NSString *text = element.stringValue ?: @"";
    if ([type isEqualToString: @"string"]) return text;
    if ([type isEqualToString: @"i4"] || [type isEqualToString: @"int"] || [type isEqualToString: @"i8"])
        return @([text longLongValue]);
    if ([type isEqualToString: @"double"]) return @([text doubleValue]);
    if ([type isEqualToString: @"boolean"]) return @([text intValue] != 0);
    if ([type isEqualToString: @"dateTime.iso8601"]) return [IsiXLegacyXMLRPCDateFormatter() dateFromString: text] ?: text;
    if ([type isEqualToString: @"base64"])
        return [[NSData alloc] initWithBase64EncodedString: text options: NSDataBase64DecodingIgnoreUnknownCharacters] ?: [NSData data];
    if ([type isEqualToString: @"nil"]) return [NSNull null];
    if ([type isEqualToString: @"array"])
    {
        NSMutableArray *array = [NSMutableArray array];
        for (NSXMLNode *value in [element nodesForXPath: @"data/value" error: NULL]) [array addObject: [self ParseElement: value]];
        return array;
    }
    if ([type isEqualToString: @"struct"])
    {
        NSMutableDictionary *members = [NSMutableDictionary dictionary];
        for (NSXMLElement *member in [element elementsForName: @"member"])
        {
            NSString *name = [[member elementsForName: @"name"] firstObject].stringValue;
            NSXMLElement *value = [[member elementsForName: @"value"] firstObject];
            if (name && value) members[name] = [self ParseElement: value];
        }
        return members;
    }
    return text;
}

+ (NSString*) FormatElement: (NSObject*) o
{
    return [self FormatElement: o options: 0];
}

+ (NSString*) FormatElement: (NSObject*) o options: (NSUInteger) options
{
    if (!o || [o isKindOfClass: [NSNull class]]) return @"<value><nil/></value>";
    if ([o isKindOfClass: [NSString class]])
        return (options & N2XMLRPCDontSpecifyStringTypeOptionMask)
            ? [NSString stringWithFormat: @"<value>%@</value>", IsiXLegacyXMLEscaped((NSString*) o)]
            : [NSString stringWithFormat: @"<value><string>%@</string></value>", IsiXLegacyXMLEscaped((NSString*) o)];
    if ([o isKindOfClass: [NSNumber class]])
    {
        NSNumber *number = (NSNumber*) o;
        if (CFGetTypeID((__bridge CFTypeRef) number) == CFBooleanGetTypeID())
            return [NSString stringWithFormat: @"<value><boolean>%d</boolean></value>", number.boolValue ? 1 : 0];
        const char *type = number.objCType;
        if (strcmp(type, @encode(double)) == 0 || strcmp(type, @encode(float)) == 0)
            return [NSString stringWithFormat: @"<value><double>%.17g</double></value>", number.doubleValue];
        return [NSString stringWithFormat: @"<value><int>%lld</int></value>", number.longLongValue];
    }
    if ([o isKindOfClass: [NSDate class]])
        return [NSString stringWithFormat: @"<value><dateTime.iso8601>%@</dateTime.iso8601></value>",
                [IsiXLegacyXMLRPCDateFormatter() stringFromDate: (NSDate*) o]];
    if ([o isKindOfClass: [NSData class]])
        return [NSString stringWithFormat: @"<value><base64>%@</base64></value>", [(NSData*) o base64EncodedStringWithOptions: 0]];
    if ([o isKindOfClass: [NSArray class]])
    {
        NSMutableString *array = [NSMutableString stringWithString: @"<value><array><data>"];
        for (id item in (NSArray*) o) [array appendString: [self FormatElement: item options: options]];
        [array appendString: @"</data></array></value>"];
        return array;
    }
    if ([o isKindOfClass: [NSDictionary class]])
    {
        NSMutableString *members = [NSMutableString stringWithString: @"<value><struct>"];
        NSDictionary *dictionary = (NSDictionary*) o;
        for (id key in dictionary)
            [members appendFormat: @"<member><name>%@</name>%@</member>", IsiXLegacyXMLEscaped([key description]),
                                   [self FormatElement: dictionary[key] options: options]];
        [members appendString: @"</struct></value>"];
        return members;
    }
    return [self FormatElement: o.description options: options];
}

+ (NSString*) requestWithMethodName: (NSString*) methodName arguments: (NSArray*) args
{
    NSMutableString *request = [NSMutableString stringWithFormat: @"<?xml version=\"1.0\"?><methodCall><methodName>%@</methodName><params>",
                                IsiXLegacyXMLEscaped(methodName)];
    for (id argument in args) [request appendFormat: @"<param>%@</param>", [self FormatElement: argument]];
    [request appendString: @"</params></methodCall>"];
    return request;
}

+ (NSString*) responseWithValue: (id) value
{
    return [self responseWithValue: value options: 0];
}

+ (NSString*) responseWithValue: (id) value options: (NSUInteger) options
{
    return [NSString stringWithFormat: @"<?xml version=\"1.0\"?><methodResponse><params><param>%@</param></params></methodResponse>",
            [self FormatElement: value options: options]];
}

@end
