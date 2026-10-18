//
//  PubgLoad.h
//  pubg
//
//  Created by 李良林 on 2021/2/14.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PubgLoad : NSObject
+ (nullable instancetype)sharedInstance;
- (void)toggleMenu;
@end

NS_ASSUME_NONNULL_END
