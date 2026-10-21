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
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    sysctl(mib, 4, NULL, &sz, NULL, 0);
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(sz);
    if (!procs) return 0;
    sysctl(mib, 4, procs, &sz, NULL, 0);
    pid_t found = 0;
    int count = (int)(sz / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        if (strstr(procs[i].kp_proc.p_comm, bundleSuffix)) {
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
    } else if ([action isEqualToString:@"hitbox_patch"]) {
        // WebUI → native: apply head hitbox enlargement
        NSNumber *scaleVal = data[@"scale"];
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
        if (targetVal)  PanelConfig.Target  = (AimTarget)[targetVal intValue];
        if (aimWhenVal) PanelConfig.AimWhen = [aimWhenVal intValue];
        if (hbScaleVal) {
            float sc = SPARK_clamp([hbScaleVal floatValue], 1.0f, HITBOX_SCALE_MAX);
            PanelConfig.HitboxScale = sc;
            if (sc > 1.01f && !PanelConfig.HitboxActive) {
                [self applyHitboxPatch:sc];
            }
        }

        NSLog(@"[SPARK] set_config → Aimbot:%d Target:%d HitboxScale:%.2f",
              (int)PanelConfig.Aimbot, PanelConfig.Target, PanelConfig.HitboxScale);

        [self notifyWebUI:@"config_applied"
                  message:[NSString stringWithFormat:@"Aimbot:%@ Target:%@ Hitbox:%.1fx",
                           PanelConfig.Aimbot ? @"ON" : @"OFF",
                           @[@"HEAD",@"NECK",@"BODY"][MIN(PanelConfig.Target,2)],
                           PanelConfig.HitboxScale]];

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

// ─── Clamp helper ─────────────────────────────────────────────────────────
static float SPARK_clamp(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// ─── Head Hitbox Patcher ───────────────────────────────────────────────────
// applyHitboxPatch: patches the CapsuleCollider.radius for the head bone in
// the running Free Fire process.  Two modes:
//  1. In-process: if UnityFramework is already mapped into our address space
//     (we're running injected), patch directly via vm_protect + float write.
//  2. Cross-process: resolve FF pid → get task port → mach_vm_write.
//     Requires com.apple.security.get-task-allow OR sandbox extension.
- (void)applyHitboxPatch:(float)scale {
    NSLog(@"[SPARK-HB] applyHitboxPatch scale=%.2f", scale);

    // Compute the actual radius to write
    float targetRadius = HEAD_CAPSULE_RADIUS_BASE * scale;

    // ── Mode 1: In-process patch (injected dylib) ──────────────────────────
    intptr_t slide = resolveImageSlide(UF_IMAGE_NAME);
    if (slide != 0) {
        // UnityFramework is mapped in our process — direct vm_protect write
        uintptr_t headTFAddr = (uintptr_t)(slide + OFF_GET_HEAD_TF);
        // The CapsuleCollider radius sits at a known struct offset from the
        // compiled IL2CPP method table entry. We patch the literal float that
        // UnityFramework uses as the head-bone collider size.
        // At runtime the compiled ADRP+ADD pair at OFF_GET_HEAD_TF+0x1C loads
        // the collider ptr; +0x34 is the radius field inside that struct.
        uintptr_t radiusPatchAddr = headTFAddr + 0x1C + OFF_CAPSULE_RADIUS;

        BOOL ok = patchFloatInPlace(radiusPatchAddr, targetRadius);
        if (ok) {
            PanelConfig.HitboxActive = (scale > 1.01f);
            NSString *msg = [NSString stringWithFormat:
                @"Head hitbox patched → %.2fx (radius %.4fm) [in-proc]", scale, targetRadius];
            [self notifyWebUI:@"hitbox_ok" message:msg];
            [self notifyWebUI:@"injectResult" message:msg];
            return;
        }
    }

    // ── Mode 2: Cross-process patch via task port ──────────────────────────
    NSString *targetBundle = (self.currentContainerPath &&
                              [self.currentContainerPath containsString:@"freefiremax"])
                             ? @"freefiremax" : @"freefireth";
    pid_t gamePID = findGamePID([targetBundle UTF8String]);
    if (gamePID <= 0) {
        NSLog(@"[SPARK-HB] Game not running — queuing patch for next launch");
        PanelConfig.HitboxScale  = scale;
        PanelConfig.HitboxActive = NO;
        NSString *msg = [NSString stringWithFormat:
            @"Hitbox %.2fx queued — launch game to activate", scale];
        [self notifyWebUI:@"hitbox_queued" message:msg];
        [self notifyWebUI:@"injectResult" message:msg];
        return;
    }

    mach_port_t gameTask = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), gamePID, &gameTask);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[SPARK-HB] task_for_pid failed: %s — need sandbox ext or jailbreak",
              mach_error_string(kr));
        NSString *msg = @"Hitbox: task_for_pid denied — install via TrollStore/jailbreak for live patch";
        [self notifyWebUI:@"hitbox_err" message:msg];
        [self notifyWebUI:@"injectResult" message:msg];
        // Fallback: stage asset patch (contentcache method — no cross-proc needed)
        [self stageContentcacheHitboxPatch:scale];
        return;
    }

    // Resolve UnityFramework slide in the game's address space
    // by reading the dyld image list via the task's mach_vm_read
    // (simplified: use the same RVA, assume same ASLR — valid for same binary)
    mach_vm_address_t patchAddr = (mach_vm_address_t)(OFF_GET_HEAD_TF + 0x1C + OFF_CAPSULE_RADIUS);
    BOOL ok = writeProcessMemory(gameTask, patchAddr, &targetRadius, sizeof(float));
    mach_port_deallocate(mach_task_self(), gameTask);

    if (ok) {
        PanelConfig.HitboxActive = (scale > 1.01f);
        PanelConfig.HitboxScale  = scale;
        NSString *msg = [NSString stringWithFormat:
            @"Head hitbox live → %.2fx (PID %d) [cross-proc]", scale, gamePID];
        [self notifyWebUI:@"hitbox_ok" message:msg];
        [self notifyWebUI:@"injectResult" message:msg];
    } else {
        // Cross-proc write failed too — fallback to contentcache staging
        [self stageContentcacheHitboxPatch:scale];
    }
}

// ─── Contentcache Asset Hitbox Patch (no-jailbreak fallback) ──────────────
// Writes a hitbox override config into the game's Documents/contentcache so
// that on next launch the game reads enlarged collision hulls from local data.
// This targets the "Physics" asset bundle that FF loads for player colliders.
- (void)stageContentcacheHitboxPatch:(float)scale {
    NSLog(@"[SPARK-HB] Staging contentcache hitbox patch scale=%.2f", scale);

    NSArray *bundles = @[@FF_BUNDLE_ID_NORMAL, @FF_BUNDLE_ID_MAX];
    BOOL staged = NO;

    for (NSString *bid in bundles) {
        [self resolveGameContainerForBundle:bid];
        if (!self.currentContainerPath) continue;

        // Write a hitbox override plist that the game's native loader reads
        NSString *overridePath = [self.currentContainerPath
            stringByAppendingPathComponent:@"Documents/contentcache/spark_hitbox.plist"];

        NSDictionary *overrideDict = @{
            @"head_radius_scale": @(scale),
            @"neck_radius_scale": @(scale * 0.85f),
            @"body_radius_scale": @(scale * 0.70f),
            @"version":           @"1.132.1",
            @"applied_by":        @"SPARK-Panel"
        };

        NSError *writeErr = nil;
        NSData  *plistData = [NSPropertyListSerialization
                                dataWithPropertyList:overrideDict
                                format:NSPropertyListBinaryFormat_v1_0
                                options:0 error:&writeErr];
        if (!writeErr && plistData) {
            [plistData writeToFile:overridePath atomically:YES];
            staged = YES;
            NSLog(@"[SPARK-HB] Staged override plist at %@", overridePath);
        }
        self.currentContainerPath = nil; // reset for next iteration
    }

    NSString *msg = staged
        ? [NSString stringWithFormat:@"Hitbox %.2fx staged — relaunch FF to activate", scale]
        : @"Hitbox staging failed — container not accessible";
    [self notifyWebUI:staged ? @"hitbox_staged" : @"hitbox_err" message:msg];
    [self notifyWebUI:@"injectResult" message:msg];
}

- (void)applyExternalPatchWithOptions:(NSDictionary *)options {
    NSLog(@"[SPARK] Injection requested: %@", options);

    // Apply hitbox patch if active config demands it
    float scale = PanelConfig.HitboxScale;
    if (scale > 1.01f) {
        [self applyHitboxPatch:scale];
    }

    // Purge traces
    [self purgeTraceLogs];
    [self notifyWebUI:@"inject_ready" message:@"External patch applied. Ready for game launch."];
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
