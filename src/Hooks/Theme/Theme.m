#import "Theme.h"
#import "../HookHelpers.h"

@interface UIColor (BHTDynamicColorIdentifier)
- (id)tfn_dynamicColorIdentifier;
@end

// MARK: - Custom accent color

NSNumber* BHTSelectedThemeColor(void) {
    return [NSUserDefaults.standardUserDefaults objectForKey:@"bh_color_theme_selectedColor"];
}

static UIColor* selectedCustomThemeColor(void) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults integerForKey:@"bh_color_theme_selectedColor"] != -1) return nil;
    NSArray* components = [defaults arrayForKey:@"bh_color_theme_customColor"];
    if (components.count != 4) return nil;
    return [UIColor colorWithRed:[components[0] doubleValue]
                           green:[components[1] doubleValue]
                            blue:[components[2] doubleValue]
                           alpha:[components[3] doubleValue]];
}

NSInteger BHTNativeThemeOption(NSInteger option) {
    // -1 is our custom swatch, not a valid Twitter palette option.
    return option == -1 ? 0 : option;
}

static char BHTNativePrimaryColorKey;
static char BHTLastNativeAccentKey;
static __thread BOOL BHTMappingLoadedColor;
static __thread BOOL BHTMappingDynamicColor;

static UIColor* BHTReplaceNativeAccent(UIColor* color, UIColor* nativeAccent) {
    UIColor* custom = selectedCustomThemeColor();
    if (!custom || ![color isKindOfClass:UIColor.class] ||
        ![nativeAccent isKindOfClass:UIColor.class]) return color;

    UITraitCollection* traits = UITraitCollection.currentTraitCollection;
    UIColor* resolved = [color resolvedColorWithTraitCollection:traits];
    UIColor* native = [nativeAccent resolvedColorWithTraitCollection:traits];
    CGFloat r, g, b, a, nr, ng, nb, na;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a] ||
        ![native getRed:&nr green:&ng blue:&nb alpha:&na] ||
        fabs(r - nr) > 0.004 || fabs(g - ng) > 0.004 ||
        fabs(b - nb) > 0.004) return color;

    return [custom colorWithAlphaComponent:MIN(1.0, custom.CGColor ? CGColorGetAlpha(custom.CGColor) * a : a)];
}

// Every apply path (launch re-apply, trait changes, both settings pickers)
// funnels through this setter, so coercing here keeps the custom color pinned.

void applySelectedThemeColor(void) {
    NSNumber* selectedColor = BHTSelectedThemeColor();
    if (selectedColor) {
        [[objc_getClass("TAEColorSettings") sharedSettings]
            setPrimaryColorOption:BHTNativeThemeOption(selectedColor.integerValue)];
    }
}

// The native palette supplies most accent-colored controls via primaryColor.
// Keep the six preset getters intact so their picker swatches stay accurate.

static UIColor* BHTNativeAccentForCurrentPalette(void) {
    TAEColorSettings* settings = [objc_getClass("TAEColorSettings") sharedSettings];
    id info = settings.currentColorPalette;
    if (!info) return nil;
    UIColor* native = objc_getAssociatedObject(info, &BHTNativePrimaryColorKey);
    if (!native) {
        ((id (*)(id, SEL))objc_msgSend)(info, @selector(colorPalette));
        native = objc_getAssociatedObject(info, &BHTNativePrimaryColorKey);
    }
    return native;
}

static UIColor* BHTNativeAccentForLastPreset(void) {
    NSInteger option = [NSUserDefaults.standardUserDefaults
        integerForKey:@"bh_color_theme_lastNativeColorOption"];
    if (option < 1 || option > 6) return nil;
    TAEColorSettings* settings = [objc_getClass("TAEColorSettings") sharedSettings];
    id info = settings.currentColorPalette;
    if (!info) return nil;
    NSDictionary* cached = objc_getAssociatedObject(info, &BHTLastNativeAccentKey);
    if ([cached[@"option"] integerValue] == option) return cached[@"color"];
    id<TAEColorPalette> palette = ((id (*)(id, SEL))objc_msgSend)(info,
                                                                  @selector(colorPalette));
    UIColor* color = [palette primaryColorForOption:option];
    if (color) {
        objc_setAssociatedObject(info, &BHTLastNativeAccentKey, @{@"option": @(option),
                                                                  @"color": color},
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return color;
}

static UIColor* BHTReplaceKnownAccent(UIColor* color, UIColor* currentNative) {
    UIColor* mapped = BHTReplaceNativeAccent(color, currentNative);
    return mapped == color
               ? BHTReplaceNativeAccent(color, BHTNativeAccentForLastPreset())
               : mapped;
}

// Named palette colors are resolved by this loader, often from a cached
// preset. Replace colors that match the palette's native accent. The six
// preset swatches stay native because their option properties are excluded.

// Attributed strings and view setters resolve saved dynamic color identifiers
// through this manager, bypassing the named palette loader above.

// MARK: - Dim background recolor

@interface BHTDimGlassPlacement : NSObject
@property (nonatomic, weak) UIView* originalParent;
@property (nonatomic) NSUInteger originalIndex;
@property (nonatomic) UIViewAutoresizing originalAutoresizingMask;
@property (nonatomic, strong) UIView* toastTint;
@end
@implementation BHTDimGlassPlacement
@end

static char BHTDimGlassPlacementKey;

static UIView* ThemeAncestorOfClass(UIView* view, Class ancestorClass) {
    for (UIView* ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:ancestorClass]) return ancestor;
    }
    return nil;
}

static BOOL BHTDimGlassIsInContainer(UIView* glass, NSString* className) {
    return ThemeAncestorOfClass(glass, NSClassFromString(className)) != nil;
}

static BOOL BHTDimGlassContainsForeground(UIView* host) {
    Class buttonClass = NSClassFromString(@"TFNButton");
    NSMutableArray<UIView*>* pending = [host.subviews mutableCopy];
    while (pending.count) {
        UIView* view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:UILabel.class] || [view isKindOfClass:UIImageView.class] ||
            [view isKindOfClass:buttonClass]) return YES;
        [pending addObjectsFromArray:view.subviews];
    }
    return NO;
}

void BHTUpdateDimGlass(UIView* glass) {
    SEL selector = @selector(contentView);
    if (![glass respondsToSelector:selector]) return;
    UIView* host = ((id (*)(id, SEL))objc_msgSend)(glass, selector);
    if (![host isKindOfClass:UIView.class]) return;

    BHTDimGlassPlacement* placement = objc_getAssociatedObject(glass, &BHTDimGlassPlacementKey);
    BOOL toast = BHTDimGlassIsInContainer(glass, @"XDSToastContainerView");
    BOOL enabled = NFBLiquidGlassEnabled() && BHTDimThemeEnabled() &&
                   glass.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark &&
                   (toast || BHTDimGlassIsInContainer(glass, @"XDSButton") ||
                    BHTDimGlassContainsForeground(host));
    if (!enabled) {
        [placement.toastTint removeFromSuperview];
        UIView* parent = placement.originalParent;
        if (parent && host.superview == glass) {
            CGRect frame = [glass convertRect:host.frame toView:parent];
            [parent insertSubview:host atIndex:MIN(placement.originalIndex, parent.subviews.count)];
            host.frame = frame;
            host.autoresizingMask = placement.originalAutoresizingMask;
        }
        objc_setAssociatedObject(glass, &BHTDimGlassPlacementKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (!placement) {
        UIView* parent = host.superview;
        UIVisualEffectView* effect = [parent.superview isKindOfClass:UIVisualEffectView.class]
                                         ? (UIVisualEffectView*)parent.superview
                                         : nil;
        if (!effect || parent != effect.contentView ||
            ![effect.effect isKindOfClass:NSClassFromString(@"UIGlassEffect")] ||
            !host.translatesAutoresizingMaskIntoConstraints) return;
        for (NSLayoutConstraint* constraint in parent.constraints) {
            if (constraint.active && (constraint.firstItem == host || constraint.secondItem == host)) return;
        }
        placement = [BHTDimGlassPlacement new];
        placement.originalParent = parent;
        placement.originalIndex = [parent.subviews indexOfObjectIdenticalTo:host];
        placement.originalAutoresizingMask = host.autoresizingMask;
        CGRect frame = [parent convertRect:host.frame toView:glass];
        objc_setAssociatedObject(glass, &BHTDimGlassPlacementKey, placement,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [glass addSubview:host];
        host.frame = frame;
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }

    if (!toast && placement.toastTint.superview) {
        [placement.toastTint removeFromSuperview];
    } else if (toast && host.superview == glass) {
        if (!placement.toastTint) {
            UIView* tint = [[UIView alloc] initWithFrame:host.bounds];
            tint.userInteractionEnabled = NO;
            tint.isAccessibilityElement = NO;
            tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            tint.backgroundColor = [BHTDimElevatedBackgroundColor() colorWithAlphaComponent:0.75];
            placement.toastTint = tint;
        }
        if (placement.toastTint.superview != host) [host insertSubview:placement.toastTint atIndex:0];
        if (host.subviews.firstObject != placement.toastTint) [host sendSubviewToBack:placement.toastTint];
        placement.toastTint.frame = host.bounds;
    }
    if (host.superview == glass && glass.subviews.lastObject != host) [glass bringSubviewToFront:host];
}

BOOL BHTIsInsideScrollEdgeTreatment(UIView* view) {
    return ThemeAncestorOfClass(view, NSClassFromString(@"_TtC13XDesignSystem19ScrollEdgeTreatment")) != nil;
}

static UIColor* BHTDimScrollEdgeColor(UIColor* color, UITraitCollection* traits) {
    if (!BHTDimThemeEnabled() ||
        traits.userInterfaceStyle != UIUserInterfaceStyleDark ||
        ![color isKindOfClass:UIColor.class]) return nil;

    UIColor* resolved = [color resolvedColorWithTraitCollection:traits];
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![resolved getRed:&red green:&green blue:&blue alpha:&alpha] ||
        alpha <= 0.01 ||
        MAX(red, MAX(green, blue)) > 0.25 ||
        MAX(red, MAX(green, blue)) - MIN(red, MIN(green, blue)) > 0.04) return nil;
    return [BHTDimBackgroundColor() colorWithAlphaComponent:alpha];
}

static BOOL BHTIsScrollEdgeBlurTintView(UIView* view) {
    Class blurClass = NSClassFromString(@"XDSBlur");
    for (UIView* parent = view.superview; parent; parent = parent.superview) {
        if (![parent isKindOfClass:blurClass]) continue;
        Ivar tintField = class_getInstanceVariable(object_getClass(parent), "tintView");
        return tintField && object_getIvar(parent, tintField) == view &&
               BHTIsInsideScrollEdgeTreatment(parent);
    }
    return NO;
}

// A flat Dim color pinned in Dark can't follow a live switch back to Light, so
// remember the color it replaced. NSNull stands for a nil background.
static char BHTDimOriginalBackgroundKey;

static void BHTSaveDimOriginalBackground(UIView* view, UIColor* original) {
    objc_setAssociatedObject(view, &BHTDimOriginalBackgroundKey, original ?: (id)NSNull.null,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void BHTApplyScrollEdgeBlur(XDSBlur* blur) {
    if (!BHTIsInsideScrollEdgeTreatment(blur)) return;
    Ivar tintField = class_getInstanceVariable(object_getClass(blur), "tintView");
    UIView* tintView = tintField ? object_getIvar(blur, tintField) : nil;
    if (![tintView isKindOfClass:UIView.class]) return;
    UIColor* original = tintView.backgroundColor;
    UIColor* dim = BHTDimScrollEdgeColor(original, blur.traitCollection);
    if (dim) {
        tintView.backgroundColor = dim;
        BHTSaveDimOriginalBackground(tintView, original);
    }
}

// Reads the CGColor directly: going through UIColor resolution would hit the
// Dim hooks, which turn opaque black into a navy this filter rejects.
// Transparent stops are recolored too, since their RGB still shows along the fade.
static UIColor* BHTDimFadeGradientColor(CGColorRef color, UITraitCollection* traits) {
    if (!BHTDimThemeEnabled() || traits.userInterfaceStyle != UIUserInterfaceStyleDark) {
        return nil;
    }

    size_t count = CGColorGetNumberOfComponents(color);
    const CGFloat* components = CGColorGetComponents(color);
    if (!components || (count != 2 && count != 4)) return nil;

    CGFloat red = components[0];
    CGFloat green = count == 4 ? components[1] : red;
    CGFloat blue = count == 4 ? components[2] : red;
    CGFloat alpha = components[count - 1];
    CGFloat maxComponent = MAX(red, MAX(green, blue));
    if (maxComponent > 0.25 || maxComponent - MIN(red, MIN(green, blue)) > 0.04) return nil;
    return [BHTDimBackgroundColor() colorWithAlphaComponent:alpha];
}

static NSArray* BHTDimFadeGradientColors(NSArray* colors, UITraitCollection* traits) {
    NSMutableArray* mapped = [NSMutableArray arrayWithCapacity:colors.count];
    BOOL changed = NO;
    for (id entry in colors) {
        UIColor* dim = BHTDimFadeGradientColor((__bridge CGColorRef)entry, traits);
        [mapped addObject:dim ? (__bridge id)dim.CGColor : entry];
        changed |= dim != nil;
    }
    return changed ? mapped : colors;
}

static BOOL BHTIsDimFadeView(UIView* view) {
    // TFNGradientView also darkens media overlays, so only match the composer's
    // button bar, where it fades the scrolling buttons into the background.
    Class gradientClass = NSClassFromString(@"TFNGradientView");
    Class buttonBarClass = NSClassFromString(@"TFNButtonBarView");
    if (gradientClass && buttonBarClass && [view isKindOfClass:gradientClass] &&
        [view.superview isKindOfClass:buttonBarClass]) return YES;

    Class fadeClass = NSClassFromString(@"_TtC13XDesignSystem18ScrollEdgeFadeView");
    return fadeClass && [view isKindOfClass:fadeClass] && BHTIsInsideScrollEdgeTreatment(view);
}

void BHTApplyScrollEdgeFade(UIView* fade) {
    if (!BHTIsDimFadeView(fade) || !BHTDimThemeEnabled() ||
        fade.traitCollection.userInterfaceStyle != UIUserInterfaceStyleDark) return;

    Ivar gradientField = class_getInstanceVariable(object_getClass(fade), "gradientLayer");
    CAGradientLayer* gradient = gradientField ? object_getIvar(fade, gradientField)
                                              : (CAGradientLayer*)fade.layer;
    if (![gradient isKindOfClass:CAGradientLayer.class]) return;

    NSArray* colors = gradient.colors;
    if (!colors.count) return;
    NSArray* mapped = BHTDimFadeGradientColors(colors, fade.traitCollection);
    if (mapped != colors) gradient.colors = mapped;
}

NSArray* BHTThemeGradientColors(CAGradientLayer* layer, NSArray* colors) {
    // TFNGradientView is backed by the gradient layer itself.
    UIView* owner = [(id)layer.delegate isKindOfClass:NSClassFromString(@"TFNGradientView")]
                        ? (UIView*)layer.delegate
                        : (UIView*)layer.superlayer.delegate;
    if (![owner isKindOfClass:UIView.class] || !BHTIsDimFadeView(owner) ||
        !BHTDimThemeEnabled() ||
        owner.traitCollection.userInterfaceStyle != UIUserInterfaceStyleDark) {
        return colors;
    }
    return BHTDimFadeGradientColors(colors, owner.traitCollection);
}

void BHTApplyDimScrollEdgeChildren(UIView* treatment) {
    Class blurClass = NSClassFromString(@"XDSBlur");
    Class fadeClass = NSClassFromString(@"_TtC13XDesignSystem18ScrollEdgeFadeView");
    NSMutableArray<UIView*>* pending = [treatment.subviews mutableCopy];
    while (pending.count) {
        UIView* view = pending.lastObject;
        [pending removeLastObject];
        if (blurClass && [view isKindOfClass:blurClass]) {
            BHTApplyScrollEdgeBlur((XDSBlur*)view);
        } else if (fadeClass && [view isKindOfClass:fadeClass]) {
            BHTApplyScrollEdgeFade(view);
        }
        [pending addObjectsFromArray:view.subviews];
    }
}

// Set once the Dim palette has been handed out, so the restore paths know
// there may be Dim colors to undo even after the setting is turned off.
static BOOL BHTDimHasRendered;
static char BHTDimProxyKey;

static BOOL BHTColorIsDimShade(UIColor* color) {
    return BHTDimShadeOfColor(color) != BHTDimShadeNone;
}

// TFNButton keeps its own background color per state and never passes an
// assigned color to UIView: it stores it as the normal, highlighted and
// disabled colors, then reapplies them whenever the palette reloads. Its
// colors already come from the palette, so Dim reaches it through the proxy;
// recoloring it here would replace the button's own colors for good.
static BOOL BHTDimLeavesBackgroundAlone(UIView* view) {
    static Class buttonClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        buttonClass = NSClassFromString(@"TFNButton");
    });
    return buttonClass && [view isKindOfClass:buttonClass];
}

static UIColor* BHTDimNormalizedBackground(UIView* view, UIColor* color,
                                           UITraitCollection* traits) {
    if (!view || !color || !BHTDimThemeEnabled() ||
        traits.userInterfaceStyle != UIUserInterfaceStyleDark) {
        return color;
    }

    if (BHTIsScrollEdgeBlurTintView(view)) {
        UIColor* dimTint = BHTDimScrollEdgeColor(color, traits);
        if (dimTint) return dimTint;
    }

    UIColor* resolved = [color resolvedColorWithTraitCollection:traits];
    UIColor* replacement = BHTDimReplacementForResolvedColor(resolved);
    if (replacement) {
        return BHTDimColorPreservingIdentifier(replacement, color);
    }

    // The UIColor hooks may already have resolved a catalog background to a
    // Dim shade. Pin that resolved value on the view so later reuse cannot
    // fall back to the catalog's original pure-black dark variant.
    if (BHTColorIsDimShade(resolved)) {
        return resolved;
    }

    return color;
}

static UIColor* BHTCurrentPaletteColorForDimShade(BHTDimShadeKind shade);

// When the app is not rendering Dim -- Light, or Dark with Dim turned off --
// returns the palette color that stands in for a Dim shade; nil otherwise.
// The app switches its palette before every view reports the new appearance
// (thread replies still on screen can claim Dark once the app is Light), so
// this asks the palette, not the view. It runs on hot paths, so it answers from
// the palette's isDark flag: reading the Dark palette would build a Dim proxy
// on every call just to say no.
static UIColor* BHTPaletteReplacementForDimShade(UIColor* color) {
    BHTDimShadeKind shade = BHTDimShadeOfColor(color);
    if (shade == BHTDimShadeNone) return nil;
    TAETwitterColorPaletteSettingInfo* info =
        [[objc_getClass("TAEColorSettings") sharedSettings] currentColorPalette];
    if (!info || (info.isDark && BHTDimThemeEnabled())) return nil;
    return BHTCurrentPaletteColorForDimShade(shade);
}

// A dynamic color reads as whatever the current appearance resolves it to, so
// a Dim reading alone doesn't make it flat: it must be Dim in Light as well.
static BOOL BHTColorIsFlatDimShade(UIColor* color) {
    static UITraitCollection* light;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        light = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    });
    return BHTColorIsDimShade(color) &&
           BHTColorIsDimShade([color resolvedColorWithTraitCollection:light]);
}

static UIColor* BHTPaletteReloadedColor(UIColor* color);

// X reloads a view's palette colors only when its traits change, and a Dim
// toggle leaves the traits where they were, so views off screen at the time
// (another tab's list, cells waiting for reuse) would keep the old colors.
// Each toggle starts a new generation; a view from an older one has its
// background re-read from the palette when it is next refreshed.
static NSUInteger BHTDimGeneration;
static char BHTDimSeenGenerationKey;

static BOOL BHTDimMarkSeen(UIView* view) {
    if (!BHTDimGeneration) return NO;
    NSNumber* seen = objc_getAssociatedObject(view, &BHTDimSeenGenerationKey);
    if (seen.unsignedIntegerValue == BHTDimGeneration) return NO;
    objc_setAssociatedObject(view, &BHTDimSeenGenerationKey, @(BHTDimGeneration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Brings one view's background in line with the app's appearance: applies Dim
// while the app renders it, and otherwise puts back the color Dim replaced.
// Some surfaces, such as thread replies, hold a flat copy of the Dim color with
// nothing saved; they get the palette's color, whose identifier lets the app
// handle later switches. Views off screen during a switch (another tab's list)
// are caught here when they come back into a window.
// `traits` stands in for the view's own: during a switch a view can still
// report the previous appearance while the palette has already moved on.
static void BHTRefreshDimBackgroundAs(UIView* view, UITraitCollection* traits) {
    // Until Dim has rendered in this process, there is nothing to undo.
    if (!BHTDimThemeEnabled() && !BHTDimHasRendered) return;
    if (BHTDimLeavesBackgroundAlone(view)) return;

    if (BHTDimMarkSeen(view)) {
        // A palette color from before the toggle: the setter hook then
        // applies or skips Dim for the reloaded value.
        UIColor* reloaded = BHTPaletteReloadedColor(view.backgroundColor);
        if (reloaded) view.backgroundColor = reloaded;
    }

    UIColor* current = view.backgroundColor;
    if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
        UIColor* normalized = current ? BHTDimNormalizedBackground(view, current, traits) : nil;
        if (!BHTPaletteReplacementForDimShade(normalized)) {
            if (normalized != current) {
                // Assign the converted color itself: the setter hook would
                // normalize with the view's own traits, not with `traits`.
                if (!BHTColorIsFlatDimShade(current)) BHTSaveDimOriginalBackground(view, current);
                view.backgroundColor = normalized;
            }
            return;
        }
    }

    id saved = objc_getAssociatedObject(view, &BHTDimOriginalBackgroundKey);
    if (saved) {
        view.backgroundColor = [saved isKindOfClass:UIColor.class] ? saved : nil;
        objc_setAssociatedObject(view, &BHTDimOriginalBackgroundKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // During a switch the palette can still be the previous one; the delayed
    // refresh retries once it has settled. Only a flat copy of a Dim shade is
    // replaced: resolving with Dark traits would run any near-black color, such
    // as the Follow button's fill in Light, through Dim's own conversion.
    if (!BHTColorIsFlatDimShade(current)) return;
    UIColor* replacement = BHTPaletteReplacementForDimShade(current);
    if (replacement) view.backgroundColor = replacement;
}

// The palette is the authority in both directions. Once the app renders Dim,
// every view is refreshed as Dark, whatever it reports itself: a view entering
// a window, or a cell prepared off screen, can still carry Light or no traits.
// Mirrors the Light handling in BHTPaletteReplacementForDimShade.
static UITraitCollection* BHTDimAuthorityTraits(void) {
    if (!BHTDimThemeEnabled()) return nil;
    TAETwitterColorPaletteSettingInfo* info =
        [[objc_getClass("TAEColorSettings") sharedSettings] currentColorPalette];
    if (!info.isDark) return nil;
    static UITraitCollection* dark;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dark = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
    });
    return dark;
}

void BHTRefreshDimBackground(UIView* view) {
    BHTRefreshDimBackgroundAs(view, BHTDimAuthorityTraits() ?: view.traitCollection);
}

// X sometimes assigns backgroundPrimary (or a literal black color) to a view
// after the palette has already been resolved, which the palette proxy and the
// UIColor resolution hooks never see.
UIColor* BHTThemeViewBackground(UIView* view, UIColor* color) {
    // Nothing to apply or undo until Dim has rendered in this process.
    if ((!BHTDimThemeEnabled() && !BHTDimHasRendered) || BHTDimLeavesBackgroundAlone(view)) {
        return color;
    }
    UIColor* normalized = BHTDimNormalizedBackground(view, color, view.traitCollection);
    // The app is not rendering Dim, or the view still reports Dark after the
    // switch: a flat Dim color takes the palette's color, any other stays as
    // assigned. Reading a dynamic color's components resolves it with the
    // current traits, still Dark during a switch, which would run a near-black
    // color such as the Follow button's Light fill through Dim's conversion.
    UIColor* replacement = BHTPaletteReplacementForDimShade(normalized);
    if (replacement) normalized = BHTColorIsFlatDimShade(color) ? replacement : color;
    if (normalized != color) {
        // A color that's already Dim has nothing worth restoring in Light; a
        // dynamic one does, since it adapts to Light on its own.
        if (!BHTColorIsFlatDimShade(color)) {
            BHTSaveDimOriginalBackground(view, color);
        }
    } else if (objc_getAssociatedObject(view, &BHTDimOriginalBackgroundKey) &&
               !BHTColorIsFlatDimShade(color)) {
        // The app assigned a new color of its own, which supersedes the saved one.
        objc_setAssociatedObject(view, &BHTDimOriginalBackgroundKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return normalized;
}

static char BHTDimHidSolidColorViewKey;

// Dim only recolors Dark, so these views are hidden in Dark alone. The flag
// records which ones Dim hid, so views the app hid itself stay hidden in Light.
void BHTApplyDimSolidColorView(UIView* view) {
    if (BHTDimThemeEnabled() &&
        view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        if (!view.hidden) {
            objc_setAssociatedObject(view, &BHTDimHidSolidColorViewKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.hidden = YES;
        }
    } else if (objc_getAssociatedObject(view, &BHTDimHidSolidColorViewKey)) {
        objc_setAssociatedObject(view, &BHTDimHidSolidColorViewKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = NO;
    }
}

UIImage* BHTDimSearchPillImage(void) {
    static UIImage* image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const CGFloat diameter = 44.0;
        UIGraphicsImageRenderer* renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter, diameter)];
        UIImage* base = [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
            [BHTDimSearchPillColor() setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, diameter, diameter)
                                        cornerRadius:diameter / 2.0] fill];
        }];
        image = [base resizableImageWithCapInsets:UIEdgeInsetsMake(diameter / 2.0,
                                                                   diameter / 2.0,
                                                                   diameter / 2.0,
                                                                   diameter / 2.0)
                                     resizingMode:UIImageResizingModeStretch];
    });
    return image;
}

static char BHTDimSearchPillAppliedKey;

void BHTApplyDimSearchPill(UISearchBar* searchBar) {
    if (BHTDimThemeEnabled() &&
        searchBar.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        objc_setAssociatedObject(searchBar, &BHTDimSearchPillAppliedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [searchBar setSearchFieldBackgroundImage:BHTDimSearchPillImage()
                                        forState:UIControlStateNormal];
    } else if (objc_getAssociatedObject(searchBar, &BHTDimSearchPillAppliedKey)) {
        objc_setAssociatedObject(searchBar, &BHTDimSearchPillAppliedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [searchBar setSearchFieldBackgroundImage:nil forState:UIControlStateNormal];
    }
}

BOOL BHTIsExploreSearchBackgroundView(UIView* view) {
    return ThemeAncestorOfClass(view, objc_getClass("TFNSearchBar")) != nil;
}

@protocol BHTDimTextPalette <NSObject>
- (UIColor*)textColor;
- (UIColor*)textDetailsColor;
- (UIColor*)dynamicColorWithIdentifier:(id)identifier;
- (UIColor*)backgroundColor;
- (UIColor*)elevatedBackgroundColor;
- (UIColor*)highlightBackgroundColor;
@end

@interface _TtC10TFNUISwift25LegacySegmentedTabBarView (BHTDimRefresh)
- (void)reloadVisibleTabs;
@end

static UIColor* BHTCurrentPaletteColor(id<BHTDimTextPalette> palette, UIColor* color,
                                       UIColor* fallback) {
    id identifier = [color respondsToSelector:@selector(tfn_dynamicColorIdentifier)]
                        ? [color tfn_dynamicColorIdentifier]
                        : nil;
    UIColor* reloaded = identifier && [palette respondsToSelector:@selector(dynamicColorWithIdentifier:)]
                            ? [palette dynamicColorWithIdentifier:identifier]
                            : nil;
    return reloaded ?: fallback;
}

static id<BHTDimTextPalette> BHTCurrentTextPalette(void) {
    id info = [[objc_getClass("TAEColorSettings") sharedSettings] currentColorPalette];
    return info ? ((id (*)(id, SEL))objc_msgSend)(info, @selector(colorPalette)) : nil;
}

// The palette's current value for a color carrying a dynamic color identifier,
// nil for any other color.
static UIColor* BHTPaletteReloadedColor(UIColor* color) {
    return BHTCurrentPaletteColor(BHTCurrentTextPalette(), color, nil);
}

static UIColor* BHTCurrentPaletteColorForDimShade(BHTDimShadeKind shade) {
    id<BHTDimTextPalette> palette = BHTCurrentTextPalette();
    switch (shade) {
        case BHTDimShadeElevated:
            return palette.elevatedBackgroundColor;
        case BHTDimShadeHighlight:
            return palette.highlightBackgroundColor;
        default:
            return palette.backgroundColor;
    }
}

// X's tab customization screen leaves its disabled Save button nearly invisible
// on the Dim background, so give the disabled state the secondary text color.
void BHTApplyDisabledBarButtonTextColor(UIViewController* controller) {
    UIColor* disabledColor = BHTDimThemeEnabled() ? BHTCurrentTextPalette().textDetailsColor : nil;
    if (!disabledColor) return;

    for (UIBarButtonItem* item in controller.navigationItem.rightBarButtonItems) {
        if (![[item titleTextAttributesForState:UIControlStateDisabled]
                    [NSForegroundColorAttributeName] isEqual:disabledColor]) {
            [item setTitleTextAttributes:@{NSForegroundColorAttributeName: disabledColor}
                                forState:UIControlStateDisabled];
        }
        if ([item.customView isKindOfClass:UIButton.class]) {
            UIButton* button = (UIButton*)item.customView;
            if (![[button titleColorForState:UIControlStateDisabled] isEqual:disabledColor]) {
                [button setTitleColor:disabledColor forState:UIControlStateDisabled];
            }
        }
    }
}

static char BHTSegmentedTabBarAppearanceKey;

// The tab bar's style holds its title colors from when it was built, so they
// have to be fetched again from the new palette after an appearance change.
void BHTRefreshSegmentedTabBarColors(_TtC10TFNUISwift25LegacySegmentedTabBarView* tabBar) {
    if (!BHTDimThemeEnabled() && !BHTDimHasRendered) return;

    NSNumber* current = @(tabBar.traitCollection.userInterfaceStyle);
    NSNumber* previous = objc_getAssociatedObject(tabBar, &BHTSegmentedTabBarAppearanceKey);
    if ([previous isEqualToNumber:current]) return;
    objc_setAssociatedObject(tabBar, &BHTSegmentedTabBarAppearanceKey, current,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!previous) return;

    _TtC10TFNUISwift26LegacySegmentedTabBarStyle* style = tabBar.style;
    id<BHTDimTextPalette> palette = BHTCurrentTextPalette();
    if (!style || !palette) return;

    style.selectedTextColor =
        BHTCurrentPaletteColor(palette, style.selectedTextColor, palette.textColor);
    style.deselectedTextColor =
        BHTCurrentPaletteColor(palette, style.deselectedTextColor, palette.textDetailsColor);
    tabBar.style = style;
    // Private, so another X build may not have it; then the tabs pick the new
    // colors up on their next layout instead.
    if ([tabBar respondsToSelector:@selector(reloadVisibleTabs)]) {
        [tabBar reloadVisibleTabs];
    }
}

void BHTApplyDimBarBackground(UIView* bar) {
    if (!BHTDimThemeEnabled() || NFBLiquidGlassEnabled() ||
        bar.traitCollection.userInterfaceStyle != UIUserInterfaceStyleDark) {
        return;
    }
    UIColor* original = bar.backgroundColor;
    if (BHTColorIsDimShade(original)) return;
    bar.backgroundColor = BHTDimBackgroundColor();
    BHTSaveDimOriginalBackground(bar, original);
}

// MARK: - Live appearance changes

static void BHTRefreshDimView(UIView* view, UITraitCollection* traits) {
    static Class barClass, solidClass, searchBarClass, blurClass, fadeClass, tabBarClass,
        gradientClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        barClass = NSClassFromString(@"_UIBarBackground");
        solidClass = NSClassFromString(@"TFNSolidColorView");
        searchBarClass = NSClassFromString(@"TFNSearchBar");
        blurClass = NSClassFromString(@"XDSBlur");
        fadeClass = NSClassFromString(@"_TtC13XDesignSystem18ScrollEdgeFadeView");
        tabBarClass = NSClassFromString(@"_TtC10TFNUISwift25LegacySegmentedTabBarView");
        gradientClass = NSClassFromString(@"TFNGradientView");
    });

    BHTRefreshDimBackgroundAs(view, traits ?: view.traitCollection);
    if (barClass && [view isKindOfClass:barClass]) {
        BHTApplyDimBarBackground(view);
    } else if (solidClass && [view isKindOfClass:solidClass]) {
        BHTApplyDimSolidColorView(view);
    } else if (searchBarClass && [view isKindOfClass:searchBarClass]) {
        BHTApplyDimSearchPill((UISearchBar*)view);
    } else if (blurClass && [view isKindOfClass:blurClass]) {
        BHTApplyScrollEdgeBlur((XDSBlur*)view);
    } else if ((fadeClass && [view isKindOfClass:fadeClass]) ||
               (gradientClass && [view isKindOfClass:gradientClass])) {
        BHTApplyScrollEdgeFade(view);
    } else if (tabBarClass && [view isKindOfClass:tabBarClass]) {
        BHTRefreshSegmentedTabBarColors((_TtC10TFNUISwift25LegacySegmentedTabBarView*)view);
    }
}

static void BHTRefreshDimInView(UIView* root, UITraitCollection* traits) {
    NSMutableArray<UIView*>* pending = [NSMutableArray arrayWithObject:root];
    while (pending.count) {
        UIView* view = pending.lastObject;
        [pending removeLastObject];
        BHTRefreshDimView(view, traits);
        [pending addObjectsFromArray:view.subviews];
    }
}

static void BHTRefreshDimInWindows(void) {
    UITraitCollection* traits = BHTDimAuthorityTraits();
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            BHTRefreshDimInView(window, traits);
        }
    }
}

// The app reloads its colors as part of the switch, and views can still report
// the previous appearance at that point, so the setter hooks let them through.
// Refresh once the switch has settled; the delayed pass covers animated ones.
void BHTScheduleDimRefresh(void) {
    static BOOL scheduled = NO;
    // Keep running after Dim is turned off: the last leg of the round trip
    // back to Dark still has the Light pass's work to undo.
    if (scheduled || (!BHTDimThemeEnabled() && !BHTDimHasRendered)) return;
    scheduled = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        BHTRefreshDimInWindows();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       scheduled = NO;
                       BHTRefreshDimInWindows();
                   });
}

// Dim is applied on the way into Dark and undone on the way into Light, so a
// setting change while the app is Dark takes a round trip through Light: the
// same path a system appearance switch takes, instead of a third one of its
// own. Forcing Light on the windows moves the traits; the palette follows
// through X's trait handler when its theme is System, and is switched here
// directly when the theme is pinned to Dark. The setting stays on through the
// Light pass so that pass restores what Dim changed; the value written at the
// end is the last one asked for, so flipping the switch again mid-trip is safe.
static BOOL BHTDimRequestedEnabled;
static BOOL BHTDimRoundTripInFlight;

void BHTDimSettingDidChange(BOOL enabled) {
    BHTDimRequestedEnabled = enabled;
    if (BHTDimRoundTripInFlight) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"enable_dim_theme"];
        return;
    }

    TAETwitterColorPaletteSettingInfo* info =
        [[objc_getClass("TAEColorSettings") sharedSettings] currentColorPalette];
    if (!info.isDark) return; // Dim is picked on the way into Dark.

    BHTDimRoundTripInFlight = YES;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"enable_dim_theme"];

    NSMutableArray<UIWindow*>* windows = [NSMutableArray array];
    NSMutableArray<NSNumber*>* styles = [NSMutableArray array];
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            [windows addObject:window];
            [styles addObject:@(window.overrideUserInterfaceStyle)];
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        }
    }
    [objc_getClass("T1ColorSettings") transitionToDarkMode:NO animated:NO];
    BHTScheduleDimRefresh();

    // Past the delayed refresh pass, so the Light pass has finished its work.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       BHTDimRoundTripInFlight = NO;
                       [NSUserDefaults.standardUserDefaults setBool:BHTDimRequestedEnabled
                                                             forKey:@"enable_dim_theme"];
                       [windows enumerateObjectsUsingBlock:^(UIWindow* window, NSUInteger index,
                                                             BOOL* stop) {
                           window.overrideUserInterfaceStyle = styles[index].integerValue;
                       }];
                       UIWindow* keyWindow = windows.firstObject;
                       for (UIWindow* window in windows) {
                           if (window.isKeyWindow) keyWindow = window;
                       }
                       BOOL dark = keyWindow.traitCollection.userInterfaceStyle ==
                                   UIUserInterfaceStyleDark;
                       [objc_getClass("T1ColorSettings") transitionToDarkMode:dark animated:NO];
                       BHTDimGeneration++;
                       BHTScheduleDimRefresh();
                   });
}

// MARK: - Tab bar icon and label theming

static char BHTGlassTabOriginalTintKey;
static char BHTGlassTabLabelKey;
static char BHTGlassTabOverlayKey;

static UILabel* BHTCreateTabLabel(void) {
    UILabel* label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont systemFontOfSize:9.0 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.isAccessibilityElement = NO;
    label.userInteractionEnabled = NO;
    return label;
}

static void BHTCollectGlassTabItems(UIView* view, Class itemClass,
                                    NSMutableArray<UIView*>* items) {
    for (UIView* subview in view.subviews) {
        if ([subview isKindOfClass:itemClass]) {
            [items addObject:subview];
        } else {
            BHTCollectGlassTabItems(subview, itemClass, items);
        }
    }
}

static NSString* BHTGlassTabItemTitle(UIView* item, UIView* bar) {
    // Reuse the accessibility label
    for (UIView* view = item; view && view != bar; view = view.superview) {
        NSString* title = view.accessibilityLabel;
        if (title.length) return title;
    }
    return nil;
}

void BHTLayoutGlassTabItem(UIView* item) {
    UILabel* label = objc_getAssociatedObject(item, &BHTGlassTabLabelKey);
    if (!label) return;

    BOOL showLabel = [BHTSettings boolForKey:@"restore_tab_labels"] && label.text.length;
    CGFloat height = CGRectGetHeight(item.bounds);
    CGFloat width = CGRectGetWidth(item.bounds);
    UIView* overlay = label.superview;
    if (overlay.superview && [item isDescendantOfView:overlay.superview]) {
        CGRect frame = CGRectMake(-6.0, height - 13.0, width + 12.0, 11.0);
        label.frame = [item convertRect:frame toView:overlay];
    } else {
        showLabel = NO;
    }
    label.hidden = !showLabel;

    Ivar imageField = class_getInstanceVariable(object_getClass(item), "imageView");
    UIImageView* imageView = imageField ? object_getIvar(item, imageField) : nil;
    if (![imageView isKindOfClass:UIImageView.class]) return;

    UIView* glyph = imageView.superview == item ? imageView : imageView.superview;
    if (glyph.superview != item) return;
    glyph.center = CGPointMake(width / 2.0,
                               height / 2.0 - (showLabel && height >= 34.0 ? 5.0 : 0.0));
}

// The bar's tab items in visual order (leading to trailing).
static NSArray<UIView*>* BHTSortedGlassTabItems(UIView* bar) {
    Class itemClass = NSClassFromString(@"_TtC11XNavigation14TabBarItemView");
    if (!itemClass) return @[];

    Ivar rowField = class_getInstanceVariable(object_getClass(bar), "itemRow");
    UIView* row = rowField ? object_getIvar(bar, rowField) : nil;
    UIView* container = [row isKindOfClass:UIView.class] ? row : bar;
    NSMutableArray<UIView*>* items = [NSMutableArray new];
    BHTCollectGlassTabItems(container, itemClass, items);
    [items sortUsingComparator:^NSComparisonResult(UIView* first, UIView* second) {
        CGFloat firstX = CGRectGetMidX([first convertRect:first.bounds toView:bar]);
        CGFloat secondX = CGRectGetMidX([second convertRect:second.bounds toView:bar]);
        return firstX < secondX ? NSOrderedAscending
                                : (firstX > secondX ? NSOrderedDescending : NSOrderedSame);
    }];
    return items;
}

static NSInteger BHTGlassTabSelectedIndex(UIView* bar) {
    Ivar selectedField = class_getInstanceVariable(object_getClass(bar), "selectedIndex");
    // Swift.Int is pointer-sized on this arm64-only target.
    return selectedField ? *(NSInteger*)((uint8_t*)(__bridge void*)bar + ivar_getOffset(selectedField))
                         : NSNotFound;
}

void BHTApplyGlassTabLabels(UIView* bar) {
    NSArray<UIView*>* items = BHTSortedGlassTabItems(bar);
    if (!items.count) return;
    NSInteger selectedIndex = BHTGlassTabSelectedIndex(bar);

    BOOL enabled = [BHTSettings boolForKey:@"restore_tab_labels"];
    UIView* overlay = objc_getAssociatedObject(bar, &BHTGlassTabOverlayKey);
    if (!overlay && enabled) {
        overlay = [[UIView alloc] initWithFrame:bar.bounds];
        overlay.userInteractionEnabled = NO;
        overlay.clipsToBounds = NO;
        objc_setAssociatedObject(bar, &BHTGlassTabOverlayKey, overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (overlay && enabled) {
        // The selection pill can cover itemRow; render text above that sibling.
        if (overlay.superview != bar) [bar addSubview:overlay];
        overlay.frame = bar.bounds;
        if (bar.subviews.lastObject != overlay) [bar bringSubviewToFront:overlay];
    }

    NSMutableSet<UIView*>* activeLabels = [NSMutableSet new];
    for (NSUInteger index = 0; index < items.count; index++) {
        UIView* item = items[index];
        UILabel* label = objc_getAssociatedObject(item, &BHTGlassTabLabelKey);
        NSString* title = enabled ? BHTGlassTabItemTitle(item, bar) : nil;
        if (!label && title.length) {
            label = BHTCreateTabLabel();
            objc_setAssociatedObject(item, &BHTGlassTabLabelKey, label,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!label) continue;
        label.text = title;
        label.textColor = (NSInteger)index == selectedIndex
                              ? (CurrentAccentColor() ?: [UIColor labelColor])
                              : [UIColor secondaryLabelColor];
        if (enabled && title.length) {
            if (label.superview != overlay) [overlay addSubview:label];
            [activeLabels addObject:label];
        }
        BHTLayoutGlassTabItem(item);
    }
    for (UIView* subview in [overlay.subviews copy]) {
        if (![activeLabels containsObject:subview]) [subview removeFromSuperview];
    }
    if (!enabled) [overlay removeFromSuperview];
}

// MARK: - Vertical tab rail (unfolded / wide windows)

// X's glass bar is hidden on wide windows and this native rail stands in for
// it on the right edge. Each button forwards its tap to X's own tab item, so X
// keeps owning selection, tab customization and navigation.

@interface BHTSyntheticTap : UITapGestureRecognizer
@property (nonatomic, weak) UIView* realView;
@property (nonatomic) CGPoint windowPoint;
@end

@implementation BHTSyntheticTap
- (UIView*)view {
    return self.realView;
}
- (UIGestureRecognizerState)state {
    return UIGestureRecognizerStateEnded;
}
- (NSUInteger)numberOfTouches {
    return 1;
}
- (CGPoint)locationInView:(UIView*)view {
    return view ? [view convertPoint:self.windowPoint fromView:nil] : self.windowPoint;
}
- (CGPoint)locationOfTouch:(NSUInteger)index inView:(UIView*)view {
    return [self locationInView:view];
}
@end

// A press-and-release as X's tab bar sees it: its tab selection is a
// "tracking" long press (the drag-between-tabs gesture), not a tap.
@interface BHTSyntheticPress : UILongPressGestureRecognizer
@property (nonatomic, weak) UIView* realView;
@property (nonatomic) CGPoint windowPoint;
@property (nonatomic) UIGestureRecognizerState fakeState;
@end

@implementation BHTSyntheticPress
- (UIView*)view {
    return self.realView;
}
- (UIGestureRecognizerState)state {
    return self.fakeState;
}
- (NSUInteger)numberOfTouches {
    return 1;
}
- (CGPoint)locationInView:(UIView*)view {
    return view ? [view convertPoint:self.windowPoint fromView:nil] : self.windowPoint;
}
- (CGPoint)locationOfTouch:(NSUInteger)index inView:(UIView*)view {
    return [self locationInView:view];
}
@end

// Calls `block` with each target/action a recognizer would send to.
static void BHTEachGestureTarget(UIGestureRecognizer* recognizer, void (^block)(id target, SEL action)) {
    Ivar targetsField = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
    NSArray* targets = targetsField ? object_getIvar(recognizer, targetsField) : nil;
    if (![targets isKindOfClass:NSArray.class]) return;
    for (id entry in targets) {
        Ivar targetField = class_getInstanceVariable(object_getClass(entry), "_target");
        Ivar actionField = class_getInstanceVariable(object_getClass(entry), "_action");
        if (!targetField || !actionField) continue;
        id target = object_getIvar(entry, targetField);
        SEL action = *(SEL*)((uint8_t*)(__bridge void*)entry + ivar_getOffset(actionField));
        if (target && action && [target respondsToSelector:action]) block(target, action);
    }
}

// Context-menu style actions ("secondary click") must never stand in for a tap.
static BOOL BHTIsSecondaryAction(SEL action) {
    return [NSStringFromSelector(action) rangeOfString:@"secondary" options:NSCaseInsensitiveSearch].location !=
           NSNotFound;
}

// Calls a tap recognizer's own target/actions with a synthetic tap at `point`.
static BOOL BHTInvokeTapTargets(UITapGestureRecognizer* recognizer, CGPoint point) {
    BHTSyntheticTap* tap = [[BHTSyntheticTap alloc] initWithTarget:nil action:nil];
    tap.realView = recognizer.view;
    tap.windowPoint = point;
    __block BOOL invoked = NO;
    BHTEachGestureTarget(recognizer, ^(id target, SEL action) {
        if (BHTIsSecondaryAction(action)) return;
        ((void (*)(id, SEL, id))objc_msgSend)(target, action, tap);
        invoked = YES;
    });
    return invoked;
}

// Replays a press at `point` (began, changed, ended) on a long press whose
// action tracks touches, which is how X's bar picks the tab under a finger.
static BOOL BHTInvokeTrackingPress(UILongPressGestureRecognizer* recognizer, CGPoint point) {
    BHTSyntheticPress* press = [[BHTSyntheticPress alloc] initWithTarget:nil action:nil];
    press.realView = recognizer.view;
    press.windowPoint = point;
    __block BOOL invoked = NO;
    BHTEachGestureTarget(recognizer, ^(id target, SEL action) {
        if ([NSStringFromSelector(action) rangeOfString:@"track" options:NSCaseInsensitiveSearch].location ==
            NSNotFound) return;
        for (NSNumber* state in @[@(UIGestureRecognizerStateBegan), @(UIGestureRecognizerStateChanged),
                                  @(UIGestureRecognizerStateEnded)]) {
            press.fakeState = state.integerValue;
            ((void (*)(id, SEL, id))objc_msgSend)(target, action, press);
        }
        invoked = YES;
    });
    return invoked;
}

// Set while a replaced (hidden) X view is shown for the length of one
// forwarded tap: hidden views drop out of hit-testing, which X's handlers use.
static BOOL BHTShowingForTap;

static NSString* BHTControlTap(UIControl* control) {
    UIControlEvents events = control.allControlEvents;
    for (NSNumber* event in @[@(UIControlEventPrimaryActionTriggered), @(UIControlEventTouchUpInside),
                              @(UIControlEventTouchDown)]) {
        if (events & event.unsignedIntegerValue) {
            [control sendActionsForControlEvents:event.unsignedIntegerValue];
            return [NSString stringWithFormat:@"control %@", NSStringFromClass(control.class)];
        }
    }
    return nil;
}

static UIControl* BHTFirstControl(UIView* view) {
    if ([view isKindOfClass:UIControl.class] && ((UIControl*)view).allControlEvents) return (UIControl*)view;
    for (UIView* subview in view.subviews) {
        UIControl* control = BHTFirstControl(subview);
        if (control) return control;
    }
    return nil;
}

static BOOL BHTIsSingleTap(UIGestureRecognizer* recognizer) {
    if (!recognizer.enabled || ![recognizer isKindOfClass:UITapGestureRecognizer.class]) return NO;
    UITapGestureRecognizer* tap = (UITapGestureRecognizer*)recognizer;
    return tap.numberOfTapsRequired == 1 && tap.numberOfTouchesRequired == 1;
}

// Taps `target` the way a finger would reach it, stopping at `boundary`.
// Returns how it was delivered, or nil if nothing took it.
static NSString* BHTForwardTap(UIView* target, UIView* boundary) {
    BOOL hidden = boundary.hidden;
    CGFloat alpha = boundary.alpha;
    BHTShowingForTap = YES;
    // Hit-testable (alpha above 0.01) but invisible: X's tab switch animation can
    // draw a frame mid-tap, which flashed X's bar at full opacity.
    if (hidden) boundary.alpha = 0.02;
    boundary.hidden = NO;
    NSString* how = nil;
    CGPoint point = [target convertPoint:CGPointMake(CGRectGetMidX(target.bounds), CGRectGetMidY(target.bounds))
                                  toView:nil];
    UIControl* inside = BHTFirstControl(target);
    if (inside) how = BHTControlTap(inside);
    for (UIView* view = target; !how && view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class]) how = BHTControlTap((UIControl*)view);
        for (UIGestureRecognizer* recognizer in view.gestureRecognizers) {
            if (how || !recognizer.enabled || ![recognizer isKindOfClass:UILongPressGestureRecognizer.class]) continue;
            if (BHTInvokeTrackingPress((UILongPressGestureRecognizer*)recognizer, point)) {
                how = [NSString stringWithFormat:@"tracking press on %@", NSStringFromClass(view.class)];
            }
        }
        for (UIGestureRecognizer* recognizer in view.gestureRecognizers) {
            if (how || !BHTIsSingleTap(recognizer)) continue;
            if (BHTInvokeTapTargets((UITapGestureRecognizer*)recognizer, point)) {
                how = [NSString stringWithFormat:@"tap on %@", NSStringFromClass(view.class)];
            }
        }
        if (view == boundary) break;
    }
    for (UIView* view = target; !how && view && view != boundary.superview; view = view.superview) {
        if ([view accessibilityActivate]) how = [NSString stringWithFormat:@"accessibility %@", NSStringFromClass(view.class)];
    }
    boundary.hidden = hidden;
    if (hidden) boundary.alpha = alpha;
    BHTShowingForTap = NO;
    return how;
}

// ponytail: debug aid. Shows how a tab tap was delivered and what X's tab
// item looks like, so forwarding can be fixed. Remove once forwarding is proven.
static void BHTReportGlassTabForwardFailure(UIView* item, UIView* bar, NSString* how) {
    static BOOL reported;
    if (reported) return;
    reported = YES;
    NSMutableString* info = [NSMutableString stringWithFormat:@"Delivered: %@\n", how ?: @"nothing took it"];
    Ivar targetsField = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
    for (UIView* view = item; view; view = view.superview) {
        [info appendFormat:@"%@%@", NSStringFromClass(view.class), view.isAccessibilityElement ? @" (ax)" : @""];
        if ([view isKindOfClass:UIControl.class]) {
            [info appendFormat:@" events=%lu", (unsigned long)((UIControl*)view).allControlEvents];
        }
        for (UIGestureRecognizer* recognizer in view.gestureRecognizers) {
            [info appendFormat:@" [%@", NSStringFromClass(recognizer.class)];
            if ([recognizer isKindOfClass:UITapGestureRecognizer.class]) {
                [info appendFormat:@" taps=%lu", (unsigned long)((UITapGestureRecognizer*)recognizer).numberOfTapsRequired];
            }
            NSArray* targets = targetsField ? object_getIvar(recognizer, targetsField) : nil;
            for (id entry in [targets isKindOfClass:NSArray.class] ? targets : @[]) {
                Ivar actionField = class_getInstanceVariable(object_getClass(entry), "_action");
                if (!actionField) continue;
                SEL action = *(SEL*)((uint8_t*)(__bridge void*)entry + ivar_getOffset(actionField));
                [info appendFormat:@" %@", action ? NSStringFromSelector(action) : @"?"];
            }
            [info appendString:@"]"];
        }
        [info appendString:@"\n"];
        if (view == bar) break;
    }
    UIViewController* top = bar.window.rootViewController;
    while (top.presentedViewController)
        top = top.presentedViewController;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Tab bar couldn't switch tabs"
                                                                   message:info
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                UIPasteboard.generalPasteboard.string = info;
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

// Forwards a tab tap, then reports if X didn't end up on that tab.
static void BHTSelectGlassTab(UIView* bar, NSArray<UIView*>* items, NSUInteger index) {
    if (index >= items.count || !bar) return;
    UIView* item = items[index];
    NSString* how = BHTForwardTap(item, bar);
    if (!how) {
        BHTReportGlassTabForwardFailure(item, bar, nil);
        return;
    }
    __weak UIView* weakBar = bar;
    __weak UIView* weakItem = item;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView* strongBar = weakBar;
        if (strongBar && BHTGlassTabSelectedIndex(strongBar) != (NSInteger)index) {
            BHTReportGlassTabForwardFailure(weakItem, strongBar, how);
        }
    });
}

static UIImage* BHTGlassTabItemImage(UIView* item) {
    Ivar imageField = class_getInstanceVariable(object_getClass(item), "imageView");
    UIImageView* imageView = imageField ? object_getIvar(item, imageField) : nil;
    UIImage* image = [imageView isKindOfClass:UIImageView.class] ? imageView.image : nil;
    return image.renderingMode == UIImageRenderingModeAlwaysOriginal
               ? image
               : [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSString* BHTGlassTabItemBadge(UIView* view) {
    for (UIView* subview in view.subviews) {
        if (subview.hidden || subview.alpha < 0.01) continue;
        if ([subview isKindOfClass:UILabel.class] && ((UILabel*)subview).text.length) {
            return ((UILabel*)subview).text;
        }
        NSString* badge = BHTGlassTabItemBadge(subview);
        if (badge) return badge;
    }
    return nil;
}

static const CGFloat BHTGlassTabRailButton = 52.0;
static const CGFloat BHTGlassTabRailPadding = 8.0;

@interface BHTGlassTabRail : UIView
@property (nonatomic, weak) UIView* bar;
@property (nonatomic, strong) UIVisualEffectView* background;
@property (nonatomic, strong) UIView* selection;
@property (nonatomic, strong) NSMutableArray<UIButton*>* buttons;
@property (nonatomic, strong) NSMutableArray<UILabel*>* badges;
@property (nonatomic, copy) NSArray<UIView*>* items;
@property (nonatomic) NSInteger selectedIndex;
@end

@implementation BHTGlassTabRail

- (instancetype)initWithBar:(UIView*)bar {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _bar = bar;
    _buttons = [NSMutableArray new];
    _badges = [NSMutableArray new];
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    UIVisualEffect* effect =
        [glassClass respondsToSelector:@selector(effectWithStyle:)]
            ? ((UIVisualEffect * (*)(id, SEL, NSInteger)) objc_msgSend)(glassClass, @selector(effectWithStyle:), 0)
            : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    _background = [[UIVisualEffectView alloc] initWithEffect:effect];
    _background.clipsToBounds = YES;
    _background.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_background];
    _selection = [UIView new];
    _selection.backgroundColor = UIColor.tertiarySystemFillColor;
    _selection.userInteractionEnabled = NO;
    [_background.contentView addSubview:_selection];
    return self;
}

- (CGSize)railSize {
    NSUInteger count = self.buttons.count;
    return CGSizeMake(BHTGlassTabRailButton + 2 * BHTGlassTabRailPadding,
                      count * BHTGlassTabRailButton + 2 * BHTGlassTabRailPadding);
}

- (void)reload {
    UIView* bar = self.bar;
    NSArray<UIView*>* items = BHTSortedGlassTabItems(bar);
    while (self.buttons.count < items.count) {
        UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button addTarget:self action:@selector(didTapButton:) forControlEvents:UIControlEventTouchUpInside];
        [self.background.contentView addSubview:button];
        [self.buttons addObject:button];
        UILabel* badge = [UILabel new];
        badge.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        badge.textColor = UIColor.whiteColor;
        badge.textAlignment = NSTextAlignmentCenter;
        badge.backgroundColor = UIColor.systemBlueColor;
        badge.clipsToBounds = YES;
        badge.userInteractionEnabled = NO;
        [self.background.contentView addSubview:badge];
        [self.badges addObject:badge];
    }
    while (self.buttons.count > items.count) {
        [self.buttons.lastObject removeFromSuperview];
        [self.buttons removeLastObject];
        [self.badges.lastObject removeFromSuperview];
        [self.badges removeLastObject];
    }
    self.items = items;
    self.selectedIndex = BHTGlassTabSelectedIndex(bar);
    UIColor* selectedColor = [BHTSettings boolForKey:@"tab_bar_theming"] ? (CurrentAccentColor() ?: UIColor.labelColor)
                                                                         : UIColor.labelColor;
    for (NSUInteger index = 0; index < items.count; index++) {
        UIButton* button = self.buttons[index];
        BOOL selected = (NSInteger)index == self.selectedIndex;
        [button setImage:BHTGlassTabItemImage(items[index]) forState:UIControlStateNormal];
        button.tintColor = selected ? selectedColor : UIColor.secondaryLabelColor;
        button.tag = index;
        button.accessibilityLabel = BHTGlassTabItemTitle(items[index], bar);
        button.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
        NSString* badge = BHTGlassTabItemBadge(items[index]);
        self.badges[index].text = badge;
        self.badges[index].hidden = !badge.length;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.background.frame = self.bounds;
    self.background.layer.cornerRadius = CGRectGetWidth(self.bounds) / 2.0;
    self.selection.hidden = YES;
    for (NSUInteger index = 0; index < self.buttons.count; index++) {
        CGRect frame = CGRectMake(BHTGlassTabRailPadding, BHTGlassTabRailPadding + index * BHTGlassTabRailButton,
                                  BHTGlassTabRailButton, BHTGlassTabRailButton);
        self.buttons[index].frame = frame;
        UILabel* badge = self.badges[index];
        CGFloat width = MAX(18.0, [badge sizeThatFits:CGSizeZero].width + 10.0);
        badge.frame = CGRectMake(CGRectGetMaxX(frame) - width - 2.0, CGRectGetMinY(frame) + 4.0, width, 18.0);
        badge.layer.cornerRadius = 9.0;
        if ((NSInteger)index == self.selectedIndex) {
            self.selection.hidden = NO;
            self.selection.frame = CGRectInset(frame, 2.0, 2.0);
            self.selection.layer.cornerRadius = CGRectGetWidth(self.selection.frame) / 2.0;
        }
    }
}

- (void)didTapButton:(UIButton*)button {
    UIView* bar = self.bar;
    if (button.tag >= (NSInteger)self.items.count || !bar) return;
    BHTSelectGlassTab(bar, self.items, button.tag);
    // Selection updates once X has handled the tap.
    __weak BHTGlassTabRail* weakSelf = self;
    for (NSNumber* delay in @[@0.05, @0.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf reload];
                       });
    }
}

@end

// MARK: Native tab bar

// A real UITabBarController laid over X, so iOS itself places the bar exactly as
// in other iPhone Duo apps (side strip, or along the bottom on the unfolded screen
// held upright). Its tabs are empty placeholders and everything but the bar
// passes touches through to X; picking a tab taps X's own item.

@interface BHTPassthroughView : UIView
@property (nonatomic, weak) UITabBarController* controller;
@end

@implementation BHTPassthroughView
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    UIView* page = self.controller.selectedViewController.viewIfLoaded;
    // Only the bar takes touches: not this view, the placeholder page, or the
    // controller's own containers around it.
    if (!hit || hit == self || (page && ([hit isDescendantOfView:page] || [page isDescendantOfView:hit]))) return nil;
    return hit;
}
@end

@interface BHTNativeTabHost : NSObject <UITabBarControllerDelegate>
@property (nonatomic, weak) UIView* bar;
@property (nonatomic, strong) UITabBarController* controller;
@property (nonatomic, strong) BHTPassthroughView* container;
@property (nonatomic, copy) NSArray<UIView*>* items;
@property (nonatomic, strong) UIVisualEffectView* compose;
@property (nonatomic, strong) UIButton* composeButton;
// The system put the bar in the vertical side strip (where compose sits on top).
@property (nonatomic) BOOL railLayout;
- (void)layoutCompose;
@end

static __weak BHTNativeTabHost* BHTActiveNativeHost;

// MARK: Compose button

// X's floating "+" (one per screen that has one) moves onto the rail as a glass
// button while the native bar is vertical. Tapping it taps X's own button.

static char BHTFloatingRequestedHiddenKey;
static char BHTFloatingOrderKey;

static NSHashTable<UIView*>* BHTFloatingButtons(void) {
    static NSHashTable<UIView*>* buttons;
    if (!buttons) buttons = [NSHashTable weakObjectsHashTable];
    return buttons;
}

static BOOL BHTFloatingButtonReplaced(UIView* button) {
    return BHTActiveNativeHost.railLayout && button.window;
}

BOOL BHTFloatingButtonHiddenRequest(UIView* button, BOOL hidden) {
    if (BHTShowingForTap) return hidden;
    objc_setAssociatedObject(button, &BHTFloatingRequestedHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BHTNativeTabHost* host = BHTActiveNativeHost;
    dispatch_async(dispatch_get_main_queue(), ^{
        [host layoutCompose];
    });
    return hidden || BHTFloatingButtonReplaced(button);
}

static char BHTFloatingContainerHiddenKey;

// The button's floating wrapper (e.g. its glass circle): the largest ancestor
// that is still button-sized.
static UIView* BHTFloatingContainer(UIView* button) {
    UIView* view = button;
    while (view.superview && CGRectGetWidth(view.superview.bounds) <= 120.0 &&
           CGRectGetHeight(view.superview.bounds) <= 120.0)
        view = view.superview;
    return view;
}

static void BHTApplyFloatingButtonHidden(UIView* button) {
    // Goes through the setHidden: hook, which adds the replacement on top.
    button.hidden = [objc_getAssociatedObject(button, &BHTFloatingRequestedHiddenKey) boolValue];
    UIView* container = BHTFloatingContainer(button);
    if (container == button) return;
    BOOL hiddenByUs = objc_getAssociatedObject(container, &BHTFloatingContainerHiddenKey) != nil;
    if (BHTFloatingButtonReplaced(button) && !container.hidden) {
        container.hidden = YES;
        objc_setAssociatedObject(container, &BHTFloatingContainerHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!BHTFloatingButtonReplaced(button) && hiddenByUs) {
        container.hidden = NO;
        objc_setAssociatedObject(container, &BHTFloatingContainerHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static char BHTComposeButtonKey;

BOOL BHTIsComposeButton(UIView* button) {
    return objc_getAssociatedObject(button, &BHTComposeButtonKey) != nil;
}

// X's Liquid Glass "+" is an XDSButton labelled "Compose post" (found with FLEX
// on X 12.46). ponytail: matched by its English label; other languages keep X's.
void BHTXDSButtonChanged(UIView* button) {
    if (!BHTIsComposeButton(button)) {
        if (![button.accessibilityLabel isEqualToString:@"Compose post"]) return;
        objc_setAssociatedObject(button, &BHTComposeButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BHTFloatingButtonDidMoveToWindow(button);
}

void BHTFloatingButtonDidMoveToWindow(UIView* button) {
    static NSUInteger order;
    if (!button.window) return;
    [BHTFloatingButtons() addObject:button];
    objc_setAssociatedObject(button, &BHTFloatingOrderKey, @(++order), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BHTApplyFloatingButtonHidden(button);
}

// The floating button of the screen on show: the newest one in this window that
// X itself isn't hiding.
static UIView* BHTCurrentFloatingButton(UIWindow* window) {
    UIView* best = nil;
    NSUInteger bestOrder = 0;
    for (UIView* button in BHTFloatingButtons().allObjects) {
        if (button.window != window || [objc_getAssociatedObject(button, &BHTFloatingRequestedHiddenKey) boolValue]) {
            continue;
        }
        BOOL visible = YES;
        for (UIView* view = button.superview; view && visible; view = view.superview) {
            BOOL ourHide = objc_getAssociatedObject(view, &BHTFloatingContainerHiddenKey) != nil;
            visible = (!view.hidden || ourHide) && view.alpha > 0.01;
        }
        NSUInteger order = [objc_getAssociatedObject(button, &BHTFloatingOrderKey) unsignedIntegerValue];
        if (visible && order >= bestOrder) {
            best = button;
            bestOrder = order;
        }
    }
    return best;
}

static UIImage* BHTFirstImage(UIView* view) {
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView*)view).image) return ((UIImageView*)view).image;
    for (UIView* subview in view.subviews) {
        UIImage* image = BHTFirstImage(subview);
        if (image) return image;
    }
    return nil;
}

@implementation BHTNativeTabHost

- (instancetype)initWithBar:(UIView*)bar {
    self = [super init];
    if (!self) return nil;
    _bar = bar;
    _controller = [UITabBarController new];
    _controller.delegate = self;
    _container = [BHTPassthroughView new];
    _container.controller = _controller;
    _container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    Class glassClass = NSClassFromString(@"UIGlassEffect");
    UIVisualEffect* effect =
        [glassClass respondsToSelector:@selector(effectWithStyle:)]
            ? ((UIVisualEffect * (*)(id, SEL, NSInteger)) objc_msgSend)(glassClass, @selector(effectWithStyle:), 0)
            : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    // iOS 26 glass API, absent from the SDK this builds against.
    if ([effect respondsToSelector:@selector(setTintColor:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(effect, @selector(setTintColor:),
                                              CurrentAccentColor() ?: UIColor.systemBlueColor);
    }
    SEL interactive = NSSelectorFromString(@"setInteractive:");
    if ([effect respondsToSelector:interactive]) ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, interactive, YES);
    _compose = [[UIVisualEffectView alloc] initWithEffect:effect];
    _compose.clipsToBounds = YES;
    _compose.hidden = YES;
    _composeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _composeButton.tintColor = UIColor.whiteColor;
    _composeButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_composeButton addTarget:self action:@selector(didTapCompose) forControlEvents:UIControlEventTouchUpInside];
    [_compose.contentView addSubview:_composeButton];
    return self;
}

- (void)didTapCompose {
    UIView* button = BHTCurrentFloatingButton(self.bar.window);
    if (button) {
        BHTForwardTap(button, BHTFloatingContainer(button));
        return;
    }
    // X's own link for "new post", as used from outside the app.
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"twitter://post"] options:@{} completionHandler:nil];
}

// Finds (in `container` coordinates) the largest visible view under `view`
// inside the side strip: the bar's background platter. It's steady, unlike the
// union of everything there, which bulges while the selection slides between
// tabs. iOS may not use `tabBar` itself for the Duo strip layout.
static void BHTFindStripPlatter(UIView* view, UIView* page, UIView* container, CGFloat stripMinX, CGRect* frame) {
    for (UIView* subview in view.subviews) {
        if (subview == page || subview.hidden || subview.alpha < 0.01) continue;
        CGRect rect = [container convertRect:subview.bounds fromView:subview];
        if (CGRectGetWidth(rect) > 0 && CGRectGetHeight(rect) > 0 && CGRectGetMinX(rect) >= stripMinX - 4.0 &&
            CGRectGetHeight(rect) < CGRectGetHeight(container.bounds) * 0.9 &&
            (CGRectIsNull(*frame) ||
             CGRectGetWidth(rect) * CGRectGetHeight(rect) > CGRectGetWidth(*frame) * CGRectGetHeight(*frame))) {
            *frame = rect;
        }
        BHTFindStripPlatter(subview, page, container, stripMinX, frame);
    }
}

// Puts the compose button on top of the vertical bar, mirroring X's current
// floating button (its icon, and whether the screen has one at all).
- (void)layoutCompose {
    UIView* container = self.container;
    UIWindow* window = container.window;
    CGFloat strip = window.safeAreaInsets.right;
    // Same rule the rail uses for where Duo apps put a vertical bar.
    BOOL rail = window && !container.hidden && strip >= 44.0 && NFBGlassTabRailActive(container);
    CGRect bar = CGRectNull;
    if (rail) {
        CGFloat stripMinX = CGRectGetMaxX(container.bounds) - strip;
        BHTFindStripPlatter(self.controller.view, self.controller.selectedViewController.viewIfLoaded, container,
                            stripMinX, &bar);
        if (CGRectIsNull(bar)) {
            // Drawn outside our views: assume a bottom-aligned bar of ~56pt per tab.
            CGFloat height = self.items.count * 56.0;
            bar = CGRectMake(stripMinX + 4.0,
                             CGRectGetMaxY(container.bounds) - window.safeAreaInsets.bottom - 12.0 - height,
                             strip - 8.0, height);
        }
    }
    if (rail != self.railLayout) {
        self.railLayout = rail;
        for (UIView* button in BHTFloatingButtons().allObjects)
            BHTApplyFloatingButtonHidden(button);
        BHTReapplyTabChildSafeAreaInsets(self.bar);
    }
    UIView* floating = rail ? BHTCurrentFloatingButton(window) : nil;
    self.compose.hidden = !rail;
    if (!rail) return;
    if (self.compose.superview != container) [container addSubview:self.compose];
    if (container.subviews.lastObject != self.compose) [container bringSubviewToFront:self.compose];
    UIImage* image = (floating ? BHTFirstImage(floating) : nil) ?: [UIImage systemImageNamed:@"plus"];
    if ([self.composeButton imageForState:UIControlStateNormal] != image) {
        [self.composeButton setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                            forState:UIControlStateNormal];
    }
    self.composeButton.accessibilityLabel = floating.accessibilityLabel ?: @"Post";
    // Same width and centre line as the bar's platter, just above it.
    CGFloat size = MAX(36.0, MIN(CGRectGetWidth(bar), strip - 8.0));
    CGRect frame = CGRectMake(CGRectGetMidX(bar) - size / 2.0, CGRectGetMinY(bar) - 10.0 - size, size, size);
    if (!CGRectEqualToRect(self.compose.frame, frame)) {
        self.compose.frame = frame;
        self.compose.layer.cornerRadius = size / 2.0;
        self.composeButton.frame = self.compose.contentView.bounds;
    }
}

// The top of the view controller chain that shows X's bar (the root, or
// whatever X presents its main interface in).
static UIViewController* BHTTopControllerForView(UIView* view) {
    UIViewController* controller = nil;
    for (UIResponder* responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) controller = (UIViewController*)responder;
    }
    while (controller.parentViewController)
        controller = controller.parentViewController;
    return controller;
}

- (void)attach {
    UIViewController* parent = BHTTopControllerForView(self.bar);
    if (!parent.isViewLoaded) return;
    UITabBarController* controller = self.controller;
    if (controller.parentViewController != parent) {
        [self detach];
        [parent addChildViewController:controller];
        self.container.frame = parent.view.bounds;
        [parent.view addSubview:self.container];
        controller.view.frame = self.container.bounds;
        controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        controller.view.backgroundColor = UIColor.clearColor;
        [self.container addSubview:controller.view];
        [controller didMoveToParentViewController:parent];
    }
    if (parent.view.subviews.lastObject != self.container) [parent.view bringSubviewToFront:self.container];
    BHTActiveNativeHost = self;
}

- (void)detach {
    if (BHTActiveNativeHost == self) BHTActiveNativeHost = nil;
    self.railLayout = NO;
    BHTReapplyTabChildSafeAreaInsets(self.bar);
    for (UIView* button in BHTFloatingButtons().allObjects)
        BHTApplyFloatingButtonHidden(button);
    UITabBarController* controller = self.controller;
    if (!controller.parentViewController) return;
    [controller willMoveToParentViewController:nil];
    [self.container removeFromSuperview];
    [controller removeFromParentViewController];
}

- (void)reload {
    UIView* bar = self.bar;
    NSArray<UIView*>* items = BHTSortedGlassTabItems(bar);
    UITabBarController* controller = self.controller;
    if (controller.viewControllers.count != items.count) {
        NSMutableArray* pages = [NSMutableArray new];
        for (NSUInteger index = 0; index < items.count; index++) {
            UIViewController* page = [UIViewController new];
            page.view.backgroundColor = UIColor.clearColor;
            [pages addObject:page];
        }
        controller.viewControllers = pages;
    }
    self.items = items;
    for (NSUInteger index = 0; index < items.count; index++) {
        UITabBarItem* item = controller.viewControllers[index].tabBarItem;
        item.image = BHTGlassTabItemImage(items[index]);
        item.title = BHTGlassTabItemTitle(items[index], bar);
        NSString* badge = BHTGlassTabItemBadge(items[index]);
        item.badgeValue = badge.length ? badge : nil;
    }
    controller.tabBar.tintColor = [BHTSettings boolForKey:@"tab_bar_theming"] ? CurrentAccentColor() : nil;
    NSInteger selected = BHTGlassTabSelectedIndex(bar);
    if (selected >= 0 && selected < (NSInteger)items.count && controller.selectedIndex != (NSUInteger)selected) {
        controller.selectedIndex = selected;
    }
    __weak BHTNativeTabHost* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf layoutCompose];
    });
}

- (BOOL)tabBarController:(UITabBarController*)controller shouldSelectViewController:(UIViewController*)page {
    NSUInteger index = [controller.viewControllers indexOfObjectIdenticalTo:page];
    UIView* bar = self.bar;
    if (index == NSNotFound || index >= self.items.count || !bar) return NO;
    BHTSelectGlassTab(bar, self.items, index);
    __weak BHTNativeTabHost* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf reload];
    });
    return YES;
}

@end

static char BHTGlassTabRailKey;
static char BHTNativeTabHostKey;
static char BHTGlassTabRequestedHiddenKey;
static char BHTGlassTabRailScheduledKey;

// Whether X's bar is currently replaced (by the native bar or the rail).
BOOL BHTGlassTabIsRail(UIView* bar) {
    return objc_getAssociatedObject(bar, &BHTGlassTabRailKey) != nil ||
           objc_getAssociatedObject(bar, &BHTNativeTabHostKey) != nil;
}

static BOOL BHTHidingGlassTabBar;

static void BHTHideReplacedGlassTabBar(UIView* bar);

BOOL BHTGlassTabHiddenRequest(UIView* bar, BOOL hidden) {
    if (BHTShowingForTap) return hidden;
    if (!BHTHidingGlassTabBar) {
        objc_setAssociatedObject(bar, &BHTGlassTabRequestedHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BHTGlassTabRail* rail = objc_getAssociatedObject(bar, &BHTGlassTabRailKey);
        rail.hidden = hidden;
        BHTNativeTabHost* host = objc_getAssociatedObject(bar, &BHTNativeTabHostKey);
        host.container.hidden = hidden;
    }
    return hidden || BHTGlassTabIsRail(bar) || BHTGlassTabReplacedNow(bar);
}

// Whether X's bar is being replaced right now, before the (asynchronous) rail
// or native bar update has caught up. A fresh bar X creates (e.g. on the Grok
// tab) would otherwise show for a frame or two.
BOOL BHTGlassTabReplacedNow(UIView* bar) {
    return bar.window && (NFBNativeTabBarEnabled() || NFBGlassTabRailActive(bar));
}

void BHTHideGlassTabBarIfReplaced(UIView* bar) {
    if (BHTGlassTabReplacedNow(bar)) BHTHideReplacedGlassTabBar(bar);
}

// MARK: Bottom space for X's bar

// X's tab container gives each tab's screen a bottom safe-area inset for its
// floating bar. Timelines scroll under it, but screens pinned to it (Grok's
// input) stop short of the bottom. While the bar lives in the side strip that
// space is empty, so drop it; X's own value is kept to restore later.
// ponytail: assumes X uses additionalSafeAreaInsets on its tab children.
static char BHTRequestedSafeAreaKey;

static UIViewController* BHTXTabController(UIViewController* controller) {
    Class tabClass = NSClassFromString(@"_TtC11XNavigation16TabBarController");
    for (UIViewController* parent = controller; parent && tabClass; parent = parent.parentViewController) {
        if ([parent isKindOfClass:tabClass]) return parent;
    }
    return nil;
}

static BOOL BHTTabBarInSideStrip(UIViewController* controller) {
    if (NFBNativeTabBarEnabled()) return BHTActiveNativeHost.railLayout;
    UIView* view = controller.viewIfLoaded ?: controller.parentViewController.viewIfLoaded;
    return NFBGlassTabRailActive(view) && !NFBGlassTabRailNeedsInset(view);
}

UIEdgeInsets BHTTabChildSafeAreaInsets(UIViewController* controller, UIEdgeInsets insets) {
    UIViewController* parent = controller.parentViewController;
    if (!parent || BHTXTabController(parent) != parent) return insets;
    objc_setAssociatedObject(controller, &BHTRequestedSafeAreaKey, [NSValue valueWithUIEdgeInsets:insets],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (BHTTabBarInSideStrip(controller)) insets.bottom = 0.0;
    return insets;
}

void BHTReapplyTabChildSafeAreaInsets(UIView* bar) {
    UIViewController* owner = nil;
    for (UIResponder* responder = bar.nextResponder; responder && !owner; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) owner = (UIViewController*)responder;
    }
    for (UIViewController* child in BHTXTabController(owner).childViewControllers) {
        NSValue* requested = objc_getAssociatedObject(child, &BHTRequestedSafeAreaKey);
        if (requested) child.additionalSafeAreaInsets = requested.UIEdgeInsetsValue;
    }
}

static void BHTHideReplacedGlassTabBar(UIView* bar) {
    if (bar.hidden) return;
    BHTHidingGlassTabBar = YES;
    bar.hidden = YES;
    BHTHidingGlassTabBar = NO;
}

static void BHTUpdateNativeTabBar(UIView* bar, BOOL active) {
    BHTNativeTabHost* host = objc_getAssociatedObject(bar, &BHTNativeTabHostKey);
    if (!active) {
        if (host) {
            [host detach];
            objc_setAssociatedObject(bar, &BHTNativeTabHostKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            bar.hidden = [objc_getAssociatedObject(bar, &BHTGlassTabRequestedHiddenKey) boolValue];
        }
        return;
    }
    if (!host) {
        host = [[BHTNativeTabHost alloc] initWithBar:bar];
        objc_setAssociatedObject(bar, &BHTNativeTabHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        host.container.hidden = [objc_getAssociatedObject(bar, &BHTGlassTabRequestedHiddenKey) boolValue];
    }
    BHTHideReplacedGlassTabBar(bar);
    [host attach];
    [host reload];
}

void BHTUpdateGlassTabRail(UIView* bar) {
    BOOL native = NFBNativeTabBarEnabled() && bar.window && bar.superview;
    BHTUpdateNativeTabBar(bar, native);
    BHTGlassTabRail* rail = objc_getAssociatedObject(bar, &BHTGlassTabRailKey);
    UIWindow* window = bar.window;
    if (native || !NFBGlassTabRailActive(bar) || !bar.superview) {
        if (rail) {
            [rail removeFromSuperview];
            objc_setAssociatedObject(bar, &BHTGlassTabRailKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!native) bar.hidden = [objc_getAssociatedObject(bar, &BHTGlassTabRequestedHiddenKey) boolValue];
            BHTReapplyTabChildSafeAreaInsets(bar);
        }
        return;
    }
    if (!rail) {
        rail = [[BHTGlassTabRail alloc] initWithBar:bar];
        objc_setAssociatedObject(bar, &BHTGlassTabRailKey, rail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BHTReapplyTabChildSafeAreaInsets(bar);
        rail.hidden = [objc_getAssociatedObject(bar, &BHTGlassTabRequestedHiddenKey) boolValue];
    }
    BHTHideReplacedGlassTabBar(bar);
    [rail reload];

    // Like native iPhone Duo apps: bottom-aligned in the side strip beside the
    // status bar. Without room there, it sits in the inset the split leaves for it.
    CGSize size = [rail railSize];
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat centerX = NFBGlassTabRailNeedsInset(bar) ? CGRectGetMaxX(window.bounds) - safe.right - NFBGlassTabRailInset / 2.0
                                                     : CGRectGetMaxX(window.bounds) - safe.right / 2.0;
    CGRect target = CGRectMake(centerX - size.width / 2.0,
                               CGRectGetMaxY(window.bounds) - safe.bottom - 12.0 - size.height, size.width,
                               size.height);
    // Host the rail in the nearest ancestor that covers it, so it receives touches.
    UIView* host = bar.superview;
    while (host.superview && !CGRectContainsRect(host.bounds, [host convertRect:target fromView:nil]))
        host = host.superview;
    if (rail.superview != host) [host addSubview:rail];
    if (host.subviews.lastObject != rail) [host bringSubviewToFront:rail];
    CGRect frame = [host convertRect:target fromView:nil];
    if (!CGRectEqualToRect(rail.frame, frame)) rail.frame = frame;
}

void BHTScheduleGlassTabRailUpdate(UIView* view) {
    Class barClass = NSClassFromString(@"_TtC11XNavigation10TabBarView");
    UIView* bar = view;
    while (bar && ![bar isKindOfClass:barClass])
        bar = bar.superview;
    if (!bar || objc_getAssociatedObject(bar, &BHTGlassTabRailScheduledKey)) return;
    if (!BHTGlassTabIsRail(bar) && !NFBGlassTabRailActive(bar) && !NFBNativeTabBarEnabled()) return;
    objc_setAssociatedObject(bar, &BHTGlassTabRailScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView* weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView* strongBar = weakBar;
        if (!strongBar) return;
        objc_setAssociatedObject(strongBar, &BHTGlassTabRailScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BHTUpdateGlassTabRail(strongBar);
    });
}

void BHTApplyGlassTabAccent(UIView* item) {
    if (item.isAccessibilityElement) return;

    Ivar field = class_getInstanceVariable(object_getClass(item), "imageView");
    UIImageView* imageView = field ? object_getIvar(item, field) : nil;
    if (![imageView isKindOfClass:UIImageView.class]) return;

    id originalTint = objc_getAssociatedObject(imageView, &BHTGlassTabOriginalTintKey);
    UIColor* tint;
    if ([BHTSettings boolForKey:@"tab_bar_theming"]) {
        if (!originalTint) {
            objc_setAssociatedObject(imageView, &BHTGlassTabOriginalTintKey,
                                     imageView.tintColor ?: (id)NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        tint = CurrentAccentColor();
    } else {
        if (!originalTint) return;
        tint = originalTint == NSNull.null ? nil : originalTint;
        objc_setAssociatedObject(imageView, &BHTGlassTabOriginalTintKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (![imageView.tintColor isEqual:tint]) imageView.tintColor = tint;
}

static char BHTLegacyTabLabelKey;
static char BHTLegacyTabGlyphShiftKey;

UIColor* BHTTabItemColor(BOOL selected) {
    return selected ? CurrentAccentColor() : [UIColor secondaryLabelColor];
}

static void BHTLayoutLegacyTabLabel(T1TabView* tabView) {
    UILabel* label = objc_getAssociatedObject(tabView, &BHTLegacyTabLabelKey);
    BOOL enabled = [BHTSettings boolForKey:@"restore_tab_labels"] && tabView.title.length;
    if (!enabled) {
        [label removeFromSuperview];
        objc_setAssociatedObject(tabView, &BHTLegacyTabLabelKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (!label) {
        label = BHTCreateTabLabel();
        objc_setAssociatedObject(tabView, &BHTLegacyTabLabelKey, label,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    label.text = tabView.title;
    label.textColor = BHTTabItemColor(tabView.selected);
    label.frame = CGRectMake(2.0, CGRectGetHeight(tabView.bounds) - 13.0,
                             MAX(0.0, CGRectGetWidth(tabView.bounds) - 4.0), 11.0);
    if (label.superview != tabView) [tabView addSubview:label];
    [tabView bringSubviewToFront:label];
}

// MARK: - Top bar logo theming

// MARK: - iPad sidebar logo theming

void BHTApplySidebarIconTheme(UIViewController* sidebar) {
    Ivar iconViewIvar =
        class_getInstanceVariable(NSClassFromString(@"T1AppSplitSideBarViewController"), "_iconView");
    if (!iconViewIvar) {
        return;
    }

    UIImageView* iconView = object_getIvar(sidebar, iconViewIvar);
    if (![iconView isKindOfClass:[UIImageView class]] || !iconView.image) {
        return;
    }

    BOOL wantsAccent = [BHTSettings boolForKey:@"color_twitter_icon_in_top_bar"];
    UIImageRenderingMode mode = wantsAccent ? UIImageRenderingModeAlwaysTemplate
                                            : UIImageRenderingModeAlwaysOriginal;

    if (iconView.image.renderingMode != mode) {
        iconView.image = [iconView.image imageWithRenderingMode:mode];
    }
    if (wantsAccent) {
        iconView.tintColor = CurrentAccentColor();
    }
    BHTMarkAccentTintedIcon(iconView, wantsAccent);
}

#pragma mark - Hook entry points

UIColor* BHTThemePrimaryColor(id palette, UIColor* native) {
    objc_setAssociatedObject(palette, &BHTNativePrimaryColorKey, native,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return selectedCustomThemeColor() ?: native;
}

UIColor* BHTThemeLoadedColor(id loader, NSString* name, UIColor* color) {
    if (BHTMappingLoadedColor || !selectedCustomThemeColor() ||
        ![name isKindOfClass:NSString.class] ||
        [name isEqualToString:@"primaryColor"] ||
        [name hasPrefix:@"primaryColorOption"]) return color;

    BHTMappingLoadedColor = YES;
    Ivar paletteField = class_getInstanceVariable(object_getClass(loader), "_palette");
    id palette = paletteField ? object_getIvar(loader, paletteField) : nil;
    UIColor* native = objc_getAssociatedObject(palette, &BHTNativePrimaryColorKey);
    if (!native && palette &&
        [palette respondsToSelector:@selector(primaryColor)]) {
        // The palette getter records the original color before substituting.
        ((id (*)(id, SEL))objc_msgSend)(palette, @selector(primaryColor));
        native = objc_getAssociatedObject(palette, &BHTNativePrimaryColorKey);
    }
    UIColor* mapped = BHTReplaceKnownAccent(color, native);
    BHTMappingLoadedColor = NO;
    return mapped;
}

UIColor* BHTThemeDynamicColor(UIColor* color, UIColor* resolved) {
    if (BHTMappingDynamicColor || !selectedCustomThemeColor()) return resolved;
    id identifier = [color respondsToSelector:@selector(tfn_dynamicColorIdentifier)]
                        ? [color tfn_dynamicColorIdentifier]
                        : nil;
    // The picker reads these six tokens directly; they are previews, not the
    // active accent, even when the selected option is custom.
    if ([identifier isKindOfClass:NSString.class] &&
        [identifier hasPrefix:@"primaryColorOption"]) return resolved;
    BHTMappingDynamicColor = YES;
    BOOL accentText = [identifier isKindOfClass:NSString.class] &&
                      ([identifier isEqualToString:@"primaryColor"] ||
                       [identifier isEqualToString:@"textLinkColor"]);
    UIColor* mapped = accentText
                          ? BHTReplaceNativeAccent(resolved, resolved)
                          : BHTReplaceKnownAccent(resolved, BHTNativeAccentForCurrentPalette());
    BHTMappingDynamicColor = NO;
    return mapped;
}

id<TAEColorPalette> BHTThemeColorPalette(id info, id<TAEColorPalette> realPalette, BOOL isDark) {
    if (selectedCustomThemeColor()) {
        UIColor* native = objc_getAssociatedObject(realPalette, &BHTNativePrimaryColorKey);
        if (!native && [(id)realPalette respondsToSelector:@selector(primaryColor)]) {
            ((id (*)(id, SEL))objc_msgSend)(realPalette, @selector(primaryColor));
            native = objc_getAssociatedObject(realPalette, &BHTNativePrimaryColorKey);
        }
        objc_setAssociatedObject(info, &BHTNativePrimaryColorKey, native,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (isDark && BHTDimThemeEnabled()) {
        BHTDimHasRendered = YES;
        // One proxy per real palette: this getter runs on hot paths.
        BHTDimPaletteProxy* proxy = objc_getAssociatedObject(realPalette, &BHTDimProxyKey);
        if (!proxy) {
            proxy = [BHTDimPaletteProxy proxyWithPalette:realPalette];
            objc_setAssociatedObject(realPalette, &BHTDimProxyKey, proxy,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return (id<TAEColorPalette>)proxy;
    }
    return realPalette;
}

// Dim can be turned off while the app runs, so the provider checks the setting
// on every resolve rather than only when the color was created.
UIColor* BHTThemeSystemBackground(UIColor* original, UIColor* dim) {
    if (!BHTDimThemeEnabled()) return original;
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        return BHTDimThemeEnabled() && traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? dim
                   : original;
    }];
}

UIColor* BHTThemeResolvedBackground(UIColor* original, UITraitCollection* traits) {
    if (!BHTDimThemeEnabled() || traits.userInterfaceStyle != UIUserInterfaceStyleDark) {
        return original;
    }
    return BHTDimReplacementForResolvedColor(original) ?: original;
}

void BHTUpdateLegacyTabLabelColor(T1TabView* tabView, BOOL selected) {
    UILabel* label = objc_getAssociatedObject(tabView, &BHTLegacyTabLabelKey);
    label.textColor = BHTTabItemColor(selected);
}

UIView* BHTPrepareLegacyTabLayout(T1TabView* tabView) {
    UIView* glyph = tabView.transformContainer ?: tabView.imageView;
    if ([objc_getAssociatedObject(glyph, &BHTLegacyTabGlyphShiftKey) boolValue]) {
        glyph.center = CGPointMake(glyph.center.x, glyph.center.y + 5.0);
        objc_setAssociatedObject(glyph, &BHTLegacyTabGlyphShiftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return glyph;
}

void BHTFinishLegacyTabLayout(T1TabView* tabView, UIView* glyph) {
    BHTLayoutLegacyTabLabel(tabView);
    if ([BHTSettings boolForKey:@"restore_tab_labels"] && tabView.title.length &&
        CGRectGetHeight(tabView.bounds) >= 34.0 && glyph) {
        glyph.center = CGPointMake(glyph.center.x, glyph.center.y - 5.0);
        objc_setAssociatedObject(glyph, &BHTLegacyTabGlyphShiftKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
