# Notes for Claude

The portable, app-agnostic version of what's below is the skill
`.claude/skills/iphone-duo-native-tab-bar/SKILL.md` (copy it to other repos or `~/.claude/skills/`).

## iPhone Duo: native vertical (right-side) Liquid Glass tab bar

- On iOS 27.1+, the vertical Liquid Glass tab bar on the unfolded iPhone Duo has no separate
  public class. UIKit draws it automatically for `UITabBarController` (with a standard `UITabBar`),
  and SwiftUI for `TabView`, when the **app** is built with the iOS 27.1 SDK or newer.
  (Source: the user's research, Nov 2026. Not checked against Apple's docs; confirm with FLEX on device.)
- Consequences for this tweak:
  - X doesn't use `UITabBarController`. Its glass bar is `_TtC11XNavigation16TabBarController` /
    `_TtC11XNavigation10TabBarView`, so X won't get the native rail by itself.
  - The behavior depends on the SDK of X's own binary, not the tweak's `sdk_version`. Raising the
    tweak's SDK in `build.yml` won't turn the rail on.
  - Current workaround: `BHTGlassTabRail` (`src/Hooks/Theme/Theme.m`) is a native glass rail on the
    right edge everywhere except the unfolded screen held upright (`NFBGlassTabRailActive`: landscape,
    or portrait narrower than `NFBGlassTabRailCompactWidth`), matching how Duo apps behave. X's bar stays in the hierarchy but hidden, and
    each rail button forwards its tap to X's own tab item (UIControl actions, else the tap
    recognizer's targets). The split columns leave `NFBGlassTabRailInset` (`src/Hooks/HookHelpers.h`) for it.
  - Native option (`native_tab_bar` setting, on by default): `BHTNativeTabHost` lays a real
    `UITabBarController` over X (as a child of the top controller, in a pass-through view). Its tabs
    are empty pages mirroring X's items, and selecting one forwards the tap to X's own item. iOS
    places this bar itself, so it gets the true Duo layout only if X's binary is built with the
    iOS 27.1 SDK. The `Build Tweak` workflow prints X's build SDK as a notice to check this. X 12.46 is built with the
    iOS 27.1 SDK (minimum iOS 15.0), checked 25 Nov 2026.
    `sidebar.preferredPlacement` stays on automatic, because `.sidebar` gives the iPad-style list.
  - Rotating X's bar instead was tried and failed: X minimizes and animates the bar with its own
    transforms.
  - A native rail would mean hosting a real `UITabBarController`/`UITabBar` that mirrors X's tabs and
    forwards tab selection to X's controller. That only works once X's binary is built with the
    iOS 27.1+ SDK.
- Apple's iPhone Duo guidance (Tech Talks "Design for iPhone Duo" / "Prepare your app for iPhone Duo"):
  bars move into a vertical strip on the side, beside the status bar. A tab bar sits at the bottom of
  that strip (the user's Photos screenshots show this). Only the unfolded screen in portrait keeps bars
  at the top and bottom. UIKit opts in through the sidebar's preferred placement; iOS 27.1 adds
  `UIViewReservedRegion` for custom UI. The rail follows this: it is bottom-aligned in the strip
  (`window.safeAreaInsets.right`), and content is only inset (`NFBGlassTabRailNeedsInset`) when there
  is no strip.
- X reveals the "Post" bar again when scrolling up a post (and after opening one), so
  `BHTSplitColumnBarHidden` forces it hidden while a post managed by the tweak is on top of its
  navigation stack. The `setNavigationBarHidden:` hooks on XNAV, T1Tab and TFN all route through it.
- Besides UINavigationBar, X's Liquid Glass post screen has its own collapsing header ("Post" title
  and glass back button) that shows at the top and on scroll-up. The tweak hooks
  `_TtC11XNavigation22NavigationBarTitleView` and hides the tallest bar-sized (≤160pt) ancestor of the
  title while a managed post is on top, restoring it when leaving posts. The header's reserved space
  is dropped too: the `setAdditionalSafeAreaInsets:` hook zeroes `top` for the managed post and its
  navigation controller (`BHTPostOwnsTopInset`), reapplied on appear and leave. Unconfirmed: this
  assumes X reserves the space that way. A second floating back button (an `XDSButton` labelled
  "Back") appears after scrolling down; the XDSButton hooks keep it hidden on managed posts
  (`BHTIsPostBackButton`).
- Post-layout report (X 12.46, outer screen): X's post header is `XNavigation.NavigationBarView`
  (377×78) over `XNavigation.ChromeBackgroundView`. The back button is an `XDSButton` inside an
  `XDSGlass` circle (45×44). The post VC (`T1ConversationContainerViewController`) has
  `additionalSafeAreaInsets.top = 78`, set before the tweak starts managing it. Its `TFNTableView`
  pads itself by hand (`contentInsetAdjustmentBehavior` never, `contentInset.top` 78). So the tweak:
  - hooks both header classes (hidden while a managed post is on top, restored on leave);
  - reapplies insets from the current value when nothing is stored;
  - trims the table's manual top padding to the safe area.
  To get the report, turn on Debug mode and long-press the rail's compose button.
- X re-pads the post table as it loads (`contentInset.top` 78, later 122). So `TFNTableView
  setContentInset:` is hooked to cap the top at the safe area on managed posts (`BHTPostTableInset`).
  A one-off trim on layout lost to later re-pads. **Never move contentOffset there.** X re-pads while
  scrolling (its collapsing header), and offset corrections tied to inset changes or layout made the
  post snap back up while scrolling down. The only offset fix is once in `viewDidAppear`
  (`BHTConversationDidAppear`), when the user isn't touching it.
- Top fade: with Liquid Glass, X's top `XDesignSystem.ScrollEdgeTreatment` (fade plus blur) is kept
  at alpha 0 (`BHTIsTopScrollEdge`: in the top 25% of the window). iOS 26's own `topEdgeEffect` on
  `TFNTableView`s is hidden too. Bottom edge treatments are untouched.
- Builds: start `Build Tweak` only **after** `git push` has finished. Starting both at once built the
  previous commit.
- The split column's open/close spring is critically damped (1.0). X's own 0.75 made the timeline
  bounce after a swipe-back close.
- The back swipe moves the column with a transform, so layout places it with bounds/center
  (`BHTPlaceColumn`), never `frame`: a layout pass mid-swipe made it jump left over the timeline.
  A swipe that closes the column hands off to the close spring from where the finger let go, so
  the timeline widens while the column slides off instead of snapping afterwards.
- X re-lays the timeline out at a new width in one frame (left-aligned when narrow, centred when
  wide). During an open/close, a display link (`followColumnEdge`) sets the timeline's width to the
  sliding column's on-screen edge every frame, so X re-lays it out smoothly like a window resize.
  A snapshot crossfade was tried first; the user found the ghosting distracting. Per-frame resizing
  sometimes stuttered and drifted, so it steps every 8pt, lays out synchronously, and keeps the top
  visible row at the same screen position (`resizeTimelineTo:`).
- The right column is revealed only on a scroll-to-replies check that needed no correction;
  revealing on the first reply found showed it, then jumped once X's padding/sort row settled.
- With the bar hidden on posts, X draws its own floating glass "Back" button. It's hidden while a post
  is showing (matched by accessibility label), along with its ≤80pt glass circle, and restored when
  leaving posts. Every hide goes through `BHTHidePostBackButton` so it's recorded: X reuses the
  button on the next screen, and untracked hides left profiles with no back button or an empty circle.
- The hidden post header's header-sized (≤200pt) containers still took taps at the top of a post (X's
  tap-to-scroll-to-top: the scroll bar flashed and the author couldn't be tapped). They get
  `userInteractionEnabled = NO` while the post is managed (`BHTMuteHeaderContainers`). Unconfirmed;
  the debug report's "Taps at x=60" lists what the top of the post hit-tests to.
- The native tab host's view sits in the first full-window view above X's bar
  (`BHTFullWindowAncestor`), so it slides with the page when X's side menu opens. Its parent is the
  controller owning that view: a child view placed under another controller's view crashed X on launch
  (UIKit's view-controller hierarchy inconsistency abort). Making it a child of X's tab controller turned the bar horizontal with an iPad sidebar
  handle: that view stops at the side strip, and iOS only puts the bar in the strip when it covers it.
- The debug report works on any screen: taps at the top (x=60), every "Back" control with its two
  ancestors and subviews (hidden/alpha, "(tweak)" if the tweak hid it), and the top strip.
- To inspect class names on device: turn on the `flex_twitter` setting (bundled FLEX), then search
  runtime classes or use the view selector on the tab bar.

- Forwarding taps to X: X's handlers hit-test the bar, and hidden views can't be hit, so the
  replaced bar is briefly shown (`BHTShowingForTap`) while a tap is delivered, at alpha 0.02. That's still
  hit-testable but invisible, because X's tab-switch animation can draw a frame mid-tap and flashed the bar. On-device diagnostics
  (X 12.46) showed how `XNavigation.TabBarView` selects tabs: a `UILongPressGestureRecognizer` with
  action `handleTracking:` (the drag-between-tabs gesture). It also has a `UITapGestureRecognizer`
  with action `handleSecondaryClick:`, the context menu that opened the account switcher on Home. The
  tweak replays began/changed/ended on the tracking press, and never calls actions named
  "secondary". If X doesn't end up on the tab, an alert lists how the tap went and the item's
  recognizers and actions.
- The compose button decides "vertical" with the rail's rule (`NFBGlassTabRailActive` plus a side
  strip). It finds the system bar's platter as the largest visible view of the tab controller inside
  the strip, because `tabBar` isn't what the Duo strip layout draws. It copies the platter's width and
  centre line. A union of all strip views bulged while the selection slid between tabs, which made the
  button jump and grow.
- While the native bar is vertical, a tinted glass compose button sits above it and replaces X's "+".
  FLEX search on X 12.46: the Liquid Glass "+" is an `XDSButton` (a UIControl, 48×48) with
  accessibility label "Compose post". It's registered by its label, then hidden together with its
  small floating wrapper, and tapped with control actions. With no compose button on screen, the rail
  button opens `twitter://post`. Older `TFNFloatingActionButton`s are handled the same way.
  - Dead end: FLEX "select" on the "+" picks whatever full-screen layer is on top, first a
    `ControlMenuHostingView` (a Grok overlay in its own window), later the tweak's own tab overlay.
    Search by class or label in FLEX's views list instead.
- X's hidden bar: X creates fresh bar instances (e.g. entering the Grok tab), so the bar is hidden
  synchronously on `didMoveToWindow` and in the `setHidden:` hook (`BHTGlassTabReplacedNow`), not only
  on the async rail update. Otherwise it flashes for a frame or two.
- Bottom space: X reserves a bottom inset on its tab screens for its floating bar, which made Grok's
  input stop short of the bottom. While the bar is in the side strip, `setAdditionalSafeAreaInsets:` on
  `XNavigation.TabBarController` children gets its bottom zeroed. X's value is stored and reapplied
  when the layout changes. This assumes X uses additionalSafeAreaInsets; unconfirmed until tested on
  device.
- On iOS 27.1, content that reaches the side strip gets X's top-bar buttons moved into the strip, and
  X's logo (a title view) disappears. Ending the content at the strip keeps the bar and logo normal.

## Split view decisions

- Two columns split on the screen's centre line (the hinge), like Duo apps. The right column (and a
  single column) ends where the side strip begins, so nothing sits under the status bar or tab bar.

- Keep the split at two columns. A post opened from the right column pushes inside that column. The
  user found more columns disorienting.
- Back is a right swipe on the right column, with no close button. Posts never show the "Post" bar
  when Liquid Glass is on.
- The right column opens with the reply sort row ("Relevant · View quotes") at the top, else the first
  reply. It hides the post until it's in place. The `split_view_loading_spinner`
  setting shows the column straight away with a spinner over it instead.

## Builds

- `v7 Tests` (on PR / push to `v7`) compiles the tweak on macOS runners with the iOS 26.5 SDK.
- `Build Tweak` (manual) needs a direct link to a decrypted X IPA (X 12.46 matches current code).
  The user uploads it to litterbox.catbox.moe, which gives a temporary direct link.
