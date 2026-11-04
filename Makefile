.PHONY: native
native:
	cmake -S native -B native/build -DCMAKE_BUILD_TYPE=Release
	cmake --build native/build
	ctest --test-dir native/build --output-on-failure
