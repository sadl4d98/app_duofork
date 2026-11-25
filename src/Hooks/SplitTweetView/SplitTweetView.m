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

BOOL BHTSplitColumnBarHidden(UINavigationController* navigation, BOOL hidden) {
    BHTSplitTweetState* state = BHTTweetStateForController(navigation);
    return hidden || (state && BHTSplitTweetViewEnabled() && navigation == state.detail);
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

static char BHTConversationBarKey;
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

void BHTConversationWillAppear(UIViewController* conversation, BOOL animated) {
    UINavigationController* navigation = conversation.navigationController;
    if (!NFBLiquidGlassEnabled() || !navigation) return;
    if (!objc_getAssociatedObject(conversation, &BHTConversationBarKey)) {
        // What the bar looked like before this post, restored when leaving posts.
        objc_setAssociatedObject(conversation, &BHTConversationBarKey, @(navigation.navigationBarHidden),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [navigation setNavigationBarHidden:YES animated:animated];
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

void BHTConversationWillDisappear(UIViewController* conversation, BOOL animated) {
    UINavigationController* navigation = conversation.navigationController;
    NSNumber* previous = objc_getAssociatedObject(conversation, &BHTConversationBarKey);
    // Post to post keeps the bar hidden; anything else gets back what it had.
    if (!previous || !navigation || BHTIsConversationController(navigation.topViewController)) return;
    objc_setAssociatedObject(conversation, &BHTConversationBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation setNavigationBarHidden:previous.boolValue animated:animated];
}

// MARK: - Open the right column at the first reply

static char BHTScrollToRepliesKey;
static char BHTLoadingCoverKey;

void BHTRevealColumn(UIView* column) {
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

// Top of the first reply below `focalBottom`, or CGFLOAT_MAX while none has loaded.
// ponytail: replies are spotted by class name (…StatusView, not the focal one).
static CGFloat BHTFirstReplyTop(UIScrollView* scroll, CGFloat focalBottom) {
    __block CGFloat best = CGFLOAT_MAX;
    EnumerateSubviewsRecursively(scroll, ^(UIView* view) {
        NSString* name = NSStringFromClass(view.class);
        if (![name hasSuffix:@"StatusView"] || [name containsString:@"Focal"] || view.hidden) return;
        UIView* cell = BHTCellForView(view, scroll);
        CGFloat top = CGRectGetMinY([cell convertRect:cell.bounds toView:scroll]);
        if (top >= focalBottom - 1.0 && top < best) best = top;
    });
    return best;
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
    CGFloat reply = BHTFirstReplyTop(scroll, focalBottom);
    CGFloat limit = scroll.contentSize.height + inset.bottom - CGRectGetHeight(scroll.bounds);
    // Until a reply cell exists, scroll to just above the post's end (kept 1pt on
    // screen so the post isn't recycled) so the cells below it get created.
    CGFloat target = reply < CGFLOAT_MAX ? MIN(reply - inset.top, limit) : focalBottom - inset.top - 1.0;
    if (target > -inset.top && target <= limit && fabs(scroll.contentOffset.y - target) > 1.0) {
        scroll.contentOffset = CGPointMake(scroll.contentOffset.x, target);
    }
    if (reply < CGFLOAT_MAX) BHTRevealColumn(column);
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
