#import "PubgLoad.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import "JHPP.h"
#import "menuUIKIT/drawview.h"

#pragma mark - Spark Floating Button View

@interface SparkFloatingButton : UIView
@property (nonatomic, strong) UILabel *iconLabel;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, copy) void (^onTapHandler)(void);
@end

@implementation SparkFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:0.88];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.borderWidth = 1.8;
        self.layer.borderColor = [UIColor colorWithRed:1.0 green:0.25 blue:0.25 alpha:0.9].CGColor;
        
        self.layer.shadowColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.6].CGColor;
        self.layer.shadowOpacity = 0.85;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;

        self.iconLabel = [[UILabel alloc] initWithFrame:self.bounds];
        self.iconLabel.text = @"⚡";
        self.iconLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        self.iconLabel.textColor = [UIColor whiteColor];
        self.iconLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:self.iconLabel];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    newCenter.x = MAX(halfW + 10, MIN(screen.size.width - halfW - 10, newCenter.x));
    newCenter.y = MAX(halfH + 10, MIN(screen.size.height - halfH - 10, newCenter.y));

    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:self.superview];

    if (pan.state == UIGestureRecognizerStateEnded) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setFloat:self.center.x forKey:@"SparkBtnX"];
        [defaults setFloat:self.center.y forKey:@"SparkBtnY"];
        [defaults synchronize];
    }
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    [UIView animateWithDuration:0.1 animations:^{
        self.transform = CGAffineTransformMakeScale(0.85, 0.85);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            self.transform = CGAffineTransformIdentity;
        }];
        if (self.onTapHandler) {
            self.onTapHandler();
        }
    }];
}

@end

#pragma mark - PubgLoad Controller

@interface PubgLoad ()
@property (nonatomic, strong) SparkFloatingButton *floatingButton;
@property (nonatomic, strong) MPVolumeView *hiddenVolumeView;
@property (nonatomic, assign) NSTimeInterval lastVolumeTime;
@end

@implementation PubgLoad

static PubgLoad *extraInfo = nil;
static bool isUIKitMenuOpen = false;

+ (void)load {
    [super load];
    
    // Allow Unity engine to fully load its windows and view controller
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        extraInfo = [PubgLoad new];
        [extraInfo setupFloatingIcon];
        [extraInfo setupVolumeButtonListener];
        [extraInfo setupBackupGestures];
        
        [[NSNotificationCenter defaultCenter] addObserver:extraInfo
                                                 selector:@selector(menuDidClose)
                                                     name:@"ModMenuDidClose"
                                                   object:nil];
    });
}

#pragma mark - Window Helper

- (UIWindow *)findActiveKeyWindow {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *w in windowScene.windows) {
                    if (w.isKeyWindow) {
                        return w;
                    }
                }
            }
        }
    }
    window = [UIApplication sharedApplication].keyWindow;
    if (!window && [UIApplication sharedApplication].windows.count > 0) {
        window = [UIApplication sharedApplication].windows.firstObject;
    }
    return window;
}

#pragma mark - Floating Button Setup

- (void)setupFloatingIcon {
    UIWindow *window = [self findActiveKeyWindow];
    if (!window) return;

    if (self.floatingButton && self.floatingButton.superview) {
        [self.floatingButton removeFromSuperview];
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat savedX = [defaults floatForKey:@"SparkBtnX"];
    CGFloat savedY = [defaults floatForKey:@"SparkBtnY"];
    if (savedX <= 0 || savedY <= 0) {
        savedX = 55.0;
        savedY = 140.0;
    }

    self.floatingButton = [[SparkFloatingButton alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    self.floatingButton.center = CGPointMake(savedX, savedY);

    __weak typeof(self) weakSelf = self;
    self.floatingButton.onTapHandler = ^{
        [weakSelf toggleMenu];
    };

    [window addSubview:self.floatingButton];
    [window bringSubviewToFront:self.floatingButton];
}

#pragma mark - Volume Button Double Click

- (void)setupVolumeButtonListener {
    // Hidden volume view prevents iOS system volume HUD from popping up
    UIWindow *window = [self findActiveKeyWindow];
    if (window) {
        self.hiddenVolumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-1000, -1000, 10, 10)];
        [window addSubview:self.hiddenVolumeView];
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryAmbient error:nil];
    [session setActive:YES error:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(volumeChangedNotification:)
                                                 name:@"AVSystemController_SystemVolumeDidChangeNotification"
                                               object:nil];
}

- (void)volumeChangedNotification:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    NSString *reason = info[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];
    
    // Check if user explicitly pressed physical volume buttons
    if (!reason || [reason isEqualToString:@"ExplicitVolumeChange"]) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastVolumeTime < 0.50) {
            // Double click detected!
            self.lastVolumeTime = 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self toggleMenu];
            });
        } else {
            self.lastVolumeTime = now;
        }
    }
}

#pragma mark - Backup Gestures

- (void)setupBackupGestures {
    UIWindow *window = [self findActiveKeyWindow];
    if (!window) return;

    // 2-Finger Double Tap as backup gesture
    UITapGestureRecognizer *twoFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleMenu)];
    twoFingerTap.numberOfTouchesRequired = 2;
    twoFingerTap.numberOfTapsRequired = 2;
    [window addGestureRecognizer:twoFingerTap];
}

#pragma mark - Menu Presentation

- (void)toggleMenu {
    if (isUIKitMenuOpen) {
        [self closeUIKitMenu];
    } else {
        [self openUIKitMenu];
    }
}

- (void)openUIKitMenu {
    if (isUIKitMenuOpen) return;

    UIWindow *window = [self findActiveKeyWindow];
    if (!window) return;

    UIViewController *rootVC = window.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    if (!rootVC) return;

    ModMenuViewController *menuVC = [[ModMenuViewController alloc] init];
    menuVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
    [rootVC presentViewController:menuVC animated:NO completion:nil];

    isUIKitMenuOpen = true;

    // Hide floating button while menu is open
    if (self.floatingButton) {
        self.floatingButton.hidden = YES;
    }
}

- (void)closeUIKitMenu {
    if (!isUIKitMenuOpen) return;

    UIWindow *window = [self findActiveKeyWindow];
    UIViewController *vc = window.rootViewController.presentedViewController;
    if ([vc isKindOfClass:[ModMenuViewController class]]) {
        [vc dismissViewControllerAnimated:NO completion:nil];
    }
    [self menuDidClose];
}

- (void)menuDidClose {
    isUIKitMenuOpen = false;
    
    // Restore floating button
    if (self.floatingButton) {
        self.floatingButton.hidden = NO;
        [self.floatingButton.superview bringSubviewToFront:self.floatingButton];
    }
}

@end