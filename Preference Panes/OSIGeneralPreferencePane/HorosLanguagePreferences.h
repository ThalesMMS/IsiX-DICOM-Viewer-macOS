#import <Foundation/Foundation.h>

static inline NSString *HorosLanguageIdentifier(NSString *localization)
{
    NSString *identifier = [NSLocale canonicalLanguageIdentifierFromString:localization];
    NSDictionary *components = [NSLocale componentsFromLocaleIdentifier:identifier];
    NSString *language = components[NSLocaleLanguageCode];
    NSString *script = components[NSLocaleScriptCode];
    NSString *country = components[NSLocaleCountryCode];
    // Match the region-independent packaged languages without collapsing
    // Brazilian/European Portuguese or Simplified/Traditional Chinese.
    if ([@[@"en", @"es", @"fr", @"de", @"ko", @"hi", @"ar", @"ru"] containsObject:language])
        return language;
    if ([language isEqualToString:@"zh"] &&
        ([script isEqualToString:@"Hans"] || (!script.length && [country isEqualToString:@"CN"])))
        return @"zh-Hans";
    return identifier;
}

static inline NSMutableArray *HorosLanguageRows(NSBundle *bundle, NSUserDefaults *defaults)
{
    id enabled = [defaults objectForKey:@"HorosEnabledLanguages"];
    if (![enabled isKindOfClass:NSArray.class]) enabled = nil;
    if (enabled) {
        NSMutableArray *identifiers = [NSMutableArray array];
        for (id value in enabled)
            if ([value isKindOfClass:NSString.class]) [identifiers addObject:HorosLanguageIdentifier(value)];
        enabled = identifiers;
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *localization in [bundle.localizations sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        if ([localization isEqualToString:@"Base"]) continue;
        NSString *identifier = HorosLanguageIdentifier(localization);
        NSString *name = [NSLocale.currentLocale displayNameForKey:NSLocaleIdentifier value:identifier] ?: localization;
        [rows addObject:[NSMutableDictionary dictionaryWithDictionary:
            @{@"foldername":localization, @"language":name, @"active":@(!enabled || [enabled containsObject:identifier])}]];
    }
    return rows;
}

static inline void HorosApplyLanguageRows(NSArray *rows, NSUserDefaults *defaults)
{
    if (!rows.count) return;
    NSMutableArray *selected = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSString *identifier = HorosLanguageIdentifier([row objectForKey:@"foldername"]);
        if ([[row objectForKey:@"active"] boolValue] && identifier.length && ![selected containsObject:identifier])
            [selected addObject:identifier];
    }
    if (!selected.count) [selected addObject:HorosLanguageIdentifier([rows[0] objectForKey:@"foldername"])];
    // Leaving an untouched pane must preserve a language chosen in macOS Settings.
    if (selected.count == rows.count) {
        if ([defaults objectForKey:@"HorosEnabledLanguages"]) {
            [defaults removeObjectForKey:@"HorosEnabledLanguages"];
            [defaults removeObjectForKey:@"AppleLanguages"];
        }
        return;
    }
    NSArray *systemLanguages = [[defaults persistentDomainForName:NSGlobalDomain] objectForKey:@"AppleLanguages"];
    if (![systemLanguages isKindOfClass:NSArray.class]) systemLanguages = NSLocale.preferredLanguages;
    NSArray *preferred = [NSBundle preferredLocalizationsFromArray:selected forPreferences:systemLanguages];
    NSMutableArray *ordered = [NSMutableArray arrayWithArray:preferred];
    for (NSString *identifier in selected) if (![ordered containsObject:identifier]) [ordered addObject:identifier];
    [defaults setObject:selected forKey:@"HorosEnabledLanguages"];
    [defaults setObject:ordered forKey:@"AppleLanguages"];
}
