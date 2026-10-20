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

@end

NS_ASSUME_NONNULL_END
