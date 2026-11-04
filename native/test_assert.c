/* asserts must be recorded, never abort */
#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"
#include "shim.h"

int main(void) {
  if (shim_headless_create(800, 600) != 0) return 1;
  igNewFrame();
  igEnd();                         /* End without Begin: misuse */
  igRender();
  if (shim_assert_count() < 1) return 2;
  if (shim_last_assert()[0] == '\0') return 3;
  shim_clear_asserts();
  if (shim_assert_count() != 0) return 4;
  shim_headless_destroy();
  return 0;
}
