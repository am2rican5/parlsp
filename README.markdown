# parlsp

A Language Server Protocol implementation for Common Lisp, written in Common Lisp.

## Features

- LSP base protocol over stdio (default) or TCP.
- `textDocument/didOpen` / `didChange` / `didSave` / `didClose` document syncing (full + incremental).
- `textDocument/completion` — prefix completion across `COMMON-LISP` exported symbols and the document's own definitions.
- `textDocument/hover` — markdown documentation for `COMMON-LISP` symbols (signature + docstring via `documentation` and `sb-introspect`).
- `textDocument/definition` — jump to in-buffer top-level definitions.
- `textDocument/documentSymbol` — outline of `defun`, `defmacro`, `defvar`, `defparameter`, `defclass`, `defstruct`, `defpackage`, `defmethod`, `defgeneric`, `define-condition`, etc.
- `textDocument/publishDiagnostics` — paren-balance and string-termination checks.
- Lifecycle: `initialize`, `initialized`, `shutdown`, `exit`.

The server never `EVAL`s user code — analysis is done with a hand-rolled scanner.

## Requirements

- [SBCL](http://www.sbcl.org/) (other implementations may work but stdio binary streams currently use `sb-sys:make-fd-stream`).
- [Quicklisp](https://www.quicklisp.org/) for resolving dependencies (`alexandria`, `bordeaux-threads`, `cl-json`, `cl-ppcre`).

## Usage

```sh
./bin/parlsp --stdio                    # default; speak LSP on stdin/stdout
./bin/parlsp --tcp 127.0.0.1:5050       # listen on TCP for one client
./bin/parlsp --log-level debug          # crank up logging (writes to stderr)
./bin/parlsp --log-file /tmp/lsp.log    # log to a file instead of stderr
./bin/parlsp --help
./bin/parlsp --version
```

The launcher loads the system via Quicklisp and dispatches to `parlsp:main`.

### Editor configuration (Neovim example)

```lua
vim.lsp.start({
  name = "parlsp",
  cmd = { "/path/to/parlsp/bin/parlsp", "--stdio" },
  filetypes = { "lisp" },
  root_dir = vim.fs.dirname(vim.fs.find({ ".git", "*.asd" }, { upward = true })[1]),
})
```

### Building a standalone binary

```sh
make build              # writes dist/parlsp (~50–100 MB SBCL core image)
make install            # symlinks bin/parlsp into ~/bin (or PREFIX=/usr/local etc.)
```

## Development

```sh
make            # run the Rove test suite (default target)
make test       # same
make repl       # SBCL REPL with the system loaded
make clean      # remove dist/ and ASDF caches for this project
make help       # list all targets
```

Tests cover JSON serialization, JSON-RPC framing, document model, analyzer (top-level scan, symbol-at-point, diagnostics) and LSP method handlers (`initialize`, `didOpen`, `completion`, `hover`, `definition`, `documentSymbol`).

## Project layout

```
parlsp.asd
src/
  package.lisp     — package definition and exports
  json.lisp        — JSON encode/decode helpers (kebab-case keyword → camelCase JSON)
  log.lisp         — leveled logging to stderr (or --log-file)
  document.lisp    — in-memory document with line/offset translation
  analyzer.lisp    — top-level form scanner, symbol-at-point, diagnostics, completions
  protocol.lisp    — LSP framing (binary streams, UTF-8 codec) and method dispatch
  handlers.lisp    — LSP method handlers
  server.lisp      — read/dispatch/write loop and stdio/tcp transports
  main.lisp        — CLI argument parsing and entry point
bin/
  parlsp           — shell launcher
tests/             — Rove suites
```

## License

MIT.
