# Notes for Claude

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
- With the bar hidden on posts, X draws its own floating glass "Back" button. It's hidden while a post
  is showing (matched by accessibility label) and restored when leaving posts.
- To inspect class names on device: turn on the `flex_twitter` setting (bundled FLEX), then search
  runtime classes or use the view selector on the tab bar.

## Split view decisions

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
