// sc-imgui native shim: window/frame lifecycle and recorded asserts.
#include "shim.h"

#include <cstdio>
#include <string>

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

extern "C" void sc_imgui_assert_failed(const char *expr, const char *file, int line) {
  char buf[64];
  std::snprintf(buf, sizeof buf, ":%d", line);
  g_last_assert = std::string(expr) + " @ " + file + buf;
  g_assert_count++;
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
  g_window = glfwCreateWindow(width, height, title ? title : "sc-imgui", nullptr, nullptr);
  if (!g_window) {
    std::string e = g_last_error.empty() ? "glfwCreateWindow failed" : g_last_error;
    glfwTerminate();
    return fail(e.c_str());
  }
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
    glfwDestroyWindow(g_window);
    g_window = nullptr;
    glfwTerminate();
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
  glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
  glfwSwapBuffers(g_window);
}

void shim_shutdown(void) {
  if (g_backends) {
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    g_backends = false;
  }
  destroy_contexts();
  if (g_window) {
    glfwDestroyWindow(g_window);
    g_window = nullptr;
    glfwTerminate();
  }
  g_headless = false;
}

const char *shim_last_error(void) { return g_last_error.c_str(); }

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
