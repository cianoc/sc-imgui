.PHONY: native bindings test smoke
native:
	cmake -S native -B native/build -DCMAKE_BUILD_TYPE=Release
	cmake --build native/build
	ctest --test-dir native/build --output-on-failure

# Regenerate src/bindings/{imgui,implot}.lisp from the cimgui/cimplot JSON.
bindings:
	sbcl --noinform --non-interactive \
	  --eval '(ql:quickload :sc-imgui/generator :silent t)' \
	  --eval '(sc-imgui.generator:generate-bindings)'

# make test            run every suite
# make test SUITE=name run one suite (generator, bindings, registry, ...)
test:
	SUITE=$(SUITE) sbcl --noinform --non-interactive --load tests/run.lisp

# Opens a real window (needs a display; on Linux CI use xvfb-run).
smoke:
	sbcl --noinform --non-interactive --load tests/smoke.lisp
