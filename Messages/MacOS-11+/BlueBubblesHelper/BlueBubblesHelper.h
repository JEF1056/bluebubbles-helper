//
//  BlueBubblesHelper.h
//  BlueBubblesHelper
//
//  Created by Tanay Neotia on 5/3/26.
//  Copyright © 2026 BlueBubbleMessaging. All rights reserved.
//

#ifndef BlueBubblesHelper_h
#define BlueBubblesHelper_h

#import "NetworkController.h"

@interface BlueBubblesHelper : NSObject

// Singleton instance
+(instancetype) sharedInstance;

// Methods
-(void) handleServerEvent: (NSString*)event data: (NSDictionary*)data transactionId: (NSString*)transaction;

@end

// Default-deny read-receipt gate: blocked unless explicitly allowed during a "mark-chat-read" without suppressReceipt.
@interface BlueBubblesHelper (ReceiptGate)
+(void) beginAllowingReceiptsForChat:(NSString *)chatGuid;
+(void) endAllowingReceiptsForChat:(NSString *)chatGuid;
+(BOOL) shouldAllowReceiptForChat:(NSString *)chatGuid;
@end

#endif /* BlueBubblesHelper_h */
