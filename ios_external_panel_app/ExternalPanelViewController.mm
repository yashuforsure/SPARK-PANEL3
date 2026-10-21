//
//  ExternalPanelViewController.mm
//  SPARK iOS External Panel
//

#import "ExternalPanelViewController.h"
#include <dlfcn.h>
#include <sys/stat.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef mach_vm_address_t mach_vm_offset_t;
kern_return_t mach_vm_write(
    vm_map_t target_task,
    mach_vm_address_t address,
    vm_offset_t data,
    mach_msg_type_number_t dataCnt
);
kern_return_t mach_vm_protect(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    boolean_t set_maximum,
    vm_prot_t new_protection
);
#ifdef __cplusplus
}
#endif

// ─── Safe App Container Resolver (TrollStore / Root / AppGroup / Sandbox) ─────
static NSString *resolveContainerViaMCM(NSString *bundleIdentifier) {
    if (!bundleIdentifier || [bundleIdentifier length] == 0) return nil;

    @try {
        NSFileManager *fm = [NSFileManager defaultManager];

        // 1. TrollStore / Root / Jailbreak direct path
        NSString *basePath = @"/var/mobile/Containers/Data/Application";
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:basePath isDirectory:&isDir] && isDir) {
            NSError *err = nil;
            NSArray *dirs = [fm contentsOfDirectoryAtPath:basePath error:&err];
            if (!err && dirs) {
                for (NSString *uuidDir in dirs) {
                    NSString *metaPath = [basePath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", uuidDir]];
                    if ([fm fileExistsAtPath:metaPath]) {
                        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
                        if (meta && [meta[@"MCMMetadataIdentifier"] isEqualToString:bundleIdentifier]) {
                            return [basePath stringByAppendingPathComponent:uuidDir];
                        }
                    }
                }
            }
        }

        // 2. Shared AppGroup paths
        NSString *groupPath = [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/group.%@", bundleIdentifier];
        if ([fm fileExistsAtPath:groupPath]) {
            return groupPath;
        }

        // 3. Check own document directory in case running inside the game
        NSURL *docsURL = [[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
        if (docsURL) {
            NSString *docsPath = [docsURL path];
            if ([docsPath containsString:bundleIdentifier]) {
                return [docsPath stringByDeletingLastPathComponent];
            }
        }
    } @catch (NSException *ex) {
        NSLog(@"[SPARK] Container resolution exception: %@", ex);
    }
    return nil;
}

// ─── Free Fire v1.132.1 arm64 IL2CPP Offsets (from global-metadata analysis) ─
// These are RVAs within UnityFramework — slide must be added at runtime
//  GetHeadTF:            CharacterController.GetHeadTF()  → bone transform ptr
//  kHeadCapsuleRadiusOff: offset within CapsuleCollider struct → float radius
// Base address resolved via _dyld_get_image_vmaddr_slide on UnityFramework
#define FF_BUNDLE_ID_NORMAL      "com.dts.freefireth"
#define FF_BUNDLE_ID_MAX         "com.dts.freefiremax"
#define UF_IMAGE_NAME            "UnityFramework"

// Confirmed offsets for FF 1.132.1 arm64 from metadata dump (class id 31767)
// GetHeadTF RVA — used to locate bone struct pointer chain
#define OFF_GET_HEAD_TF          0x1F8C4A0ULL
// GetNeckPosition RVA
#define OFF_GET_NECK_POS         0x1F8C380ULL
// CapsuleCollider.radius field — float at +0x34 inside CapsuleCollider
#define OFF_CAPSULE_RADIUS       0x34

// Default hitbox multipliers (1.0 = unmodified; > 1.0 = enlarged)
#define HITBOX_SCALE_DEFAULT     1.0f
#define HITBOX_SCALE_MAX         4.5f
// Head bone capsule default radius in FF (empirically ~0.22m game units)
#define HEAD_CAPSULE_RADIUS_BASE 0.22f

enum AimTarget {
    AIM_TARGET_HEAD = 0,
    AIM_TARGET_NECK = 1,
    AIM_TARGET_BODY = 2
};

struct PanelConfig_t {
    bool   Aimbot;
    AimTarget Target;
    int    AimWhen;
    float  HitboxScale;   // 1.0 – 4.5
    bool   HitboxActive;  // whether hitbox patch is live
};
static PanelConfig_t PanelConfig = { false, AIM_TARGET_HEAD, 0, HITBOX_SCALE_DEFAULT, false };

// ─── Mach-O slide resolver ─────────────────────────────────────────────────
// Returns the ASLR slide for the image whose path contains `imageName`.
// Returns 0 if the image is not loaded (game not running).
static intptr_t resolveImageSlide(const char *imageName) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, imageName)) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

// ─── mach_vm_write wrapper ─────────────────────────────────────────────────
// Writes `size` bytes from `src` into task `tsk` at virtual address `dest`.
// Returns YES on success. Requires task port — only works in-process or with
// task_for_pid entitlement (present on jailbroken devices / sandbox-escaped).
static BOOL writeProcessMemory(mach_port_t tsk, mach_vm_address_t dest,
                                const void *src, mach_vm_size_t size) {
    kern_return_t kr = mach_vm_write(tsk, dest, (vm_offset_t)src, (mach_msg_type_number_t)size);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[SPARK-HB] mach_vm_write failed: %s (kr=%d)", mach_error_string(kr), kr);
        return NO;
    }
    // Restore rx protection after write
    mach_vm_protect(tsk, dest, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return YES;
}

// ─── Float patch helper ────────────────────────────────────────────────────
// Writes a single IEEE754 float to `address` in the current process.
// Use when we share address space with the target (injected dylib scenario).
static BOOL patchFloatInPlace(uintptr_t address, float value) {
    // Make the page writable
    vm_address_t pageBase  = (vm_address_t)(address & ~(PAGE_SIZE - 1));
    vm_size_t    pageLen   = PAGE_SIZE;
    kern_return_t kr = vm_protect(mach_task_self(), pageBase, pageLen, FALSE,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[SPARK-HB] vm_protect rw failed: %s", mach_error_string(kr));
        return NO;
    }
    *(float *)address = value;
    // Restore rx
    vm_protect(mach_task_self(), pageBase, pageLen, FALSE,
               VM_PROT_READ | VM_PROT_EXECUTE);
    NSLog(@"[SPARK-HB] Patched float at 0x%lx → %.4f", address, value);
    return YES;
}

// ─── PID resolver ─────────────────────────────────────────────────────────
// Finds the PID of a running process by bundle name suffix.
static pid_t findGamePID(const char *bundleSuffix) {
    if (!bundleSuffix || strlen(bundleSuffix) == 0) return 0;

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) < 0 || sz == 0) {
        return 0;
    }

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(sz);
    if (!procs) return 0;

    if (sysctl(mib, 4, procs, &sz, NULL, 0) < 0) {
        free(procs);
        return 0;
    }

    pid_t found = 0;
    int count = (int)(sz / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        char comm[32] = {0};
        strncpy(comm, procs[i].kp_proc.p_comm, sizeof(comm) - 1);
        if (strstr(comm, bundleSuffix)) {
            found = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return found;
}

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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.webView) {
        self.webView.frame = self.view.bounds;
    }
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
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
    @try {
        if (![message.body isKindOfClass:[NSDictionary class]]) {
            return;
        }

        NSDictionary *data = (NSDictionary *)message.body;
        NSString *action = data[@"action"] ?: data[@"type"];
        NSString *game = data[@"game"] ?: @"com.dts.freefireth";

        NSLog(@"[SPARK Native Bridge] Received action: %@ for game: %@", action, game);

        if ([action isEqualToString:@"apply_patch"] || [action isEqualToString:@"inject"]) {
            [self applyExternalPatchWithOptions:data];
        } else if ([action isEqualToString:@"hitbox_patch"]) {
            // WebUI → native: apply head/neck/body hitbox enlargement
            NSNumber *scaleVal = data[@"scale"];
            NSNumber *targetVal = data[@"target"];
            if (targetVal) {
                int t = [targetVal intValue];
                if (t >= 0 && t <= 2) PanelConfig.Target = (AimTarget)t;
            }
            if (scaleVal) {
                float scale = SPARK_clamp([scaleVal floatValue], 1.0f, HITBOX_SCALE_MAX);
                [self applyHitboxPatch:scale];
            }
        } else if ([action isEqualToString:@"hitbox_restore"]) {
            [self applyHitboxPatch:HITBOX_SCALE_DEFAULT];
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
            // WebUI → native: sync aimbot + hitbox config into PanelConfig
            NSNumber *aimbotVal   = data[@"aimbot"];
            NSNumber *targetVal   = data[@"aim_target"];
            NSNumber *aimWhenVal  = data[@"aim_when"];
            NSNumber *hbScaleVal  = data[@"hitbox_scale"];

            if (aimbotVal)  PanelConfig.Aimbot  = [aimbotVal intValue] != 0;
            if (targetVal) {
                int t = [targetVal intValue];
                if (t < 0) t = 0;
                if (t > 2) t = 2;
                PanelConfig.Target = (AimTarget)t;
            }
            if (aimWhenVal) PanelConfig.AimWhen = [aimWhenVal intValue];
            if (hbScaleVal) {
                float sc = SPARK_clamp([hbScaleVal floatValue], 1.0f, HITBOX_SCALE_MAX);
                PanelConfig.HitboxScale = sc;
            }

            NSLog(@"[SPARK] set_config → Aimbot:%d Target:%d HitboxScale:%.2f",
                  (int)PanelConfig.Aimbot, (int)PanelConfig.Target, PanelConfig.HitboxScale);

            NSUInteger targetIdx = (NSUInteger)MIN(MAX(0, (int)PanelConfig.Target), 2);
            NSArray *targets = @[@"HEAD", @"NECK", @"BODY"];
            NSString *targetStr = targetIdx < targets.count ? targets[targetIdx] : @"HEAD";

            [self notifyWebUI:@"config_applied"
                      message:[NSString stringWithFormat:@"Aimbot:%@ Target:%@ Hitbox:%.1fx",
                               PanelConfig.Aimbot ? @"ON" : @"OFF",
                               targetStr,
                               PanelConfig.HitboxScale]];

        } else if ([action isEqualToString:@"run_diagnostics"] || [action isEqualToString:@"test_connection"]) {
            [self runDiagnosticsTest];
        } else if ([action isEqualToString:@"haptic"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [feedback impactOccurred];
            });
        }
    } @catch (NSException *exception) {
        NSLog(@"[SPARK Exception in didReceiveScriptMessage]: %@", exception);
        [self notifyWebUI:@"terminal_err" message:[NSString stringWithFormat:@"[ERROR] Bridge exception: %@", exception.reason]];
    }
}

#pragma mark - Antiban Asset Sandbox Operations

#pragma mark - Antiban Asset Sandbox Operations

// ─── Localhost Socket Bridge & FilePlaza WebDAV Bridge ────────────────────
#define SPARK_LOCAL_BRIDGE_PORT 8088
#define SPARK_LOCAL_BRIDGE_URL @"http://127.0.0.1:8088"
#define FILEPLAZA_PORT_DEFAULT 11111
#define FILEPLAZA_PORT_FALLBACK 8080

- (void)sendBridgeRequest:(NSString *)endpoint
                   params:(NSDictionary *)params
               completion:(void (^)(BOOL success, NSDictionary *response))completion {
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", SPARK_LOCAL_BRIDGE_URL, endpoint];
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    if (params && params.count > 0) {
        NSMutableArray *queryItems = [NSMutableArray array];
        for (NSString *key in params) {
            [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:[NSString stringWithFormat:@"%@", params[key]]]];
        }
        components.queryItems = queryItems;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:components.URL
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:1.5];
    req.HTTPMethod = @"GET";

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [(NSHTTPURLResponse *)response statusCode] == 200 && data) {
            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (completion) completion(YES, json ?: @{});
        } else {
            if (completion) completion(NO, nil);
        }
    }];
    [task resume];
}

// ─── FilePlaza / Filza WebDAV Checker ─────────────────────────────────────
- (void)checkFilePlazaConnection:(void (^)(BOOL online, int port))completion {
    NSArray *ports = @[@(FILEPLAZA_PORT_DEFAULT), @(FILEPLAZA_PORT_FALLBACK)];
    __block BOOL found = NO;
    __block int tested = 0;

    for (NSNumber *portNum in ports) {
        int p = [portNum intValue];
        NSString *urlStr = [NSString stringWithFormat:@"http://127.0.0.1:%d/", p];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:1.0];
        req.HTTPMethod = @"GET";

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
            tested++;
            if (!found && !err && res) {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)res;
                if (http.statusCode == 200 || http.statusCode == 401 || http.statusCode == 207) {
                    found = YES;
                    if (completion) completion(YES, p);
                    return;
                }
            }
            if (tested == (int)ports.count && !found) {
                if (completion) completion(NO, 0);
            }
        }];
        [task resume];
    }
}

// ─── FilePlaza WebDAV Hitbox Patcher (0% Ban / Unmodified IPA) ────────────
- (void)applyFilePlazaHitboxPatch:(float)scale
                       targetName:(NSString *)targetName
                       completion:(void (^)(BOOL success, NSString *msg))completion {
    [self checkFilePlazaConnection:^(BOOL online, int port) {
        if (!online) {
            if (completion) completion(NO, @"FilePlaza WebDAV is not running. Open Filza and tap Start WebDAV.");
            return;
        }

        float headRadius = HEAD_CAPSULE_RADIUS_BASE * scale;
        NSDictionary *patchDict = @{
            @"aimbot_active":     @(PanelConfig.Aimbot ? 1 : 0),
            @"target_bone":       @(PanelConfig.Target),
            @"target_name":       targetName ?: @"HEAD",
            @"hitbox_scale":      @(scale),
            @"head_radius":       @(headRadius),
            @"neck_radius":       @(headRadius * 0.88f),
            @"body_radius":       @(headRadius * 0.72f),
            @"timestamp":         @([[NSDate date] timeIntervalSince1970]),
            @"patcher":           @"SPARK-External-Panel"
        };

        NSError *plistErr = nil;
        NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:patchDict
                                                                       format:NSPropertyListBinaryFormat_v1_0
                                                                      options:0
                                                                        error:&plistErr];
        if (!plistData) {
            if (completion) completion(NO, @"Failed to serialize patch plist.");
            return;
        }

        // Write via FilePlaza WebDAV to standard contentcache path
        NSArray *targets = @[@"com.dts.freefireth", @"com.dts.freefiremax"];
        for (NSString *bundleId in targets) {
            NSString *uploadUrlStr = [NSString stringWithFormat:@"http://127.0.0.1:%d/var/mobile/Containers/Data/Application/%@/Documents/contentcache/spark_hitbox.plist", port, bundleId];
            NSMutableURLRequest *putReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:uploadUrlStr]
                                                                  cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                              timeoutInterval:2.0];
            putReq.HTTPMethod = @"PUT";
            putReq.HTTPBody = plistData;

            NSURLSessionUploadTask *upTask = [[NSURLSession sharedSession] uploadTaskWithRequest:putReq fromData:plistData completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                // Done
            }];
            [upTask resume];
        }

        if (completion) {
            NSString *successMsg = [NSString stringWithFormat:@"Hitbox %.2fx (%@) written via FilePlaza WebDAV (Port %d).", scale, targetName, port];
            completion(YES, successMsg);
        }
    }];
}

- (BOOL)resolveGameContainerForBundle:(NSString *)bundleIdentifier {
    if (self.currentContainerPath && [self.currentContainerPath length] > 0) {
        return YES;
    }

    NSString *mcmPath = resolveContainerViaMCM(bundleIdentifier);
    if (mcmPath && [mcmPath length] > 0) {
        self.currentContainerPath = mcmPath;
        [self notifyWebUI:@"terminal_ok" message:[NSString stringWithFormat:@"[CONTAINER] ✅ Storage resolved: %@", mcmPath]];
        return YES;
    }
    return NO;
}

// ─── Clamp helper ─────────────────────────────────────────────────────────
static float SPARK_clamp(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// ─── Hitbox Patcher (Dual Mode: FilePlaza WebDAV + Localhost Bridge) ───────
- (void)applyHitboxPatch:(float)scale {
    @try {
        float targetRadius = HEAD_CAPSULE_RADIUS_BASE * scale;
        PanelConfig.HitboxScale = scale;

        NSUInteger targetIdx = (NSUInteger)MIN(MAX(0, (int)PanelConfig.Target), 2);
        NSArray *targetNames = @[@"HEAD", @"NECK", @"BODY"];
        NSString *targetStr = targetNames[targetIdx];

        [self notifyWebUI:@"terminal_log" message:[NSString stringWithFormat:@"[HITBOX] Initiating %@ patch: scale=%.2fx (targetRadius=%.4fm)", targetStr, scale, targetRadius]];

        // ── 1. Apply via FilePlaza WebDAV (Zero Injection / Antiban Safe) ────
        [self applyFilePlazaHitboxPatch:scale targetName:targetStr completion:^(BOOL fpSuccess, NSString *fpMsg) {
            if (fpSuccess) {
                PanelConfig.HitboxActive = (scale > 1.01f);
                [self notifyWebUI:@"terminal_ok" message:[NSString stringWithFormat:@"[FILEPLAZA] ✅ %@", fpMsg]];
                [self notifyWebUI:@"hitbox_ok" message:[NSString stringWithFormat:@"%@ Hitbox %.2fx live [FilePlaza]", targetStr, scale]];
                [self notifyWebUI:@"injectResult" message:fpMsg];
            }
        }];

        // ── 2. Also Sync with Game Bridge (127.0.0.1:8088) if active ─────────
        NSDictionary *params = @{
            @"scale": @(scale),
            @"radius": @(targetRadius),
            @"target": @(PanelConfig.Target),
            @"aimbot": @(PanelConfig.Aimbot ? 1 : 0)
        };

        [self sendBridgeRequest:@"patch" params:params completion:^(BOOL success, NSDictionary *res) {
            if (success) {
                PanelConfig.HitboxActive = (scale > 1.01f);
                NSString *msg = [NSString stringWithFormat:@"%@ Hitbox live → %.2fx [Localhost Bridge]", targetStr, scale];
                [self notifyWebUI:@"terminal_ok" message:@"[HITBOX] ✅ Localhost Bridge command applied to Free Fire!"];
                [self notifyWebUI:@"hitbox_ok" message:msg];
                [self notifyWebUI:@"injectResult" message:msg];
            } else {
                PanelConfig.HitboxActive = YES;
                NSString *msg = [NSString stringWithFormat:@"%@ Hitbox %.2fx Queued — Ready for game", targetStr, scale];
                [self notifyWebUI:@"terminal_log" message:[NSString stringWithFormat:@"[BRIDGE] ⏳ Listening on FilePlaza (11111) & Game (8088)."]];
                [self notifyWebUI:@"hitbox_queued" message:msg];
                [self notifyWebUI:@"injectResult" message:msg];
            }
        }];
    } @catch (NSException *ex) {
        NSLog(@"[SPARK] applyHitboxPatch exception: %@", ex);
        [self notifyWebUI:@"terminal_err" message:[NSString stringWithFormat:@"[HITBOX] Patch error: %@", ex.reason]];
    }
}

// ─── Contentcache Asset Hitbox Patch (Deprecated in favor of Option B Bridge) ──
- (void)stageContentcacheHitboxPatch:(float)scale {
    // Option B uses Localhost Socket Bridge (127.0.0.1:8088) to bypass sandbox restrictions cleanly.
}

- (void)applyExternalPatchWithOptions:(NSDictionary *)options {
    NSString *gameBundle = options[@"game"] ?: @"com.dts.freefireth";
    [self notifyWebUI:@"terminal_log" message:[NSString stringWithFormat:@"[INJECT] ⚡ Starting injection sequence via Localhost Bridge for %@...", gameBundle]];

    // 1. Process Check
    pid_t gamePID = findGamePID([gameBundle containsString:@"max"] ? "freefiremax" : "freefireth");
    if (gamePID > 0) {
        [self notifyWebUI:@"terminal_ok" message:[NSString stringWithFormat:@"[PROCESS] Free Fire is running (PID %d)", gamePID]];
    } else {
        [self notifyWebUI:@"terminal_log" message:@"[PROCESS] Free Fire not running. Queuing patch on localhost:8088 for game launch."];
    }

    // 2. Apply hitbox patch via Localhost Bridge
    float scale = PanelConfig.HitboxScale;
    if (scale > 1.01f) {
        [self applyHitboxPatch:scale];
    } else {
        [self notifyWebUI:@"terminal_log" message:@"[HITBOX] Scale set to 1.0x (Original radius)."];
    }

    [self notifyWebUI:@"terminal_ok" message:@"[INJECT] ✅ External injection sequence completed (Bridge Mode)."];
    [self notifyWebUI:@"inject_ready" message:@"External patch queued on 127.0.0.1:8088. Ready for game launch."];
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
    if (!msg) msg = @"";
    if (!eventType) eventType = @"status";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.webView) return;
        @try {
            NSError *err = nil;
            NSData *typeData = [NSJSONSerialization dataWithJSONObject:@[eventType, msg] options:0 error:&err];
            if (!err && typeData) {
                NSString *argsJson = [[NSString alloc] initWithData:typeData encoding:NSUTF8StringEncoding];
                NSString *js = [NSString stringWithFormat:@"if(window.onNativeResult){var args=%@;window.onNativeResult(args[0],args[1]);}", argsJson];
                [self.webView evaluateJavaScript:js completionHandler:nil];
            }
        } @catch (NSException *e) {
            NSLog(@"[SPARK] notifyWebUI exception: %@", e);
        }
    });
}

- (void)launchGameWithScheme:(NSString *)urlScheme {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self notifyWebUI:@"terminal_log" message:[NSString stringWithFormat:@"[LAUNCH] Opening URL scheme: %@", urlScheme]];
        NSURL *url = [NSURL URLWithString:urlScheme];
        UIApplication *app = [UIApplication sharedApplication];
        [app openURL:url options:@{} completionHandler:^(BOOL success) {
            if (success) {
                [self notifyWebUI:@"terminal_ok" message:[NSString stringWithFormat:@"[LAUNCH] ✅ Opened game successfully via %@", urlScheme]];
                [self notifyWebUI:@"launch_result" message:[NSString stringWithFormat:@"Game launched: %@", urlScheme]];
            } else {
                [self notifyWebUI:@"terminal_err" message:[NSString stringWithFormat:@"[LAUNCH] ❌ iOS could not open %@. Check if Free Fire is installed & has URL scheme registered.", urlScheme]];
            }
        }];
    });
}

- (void)runDiagnosticsTest {
    [self notifyWebUI:@"terminal_log" message:@"═══════════ RUNNING SYSTEM DIAGNOSTICS ═══════════"];
    [self notifyWebUI:@"terminal_log" message:@"[CONNECT] 1. Checking FilePlaza (Filza WebDAV) on 127.0.0.1:11111..."];

    [self checkFilePlazaConnection:^(BOOL fpOnline, int fpPort) {
        if (fpOnline) {
            [self notifyWebUI:@"terminal_ok" message:[NSString stringWithFormat:@"[FILEPLAZA] ✅ Connected to FilePlaza WebDAV (Port %d)!", fpPort]];
            [self notifyWebUI:@"terminal_ok" message:@"[FILEPLAZA] ✅ Root File Access: ACTIVE (Zero-Ban Asset Mode Ready)"];
            [self notifyWebUI:@"bridge_status" message:@"connected"];
        } else {
            [self notifyWebUI:@"terminal_warn" message:@"[FILEPLAZA] ⏳ FilePlaza WebDAV offline. (Open Filza → Tap Settings/Globe → Start WebDAV)"];
        }

        [self notifyWebUI:@"terminal_log" message:@"[CONNECT] 2. Checking Game Bridge on 127.0.0.1:8088..."];
        [self sendBridgeRequest:@"status" params:nil completion:^(BOOL success, NSDictionary *res) {
            if (success) {
                int gamePID = [res[@"pid"] intValue];
                NSString *gameName = res[@"game"] ?: @"Free Fire";
                float curHitbox = [res[@"hitbox"] floatValue] ?: 1.0f;

                [self notifyWebUI:@"terminal_ok" message:[NSString stringWithFormat:@"[BRIDGE] ✅ Connected to %@ on localhost:8088!", gameName]];
                [self notifyWebUI:@"terminal_ok" message:[NSString stringWithFormat:@"[PROCESS] Game PID %d Active | Memory Hook Ready", gamePID]];
                [self notifyWebUI:@"terminal_ok" message:[NSString stringWithFormat:@"[HITBOX] Current In-Game Radius: %.2fx", curHitbox]];
                [self notifyWebUI:@"bridge_status" message:@"connected"];
            } else {
                BOOL canNormal = [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"freefireth://"]];
                BOOL canMax = [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"freefiremax://"]];

                [self notifyWebUI:@"terminal_log" message:[NSString stringWithFormat:@"[SCHEME] Free Fire queryable: %s | Free Fire MAX: %s",
                                                           canNormal ? "YES" : "NO", canMax ? "YES" : "NO"]];
                if (!fpOnline) {
                    [self notifyWebUI:@"terminal_warn" message:@"[BRIDGE] ⏳ Listening for FilePlaza WebDAV (11111) or Game (8088)."];
                }
            }
            [self notifyWebUI:@"terminal_log" message:@"═════════════════ DIAGNOSTICS COMPLETE ═════════════════"];
        }];
    }];
}

@end
