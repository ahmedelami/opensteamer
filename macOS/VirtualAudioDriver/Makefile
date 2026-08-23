SHELL := /bin/zsh

DEVELOPER_DIR ?= /Applications/Xcode-26.6.0.app/Contents/Developer
XCRUN := /usr/bin/xcrun
CLANG := DEVELOPER_DIR="$(DEVELOPER_DIR)" "$(XCRUN)" --sdk macosx clang
REPOSITORY_KEY := $(shell /usr/bin/printf '%s' "$(CURDIR)" | \
	/usr/bin/shasum -a 256 | /usr/bin/cut -c 1-12)
BUILD_DIR ?= /private/tmp/opensteamer-virtual-audio-tests-$(shell /usr/bin/id -u)-$(REPOSITORY_KEY)

INCLUDE_DIR := $(CURDIR)/include
CORE_SOURCE := $(CURDIR)/src/OpensteamerVirtualAudioCore.c
CORE_TEST_SOURCE := $(CURDIR)/tests/OpensteamerVirtualAudioCoreTests.c
DRIVER_SOURCE := $(CURDIR)/Driver/OpensteamerVirtualMicrophone.c
DRIVER_TEST_SOURCE := $(CURDIR)/tests/OpensteamerVirtualMicrophoneDriverTests.c

COMMON_FLAGS := \
	-std=c17 \
	-g \
	-O1 \
	-Wall \
	-Wextra \
	-Werror \
	-Wpedantic \
	-Wconversion \
	-Wsign-conversion \
	-Wshadow \
	-Wstrict-prototypes \
	-Wmissing-prototypes \
	-I "$(INCLUDE_DIR)" \
	-pthread

CORE_BINARY := $(BUILD_DIR)/OpensteamerVirtualAudioCoreTests
DRIVER_BINARY := $(BUILD_DIR)/OpensteamerVirtualMicrophoneDriverTests
CORE_ASAN_BINARY := $(BUILD_DIR)/OpensteamerVirtualAudioCoreTests.asan-ubsan
DRIVER_ASAN_BINARY := $(BUILD_DIR)/OpensteamerVirtualMicrophoneDriverTests.asan-ubsan
CORE_TSAN_BINARY := $(BUILD_DIR)/OpensteamerVirtualAudioCoreTests.tsan
DRIVER_TSAN_BINARY := $(BUILD_DIR)/OpensteamerVirtualMicrophoneDriverTests.tsan
CORE_DSYM := $(CORE_BINARY).dSYM
DRIVER_DSYM := $(DRIVER_BINARY).dSYM
CORE_ASAN_DSYM := $(CORE_ASAN_BINARY).dSYM
DRIVER_ASAN_DSYM := $(DRIVER_ASAN_BINARY).dSYM
CORE_TSAN_DSYM := $(CORE_TSAN_BINARY).dSYM
DRIVER_TSAN_DSYM := $(DRIVER_TSAN_BINARY).dSYM

.PHONY: all test test-core test-driver test-bundle-load test-asan-ubsan test-tsan \
	test-sanitizers clean

all: test

test: test-core test-driver test-bundle-load

test-core: $(CORE_BINARY)
	"$(CORE_BINARY)"

test-driver: $(DRIVER_BINARY)
	"$(DRIVER_BINARY)"

test-bundle-load:
	"$(CURDIR)/scripts/test-built-driver-bundle.sh"

test-asan-ubsan: $(CORE_ASAN_BINARY) $(DRIVER_ASAN_BINARY)
	ASAN_OPTIONS=abort_on_error=1:detect_leaks=0:strict_string_checks=1 \
	UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
	"$(CORE_ASAN_BINARY)"
	ASAN_OPTIONS=abort_on_error=1:detect_leaks=0:strict_string_checks=1 \
	UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
	"$(DRIVER_ASAN_BINARY)"

test-tsan: $(CORE_TSAN_BINARY) $(DRIVER_TSAN_BINARY)
	TSAN_OPTIONS=halt_on_error=1:history_size=7 \
	"$(CORE_TSAN_BINARY)"
	TSAN_OPTIONS=halt_on_error=1:history_size=7 \
	"$(DRIVER_TSAN_BINARY)"

test-sanitizers: test-asan-ubsan test-tsan

$(BUILD_DIR):
	/bin/mkdir -p "$@"

$(CORE_BINARY): $(CORE_SOURCE) $(CORE_TEST_SOURCE) \
		$(INCLUDE_DIR)/OpensteamerVirtualAudioCore.h | $(BUILD_DIR)
	$(CLANG) $(COMMON_FLAGS) \
		"$(CORE_SOURCE)" "$(CORE_TEST_SOURCE)" -o "$@"

$(DRIVER_BINARY): $(CORE_SOURCE) $(DRIVER_SOURCE) $(DRIVER_TEST_SOURCE) \
		$(INCLUDE_DIR)/OpensteamerVirtualAudioCore.h \
		$(INCLUDE_DIR)/OpensteamerVirtualMicrophoneDriver.h | $(BUILD_DIR)
	$(CLANG) $(COMMON_FLAGS) -fblocks -DOSVA_DRIVER_TESTING=1 \
		"$(CORE_SOURCE)" "$(DRIVER_SOURCE)" "$(DRIVER_TEST_SOURCE)" \
		-framework CoreAudio -framework CoreFoundation -o "$@"

$(CORE_ASAN_BINARY): $(CORE_SOURCE) $(CORE_TEST_SOURCE) \
		$(INCLUDE_DIR)/OpensteamerVirtualAudioCore.h | $(BUILD_DIR)
	$(CLANG) $(COMMON_FLAGS) -fno-omit-frame-pointer \
		-fsanitize=address,undefined \
		"$(CORE_SOURCE)" "$(CORE_TEST_SOURCE)" -o "$@"

$(DRIVER_ASAN_BINARY): $(CORE_SOURCE) $(DRIVER_SOURCE) $(DRIVER_TEST_SOURCE) \
		$(INCLUDE_DIR)/OpensteamerVirtualAudioCore.h \
		$(INCLUDE_DIR)/OpensteamerVirtualMicrophoneDriver.h | $(BUILD_DIR)
	$(CLANG) $(COMMON_FLAGS) -fblocks -DOSVA_DRIVER_TESTING=1 \
		-fno-omit-frame-pointer -fsanitize=address,undefined \
		"$(CORE_SOURCE)" "$(DRIVER_SOURCE)" "$(DRIVER_TEST_SOURCE)" \
		-framework CoreAudio -framework CoreFoundation -o "$@"

$(CORE_TSAN_BINARY): $(CORE_SOURCE) $(CORE_TEST_SOURCE) \
		$(INCLUDE_DIR)/OpensteamerVirtualAudioCore.h | $(BUILD_DIR)
	$(CLANG) $(COMMON_FLAGS) -fno-omit-frame-pointer -fsanitize=thread \
		"$(CORE_SOURCE)" "$(CORE_TEST_SOURCE)" -o "$@"

$(DRIVER_TSAN_BINARY): $(CORE_SOURCE) $(DRIVER_SOURCE) $(DRIVER_TEST_SOURCE) \
		$(INCLUDE_DIR)/OpensteamerVirtualAudioCore.h \
		$(INCLUDE_DIR)/OpensteamerVirtualMicrophoneDriver.h | $(BUILD_DIR)
	$(CLANG) $(COMMON_FLAGS) -fblocks -DOSVA_DRIVER_TESTING=1 \
		-fno-omit-frame-pointer -fsanitize=thread \
		"$(CORE_SOURCE)" "$(DRIVER_SOURCE)" "$(DRIVER_TEST_SOURCE)" \
		-framework CoreAudio -framework CoreFoundation -o "$@"

clean:
	@build_dir="$(BUILD_DIR)"; \
	build_parent="$${build_dir:h}"; \
	build_leaf="$${build_dir:t}"; \
	if [[ "$$build_parent" != "/private/tmp" ]] || \
	   ! /usr/bin/printf '%s\n' "$$build_leaf" | \
	       /usr/bin/grep -Eq '^opensteamer-virtual-audio-tests-[0-9]+-[0-9a-f]{12}$$'; then \
		print -u2 "refusing to clean unrecognized BUILD_DIR: $$build_dir"; \
		exit 73; \
	fi; \
	if [[ -L "$$build_dir" ]]; then \
		print -u2 "refusing to clean symlink BUILD_DIR: $$build_dir"; \
		exit 73; \
	fi; \
	for artifact in \
		"$(CORE_BINARY)" \
		"$(DRIVER_BINARY)" \
		"$(CORE_ASAN_BINARY)" \
		"$(DRIVER_ASAN_BINARY)" \
		"$(CORE_TSAN_BINARY)" \
		"$(DRIVER_TSAN_BINARY)"; do \
		if [[ -e "$$artifact" || -L "$$artifact" ]]; then \
			if [[ ! -f "$$artifact" || -L "$$artifact" ]]; then \
				print -u2 "refusing to remove unexpected build artifact node: $$artifact"; \
				exit 73; \
			fi; \
			/bin/rm -- "$$artifact"; \
		fi; \
	done; \
	for debug_bundle in \
		"$(CORE_DSYM)" \
		"$(DRIVER_DSYM)" \
		"$(CORE_ASAN_DSYM)" \
		"$(DRIVER_ASAN_DSYM)" \
		"$(CORE_TSAN_DSYM)" \
		"$(DRIVER_TSAN_DSYM)"; do \
		if [[ -e "$$debug_bundle" || -L "$$debug_bundle" ]]; then \
			if [[ ! -d "$$debug_bundle" || -L "$$debug_bundle" ]]; then \
				print -u2 "refusing to remove unexpected debug bundle node: $$debug_bundle"; \
				exit 73; \
			fi; \
			/bin/rm -rf -- "$$debug_bundle"; \
		fi; \
	done; \
	if [[ -d "$$build_dir" ]]; then \
		/bin/rmdir -- "$$build_dir" || { \
			print -u2 "refusing to recursively clean non-empty BUILD_DIR: $$build_dir"; \
			exit 73; \
		}; \
	fi
