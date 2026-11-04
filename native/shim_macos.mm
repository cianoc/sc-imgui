// macOS-only parts of the shim (built only on Apple; see CMakeLists.txt).
#include "shim.h"
#include "shim_macos.h"

#include <unistd.h>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>  // imports Cocoa
#include <CoreGraphics/CoreGraphics.h>

void shim_macos_close_window(GLFWwindow *window) {
  @autoreleasepool {
    // A closing NSWindow normally animates out, driven by timers on the main
    // run loop.  After the frame loop exits nothing runs that loop (an idle
    // SBCL REPL never does), so the window would stay on screen.  Close it
    // without animation, then run one run-loop pass so its observers commit
    // the change to the window server.
    NSWindow *ns = glfwGetCocoaWindow(window);
    if (ns) [ns setAnimationBehavior:NSWindowAnimationBehaviorNone];
    glfwDestroyWindow(window);
    glfwTerminate();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false);
  }
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
