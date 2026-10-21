//
//  ExternalPanelViewController.h
//  SPARK iOS External Panel
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ExternalPanelViewController : UIViewController <WKScriptMessageHandler, WKNavigationDelegate>

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy, nullable) NSString *currentContainerPath;

// Singleton or convenience initialization
+ (instancetype)sharedPanel;

// Container operations
- (BOOL)resolveGameContainerForBundle:(NSString *)bundleIdentifier;
- (void)applyExternalPatchWithOptions:(NSDictionary *)options;
- (void)restoreOriginalGameFiles;
- (void)resetGuestAccount;
- (void)purgeTraceLogs;
- (void)launchGameWithScheme:(NSString *)urlScheme;
- (void)runDiagnosticsTest;

// Hitbox patchers
// scale: 1.0 = original, 1.5–4.5 = enlarged. Two-mode: in-proc vm_protect
// write (injected) or cross-proc mach_vm_write (task_for_pid), with
// contentcache plist fallback when task port is unavailable.
- (void)applyHitboxPatch:(float)scale;
- (void)stageContentcacheHitboxPatch:(float)scale;

@end

NS_ASSUME_NONNULL_END
