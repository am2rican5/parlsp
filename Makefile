# parlsp — Language Server for Common Lisp
#
# Common targets:
#   make            Run tests (default).
#   make test       Run the Rove test suite via asdf:test-system.
#   make build      Compile a standalone SBCL core image to dist/parlsp.
#   make run        Launch the server in --stdio mode (interactive smoke test).
#   make repl       Start an SBCL REPL with the system loaded.
#   make install    Symlink bin/parlsp into $(PREFIX)/bin (default: ~/bin).
#   make uninstall  Remove the symlink.
#   make clean      Delete dist/ and SBCL FASL caches for this project.
#   make help       Show this list.

SBCL          ?= sbcl
QUICKLISP     ?= $(HOME)/quicklisp/setup.lisp
PREFIX        ?= $(HOME)
INSTALL_DIR   := $(PREFIX)/bin
LAUNCHER      := $(CURDIR)/bin/parlsp
SYSTEM        := parlsp
TEST_SYSTEM   := parlsp/tests
DIST_DIR      := dist

# Always make this directory available to ASDF so it picks up parlsp.asd
# from the working tree without needing local-projects symlinks.
SBCL_LOAD     := $(SBCL) --noinform --disable-debugger \
                         --no-userinit --no-sysinit \
                         --load $(QUICKLISP)
ASDF_REGISTRY := CL_SOURCE_REGISTRY="$(CURDIR)//:"

.PHONY: all help test build run repl install uninstall clean

all: test

help:
	@awk '/^[^#]/{exit} /^# /{print substr($$0,3)}' Makefile

test:
	@echo ">> running test suite"
	@$(ASDF_REGISTRY) $(SBCL_LOAD) \
	    --eval "(ql:quickload :$(TEST_SYSTEM) :silent t)" \
	    --eval "(let ((res (asdf:test-system :$(SYSTEM)))) (sb-ext:exit :code (if res 0 1)))"

build: $(DIST_DIR)/parlsp

$(DIST_DIR)/parlsp:
	@echo ">> building standalone binary -> $@"
	@mkdir -p $(DIST_DIR)
	@$(ASDF_REGISTRY) $(SBCL_LOAD) \
	    --eval "(ql:quickload :$(SYSTEM) :silent t)" \
	    --eval "(asdf:make :$(SYSTEM))" \
	    --eval "(sb-ext:exit :code 0)"
	@echo "   -> $@ ($(shell du -h $@ 2>/dev/null | cut -f1))"

run:
	@$(LAUNCHER) --stdio

repl:
	@$(ASDF_REGISTRY) $(SBCL) --load $(QUICKLISP) \
	    --eval "(ql:quickload :$(SYSTEM))"

install: $(LAUNCHER)
	@mkdir -p $(INSTALL_DIR)
	@ln -sf $(LAUNCHER) $(INSTALL_DIR)/parlsp
	@echo ">> installed: $(INSTALL_DIR)/parlsp -> $(LAUNCHER)"

uninstall:
	@rm -f $(INSTALL_DIR)/parlsp
	@echo ">> removed $(INSTALL_DIR)/parlsp"

clean:
	@rm -rf $(DIST_DIR)
	@find $(HOME)/.cache/common-lisp -type d -name "*parlsp*" 2>/dev/null \
	     -exec rm -rf {} + || true
	@echo ">> cleaned dist/ and ASDF caches for $(SYSTEM)"
