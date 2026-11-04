// Internal to the shim: macOS-only helpers implemented in shim_macos.mm.
#ifndef SC_IMGUI_SHIM_MACOS_H
#define SC_IMGUI_SHIM_MACOS_H

struct GLFWwindow;

// Destroy WINDOW and terminate GLFW so that the window leaves the screen
// without the main run loop running afterwards.
void shim_macos_close_window(GLFWwindow *window);

#endif
