#include "ios_scene.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static UIWindowScene* g_scene = nil;
static UIWindow* g_pendingWindow = nil;

// Shown as soon as the scene connects, so iOS can end the launch screen right away instead of keeping it up
// until the game creates its window, which happens much later.
static UIWindow* g_placeholderWindow = nil;

static void HidePlaceholderWindow()
{
    if (g_placeholderWindow == nil)
        return;

    g_placeholderWindow.hidden = YES;
    g_placeholderWindow = nil;
}

// The game's loop never lets the run loop idle, which is when UIKit normally lays out views and commits
// them to the screen. Without forcing it, the Metal view keeps the portrait size it was created with.
static void LayOutAndCommit(UIWindow* window)
{
    [window layoutIfNeeded];
    [CATransaction flush];
}

// The scene's bounds change when it rotates to landscape, so the window has to follow them. Only while the
// app is active: in the background the renderer is parked and UIKit lays the views out for its snapshots.
// The game only runs in landscape, so portrait bounds are never applied.
static void SyncWindowToScene(UIWindow* window)
{
    if (window == nil || g_scene == nil)
        return;

    CGRect bounds = g_scene.coordinateSpace.bounds;
    bool active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    bool portrait = bounds.size.width < bounds.size.height;
    if (!active || portrait)
    {
        [CATransaction flush];
        return;
    }

    if (!CGRectEqualToRect(window.frame, bounds))
        window.frame = bounds;

    // SDL swaps in its Metal view as the root view controller's view after the window is set up. UIKit doesn't
    // resize a swapped-in root view when the scene rotates, and sets it back to the portrait size whenever the
    // app goes to the background, so keep it at the window's bounds.
    UIView* rootView = window.rootViewController.view;
    if (rootView != nil && !CGRectEqualToRect(rootView.frame, window.bounds))
        rootView.frame = window.bounds;

    LayOutAndCommit(window);
}

static void AttachToScene(UIWindow* window)
{
    if (window == nil || g_scene == nil)
        return;

    if (window.windowScene != g_scene)
        window.windowScene = g_scene;

    [window makeKeyAndVisible];

    if (window != g_placeholderWindow)
        HidePlaceholderWindow();

    SyncWindowToScene(window);
}

// Windows created by SDL (the game window, and the extra window message boxes use) don't know about scenes,
// and a window without a scene is never shown. Attach every new window to the app's scene.
@implementation UIWindow (UnleashedScene)

+ (void)load
{
    Class windowClass = [UIWindow class];
    SEL originalSelector = @selector(initWithFrame:);
    SEL replacementSelector = @selector(unleashed_initWithFrame:);
    Method original = class_getInstanceMethod(windowClass, originalSelector);
    Method replacement = class_getInstanceMethod(windowClass, replacementSelector);

    // If UIWindow only inherits initWithFrame: from UIView, add it to UIWindow instead of swapping UIView's.
    if (class_addMethod(windowClass, originalSelector, method_getImplementation(replacement), method_getTypeEncoding(replacement)))
        class_replaceMethod(windowClass, replacementSelector, method_getImplementation(original), method_getTypeEncoding(original));
    else
        method_exchangeImplementations(original, replacement);
}

- (instancetype)unleashed_initWithFrame:(CGRect)frame
{
    // Calls the original initWithFrame:, as the implementations are swapped.
    UIWindow* window = [self unleashed_initWithFrame:frame];

    if (window != nil && window.windowScene == nil && g_scene != nil)
        window.windowScene = g_scene;

    return window;
}

@end

// Referenced by name from UIApplicationSceneManifest in Info.plist.
@interface UnleashedSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow* window;
@end

@implementation UnleashedSceneDelegate

- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)connectionOptions
{
    if (![scene isKindOfClass:[UIWindowScene class]])
        return;

    g_scene = (UIWindowScene*)scene;

    // SDL may have created its window before the scene connected.
    // Otherwise, show a black window until it does.
    UIWindow* window = g_pendingWindow;
    if (window == nil)
    {
        id<UIApplicationDelegate> appDelegate = UIApplication.sharedApplication.delegate;
        if ([appDelegate respondsToSelector:@selector(window)])
            window = appDelegate.window;
    }

    if (window != nil)
    {
        self.window = window;
        AttachToScene(window);
    }
    else
    {
        UIViewController* viewController = [[UIViewController alloc] init];
        viewController.view.backgroundColor = [UIColor blackColor];

        g_placeholderWindow = [[UIWindow alloc] initWithWindowScene:g_scene];
        g_placeholderWindow.backgroundColor = [UIColor blackColor];
        g_placeholderWindow.rootViewController = viewController;

        self.window = g_placeholderWindow;
        [g_placeholderWindow makeKeyAndVisible];
        [CATransaction flush];
    }
}

- (void)sceneDidDisconnect:(UIScene*)scene
{
    if (scene == g_scene)
        g_scene = nil;
}

- (void)windowScene:(UIWindowScene*)windowScene
    didUpdateCoordinateSpace:(id<UICoordinateSpace>)previousCoordinateSpace
    interfaceOrientation:(UIInterfaceOrientation)previousInterfaceOrientation
    traitCollection:(UITraitCollection*)previousTraitCollection
{
    SyncWindowToScene(g_pendingWindow);
}

@end

namespace ios_scene
{
    void WaitForScene()
    {
        // The scene connects while the run loop runs, shortly after launch. Wait for it (up to a few
        // seconds) so that windows and message boxes created at startup can be shown.
        for (int i = 0; i < 300 && g_scene == nil; i++)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }

    void FlushDisplayChanges()
    {

        if (g_pendingWindow != nil)
            SyncWindowToScene(g_pendingWindow);
        else
            [CATransaction flush];
    }

    void AttachWindow(void* uiWindow)
    {
        UIWindow* window = (__bridge UIWindow*)uiWindow;
        if (window == nil)
            return;

        // Keeps the window alive until the scene connects and adopts it.
        g_pendingWindow = window;

        AttachToScene(window);

        if (g_scene != nil && [g_scene.delegate isKindOfClass:[UnleashedSceneDelegate class]])
            ((UnleashedSceneDelegate*)g_scene.delegate).window = window;
    }
}
