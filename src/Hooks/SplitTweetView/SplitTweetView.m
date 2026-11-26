#import "SplitTweetView.h"

BOOL BHTSplitTweetViewEnabled(void) {
    return [BHTSettings boolForKey:@"ipad_split_view"];
}

BHTSplitTweetState* BHTTweetState(id object) {
    return object ? objc_getAssociatedObject(object, &BHTSplitTweetStateKey) : nil;
}

BHTSplitTweetState* BHTTweetStateForController(UIViewController* controller) {
    while (controller) {
        BHTSplitTweetState* state = BHTTweetState(controller);
        if (state) {
            return state;
        }
        controller = controller.parentViewController;
    }
    return nil;
}

BOOL BHTIsConversationController(UIViewController* controller) {
    Class conversationClass = NSClassFromString(@"T1ConversationContainerViewController");
    Class linkClass = NSClassFromString(@"T1XLinkViewController");
    // XLinks is the Swift route
    return (conversationClass && [controller isKindOfClass:conversationClass]) ||
           (linkClass && [controller isKindOfClass:linkClass]);
}

BOOL BHTRouteTweetToDetail(UINavigationController* primary, UIViewController* controller) {
    if (!BHTSplitTweetViewEnabled() || !BHTIsConversationController(controller)) {
        return NO;
    }
    BHTSplitTweetState* state = BHTTweetStateForController(primary);
    if (!state || primary == state.detail) {
        return NO;
    }
    return [state showConversation:controller fromPrimary:primary];
}

BOOL BHTRouteAppendedTweet(UINavigationController* primary, NSArray<UIViewController*>* controllers) {
    NSArray<UIViewController*>* existing = primary.viewControllers;
    if (!existing.count || controllers.count != existing.count + 1) {
        return NO;
    }
    for (NSUInteger index = 0; index < existing.count; index++) {
        if (existing[index] != controllers[index]) {
            return NO;
        }
    }
    return BHTRouteTweetToDetail(primary, controllers.lastObject);
}

BHTSplitTweetHostController* BHTMakeTweetColumnHost(UIViewController* content) {
    Class factory = NSClassFromString(@"NavigationControllerFactoryTFNFallback");
    if (!BHTSplitTweetViewEnabled() || !content || content.parentViewController ||
        [content isKindOfClass:BHTSplitTweetHostController.class] ||
        ![factory respondsToSelector:@selector(makeWithRootViewController:)]) {
        return nil;
    }

    UIViewController* empty = [UIViewController new];
    UINavigationController* detail = [factory makeWithRootViewController:empty];
    if (![detail isKindOfClass:UINavigationController.class]) {
        return nil;
    }
    BHTSplitTweetHostController* host = [[BHTSplitTweetHostController alloc] initWithContent:content detail:detail];
    BHTSplitTweetState* state = [BHTSplitTweetState new];
    state.glassHost = host;
    state.detail = detail;
    state.emptyController = empty;
    objc_setAssociatedObject(host, &BHTSplitTweetStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(detail, &BHTSplitTweetStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [state setUpDetailColumn];
    return host;
}

void BHTAttachTweetColumn(T1AppSplitViewController* split, BHTSplitTweetHostController* host) {
    if (!split) {
        return;
    }
    BHTSplitTweetState* state = BHTTweetState(host);
    state.split = split;
    objc_setAssociatedObject(split, &BHTSplitTweetStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UIView* BHTTweetColumnAppView(BHTSplitTweetHostController* host) {
    id delegate = BHTTweetState(host).split.delegate;
    if (![delegate isKindOfClass:UIViewController.class]) return nil;
    for (UIViewController* parent = host.parentViewController; parent; parent = parent.parentViewController) {
        if (parent == delegate) return parent.viewIfLoaded;
    }
    return nil;
}

void BHTLayoutTweetColumnChrome(BHTSplitTweetHostController* host) {
    [host.content.viewIfLoaded layoutIfNeeded];
    UIView* appView = BHTTweetColumnAppView(host);
    [appView setNeedsLayout];
    [appView layoutIfNeeded];
    [host.content.viewIfLoaded layoutIfNeeded];
}

static char BHTConversationBarKey;

BOOL BHTSplitColumnBarHidden(UINavigationController* navigation, BOOL hidden) {
    if (hidden) return YES;
    // A post keeps the "Post" bar hidden even when X reveals it on scrolling up.
    UIViewController* top = navigation.topViewController;
    if (NFBLiquidGlassEnabled() && BHTIsConversationController(top) &&
        objc_getAssociatedObject(top, &BHTConversationBarKey)) return YES;
    BHTSplitTweetState* state = BHTTweetStateForController(navigation);
    return state && BHTSplitTweetViewEnabled() && navigation == state.detail;
}

// MARK: - Back swipe (shared by the right column and posts in the normal view)

BOOL BHTIsBackSwipeStart(UIPanGestureRecognizer* pan) {
    CGPoint velocity = [pan velocityInView:pan.view];
    if (velocity.x <= fabs(velocity.y)) return NO;
    // Leave horizontal scrollers (media carousels) alone while they can still scroll back.
    UIView* hit = [pan.view hitTest:[pan locationInView:pan.view] withEvent:nil];
    for (UIView* view = hit; view && view != pan.view; view = view.superview) {
        if (![view isKindOfClass:UIScrollView.class]) continue;
        UIScrollView* scroll = (UIScrollView*)view;
        if (scroll.contentSize.width > CGRectGetWidth(scroll.bounds) &&
            scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1.0) return NO;
    }
    return YES;
}

BOOL BHTBackSwipeBlocksScrolling(UIGestureRecognizer* gesture, UIGestureRecognizer* other) {
    // Vertical scrolling waits until the swipe has ruled out going back.
    UIView* view = other.view;
    return [other isKindOfClass:UIPanGestureRecognizer.class] && [view isKindOfClass:UIScrollView.class] &&
           ((UIScrollView*)view).contentSize.width <= CGRectGetWidth(view.bounds) &&
           [view isDescendantOfView:gesture.view];
}

// MARK: - Posts without the "Post" bar (Liquid Glass)

static char BHTConversationSwipeKey;

@interface BHTConversationSwipe : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController* conversation;
@end

@implementation BHTConversationSwipe

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    UINavigationController* navigation = self.conversation.navigationController;
    // The split view's right column has its own swipe.
    return NFBLiquidGlassEnabled() && navigation.navigationBarHidden && !BHTTweetState(navigation) &&
           navigation.viewControllers.count > 1 && navigation.topViewController == self.conversation &&
           !navigation.transitionCoordinator && BHTIsBackSwipeStart((UIPanGestureRecognizer*)gesture);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer*)other {
    return BHTBackSwipeBlocksScrolling(gesture, other);
}

- (void)handlePan:(UIPanGestureRecognizer*)pan {
    if (pan.state != UIGestureRecognizerStateEnded) return;
    UIView* view = pan.view;
    if ([pan translationInView:view].x > 80.0 || [pan velocityInView:view].x > 500.0) {
        [self.conversation.navigationController popViewControllerAnimated:YES];
    }
}

@end

static BOOL BHTIsManagedPost(UIViewController* controller) {
    return NFBLiquidGlassEnabled() && BHTIsConversationController(controller) &&
           objc_getAssociatedObject(controller, &BHTConversationBarKey);
}

// X pads its post table by hand (no automatic insets) and re-pads it as the
// post loads (78, later 122) to clear the header the tweak hides. Cap the top
// at the real safe area, and pull the table back to the top if it was there.
UIEdgeInsets BHTPostTableInset(UIScrollView* table, UIEdgeInsets inset) {
    if (!NFBLiquidGlassEnabled() || table.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
        return inset;
    }
    UIViewController* post = nil;
    for (UIResponder* responder = table.nextResponder; responder && !post; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class] && BHTIsConversationController((UIViewController*)responder)) {
            post = (UIViewController*)responder;
        }
    }
    if (!BHTIsManagedPost(post)) return inset;
    CGFloat safeTop = post.view.safeAreaInsets.top;
    // Only the padding: X re-pads while scrolling (its collapsing header), so
    // moving the scroll position here fought the user's scroll.
    if (inset.top > safeTop + 1.0) inset.top = safeTop;
    return inset;
}

// Once, when a post appears: if it opened scrolled into the old header padding,
// show it from the top. Never while the user is scrolling.
void BHTConversationDidAppear(UIViewController* conversation) {
    if (!BHTIsManagedPost(conversation)) return;
    UIScrollView* table = BHTLargestScrollView(conversation.viewIfLoaded);
    if (!table || table.isTracking || table.isDragging || table.isDecelerating) return;
    CGFloat top = -table.adjustedContentInset.top;
    if (table.contentOffset.y < top - 1.0) table.contentOffset = CGPointMake(table.contentOffset.x, top);
}

// iOS 26's own scroll-edge effect at the top of lists (runtime API: this builds
// against an older SDK). Hidden with Liquid Glass, like X's top fade.
void BHTHideTopEdgeEffect(UIScrollView* scroll) {
    if (!NFBLiquidGlassEnabled()) return;
    SEL topEffect = NSSelectorFromString(@"topEdgeEffect");
    if (![scroll respondsToSelector:topEffect]) return;
    id effect = ((id (*)(id, SEL))objc_msgSend)(scroll, topEffect);
    SEL setHidden = NSSelectorFromString(@"setHidden:");
    if ([effect respondsToSelector:setHidden]) ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setHidden, YES);
}

BOOL BHTPostOwnsTopInset(UIViewController* controller) {
    if (BHTIsManagedPost(controller)) return YES;
    return [controller isKindOfClass:UINavigationController.class] &&
           BHTIsManagedPost(((UINavigationController*)controller).topViewController);
}

// X's glass back buttons are XDSButtons; one also floats in once a post is
// scrolled down. On a managed post, any of them labelled "Back" stays hidden.
BOOL BHTIsPostBackButton(UIView* button) {
    NSString* label = button.accessibilityLabel;
    if (!label.length || !NFBLiquidGlassEnabled()) return NO;
    static NSSet<NSString*>* labels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString* uikit = [[NSBundle bundleForClass:UIApplication.class] localizedStringForKey:@"Back"
                                                                                         value:@"Back"
                                                                                         table:nil];
        labels = [NSSet setWithObjects:@"Back", uikit, nil];
    });
    if (![labels containsObject:label]) return NO;
    for (UIResponder* responder = button.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UINavigationController.class]) {
            return BHTIsManagedPost(((UINavigationController*)responder).topViewController);
        }
    }
    return NO;
}

static __weak UIViewController* BHTCurrentPost;

static NSString* BHTRectText(CGRect rect) {
    return [NSString stringWithFormat:@"(%.0f,%.0f %.0fx%.0f)", rect.origin.x, rect.origin.y, rect.size.width,
                                      rect.size.height];
}

static NSString* BHTInsetsText(UIEdgeInsets insets) {
    return [NSString stringWithFormat:@"t%.0f l%.0f b%.0f r%.0f", insets.top, insets.left, insets.bottom, insets.right];
}

UIScrollView* BHTLargestScrollView(UIView* view) {
    UIScrollView* best = nil;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:view];
    while (queue.count) {
        UIView* current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([current isKindOfClass:UIScrollView.class] && !current.hidden &&
            CGRectGetWidth(current.bounds) * CGRectGetHeight(current.bounds) >
                CGRectGetWidth(best.bounds) * CGRectGetHeight(best.bounds)) {
            best = (UIScrollView*)current;
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return best;
}

// Views in the top strip (not content, not the tweak's own overlay) and every
// "Back"-labelled view, with frames in window coordinates.
static void BHTReportViews(UIView* view, NSMutableString* top, NSMutableString* back, NSUInteger depth) {
    for (UIView* subview in view.subviews) {
        NSString* name = NSStringFromClass(subview.class);
        if ([name hasPrefix:@"BHT"]) continue;
        CGRect rect = [subview convertRect:subview.bounds toView:nil];
        NSString* line = [NSString stringWithFormat:@"%@%@ %@%@%@\n", [@"" stringByPaddingToLength:depth withString:@"." startingAtIndex:0], name,
                                                    BHTRectText(rect), subview.hidden ? @" hidden" : @"",
                                                    subview.alpha < 0.01 ? @" a0" : @""];
        if ([subview.accessibilityLabel isEqualToString:@"Back"]) [back appendString:line];
        BOOL content = [subview isKindOfClass:UIScrollView.class];
        if (!content && CGRectGetMinY(rect) < 160.0 && CGRectGetHeight(rect) <= 200.0 && CGRectGetWidth(rect) >= 20.0 &&
            top.length < 3000) {
            [top appendString:line];
        }
        BHTReportViews(subview, content ? nil : top, back, depth + 1);
    }
}

NSString* BHTPostLayoutReport(void) {
    UIViewController* post = BHTCurrentPost;
    UINavigationController* navigation = post.navigationController;
    if (!post.viewIfLoaded.window) return nil;
    NSMutableString* report = [NSMutableString new];
    [report appendFormat:@"Post %@ additional %@ safe %@\n", NSStringFromClass(post.class),
                         BHTInsetsText(post.additionalSafeAreaInsets), BHTInsetsText(post.view.safeAreaInsets)];
    [report appendFormat:@"Nav %@ additional %@ barHidden %d\n", NSStringFromClass(navigation.class),
                         BHTInsetsText(navigation.additionalSafeAreaInsets), navigation.navigationBarHidden];
    for (UIViewController* parent = navigation.parentViewController; parent; parent = parent.parentViewController) {
        [report appendFormat:@"Parent %@ additional %@\n", NSStringFromClass(parent.class),
                             BHTInsetsText(parent.additionalSafeAreaInsets)];
    }
    UIScrollView* scroll = BHTLargestScrollView(post.view);
    [report appendFormat:@"Scroll %@ %@ inset %@ adjusted %@ behavior %ld\n", NSStringFromClass(scroll.class),
                         BHTRectText([scroll convertRect:scroll.bounds toView:nil]), BHTInsetsText(scroll.contentInset),
                         BHTInsetsText(scroll.adjustedContentInset), (long)scroll.contentInsetAdjustmentBehavior];
    NSMutableString* top = [NSMutableString new];
    NSMutableString* back = [NSMutableString new];
    for (UIWindow* window in post.view.window.windowScene.windows)
        BHTReportViews(window, top, back, 0);
    [report appendFormat:@"\nBack views:\n%@\nTop strip:\n%@", back.length ? back : @"none\n", top];
    return report;
}

void BHTConversationWillAppear(UIViewController* conversation, BOOL animated) {
    UINavigationController* navigation = conversation.navigationController;
    if (!NFBLiquidGlassEnabled() || !navigation) return;
    BHTCurrentPost = conversation;
    if (!objc_getAssociatedObject(conversation, &BHTConversationBarKey)) {
        // What the bar looked like before this post, restored when leaving posts.
        objc_setAssociatedObject(conversation, &BHTConversationBarKey, @(navigation.navigationBarHidden),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [navigation setNavigationBarHidden:YES animated:animated];
    // Drop X's room for its (hidden) header now that the post is managed.
    BHTReapplySafeAreaInsets(conversation);
    BHTReapplySafeAreaInsets(navigation);
    if (!objc_getAssociatedObject(conversation, &BHTConversationSwipeKey)) {
        // ponytail: not interactive; the pop animates once the swipe ends.
        BHTConversationSwipe* swipe = [BHTConversationSwipe new];
        swipe.conversation = conversation;
        UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:swipe
                                                                              action:@selector(handlePan:)];
        pan.delegate = swipe;
        [conversation.view addGestureRecognizer:pan];
        objc_setAssociatedObject(conversation, &BHTConversationSwipeKey, swipe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSHashTable<UIView*>* BHTHiddenBackButtons(void);

void BHTConversationWillDisappear(UIViewController* conversation, BOOL animated) {
    UINavigationController* navigation = conversation.navigationController;
    NSNumber* previous = objc_getAssociatedObject(conversation, &BHTConversationBarKey);
    // Post to post keeps the bar hidden; anything else gets back what it had.
    if (!previous || !navigation || BHTIsConversationController(navigation.topViewController)) return;
    objc_setAssociatedObject(conversation, &BHTConversationBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation setNavigationBarHidden:previous.boolValue animated:animated];
    BHTReapplySafeAreaInsets(conversation);
    BHTReapplySafeAreaInsets(navigation);
    // Other screens keep X's floating back button.
    for (UIView* button in BHTHiddenBackButtons().allObjects)
        button.hidden = NO;
    [BHTHiddenBackButtons() removeAllObjects];
}

// X shows its own floating glass back button over a post once the bar is
// hidden. Swiping replaces it, so hide it.
// ponytail: found by its "Back" accessibility label (English plus UIKit's own).
static NSHashTable<UIView*>* BHTHiddenBackButtons(void) {
    static NSHashTable<UIView*>* buttons;
    if (!buttons) buttons = [NSHashTable weakObjectsHashTable];
    return buttons;
}

static void BHTHideForPost(UIView* view) {
    if (view.hidden) return;
    view.hidden = YES;
    [BHTHiddenBackButtons() addObject:view];
}

static void BHTHideFloatingBackButtons(UIView* view, NSSet<NSString*>* labels) {
    for (UIView* subview in view.subviews) {
        if ([subview isKindOfClass:UIScrollView.class]) continue; // content, not chrome
        if ([subview isKindOfClass:UIControl.class] && [labels containsObject:subview.accessibilityLabel]) {
            // Its glass circle too: the largest ancestor that is still button-sized.
            UIView* button = subview;
            while (button.superview && CGRectGetWidth(button.superview.bounds) <= 80.0 &&
                   CGRectGetHeight(button.superview.bounds) <= 80.0)
                button = button.superview;
            BHTHideForPost(button);
            continue;
        }
        BHTHideFloatingBackButtons(subview, labels);
    }
}

// Whether `view` is X's post header chrome (NavigationBarView or its
// ChromeBackgroundView) in a navigation stack showing a managed post.
BOOL BHTIsPostChrome(UIView* view) {
    if (!NFBLiquidGlassEnabled() || !view.window) return NO;
    for (UIResponder* responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UINavigationController.class]) {
            UIViewController* top = ((UINavigationController*)responder).topViewController;
            return BHTIsConversationController(top) && objc_getAssociatedObject(top, &BHTConversationBarKey);
        }
    }
    return NO;
}

void BHTPostChromeChanged(UIView* view) {
    if (!view.hidden && BHTIsPostChrome(view)) BHTHideForPost(view);
}

// X's Liquid Glass post screen has its own collapsing header ("Post" title,
// back button) besides UINavigationBar; it shows at the top and on scrolling
// up. Hide the strip holding its title view while a post is managed here.
void BHTNavigationTitleDidLayout(UIView* title) {
    if (!NFBLiquidGlassEnabled() || !title.window) return;
    UINavigationController* navigation = nil;
    for (UIResponder* responder = title.nextResponder; responder && !navigation; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UINavigationController.class]) navigation = (UINavigationController*)responder;
    }
    UIViewController* top = navigation.topViewController;
    if (!BHTIsConversationController(top) || !objc_getAssociatedObject(top, &BHTConversationBarKey)) return;
    // The header: the tallest ancestor still bar-sized (a header, not the screen).
    UIView* header = title;
    for (UIView* view = title.superview; view && view != navigation.view; view = view.superview) {
        if (CGRectGetHeight(view.bounds) > 160.0 || [view isKindOfClass:UIScrollView.class]) break;
        header = view;
    }
    BHTHideForPost(header);
}

void BHTConversationDidLayout(UIViewController* conversation) {
    UINavigationController* navigation = conversation.navigationController;
    if (!NFBLiquidGlassEnabled() || !navigation.navigationBarHidden ||
        !objc_getAssociatedObject(conversation, &BHTConversationBarKey)) return;
    static NSSet<NSString*>* labels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString* uikit = [[NSBundle bundleForClass:UIApplication.class] localizedStringForKey:@"Back"
                                                                                         value:@"Back"
                                                                                         table:nil];
        labels = [NSSet setWithObjects:@"Back", uikit, nil];
    });
    BHTHideFloatingBackButtons(navigation.view, labels);
}

// MARK: - Open the right column at the first reply

static char BHTScrollToRepliesKey;
static char BHTLoadingCoverKey;

void BHTRevealColumn(UIView* column) {
    if (!column) return; // e.g. a timer outliving the column
    UIView* cover = objc_getAssociatedObject(column, &BHTLoadingCoverKey);
    objc_setAssociatedObject(column, &BHTLoadingCoverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (column.alpha >= 1.0 && !cover) return;
    [UIView animateWithDuration:0.15
        animations:^{
            column.alpha = 1.0;
            cover.alpha = 0.0;
        }
        completion:^(BOOL finished) {
            [cover removeFromSuperview];
        }];
}

// The post's content stays out of sight until it sits at the first reply, so
// it never visibly loads and then jumps: either the whole column is blank, or
// (with the setting) the column shows a spinner. A safety timer always reveals it.
void BHTMarkScrollToReplies(UIViewController* conversation, UIView* column) {
    objc_setAssociatedObject(conversation, &BHTScrollToRepliesKey, column, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [objc_getAssociatedObject(column, &BHTLoadingCoverKey) removeFromSuperview];
    if ([BHTSettings boolForKey:@"split_view_loading_spinner"]) {
        UIView* cover = [[UIView alloc] initWithFrame:column.bounds];
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        cover.backgroundColor = UIColor.systemBackgroundColor;
        UIActivityIndicatorView* spinner =
            [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.center = CGPointMake(CGRectGetMidX(cover.bounds), CGRectGetMidY(cover.bounds));
        spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                   UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [spinner startAnimating];
        [cover addSubview:spinner];
        [column addSubview:cover];
        objc_setAssociatedObject(column, &BHTLoadingCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        column.alpha = 1.0;
    } else {
        objc_setAssociatedObject(column, &BHTLoadingCoverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        column.alpha = 0.0;
    }
    __weak UIView* weakColumn = column;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTRevealColumn(weakColumn);
    });
}

static UIView* BHTCellForView(UIView* view, UIScrollView* scroll) {
    while (view.superview && view.superview != scroll && ![view isKindOfClass:UITableViewCell.class] &&
           ![view isKindOfClass:UICollectionViewCell.class])
        view = view.superview;
    return view;
}

// Where the replies start below `focalBottom`: the reply sort row ("Relevant ·
// View quotes"), else the first reply, or CGFLOAT_MAX while neither has loaded.
// ponytail: both are spotted by name (a "Sort" class or the "View quotes" label;
// replies by a …StatusView class that isn't the focal post's).
static CGFloat BHTRepliesTop(UIScrollView* scroll, CGFloat focalBottom) {
    __block CGFloat sortTop = CGFLOAT_MAX;
    __block CGFloat replyTop = CGFLOAT_MAX;
    EnumerateSubviewsRecursively(scroll, ^(UIView* view) {
        if (view.hidden) return;
        NSString* name = NSStringFromClass(view.class);
        BOOL sort = [name rangeOfString:@"Sort" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    ([view isKindOfClass:UILabel.class] && [((UILabel*)view).text isEqualToString:@"View quotes"]);
        BOOL reply = [name hasSuffix:@"StatusView"] && ![name containsString:@"Focal"];
        if (!sort && !reply) return;
        UIView* cell = BHTCellForView(view, scroll);
        CGFloat top = CGRectGetMinY([cell convertRect:cell.bounds toView:scroll]);
        if (top < focalBottom - 1.0) return;
        if (sort) sortTop = MIN(sortTop, top);
        if (reply) replyTop = MIN(replyTop, top);
    });
    return sortTop < CGFLOAT_MAX ? sortTop : replyTop;
}

// Replies load after the post and X re-anchors the post while they do, so keep
// the first reply at the top for a moment unless the user scrolls.
static void BHTKeepScrolledToFirstReply(UIView* focal, UIScrollView* scroll, UIView* column, NSInteger attempts) {
    if (attempts <= 0 || !focal.window || !scroll.window || scroll.isTracking || scroll.isDragging ||
        scroll.isDecelerating) {
        BHTRevealColumn(column);
        return;
    }
    UIEdgeInsets inset = scroll.adjustedContentInset;
    CGFloat focalBottom = CGRectGetMaxY([focal convertRect:focal.bounds toView:scroll]);
    CGFloat reply = BHTRepliesTop(scroll, focalBottom);
    CGFloat limit = scroll.contentSize.height + inset.bottom - CGRectGetHeight(scroll.bounds);
    // Until a reply cell exists, scroll to just above the post's end (kept 1pt on
    // screen so the post isn't recycled) so the cells below it get created.
    CGFloat target = reply < CGFLOAT_MAX ? MIN(reply - inset.top, limit) : focalBottom - inset.top - 1.0;
    BOOL moved = target > -inset.top && target <= limit && fabs(scroll.contentOffset.y - target) > 1.0;
    if (moved) scroll.contentOffset = CGPointMake(scroll.contentOffset.x, target);
    // Reveal once a check needed no correction: X's padding and the sort row can
    // still move things right after the first reply turns up.
    if (reply < CGFLOAT_MAX && !moved) BHTRevealColumn(column);
    __weak UIView* weakFocal = focal;
    __weak UIScrollView* weakScroll = scroll;
    __weak UIView* weakColumn = column;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTKeepScrolledToFirstReply(weakFocal, weakScroll, weakColumn, attempts - 1);
    });
}

void BHTScrollPastFocalIfNeeded(UIView* focal) {
    if (!focal.window || !BHTSplitTweetViewEnabled()) return;
    for (UIResponder* responder = focal.nextResponder; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIView* column = objc_getAssociatedObject(responder, &BHTScrollToRepliesKey);
        if (!column) continue;
        objc_setAssociatedObject(responder, &BHTScrollToRepliesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView* scroll = focal.superview;
        while (scroll && ![scroll isKindOfClass:UIScrollView.class])
            scroll = scroll.superview;
        if (scroll) {
            BHTKeepScrolledToFirstReply(focal, (UIScrollView*)scroll, column, 25);
        } else {
            BHTRevealColumn(column);
        }
        return;
    }
}
