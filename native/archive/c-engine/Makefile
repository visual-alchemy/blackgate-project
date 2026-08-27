CC ?= gcc
PKGS := gstreamer-1.0 gstreamer-app-1.0 gio-2.0 libcjson srt
CFLAGS ?= -O2 -g -Wall -Wextra
CFLAGS += $(shell pkg-config --cflags $(PKGS)) -Iinclude
LDLIBS += $(shell pkg-config --libs $(PKGS)) -lpthread

SRC := $(wildcard src/*.c)
OBJ := $(patsubst src/%.c,build/%.o,$(SRC))
BIN := build/blackgate_pipeline

.PHONY: all clean verify

all: $(BIN)

$(BIN): $(OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

build:
	mkdir -p build

verify:
	sha256sum -c MANIFEST.sha256

clean:
	rm -rf build
