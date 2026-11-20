#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

@interface MockChat : NSObject
@property (nonatomic, copy) NSString *guid;
@property (nonatomic, assign) BOOL throwOnMarkRead;
@property (nonatomic, assign) BOOL triggerForeignChatReceipt;
@property (nonatomic, strong) MockChat *foreignChat;
@property (nonatomic, assign) NSInteger markAllReadCalls;
@property (nonatomic, assign) NSInteger clearCacheCalls;
@end

static id gMockRegistryInstance = nil;
static NSMutableDictionary<NSString *, MockChat *> *gMockChats = nil;
static NSMutableArray<NSString *> *gSentAllReceipts = nil;
static NSMutableArray<NSString *> *gSentMessageReceipts = nil;

@implementation MockChat

- (void)markAllMessagesAsRead {
    self.markAllReadCalls += 1;
    if (self.throwOnMarkRead) {
        @throw [NSException exceptionWithName:@"MockReadException" reason:@"simulated failure" userInfo:nil];
    }
    ((void (*)(id, SEL, id))objc_msgSend)(gMockRegistryInstance, sel_registerName("_chat_sendReadReceiptForAllMessages:"), self);
    if (self.triggerForeignChatReceipt && self.foreignChat != nil) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(gMockRegistryInstance, sel_registerName("_chat:sendReadReceiptForMessages:"), self.foreignChat, @[@"msg-foreign"]);
    }
}

- (void)__clearReadMessageCache {
    self.clearCacheCalls += 1;
}

- (void)markLastMessageAsUnread {
}

@end

static id SpySharedInstance(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return gMockRegistryInstance;
}

static id SpyExistingChatWithGUID(id self, SEL _cmd, NSString *guid) {
    (void)self; (void)_cmd;
    return guid ? gMockChats[guid] : nil;
}

static id SpyValueForKey(id self, SEL _cmd, NSString *key) {
    (void)self; (void)_cmd; (void)key;
    return nil;
}

static void SpySendReadReceiptForAllMessages(id self, SEL _cmd, id chat) {
    (void)self; (void)_cmd;
    NSString *guid = [chat respondsToSelector:@selector(guid)] ? [chat guid] : @"(nil)";
    [gSentAllReceipts addObject:(guid ?: @"(nil)")];
}

static void SpySendReadReceiptForMessages(id self, SEL _cmd, id chat, id messages) {
    (void)self; (void)_cmd; (void)messages;
    NSString *guid = [chat respondsToSelector:@selector(guid)] ? [chat guid] : @"(nil)";
    [gSentMessageReceipts addObject:(guid ?: @"(nil)")];
}

static void AssertTrue(BOOL cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", msg);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path/to/BlueBubblesHelper.dylib>\n", argv[0]);
            return 2;
        }

        Class imRegClass = objc_getClass("IMChatRegistry");
        AssertTrue(imRegClass != Nil, "IMChatRegistry class loaded from IMCore");

        gMockRegistryInstance = [imRegClass alloc];
        gMockChats = [NSMutableDictionary dictionary];
        gSentAllReceipts = [NSMutableArray array];
        gSentMessageReceipts = [NSMutableArray array];

        // Replace IMChatRegistry methods BEFORE dlopen so BBH_IMChatRegistry_Receipts swizzles over our spies
        // without ever touching imagent XPC.
        Method mShared = class_getClassMethod(imRegClass, sel_registerName("sharedInstance"));
        AssertTrue(mShared != NULL, "IMChatRegistry +sharedInstance exists");
        method_setImplementation(mShared, (IMP)SpySharedInstance);

        Method mExisting = class_getInstanceMethod(imRegClass, sel_registerName("existingChatWithGUID:"));
        AssertTrue(mExisting != NULL, "IMChatRegistry -existingChatWithGUID: exists");
        method_setImplementation(mExisting, (IMP)SpyExistingChatWithGUID);

        Method mAll = class_getInstanceMethod(imRegClass, sel_registerName("_chat_sendReadReceiptForAllMessages:"));
        AssertTrue(mAll != NULL, "IMChatRegistry -_chat_sendReadReceiptForAllMessages: exists");
        method_setImplementation(mAll, (IMP)SpySendReadReceiptForAllMessages);

        Method mMsgs = class_getInstanceMethod(imRegClass, sel_registerName("_chat:sendReadReceiptForMessages:"));
        AssertTrue(mMsgs != NULL, "IMChatRegistry -_chat:sendReadReceiptForMessages: exists");
        method_setImplementation(mMsgs, (IMP)SpySendReadReceiptForMessages);

        class_replaceMethod(imRegClass, sel_registerName("valueForKey:"), (IMP)SpyValueForKey, "@@:@");

        void *handle = dlopen(argv[1], RTLD_NOW);
        if (!handle) {
            fprintf(stderr, "dlopen(%s) failed: %s\n", argv[1], dlerror());
            return 1;
        }

        Class helperCls = objc_getClass("BlueBubblesHelper");
        AssertTrue(helperCls != Nil, "BlueBubblesHelper class loaded");
        id helper = ((id (*)(id, SEL))objc_msgSend)(helperCls, sel_registerName("sharedInstance"));
        AssertTrue(helper != nil, "BlueBubblesHelper sharedInstance created");

        NSString *guidA = @"iMessage;-;+15550001111";
        NSString *guidB = @"iMessage;-;+15550002222";
        MockChat *chatA = [[MockChat alloc] init];
        chatA.guid = guidA;
        MockChat *chatB = [[MockChat alloc] init];
        chatB.guid = guidB;
        gMockChats[guidA] = chatA;
        gMockChats[guidB] = chatB;

        BOOL (*shouldAllow)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
        void (*beginAllow)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))objc_msgSend;
        void (*endAllow)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))objc_msgSend;
        void (*handleEvent)(id, SEL, NSString *, NSDictionary *, NSString *) =
            (void (*)(id, SEL, NSString *, NSDictionary *, NSString *))objc_msgSend;

        SEL sAllow = sel_registerName("shouldAllowReceiptForChat:");
        SEL sBegin = sel_registerName("beginAllowingReceiptsForChat:");
        SEL sEnd = sel_registerName("endAllowingReceiptsForChat:");
        SEL sHandle = sel_registerName("handleServerEvent:data:transactionId:");

        // 1. Default-deny: nil and arbitrary chat guids are denied.
        AssertTrue(!shouldAllow(helperCls, sAllow, nil), "default-deny nil guid");
        AssertTrue(!shouldAllow(helperCls, sAllow, guidA), "default-deny chatA");

        // 2. Unsolicited receipt sends (e.g. Catalyst launch / scene restore) are dropped.
        ((void (*)(id, SEL, id))objc_msgSend)(gMockRegistryInstance, sel_registerName("_chat_sendReadReceiptForAllMessages:"), chatA);
        ((void (*)(id, SEL, id, id))objc_msgSend)(gMockRegistryInstance, sel_registerName("_chat:sendReadReceiptForMessages:"), chatA, @[@"m1"]);
        AssertTrue(gSentAllReceipts.count == 0, "unsolicited sendReadReceiptForAllMessages blocked");
        AssertTrue(gSentMessageReceipts.count == 0, "unsolicited sendReadReceiptForMessages blocked");

        // 3. Explicit mark-chat-read with suppressReceipt=YES marks read locally, blocks receipt.
        handleEvent(helper, sHandle, @"mark-chat-read", @{@"chatGuid": guidA, @"suppressReceipt": @YES}, nil);
        AssertTrue(chatA.markAllReadCalls == 1, "markAllMessagesAsRead called with suppressReceipt=YES");
        AssertTrue(chatA.clearCacheCalls == 1, "__clearReadMessageCache called with suppressReceipt=YES");
        AssertTrue(gSentAllReceipts.count == 0, "suppressReceipt=YES blocks read receipt");
        AssertTrue(!shouldAllow(helperCls, sAllow, guidA), "chatA stays denied after suppressReceipt=YES");

        // 4. Explicit mark-chat-read with suppressReceipt=NO allows ONLY chatA during execution, blocks chatB, and closes gate after.
        chatA.triggerForeignChatReceipt = YES;
        chatA.foreignChat = chatB;
        handleEvent(helper, sHandle, @"mark-chat-read", @{@"chatGuid": guidA, @"suppressReceipt": @NO}, nil);
        chatA.triggerForeignChatReceipt = NO;
        AssertTrue(chatA.markAllReadCalls == 2, "markAllMessagesAsRead called with suppressReceipt=NO");
        AssertTrue(gSentAllReceipts.count == 1 && [gSentAllReceipts[0] isEqualToString:guidA], "suppressReceipt=NO sends receipt for chatA");
        AssertTrue(gSentMessageReceipts.count == 0, "foreign chatB remains blocked during chatA mark-chat-read");
        AssertTrue(!shouldAllow(helperCls, sAllow, guidA), "chatA gate closes after mark-chat-read returns");

        // 5. Explicit mark-chat-read with omitted suppressReceipt defaults to sending for that call, then closes gate.
        [gSentAllReceipts removeAllObjects];
        handleEvent(helper, sHandle, @"mark-chat-read", @{@"chatGuid": guidA}, nil);
        AssertTrue(gSentAllReceipts.count == 1 && [gSentAllReceipts[0] isEqualToString:guidA], "omitted suppressReceipt sends receipt for chatA");
        AssertTrue(!shouldAllow(helperCls, sAllow, guidA), "chatA gate closes after omitted suppressReceipt call");

        // 6. Post-call unsolicited receipts remain blocked.
        [gSentAllReceipts removeAllObjects];
        ((void (*)(id, SEL, id))objc_msgSend)(gMockRegistryInstance, sel_registerName("_chat_sendReadReceiptForAllMessages:"), chatA);
        AssertTrue(gSentAllReceipts.count == 0, "post-call unsolicited receipt blocked");

        // 7. Exception safety: @finally closes allow window even if markAllMessagesAsRead throws.
        chatA.throwOnMarkRead = YES;
        @try {
            handleEvent(helper, sHandle, @"mark-chat-read", @{@"chatGuid": guidA, @"suppressReceipt": @NO}, nil);
        } @catch (NSException *ignored) {
        }
        chatA.throwOnMarkRead = NO;
        AssertTrue(!shouldAllow(helperCls, sAllow, guidA), "@finally closes allow gate on exception");

        // 8. Re-entrant ref-counting.
        beginAllow(helperCls, sBegin, guidA);
        beginAllow(helperCls, sBegin, guidA);
        AssertTrue(shouldAllow(helperCls, sAllow, guidA), "nested begin allows chatA");
        endAllow(helperCls, sEnd, guidA);
        AssertTrue(shouldAllow(helperCls, sAllow, guidA), "one end keeps nested allow active");
        endAllow(helperCls, sEnd, guidA);
        AssertTrue(!shouldAllow(helperCls, sAllow, guidA), "second end closes allow");

        printf("PASS: All RR-P0-1 receipt-gate tests passed (%s)\n", argv[1]);
    }
    return 0;
}
