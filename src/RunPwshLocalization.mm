#import "RunPwshLocalization.h"

// Matches the host's own kPrefLanguage constant value (src/NppLocalizer.mm:
// `NSString * const kPrefLanguage = @"language";`). Not linked against the
// host — just the same NSUserDefaults key by string literal, which is all
// that's needed since plugin and host share one process/defaults domain.
static NSString * const kHostLanguagePrefKey = @"language";

@implementation RunPwshLocalization

+ (BOOL)isEnglish {
    NSString *lang = [[NSUserDefaults standardUserDefaults] stringForKey:kHostLanguagePrefKey];
    if (lang.length == 0) return YES;
    return ![lang.lowercaseString isEqualToString:@"german"];
}

+ (NSString *)pick:(NSString *)de en:(NSString *)en {
    return [self isEnglish] ? en : de;
}

+ (void)observeLanguageChangesWithBlock:(void (^)(void))block {
    if (!block) return;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"NPPLocalizationChanged"
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification *note) {
        (void)note;
        block();
    }];
}

@end
