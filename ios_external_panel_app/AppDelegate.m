#import "AppDelegate.h"
#import "ExternalPanelViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = [ExternalPanelViewController sharedPanel];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
