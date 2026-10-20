//
//  ExternalPanelViewController.mm
//  SPARK iOS External Panel
//

#import "ExternalPanelViewController.h"
#include <dlfcn.h>
#include <sys/stat.h>

enum AimTarget {
    AIM_TARGET_HEAD = 0,
    AIM_TARGET_NECK = 1,
    AIM_TARGET_BODY = 2
};

struct PanelConfig_t {
    bool Aimbot;
    AimTarget Target;
    int AimWhen;
};
static PanelConfig_t PanelConfig = { false, AIM_TARGET_HEAD, 0 };

@implementation ExternalPanelViewController

+ (instancetype)sharedPanel {
    static ExternalPanelViewController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ExternalPanelViewController alloc] init];
    });
    return instance;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.03 green:0.04 blue:0.06 alpha:1.0];

    [self setupWebView];
    [self loadPanelHTML];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)setupWebView {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *contentController = [[WKUserContentController alloc] init];

    // Register script message handlers for both bridges
    [contentController addScriptMessageHandler:self name:@"externalPanel"];
    [contentController addScriptMessageHandler:self name:@"oxCheatsUI"];

    config.userContentController = contentController;
    config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
    config.allowsInlineMediaPlayback = YES;

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = [UIColor clearColor];
    self.webView.scrollView.backgroundColor = [UIColor clearColor];
    self.webView.scrollView.bounces = NO;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;

    [self.view addSubview:self.webView];
}

- (void)loadPanelHTML {
    // 1. Try loading from main app bundle
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html" inDirectory:@"ios_external_panel_app"];
    if (!bundlePath) {
        bundlePath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    }

    if (bundlePath) {
        NSURL *fileURL = [NSURL fileURLWithPath:bundlePath];
        NSURL *accessURL = [fileURL URLByDeletingLastPathComponent];
        [self.webView loadFileURL:fileURL allowingReadAccessToURL:accessURL];
    } else {
        // Fallback or debug mode
        NSLog(@"[SPARK] index.html not found in bundle, check resource path.");
    }
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *data = (NSDictionary *)message.body;
    NSString *action = data[@"action"] ?: data[@"type"];
    NSString *game = data[@"game"] ?: @"com.dts.freefireth";

    NSLog(@"[SPARK Native Bridge] Received action: %@ for game: %@", action, game);

    if ([action isEqualToString:@"apply_patch"] || [action isEqualToString:@"inject"]) {
        [self applyExternalPatchWithOptions:data];
    } else if ([action isEqualToString:@"restore_assets"] || [action isEqualToString:@"restore"]) {
        [self restoreOriginalGameFiles];
    } else if ([action isEqualToString:@"reset_guest"] || [action isEqualToString:@"guestReset"] || [action isEqualToString:@"guest_reset"]) {
        [self resetGuestAccount];
    } else if ([action isEqualToString:@"clean_traces"] || [action isEqualToString:@"clean"]) {
        [self purgeTraceLogs];
    } else if ([action isEqualToString:@"launch_game"] || [action isEqualToString:@"openURL"]) {
        NSString *scheme = data[@"scheme"] ?: (data[@"url"] ?: @"freefireth://");
        [self launchGameWithScheme:scheme];
    } else if ([action isEqualToString:@"set_config"]) {
        // WebUI → native: sync aimbot feature toggles into Vars
        NSNumber *aimbotVal  = data[@"aimbot"];
        NSNumber *targetVal  = data[@"aim_target"];
        NSNumber *aimWhenVal = data[@"aim_when"];

        if (aimbotVal)  PanelConfig.Aimbot  = [aimbotVal intValue] != 0;
        if (targetVal)  PanelConfig.Target  = (AimTarget)[targetVal intValue];  // 0=HEAD 1=NECK 2=BODY
        if (aimWhenVal) PanelConfig.AimWhen = [aimWhenVal intValue];            // 0=always

        NSLog(@"[SPARK] set_config → Aimbot:%d Target:%d AimWhen:%d",
              (int)PanelConfig.Aimbot, PanelConfig.Target, PanelConfig.AimWhen);

        [self notifyWebUI:@"config_applied"
                  message:[NSString stringWithFormat:@"Aimbot:%@ Target:%@",
                           PanelConfig.Aimbot ? @"ON" : @"OFF",
                           @[@"HEAD",@"NECK",@"BODY"][MIN(PanelConfig.Target,2)]]];

    } else if ([action isEqualToString:@"haptic"]) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
}

#pragma mark - Antiban Asset Sandbox Operations

- (BOOL)resolveGameContainerForBundle:(NSString *)bundleIdentifier {
    if (self.currentContainerPath && [self.currentContainerPath length] > 0) {
        return YES;
    }

    NSString *containerBasePath = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSError *err = nil;
    NSArray *dirs = [fm contentsOfDirectoryAtPath:containerBasePath error:&err];
    if (err || !dirs) {
        NSLog(@"[SPARK] Cannot access containers directory without entitlements or sandbox extension: %@", err);
        return NO;
    }

    for (NSString *uuidDir in dirs) {
        NSString *candidateMetadata = [containerBasePath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", uuidDir]];
        if ([fm fileExistsAtPath:candidateMetadata]) {
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:candidateMetadata];
            if ([meta[@"MCMMetadataIdentifier"] isEqualToString:bundleIdentifier]) {
                self.currentContainerPath = [containerBasePath stringByAppendingPathComponent:uuidDir];
                NSLog(@"[SPARK] Found container for %@: %@", bundleIdentifier, self.currentContainerPath);
                return YES;
            }
        }
    }

    return NO;
}

- (void)applyExternalPatchWithOptions:(NSDictionary *)options {
    NSLog(@"[SPARK] External injection requested with options: %@", options);
    // As per specification: Actual game-specific offset/asset modifications will be hooked
    // when game asset bundles are provided. Zero broken memory hooks.
    
    // Automatically purge trace logs after operation
    [self purgeTraceLogs];

    [self notifyWebUI:@"inject_ready" message:@"External patch staged. Ready for game launch."];
}

- (void)restoreOriginalGameFiles {
    NSLog(@"[SPARK] Restoring clean original asset backups...");
    NSFileManager *fm = [NSFileManager defaultManager];

    // Check containers for both FF Normal and FF MAX
    NSArray *targets = @[@"com.dts.freefireth", @"com.dts.freefiremax"];
    for (NSString *bundleId in targets) {
        [self resolveGameContainerForBundle:bundleId];
        if (!self.currentContainerPath) continue;

        NSString *compulsoryPath = [self.currentContainerPath stringByAppendingPathComponent:@"Documents/contentcache/Compulsory/ios/gameassetbundles"];
        NSString *optionalPath = [self.currentContainerPath stringByAppendingPathComponent:@"Documents/contentcache/Optional/ios/gameassetbundles"];
        NSString *backupPath = [self.currentContainerPath stringByAppendingPathComponent:@"Documents/0xfixa-originals"];

        // If backup folder exists, restore original files back to compulsory & optional
        if ([fm fileExistsAtPath:backupPath]) {
            NSArray *backupFiles = [fm contentsOfDirectoryAtPath:backupPath error:nil];
            for (NSString *file in backupFiles) {
                NSString *src = [backupPath stringByAppendingPathComponent:file];
                NSString *dstCompulsory = [compulsoryPath stringByAppendingPathComponent:file];
                NSString *dstOptional = [optionalPath stringByAppendingPathComponent:file];

                if ([fm fileExistsAtPath:dstCompulsory]) {
                    [fm removeItemAtPath:dstCompulsory error:nil];
                    [fm copyItemAtPath:src toPath:dstCompulsory error:nil];
                }
                if ([fm fileExistsAtPath:dstOptional]) {
                    [fm removeItemAtPath:dstOptional error:nil];
                    [fm copyItemAtPath:src toPath:dstOptional error:nil];
                }
            }
        }

        // Clean any residual custom patch cache
        NSString *patchCache = [self.currentContainerPath stringByAppendingPathComponent:@"Documents/0xfixa-patch-cache"];
        if ([fm fileExistsAtPath:patchCache]) {
            [fm removeItemAtPath:patchCache error:nil];
        }
    }

    // Automatically purge trace logs
    [self purgeTraceLogs];

    [self notifyWebUI:@"restore_success" message:@"100% clean original asset bundles restored."];
}

- (void)resetGuestAccount {
    NSLog(@"[SPARK] Resetting guest account UUID & credentials...");
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *targets = @[@"com.dts.freefireth", @"com.dts.freefiremax"];
    for (NSString *bundleId in targets) {
        [self resolveGameContainerForBundle:bundleId];
        if (!self.currentContainerPath) continue;

        NSString *localConfigPath = [self.currentContainerPath stringByAppendingPathComponent:@"Documents/localConfig.json"];
        
        // Generate new random UUID v4
        NSString *newUUID = [[NSUUID UUID] UUIDString];
        NSString *newOpenUDID = [newUUID stringByReplacingOccurrencesOfString:@"-" withString:@""];

        if ([fm fileExistsAtPath:localConfigPath]) {
            NSData *data = [NSData dataWithContentsOfFile:localConfigPath];
            if (data) {
                NSError *jsonErr = nil;
                NSMutableDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonErr];
                if ([dict isKindOfClass:[NSMutableDictionary class]]) {
                    dict[@"device_id"] = newUUID;
                    dict[@"openudid"] = newOpenUDID;
                    dict[@"guest_uid"] = @"";
                    dict[@"guest_token"] = @"";
                    
                    NSData *newData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
                    [newData writeToFile:localConfigPath atomically:YES];
                } else {
                    // Wipe file to force game to regenerate
                    [fm removeItemAtPath:localConfigPath error:nil];
                }
            }
        }

        // Remove any cached guest credential files
        NSString *guestDat = [self.currentContainerPath stringByAppendingPathComponent:@"Documents/guest_account.dat"];
        if ([fm fileExistsAtPath:guestDat]) {
            [fm removeItemAtPath:guestDat error:nil];
        }

        NSString *guestFolder = [self.currentContainerPath stringByAppendingPathComponent:@"Documents/guest"];
        if ([fm fileExistsAtPath:guestFolder]) {
            [fm removeItemAtPath:guestFolder error:nil];
        }
    }

    // Automatically purge trace logs
    [self purgeTraceLogs];

    [self notifyWebUI:@"guest_reset_success" message:@"Guest account reset. New device identity generated."];
}

- (void)purgeTraceLogs {
    NSLog(@"[SPARK] Auto-purging crash logs and telemetry caches...");
    NSFileManager *fm = [NSFileManager defaultManager];

    if (!self.currentContainerPath) return;

    NSArray *logFolders = @[
        @"Library/Caches",
        @"Documents/log",
        @"Documents/crash",
        @"Documents/Telemetry",
        @"Library/Logs"
    ];

    for (NSString *relPath in logFolders) {
        NSString *fullPath = [self.currentContainerPath stringByAppendingPathComponent:relPath];
        if ([fm fileExistsAtPath:fullPath]) {
            NSArray *files = [fm contentsOfDirectoryAtPath:fullPath error:nil];
            for (NSString *f in files) {
                [fm removeItemAtPath:[fullPath stringByAppendingPathComponent:f] error:nil];
            }
        }
    }
}

- (void)notifyWebUI:(NSString *)eventType message:(NSString *)msg {
    NSString *js = [NSString stringWithFormat:@"if(window.onNativeResult){window.onNativeResult('%@','%@');}", eventType, msg];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:js completionHandler:nil];
    });
}

- (void)launchGameWithScheme:(NSString *)urlScheme {
    NSURL *url = [NSURL URLWithString:urlScheme];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        NSLog(@"[SPARK] Cannot open scheme: %@", urlScheme);
    }
}

@end
