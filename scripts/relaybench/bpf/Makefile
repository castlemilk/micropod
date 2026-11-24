# Build only. Attaching requires a separately admitted Linux diagnostic window.
BPF_CLANG ?= clang
BPF_CPPFLAGS ?= $(shell pkg-config --cflags libbpf)
# Debian-family multiarch installs asm/types.h under the compiler's tuple.
MULTIARCH := $(shell $(CC) -print-multiarch 2>/dev/null)
BPF_CFLAGS ?= -O2 -g -target bpfel
OUT ?= .build
GO ?= go
HOST_CC ?= cc
GUEST_TX_TEST_OBJECT ?= $(wildcard $(OUT)/guest_tx.bpf.o)
GUEST_TX_TEST_TARGET ?=
TEST_ENV = GUEST_TX_TEST_OBJECT="$(abspath $(GUEST_TX_TEST_OBJECT))" GUEST_TX_TEST_TARGET="$(abspath $(GUEST_TX_TEST_TARGET))"

all: $(OUT)/guest_tx $(OUT)/guest_tx.bpf.o

$(OUT):
	mkdir -p "$@"

$(OUT)/guest_tx: guesttx/go.mod guesttx/go.sum $(wildcard guesttx/*.go) | $(OUT)
	cd guesttx && GOOS=linux CGO_ENABLED=0 $(GO) build -mod=readonly -buildvcs=false -trimpath -o "$(abspath $@)" .

$(OUT)/guest_tx.bpf.o: guest_tx.bpf.c guest_tx.h service_send.bpf.h | $(OUT)
	$(BPF_CLANG) $(BPF_CFLAGS) $(BPF_CPPFLAGS) $(if $(MULTIARCH),-I/usr/include/$(MULTIARCH)) -c $< -o "$@"

$(OUT)/test_guest_tx: test_guest_tx.c guest_tx.bpf.c guest_tx.h service_send.bpf.h | $(OUT)
	$(HOST_CC) -std=c11 -Wall -Wextra -Werror $< -o "$@"

test: $(OUT)/test_guest_tx
	"$(OUT)/test_guest_tx"
	cd guesttx && $(TEST_ENV) $(GO) test -mod=readonly ./...
	cd guesttx && $(TEST_ENV) $(GO) test -mod=readonly ../corecheck/*.go

.PHONY: all test
