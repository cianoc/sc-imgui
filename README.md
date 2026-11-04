# sc-imgui

Common Lisp (SBCL) binding to Dear ImGui and ImPlot.

## Native shim

`make native` builds `native/build/libsc_imgui_shim.{dylib,so}` (ImGui, ImPlot,
cimgui, cimplot, GLFW and the shim in one shared library) and runs the C tests.

```
git submodule update --init native/third_party/{imgui,cimgui,implot,cimplot,glfw}
make native
```

Do not initialise the nested submodules inside `cimgui/` or `cimplot/`: only the
top-level `native/third_party/imgui` and `native/third_party/implot` are compiled
(`cimgui.cpp` and `cimplot.cpp` find them through an include directory).

### Pinned submodules

| Submodule | Commit | Commit date | Notes |
|-----------|--------|-------------|-------|
| imgui | `d88f238d1d363ef387382b2e29ad12cf96f826ac` | 2026-10-15 | docking branch; the ImGui commit cimgui `5d7cc7e` was generated from |
| cimgui | `5d7cc7e12de9a868bbecc00ce2ed74e58d266f1c` | 2026-10-16 | `docking_inter`, "pull imgui docking 1.93 and generate" |
| implot | `72de27832d1e6299bcc930ce01073d899d420392` | 2026-10-25 | the ImPlot commit cimplot `c809ff2` points at |
| cimplot | `c809ff29c84813fe1cdc8a0c069145ef2285f22a` | 2026-10-26 | "pull v1.1 and generate" |
| glfw | `7b6aead9fb88b3623e3b3725ebb42670cbe4c579` | 2024-02-23 | tag 3.4 |

cimgui's `docking_inter` HEAD (`2a6a93f`, 2026-10-18) is not used: its generated
output was produced from non-docking ImGui (no `ImGuiConfigFlags_DockingEnable`,
no dock API), as its own commit message half-admits. `5d7cc7e` is the newest
commit whose output contains the docking API.
