#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Tiny JSON-file-backed preferences store (same approach as the Finder
/// plugin's FinderPreferences): remembers whether the panel was open, so a
/// closed panel stays closed at the next launch and an open one is reopened.
@interface RunPwshPreferences : NSObject

/// Loads `<dir>/runpwsh-plugin-prefs.json` if it exists. `dir` is created when
/// missing. Call once, early (NPPM_GETPLUGINSCONFIGDIR). A missing or corrupt
/// file leaves the defaults in place.
- (instancetype)initWithConfigDirectory:(NSString *)dir NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Whether the panel was open the last time the user changed it. Default NO:
/// the panel is not opened on its own on first launch.
@property (nonatomic, readonly) BOOL panelWasVisible;

/// Stores the new value and writes the file immediately (a crash or a forced
/// quit must not lose it). Writing an unchanged value does nothing.
- (void)setPanelWasVisible:(BOOL)visible;

@end

NS_ASSUME_NONNULL_END
