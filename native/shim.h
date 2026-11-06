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
void        shim_shutdown(void);              /* hides the window and pumps events so it leaves the screen, then destroys backends, ImPlot and ImGui contexts, window */
void        shim_show_window(const char *title); /* main thread; title NULL = keep the current one */
void        shim_hide_window(void);           /* main thread; saves the ini file, hides the window, clears should-close */
int         shim_wait_events(double timeout); /* main thread; wait up to timeout seconds for events; -1 = no window */
void        shim_wake(void);                  /* any thread; wakes shim_wait_events; no-op without a window */
const char *shim_last_error(void);            /* message for the last nonzero return, or "" */
int         shim_add_font(const char *path, float size); /* main thread; add a font file (NULL = none) at SIZE px; returns its index, or -1 with shim_last_error.  The first font is the default and sets the base size; if it fails (or PATH is NULL) the built-in font takes index 0 */
void        shim_set_clear_color(float r, float g, float b); /* main thread; colour behind all windows, 0-1 components (default 0.1 grey); kept across windows */
void        shim_push_font(int index, float size);       /* main thread; PushFont the font at INDEX at SIZE px (0 = keep size); -1 or no such font pushes NULL, so PopFont balances */
int         shim_headless_create(int width, int height); /* contexts, DisplaySize, DeltaTime 1/60, font atlas built; 0 = ok */
void        shim_headless_destroy(void);
int         shim_assert_count(void);
const char *shim_last_assert(void);           /* "expr @ file:line" */
void        shim_clear_asserts(void);
int         shim_window_visible(void);        /* main thread; 1 visible, 0 hidden, -1 no window */
int         shim_test_request_close(void);    /* tests, any thread: set the should-close flag as the close button does; 0 = set, -1 = no window */

#ifdef __cplusplus
}
#endif

#endif
