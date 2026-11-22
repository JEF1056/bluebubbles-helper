// Fork-only additions to BlueBubblesHelper, included at the bottom of BlueBubblesHelper.m
// so upstream merges into BlueBubblesHelper.m stay minimal without touching project.pbxproj.

// LPImage comes from LinkPresentation, which is loaded at runtime (see send-rich-link)
@protocol RichLinkImageInit <NSObject>
- (id)initWithData:(NSData *)data MIMEType:(NSString *)mime;
@end

@interface BlueBubblesHelper (Stickers)
+ (void)sendSticker:(NSDictionary *)data transaction:(NSString *)transaction;
@end

// Chat guids actively allowed to send outgoing read receipts during an explicit
// "mark-chat-read" without suppressReceipt. Default-deny blocks all other receipts
// (e.g., Catalyst scene restore / window activation / relaunch).
static NSMutableDictionary<NSString *, NSNumber *> *_allowedReceiptChatCounts = nil;

// Largest image the helper reads for a link preview (the server caps images at the same size)
static const unsigned long long kRichLinkMaxImageBytes = 5 * 1024 * 1024;

// One log line per step so a failed rich link can be diagnosed from the Messages log (NSLog, so it shows in release builds).
// Read it with: log stream --predicate 'eventMessage CONTAINS "HLP-LINK"'
static void RichLinkStep(NSString *step, id result) {
    NSLog(@"HLP-LINK step=%@ result=%@", step, (result != nil ? result : @"nil"));
}

@implementation BlueBubblesHelper (Fork)

+ (void)beginAllowingReceiptsForChat:(NSString *)chatGuid {
    if (chatGuid == nil) return;
    @synchronized(self) {
        if (_allowedReceiptChatCounts == nil) _allowedReceiptChatCounts = [NSMutableDictionary dictionary];
        NSInteger count = [_allowedReceiptChatCounts[chatGuid] integerValue];
        _allowedReceiptChatCounts[chatGuid] = @(count + 1);
    }
}

+ (void)endAllowingReceiptsForChat:(NSString *)chatGuid {
    if (chatGuid == nil) return;
    @synchronized(self) {
        NSInteger count = [_allowedReceiptChatCounts[chatGuid] integerValue];
        if (count <= 1) {
            [_allowedReceiptChatCounts removeObjectForKey:chatGuid];
        } else {
            _allowedReceiptChatCounts[chatGuid] = @(count - 1);
        }
    }
}

+ (BOOL)shouldAllowReceiptForChat:(NSString *)chatGuid {
    if (chatGuid == nil) return NO;
    @synchronized(self) {
        return [_allowedReceiptChatCounts[chatGuid] integerValue] > 0;
    }
}

#pragma mark - Pinned Chats

- (NSArray<NSString *> *)getPinnedChatGuids {
    IMPinnedConversationsController *controller = [IMPinnedConversationsController sharedInstance];
    NSOrderedSet *identifierSet = [controller pinnedConversationIdentifierSet];
    if (identifierSet == nil || identifierSet.count == 0) {
        return @[];
    }

    IMChatRegistry *registry = [IMChatRegistry sharedInstance];
    NSMutableArray<NSString *> *guids = [NSMutableArray arrayWithCapacity:identifierSet.count];
    for (id identifier in identifierSet) {
        if (![identifier isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *pinningId = (NSString *)identifier;
        NSString *resolvedGuid = nil;
        if ([registry respondsToSelector:@selector(existingChatWithPinningIdentifier:)]) {
            IMChat *chat = [registry existingChatWithPinningIdentifier:pinningId];
            if (chat != nil && chat.guid != nil) {
                resolvedGuid = chat.guid;
            }
        }
        [guids addObject:(resolvedGuid != nil ? resolvedGuid : pinningId)];
    }
    return [guids copy];
}

#pragma mark - Fork Event Dispatch

- (BOOL)handleForkServerEvent:(NSString *)event data:(NSDictionary *)data transaction:(NSString *)transaction {
    if ([event isEqualToString:@"get-pinned-chats"]) {
        SendTransactionResponse(transaction, @{@"pinnedChatGuids": [self getPinnedChatGuids]});
        return YES;
    } else if ([event isEqualToString:@"update-chat-pinned"]) {
        IMChat *chat = [self getIMChatFromGuid: data[@"chatGuid"] transaction: transaction];
        if (chat == nil) {
            return YES;
        }
        BOOL shouldPin = (data[@"pinned"] != nil && data[@"pinned"] != [NSNull null])
            ? [data[@"pinned"] boolValue]
            : !chat.isPinned;
        IMPinnedConversationsController *controller = [IMPinnedConversationsController sharedInstance];
        NSArray *arr = [[controller pinnedConversationIdentifierSet] array];
        NSMutableArray<NSString *> *chatArr = arr != nil ? [arr mutableCopy] : [NSMutableArray array];
        NSString *pinningId = chat.pinningIdentifier;
        if (pinningId == nil) {
            SendTransactionResponse(transaction, @{@"error": @"Chat does not have a pinningIdentifier!"});
            return YES;
        }
        if (shouldPin) {
            if (![chatArr containsObject:pinningId]) {
                [chatArr addObject:pinningId];
                [controller setPinnedConversationIdentifiers:[chatArr copy] withUpdateReason:@"contextMenu"];
            }
        } else {
            if ([chatArr containsObject:pinningId]) {
                [chatArr removeObject:pinningId];
                [controller setPinnedConversationIdentifiers:[chatArr copy] withUpdateReason:@"contextMenu"];
            }
        }
        SendTransactionResponse(transaction, @{@"pinnedChatGuids": [self getPinnedChatGuids]});
        return YES;
    } else if ([event isEqualToString:@"send-rich-link"]) {
        [BlueBubblesHelper sendRichLink:(data) transaction:(transaction)];
        return YES;
    } else if ([event isEqualToString:@"send-sticker"]) {
        [BlueBubblesHelper sendSticker:(data) transaction:(transaction)];
        return YES;
    } else if ([event isEqualToString:@"set-nickname-info"]) {
        NSString *displayName = [data[@"displayName"] isKindOfClass:[NSString class]] && [data[@"displayName"] length] > 0 ? data[@"displayName"] : nil;
        NSString *avatarPath = [data[@"avatarPath"] isKindOfClass:[NSString class]] && [data[@"avatarPath"] length] > 0 ? data[@"avatarPath"] : nil;
        NSString *avatarBytes = [data[@"avatarBytes"] isKindOfClass:[NSString class]] && [data[@"avatarBytes"] length] > 0 ? data[@"avatarBytes"] : nil;

        if (displayName == nil) {
            if (transaction != nil) {
                SendTransactionResponse(transaction, @{@"error": @"displayName is required"});
            }
            return YES;
        }

        // Split displayName into first/last for IMNickname's initWithFirstName:lastName:avatar:
        NSString *firstName = displayName;
        NSString *lastName = @"";
        NSRange spaceRange = [displayName rangeOfString:@" "];
        if (spaceRange.location != NSNotFound) {
            firstName = [displayName substringToIndex:spaceRange.location];
            lastName = [[displayName substringFromIndex:(spaceRange.location + 1)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }

        // Resolve avatar image data + on-disk path. IMNicknameAvatarImage prefers a path Apple controls.
        static const unsigned long long kNicknameMaxAvatarBytes = 20ULL * 1024ULL * 1024ULL;
        NSData *imageData = nil;
        NSString *resolvedAvatarPath = nil;
        if (avatarPath != nil) {
            NSString *resolved = [[avatarPath stringByStandardizingPath] stringByResolvingSymlinksInPath];
            NSString *root = [[[BlueBubblesHelper richLinkImageRoot] stringByStandardizingPath] stringByResolvingSymlinksInPath];
            NSError *readError = nil;
            NSString *rejected = nil;
            if (root == nil || ![resolved hasPrefix:[root stringByAppendingString:@"/"]]) {
                rejected = @"avatarPath outside the attachment store";
            } else {
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:resolved error:&readError];
                if (attrs == nil || ![[attrs fileType] isEqualToString:NSFileTypeRegular]) {
                    rejected = @"avatarPath is not a regular file";
                } else if ([attrs fileSize] > kNicknameMaxAvatarBytes) {
                    rejected = @"avatarPath exceeds 20MB limit";
                } else {
                    imageData = [NSData dataWithContentsOfFile:resolved options:0 error:&readError];
                    if (imageData == nil) {
                        rejected = @"failed to read avatarPath";
                    } else {
                        resolvedAvatarPath = resolved;
                    }
                }
            }
            if (rejected != nil) {
                if (transaction != nil) {
                    SendTransactionResponse(transaction, @{@"error": rejected});
                }
                return YES;
            }
        } else if (avatarBytes != nil) {
            imageData = [[NSData alloc] initWithBase64EncodedString:avatarBytes options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (imageData != nil && [imageData length] > kNicknameMaxAvatarBytes) {
                if (transaction != nil) {
                    SendTransactionResponse(transaction, @{@"error": @"avatarBytes exceeds 20MB limit"});
                }
                return YES;
            }
        }

        IMNicknameAvatarImage *avatar = nil;
        if (imageData != nil) {
            // Copy bytes into the path Apple expects so the avatar persists across syncs.
            NSString *destPath = [IMNickname uniqueFilePathForWritingImageData];
            NSError *writeError = nil;
            avatar = [[IMNicknameAvatarImage alloc] initWithImageName:displayName imageData:imageData imageFilePath:(destPath ?: resolvedAvatarPath) error:&writeError];
            if (avatar == nil && resolvedAvatarPath != nil) {
                avatar = [[IMNicknameAvatarImage alloc] initWithImageName:displayName imageFilePath:resolvedAvatarPath];
            }
        }

        IMNickname *nickname = [[IMNickname alloc] initWithFirstName:firstName lastName:lastName avatar:avatar];
        [nickname setDisplayName:displayName];

        IMNicknameController *controller = [IMNicknameController sharedInstance];
        [controller updatePersonalNickname:nickname];
        // Persist locally so Messages.app picks it up on next launch as well as immediately.
        if ([controller respondsToSelector:@selector(_updateLocalNicknameStore)]) {
            [controller _updateLocalNicknameStore];
        }

        if (transaction != nil) {
            SendTransactionResponse(transaction, @{@"name": displayName, @"avatar_path": avatarPath ?: [NSNull null]});
        }
        return YES;
    }
    return NO;
}

#pragma mark - Rich link sending

// The folder an imagePath has to be in: ~/Library/Messages/Attachments of the real user (where the server saves
// attachments). NSHomeDirectory() is the app container inside Messages, so the home comes from getpwuid.
+ (NSString *)richLinkImageRoot {
    struct passwd *pw = getpwuid(getuid());
    if (pw == NULL || pw->pw_dir == NULL) return nil;
    return [[NSString stringWithUTF8String:pw->pw_dir] stringByAppendingPathComponent:@"Library/Messages/Attachments"];
}

// Replies to the server with an error for this transaction (if there is one). Nothing is sent to the chat.
+ (void)richLinkFail:(NSString *)why transaction:(NSString *)transaction {
    RichLinkStep(@"failed", why);
    if (transaction != nil) {
        SendTransactionResponse(transaction, @{@"error": [@"send-rich-link: " stringByAppendingString:why]});
    }
}

// Sends the link as plain text instead. This also sends the reply for the transaction.
+ (void)richLinkFallback:(NSString *)why data:(NSDictionary *)data url:(NSURL *)url transaction:(NSString *)transaction {
    RichLinkStep(@"fallback", [@"plain url, " stringByAppendingString:why]);
    NSString *chatGuid = [data[@"chatGuid"] isKindOfClass:[NSString class]] ? data[@"chatGuid"] : nil;
    NSString *urlText = [url absoluteString];
    if (chatGuid.length == 0 || urlText.length == 0) {
        [self richLinkFail:why transaction:transaction];
        return;
    }
    [BlueBubblesHelper sendMessage:@{@"chatGuid": chatGuid, @"message": urlText} transfers:nil attributedString:nil transaction:transaction];
}

// Builds the RichLink keyed archive Messages uses for a link balloon (an LPLinkMetadata, with the image
// replaced by an attachment substitute). Returns nil and sets *err on failure.
// The substituted image data is returned in *outAttachments, in archive order.
+ (NSData *)richLinkPayloadForUrl:(NSURL *)url title:(NSString *)title siteName:(NSString *)siteName summary:(NSString *)summary imageData:(NSData *)imageData imageMime:(NSString *)imageMime attachments:(NSArray **)outAttachments error:(NSString **)err {
    // LinkPresentation is not linked into the bundle, so the classes are looked up at runtime
    void *lp = dlopen("/System/Library/Frameworks/LinkPresentation.framework/LinkPresentation", RTLD_NOW);
    Class metadataClass = NSClassFromString(@"LPLinkMetadata");
    Class imageClass = NSClassFromString(@"LPImage");
    Class substituterClass = NSClassFromString(@"RichLinkAttachmentSubstituter");
    Class substituteImageClass = NSClassFromString(@"LPImageAttachmentSubstitute");
    if (lp == NULL || metadataClass == nil || imageClass == nil || substituterClass == nil || substituteImageClass == nil) {
        *err = @"LinkPresentation classes missing";
        return nil;
    }

    id metadata = [[metadataClass alloc] init];
    [metadata setValue:url forKey:@"URL"];
    [metadata setValue:url forKey:@"originalURL"];
    if ([title length] > 0) { [metadata setValue:title forKey:@"title"]; }
    if ([summary length] > 0) { [metadata setValue:summary forKey:@"summary"]; }
    if ([siteName length] > 0) { [metadata setValue:siteName forKey:@"siteName"]; }
    [metadata setValue:@"object" forKey:@"itemType"];

    if (imageData != nil) {
        id image = [(id<RichLinkImageInit>)[imageClass alloc] initWithData:imageData MIMEType:imageMime];
        if (image == nil) {
            *err = @"image decode failed";
            return nil;
        }
        [metadata setValue:image forKey:@"image"];
        [metadata setValue:@"summary_large_image" forKey:@"twitterCard"];
    }

    // The root object has to be called "RichLink" in the archive, like the payloads Messages writes.
    // There is no public class for it, so one is registered here that encodes the metadata the same way.
    Class rootClass = objc_allocateClassPair([NSObject class], "BBRichLinkRoot", 0);
    if (rootClass == Nil) {
        rootClass = NSClassFromString(@"BBRichLinkRoot");
    } else {
        IMP encode = imp_implementationWithBlock(^(id self_, NSCoder *coder) {
            [coder encodeBool:NO forKey:@"richLinkIsPlaceholder"];
            [coder encodeObject:objc_getAssociatedObject(self_, "metadata") forKey:@"richLinkMetadata"];
        });
        class_addMethod(rootClass, @selector(encodeWithCoder:), encode, "v@:@");
        IMP secure = imp_implementationWithBlock(^BOOL(id self_) { return YES; });
        class_addMethod(object_getClass(rootClass), @selector(supportsSecureCoding), secure, "c@:");
        class_addProtocol(rootClass, @protocol(NSSecureCoding));
        objc_registerClassPair(rootClass);
    }
    id root = [[rootClass alloc] init];
    objc_setAssociatedObject(root, "metadata", metadata, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id substituter = [[substituterClass alloc] init];
    [substituter setValue:@YES forKey:@"shouldSubstituteAttachments"];

    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver setClassName:@"RichLink" forClass:rootClass];
    [archiver setClassName:@"RichLinkImageAttachmentSubstitute" forClass:substituteImageClass];
    archiver.delegate = (id<NSKeyedArchiverDelegate>)substituter;
    [archiver encodeObject:root forKey:NSKeyedArchiveRootObjectKey];
    [archiver finishEncoding];
    NSData *payload = archiver.encodedData;
    if (payload == nil || [payload length] == 0) {
        *err = @"archive failed";
        return nil;
    }
    *outAttachments = [substituter valueForKey:@"archivedAttachments"];
    return payload;
}

// Registers one substituted image as a hidden IMFileTransfer, the way Messages does for a link balloon: the file is
// named <UUID>.pluginPayloadAttachment and sits in the attachment store (<store>/xx/yy/<transfer GUID>/<name>).
// imagent refuses a transfer whose file is outside the store, so the file is copied there before registering.
// stagingDir must be inside ~/Library/Messages (the folder the server keeps its attachments in).
// Returns the transfer GUID, or nil on any failure (nothing is left behind in that case).
+ (NSString *)richLinkTransferGuidForBlob:(NSData *)blob stagingDir:(NSString *)stagingDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *stagedURL = nil;
    @try {
        NSString *name = [[[NSUUID UUID] UUIDString] stringByAppendingString:@".pluginPayloadAttachment"];
        stagedURL = [NSURL fileURLWithPath:[stagingDir stringByAppendingPathComponent:name]];
        NSError *error = nil;
        BOOL ok = [blob writeToURL:stagedURL options:NSDataWritingAtomic error:&error];
        RichLinkStep(@"stage-write", ok ? [NSString stringWithFormat:@"ok %lu bytes", (unsigned long)[blob length]] : [NSString stringWithFormat:@"FAILED %@", error]);
        if (!ok) { stagedURL = nil; return nil; }

        IMFileTransferCenter *center = [IMFileTransferCenter sharedInstance];
        NSString *guid = [center guidForNewOutgoingTransferWithLocalURL:stagedURL];
        IMFileTransfer *transfer = (guid != nil ? [center transferForGUID:guid] : nil);
        RichLinkStep(@"transfer-object", transfer != nil ? guid : nil);
        if (transfer == nil) { [fm removeItemAtURL:stagedURL error:nil]; return nil; }

        // Ask the daemon where the file belongs. Inside Messages it can answer nil, so build the same layout here then.
        NSString *persistentPath = [[IMDPersistentAttachmentController sharedInstance] _persistentPathForTransfer:transfer filename:name highQuality:TRUE chatGUID:nil storeAtExternalPath:TRUE];
        RichLinkStep(@"persistent-path-daemon", persistentPath);
        if (![persistentPath isKindOfClass:[NSString class]] || [persistentPath length] == 0) {
            NSString *store = [self richLinkImageRoot] ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Messages/Attachments"];
            // xx/yy as in the attachment rows Messages writes: two hex digits, then a small decimal number
            NSString *xx = [NSString stringWithFormat:@"%02x", arc4random_uniform(256)];
            NSString *yy = [NSString stringWithFormat:@"%02u", arc4random_uniform(16)];
            persistentPath = [[[[store stringByAppendingPathComponent:xx] stringByAppendingPathComponent:yy] stringByAppendingPathComponent:[transfer guid]] stringByAppendingPathComponent:name];
            RichLinkStep(@"persistent-path-own", persistentPath);
        }
        NSURL *persistentURL = [NSURL fileURLWithPath:persistentPath];
        error = nil;
        ok = [fm createDirectoryAtURL:[persistentURL URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error];
        RichLinkStep(@"store-dir-create", ok ? @"ok" : [NSString stringWithFormat:@"FAILED %@", error]);
        if (!ok) { [fm removeItemAtURL:stagedURL error:nil]; return nil; }
        error = nil;
        ok = [fm copyItemAtURL:stagedURL toURL:persistentURL error:&error];
        RichLinkStep(@"file-copy", ok ? @"ok" : [NSString stringWithFormat:@"FAILED %@", error]);
        [fm removeItemAtURL:stagedURL error:nil];
        stagedURL = nil;
        if (!ok) { return nil; }

        [center retargetTransfer:[transfer guid] toPath:persistentPath];
        transfer.localURL = persistentURL;
        // The payload image must not show up as a separate attachment in the chat. Set before registering so the daemon sees it.
        transfer.hideAttachment = 1;
        // The file must be in its final place before this
        [center registerTransferWithDaemon:[transfer guid]];
        RichLinkStep(@"transfer-register", [transfer guid]);
        return [transfer guid];
    } @catch (NSException *ex) {
        RichLinkStep(@"transfer-exception", ex.reason);
        if (stagedURL != nil) { [fm removeItemAtURL:stagedURL error:nil]; }
        return nil;
    }
}

// Sends a link with a preview balloon (title, site name, summary and an optional image) instead of plain text.
// data: chatGuid, url, title, siteName, summary (all but chatGuid and url optional), imagePath (optional, a PNG or
// JPEG inside ~/Library/Messages/Attachments, at most 5 MB). Replies like the other send actions: transactionId and identifier.
// If the image can not be attached, the link is sent with the text fields only. If anything else fails (unreadable
// image, archive error, exception), the URL is sent as plain text. Only a chat or URL that can not be resolved
// returns an error and sends nothing. Once the message has been handed to Messages the reply never carries an error
// (an exception after that point replies with an empty identifier), so the server does not send the link twice.
+ (void)sendRichLink:(NSDictionary *)data transaction:(NSString *)transaction {
    NSURL *url = nil;
    BOOL sent = NO;
    @try {
        NSString *chatGuid = data[@"chatGuid"];
        IMChat *chat = ([chatGuid isKindOfClass:[NSString class]] ? [[IMChatRegistry sharedInstance] existingChatWithGUID:chatGuid] : nil);
        if (chat == nil) { [self richLinkFail:@"chat not found" transaction:transaction]; return; }

        NSString *urlString = data[@"url"];
        url = ([urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil);
        if (url == nil || url.scheme == nil || url.host == nil) { [self richLinkFail:@"bad url" transaction:transaction]; return; }

        // Optional text fields are NSNull when the server has nothing for them
        NSString *title = ([data[@"title"] isKindOfClass:[NSString class]] ? data[@"title"] : nil);
        NSString *siteName = ([data[@"siteName"] isKindOfClass:[NSString class]] ? data[@"siteName"] : nil);
        NSString *summary = ([data[@"summary"] isKindOfClass:[NSString class]] ? data[@"summary"] : nil);

        NSData *imageData = nil;
        NSString *imageMime = nil;
        NSString *imagePath = ([data[@"imagePath"] isKindOfClass:[NSString class]] && [data[@"imagePath"] length] > 0 ? data[@"imagePath"] : nil);
        NSString *imageDir = nil;
        if (imagePath != nil) {
            // Only files inside the Messages attachment store are read (real path, symlinks resolved), up to a size cap
            NSString *resolved = [[imagePath stringByStandardizingPath] stringByResolvingSymlinksInPath];
            NSString *root = [[[BlueBubblesHelper richLinkImageRoot] stringByStandardizingPath] stringByResolvingSymlinksInPath];
            NSError *readError = nil;
            NSString *rejected = nil;
            if (root == nil || ![resolved hasPrefix:[root stringByAppendingString:@"/"]]) {
                rejected = @"path outside the attachment store";
            } else {
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:resolved error:&readError];
                if (attrs == nil || ![[attrs fileType] isEqualToString:NSFileTypeRegular]) {
                    rejected = @"not a regular file";
                } else if ([attrs fileSize] > kRichLinkMaxImageBytes) {
                    rejected = [NSString stringWithFormat:@"file too large (%llu bytes)", [attrs fileSize]];
                }
            }
            if (rejected == nil) {
                imageData = [NSData dataWithContentsOfFile:resolved options:0 error:&readError];
                // PNG or JPEG only, by the first bytes (the extension is not trusted)
                const unsigned char *b = (const unsigned char *)[imageData bytes];
                if (imageData != nil) {
                    if ([imageData length] > 8 && memcmp(b, "\x89PNG\r\n\x1a\n", 8) == 0) { imageMime = @"image/png"; }
                    else if ([imageData length] > 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) { imageMime = @"image/jpeg"; }
                    else { rejected = @"not a PNG or JPEG"; imageData = nil; }
                }
            }
            RichLinkStep(@"image-read", imageData != nil ? [NSString stringWithFormat:@"ok %lu bytes", (unsigned long)[imageData length]] : [NSString stringWithFormat:@"FAILED %@", rejected ?: readError]);
            if (imageData == nil) { [self richLinkFallback:@"image unreadable" data:data url:url transaction:transaction]; return; }
            imageDir = [resolved stringByDeletingLastPathComponent];
        }

        NSArray *attachments = nil;
        NSString *buildError = nil;
        NSData *payload = [self richLinkPayloadForUrl:url title:title siteName:siteName summary:summary imageData:imageData imageMime:imageMime attachments:&attachments error:&buildError];
        RichLinkStep(@"payload-build", payload != nil ? [NSString stringWithFormat:@"ok %lu bytes, %lu substituted attachments", (unsigned long)[payload length], (unsigned long)[attachments count]] : [@"FAILED " stringByAppendingString:(buildError ?: @"unknown")]);
        if (payload == nil) { [self richLinkFallback:(buildError ?: @"payload build failed") data:data url:url transaction:transaction]; return; }

        // One hidden file transfer per substituted image, in archive order. If one fails, the preview goes out without
        // its image (the archive is the same, only the transfers are dropped).
        NSMutableArray<NSString *> *transferGuids = [[NSMutableArray alloc] init];
        for (NSData *blob in attachments) {
            NSString *transferGuid = [self richLinkTransferGuidForBlob:blob stagingDir:imageDir];
            if (transferGuid == nil) {
                [transferGuids removeAllObjects];
                RichLinkStep(@"fallback", @"sending without the image");
                break;
            }
            [transferGuids addObject:transferGuid];
        }

        // The message text is the URL itself, marked as a rich link
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:[url absoluteString]];
        [text addAttributes:@{
            @"__kIMBaseWritingDirectionAttributeName": @(-1),
            @"__kIMLinkIsRichLinkAttributeName": @YES,
            @"__kIMLinkAttributeName": url,
            @"__kIMMessagePartAttributeName": @0,
        } range:NSMakeRange(0, [text length])];

        IMMessage *message = [[IMMessage alloc] init];
        message = [message initWithSender:(nil) time:(nil) text:(text) messageSubject:(nil) fileTransferGUIDs:([transferGuids copy]) flags:(0x100005) error:(nil) guid:(nil) subject:(nil) balloonBundleID:(@"com.apple.messages.URLBalloonProvider") payloadData:(payload) expressiveSendStyleID:(nil)];
        if (message == nil) { [self richLinkFallback:@"IMMessage init failed" data:data url:url transaction:transaction]; return; }
        // From here on the message may be out, so no path below may make the server send the link again
        sent = YES;
        [chat sendMessage:message];
        NSString *sentGuid = [[chat lastSentMessage] guid];
        RichLinkStep(@"send", sentGuid);
        if (transaction != nil) {
            SendTransactionResponse(transaction, @{@"identifier": (sentGuid ?: @"")});
        }
    } @catch (NSException *ex) {
        NSString *why = [NSString stringWithFormat:@"exception %@", ex.reason];
        if (sent) {
            // Already handed to Messages: reply with an empty identifier, not an error, so the server does not send it again
            RichLinkStep(@"failed-after-send", why);
            if (transaction != nil) { SendTransactionResponse(transaction, @{@"identifier": @""}); }
        } else if (url != nil) {
            [self richLinkFallback:why data:data url:url transaction:transaction];
        } else {
            [self richLinkFail:why transaction:transaction];
        }
    }
}

#pragma mark - Native Tapback Sender (macOS 15+)

+ (BOOL)trySendNativeTapback:(NSDictionary *)data chat:(IMChat *)chat message:(IMMessage *)message item:(IMMessagePartChatItem *)item partIndex:(NSInteger)partIndex reactionLong:(long long)reactionLong transaction:(NSString *)transaction {
    NSString *reaction = data[@"reactionType"];
    NSString *emojiStr = (data[@"emoji"] != nil && [data[@"emoji"] isKindOfClass:[NSString class]]) ? data[@"emoji"] : nil;

    // Use native IMTapbackSender on macOS 15+ so RCS and iMessage tapbacks (classic + emoji)
    // go through Apple's native Messages pipeline with proper ampt/GUID formatting.
    Class tapbackSenderCls = NSClassFromString(@"IMTapbackSender");
    BOOL sentViaNativeTapback = NO;
    if (tapbackSenderCls != nil && reactionLong != 0) {
        id tapback = nil;
        if (reactionLong == 2006 || reactionLong == 3006) {
            Class emojiTapbackCls = NSClassFromString(@"IMEmojiTapback");
            if (emojiTapbackCls != nil && emojiStr.length > 0 && [emojiTapbackCls instancesRespondToSelector:@selector(initWithEmoji:isRemoved:)]) {
                tapback = ((id (*)(id, SEL, NSString *, BOOL))objc_msgSend)([emojiTapbackCls alloc], @selector(initWithEmoji:isRemoved:), emojiStr, (reactionLong == 3006));
            }
        } else {
            Class classicTapbackCls = NSClassFromString(@"IMClassicTapback");
            if (classicTapbackCls != nil && [classicTapbackCls instancesRespondToSelector:@selector(initWithAssociatedMessageType:)]) {
                tapback = ((id (*)(id, SEL, long long))objc_msgSend)([classicTapbackCls alloc], @selector(initWithAssociatedMessageType:), reactionLong);
            }
        }

        if (tapback != nil) {
            id senderObj = nil;
            if (item != nil && [tapbackSenderCls instancesRespondToSelector:@selector(initWithTapback:chat:messagePartChatItem:)]) {
                senderObj = ((id (*)(id, SEL, id, id, id))objc_msgSend)([tapbackSenderCls alloc], @selector(initWithTapback:chat:messagePartChatItem:), tapback, chat, item);
            }
            // Fall back to explicit GUID/summary initializer when messagePartChatItem returns nil (e.g. attachments or non-text parts).
            if (senderObj == nil && [tapbackSenderCls instancesRespondToSelector:@selector(initWithTapback:chat:messageGUID:messagePartRange:messageSummaryInfo:threadIdentifier:)]) {
                NSString *fbText = (item != nil && [item text] != nil) ? [item text].string : ([message text].string ?: @"");
                NSRange fbRange = (item != nil) ? [item messagePartRange] : NSMakeRange(0, fbText.length);
                BOOL isAttachmentPart = (fbText.length == 0 || [fbText isEqualToString:@"\uFFFC"]);
                NSDictionary *fbSummary = isAttachmentPart ? @{@"amc": @3} : @{@"amc": @1, @"ams": fbText};
                NSString *fbGuid = [NSString stringWithFormat:@"p:%ld/%@", (long)partIndex, [message guid]];
                senderObj = ((id (*)(id, SEL, id, id, NSString *, NSRange, NSDictionary *, NSString *))objc_msgSend)(
                    [tapbackSenderCls alloc],
                    @selector(initWithTapback:chat:messageGUID:messagePartRange:messageSummaryInfo:threadIdentifier:),
                    tapback,
                    chat,
                    fbGuid,
                    fbRange,
                    fbSummary,
                    message.threadIdentifier
                );
            }
            if (senderObj != nil && [senderObj respondsToSelector:@selector(send)]) {
                NSString *prevLastGuid = [[chat lastSentMessage] guid];
                id rawSentGuid = ((id (*)(id, SEL))objc_msgSend)(senderObj, @selector(send));
                NSString *sentGuid = [rawSentGuid isKindOfClass:[NSString class]] ? (NSString *)rawSentGuid : nil;
                if (sentGuid.length == 0) {
                    NSString *afterLastGuid = [[chat lastSentMessage] guid];
                    if (afterLastGuid.length > 0 && ![afterLastGuid isEqualToString:prevLastGuid]) {
                        sentGuid = afterLastGuid;
                    }
                }
                if (sentGuid.length > 0) {
                    sentViaNativeTapback = YES;
                    if (transaction != nil) {
                        [[NetworkController sharedInstance] sendMessage:@{@"transactionId": transaction, @"identifier": sentGuid}];
                    }
                } else {
                    DLog("BLUEBUBBLESHELPER: IMTapbackSender -send returned empty guid for reaction %{public}@ on %{public}@", reaction, [message guid]);
                }
            } else {
                DLog("BLUEBUBBLESHELPER: IMTapbackSender init returned nil for reaction %{public}@ on %{public}@", reaction, [message guid]);
            }
        } else {
            DLog("BLUEBUBBLESHELPER: Failed to construct native tapback for reaction %{public}@ (emoji=%{public}@)", reaction, emojiStr ?: @"");
        }
    }
    return sentViaNativeTapback;
}

@end

static id BBPerformIfResponds(id obj, const char *selName) {
    SEL sel = sel_registerName(selName);
    return (obj != nil && [obj respondsToSelector:sel]) ? ((id (*)(id, SEL))objc_msgSend)(obj, sel) : nil;
}

static BOOL BBShouldSuppressChatReceipt(id chat) {
    NSString *guid = BBPerformIfResponds(chat, "guid");
    BOOL suppress = ![BlueBubblesHelper shouldAllowReceiptForChat:guid];
    NSLog(@"BlueBubblesHelper: %@ read receipt for chat %@", suppress ? @"Suppressed" : @"Sending", guid);
    return suppress;
}

// macOS Tahoe (26+) typing indicator support
ZKSwizzleInterface(BBH_CKConversationListStandardCell, CKConversationListStandardCell, NSObject)
@implementation BBH_CKConversationListStandardCell

- (void)setShowTypingIndicator:(BOOL)show {
    ZKOrig(void, show);

    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 26) {
        return;
    }

    @try {
        id conversation = BBPerformIfResponds(self, "conversation");
        id chat = BBPerformIfResponds(conversation, "chat");
        NSString *guid = BBPerformIfResponds(chat, "guid");
        if (guid != nil) {
            [[NetworkController sharedInstance] sendMessage:@{@"event": show ? @"started-typing" : @"stopped-typing", @"guid": guid}];
            DLog("BLUEBUBBLESHELPER: %{public}@ %s typing (Tahoe)", guid, show ? "started" : "stopped");
        }
    } @catch (NSException *e) {
        DLog("BLUEBUBBLESHELPER: Typing indicator exception: %@", e);
    }
}

@end

// Default-deny outgoing read receipts. IMCore triggers receipt sends synchronously from
// markAllMessagesAsRead / markMessagesAsRead:; no-op'ing here keeps local read state
// unless BlueBubblesHelper explicitly allows the chat for an active "mark-chat-read"
// request without suppressReceipt.
ZKSwizzleInterface(BBH_IMChatRegistry_Receipts, IMChatRegistry, NSObject)
@implementation BBH_IMChatRegistry_Receipts

- (void)_chat:(id)chat sendReadReceiptForMessages:(id)messages {
    if (BBShouldSuppressChatReceipt(chat)) return;
    ZKOrig(void, chat, messages);
}

- (void)_chat_sendReadReceiptForAllMessages:(id)chat {
    if (BBShouldSuppressChatReceipt(chat)) return;
    ZKOrig(void, chat);
}

@end

#pragma mark - Sticker sending & iCloud Sticker store XPC

@interface BlueBubblesHelper (Stickers)
+ (void)sendSticker:(NSDictionary *)data transaction:(NSString *)transaction;
@end

@implementation BlueBubblesHelper (Stickers)

+ (NSDictionary *)normalizedStickerUserInfo:(NSDictionary *)data {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSDictionary *raw = [data[@"stickerUserInfo"] isKindOfClass:[NSDictionary class]] ? data[@"stickerUserInfo"] : data;
    NSDictionary *aliases = @{
        @"sxs": @"xScalar",
        @"sys": @"yScalar",
        @"ssa": @"scale",
        @"sro": @"rotation",
        @"spw": @"parentPreviewWidth"
    };
    for (NSString *key in aliases) {
        id val = raw[key] ?: raw[aliases[key]];
        if ([val isKindOfClass:[NSNumber class]] || [val isKindOfClass:[NSString class]]) {
            info[key] = @([val doubleValue]);
        }
    }
    if (info.count > 0 && raw[@"spv"] == nil) {
        info[@"spv"] = @1;
    }
    for (NSString *extraKey in @[@"spv", @"sid", @"shash", @"suri", @"pid", @"sir", @"sli", @"sai"]) {
        id val = raw[extraKey];
        if (val != nil && val != [NSNull null]) {
            info[extraKey] = val;
        }
    }
    return [info copy];
}

+ (void)sendSticker:(NSDictionary *)data transaction:(NSString *)transaction {
    NSString *chatGuid = [data[@"chatGuid"] isKindOfClass:[NSString class]] ? data[@"chatGuid"] : nil;
    NSString *filePath = [data[@"filePath"] isKindOfClass:[NSString class]] ? data[@"filePath"] : nil;
    if (chatGuid.length == 0 || filePath.length == 0) {
        if (transaction != nil) {
            SendTransactionResponse(transaction, @{@"error": @"Missing chatGuid or filePath for send-sticker"});
        }
        return;
    }

    NSURL *fileUrl = [NSURL fileURLWithPath:filePath];
    NSString *filename = [fileUrl lastPathComponent] ?: @"sticker.png";
    IMFileTransfer *fileTransfer = [BlueBubblesHelper prepareFileTransferForAttachment:fileUrl filename:filename];
    NSString *transferGuid = [fileTransfer guid];
    if (transferGuid == nil) {
        if (transaction != nil) {
            SendTransactionResponse(transaction, @{@"error": @"Failed to prepare sticker file transfer"});
        }
        return;
    }

    if ([fileTransfer respondsToSelector:@selector(setIsSticker:)]) {
        [fileTransfer setIsSticker:YES];
    }
    NSDictionary *stickerUserInfo = [self normalizedStickerUserInfo:data];
    if (stickerUserInfo.count > 0 && [fileTransfer respondsToSelector:@selector(setStickerUserInfo:)]) {
        [fileTransfer setStickerUserInfo:stickerUserInfo];
    }

    NSMutableAttributedString *attachmentStr = [[NSMutableAttributedString alloc] initWithString:@"\ufffc"];
    [attachmentStr addAttributes:@{
        @"__kIMBaseWritingDirectionAttributeName": @"-1",
        @"__kIMFileTransferGUIDAttributeName": transferGuid,
        @"__kIMFilenameAttributeName": filename,
        @"__kIMMessagePartAttributeName": @0,
    } range:NSMakeRange(0, 1)];

    NSString *assocGuidRaw = [data[@"associatedMessageGuid"] isKindOfClass:[NSString class]]
        ? data[@"associatedMessageGuid"]
        : ([data[@"selectedMessageGuid"] isKindOfClass:[NSString class]] ? data[@"selectedMessageGuid"] : nil);

    if (assocGuidRaw.length > 0) {
        IMChat *chat = [[BlueBubblesHelper sharedInstance] getIMChatFromGuid:chatGuid transaction:transaction];
        if (chat == nil) return;

        id partRaw = (data[@"associatedMessagePart"] != nil && data[@"associatedMessagePart"] != [NSNull null])
            ? data[@"associatedMessagePart"]
            : data[@"partIndex"];
        NSInteger partIndex = ([partRaw isKindOfClass:[NSNumber class]] || [partRaw isKindOfClass:[NSString class]])
            ? [partRaw integerValue]
            : 0;
        id assocTypeRaw = data[@"associatedMessageType"];
        long long assocType = ([assocTypeRaw isKindOfClass:[NSNumber class]] || [assocTypeRaw isKindOfClass:[NSString class]])
            ? [assocTypeRaw longLongValue]
            : 1000;
        NSString *assocGuid = [assocGuidRaw hasPrefix:@"p:"]
            ? assocGuidRaw
            : [NSString stringWithFormat:@"p:%ld/%@", (long)partIndex, assocGuidRaw];

        IMMessage *messageToSend = [[IMMessage alloc] initWithSender:nil
                                                                time:nil
                                                                text:attachmentStr
                                                      messageSubject:nil
                                                   fileTransferGUIDs:@[transferGuid]
                                                               flags:0x100005
                                                               error:nil
                                                                guid:nil
                                                             subject:nil
                                               associatedMessageGUID:assocGuid
                                               associatedMessageType:assocType
                                              associatedMessageRange:NSMakeRange(0, 1)
                                                  messageSummaryInfo:nil];
        [chat sendMessage:messageToSend];
        if (transaction != nil) {
            SendTransactionResponse(transaction, @{@"identifier": [[chat lastSentMessage] guid] ?: [NSNull null]});
        }
        return;
    }

    [BlueBubblesHelper sendMessage:data transfers:@[transferGuid] attributedString:attachmentStr transaction:transaction];
}

@end
