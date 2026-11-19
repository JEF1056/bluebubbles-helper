#import <Foundation/Foundation.h>

#import "FindMyLocateSession.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^FindMyFriendsRefreshResponseHandler)(NSDictionary *response);

@interface FindMyFriendsRefreshCoordinator : NSObject

@property (nonatomic, assign) BOOL preserveFocusedLiveRefresh;

- (instancetype)initWithSession:(id<FindMyLocateSessionProtocol>)session
           transactionIdentifier:(nullable NSString *)transactionIdentifier
                   focusedHandle:(nullable NSString *)focusedHandle
                    targetedOnly:(BOOL)targetedOnly
               friendListTimeout:(NSTimeInterval)friendListTimeout
          locationRefreshTimeout:(NSTimeInterval)locationRefreshTimeout
                 responseHandler:(FindMyFriendsRefreshResponseHandler)responseHandler;

- (void)start;

@end

NS_ASSUME_NONNULL_END
