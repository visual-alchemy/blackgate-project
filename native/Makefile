# Blackgate Native Engine — Rust Build
# C engine archived to native/archive/. This Makefile builds Rust engine only.

RUST_SRC_DIR := rust
RUST_BUILD_DIR := build/rust
RUST_BINARY := $(RUST_BUILD_DIR)/release/blackgate-engine

.PHONY: all clean rust-build rust-clean help

all: rust-build

rust-build:
	cd $(RUST_SRC_DIR) && cargo build --release --target-dir ../$(RUST_BUILD_DIR)
	cp $(RUST_BINARY) build/blackgate-engine

rust-clean:
	cd $(RUST_SRC_DIR) && cargo clean
	rm -rf $(RUST_BUILD_DIR)

clean:
	rm -rf build

help:
	@echo "Available targets:"
	@echo "  make              - Build Rust engine (cargo build --release)"
	@echo "  make clean        - Remove compiled files"
	@echo "  make rust-build   - Build Rust engine only"
	@echo "  make rust-clean   - Clean Rust build artifacts"
	@echo "  make help         - Show this help message"
