#ifndef FindMyHelper_h
#define FindMyHelper_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FindMyHelper : NSObject

+ (instancetype)sharedInstance;

- (void)handleServerAction:(nullable NSString *)action
     transactionIdentifier:(nullable NSString *)transactionIdentifier;

- (void)handleServerAction:(nullable NSString *)action
                      data:(nullable NSDictionary *)data
     transactionIdentifier:(nullable NSString *)transactionIdentifier;

- (void)handleServerRegistered;
- (void)handleServerDisconnected;

@end

NS_ASSUME_NONNULL_END

#endif
