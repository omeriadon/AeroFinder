@import Foundation;
@import AppKit;
@import QuartzCore;
@import CoreVideo;
#import "../ZKSwizzle/ZKSwizzle.h"
#import <objc/runtime.h>

/**
 * AeroFinder - Finder HUD Effect Tweak (Merged v2.2 - Grouped Swizzling)
 *
 * IMPLEMENTATION:
 * - Hides Finder's background by removing/hiding NSVisualEffectView
 * - Adds an always-active NSVisualEffectView with HUD material to navigation
 *   windows
 * - Handles Sidebar and Titlebar artifacts
 * - Smart Fullscreen and Focus handling
 * - Uses ZKSwizzleInterfaceGroup for safe, process-isolated injection
 *
 * REQUIREMENTS:
 * - Finder-only injection
 */

#pragma mark - Configuration

static BOOL tweakEnabled = YES;
static NSMutableDictionary<NSNumber *, NSVisualEffectView *> *effectViews = nil;
static char kAeroFinderEffectViewKey;
static char kAeroFinderChromeEffectViewKey;
static char kAeroFinderNativeChromeStateKey;
// static NSMutableDictionary *windowTimers = nil; // Removed in favor of
// CVDisplayLink
static NSMutableDictionary<NSNumber *, NSNumber *>
    *windowMaintenanceTimestamps = nil;
static NSMutableDictionary<NSNumber *, NSValue *> *windowDisplayLinks = nil;
static NSMutableDictionary<NSNumber *, NSNumber *> *windowScrollTimestamps =
    nil;
static NSColor *clearColorCache = nil;
static const NSTimeInterval kWindowMaintenanceInterval =
    0.018; // ~60FPS target for active
static const NSTimeInterval kWindowIdleInterval = 1.0; // 1Hz for idle
static const NSTimeInterval kScrollActivityWindow = 0.5;

#pragma mark - Macros

#define BEGIN_NO_ANIMATION                                                     \
  [CATransaction begin];                                                       \
  [CATransaction setDisableActions:YES];                                       \
  [CATransaction setAnimationDuration:0];

#define END_NO_ANIMATION [CATransaction commit];

#pragma mark - Helper Functions

// Check if running in Finder
static inline BOOL isFinderProcess(void) {
  static dispatch_once_t onceToken;
  static BOOL isFinder = NO;
  dispatch_once(&onceToken, ^{
    isFinder =
        [[[NSProcessInfo processInfo] processName] isEqualToString:@"Finder"];
  });
  return isFinder;
}

// Forward declarations
static inline void ensureTransparentScrollStack(NSScrollView *scrollView);
static void refreshScrollStacksInView(NSView *view, NSInteger depth);
static void refreshScrollStacksForWindow(NSWindow *window);
static void stopDisplayLinkForWindow(NSWindow *window);
static inline BOOL shouldModifyWindow(NSWindow *window);
static CVReturn
displayLinkCallback(CVDisplayLinkRef link, const CVTimeStamp *inNow,
                    const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn,
                    CVOptionFlags *flagsOut, void *displayLinkContext);
static void applyHUDEffect(NSWindow *window);
static void removeHUDEffect(NSWindow *window);
static void processTitlebarArea(NSWindow *window);
static void refreshChromeEffectsForWindow(NSWindow *window);
static void removeChromeEffectsForWindow(NSWindow *window);

@interface AeroFinderEffectView : NSVisualEffectView
@property(nonatomic, weak) NSWindow *ownerWindow;
@property(nonatomic) BOOL allowsReattachment;
@end

@interface AeroFinderChromeEffectView : NSVisualEffectView
@end

@implementation AeroFinderChromeEffectView

- (NSView *)hitTest:(NSPoint)point {
  return nil;
}

@end

@implementation AeroFinderEffectView

- (void)viewDidMoveToSuperview {
  [super viewDidMoveToSuperview];

  if (self.superview || !self.allowsReattachment)
    return;

  NSWindow *window = self.ownerWindow;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.superview && self.allowsReattachment && window &&
        shouldModifyWindow(window)) {
      applyHUDEffect(window);
    }
  });
}

@end

// Check if window is in fullscreen mode
static inline BOOL isWindowFullscreen(NSWindow *window) {
  if (!window)
    return NO;
  return (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

// Ensure clearColorCache is initialized
static inline NSColor *getClearColor(void) {
  if (!clearColorCache)
    clearColorCache = [NSColor clearColor];
  return clearColorCache;
}

// Set window transparency
static inline void setWindowTransparent(NSWindow *window) {
  window.backgroundColor = getClearColor();
  window.opaque = NO;
}

// Check if window should be modified
static inline BOOL shouldModifyWindow(NSWindow *window) {
  if (!window || !tweakEnabled)
    return NO;

  // Fail fast checks
  if (window.level != NSNormalWindowLevel)
    return NO;
  if (!(window.styleMask & NSWindowStyleMaskTitled))
    return NO;
  if (!window.contentView)
    return NO;
  if (!isFinderProcess())
    return NO;

  // EXCLUDE: Fullscreen windows
  if (isWindowFullscreen(window))
    return NO;

  // EXCLUDE: TGoToWindowController and related windows
  // Check class name first as it's faster than string containment on titles
  NSString *windowClassName = NSStringFromClass([window class]);
  if ([windowClassName isEqualToString:@"TGoToWindowController"] ||
      [windowClassName containsString:@"TGoToWindow"] ||
      [windowClassName containsString:@"GoToWindow"] ||
      [windowClassName containsString:@"Preferences"] ||
      [windowClassName containsString:@"QLPreview"] ||
      [windowClassName containsString:@"QuickLook"])
    return NO;

  // Check window controller class name
  if (window.windowController) {
    NSString *controllerClassName =
        NSStringFromClass([window.windowController class]);
    if ([controllerClassName isEqualToString:@"TGoToWindowController"] ||
        [controllerClassName containsString:@"TGoToWindow"] ||
        [controllerClassName containsString:@"GoToWindow"] ||
        [controllerClassName containsString:@"Preferences"] ||
        [controllerClassName containsString:@"QLPreview"] ||
        [controllerClassName containsString:@"QuickLook"])
      return NO;
  }

  // Check window title last (most expensive)
  NSString *title = window.title;
  if (title.length > 0) {
    if ([title containsString:@"Go to"] || [title containsString:@"Go To"] ||
        [title isEqualToString:@"Go to the Folder:"] ||
        [title isEqualToString:@"Finder Settings"])
      return NO;
  }

  if ([window isKindOfClass:[NSPanel class]])
    return NO;

  return YES;
}

static inline BOOL isAeroFinderEffectView(NSView *view) {
  return [objc_getAssociatedObject(view, &kAeroFinderEffectViewKey) boolValue];
}

// Finder owns the toolbar, path bar, and status bar backgrounds. Clearing
// anything inside these hierarchies makes file content show through the bars.
static inline BOOL isFinderChromeView(NSView *view) {
  NSView *current = view;
  while (current) {
    NSString *className = NSStringFromClass([current class]);
    if ([className containsString:@"Toolbar"] ||
        [className containsString:@"Titlebar"] ||
        [className containsString:@"StatusBar"] ||
        [className containsString:@"NSBanner"] ||
        [className containsString:@"SplitViewItemAccessory"] ||
        [className containsString:@"PathControl"] ||
        [className containsString:@"ListHeader"] ||
        [className containsString:@"TableHeader"]) {
      return YES;
    }
    current = current.superview;
  }
  return NO;
}

static void setNativeChromeBackgroundHidden(NSView *view) {
  if (!view)
    return;

  if (!objc_getAssociatedObject(view, &kAeroFinderNativeChromeStateKey)) {
    NSDictionary *state = @{
      @"hidden" : @(view.hidden),
      @"alpha" : @(view.alphaValue),
    };
    objc_setAssociatedObject(view, &kAeroFinderNativeChromeStateKey, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }

  // Finder reasserts these backgrounds during navigation and tab changes.
  // Reapply our state every maintenance pass instead of treating the
  // association as proof that the view is still hidden.
  view.hidden = YES;
  view.alphaValue = 0.0;
}

static CGFloat finderSidebarWidthInView(NSView *view, NSView *contentView,
                                        NSInteger depth) {
  if (!view || !contentView || depth > 14)
    return 0.0;

  NSString *className = NSStringFromClass([view class]);
  if ([className containsString:@"TSidebarScrollView"] && !view.hidden &&
      NSWidth(view.bounds) > 0.0) {
    NSRect sidebarRect = [view convertRect:view.bounds toView:contentView];
    return NSMaxX(sidebarRect);
  }

  for (NSView *subview in [view.subviews copy]) {
    CGFloat width = finderSidebarWidthInView(subview, contentView, depth + 1);
    if (width > 0.0)
      return width;
  }
  return 0.0;
}

static CGFloat finderSidebarWidthForWindow(NSWindow *window) {
  if (!window || !window.contentView)
    return 0.0;
  return finderSidebarWidthInView(window.contentView, window.contentView, 0);
}

static void ensureChromeEffectInHost(
    NSView *host, NSVisualEffectBlendingMode blendingMode, CGFloat alphaValue) {
  if (!host)
    return;

  AeroFinderChromeEffectView *effectView =
      objc_getAssociatedObject(host, &kAeroFinderChromeEffectViewKey);
  if (!effectView) {
    effectView = [[AeroFinderChromeEffectView alloc] initWithFrame:host.bounds];
    effectView.material = NSVisualEffectMaterialHUDWindow;
    effectView.state = NSVisualEffectStateActive;
    effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    objc_setAssociatedObject(effectView, &kAeroFinderEffectViewKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(host, &kAeroFinderChromeEffectViewKey, effectView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }

  effectView.blendingMode = blendingMode;
  effectView.state = NSVisualEffectStateActive;
  effectView.hidden = NO;
  effectView.alphaValue = alphaValue;

  NSRect effectFrame = host.bounds;
  NSString *hostClassName = NSStringFromClass([host class]);
  if ([hostClassName containsString:@"Titlebar"]) {
    CGFloat sidebarWidth = finderSidebarWidthForWindow(host.window);
    if (sidebarWidth > 0.0 && sidebarWidth < NSWidth(effectFrame)) {
      effectFrame.origin.x += sidebarWidth;
      effectFrame.size.width -= sidebarWidth;
    }
  }
  effectView.frame = effectFrame;

  if (effectView.superview != host) {
    [effectView removeFromSuperview];
    NSView *contentSubview = nil;
    for (NSView *subview in [host.subviews copy]) {
      NSString *subviewClassName = NSStringFromClass([subview class]);
      if (([hostClassName containsString:@"Titlebar"] &&
           [subviewClassName containsString:@"Toolbar"]) ||
          ([hostClassName containsString:@"ListHeader"] &&
           [subviewClassName containsString:@"ListHeaderCell"]) ||
          ([hostClassName containsString:@"StatusBar"] &&
           [subviewClassName containsString:@"StatusBarStack"]) ||
          ([hostClassName containsString:@"NSBanner"] &&
           [subviewClassName containsString:@"PathControl"])) {
        contentSubview = subview;
        break;
      }
    }

    if (contentSubview) {
      [host addSubview:effectView
            positioned:NSWindowBelow
            relativeTo:contentSubview];
    } else if (host.subviews.count > 0) {
      [host addSubview:effectView
            positioned:NSWindowBelow
            relativeTo:host.subviews.firstObject];
    } else {
      [host addSubview:effectView];
    }
  }
}

static void hideBannerBackgroundViews(NSView *bannerView) {
  for (NSView *subview in [bannerView.subviews copy]) {
    NSString *className = NSStringFromClass([subview class]);
    if ([className containsString:@"NSBannerDecorationView"] ||
        [className containsString:@"NSHardPocketView"]) {
      setNativeChromeBackgroundHidden(subview);
    }
  }
}

static void refreshChromeEffectsInView(NSView *view, NSInteger depth) {
  if (!view || depth > 14 || isAeroFinderEffectView(view))
    return;

  NSString *className = NSStringFromClass([view class]);
  if ([className containsString:@"NSTitlebarView"]) {
    for (NSView *subview in [view.subviews copy]) {
      if ([NSStringFromClass([subview class])
              containsString:@"RFVisualEffectView"]) {
        setNativeChromeBackgroundHidden(subview);
      }
    }
    ensureChromeEffectInHost(view, NSVisualEffectBlendingModeBehindWindow,
                             1.0);
  } else if ([className containsString:@"ListHeaderRowView"]) {
    for (NSView *subview in [view.subviews copy]) {
      if ([NSStringFromClass([subview class]) containsString:@"NSBannerView"])
        hideBannerBackgroundViews(subview);
    }
    ensureChromeEffectInHost(view, NSVisualEffectBlendingModeBehindWindow,
                             1.0);
  } else if ([className containsString:@"StatusBar"] &&
             ![className containsString:@"StackView"]) {
    ensureChromeEffectInHost(view, NSVisualEffectBlendingModeBehindWindow,
                             1.0);
  } else if ([className containsString:@"NSBannerView"]) {
    BOOL containsPathControl = NO;
    for (NSView *subview in [view.subviews copy]) {
      if ([NSStringFromClass([subview class]) containsString:@"PathControl"]) {
        containsPathControl = YES;
        break;
      }
    }
    if (containsPathControl) {
      hideBannerBackgroundViews(view);
      ensureChromeEffectInHost(view, NSVisualEffectBlendingModeBehindWindow,
                               1.0);
    }
  }

  if ([view isKindOfClass:[NSClipView class]] ||
      [className containsString:@"NSGlassEffectView"])
    return;

  for (NSView *subview in [view.subviews copy]) {
    refreshChromeEffectsInView(subview, depth + 1);
  }
}

static void refreshChromeEffectsForWindow(NSWindow *window) {
  if (!window || !window.contentView || !window.contentView.superview)
    return;
  refreshChromeEffectsInView(window.contentView.superview, 0);
}

static void removeChromeEffectsInView(NSView *view, NSInteger depth) {
  if (!view || depth > 14)
    return;

  NSVisualEffectView *effectView =
      objc_getAssociatedObject(view, &kAeroFinderChromeEffectViewKey);
  if (effectView) {
    [effectView removeFromSuperview];
    objc_setAssociatedObject(view, &kAeroFinderChromeEffectViewKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }

  NSDictionary *state =
      objc_getAssociatedObject(view, &kAeroFinderNativeChromeStateKey);
  if (state) {
    view.hidden = [state[@"hidden"] boolValue];
    view.alphaValue = [state[@"alpha"] doubleValue];
    objc_setAssociatedObject(view, &kAeroFinderNativeChromeStateKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }

  NSString *className = NSStringFromClass([view class]);
  if ([view isKindOfClass:[NSClipView class]] ||
      [className containsString:@"NSGlassEffectView"])
    return;

  for (NSView *subview in [view.subviews copy]) {
    removeChromeEffectsInView(subview, depth + 1);
  }
}

static void removeChromeEffectsForWindow(NSWindow *window) {
  if (!window || !window.contentView || !window.contentView.superview)
    return;
  removeChromeEffectsInView(window.contentView.superview, 0);
}

// Check if view belongs to QuickLook or WebKit
static inline BOOL isQuickLookOrWebKitView(NSView *view) {
  if (!view)
    return NO;
  NSString *className = NSStringFromClass([view class]);
  if ([className containsString:@"QL"] ||
      [className containsString:@"QuickLook"] ||
      [className containsString:@"Web"] || [className containsString:@"WebKit"])
    return YES;

  NSView *current = view;
  while (current) {
    NSString *currentClassName = NSStringFromClass([current class]);
    if ([currentClassName containsString:@"QL"] ||
        [currentClassName containsString:@"QuickLook"] ||
        [currentClassName containsString:@"Web"] ||
        [currentClassName containsString:@"WebKit"])
      return YES;
    current = current.superview;
  }
  return NO;
}

// Optimized single-pass view hierarchy processing
static void processViewHierarchy(NSView *view) {
  if (!view)
    return;
  if (isQuickLookOrWebKitView(view))
    return;
  if (view.window && !shouldModifyWindow(view.window))
    return;
  if (isAeroFinderEffectView(view))
    return;
  if (isFinderChromeView(view))
    return;

  NSString *className = NSStringFromClass([view class]);

  // 1. Handle VisualEffectViews and Background Views
  BOOL isVisualEffect = [view isKindOfClass:[NSVisualEffectView class]];
  BOOL isBackgroundClass =
      ([className isEqualToString:@"NSTitlebarBackgroundView"] ||
       [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
       [className isEqualToString:@"BackdropView"] ||
       [className hasSuffix:@"BackgroundView"]);

  if (isVisualEffect || isBackgroundClass) {
    // Hide/Remove logic
    if (isVisualEffect) {
      view.hidden = YES;
      view.alphaValue = 0.0;
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        [view removeFromSuperview];
      });
      return; // Stop processing this branch if removed
    }
  }

  // 2. Make Transparent
  if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
    @try {
      [(id)view setDrawsBackground:NO];
    } @catch (NSException *e) {
    }
  }

  NSColor *clear = getClearColor();
  if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
    @try {
      [(id)view setBackgroundColor:clear];
    } @catch (NSException *e) {
    }
  }

  // 3. Handle Sidebar/Titlebar Specifics
  BOOL isSidebarRelated = ([className containsString:@"Sidebar"] ||
                           [className containsString:@"SourceList"] ||
                           [className containsString:@"Browser"] ||
                           [className containsString:@"TNode"] ||
                           [className containsString:@"Title"] ||
                           [className containsString:@"Header"] ||
                           [className containsString:@"Section"] ||
                           [className hasSuffix:@"HeaderView"] ||
                           [className hasSuffix:@"TitleView"]);

  if (isSidebarRelated) {
    if (!view.wantsLayer)
      view.wantsLayer = YES;
    if (view.layer) {
      view.layer.backgroundColor = [clear CGColor];
      view.layer.opaque = NO;
    }
  }

  // 4. Recurse
  NSArray *subviews = [view.subviews copy];
  for (NSView *subview in subviews) {
    // If parent is sidebar related, check for specific children to hide
    if (isSidebarRelated) {
      NSString *subviewClass = NSStringFromClass([subview class]);
      if ([subview isKindOfClass:[NSVisualEffectView class]] ||
          [subviewClass hasSuffix:@"BackgroundView"] ||
          [subviewClass isEqualToString:@"BackdropView"] ||
          [subviewClass containsString:@"Background"] ||
          [subviewClass containsString:@"Fill"] ||
          [subviewClass containsString:@"Separator"]) {
        subview.hidden = YES;
        subview.alphaValue = 0.0;
        if (subview.layer)
          subview.layer.opacity = 0.0;
      }
    }

    processViewHierarchy(subview);
  }
}

// Remove known Finder background wrappers (kept for scroll view usage)
static inline void pruneImmediateBackgroundViews(NSView *view) {
  if (!view)
    return;
  if (isQuickLookOrWebKitView(view))
    return;
  NSArray *subviews = [view.subviews copy];
  for (NSView *subview in subviews) {
    if (isQuickLookOrWebKitView(subview))
      continue;
    if (isFinderChromeView(subview))
      continue;
    NSString *className = NSStringFromClass([subview class]);
    BOOL isBackgroundClass =
        ([className isEqualToString:@"NSTitlebarBackgroundView"] ||
         [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
         [className isEqualToString:@"BackdropView"]);
    if ((!isAeroFinderEffectView(subview) &&
         [subview isKindOfClass:[NSVisualEffectView class]]) ||
        isBackgroundClass) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [subview removeFromSuperview];
      });
      continue;
    }
    if ([subview isKindOfClass:[NSScrollView class]] ||
        [subview isKindOfClass:[NSClipView class]]) {
      continue;
    }
    if ([subview respondsToSelector:@selector(setDrawsBackground:)]) {
      @try {
        [(id)subview setDrawsBackground:NO];
      } @catch (NSException *e) {
      }
    }
    NSColor *clear = getClearColor();
    if ([subview respondsToSelector:@selector(setBackgroundColor:)]) {
      @try {
        [(id)subview setBackgroundColor:clear];
      } @catch (NSException *e) {
      }
    }
  }
}

static void refreshScrollStacksInView(NSView *view, NSInteger depth) {
  if (!view || depth > 3)
    return;
  if (isQuickLookOrWebKitView(view))
    return;
  if (isFinderChromeView(view))
    return;
  if ([view isKindOfClass:[NSScrollView class]]) {
    ensureTransparentScrollStack((NSScrollView *)view);
    pruneImmediateBackgroundViews(view);
  } else {
    pruneImmediateBackgroundViews(view);
  }
  if (depth == 3)
    return;
  for (NSView *subview in [view.subviews copy]) {
    refreshScrollStacksInView(subview, depth + 1);
  }
}

static void refreshScrollStacksForWindow(NSWindow *window) {
  if (!window || !window.contentView)
    return;
  refreshScrollStacksInView(window.contentView, 0);
}

// Mark window as actively scrolling
static inline void markWindowScrolling(NSWindow *window) {
  if (!window)
    return;
  if (!windowScrollTimestamps) {
    windowScrollTimestamps = [NSMutableDictionary dictionary];
  }
  NSNumber *key = @((uintptr_t)window);
  windowScrollTimestamps[key] = @(CFAbsoluteTimeGetCurrent());
}

static inline BOOL isWindowScrolling(NSWindow *window) {
  if (!window || !windowScrollTimestamps)
    return NO;
  NSNumber *key = @((uintptr_t)window);
  NSNumber *lastScroll = windowScrollTimestamps[key];
  if (!lastScroll)
    return NO;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  return (now - lastScroll.doubleValue) < kScrollActivityWindow;
}

// Lightweight refresh for scroll stacks
static inline void ensureTransparentScrollStack(NSScrollView *scrollView) {
  if (!scrollView)
    return;
  if (isQuickLookOrWebKitView(scrollView))
    return;
  NSColor *clear = getClearColor();

  if (scrollView.window) {
    markWindowScrolling(scrollView.window);
  }

  void (^applyTransparency)(NSView *) = ^(NSView *view) {
    if (!view || isQuickLookOrWebKitView(view))
      return;
    if (isFinderChromeView(view))
      return;
    if (!view.wantsLayer)
      view.wantsLayer = YES;

    if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
      @try {
        [(id)view setDrawsBackground:NO];
      } @catch (NSException *e) {
      }
    }
    if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
      @try {
        [(id)view setBackgroundColor:clear];
      } @catch (NSException *e) {
      }
    }
    if (view.layer) {
      view.layer.backgroundColor = [clear CGColor];
      view.layer.opaque = NO;
    }
  };

  void (^hideBackgroundLayer)(NSView *) = ^(NSView *view) {
    if (!view || isQuickLookOrWebKitView(view))
      return;
    if (isFinderChromeView(view))
      return;
    NSString *className = NSStringFromClass([view class]);

    BOOL isBackgroundView =
        ([view isKindOfClass:[NSVisualEffectView class]] ||
         [className isEqualToString:@"NSTitlebarBackgroundView"] ||
         [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
         [className isEqualToString:@"BackdropView"] ||
         [className hasSuffix:@"BackgroundView"]);

    if (isBackgroundView) {
      if (view.layer || view.wantsLayer) {
        if (!view.wantsLayer)
          view.wantsLayer = YES;
        view.layer.opacity = 0.0;
        view.layer.backgroundColor = [[NSColor clearColor] CGColor];
        if ([view isKindOfClass:[NSVisualEffectView class]]) {
          view.hidden = YES;
        }
      }
      if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
        @try {
          [(id)view setDrawsBackground:NO];
        } @catch (NSException *e) {
        }
      }
    } else {
      if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
        @try {
          [(id)view setDrawsBackground:NO];
        } @catch (NSException *e) {
        }
      }
    }
  };

  applyTransparency(scrollView);
  NSClipView *clipView = scrollView.contentView;
  applyTransparency(clipView);

  for (NSView *subview in scrollView.subviews) {
    hideBackgroundLayer(subview);
    applyTransparency(subview);
  }
  for (NSView *subview in clipView.subviews) {
    hideBackgroundLayer(subview);
    applyTransparency(subview);
  }

  if ([clipView isKindOfClass:[NSClipView class]]) {
    NSView *documentView = clipView.documentView;
    if ([documentView isKindOfClass:[NSVisualEffectView class]]) {
      hideBackgroundLayer(documentView);
    } else {
      applyTransparency(documentView);
      NSArray *allSubviews = [documentView.subviews copy];
      for (NSView *subview in allSubviews) {
        NSString *subviewClass = NSStringFromClass([subview class]);
        if ([subview isKindOfClass:[NSVisualEffectView class]] ||
            [subviewClass hasSuffix:@"BackgroundView"] ||
            [subviewClass isEqualToString:@"BackdropView"]) {
          hideBackgroundLayer(subview);
        }
        applyTransparency(subview);
      }
    }
  }
}

// Recursive background removal
static void forceHideBackgrounds(NSView *view) { processViewHierarchy(view); }

static void stopDisplayLinkForKey(NSNumber *key) {
  if (!windowDisplayLinks || !key)
    return;
  NSValue *linkValue = windowDisplayLinks[key];
  if (!linkValue)
    return;
  CVDisplayLinkRef link = (CVDisplayLinkRef)[linkValue pointerValue];
  if (link) {
    CVDisplayLinkStop(link);
    CVDisplayLinkRelease(link);
  }
  [windowDisplayLinks removeObjectForKey:key];
}

static void stopDisplayLinkForWindow(NSWindow *window) {
  if (!window)
    return;
  NSNumber *key = @((uintptr_t)window);
  stopDisplayLinkForKey(key);
}

static CVReturn
displayLinkCallback(CVDisplayLinkRef link, const CVTimeStamp *inNow,
                    const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn,
                    CVOptionFlags *flagsOut, void *displayLinkContext) {
  @autoreleasepool {
    NSWindow *window = (__bridge NSWindow *)displayLinkContext;
    if (!window)
      return kCVReturnSuccess;
    __weak NSWindow *weakWindow = window;

    dispatch_async(dispatch_get_main_queue(), ^{
      NSWindow *strongWindow = weakWindow;
      if (!tweakEnabled || !strongWindow || !strongWindow.contentView)
        return;
      if (!shouldModifyWindow(strongWindow))
        return;

      NSNumber *key = @((uintptr_t)strongWindow);
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      NSNumber *lastMaintenance = windowMaintenanceTimestamps[key];

      // Adaptive Polling Logic
      // FIX: Only run high-frequency maintenance during Live Resize.
      // Scrolling is handled by specific swizzles (NSClipView/NSScrollView),
      // so we don't need to burn CPU scanning the whole window 60 times a
      // second.
      BOOL isActive = strongWindow.inLiveResize;
      NSTimeInterval interval =
          isActive ? kWindowMaintenanceInterval : kWindowIdleInterval;

      if (lastMaintenance && (now - lastMaintenance.doubleValue) < interval)
        return;

      windowMaintenanceTimestamps[key] = @(now);

      // Consolidated Logic from Timer
      BEGIN_NO_ANIMATION
      setWindowTransparent(strongWindow);
      processTitlebarArea(strongWindow);
      refreshChromeEffectsForWindow(strongWindow);

      if (isActive) {
        refreshScrollStacksForWindow(strongWindow);
      } else {
        // Occasional deep clean even if idle, but less frequent?
        // For now, just do what the timer did:
        if (isWindowScrolling(strongWindow)) {
          refreshScrollStacksForWindow(strongWindow);
        }
      }

      NSVisualEffectView *effectView = effectViews[key];
      if (effectView) {
        effectView.state = NSVisualEffectStateActive;
        effectView.hidden = NO;
        effectView.alphaValue = 1.0;

        if (effectView.superview != strongWindow.contentView) {
          [effectView removeFromSuperview];
          if (strongWindow.contentView.subviews.count > 0) {
            [strongWindow.contentView
                addSubview:effectView
                positioned:NSWindowBelow
                relativeTo:strongWindow.contentView.subviews.firstObject];
          } else {
            [strongWindow.contentView addSubview:effectView];
          }
        }

        NSView *bottomView = strongWindow.contentView.subviews.firstObject;
        if (bottomView != effectView &&
            strongWindow.contentView.subviews.count > 1) {
          [effectView removeFromSuperview];
          [strongWindow.contentView
              addSubview:effectView
              positioned:NSWindowBelow
              relativeTo:strongWindow.contentView.subviews.firstObject];
          if (effectView.layer)
            effectView.layer.zPosition = -1000.0;
        }

        NSRect extendedFrame =
            NSInsetRect(strongWindow.contentView.bounds, -3, -3);
        if (!NSEqualRects(effectView.frame, extendedFrame)) {
          effectView.frame = extendedFrame;
          if (effectView.layer) {
            effectView.layer.cornerRadius = 12.0;
            effectView.layer.masksToBounds = YES;
          }
        }
      }
      END_NO_ANIMATION
    });
  }
  return kCVReturnSuccess;
}

// Process titlebar/toolbar area
static void processTitlebarArea(NSWindow *window) {
  if (!window)
    return;

  NSView *contentView = window.contentView;
  if (contentView && contentView.superview) {
    NSView *parentView = contentView.superview;
    processViewHierarchy(parentView);

    if ([window
            respondsToSelector:@selector(titlebarAccessoryViewControllers)]) {
      NSArray *accessories =
          [window performSelector:@selector(titlebarAccessoryViewControllers)];
      for (id accessory in accessories) {
        if ([accessory respondsToSelector:@selector(view)]) {
          NSView *accessoryView = [accessory performSelector:@selector(view)];
          if (accessoryView) {
            processViewHierarchy(accessoryView);
          }
        }
      }
    }
  }
}

static void startWindowMaintenance(NSWindow *window) {
  if (!window)
    return;

  // if (!windowTimers) windowTimers = [NSMutableDictionary dictionary]; //
  // Removed
  if (!windowMaintenanceTimestamps)
    windowMaintenanceTimestamps = [NSMutableDictionary dictionary];
  if (!windowDisplayLinks)
    windowDisplayLinks = [NSMutableDictionary dictionary];

  NSNumber *key = @((uintptr_t)window);

  // Ensure no legacy timer exists (just in case)
  // NSTimer *existingTimer = windowTimers[key];
  // if (existingTimer && existingTimer.valid) { [existingTimer invalidate]; }
  // [windowTimers removeObjectForKey:key];

  NSValue *existingLinkValue = windowDisplayLinks[key];
  if (!existingLinkValue) {
    CVDisplayLinkRef link = NULL;
    CVReturn linkResult = CVDisplayLinkCreateWithActiveCGDisplays(&link);
    if (linkResult == kCVReturnSuccess && link) {
      CVDisplayLinkSetOutputCallback(link, displayLinkCallback,
                                     (__bridge void *)window);
      CVDisplayLinkStart(link);
      windowDisplayLinks[key] = [NSValue valueWithPointer:link];
    } else if (link) {
      CVDisplayLinkRelease(link);
    }
  }
}

static void applyHUDEffect(NSWindow *window) {
  if (!shouldModifyWindow(window))
    return;

  setWindowTransparent(window);
  processTitlebarArea(window);
  refreshChromeEffectsForWindow(window);

  NSView *contentView = window.contentView;
  if (!contentView)
    return;

  NSNumber *key = @((uintptr_t)window);
  NSVisualEffectView *effectView = effectViews[key];

  if (!effectView) {
    NSRect extendedFrame = NSInsetRect(contentView.bounds, -3, -3);
    AeroFinderEffectView *managedEffectView =
        [[AeroFinderEffectView alloc] initWithFrame:extendedFrame];
    managedEffectView.ownerWindow = window;
    managedEffectView.allowsReattachment = YES;
    effectView = managedEffectView;
    effectView.material = NSVisualEffectMaterialHUDWindow;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state = NSVisualEffectStateActive;
    effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    effectView.wantsLayer = YES;
    if (effectView.layer) {
      effectView.layer.cornerRadius = 12.0;
      effectView.layer.masksToBounds = YES;
    }
    objc_setAssociatedObject(effectView, &kAeroFinderEffectViewKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    effectViews[key] = effectView;
    NSLog(@"[AeroFinder] Created always-active HUD NSVisualEffectView");
  }

  processViewHierarchy(contentView);

  if (!effectView.superview) {
    if (contentView.subviews.count > 0) {
      [contentView addSubview:effectView
                   positioned:NSWindowBelow
                   relativeTo:contentView.subviews.firstObject];
    } else {
      [contentView addSubview:effectView];
    }
    if (effectView.layer)
      effectView.layer.zPosition = -1000.0;
  } else {
    NSView *bottomView = contentView.subviews.firstObject;
    if (bottomView != effectView && contentView.subviews.count > 1) {
      [effectView removeFromSuperview];
      [contentView addSubview:effectView
                   positioned:NSWindowBelow
                   relativeTo:contentView.subviews.firstObject];
      if (effectView.layer)
        effectView.layer.zPosition = -1000.0;
    }
  }

  NSRect extendedFrame = NSInsetRect(contentView.bounds, -3, -3);
  if (!NSEqualRects(effectView.frame, extendedFrame)) {
    BEGIN_NO_ANIMATION
    effectView.frame = extendedFrame;
    if (effectView.layer) {
      effectView.layer.cornerRadius = 12.0;
      effectView.layer.masksToBounds = YES;
    }
    END_NO_ANIMATION
  }

  startWindowMaintenance(window);
}

static void removeHUDEffect(NSWindow *window) {
  NSNumber *key = @((uintptr_t)window);
  // NSTimer *timer = windowTimers[key];
  // if (timer && timer.valid) {
  //   [timer invalidate];
  //   [windowTimers removeObjectForKey:key];
  // }

  stopDisplayLinkForWindow(window);
  [windowMaintenanceTimestamps removeObjectForKey:key];
  removeChromeEffectsForWindow(window);

  if (!effectViews)
    return;
  NSVisualEffectView *effectView = effectViews[key];
  if (effectView) {
    if ([effectView isKindOfClass:[AeroFinderEffectView class]]) {
      ((AeroFinderEffectView *)effectView).allowsReattachment = NO;
    }
    [effectView removeFromSuperview];
    [effectViews removeObjectForKey:key];
  }

  window.backgroundColor = [NSColor windowBackgroundColor];
  window.opaque = YES;
}

static void updateAllWindows(void) {
  for (NSWindow *window in [NSApplication sharedApplication].windows) {
    if (tweakEnabled)
      applyHUDEffect(window);
    else
      removeHUDEffect(window);
  }
}

#pragma mark - NSWindow Swizzles

// Swizzles are grouped under "AeroFinderGroup" and NOT applied at +load
ZKSwizzleInterfaceGroup(_AeroFinder_NSWindow, NSWindow, NSObject,
                        AeroFinderGroup) @implementation _AeroFinder_NSWindow

- (void)close {
  NSWindow *window = (NSWindow *)self;
  if (shouldModifyWindow(window)) {
    removeHUDEffect(window);
  }
  ZKOrig(void);
}

- (id)initWithContentRect:(NSRect)rect
                styleMask:(NSWindowStyleMask)style
                  backing:(NSBackingStoreType)backing
                    defer:(BOOL)flag {
  id result = ZKOrig(id, rect, style, backing, flag);
  if (result && tweakEnabled) {
    NSWindow *window = (NSWindow *)result;
    // V1 Safe Logic: Delay application until runloop settles
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          if (window && window.contentView && shouldModifyWindow(window)) {
            applyHUDEffect(window);
          }
        });
  }
  return result;
}

- (void)orderFront:(id)sender {
  NSWindow *window = (NSWindow *)self;
  if (tweakEnabled && shouldModifyWindow(window)) {
    applyHUDEffect(window);
  }
  ZKOrig(void, sender);
}

- (void)makeKeyAndOrderFront:(id)sender {
  NSWindow *window = (NSWindow *)self;
  if (tweakEnabled && shouldModifyWindow(window)) {
    applyHUDEffect(window);
  }
  ZKOrig(void, sender);
}

- (void)becomeKeyWindow {
  NSWindow *window = (NSWindow *)self;
  if (tweakEnabled && shouldModifyWindow(window)) {
    applyHUDEffect(window);
  }
  ZKOrig(void);
}

- (void)setContentView:(NSView *)contentView {
  ZKOrig(void, contentView);
  NSWindow *window = (NSWindow *)self;
  if (tweakEnabled && shouldModifyWindow(window)) {
    // V1 Safe Logic: Wait for content view layout
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          if (window && window.contentView && shouldModifyWindow(window)) {
            applyHUDEffect(window);
          }
        });
  }
}

- (void)setFrame:(NSRect)frameRect display:(BOOL)flag {
  NSWindow *window = (NSWindow *)self;

  if (tweakEnabled && shouldModifyWindow(window)) {
    BEGIN_NO_ANIMATION
    setWindowTransparent(window);
    END_NO_ANIMATION
  }

  ZKOrig(void, frameRect, flag);

  if (tweakEnabled && shouldModifyWindow(window)) {
    NSNumber *key = @((uintptr_t)window);
    NSVisualEffectView *effectView = effectViews[key];
    if (effectView && effectView.superview && window.contentView) {
      BEGIN_NO_ANIMATION
      NSRect extendedFrame = NSInsetRect(window.contentView.bounds, -3, -3);
      effectView.frame = extendedFrame;
      if (effectView.layer) {
        effectView.layer.cornerRadius = 12.0;
        effectView.layer.masksToBounds = YES;
      }
      setWindowTransparent(window);
      dispatch_async(dispatch_get_main_queue(), ^{
        forceHideBackgrounds(window.contentView);
      });
      END_NO_ANIMATION
    }
  }
}

- (void)setBackgroundColor:(NSColor *)color {
  NSWindow *window = (NSWindow *)self;
  if (tweakEnabled && shouldModifyWindow(window)) {
    ZKOrig(void, [NSColor clearColor]);
  } else {
    ZKOrig(void, color);
  }
}

- (void)setOpaque:(BOOL)opaque {
  NSWindow *window = (NSWindow *)self;
  if (tweakEnabled && shouldModifyWindow(window)) {
    ZKOrig(void, NO);
  } else {
    ZKOrig(void, opaque);
  }
}

- (void)setStyleMask:(NSWindowStyleMask)styleMask {
  NSWindow *window = (NSWindow *)self;
  BOOL wasFullscreen = isWindowFullscreen(window);

  ZKOrig(void, styleMask);

  if (!tweakEnabled || !isFinderProcess() || !window)
    return;

  BOOL isFullscreen = isWindowFullscreen(window);

  if (!wasFullscreen && isFullscreen) {
    removeHUDEffect(window);
    window.backgroundColor = [NSColor windowBackgroundColor];
    window.opaque = YES;
  } else if (wasFullscreen && !isFullscreen) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!shouldModifyWindow(window))
        return;
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            if (!window || isWindowFullscreen(window) ||
                !shouldModifyWindow(window))
              return;
            applyHUDEffect(window);
          });
    });
  }
}

static void handleLiveResize(NSWindow *window) {
  BEGIN_NO_ANIMATION
  setWindowTransparent(window);
  dispatch_async(dispatch_get_main_queue(), ^{
    forceHideBackgrounds(window.contentView);
  });
  END_NO_ANIMATION
}

- (void)viewWillStartLiveResize {
  NSWindow *window = (NSWindow *)self;
  if (tweakEnabled && shouldModifyWindow(window))
    handleLiveResize(window);
  ZKOrig(void);
}

- (void)viewDidEndLiveResize {
  NSWindow *window = (NSWindow *)self;
  if (tweakEnabled && shouldModifyWindow(window))
    handleLiveResize(window);
  ZKOrig(void);
}

@end

#pragma mark - NSClipView Swizzles

ZKSwizzleInterfaceGroup(_AeroFinder_NSClipView, NSClipView, NSObject,
                        AeroFinderGroup) @implementation _AeroFinder_NSClipView

- (void)setBoundsOrigin:(NSPoint)newOrigin {
  NSClipView *clipView = (NSClipView *)self;
  if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
    BEGIN_NO_ANIMATION
    ensureTransparentScrollStack((NSScrollView *)clipView.superview);
    END_NO_ANIMATION
  }
  ZKOrig(void, newOrigin);
}

- (void)setNeedsDisplay:(BOOL)flag {
  NSClipView *clipView = (NSClipView *)self;
  if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window))
    return;
  ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
  NSClipView *clipView = (NSClipView *)self;
  if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window))
    return;
  ZKOrig(void, rect);
}

- (void)scrollToPoint:(NSPoint)newOrigin {
  NSClipView *clipView = (NSClipView *)self;
  if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
    BEGIN_NO_ANIMATION
    ensureTransparentScrollStack((NSScrollView *)clipView.superview);
    END_NO_ANIMATION
  }
  ZKOrig(void, newOrigin);
}

@end

#pragma mark - NSScrollView Swizzles

ZKSwizzleInterfaceGroup(_AeroFinder_NSScrollView, NSScrollView, NSObject,
                        AeroFinderGroup)
    @implementation _AeroFinder_NSScrollView

- (void)reflectScrolledClipView:(NSClipView *)clipView {
  ZKOrig(void, clipView);
  NSScrollView *scrollView = (NSScrollView *)self;
  if (tweakEnabled && scrollView.window &&
      shouldModifyWindow(scrollView.window)) {
    BEGIN_NO_ANIMATION
    ensureTransparentScrollStack(scrollView);
    END_NO_ANIMATION
  }
}

- (void)tile {
  NSScrollView *scrollView = (NSScrollView *)self;
  if (tweakEnabled && scrollView.window &&
      shouldModifyWindow(scrollView.window)) {
    BEGIN_NO_ANIMATION
    ensureTransparentScrollStack(scrollView);
    END_NO_ANIMATION
  }
  ZKOrig(void);
  if (tweakEnabled && scrollView.window &&
      shouldModifyWindow(scrollView.window)) {
    refreshChromeEffectsForWindow(scrollView.window);
  }
}

- (void)setNeedsDisplay:(BOOL)flag {
  NSScrollView *scrollView = (NSScrollView *)self;
  if (tweakEnabled && scrollView.window &&
      shouldModifyWindow(scrollView.window))
    return;
  ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
  NSScrollView *scrollView = (NSScrollView *)self;
  if (tweakEnabled && scrollView.window &&
      shouldModifyWindow(scrollView.window))
    return;
  ZKOrig(void, rect);
}

- (void)layout {
  ZKOrig(void);
  NSView *view = (NSView *)self;
  if (!tweakEnabled || !view.window || !shouldModifyWindow(view.window))
    return;
  if (view != view.window.contentView)
    return;

  NSNumber *key = @((uintptr_t)view.window);
  NSVisualEffectView *effectView = effectViews[key];
  if (!effectView || !effectView.superview)
    return;

  NSRect extendedFrame = NSInsetRect(view.bounds, -3, -3);
  BOOL needsFrameUpdate = !NSEqualRects(effectView.frame, extendedFrame);
  BOOL needsRepositioning =
      (view.subviews.firstObject != effectView && view.subviews.count > 1);

  if (needsFrameUpdate || needsRepositioning) {
    BEGIN_NO_ANIMATION
    if (needsFrameUpdate) {
      effectView.frame = extendedFrame;
      if (effectView.layer) {
        effectView.layer.cornerRadius = 12.0;
        effectView.layer.masksToBounds = YES;
      }
    }
    if (needsRepositioning) {
      [effectView removeFromSuperview];
      [view addSubview:effectView
            positioned:NSWindowBelow
            relativeTo:view.subviews.firstObject];
      if (effectView.layer)
        effectView.layer.zPosition = -1000.0;
    }
    END_NO_ANIMATION
  }
}

@end

#pragma mark - Constructor

__attribute__((constructor)) static void initAeroFinder(void) {
  @autoreleasepool {
    // 1. PROCESS CHECK
    if (!isFinderProcess()) {
      NSLog(@"[AeroFinder] Not Finder - skipping");
      return;
    }

    // 2. INITIALIZATION
    effectViews = [NSMutableDictionary dictionary];
    // windowTimers = [NSMutableDictionary dictionary]; // Removed
    windowMaintenanceTimestamps = [NSMutableDictionary dictionary];
    windowDisplayLinks = [NSMutableDictionary dictionary];
    windowScrollTimestamps = [NSMutableDictionary dictionary];

    NSLog(@"[AeroFinder] Initializing HUD effect tweak (Merged v2.2 Group)");

    // 3. ACTIVATE SWIZZLES
    // Only activate now that we know we are safely inside Finder
    ZKSwizzleGroup(AeroFinderGroup);

    // 4. UPDATE EXISTING WINDOWS
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          updateAllWindows();
        });
  }
}
