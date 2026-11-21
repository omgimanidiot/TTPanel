#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kEnabled = @"ttpanel_enabled";
static NSString *const kMessage = @"ttpanel_message";
static NSString *const kTargets = @"ttpanel_targets";
static NSString *const kKnown = @"ttpanel_known";
static NSString *const kSent = @"ttpanel_sent";
static NSString *const kMe = @"ttpanel_me";

static BOOL gRunning = NO;
static BOOL gTraceOn = NO;
static BOOL gPassive = NO;
static NSMutableString *gTraceLog;
static __weak id gSendController;
static id gOwnController;
static id gLastConv;
static id gSDK;
static NSMutableDictionary *gConvs;

static NSUserDefaults *D(void) {
    return NSUserDefaults.standardUserDefaults;
}

static void TTOnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static NSString *TTToday(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:NSDate.date];
}

static NSArray<NSString *> *TTTargets(void) {
    return [D() arrayForKey:kTargets] ?: @[];
}

static BOOL TTSentToday(NSString *cid) {
    NSDictionary *d = [D() dictionaryForKey:kSent];
    return [d[cid] isEqualToString:TTToday()];
}

static void TTMarkSentID(NSString *cid) {
    NSMutableDictionary *d = [([D() dictionaryForKey:kSent] ?: @{}) mutableCopy];
    d[cid] = TTToday();
    [D() setObject:d forKey:kSent];
}

static void TTUnmarkSentID(NSString *cid) {
    NSMutableDictionary *d = [([D() dictionaryForKey:kSent] ?: @{}) mutableCopy];
    [d removeObjectForKey:cid];
    [D() setObject:d forKey:kSent];
}

static void TTTraceAdd(NSString *line) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gTraceLog) gTraceLog = [NSMutableString string];
        if (gTraceLog.length > 60000) [gTraceLog deleteCharactersInRange:NSMakeRange(0, 20000)];
        [gTraceLog appendFormat:@"%@\n", line];
    });
}

static NSString *TTShort(id o) {
    if (!o) return @"nil";
    NSString *d = nil;
    @try { d = [o description]; } @catch (...) { d = @"?"; }
    if (d.length > 300) d = [[d substringToIndex:300] stringByAppendingString:@"..."];
    return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([o class]), d];
}

static BOOL TTIsPlain(id o) {
    return [o isKindOfClass:NSString.class] || [o isKindOfClass:NSNumber.class] || [o isKindOfClass:NSDictionary.class] || [o isKindOfClass:NSArray.class] || [o isKindOfClass:NSClassFromString(@"NSBlock")];
}

static NSString *TTProps(id o) {
    NSMutableString *r = [NSMutableString string];
    int count = 0;
    for (Class c = [o class]; c && c != NSObject.class && count < 40; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        objc_property_t *ps = class_copyPropertyList(c, &n);
        for (unsigned int i = 0; i < n && count < 40; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(ps[i])];
            id v = nil;
            @try { v = [o valueForKey:name]; } @catch (...) { v = @"(loi)"; }
            [r appendFormat:@"    .%@ = %@\n", name, TTShort(v)];
            count++;
        }
        free(ps);
    }
    return r;
}

static void TTLogCall(NSString *name, id me, NSArray *args) {
    @try {
        NSMutableString *s = [NSMutableString stringWithFormat:@"== %@\n  self %@\n", name, TTShort(me)];
        for (NSUInteger i = 0; i < args.count; i++) {
            id a = args[i] == NSNull.null ? nil : args[i];
            [s appendFormat:@"  arg%lu %@\n", (unsigned long)i, TTShort(a)];
            if (a && !TTIsPlain(a)) {
                Class tc = NSClassFromString(@"TIMOConversation");
                if (tc && [a isKindOfClass:tc]) {
                    [s appendFormat:@"    .identifier = %@\n", [a valueForKey:@"identifier"]];
                } else {
                    [s appendString:TTProps(a)];
                    if ([a respondsToSelector:@selector(content)]) {
                        id ct = [a valueForKey:@"content"];
                        if (ct) [s appendFormat:@"  [content] %@\n%@", TTShort(ct), TTProps(ct)];
                    }
                }
            }
        }
        TTTraceAdd(s);
    } @catch (...) {}
}

static NSString *TTOtherUID(NSString *cid) {
    NSArray *p = [cid componentsSeparatedByString:@":"];
    if (p.count != 4 || ![cid hasPrefix:@"0:1:"]) return nil;
    NSString *me = [D() stringForKey:kMe];
    if ([p[2] isEqualToString:me]) return p[3];
    if ([p[3] isEqualToString:me]) return p[2];
    return [NSString stringWithFormat:@"%@/%@", p[2], p[3]];
}

static void TTRemember(id conv) {
    Class tc = NSClassFromString(@"TIMOConversation");
    if (!conv || !tc || ![conv isKindOfClass:tc]) return;
    @try {
        NSString *cid = [conv valueForKey:@"identifier"];
        if (![cid isKindOfClass:NSString.class] || ![cid hasPrefix:@"0:1:"]) return;
        if ([cid componentsSeparatedByString:@":"].count != 4) return;
        if (!gConvs) gConvs = [NSMutableDictionary dictionary];
        if (gConvs[cid] == conv) return;
        gConvs[cid] = conv;
        id sdk = [conv valueForKey:@"r"];
        if (sdk) gSDK = sdk;
        id me = [conv valueForKey:@"scopedUserID"];
        if (me) [D() setObject:[me description] forKey:kMe];
        NSMutableDictionary *known = [([D() dictionaryForKey:kKnown] ?: @{}) mutableCopy];
        if (!known[cid]) {
            known[cid] = @{@"t": @([NSDate.date timeIntervalSince1970])};
            [D() setObject:known forKey:kKnown];
        }
    } @catch (...) {}
}

static void TTRememberAsync(id conv) {
    if (!conv) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        TTRemember(conv);
    });
}

static void TTNoteSend(id ctrl, id conv) {
    TTOnMain(^{
        gSendController = ctrl;
        gLastConv = conv;
        TTRemember(conv);
        @try {
            NSString *cid = [conv valueForKey:@"identifier"];
            if ([cid isKindOfClass:NSString.class]) TTMarkSentID(cid);
        } @catch (...) {}
    });
}

static id TTController(NSString **how) {
    id c = gSendController;
    if (c) {
        if (how) *how = @"controller đang dùng";
        return c;
    }
    if (!gOwnController) {
        Class cc = NSClassFromString(@"AWEIMSendMessageController");
        if (cc) gOwnController = [[cc alloc] init];
    }
    if (how) *how = @"controller mới tạo";
    return gOwnController;
}

static id TTConversationFor(NSString *cid) {
    id c = gConvs[cid];
    if (c) return c;
    Class tc = NSClassFromString(@"TIMOConversation");
    if (!tc || !gSDK) return nil;
    @try {
        id (*f)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        id r = f(tc, @selector(instanceWithSDKInstance:conversationIdentifier:), gSDK, cid);
        if (r) {
            if (!gConvs) gConvs = [NSMutableDictionary dictionary];
            gConvs[cid] = r;
        }
        return r;
    } @catch (...) {
        return nil;
    }
}

static id TTSendText(id conv, NSString *text, NSString **how) {
    id ctrl = TTController(how);
    Class mc = NSClassFromString(@"AWEIMSendTextMessageModel");
    Class cc = NSClassFromString(@"AWEIMTextMessageContent");
    if (!ctrl || !mc || !cc || !conv) return nil;
    @try {
        id (*init1)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id content = init1([cc alloc], @selector(initWithText:), text);
        id model = init1([mc alloc], @selector(initWithContent:), content);
        id (*send)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        id r = send(ctrl, @selector(sendMessage:conversation:), model, conv);
        if (r && [[r description] length] == 0) return nil;
        return r;
    } @catch (NSException *e) {
        TTTraceAdd([NSString stringWithFormat:@"Lỗi gửi: %@", e.reason]);
        return nil;
    }
}

static void TTRunDaily(void (^log)(NSString *)) {
    if (gRunning) {
        log(@"Đang chạy");
        return;
    }
    NSString *text = [D() stringForKey:kMessage] ?: @"";
    if (!text.length) {
        log(@"Chưa nhập nội dung tin nhắn");
        return;
    }
    NSMutableArray *queue = [NSMutableArray array];
    for (NSString *cid in TTTargets()) {
        if (!TTSentToday(cid)) [queue addObject:cid];
    }
    if (!queue.count) {
        log(@"Không còn ai cần gửi hôm nay (hoặc chưa chọn ai)");
        return;
    }
    gRunning = YES;
    __block NSUInteger i = 0;
    __block void (^next)(void);
    next = ^{
        if (i >= queue.count) {
            gRunning = NO;
            log(@"Xong");
            next = nil;
            return;
        }
        NSString *cid = queue[i++];
        NSString *who = TTOtherUID(cid) ?: cid;
        if (TTSentToday(cid)) {
            next();
            return;
        }
        id conv = TTConversationFor(cid);
        if (!conv) {
            log([NSString stringWithFormat:@"UID %@: chưa nạp được cuộc trò chuyện, sẽ thử lại sau", who]);
            next();
            return;
        }
        TTMarkSentID(cid);
        NSString *how = nil;
        id r = TTSendText(conv, text, &how);
        if (r) {
            log([NSString stringWithFormat:@"UID %@: đã gửi (%@)", who, how]);
        } else {
            TTUnmarkSentID(cid);
            log([NSString stringWithFormat:@"UID %@: gửi lỗi, không có messageID (%@)", who, how]);
        }
        double delay = 6 + arc4random_uniform(7);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            next();
        });
    };
    next();
}

static void TTAutoRun(int attempt) {
    if (![D() boolForKey:kEnabled]) return;
    TTRunDaily(^(NSString *s) {
        NSLog(@"[TTPanel] %@", s);
        TTTraceAdd([@"auto: " stringByAppendingString:s]);
    });
    if (attempt < 3) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TTAutoRun(attempt + 1);
        });
    }
}

static BOOL TTHookInstVoid1(Class c, SEL s, void (^cb)(id me, id a)) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    void (*o)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id a) {
        cb(me, a);
        o(me, s, a);
    }));
    return YES;
}

static BOOL TTHookInstMsgsCreated(Class c, SEL s, void (^cb)(id me)) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    void (*o)(id, SEL, id, id, id, BOOL) = (void (*)(id, SEL, id, id, id, BOOL))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id a, id b, id d, BOOL e) {
        cb(me);
        o(me, s, a, b, d, e);
    }));
    return YES;
}

static BOOL TTHookClassRet2(Class c, SEL s, void (^onResult)(id a, id b, id r)) {
    Method m = c ? class_getClassMethod(c, s) : NULL;
    if (!m) return NO;
    id (*o)(id, SEL, id, id) = (id (*)(id, SEL, id, id))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^id(id me, id a, id b) {
        id r = o(me, s, a, b);
        onResult(a, b, r);
        return r;
    }));
    return YES;
}

static BOOL TTHookSendMessage(void) {
    Class sc = NSClassFromString(@"AWEIMSendMessageController");
    Method m = sc ? class_getInstanceMethod(sc, @selector(sendMessage:conversation:)) : NULL;
    if (!m) return NO;
    id (*o)(id, SEL, id, id) = (id (*)(id, SEL, id, id))method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^id(id me, id a, id b) {
        if (gTraceOn) TTLogCall(@"-[AWEIMSendMessageController sendMessage:conversation:]", me, @[a ?: NSNull.null, b ?: NSNull.null]);
        TTNoteSend(me, b);
        id r = o(me, @selector(sendMessage:conversation:), a, b);
        if (gTraceOn) TTTraceAdd([NSString stringWithFormat:@"  return %@", TTShort(r)]);
        return r;
    }));
    return YES;
}

static void TTInstallPassive(void) {
    if (gPassive) return;
    Class tc = NSClassFromString(@"TIMOConversation");
    Class mc = NSClassFromString(@"TIMOModel");
    Class sc = NSClassFromString(@"AWEIMSendMessageController");
    if (!tc || !mc || !sc) return;
    gPassive = YES;

    void (^remember)(id, id) = ^(id me, id a) {
        TTRememberAsync(me);
    };
    TTHookInstVoid1(tc, @selector(onConversationsUpdated:), remember);
    TTHookInstVoid1(tc, @selector(onConversationsCreated:), remember);
    TTHookInstMsgsCreated(tc, @selector(onMessagesCreated:belongingConversationMap:reason:isPullMessage:), ^(id me) {
        TTRememberAsync(me);
    });

    void (^onModel)(id, id, id) = ^(id sdkArg, id arg, id ret) {
        Class sk = NSClassFromString(@"TIMSDKInstance");
        id captured = (sk && [sdkArg isKindOfClass:sk]) ? sdkArg : nil;
        NSArray *items = @[];
        if ([ret isKindOfClass:NSArray.class]) items = ret;
        else if ([ret isKindOfClass:NSDictionary.class]) items = [ret allValues];
        else if (ret) items = @[ret];
        if (!captured && !items.count) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (captured) gSDK = captured;
            for (id x in items) TTRemember(x);
        });
    };
    TTHookClassRet2(mc, @selector(cachedInstanceWithSDKInstance:identifier:), onModel);
    TTHookClassRet2(mc, @selector(cachedInstanceWithSDKInstance:identifiers:), onModel);

    TTHookSendMessage();
}

static BOOL TTHookVoid1(Class c, SEL s) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    void (*o)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(c), NSStringFromSelector(s)];
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id a) {
        if (gTraceOn) TTLogCall(name, me, @[a ?: NSNull.null]);
        o(me, s, a);
    }));
    return YES;
}

static BOOL TTHookVoid2(Class c, SEL s) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    void (*o)(id, SEL, id, id) = (void (*)(id, SEL, id, id))method_getImplementation(m);
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(c), NSStringFromSelector(s)];
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id a, id b) {
        if (gTraceOn) TTLogCall(name, me, @[a ?: NSNull.null, b ?: NSNull.null]);
        o(me, s, a, b);
    }));
    return YES;
}

static BOOL TTHookVoid3(Class c, SEL s) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    void (*o)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(c), NSStringFromSelector(s)];
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id a, id b, id d) {
        if (gTraceOn) TTLogCall(name, me, @[a ?: NSNull.null, b ?: NSNull.null, d ?: NSNull.null]);
        o(me, s, a, b, d);
    }));
    return YES;
}

static void TTInstallTrace(void) {
    gTraceOn = YES;
    static BOOL done = NO;
    if (done) {
        TTTraceAdd(@"Trace đã bật rồi");
        return;
    }
    done = YES;
    Class sc = NSClassFromString(@"AWEIMSendMessageController");
    Class qc = NSClassFromString(@"AWEIMQuickDMMessageSenderService");
    Class rc = NSClassFromString(@"AWEIMChatRoomMessageSender");
    NSArray *res = @[
        @(TTHookVoid3(sc, @selector(p_sendMessage:toConversation:sentMessageDict:))),
        @(TTHookVoid2(sc, @selector(sendBatchMessages:completion:))),
        @(TTHookVoid1(qc, @selector(sendMessageWithParams:))),
        @(TTHookVoid1(rc, @selector(trySendMessage:))),
        @(TTHookVoid3(rc, @selector(trySendMessage:onCanContinueToSend:onDidGenerateMessageId:)))
    ];
    TTTraceAdd([NSString stringWithFormat:@"Đã bật trace, kết quả từng hook (1 là được, 0 là không thấy): %@", [res componentsJoinedByString:@" "]]);
}

static NSArray<NSString *> *TTAppClassNames(void) {
    NSMutableArray *all = [NSMutableArray array];
    unsigned int ic = 0;
    const char **images = objc_copyImageNames(&ic);
    NSString *root = NSBundle.mainBundle.bundlePath;
    for (unsigned int i = 0; i < ic; i++) {
        NSString *p = [NSString stringWithUTF8String:images[i]];
        if (![p hasPrefix:root]) continue;
        unsigned int n = 0;
        const char **names = objc_copyClassNamesForImage(images[i], &n);
        for (unsigned int j = 0; j < n; j++) {
            [all addObject:[NSString stringWithUTF8String:names[j]]];
        }
        free(names);
    }
    free(images);
    return all;
}

static NSString *TTScanClasses(NSString *filter) {
    NSArray *keys = filter.length ? @[filter.lowercaseString] : @[@"conversation", @"message", @"chat", @"inbox", @"directmessage"];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *s in TTAppClassNames()) {
        NSString *l = s.lowercaseString;
        for (NSString *k in keys) {
            if ([l containsString:k]) {
                [hits addObject:s];
                break;
            }
        }
    }
    [hits sortUsingSelector:@selector(compare:)];
    NSUInteger total = hits.count;
    if (hits.count > 400) hits = [[hits subarrayWithRange:NSMakeRange(0, 400)] mutableCopy];
    return [NSString stringWithFormat:@"%lu class (hiện tối đa 400)\n%@", (unsigned long)total, [hits componentsJoinedByString:@"\n"]];
}

static NSString *TTDumpMethods(NSString *cls) {
    Class c = NSClassFromString(cls);
    if (!c) return @"Không tìm thấy class";
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n; i++) {
        [out addObject:[@"- " stringByAppendingString:NSStringFromSelector(method_getName(ms[i]))]];
    }
    free(ms);
    n = 0;
    Method *cm = class_copyMethodList(object_getClass(c), &n);
    for (unsigned int i = 0; i < n; i++) {
        [out addObject:[@"+ " stringByAppendingString:NSStringFromSelector(method_getName(cm[i]))]];
    }
    free(cm);
    if (out.count > 500) out = [[out subarrayWithRange:NSMakeRange(0, 500)] mutableCopy];
    return [out componentsJoinedByString:@"\n"];
}

static NSString *TTDumpFiltered(NSString *cls, NSString *kwString, NSUInteger cap) {
    Class c = NSClassFromString(cls);
    if (!c) return [NSString stringWithFormat:@"## %@: không tìm thấy\n", cls];
    NSArray *kws = kwString.length ? [kwString.lowercaseString componentsSeparatedByString:@"|"] : @[];
    NSMutableArray *lines = [NSMutableArray array];
    for (int pass = 0; pass < 2; pass++) {
        Class target = pass == 0 ? c : object_getClass(c);
        unsigned int n = 0;
        Method *ms = class_copyMethodList(target, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *name = NSStringFromSelector(method_getName(ms[i]));
            BOOL match = kws.count == 0;
            for (NSString *k in kws) {
                if ([name.lowercaseString containsString:k]) {
                    match = YES;
                    break;
                }
            }
            if (match) {
                const char *enc = method_getTypeEncoding(ms[i]);
                [lines addObject:[NSString stringWithFormat:@"%@ %@  %s", pass == 0 ? @"-" : @"+", name, enc ? enc : ""]];
            }
        }
        free(ms);
    }
    NSUInteger total = lines.count;
    if (lines.count > cap) lines = [[lines subarrayWithRange:NSMakeRange(0, cap)] mutableCopy];
    return [NSString stringWithFormat:@"## %@ (%lu)\n%@\n", cls, (unsigned long)total, [lines componentsJoinedByString:@"\n"]];
}

static NSString *TTQuickDump(void) {
    NSMutableString *r = [NSMutableString string];
    NSArray *items = @[
        @[@"AWEIMUserManager", @"", @120],
        @[@"AWEIMUser", @"", @100],
        @[@"AWEIMContactManager", @"", @100],
        @[@"AWEIMContactListManager", @"", @80],
        @[@"AWEIMMAFUserManager", @"", @60],
        @[@"AWEIMSendMessageController", @"", @150],
        @[@"AWEIMChatRoomMessageSender", @"", @60]
    ];
    for (NSArray *it in items) {
        [r appendString:TTDumpFiltered(it[0], it[1], [it[2] unsignedIntegerValue])];
    }
    return r;
}

static NSArray<NSDictionary *> *TTRows(void) {
    NSDictionary *known = [D() dictionaryForKey:kKnown] ?: @{};
    NSArray *ids = [known.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSNumber *ta = known[a][@"t"] ?: @0;
        NSNumber *tb = known[b][@"t"] ?: @0;
        return [tb compare:ta];
    }];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *cid in ids) {
        NSString *other = TTOtherUID(cid) ?: cid;
        NSString *sub = [NSString stringWithFormat:@"%@ | %@", TTSentToday(cid) ? @"đã nhắn hôm nay" : @"chưa nhắn hôm nay", gConvs[cid] ? @"sẵn sàng" : @"chưa nạp"];
        [rows addObject:@{@"id": cid, @"title": [@"UID " stringByAppendingString:other], @"sub": sub}];
    }
    return rows;
}

static UIWindow *TTKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return nil;
}

static UIButton *TTButton(NSString *title, CGRect f, id target, SEL sel) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:13];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:target action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UITextField *TTField(NSString *placeholder, CGRect f, NSString *text) {
    UITextField *t = [[UITextField alloc] initWithFrame:f];
    t.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    t.textColor = UIColor.whiteColor;
    t.font = [UIFont systemFontOfSize:14];
    t.layer.cornerRadius = 8;
    t.autocapitalizationType = UITextAutocapitalizationTypeNone;
    t.autocorrectionType = UITextAutocorrectionTypeNo;
    t.returnKeyType = UIReturnKeyDone;
    t.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, f.size.height)];
    t.leftViewMode = UITextFieldViewModeAlways;
    t.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: UIColor.grayColor}];
    t.text = text;
    return t;
}

@interface TTPanelView : UIView <UITableViewDataSource>
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UITextField *msg;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *rows;
@property (nonatomic, strong) UITextField *cls;
@property (nonatomic, strong) UITextView *out;
- (void)reloadRows;
@end

@implementation TTPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    CGFloat w = frame.size.width;
    CGFloat h = frame.size.height;
    CGFloat third = (w - 48) / 3;
    CGFloat x1 = 16, x2 = 24 + third, x3 = 32 + third * 2;

    self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.97];
    self.layer.cornerRadius = 16;
    self.clipsToBounds = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, w - 60, 24)];
    title.text = @"TT Panel";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    [self addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 44, 8, 32, 32);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:close];

    UILabel *state = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, w - 90, 31)];
    state.text = @"Tự động gửi khi mở app";
    state.textColor = UIColor.whiteColor;
    state.font = [UIFont systemFontOfSize:15];
    [self addSubview:state];

    self.toggle = [[UISwitch alloc] init];
    self.toggle.center = CGPointMake(w - 16 - self.toggle.bounds.size.width / 2, 63);
    self.toggle.on = [D() boolForKey:kEnabled];
    [self.toggle addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:self.toggle];

    self.msg = TTField(@"Nội dung tin nhắn", CGRectMake(16, 88, w - 32, 36), [D() stringForKey:kMessage]);
    [self.msg addTarget:self action:@selector(msgChanged) forControlEvents:UIControlEventEditingChanged];
    [self.msg addTarget:self action:@selector(endEdit) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self addSubview:self.msg];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 128, w - 32, 18)];
    hint.text = @"Chọn người nhận (bấm Làm mới để cập nhật)";
    hint.textColor = UIColor.grayColor;
    hint.font = [UIFont systemFontOfSize:12];
    [self addSubview:hint];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(16, 148, w - 32, 150) style:UITableViewStylePlain];
    self.table.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    self.table.layer.cornerRadius = 8;
    self.table.rowHeight = 52;
    self.table.dataSource = self;
    [self addSubview:self.table];

    [self addSubview:TTButton(@"Chạy ngay", CGRectMake(x1, 306, third, 36), self, @selector(runNow))];
    [self addSubview:TTButton(@"Làm mới", CGRectMake(x2, 306, third, 36), self, @selector(refresh))];
    [self addSubview:TTButton(@"Gửi thử", CGRectMake(x3, 306, third, 36), self, @selector(testSend))];

    self.cls = TTField(@"Tên class (Methods) hoặc từ khóa (Quét class)", CGRectMake(16, 350, w - 32, 36), nil);
    [self.cls addTarget:self action:@selector(endEdit) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self addSubview:self.cls];

    [self addSubview:TTButton(@"Quét class", CGRectMake(x1, 394, third, 36), self, @selector(scan))];
    [self addSubview:TTButton(@"Methods", CGRectMake(x2, 394, third, 36), self, @selector(methods))];
    [self addSubview:TTButton(@"Dump nhanh", CGRectMake(x3, 394, third, 36), self, @selector(quickDump))];

    [self addSubview:TTButton(@"Bật trace", CGRectMake(x1, 438, third, 36), self, @selector(startTrace))];
    [self addSubview:TTButton(@"Xem trace", CGRectMake(x2, 438, third, 36), self, @selector(showTrace))];
    [self addSubview:TTButton(@"Sao chép", CGRectMake(x3, 438, third, 36), self, @selector(copyOut))];

    self.out = [[UITextView alloc] initWithFrame:CGRectMake(16, 482, w - 32, h - 482 - 12)];
    self.out.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1];
    self.out.textColor = [UIColor colorWithRed:0.5 green:1 blue:0.6 alpha:1];
    self.out.font = [UIFont fontWithName:@"Menlo" size:11];
    self.out.editable = NO;
    self.out.layer.cornerRadius = 8;
    [self addSubview:self.out];

    [self reloadRows];
    return self;
}

- (void)reloadRows {
    self.rows = TTRows();
    [self.table reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
        c.backgroundColor = UIColor.clearColor;
        c.textLabel.textColor = UIColor.whiteColor;
        c.textLabel.font = [UIFont systemFontOfSize:14];
        c.detailTextLabel.textColor = UIColor.grayColor;
        c.detailTextLabel.font = [UIFont systemFontOfSize:11];
        UISwitch *sw = [[UISwitch alloc] init];
        [sw addTarget:self action:@selector(rowToggled:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    }
    NSDictionary *row = self.rows[indexPath.row];
    c.textLabel.text = row[@"title"];
    c.detailTextLabel.text = row[@"sub"];
    UISwitch *sw = (UISwitch *)c.accessoryView;
    sw.tag = indexPath.row;
    sw.on = [TTTargets() containsObject:row[@"id"]];
    return c;
}

- (void)rowToggled:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (NSInteger)self.rows.count) return;
    NSString *cid = self.rows[sw.tag][@"id"];
    NSMutableArray *t = [TTTargets() mutableCopy];
    if (sw.isOn) {
        if (![t containsObject:cid]) [t addObject:cid];
    } else {
        [t removeObject:cid];
    }
    [D() setObject:t forKey:kTargets];
}

- (void)msgChanged {
    [D() setObject:self.msg.text ?: @"" forKey:kMessage];
}

- (void)toggleChanged {
    [D() setBool:self.toggle.isOn forKey:kEnabled];
}

- (void)endEdit {
    [self endEditing:YES];
}

- (void)appendOut:(NSString *)s {
    self.out.text = [self.out.text stringByAppendingFormat:@"%@\n", s];
}

- (void)runNow {
    [self endEditing:YES];
    self.out.text = @"";
    __weak TTPanelView *ws = self;
    TTRunDaily(^(NSString *s) {
        [ws appendOut:s];
        [ws reloadRows];
    });
}

- (void)refresh {
    [self endEditing:YES];
    [self reloadRows];
    self.out.text = [NSString stringWithFormat:@"%lu cuộc trò chuyện đã biết | SDK: %@ | controller: %@ | đã chọn: %lu", (unsigned long)self.rows.count, gSDK ? @"có" : @"chưa", gSendController ? @"có" : @"chưa (sẽ tạo mới)", (unsigned long)TTTargets().count];
}

- (void)testSend {
    [self endEditing:YES];
    NSString *t = [D() stringForKey:kMessage] ?: @"";
    if (!t.length) {
        self.out.text = @"Chưa nhập nội dung tin nhắn";
        return;
    }
    if (!gLastConv) {
        self.out.text = @"Chưa có cuộc trò chuyện nào được ghi nhận. Tự gửi tay một tin trong chat thử trước.";
        return;
    }
    NSString *how = nil;
    id r = TTSendText(gLastConv, t, &how);
    self.out.text = [NSString stringWithFormat:@"%@ | %@", how ?: @"?", r ? [NSString stringWithFormat:@"đã gọi, messageID %@", TTShort(r)] : @"lỗi, không có messageID"];
    [self reloadRows];
}

- (void)scan {
    [self endEditing:YES];
    self.out.text = TTScanClasses([self.cls.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
}

- (void)methods {
    [self endEditing:YES];
    NSString *name = [self.cls.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    self.out.text = TTDumpMethods(name);
}

- (void)quickDump {
    [self endEditing:YES];
    self.out.text = @"Đang dump...";
    dispatch_async(dispatch_get_main_queue(), ^{
        self.out.text = TTQuickDump();
    });
}

- (void)startTrace {
    [self endEditing:YES];
    TTInstallTrace();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.out.text = gTraceLog ?: @"";
    });
}

- (void)showTrace {
    [self endEditing:YES];
    self.out.text = gTraceLog.length ? gTraceLog : @"Chưa có gì.";
}

- (void)copyOut {
    UIPasteboard.generalPasteboard.string = self.out.text;
}

- (void)hide {
    [self endEditing:YES];
    self.hidden = YES;
}

@end

@interface TTPanelController : NSObject
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) TTPanelView *panel;
+ (instancetype)shared;
- (void)install;
@end

@implementation TTPanelController

+ (instancetype)shared {
    static TTPanelController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [TTPanelController new]; });
    return c;
}

- (void)install {
    UIWindow *window = TTKeyWindow();
    if (!window || self.button) return;

    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button.frame = CGRectMake(12, 120, 44, 44);
    self.button.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
    self.button.layer.cornerRadius = 22;
    [self.button setTitle:@"⚙" forState:UIControlStateNormal];
    [self.button addTarget:self action:@selector(toggleUI) forControlEvents:UIControlEventTouchUpInside];
    [self.button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [window addSubview:self.button];

    CGFloat w = MIN(340, window.bounds.size.width - 24);
    CGFloat h = MIN(660, window.bounds.size.height - 60);
    self.panel = [[TTPanelView alloc] initWithFrame:CGRectMake((window.bounds.size.width - w) / 2, 40, w, h)];
    self.panel.hidden = YES;
    [window addSubview:self.panel];
}

- (void)toggleUI {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) [self.panel reloadRows];
    [self.panel.superview bringSubviewToFront:self.panel];
    [self.button.superview bringSubviewToFront:self.button];
}

- (void)drag:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

@end

%ctor {
    TTInstallPassive();
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        TTInstallPassive();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[TTPanelController shared] install];
        });
        static dispatch_once_t autoOnce;
        dispatch_once(&autoOnce, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                TTAutoRun(0);
            });
        });
    }];
}
