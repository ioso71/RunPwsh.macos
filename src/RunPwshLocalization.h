/*
 * RunPwshLocalization.h — tiny German/English string helper for the RunPwsh
 * plugin's own UI text (menu items, tooltips, buttons, dialogs).
 *
 * Same rationale and mechanism as FinderLocalization (see the Finder
 * plugin): there is no working plugin-ABI localization hook on macOS
 * (NPPN_NATIVELANGCHANGED / NPPM_GETNATIVELANGFILENAME are declared in
 * NppPluginInterfaceMac.h but never wired up in NppPluginManager.mm — same
 * situation as the FuncItem._pShKey shortcut limitation). So instead of
 * building a second, independent language switcher, this reads the *same*
 * NSUserDefaults key the host's own NppLocalizer uses ("language", plain
 * string values like "german", "french", …) — safe to do since a plugin
 * bundle runs in-process with the host, sharing its defaults domain.
 *
 * The host posts "NPPLocalizationChanged" (NSNotificationCenter, default
 * center) whenever the user switches language at runtime; we piggy-back on
 * that instead of inventing our own notification.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RunPwshLocalization : NSObject

/// YES unless the host's "language" preference is explicitly "german" (case-
/// insensitive). Absent/unset defaults to English, matching NppLocalizer's
/// own default — this plugin only ships German + English text, so anything
/// that isn't German falls back to English rather than a third,
/// untranslated state.
+ (BOOL)isEnglish;

/// Picks the German or English variant based on -isEnglish.
+ (NSString *)pick:(NSString *)de en:(NSString *)en;

/// Registers `block` to run whenever the host's language changes at runtime
/// (posts of "NPPLocalizationChanged"). Returns an opaque observer token the
/// caller doesn't need to keep — matches this plugin's singleton-controller
/// lifetime (never torn down before NPPN_BEFORESHUTDOWN).
+ (void)observeLanguageChangesWithBlock:(void (^)(void))block;

@end

/// Shorthand: `RPLoc(@"Deutscher Text", @"English text")`.
///
/// NB: the macro parameter names deliberately avoid "en" — the method's
/// second selector keyword is also literally "en:", and the C preprocessor
/// does plain token substitution with no awareness of Objective-C selector
/// syntax. A parameter named "en" would also replace the "en" inside the
/// "en:" keyword itself, corrupting the expansion (this exact bug shipped
/// once in the Finder plugin and broke every FDLoc(...) call site — see its
/// CHANGELOG entry 1.2.1 — so this file uses deText/enText from the start).
#define RPLoc(deText, enText) [RunPwshLocalization pick:(deText) en:(enText)]

NS_ASSUME_NONNULL_END
