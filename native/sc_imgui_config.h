/* Dear ImGui user config: asserts are recorded, never abort. */
#pragma once

#ifdef __cplusplus
extern "C" void sc_imgui_assert_failed(const char *expr, const char *file, int line);
#else
void sc_imgui_assert_failed(const char *expr, const char *file, int line);
#endif

#define IM_ASSERT(e) do { if (!(e)) sc_imgui_assert_failed(#e, __FILE__, __LINE__); } while (0)
