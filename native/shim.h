/* C API of the sc-imgui native shim. Includable from C and C++. */
#ifndef SC_IMGUI_SHIM_H
#define SC_IMGUI_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

int         shim_open_window(int width, int height, const char *title, const char *ini_path); /* 0 = ok; ini_path NULL = no ini file; string is copied */
int         shim_should_close(void);          /* 1 when the user closed the window */
void        shim_begin_frame(void);           /* glfwPollEvents + backend NewFrame + igNewFrame */
void        shim_end_frame(void);             /* igRender + GL draw + glfwSwapBuffers */
void        shim_shutdown(void);              /* destroys backends, ImPlot and ImGui contexts, window */
const char *shim_last_error(void);            /* message for the last nonzero return, or "" */
int         shim_headless_create(int width, int height); /* contexts, DisplaySize, DeltaTime 1/60, font atlas built; 0 = ok */
void        shim_headless_destroy(void);
int         shim_assert_count(void);
const char *shim_last_assert(void);           /* "expr @ file:line" */
void        shim_clear_asserts(void);
int         shim_onscreen_window_count(void);  /* on-screen windows owned by this process; -1 where unavailable (non-macOS) */

#ifdef __cplusplus
}
#endif

#endif
