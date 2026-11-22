#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (^FindMyDevicesDataSourceProvider)(void);
typedef NSDictionary * _Nonnull (^FindMyDevicesSnapshotProvider)(id dataSource);
typedef BOOL (^FindMyDevicesRefreshTrigger)(id dataSource, NSString * _Nullable deviceId, BOOL force);
typedef void (^FindMyDevicesRefreshResponseHandler)(NSDictionary *response);

@interface FindMyDevicesRefreshCoordinator : NSObject

+ (BOOL)triggerFMIPManagerRefresh:(nullable id)fmipManager;
+ (void)restoreFMIPManagerRefreshThrottle:(nullable id)fmipManager;

- (instancetype)initWithTransactionIdentifier:(nullable NSString *)transactionIdentifier
                             dataSourceTimeout:(NSTimeInterval)dataSourceTimeout
                                  pollInterval:(NSTimeInterval)pollInterval
                            dataSourceProvider:(FindMyDevicesDataSourceProvider)dataSourceProvider
                              snapshotProvider:(FindMyDevicesSnapshotProvider)snapshotProvider
                               responseHandler:(FindMyDevicesRefreshResponseHandler)responseHandler;

- (instancetype)initWithTransactionIdentifier:(nullable NSString *)transactionIdentifier
                             dataSourceTimeout:(NSTimeInterval)dataSourceTimeout
                                  pollInterval:(NSTimeInterval)pollInterval
                                      deviceId:(nullable NSString *)deviceId
                                         force:(BOOL)force
                          activeRefreshTimeout:(NSTimeInterval)activeRefreshTimeout
                            activePollInterval:(NSTimeInterval)activePollInterval
                            dataSourceProvider:(FindMyDevicesDataSourceProvider)dataSourceProvider
                              snapshotProvider:(FindMyDevicesSnapshotProvider)snapshotProvider
                                refreshTrigger:(nullable FindMyDevicesRefreshTrigger)refreshTrigger
                               responseHandler:(FindMyDevicesRefreshResponseHandler)responseHandler;

- (void)start;

@end

NS_ASSUME_NONNULL_END
