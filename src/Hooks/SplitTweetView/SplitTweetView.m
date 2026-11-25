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
    if (!state) {
        return NO;
    }
    if (primary == state.detail) {
        return [state advanceToConversation:controller];
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
    if (hidden || !state || !BHTSplitTweetViewEnabled()) return hidden;
    return navigation == state.detail || (state.primaryBarHidden && navigation == state.primary);
}

// MARK: - Open the right column at the first reply

static char BHTScrollToRepliesKey;

void BHTMarkScrollToReplies(UIViewController* conversation) {
    objc_setAssociatedObject(conversation, &BHTScrollToRepliesKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Replies load after the focal post, and X re-anchors the post while they do,
// so keep the post scrolled just out of view for a moment unless the user scrolls.
static void BHTKeepScrolledPastFocal(UIView* focal, UIScrollView* scroll, NSInteger attempts) {
    if (attempts <= 0 || !focal.window || !scroll.window || scroll.isTracking || scroll.isDragging ||
        scroll.isDecelerating) return;
    UIEdgeInsets inset = scroll.adjustedContentInset;
    CGFloat target = CGRectGetMaxY([focal convertRect:focal.bounds toView:scroll]) - inset.top;
    CGFloat limit = scroll.contentSize.height + inset.bottom - CGRectGetHeight(scroll.bounds);
    // ponytail: with too few replies to fill the column, the post stays where X put it.
    if (target <= limit && fabs(scroll.contentOffset.y - target) > 1.0) {
        scroll.contentOffset = CGPointMake(scroll.contentOffset.x, target);
    }
    __weak UIView* weakFocal = focal;
    __weak UIScrollView* weakScroll = scroll;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTKeepScrolledPastFocal(weakFocal, weakScroll, attempts - 1);
    });
}

void BHTScrollPastFocalIfNeeded(UIView* focal) {
    if (!focal.window || !BHTSplitTweetViewEnabled()) return;
    for (UIResponder* responder = focal.nextResponder; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class] ||
            !objc_getAssociatedObject(responder, &BHTScrollToRepliesKey)) continue;
        objc_setAssociatedObject(responder, &BHTScrollToRepliesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView* scroll = focal.superview;
        while (scroll && ![scroll isKindOfClass:UIScrollView.class])
            scroll = scroll.superview;
        if (scroll) BHTKeepScrolledPastFocal(focal, (UIScrollView*)scroll, 25);
        return;
    }
}
