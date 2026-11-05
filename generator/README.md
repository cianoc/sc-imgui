# The binding generator

`make bindings` reads the JSON that cimgui and cimplot generated
(`native/third_party/{cimgui,cimplot}/generator/output/`). It writes
`src/bindings/imgui.lisp` (package `%imgui`) and `src/bindings/implot.lisp`
(package `%implot`). Both files are committed, so loading the system never runs
the generator.

| File | Role |
|------|------|
| `model.lisp` | Loads the three JSON files into plists. Instantiates the templates that cimgui flattens. |
| `names.lisp` | `c-name->lisp-name`: removes the prefix, splits CamelCase, turns `_` into `-` and lowercases. `*lisp-name-overrides*`: renames chosen C names to resolve collisions. |
| `types.lisp` | `c-type->cffi`: maps C types to CFFI types. |
| `emit.lisp` | `emit-forms`: turns a model into `defcstruct`, `defconstant` and `defcfun`/`defun` forms. |
| `main.lisp` | `generate-bindings`: runs both libraries, then writes the two files. |

## Skipped functions

`emit-forms` returns the functions it skips, each with a reason, and `make bindings` prints how many there are. A function is skipped when it is:

- variadic;
- templated;
- using a return type or argument type it can't map;
- given two arguments with the same Lisp name.

## Gotchas

### Name collisions are errors

The naming rule erases some differences. `igFooIO` and `igFoo_IO` both become `foo-io`. Every function with a C `bool` return or argument also takes a second name, `NAME-RAW`, for its raw `defcfun`, so a C function called `igFooRaw` would collide with the raw wrapper of a bool-returning `igFoo`.

If two C names map to one Lisp symbol, `emit-forms` signals `binding-name-collision`. That covers two functions, a function and another function's `NAME-RAW`, two enum constants (even with equal values), or two structs. It gathers every collision first and then signals a single error. The report gives each Lisp symbol and every C name that maps to it. From code, `binding-name-collisions` returns the list, and `collision-kind`, `collision-lisp-name` and `collision-c-names` read each entry.

`generate-bindings` emits both libraries before it writes anything. A collision in either one leaves `src/bindings/` exactly as it was. In particular, a collision in cimplot doesn't leave a regenerated `imgui.lisp` behind.

Collisions are errors because the generator used to keep the first name and skip the second. After an upgrade, an existing Lisp name could then have silently pointed at a different C function.

**Resolving a collision.** Collisions are resolved with `*lisp-name-overrides*` in `names.lisp`, an alist of `(C-NAME . LISP-NAME)` that replaces the naming rule for those C names. It's empty unless a collision has needed it.

1. **Decide which C name keeps the Lisp name.** Usually it's the one that had the name before the upgrade, because existing code relies on it. Diffing `src/bindings/` against the previous pins shows which one that is.
2. **Rename the other one** by adding an entry. Give the Lisp name in the form `c-name->lisp-name` returns. Leave out the prefix (`ig`, `ImPlot_`, `ImGui`), the `+…+` around constants, and the `-raw` suffix, because the generator adds those itself:

   ```lisp
   (defparameter *lisp-name-overrides*
     '(("igFoo_IO" . "foo-io-by-index")           ; function: foo-io stays with igFooIO
       ("ImGuiFlags_No_Title" . "flags-no-title-legacy"))) ; constant: +flags-no-title-legacy+
   ```

3. **Add a test** in `tests/test-generator.lisp` that reproduces the collision with the real C names, adding fixture entries if needed. It should check that the override resolves it. Then run `make bindings`, `make test`, and read the diff of the bindings.

How each kind of collision applies:

- **Function:** the override renames that function. For a function with a `bool` return or argument, it renames both the wrapper and its `NAME-RAW`. So for `igFooRaw` colliding with `igFoo`'s `foo-raw`, rename either `igFooRaw` or `igFoo`.
- **Constant:** rename one of the two, even when their values are equal. One may be a deprecated alias, and keeping it under its own name is a choice you can see in the code.
- **Struct:** the override applies wherever that struct is referred to (its `defcstruct`, struct fields and by-value arguments), so nothing still uses the old name.

Overrides are keyed by C name only, and both libraries share one table. If an override's C name matches nothing that either library emits, `make bindings` warns with `unused-name-override` and still writes the files. That happens when cimgui renames or drops the C name, or the generator skips it. Remove the entry, and if the C name was renamed, check whether the collision still exists under the new name.

## When the cimgui or cimplot pins move

After changing the pins (see `native/README.md`), run `make bindings`. Then:

1. If it warns with `unused-name-override`, an override no longer matches anything. Remove it as described above.
2. If it fails with `binding-name-collision`, the new JSON has introduced a collision. Resolve each collision with an override as described above. Nothing was written, so the old bindings are still in place.
3. Read the output and `git diff src/bindings/`, not just the test results. The generator tests only use hand-written fixtures, so a change to cimgui's JSON format shows up only here.
4. Run `make test`. Commit the regenerated files together with the new pins.
