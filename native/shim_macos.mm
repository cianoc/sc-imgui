// macOS-only parts of the shim (built only on Apple; see CMakeLists.txt).
#include "shim.h"
#include "shim_macos.h"

#include <unistd.h>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>  // imports Cocoa
#include <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

void shim_macos_close_window(GLFWwindow *window) {
  @autoreleasepool {
    // A closing NSWindow normally animates out, driven by timers on the main
    // run loop.  After the frame loop exits nothing runs that loop (an idle
    // SBCL REPL never does), so the window would stay on screen.  Close it
    // without animation.
    //
    // Shortly after a click on the title-bar close button, AppKit defers the
    // window's removal into the main thread's implicit Core Animation
    // transaction rather than sending it to the window server at once.  That
    // transaction is normally committed by a run-loop observer, and a single
    // zero-timeout pass does not reliably commit it, so the window stayed on
    // screen (busy cursor) until something ran the run loop again.  Commit it
    // explicitly, then run one pass for anything else the observers do.
    NSWindow *ns = glfwGetCocoaWindow(window);
    if (ns) [ns setAnimationBehavior:NSWindowAnimationBehaviorNone];
    glfwDestroyWindow(window);
    glfwTerminate();
    [CATransaction flush];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false);
  }
}

int shim_macos_perform_close(GLFWwindow *window) {
  if (!window) return -1;
  @autoreleasepool {
    NSWindow *ns = glfwGetCocoaWindow(window);
    if (!ns) return -1;
    // AppKit's own close-button path: highlights the button, asks the
    // delegate (GLFW's windowShouldClose:), which sets the close flag.
    [ns performClose:nil];
  }
  return 0;
}

int shim_onscreen_window_count(void) {
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  if (!list) return -1;
  const long self = (long)getpid();
  int count = 0;
  for (CFIndex i = 0, n = CFArrayGetCount(list); i < n; i++) {
    CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
    CFNumberRef pid = (CFNumberRef)CFDictionaryGetValue(info, kCGWindowOwnerPID);
    long value = 0;
    if (pid && CFNumberGetValue(pid, kCFNumberLongType, &value) && value == self) count++;
  }
  CFRelease(list);
  return count;
}
