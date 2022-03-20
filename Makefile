PYODIDE_ROOT=$(abspath .)

include Makefile.envs

.PHONY=check

CC=emcc
CXX=em++


all: check \
	build/pyodide.asm.js \
	build/pyodide.js \
	build/console.html \
	build/distutils.tar \
	build/packages.json \
	build/pyodide_py.tar \
	build/test.tar \
	build/test.html \
	build/module_test.html \
	build/webworker.js \
	build/webworker_dev.js \
	build/module_webworker_dev.js
	echo -e "\nSUCCESS!"

$(CPYTHONLIB)/tzdata :
	pip install tzdata --target=$(CPYTHONLIB)

build/pyodide_py.tar: $(wildcard src/py/pyodide/*.py)  $(wildcard src/py/_pyodide/*.py)
	cd src/py && tar --exclude '*__pycache__*' -cf ../../build/pyodide_py.tar pyodide _pyodide

build/pyodide.asm.js: \
	src/core/docstring.o \
	src/core/error_handling.o \
	src/core/error_handling_cpp.o \
	src/core/hiwire.o \
	src/core/js2python.o \
	src/core/jsproxy.o \
	src/core/keyboard_interrupt.o \
	src/core/main.o  \
	src/core/pyproxy.o \
	src/core/python2js_buffer.o \
	src/core/python2js.o \
	$(wildcard src/py/lib/*.py) \
	$(CPYTHONLIB)/tzdata \
	$(CPYTHONLIB)
	date +"[%F %T] Building pyodide.asm.js..."
	[ -d build ] || mkdir build
	$(CXX) -o build/pyodide.asm.js $(filter %.o,$^) \
		$(MAIN_MODULE_LDFLAGS)
   # Strip out C++ symbols which all start __Z.
   # There are 4821 of these and they have VERY VERY long names.
   # To show some stats on the symbols you can use the following:
   # cat build/pyodide.asm.js | grep -ohE 'var _{0,5}.' | sort | uniq -c | sort -nr | head -n 20
	sed -i -E 's/var __Z[^;]*;//g' build/pyodide.asm.js
	sed -i '1i\
		"use strict";\
		let setImmediate = globalThis.setImmediate;\
		let clearImmediate = globalThis.clearImmediate;\
		let baseName, fpcGOT, dyncallGOT, fpVal, dcVal;\
	' build/pyodide.asm.js
	# Remove last 6 lines of pyodide.asm.js, see issue #2282
	# Hopefully we will remove this after emscripten fixes it, upstream issue
	# emscripten-core/emscripten#16518
	# Sed nonsense from https://stackoverflow.com/a/13383331
	sed -i -n -e :a -e '1,6!{P;N;D;};N;ba' build/pyodide.asm.js
	echo "globalThis._createPyodideModule = _createPyodideModule;" >> build/pyodide.asm.js
	date +"[%F %T] done building pyodide.asm.js."


env:
	env


node_modules/.installed : src/js/package.json src/js/package-lock.json
	cd src/js && npm ci
	ln -sfn src/js/node_modules/ node_modules
	touch node_modules/.installed

build/pyodide.js: src/js/*.ts src/js/pyproxy.gen.ts src/js/error_handling.gen.ts node_modules/.installed
	npx rollup -c src/js/rollup.config.js

src/js/error_handling.gen.ts : src/core/error_handling.ts
	cp $< $@

src/js/pyproxy.gen.ts : src/core/pyproxy.* src/core/*.h
	# We can't input pyproxy.js directly because CC will be unhappy about the file
	# extension. Instead cat it and have CC read from stdin.
	# -E : Only apply prepreocessor
	# -C : Leave comments alone (this allows them to be preserved in typescript
	#      definition files, rollup will strip them out)
	# -P : Don't put in macro debug info
	# -imacros pyproxy.c : include all of the macros definitions from pyproxy.c
	#
	# First we use sed to delete the segments of the file between
	# "// pyodide-skip" and "// end-pyodide-skip". This allows us to give
	# typescript type declarations for the macros which we need for intellisense
	# and documentation generation. The result of processing the type
	# declarations with the macro processor is a type error, so we snip them
	# out.
	rm -f $@
	echo "// This file is generated by applying the C preprocessor to core/pyproxy.ts" >> $@
	echo "// It uses the macros defined in core/pyproxy.c" >> $@
	echo "// Do not edit it directly!" >> $@
	cat src/core/pyproxy.ts | \
		sed '/^\/\/\s*pyodide-skip/,/^\/\/\s*end-pyodide-skip/d' | \
		$(CC) -E -C -P -imacros src/core/pyproxy.c $(MAIN_MODULE_CFLAGS) - \
		>> $@

build/test.html: src/templates/test.html
	cp $< $@

build/module_test.html: src/templates/module_test.html
	cp $< $@

.PHONY: build/console.html
build/console.html: src/templates/console.html
	cp $< $@
	sed -i -e 's#{{ PYODIDE_BASE_URL }}#$(PYODIDE_BASE_URL)#g' $@


.PHONY: docs/_build/html/console.html
docs/_build/html/console.html: src/templates/console.html
	mkdir -p docs/_build/html
	cp $< $@
	sed -i -e 's#{{ PYODIDE_BASE_URL }}#$(PYODIDE_BASE_URL)#g' $@


.PHONY: build/webworker.js
build/webworker.js: src/templates/webworker.js
	cp $< $@
	sed -i -e 's#{{ PYODIDE_BASE_URL }}#$(PYODIDE_BASE_URL)#g' $@

.PHONY: build/module_webworker_dev.js
build/module_webworker_dev.js: src/templates/module_webworker.js
	cp $< $@
	sed -i -e 's#{{ PYODIDE_BASE_URL }}#./#g' $@

.PHONY: build/webworker_dev.js
build/webworker_dev.js: src/templates/webworker.js
	cp $< $@
	sed -i -e 's#{{ PYODIDE_BASE_URL }}#./#g' $@


update_base_url: \
	build/console.html \
	build/webworker.js



.PHONY: lint
lint:
	pre-commit run -a --show-diff-on-failure

benchmark: all
	$(HOSTPYTHON) benchmark/benchmark.py all --output build/benchmarks.json
	$(HOSTPYTHON) benchmark/plot_benchmark.py build/benchmarks.json build/benchmarks.png


clean:
	rm -fr build/*
	rm -fr src/*/*.o
	rm -fr node_modules
	make -C packages clean
	echo "The Emsdk, CPython are not cleaned. cd into those directories to do so."

clean-python: clean
	make -C cpython clean

clean-all:
	make -C emsdk clean
	make -C cpython clean-all

src/core/error_handling_cpp.o: src/core/error_handling_cpp.cpp
	$(CXX) -o $@ -c $< $(MAIN_MODULE_CFLAGS) -Isrc/core/

%.o: %.c $(CPYTHONLIB) $(wildcard src/core/*.h src/core/*.js)
	$(CC) -o $@ -c $< $(MAIN_MODULE_CFLAGS) -Isrc/core/


# Stdlib modules that we repackage as standalone packages

TEST_EXTENSIONS= \
		_testinternalcapi.so \
		_testcapi.so \
		_testbuffer.so \
		_testimportmultiple.so \
		_testmultiphase.so
TEST_MODULE_CFLAGS= $(SIDE_MODULE_CFLAGS) -I Include/ -I .

# TODO: also include test directories included in other stdlib modules
build/test.tar: $(CPYTHONLIB) node_modules/.installed
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testinternalcapi.c -o Modules/_testinternalcapi.o \
							   -I Include/internal/ -DPy_BUILD_CORE_MODULE
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testcapimodule.c -o Modules/_testcapi.o
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testbuffer.c -o Modules/_testbuffer.o
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testimportmultiple.c -o Modules/_testimportmultiple.o
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testmultiphase.c -o Modules/_testmultiphase.o

	for testname in $(TEST_EXTENSIONS); do \
		cd $(CPYTHONBUILD) && \
		emcc Modules/$${testname%.*}.o -o $$testname $(SIDE_MODULE_LDFLAGS) && \
		ln -s $(CPYTHONBUILD)/$$testname $(CPYTHONLIB)/$$testname ; \
	done

	cd $(CPYTHONLIB) && tar -h --exclude=__pycache__ -cf $(PYODIDE_ROOT)/build/test.tar \
		test $(TEST_EXTENSIONS)

	cd $(CPYTHONLIB) && rm $(TEST_EXTENSIONS)


build/distutils.tar: $(CPYTHONLIB) node_modules/.installed
	cd $(CPYTHONLIB) && tar --exclude=__pycache__ -cf $(PYODIDE_ROOT)/build/distutils.tar distutils


$(CPYTHONLIB): emsdk/emsdk/.complete $(PYODIDE_EMCC) $(PYODIDE_CXX)
	date +"[%F %T] Building cpython..."
	make -C $(CPYTHONROOT)
	date +"[%F %T] done building cpython..."


build/packages.json: FORCE
	date +"[%F %T] Building packages..."
	make -C packages
	date +"[%F %T] done building packages..."


emsdk/emsdk/.complete:
	date +"[%F %T] Building emsdk..."
	make -C emsdk
	date +"[%F %T] done building emsdk."


FORCE:


check:
	./tools/dependency-check.sh


debug :
	EXTRA_CFLAGS+=" -D DEBUG_F" \
	make
