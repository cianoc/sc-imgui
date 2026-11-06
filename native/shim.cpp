// sc-imgui native shim: window/frame lifecycle and recorded asserts.
#include "shim.h"

#include <algorithm>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include "implot.h"

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#include "imgui_impl_opengl3_loader.h"  // GL function pointers shared with the backend

static int g_assert_count = 0;
static std::string g_last_assert;
static std::string g_last_error;
static std::string g_ini_path;
static GLFWwindow *g_window = nullptr;
static bool g_backends = false;
static bool g_headless = false;
// Fonts added with shim_add_font, by index.  Lisp only ever sees the indexes.
// Valid for the current ImGui context; cleared when it is destroyed.
static std::vector<ImFont *> g_fonts;
// The colour behind all windows, set by the theme.
static float g_clear_color[3] = {0.1f, 0.1f, 0.1f};
// Guards g_window against shim_wake, which other threads call: GLFW allows
// glfwPostEmptyEvent from any thread, but not concurrently with glfwTerminate.
static std::mutex g_wake_mutex;

extern "C" void sc_imgui_assert_failed(const char *expr, const char *file, int line) {
  char buf[64];
  std::snprintf(buf, sizeof buf, ":%d", line);
  g_last_assert = std::string(expr) + " @ " + file + buf;
  g_assert_count++;
}

// Destroy the window and end GLFW.
static void close_window() {
  {
    std::lock_guard<std::mutex> lock(g_wake_mutex);
    glfwDestroyWindow(g_window);
    g_window = nullptr;
  }
  glfwTerminate();
}

// Seconds to keep the run loop going after hiding the window before it may
// be destroyed (see shim_shutdown).
static const double HIDE_SETTLE = 0.5;
static double g_hidden_at = -1e9;  // glfwGetTime() of the last hide

static void hide_window() {
  glfwHideWindow(g_window);
  g_hidden_at = glfwGetTime();
}

static void configure_io() {
  ImGuiIO &io = ImGui::GetIO();
  io.ConfigErrorRecovery = true;
  io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
  // ImGuiConfigFlags_ViewportsEnable is deliberately never set.
}

static void create_contexts() {
  ImGui::CreateContext();
  ImPlot::CreateContext();
  configure_io();
}

static void destroy_contexts() {
  if (ImPlot::GetCurrentContext()) ImPlot::DestroyContext();
  if (ImGui::GetCurrentContext()) ImGui::DestroyContext();
  g_fonts.clear();
}

// Store FONT as the next index; the first becomes the default at SIZE.
static int store_font(ImFont *font, float size) {
  g_fonts.push_back(font);
  if (g_fonts.size() == 1) {
    ImGui::GetIO().FontDefault = font;
    ImGui::GetStyle().FontSizeBase = size;
  }
  return (int)g_fonts.size() - 1;
}

static int fail(const char *msg) {
  g_last_error = msg;
  return 1;
}

static void glfw_error_cb(int code, const char *desc) {
  g_last_error = std::string("GLFW error ") + std::to_string(code) + ": " + (desc ? desc : "");
}

extern "C" {

int shim_open_window(int width, int height, const char *title, const char *ini_path) {
  g_last_error.clear();
  if (g_window || g_headless) return fail("a window or headless context is already open");
  glfwSetErrorCallback(glfw_error_cb);
  if (!glfwInit()) return fail(g_last_error.empty() ? "glfwInit failed" : g_last_error.c_str());
#ifdef __APPLE__
  const char *glsl_version = "#version 150";
  glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
  glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
  glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
  glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GLFW_TRUE);
#else
  const char *glsl_version = "#version 130";
  glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
  glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
#endif
  GLFWwindow *window = glfwCreateWindow(width, height, title ? title : "sc-imgui", nullptr, nullptr);
  {
    std::lock_guard<std::mutex> lock(g_wake_mutex);
    g_window = window;
  }
  if (!g_window) {
    std::string e = g_last_error.empty() ? "glfwCreateWindow failed" : g_last_error;
    glfwTerminate();
    return fail(e.c_str());
  }
  g_hidden_at = -1e9;  // glfwGetTime restarts with each glfwInit
  glfwMakeContextCurrent(g_window);
  glfwSwapInterval(1);

  create_contexts();
  ImGuiIO &io = ImGui::GetIO();
  if (ini_path) {
    g_ini_path = ini_path;
    io.IniFilename = g_ini_path.c_str();
  } else {
    io.IniFilename = nullptr;
  }
  bool glfw_ok = ImGui_ImplGlfw_InitForOpenGL(g_window, true);
  if (!glfw_ok || !ImGui_ImplOpenGL3_Init(glsl_version)) {
    if (glfw_ok) ImGui_ImplGlfw_Shutdown();
    destroy_contexts();
    close_window();
    return fail("ImGui backend initialisation failed");
  }
  g_backends = true;
  return 0;
}

int shim_should_close(void) {
  return (!g_window || glfwWindowShouldClose(g_window)) ? 1 : 0;
}

// begin/end_frame are no-ops unless shim_open_window succeeded.
void shim_begin_frame(void) {
  if (!g_backends) return;
  glfwPollEvents();
  ImGui_ImplOpenGL3_NewFrame();
  ImGui_ImplGlfw_NewFrame();
  ImGui::NewFrame();
}

void shim_end_frame(void) {
  if (!g_backends) return;
  ImGui::Render();
  int w = 0, h = 0;
  glfwGetFramebufferSize(g_window, &w, &h);
  glViewport(0, 0, w, h);
  glClearColor(g_clear_color[0], g_clear_color[1], g_clear_color[2], 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
  glfwSwapBuffers(g_window);
}

void shim_shutdown(void) {
  if (g_window) {
    // Take the window off screen before destroying it.  On macOS hiding
    // animates for about 0.25 s, driven by the main run loop; a window
    // destroyed before that ends stays on screen, and nothing runs the run
    // loop after the frame loop exits.  So hide it (if shown) and pump events
    // until HIDE_SETTLE seconds after it was hidden, here or by an earlier
    // shim_hide_window.  The time is measured: 0.2 s was too short, 0.3 s
    // enough.  A loop of fixed passes is no use: each returns at once while
    // events are queued.
    if (glfwGetWindowAttrib(g_window, GLFW_VISIBLE)) hide_window();
    const double end = std::max(g_hidden_at + HIDE_SETTLE, glfwGetTime() + 0.02);
    for (double now = glfwGetTime(); now < end; now = glfwGetTime())
      glfwWaitEventsTimeout(end - now);
  }
  if (g_backends) {
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    g_backends = false;
  }
  destroy_contexts();
  if (g_window) close_window();
  g_headless = false;
}

void shim_show_window(const char *title) {
  if (!g_window) return;
  if (title) glfwSetWindowTitle(g_window, title);
  glfwShowWindow(g_window);
}

void shim_hide_window(void) {
  if (!g_window) return;
  ImGuiIO &io = ImGui::GetIO();
  if (io.IniFilename) ImGui::SaveIniSettingsToDisk(io.IniFilename);
  hide_window();
  glfwSetWindowShouldClose(g_window, GLFW_FALSE);
}

int shim_wait_events(double timeout) {
  if (!g_window) return -1;
  glfwWaitEventsTimeout(timeout);
  return 0;
}

void shim_wake(void) {
  std::lock_guard<std::mutex> lock(g_wake_mutex);
  if (g_window) glfwPostEmptyEvent();
}

int shim_window_visible(void) {
  if (!g_window) return -1;
  return glfwGetWindowAttrib(g_window, GLFW_VISIBLE) ? 1 : 0;
}

int shim_test_request_close(void) {
  std::lock_guard<std::mutex> lock(g_wake_mutex);
  if (!g_window) return -1;
  glfwSetWindowShouldClose(g_window, GLFW_TRUE);
  glfwPostEmptyEvent();
  return 0;
}

const char *shim_last_error(void) { return g_last_error.c_str(); }

int shim_add_font(const char *path, float size) {
  g_last_error.clear();
  if (!ImGui::GetCurrentContext()) {
    g_last_error = "no ImGui context";
    return -1;
  }
  ImFontAtlas *atlas = ImGui::GetIO().Fonts;
  ImFont *font = nullptr;
  if (path) {
    ImFontConfig cfg;
    cfg.Flags |= ImFontFlags_NoLoadError;  // a missing file returns NULL, no assert
    // A file that is not a font still trips an ImGui user-error assert (it
    // then rolls the font back and returns NULL).  That is reported here, as
    // a failed load, so take it back out of the assert record.
    const int asserts = g_assert_count;
    const std::string last_assert = g_last_assert;
    font = atlas->AddFontFromFileTTF(path, size, &cfg);
    if (!font) {
      g_last_error = std::string("could not load font file ") + path;
      if (g_assert_count != asserts) {
        g_last_error += " (" + g_last_assert + ")";
        g_assert_count = asserts;
        g_last_assert = last_assert;
      }
    }
  } else if (!g_fonts.empty()) {
    g_last_error = "no font file given";
    return -1;
  }
  if (font) return store_font(font, size);
  if (g_fonts.empty()) {
    // The default must be a font: ImGui's built-in scalable one.
    ImFontConfig cfg;
    cfg.SizePixels = size;
    store_font(atlas->AddFontDefaultVector(&cfg), size);
    return path ? -1 : 0;
  }
  return -1;
}

void shim_set_clear_color(float r, float g, float b) {
  g_clear_color[0] = r;
  g_clear_color[1] = g;
  g_clear_color[2] = b;
}

void shim_push_font(int index, float size) {
  ImFont *font = (index >= 0 && index < (int)g_fonts.size()) ? g_fonts[index] : nullptr;
  ImGui::PushFont(font, size);
}

int shim_headless_create(int width, int height) {
  g_last_error.clear();
  if (g_window || g_headless) return fail("a window or headless context is already open");
  create_contexts();
  ImGuiIO &io = ImGui::GetIO();
  io.IniFilename = nullptr;
  io.DisplaySize = ImVec2((float)width, (float)height);
  io.DeltaTime = 1.0f / 60.0f;
  // ImGui 1.92+ builds the font atlas lazily on the first NewFrame as long as
  // the "backend" supports dynamic textures; there is no renderer here, so
  // claim that and leave the texture updates unconsumed.
  io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
  // The OpenGL3 backend sets this in production, so draw lists may exceed 64k
  // vertices there.  Without it ImGui asserts on 16-bit indices; match production.
  io.BackendFlags |= ImGuiBackendFlags_RendererHasVtxOffset;
  g_headless = true;
  return 0;
}

void shim_headless_destroy(void) {
  destroy_contexts();
  g_headless = false;
}

int shim_assert_count(void) { return g_assert_count; }
const char *shim_last_assert(void) { return g_last_assert.c_str(); }
void shim_clear_asserts(void) {
  g_assert_count = 0;
  g_last_assert.clear();
}

}  // extern "C"

