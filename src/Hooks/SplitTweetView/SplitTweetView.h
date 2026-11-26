#import "../HookHelpers.h"

static char BHTSplitTweetStateKey;

BOOL BHTSplitTweetViewEnabled(void);
BHTSplitTweetState* BHTTweetState(id object);
BHTSplitTweetState* BHTTweetStateForController(UIViewController* controller);
BOOL BHTIsConversationController(UIViewController* controller);
BOOL BHTRouteTweetToDetail(UINavigationController* primary, UIViewController* controller);
BOOL BHTRouteAppendedTweet(UINavigationController* primary, NSArray<UIViewController*>* controllers);
BHTSplitTweetHostController* BHTMakeTweetColumnHost(UIViewController* content);
void BHTAttachTweetColumn(T1AppSplitViewController* split, BHTSplitTweetHostController* host);
UIView* BHTTweetColumnAppView(BHTSplitTweetHostController* host);
void BHTLayoutTweetColumnChrome(BHTSplitTweetHostController* host);
BOOL BHTSplitColumnBarHidden(UINavigationController* navigation, BOOL hidden);
void BHTMarkScrollToReplies(UIViewController* conversation, UIView* column);
void BHTScrollPastFocalIfNeeded(UIView* focal);
void BHTRevealColumn(UIView* column);
BOOL BHTIsBackSwipeStart(UIPanGestureRecognizer* pan);
BOOL BHTBackSwipeBlocksScrolling(UIGestureRecognizer* gesture, UIGestureRecognizer* other);
void BHTConversationWillAppear(UIViewController* conversation, BOOL animated);
void BHTConversationWillDisappear(UIViewController* conversation, BOOL animated);
void BHTConversationDidLayout(UIViewController* conversation);
void BHTNavigationTitleDidLayout(UIView* title);
BOOL BHTIsPostChrome(UIView* view);
void BHTPostChromeChanged(UIView* view);
