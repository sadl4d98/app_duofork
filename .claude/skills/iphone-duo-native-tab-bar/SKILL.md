---
name: iphone-duo-native-tab-bar
description: Make a third-party iOS app (via a Theos/Logos tweak) lay out like a native iPhone Duo app on iOS 27.1+. Covers replacing a custom tab bar with a real UIKit tab bar that iOS places in the Duo side strip, forwarding taps to the app's own tabs, a glass compose button on the rail, two-column split layout aligned to the hinge, side-strip spacing, hiding the app's nav bar and back buttons, and how to debug it all on device. Use when tweaking an app for iPhone Duo, foldables, side-strip tab bars, or iOS 27.1 layout.
---

# iPhone Duo native tab bar and layout (iOS 27.1+)

Learned while adapting X (NeoFreeBird fork, `sadl4d98/app_duofork`, Nov 2026) on a real iPhone Duo
running iOS 27.3. The working code is in that repo: `src/Hooks/Theme/Theme.m` (native tab bar, compose
button, tap forwarding) and `src/Hooks/SplitTweetView/` (two columns, nav bar and back handling). X's
class names appear only as examples; every app needs its own found with FLEX.

## 1. How iOS 27.1 lays out apps on iPhone Duo

- **Side strip.** On the outer screen and on the inner screen in landscape, the status bar sits in a
  vertical strip on the right edge. The strip is the window's `safeAreaInsets.right` (about 85pt).
  The system moves navigation and toolbar buttons into it.
- **Tab bar.** A standard tab bar sits at the **bottom** of that strip, vertical, as in Photos. On the
  **inner screen held upright** (portrait) bars stay horizontal at the top and bottom.
- **Only for standard containers.** UIKit draws that vertical bar only for `UITabBarController` (SwiftUI:
  `TabView`), and only when the **app's main binary is built with the iOS 27.1 SDK or newer**. The
  tweak's own SDK doesn't matter.
  - Check the app: `vtool -show-build <App>.app/<CFBundleExecutable>` (look for `sdk 27.1`). The NFB
    `Build Tweak` workflow prints it as a run notice. X 12.46 = SDK 27.1, minimum iOS 15.0.
  - Leave `UITabBarController.sidebar.preferredPlacement` on `.automatic` to get the Photos-style strip
    bar. `.sidebar` gives the iPad-style list instead.
- **Title views disappear when content reaches the strip.** If an app's content reaches the side strip,
  iOS moves its top-bar buttons into the strip and drops custom title views (X's logo vanished). End
  the content where the strip begins and the bar keeps its normal layout.
- **New 27.1 layout APIs** (`UIViewReservedRegion`, `ArrangementView` / `UIArrangementViewController`)
  exist, but their documentation was thin. None of the work below needed them.
- Apple sources: Tech Talks "Design for iPhone Duo" (developer.apple.com/videos/play/tech-talks/111466)
  and "Prepare your app for iPhone Duo" (…/111461); WWDC26 "Modernize your UIKit app" (session 278).

## 2. Replacing a custom tab bar with a native one

Apps with their own tab bar (X: `_TtC11XNavigation16TabBarController` / `…10TabBarView`) never get the
strip bar. The pattern that worked: lay a real `UITabBarController` over the app and let iOS place it.

1. **Host.** Create a `UITabBarController` and add it as a child of the **top view controller** of the
   chain that shows the app's bar (walk `nextResponder` to the outermost VC). Put its view inside a
   full-screen **pass-through view** whose `hitTest:` returns nil for everything except the bar: the
   view itself, the selected placeholder page, and the controller's containers around that page.
2. **Placeholder tabs.** Use one empty `UIViewController` per app tab, with a clear background, and
   copy each tab's icon (the app item's image, as template), title (its accessibility label) and badge
   (the first visible non-empty `UILabel` in the item). Keep `selectedIndex` in sync with the app's own.
3. **Selecting a tab** in the delegate's `shouldSelectViewController:` forwards a tap to the app's own
   tab item (section 3), then returns YES and reloads shortly after.
4. **Hide the app's bar, but keep it.** It's still needed as the tap target.
   - Hook its `setHidden:`. Record what the **app** asks for (mirror that onto your bar, e.g. to hide
     it for full-screen video), and return `hidden || replaced`.
   - Also hide it **synchronously in `didMoveToWindow`**. Apps create fresh bar instances (X does on
     the Grok tab), and an async-only update lets each one flash for a frame or two.
5. **Give back the bottom space.** Custom bars usually reserve room through `additionalSafeAreaInsets`
   on the tab children. Pinned content (X's Grok input) then stops short of the bottom. While the bar
   is in the strip, hook `UIViewController setAdditionalSafeAreaInsets:` for children of the app's tab
   container: store the app's value and zero `bottom`. Reapply the stored values when the layout
   switches back to horizontal.
6. **"Is the bar vertical right now?"** Don't ask `tabBar`, because the Duo strip bar isn't drawn by
   `tabBar`. A rule that matched device behaviour: the window is landscape, or portrait narrower than
   ~560pt (the outer screen), **and** `safeAreaInsets.right >= 44`. To locate the drawn bar, take the
   **largest** visible view of the tab controller inside the strip (minX ≥ window maxX − strip): that's
   the bar's background platter. Don't take the union of every view in the strip, because the
   selection highlight bulges out while it slides between tabs and anything aligned to the union
   jumps.
7. **Setting.** Keep a toggle back to the app's own bar, or a fallback, while iterating.

### Glass compose button on top of the rail

- Hide the app's floating compose button **together with its small wrapper**: the largest ancestor that
  is still about button-sized, ≤120pt, which holds the glass circle. Put a glass circle above the strip
  bar instead.
- Native spacing, measured from the Claude app's Duo rail: round glass buttons are **as wide as the
  rail**, on its centre line, with **~12pt gaps** (rail and circles 138–140px at 3x, gaps ~37px). The strip's centre isn't the
  bar's centre, and a union-of-views measurement makes it jump and grow during tab switches.
- Tapping it forwards to the app's current compose button: the newest one in the window that the app
  isn't hiding. Fall back to the app's URL scheme (X: `twitter://post`) when there's none.
- Glass on SDKs older than 26: `NSClassFromString(@"UIGlassEffect")` with `+effectWithStyle:0`, and call
  `setTintColor:` / `setInteractive:` through `objc_msgSend`. ARC rejects undeclared selectors.
- X's Liquid Glass "+" turned out to be an `XDSButton` (a UIControl, 48×48) labelled "Compose post".
  It's matched by that English label.

## 3. Forwarding taps into someone else's tab bar

Order that works, all in one synchronous call:

1. **Make the bar hit-testable but invisible.** Hidden views can't be hit-tested, and many handlers
   hit-test the bar at the touch point. Set `alpha = 0.02` (above UIKit's 0.01 hit-test cutoff), then
   `hidden = NO`, deliver the tap, and restore both. A full-opacity un-hide flashed the bar, because
   the app's tab-switch animation draws a frame mid-tap.
2. **UIControl.** On a `UIControl` (first one inside the target, then ancestors), send the first event
   it has actions for: PrimaryActionTriggered, then TouchUpInside, then TouchDown.
3. **Long press with a "track" action.** Replay began → changed → ended through a
   `UILongPressGestureRecognizer` subclass that overrides `state`, `view`, `locationInView:`,
   `numberOfTouches` and `locationOfTouch:inView:`. Glass tab bars select tabs this way, with a
   drag-between-tabs lens gesture (X: `handleTracking:`).
4. **Single-tap recognizers** (1 tap, 1 touch). Call their targets with a synthetic tap, reading
   targets/actions from the private `_targets` ivar (`_target` and `_action` on each entry).
   **Never** call actions named "secondary": `handleSecondaryClick:` is the context menu, which opened
   X's account switcher.
5. `accessibilityActivate` as a last resort.
6. **Verify.** About 0.6s later, check the app's selected index (X: Swift `selectedIndex` ivar, Int). If
   it didn't change, show a one-time alert with a Copy button. It should list how the tap was delivered
   and each view from item to bar with its recognizers, tap counts and action selectors. That alert
   pinned down X's gestures in one round.

## 4. Two-column (split) layout on the inner screen

- Split **on the window's centre line** (`midX` of the window, converted to the container), so the
  divider lines up with the hinge. A 55/45 split looked wrong on the device.
- The right column, and a single column too, **ends where the side strip begins**:
  `window.maxX − safeAreaInsets.right`. Nothing then sits under the status bar or tab bar, and the
  app's top bar and logo keep their normal layout (section 1).
- Only compute against the window when the requested width equals the current bounds. During rotation,
  fall back to half the width.
- Keep it to **two columns**. Cascading posts into extra columns was disorienting. Open the next item
  inside the right column instead.
- Back in the right column is a **right swipe** on the column, with no close button. Pan recognizer:
  - begin only for rightward-dominant velocity;
  - don't begin over horizontal scrollers that can still scroll back;
  - make vertical scroll views wait for it (`shouldBeRequiredToFailByGestureRecognizer:`);
  - drag the column with a transform;
  - on release past 30% or above 600pt/s, either pop inside the column or close it;
  - animate the column open and close with a **critically damped** spring (1.0). A bouncier spring,
    like X's 0.75, makes the remaining column visibly bounce as it re-lays out.
  - if the back swipe moves the column with a transform, lay it out with bounds/center, never
    `frame` (a mid-swipe layout offsets it by the translation and it jumps). When the swipe closes
    the column, hand off to the close spring from the finger's position, so the other column widens
    during the slide rather than snapping afterwards.
  - the host app usually re-lays a list out at the new width in one frame. Instead of animating
    the left column's frame, drive its width from the sliding column's presentation-layer edge with
    a CADisplayLink, so the app re-lays out every frame like a window resize. (A snapshot crossfade
    works but the ghosting is distracting.) Step the width (~8pt), call layoutIfNeeded right away,
    and re-anchor the top visible row's screen position after each step, or the list drifts.
  - when hiding a column until it's scrolled into place, reveal it only after a check that needed
    no correction, not on the first one; late padding or header rows otherwise make it jump.
- Opening at the first reply instead of a repeat of the post:
  - Keep the column invisible, or covered with a spinner (setting), until it's scrolled into place,
    then fade it in. A 2s safety timer always reveals it.
  - Scroll target: the reply sort row (a class containing "Sort", or the "View quotes" label), else the
    first reply cell below the focal post.
  - Re-apply for about 2.5s, because the app re-anchors while replies load. Stop on user scroll.

## 5. Hiding the "Post" bar and floating back buttons

- **Hide on appear, restore on leave.** In the detail page's `viewWillAppear`, store the nav bar's
  previous hidden state and hide it. In `viewWillDisappear`, restore it only if the new top isn't
  another such page.
- **Force it hidden.** Apps reveal the bar again on scroll-up and after loading, so hook
  `setNavigationBarHidden:animated:` on every navigation controller class they use (X: XNAV, T1Tab,
  TFN). Return YES while a managed page is on top.
- **The app's own header.** Glass designs often add a collapsing header of their own (title plus glass
  back button) on top of UINavigationBar. It shows at the top and on scroll-up, and hiding
  UINavigationBar doesn't touch it. Hook the title view class (X: `XNavigation.NavigationBarTitleView`)
  and hide its tallest bar-sized ancestor (≤160pt, stop at scroll views) while a managed page is on top.
  Hiding it leaves an empty strip, because the app still reserves room for it. Zero the top of
  `additionalSafeAreaInsets` for the page and its navigation controller, storing and reapplying the
  app's value, the same way as the tab bar's bottom inset.
- **The space the header leaves behind can come from three places.** All three applied in X:
  - the page's `additionalSafeAreaInsets.top`, often set **before** your code manages the page, so
    reapply from the current value when nothing is stored;
  - a scroll view padded by hand (`contentInsetAdjustmentBehavior == .never` with its own
    `contentInset.top`). Apps re-pad as content loads (X: 78, then 122), so hook the table's
    `setContentInset:` to cap the top at the safe area. A one-off trim loses. **Don't touch
    `contentOffset` in that hook or on layout.** Apps re-pad during scrolling (collapsing headers), and
    offset fixes there yank the user back up. Correct the offset once, on appear, when not tracking;
  - the header's own background view (X: `ChromeBackgroundView`), so hide it too.
- **Top fades.** Glass apps put a fade or blur along the top edge (X: `XDesignSystem.ScrollEdgeTreatment`)
  and iOS 26 adds `UIScrollView.topEdgeEffect`. Once the header is gone, both read as a band, so keep
  the top treatment at alpha 0 (hook `setAlpha:`) and hide `topEdgeEffect` at runtime.
- **Back buttons can come back.** A second floating back button may appear only after scrolling down.
  Hook the glass button class itself (X: `XDSButton`) and keep any one labelled "Back" hidden while a
  managed page is on top. A one-off view-tree scan misses it.
- **Floating back buttons.** Hide UIControls labelled "Back" (also UIKit's localized "Back") outside
  scroll views, **with their glass circle** (the largest ≤80pt ancestor). Hiding only the control
  leaves an empty circle that still catches taps. Un-hide everything when leaving.
- Add a right-swipe pop on those pages, because hiding the bar can disable UIKit's edge swipe.

## 6. Debugging on device

- **Once your own full-screen overlay exists** (the native tab host), FLEX "select" returns it
  (`BHTPassthroughView` → `UITabBarController` → `_UITabContainerView` → `SwiftUI._UIInheritedView`)
  wherever you tap. Use the views-list search, or build a debug report into the tweak. NFB:
  long-press the rail's compose button in Debug mode for insets, top-strip views and "Back" views.
- **FLEX** (bundled in NFB as Settings → Debug → "Debug mode", key `flex_twitter`):
  - "Select" on a floating button grabs whatever **full-screen layer** is on top (a hidden-looking
    overlay window, or your own pass-through view). Don't trust it for small floating controls.
  - Use the **views list's filter** to search by class or accessibility label (Compose, Float, Action,
    Fab, Back). That found X's real "+".
  - An object's **ⓘ** page shows its full class name, its nearest view controller and whether it's
    `hidden`.
- **Crash reports:** Settings → Privacy & Security → Analytics & Improvements → Analytics Data.
  Sideloaded apps in LiveContainer log as `LiveContainer…ips`. Read `exception`, `faultingThread`
  frames and `usedImages`.
  - Example: `EXC_BAD_ACCESS at 0x0 in objc_setAssociatedObject` means the object was nil. Guard every
    `objc_setAssociatedObject` whose object comes from a search or a timer.
- **Screen recordings:** make a contact sheet with
  `ffmpeg -i rec.mov -vf "fps=24/<duration>,scale=400:-1,tile=6x4" -frames:v 1 sheet.png` to spot
  one-frame flashes.
- **Can't test locally.** No iOS SDK in the cloud container, so CI is the compiler (`Build Tweak` on
  macOS runners):
  - It needs a direct link to a decrypted IPA (litterbox.catbox.moe works).
  - Runs cancelled with no steps after about 15 minutes mean no free macOS runner. Re-run; it isn't a
    code error.
  - Code using iOS 26+ APIs compiles against the 16.5 SDK when classes and selectors are looked up at
    runtime.

## 7. Checklist for a new app

1. Check the main binary's SDK (`vtool -show-build`). Below 27.1, the native bar won't go vertical.
2. FLEX: find the app's tab bar class, its item class, the selected-index ivar, the item's gesture
   recognizers and action names, its floating compose button, nav controller classes and the
   detail-page VC class.
3. Native tab host + pass-through view; mirror items; forward taps (section 3); hide the app's bar
   synchronously on appearance.
4. Bottom inset hook while vertical; compose button on the strip.
5. Split layout: hinge at window midX, end at the strip; swipe back; no extra columns.
6. Nav bar and back-button hiding on detail pages, forced through `setNavigationBarHidden:`.
7. Ship behind settings; keep one-time diagnostic alerts in until each forwarding path is proven.

## More lessons (X 12.46)

- Hidden header views can still steal taps: an app's view that overrides `hitTest:withEvent:` may
  answer even while hidden. Hook its hitTest to return nil when hidden; check with a debug report that
  hit-tests points at the top of the screen.
- Restore an app's hidden header/back buttons in the navigation transition's completion (skip if
  cancelled), and treat the transition's from-controller as still showing, or they flash over the
  outgoing screen.
- Don't host the native tab bar inside a view that slides (e.g. a side menu page): its safe area
  changes as it moves and iOS re-lays the bar out (horizontal or mid-screen). Keep it fixed, watch the
  sliding views with KVO (position/transform/bounds), and slide a snapshot instead. A child
  controller's view must sit in its parent controller's own view, or UIKit aborts.
