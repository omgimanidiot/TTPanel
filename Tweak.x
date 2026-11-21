#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kEnabled = @"ttpanel_enabled";
static NSString *const kMessage = @"ttpanel_message";
static NSString *const kTargets = @"ttpanel_targets";
static NSString *const kKnown = @"ttpanel_known";
static NSString *const kSent = @"ttpanel_sent";
static NSString *const kMe = @"ttpanel_me";
static NSString *const kNames = @"ttpanel_names";
static NSString *const kManual = @"ttpanel_manual_names";

static BOOL gRunning = NO;
static BOOL gPassive = NO;
static NSTimeInterval gProgress = 0;
static NSInteger gAutoGen = 0;
static NSMutableString *gLog;
static __weak id gSendController;
static id gOwnController;
static id gSDK;
static NSMutableDictionary *gConvs;
static NSMutableSet *gTried;

static NSUserDefaults *D(void) {
    return NSUserDefaults.standardUserDefaults;
}

static void TTOnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static void TTLog(NSString *line) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLog) gLog = [NSMutableString string];
        if (gLog.length > 20000) [gLog deleteCharactersInRange:NSMakeRange(0, 8000)];
        [gLog appendFormat:@"%@\n", line];
    });
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
    [D() synchronize];
}

static void TTUnmarkSentID(NSString *cid) {
    NSMutableDictionary *d = [([D() dictionaryForKey:kSent] ?: @{}) mutableCopy];
    [d removeObjectForKey:cid];
    [D() setObject:d forKey:kSent];
    [D() synchronize];
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
        TTLog([NSString stringWithFormat:@"Lỗi gửi: %@", e.reason]);
        return nil;
    }
}

static NSString *TTNameFor(NSString *uid) {
    NSString *m = [D() dictionaryForKey:kManual][uid];
    if (m.length) return m;
    NSString *a = [D() dictionaryForKey:kNames][uid];
    return a.length ? a : nil;
}

static void TTDiag(NSMutableString *d, NSString *s) {
    if (d) [d appendFormat:@"%@\n", s];
}

static NSString *TTNameFromUserObject(id u) {
    if (!u) return nil;
    for (NSString *k in @[@"nickname", @"nickName", @"displayName", @"name", @"userName", @"uniqueID", @"uniqueId"]) {
        @try {
            id v = [u valueForKey:k];
            if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) return v;
        } @catch (...) {}
    }
    return nil;
}

static id TTSingletonFor(Class c) {
    for (NSString *n in @[@"sharedInstance", @"sharedManager", @"shared", @"defaultManager", @"sharedUserManager", @"manager", @"instance"]) {
        SEL s = NSSelectorFromString(n);
        if ([c respondsToSelector:s]) {
            id (*f)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            @try {
                id o = f(c, s);
                if (o) return o;
            } @catch (...) {}
        }
    }
    return nil;
}

static NSString *TTResolveViaClass(Class c, NSString *uid, NSMutableString *diag) {
    id inst = TTSingletonFor(c);
    if (!inst) {
        TTDiag(diag, [NSString stringWithFormat:@"%@: không lấy được singleton", NSStringFromClass(c)]);
        return nil;
    }
    NSArray *bad = @[@"set", @"remove", @"delete", @"update", @"fetch", @"request", @"load", @"add", @"save", @"block", @"follow", @"report", @"clear", @"reset", @"insert", @"sync", @"observe", @"register", @"notify", @"cancel", @"unfollow"];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSString *found = nil;
    int tried = 0;
    for (unsigned int i = 0; i < n && !found; i++) {
        SEL sel = method_getName(ms[i]);
        NSString *name = NSStringFromSelector(sel);
        NSString *l = name.lowercaseString;
        if ([name componentsSeparatedByString:@":"].count != 2) continue;
        if (!([l containsString:@"user"] || [l containsString:@"contact"] || [l containsString:@"friend"])) continue;
        if (!([l containsString:@"id"] || [l containsString:@"uid"])) continue;
        BOOL skip = NO;
        for (NSString *b in bad) {
            if ([l containsString:b]) {
                skip = YES;
                break;
            }
        }
        if (skip) continue;
        char ret[16];
        method_getReturnType(ms[i], ret, sizeof ret);
        if (ret[0] != '@') continue;
        char arg[16];
        method_getArgumentType(ms[i], 2, arg, sizeof arg);
        id u = nil;
        BOOL called = NO;
        @try {
            if (arg[0] == 'q' || arg[0] == 'Q' || arg[0] == 'l' || arg[0] == 'L') {
                id (*f)(id, SEL, long long) = (id (*)(id, SEL, long long))objc_msgSend;
                u = f(inst, sel, uid.longLongValue);
                called = YES;
            } else if (arg[0] == '@') {
                id (*f)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
                u = f(inst, sel, uid);
                called = YES;
            }
        } @catch (...) {}
        if (!called) continue;
        tried++;
        NSString *nm = TTNameFromUserObject(u);
        if (nm) {
            found = nm;
            TTDiag(diag, [NSString stringWithFormat:@"%@ %@ -> %@", NSStringFromClass(c), name, nm]);
        } else if (tried <= 12) {
            TTDiag(diag, [NSString stringWithFormat:@"%@ %@ -> không có tên (%@)", NSStringFromClass(c), name, u ? NSStringFromClass([u class]) : @"nil"]);
        }
    }
    free(ms);
    return found;
}

static void TTResolveNames(NSMutableString *diag) {
    if (!gTried) gTried = [NSMutableSet set];
    NSDictionary *known = [D() dictionaryForKey:kKnown] ?: @{};
    NSMutableDictionary *names = [([D() dictionaryForKey:kNames] ?: @{}) mutableCopy];
    BOOL changed = NO;
    NSArray *classes = @[@"AWEIMUserManager", @"AWEIMContactManager", @"AWEIMMAFUserManager", @"AWEIMContactListManager"];
    for (NSString *cid in known) {
        NSString *uid = TTOtherUID(cid);
        if (!uid || [uid containsString:@"/"] || names[uid]) continue;
        if ([gTried containsObject:uid]) continue;
        [gTried addObject:uid];
        for (NSString *cn in classes) {
            Class c = NSClassFromString(cn);
            if (!c) continue;
            NSString *nm = TTResolveViaClass(c, uid, diag);
            if (nm) {
                names[uid] = nm;
                changed = YES;
                break;
            }
        }
    }
    if (changed) [D() setObject:names forKey:kNames];
}

static void TTRunDaily(void (^log)(NSString *)) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (gRunning) {
        if (now - gProgress < 60) {
            log(@"Đang chạy");
            return;
        }
        gRunning = NO;
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
    gProgress = now;
    __block NSUInteger i = 0;
    __block void (^next)(void);
    next = ^{
        gProgress = NSDate.timeIntervalSinceReferenceDate;
        if (i >= queue.count) {
            gRunning = NO;
            log(@"Xong");
            next = nil;
            return;
        }
        NSString *cid = queue[i++];
        NSString *uid = TTOtherUID(cid) ?: cid;
        NSString *who = TTNameFor(uid) ?: [@"UID " stringByAppendingString:uid];
        if (TTSentToday(cid)) {
            next();
            return;
        }
        id conv = TTConversationFor(cid);
        if (!conv) {
            log([NSString stringWithFormat:@"%@: chưa nạp được cuộc trò chuyện, sẽ thử lại sau", who]);
            next();
            return;
        }
        TTMarkSentID(cid);
        NSString *how = nil;
        id r = TTSendText(conv, text, &how);
        if (r) {
            log([NSString stringWithFormat:@"%@: đã gửi", who]);
        } else {
            TTUnmarkSentID(cid);
            log([NSString stringWithFormat:@"%@: gửi lỗi (%@), sẽ thử lại sau", who, how ?: @"?"]);
        }
        double delay = 1.5 + arc4random_uniform(20) / 10.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            next();
        });
    };
    next();
}

static void TTAutoRun(NSInteger gen, int attempt) {
    if (gen != gAutoGen) return;
    if (![D() boolForKey:kEnabled]) return;
    BOOL pending = NO;
    for (NSString *cid in TTTargets()) {
        if (!TTSentToday(cid)) {
            pending = YES;
            break;
        }
    }
    if (!pending) return;
    TTRunDaily(^(NSString *s) {
        NSLog(@"[TTPanel] %@", s);
        TTLog([@"auto: " stringByAppendingString:s]);
    });
    if (attempt < 12) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TTAutoRun(gen, attempt + 1);
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
        TTNoteSend(me, b);
        return o(me, @selector(sendMessage:conversation:), a, b);
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

static NSString *TTDumpFiltered(NSString *cls, NSUInteger cap) {
    Class c = NSClassFromString(cls);
    if (!c) return [NSString stringWithFormat:@"## %@: không tìm thấy\n", cls];
    NSMutableArray *lines = [NSMutableArray array];
    for (int pass = 0; pass < 2; pass++) {
        Class target = pass == 0 ? c : object_getClass(c);
        unsigned int n = 0;
        Method *ms = class_copyMethodList(target, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *enc = method_getTypeEncoding(ms[i]);
            [lines addObject:[NSString stringWithFormat:@"%@ %@  %s", pass == 0 ? @"-" : @"+", NSStringFromSelector(method_getName(ms[i])), enc ? enc : ""]];
        }
        free(ms);
    }
    NSUInteger total = lines.count;
    if (lines.count > cap) lines = [[lines subarrayWithRange:NSMakeRange(0, cap)] mutableCopy];
    return [NSString stringWithFormat:@"## %@ (%lu)\n%@\n", cls, (unsigned long)total, [lines componentsJoinedByString:@"\n"]];
}

static NSString *TTUserClassDump(void) {
    NSMutableString *r = [NSMutableString string];
    NSArray *items = @[
        @[@"AWEIMUserManager", @120],
        @[@"AWEIMUser", @100],
        @[@"AWEIMContactManager", @100],
        @[@"AWEIMContactListManager", @80],
        @[@"AWEIMMAFUserManager", @60]
    ];
    for (NSArray *it in items) {
        [r appendString:TTDumpFiltered(it[0], [it[1] unsignedIntegerValue])];
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
        NSString *uid = TTOtherUID(cid);
        NSString *name = uid ? TTNameFor(uid) : nil;
        NSString *title = name ?: [@"UID " stringByAppendingString:uid ?: cid];
        NSString *sub = [NSString stringWithFormat:@"%@%@", TTSentToday(cid) ? @"đã nhắn hôm nay" : @"chưa nhắn hôm nay", name ? @"" : @" | chạm để đặt tên"];
        [rows addObject:@{@"id": cid, @"title": title, @"sub": sub}];
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

static UIViewController *TTTopVC(void) {
    UIViewController *vc = TTKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
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

@interface TTPanelView : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UITextField *msg;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *rows;
@property (nonatomic, strong) UITextView *out;
- (void)reloadRows;
@end

@implementation TTPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    CGFloat w = frame.size.width;
    CGFloat h = frame.size.height;
    CGFloat half = (w - 40) / 2;

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
    hint.text = @"Bật công tắc để chọn người nhận, chạm vào dòng để đặt tên";
    hint.textColor = UIColor.grayColor;
    hint.font = [UIFont systemFontOfSize:12];
    [self addSubview:hint];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(16, 148, w - 32, 220) style:UITableViewStylePlain];
    self.table.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    self.table.layer.cornerRadius = 8;
    self.table.rowHeight = 52;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self addSubview:self.table];

    [self addSubview:TTButton(@"Chạy ngay", CGRectMake(16, 376, half, 36), self, @selector(runNow))];
    [self addSubview:TTButton(@"Làm mới", CGRectMake(24 + half, 376, half, 36), self, @selector(refresh))];
    [self addSubview:TTButton(@"Chẩn đoán", CGRectMake(16, 420, half, 36), self, @selector(diagnose))];
    [self addSubview:TTButton(@"Sao chép", CGRectMake(24 + half, 420, half, 36), self, @selector(copyOut))];

    self.out = [[UITextView alloc] initWithFrame:CGRectMake(16, 464, w - 32, h - 464 - 12)];
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
    TTResolveNames(nil);
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

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *cid = self.rows[indexPath.row][@"id"];
    NSString *uid = TTOtherUID(cid);
    if (!uid) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đặt tên" message:[@"UID " stringByAppendingString:uid] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = TTNameFor(uid);
        tf.placeholder = @"Tên hiển thị";
    }];
    __weak TTPanelView *ws = self;
    __weak UIAlertController *wa = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        ws.hidden = NO;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *v = [wa.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableDictionary *m = [([D() dictionaryForKey:kManual] ?: @{}) mutableCopy];
        if (v.length) m[uid] = v;
        else [m removeObjectForKey:uid];
        [D() setObject:m forKey:kManual];
        [D() synchronize];
        ws.hidden = NO;
        [ws reloadRows];
    }]];
    self.hidden = YES;
    [TTTopVC() presentViewController:alert animated:YES completion:nil];
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
    [D() synchronize];
}

- (void)msgChanged {
    [D() setObject:self.msg.text ?: @"" forKey:kMessage];
}

- (void)toggleChanged {
    [D() setBool:self.toggle.isOn forKey:kEnabled];
    [D() synchronize];
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
    self.out.text = [NSString stringWithFormat:@"%lu cuộc trò chuyện đã biết, đã chọn %lu người", (unsigned long)self.rows.count, (unsigned long)TTTargets().count];
}

- (void)diagnose {
    [self endEditing:YES];
    [gTried removeAllObjects];
    NSMutableString *d = [NSMutableString string];
    [d appendFormat:@"Đã biết %lu chat | SDK %@ | controller %@ | đã chọn %lu\n\n", (unsigned long)self.rows.count, gSDK ? @"có" : @"chưa", gSendController ? @"có" : @"chưa (sẽ tạo mới)", (unsigned long)TTTargets().count];
    TTResolveNames(d);
    [self reloadRows];
    [d appendFormat:@"\n== log\n%@\n", gLog ?: @""];
    [d appendString:TTUserClassDump()];
    self.out.text = d;
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
    CGFloat h = MIN(640, window.bounds.size.height - 60);
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
        NSInteger gen = ++gAutoGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TTAutoRun(gen, 0);
        });
    }];
}
