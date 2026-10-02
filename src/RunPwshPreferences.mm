#import "RunPwshPreferences.h"

static NSString *const kPrefsFileName = @"runpwsh-plugin-prefs.json";
static NSString *const kKeyPanelWasVisible = @"panelWasVisible";

@implementation RunPwshPreferences {
    NSString *_path;
    BOOL _panelWasVisible;
    NSMutableDictionary *_extra;   // keys this version does not know, written back unchanged
}

- (instancetype)initWithConfigDirectory:(NSString *)dir {
    if ((self = [super init])) {
        _extra = [NSMutableDictionary dictionary];
        if (dir.length > 0) {
            _path = [dir stringByAppendingPathComponent:kPrefsFileName];
            NSData *data = [NSData dataWithContentsOfFile:_path];
            id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([obj isKindOfClass:[NSDictionary class]]) {
                [_extra addEntriesFromDictionary:obj];
                id v = _extra[kKeyPanelWasVisible];
                [_extra removeObjectForKey:kKeyPanelWasVisible];
                // Only a real JSON boolean/number counts; a string like "yes" is ignored.
                if ([v isKindOfClass:[NSNumber class]]) _panelWasVisible = [v boolValue];
            }
        }
    }
    return self;
}

- (BOOL)panelWasVisible { return _panelWasVisible; }

- (void)setPanelWasVisible:(BOOL)visible {
    if (visible == _panelWasVisible && [[NSFileManager defaultManager] fileExistsAtPath:_path ?: @""]) return;
    _panelWasVisible = visible;
    [self save];
}

- (void)save {
    if (!_path) return;
    NSString *dir = [_path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *d = [_extra mutableCopy];
    d[kKeyPanelWasVisible] = @(_panelWasVisible);
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
    if (!data || ![data writeToFile:_path options:NSDataWritingAtomic error:nil]) {
        NSLog(@"[RunPwsh plugin] Failed to write prefs to %@", _path);
    }
}

@end
