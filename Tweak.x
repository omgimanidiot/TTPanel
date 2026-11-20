#import <UIKit/UIKit.h>

static NSString *const kEnabled = @"ttpanel_enabled";
static NSString *const kUsername = @"ttpanel_username";

BOOL TTPanelEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kEnabled];
}

NSString *TTPanelUsername(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:kUsername] ?: @"";
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

@interface TTPanelView : UIView
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UISwitch *toggle;
@end

@implementation TTPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.96];
    self.layer.cornerRadius = 16;
    self.clipsToBounds = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, frame.size.width - 60, 24)];
    title.text = @"TT Panel";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    [self addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(frame.size.width - 44, 8, 32, 32);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:close];

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(16, 52, frame.size.width - 32, 40)];
    self.field.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    self.field.textColor = UIColor.whiteColor;
    self.field.layer.cornerRadius = 8;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.returnKeyType = UIReturnKeyDone;
    self.field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 40)];
    self.field.leftViewMode = UITextFieldViewModeAlways;
    self.field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Username" attributes:@{NSForegroundColorAttributeName: UIColor.grayColor}];
    self.field.text = TTPanelUsername();
    [self.field addTarget:self action:@selector(usernameChanged) forControlEvents:UIControlEventEditingChanged];
    [self.field addTarget:self action:@selector(dismissKeyboard) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self addSubview:self.field];

    UILabel *state = [[UILabel alloc] initWithFrame:CGRectMake(16, 108, 150, 31)];
    state.text = @"Enable";
    state.textColor = UIColor.whiteColor;
    [self addSubview:state];

    self.toggle = [[UISwitch alloc] init];
    self.toggle.center = CGPointMake(frame.size.width - 16 - self.toggle.bounds.size.width / 2, 123);
    self.toggle.on = TTPanelEnabled();
    [self.toggle addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:self.toggle];

    return self;
}

- (void)usernameChanged {
    [NSUserDefaults.standardUserDefaults setObject:self.field.text ?: @"" forKey:kUsername];
}

- (void)toggleChanged {
    [NSUserDefaults.standardUserDefaults setBool:self.toggle.isOn forKey:kEnabled];
}

- (void)dismissKeyboard {
    [self.field resignFirstResponder];
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

    CGFloat w = MIN(300, window.bounds.size.width - 40);
    self.panel = [[TTPanelView alloc] initWithFrame:CGRectMake((window.bounds.size.width - w) / 2, 200, w, 160)];
    self.panel.hidden = YES;
    [window addSubview:self.panel];
}

- (void)toggleUI {
    self.panel.hidden = !self.panel.hidden;
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
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[TTPanelController shared] install];
        });
    }];
}
