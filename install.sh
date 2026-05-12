#!/bin/sh
#
# parlsp installer — one-shot setup for the parlsp Common Lisp LSP server.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/am2rican5/parlsp/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/am2rican5/parlsp/main/install.sh | sh -s -- --no-build
#
# Environment variables:
#   PARLSP_VERSION             Git ref to install (default: main)
#   PARLSP_REPO_URL            GitHub repo URL (default: https://github.com/am2rican5/parlsp)
#   PARLSP_TARBALL_URL         Override tarball URL entirely
#   PARLSP_SOURCE_DIR          Where to keep the source tree (default: ~/.local/share/parlsp)
#   PARLSP_INSTALL_PATH        Final binary path (default: ~/.local/bin/parlsp)
#   PARLSP_QUICKLISP_HOME      Quicklisp directory (default: ~/quicklisp)
#   PARLSP_NO_BUILD            If 1/true, skip the standalone build and install the launcher
#   PARLSP_NO_QUICKLISP_INSTALL  If 1/true, do not auto-install Quicklisp
#   PARLSP_DEBUG               If 1/true, print verbose trace
#   PARLSP_QUIET               If 1/true, suppress informational output
#   PARLSP_SBCL                Path to SBCL (default: sbcl on PATH)
#
# Flags (forwarded via `sh -s --`):
#   --no-build        equivalent to PARLSP_NO_BUILD=1
#   --version <ref>   equivalent to PARLSP_VERSION=<ref>
#   --prefix <dir>    install binary into <dir>/bin/parlsp

set -eu

#region logging
if [ "${PARLSP_DEBUG-}" = "true" ] || [ "${PARLSP_DEBUG-}" = "1" ]; then
  debug() { echo "parlsp: [debug] $*" >&2; }
  set -x
else
  debug() { :; }
fi

if [ "${PARLSP_QUIET-}" = "true" ] || [ "${PARLSP_QUIET-}" = "1" ]; then
  info() { :; }
else
  info() { echo "parlsp: $*" >&2; }
fi

warn() { echo "parlsp: [warn] $*" >&2; }
error() { echo "parlsp: [error] $*" >&2; exit 1; }
#endregion

#region argument parsing
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build)
      PARLSP_NO_BUILD=1
      shift
      ;;
    --version)
      [ $# -ge 2 ] || error "--version requires a value"
      PARLSP_VERSION="$2"
      shift 2
      ;;
    --prefix)
      [ $# -ge 2 ] || error "--prefix requires a value"
      PARLSP_INSTALL_PATH="${2%/}/bin/parlsp"
      shift 2
      ;;
    -h|--help)
      sed -n '2,30p' "$0" 2>/dev/null || true
      exit 0
      ;;
    *)
      error "unknown argument: $1"
      ;;
  esac
done
#endregion

#region environment
VERSION="${PARLSP_VERSION:-main}"
REPO_URL="${PARLSP_REPO_URL:-https://github.com/am2rican5/parlsp}"
SOURCE_DIR="${PARLSP_SOURCE_DIR:-$HOME/.local/share/parlsp}"
INSTALL_PATH="${PARLSP_INSTALL_PATH:-$HOME/.local/bin/parlsp}"
INSTALL_DIR="$(dirname "$INSTALL_PATH")"
QUICKLISP_HOME="${PARLSP_QUICKLISP_HOME:-$HOME/quicklisp}"
SBCL="${PARLSP_SBCL:-sbcl}"
NO_BUILD="${PARLSP_NO_BUILD:-0}"
NO_QL_INSTALL="${PARLSP_NO_QUICKLISP_INSTALL:-0}"

case "$NO_BUILD" in true|1) NO_BUILD=1 ;; *) NO_BUILD=0 ;; esac
case "$NO_QL_INSTALL" in true|1) NO_QL_INSTALL=1 ;; *) NO_QL_INSTALL=0 ;; esac

debug "VERSION=$VERSION"
debug "REPO_URL=$REPO_URL"
debug "SOURCE_DIR=$SOURCE_DIR"
debug "INSTALL_PATH=$INSTALL_PATH"
debug "QUICKLISP_HOME=$QUICKLISP_HOME"
debug "NO_BUILD=$NO_BUILD NO_QL_INSTALL=$NO_QL_INSTALL"
#endregion

#region platform detection
get_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      error "unsupported OS: $(uname -s)" ;;
  esac
}

get_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) error "unsupported architecture: $(uname -m)" ;;
  esac
}

OS="$(get_os)"
ARCH="$(get_arch)"
debug "platform: $OS-$ARCH"
#endregion

#region tool helpers
have() { command -v "$1" >/dev/null 2>&1; }

require_one_of() {
  for tool in "$@"; do
    if have "$tool"; then
      echo "$tool"
      return 0
    fi
  done
  return 1
}

DOWNLOADER=""
if have curl; then
  DOWNLOADER="curl"
elif have wget; then
  DOWNLOADER="wget"
else
  error "either curl or wget is required"
fi
debug "downloader: $DOWNLOADER"

download() {
  url="$1"
  out="$2"
  if [ "$DOWNLOADER" = "curl" ]; then
    debug ">" curl -fsSL "$url" -o "$out"
    curl -fsSL "$url" -o "$out"
  else
    debug ">" wget -qO "$out" "$url"
    wget -qO "$out" "$url"
  fi
}

EXTRACTOR=""
if have tar; then
  EXTRACTOR="tar"
else
  error "tar is required to extract the source tarball"
fi
#endregion

#region sbcl
check_sbcl() {
  if have "$SBCL"; then
    sbcl_version="$("$SBCL" --version 2>/dev/null | head -n1 || true)"
    info "found ${sbcl_version:-SBCL}"
    return 0
  fi

  warn "SBCL not found on PATH"
  case "$OS" in
    macos)
      if have brew; then
        info "installing SBCL via Homebrew"
        brew install sbcl >&2
      else
        error "SBCL is required. Install it from http://www.sbcl.org or run: brew install sbcl"
      fi
      ;;
    linux)
      if have apt-get; then
        error "SBCL is required. Try: sudo apt-get install -y sbcl"
      elif have dnf; then
        error "SBCL is required. Try: sudo dnf install -y sbcl"
      elif have pacman; then
        error "SBCL is required. Try: sudo pacman -S --needed sbcl"
      else
        error "SBCL is required. Install it from http://www.sbcl.org"
      fi
      ;;
  esac
}
#endregion

#region quicklisp
ensure_quicklisp() {
  if [ -f "$QUICKLISP_HOME/setup.lisp" ]; then
    info "found Quicklisp at $QUICKLISP_HOME"
    return 0
  fi

  if [ "$NO_QL_INSTALL" = "1" ]; then
    error "Quicklisp not found at $QUICKLISP_HOME (PARLSP_NO_QUICKLISP_INSTALL=1 set)"
  fi

  info "installing Quicklisp into $QUICKLISP_HOME"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  download "https://beta.quicklisp.org/quicklisp.lisp" "$tmp/quicklisp.lisp"

  # Optional but recommended: verify signature if gpg+sig fetch succeed.
  if have gpg; then
    if download "https://beta.quicklisp.org/quicklisp.lisp.asc" "$tmp/quicklisp.lisp.asc" 2>/dev/null; then
      debug "attempting Quicklisp signature verification"
      gpg --verify "$tmp/quicklisp.lisp.asc" "$tmp/quicklisp.lisp" >/dev/null 2>&1 \
        || warn "Quicklisp signature could not be verified (key not imported); continuing"
    fi
  fi

  "$SBCL" --noinform --non-interactive --no-sysinit --no-userinit \
    --load "$tmp/quicklisp.lisp" \
    --eval "(quicklisp-quickstart:install :path \"$QUICKLISP_HOME/\")" \
    >&2

  rm -rf "$tmp"
  trap - EXIT INT TERM

  [ -f "$QUICKLISP_HOME/setup.lisp" ] \
    || error "Quicklisp installation did not produce $QUICKLISP_HOME/setup.lisp"
}
#endregion

#region source acquisition
fetch_source() {
  tarball_url="${PARLSP_TARBALL_URL:-${REPO_URL%/}/archive/${VERSION}.tar.gz}"
  info "downloading parlsp@${VERSION} from $tarball_url"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  download "$tarball_url" "$tmp/parlsp.tar.gz"

  mkdir -p "$tmp/extract"
  tar -xzf "$tmp/parlsp.tar.gz" -C "$tmp/extract"

  # GitHub tarballs extract as <repo>-<ref>/; pick the one directory inside.
  extracted="$(find "$tmp/extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$extracted" ] || error "tarball did not contain a source directory"
  [ -f "$extracted/parlsp.asd" ] || error "extracted source is missing parlsp.asd"

  mkdir -p "$(dirname "$SOURCE_DIR")"
  if [ -e "$SOURCE_DIR" ]; then
    debug "replacing existing $SOURCE_DIR"
    rm -rf "$SOURCE_DIR"
  fi
  mv "$extracted" "$SOURCE_DIR"

  rm -rf "$tmp"
  trap - EXIT INT TERM

  info "source installed at $SOURCE_DIR"
}
#endregion

#region build / install
build_binary() {
  info "building standalone binary (this can take 1-2 minutes)"
  (
    cd "$SOURCE_DIR"
    CL_SOURCE_REGISTRY="$SOURCE_DIR//:" \
      "$SBCL" --noinform --disable-debugger --no-userinit --no-sysinit \
        --load "$QUICKLISP_HOME/setup.lisp" \
        --eval "(ql:quickload :parlsp :silent t)" \
        --eval "(asdf:make :parlsp)" \
        --eval "(sb-ext:exit :code 0)" >&2
  )
  built="$SOURCE_DIR/dist/parlsp"
  [ -x "$built" ] || error "build did not produce $built"
  install_file "$built"
}

install_launcher() {
  launcher="$SOURCE_DIR/bin/parlsp"
  [ -x "$launcher" ] || error "launcher missing or not executable: $launcher"
  install_link "$launcher"
}

install_file() {
  src="$1"
  mkdir -p "$INSTALL_DIR"
  rm -f "$INSTALL_PATH"
  cp "$src" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
  info "installed binary to $INSTALL_PATH"
}

install_link() {
  src="$1"
  mkdir -p "$INSTALL_DIR"
  rm -f "$INSTALL_PATH"
  ln -s "$src" "$INSTALL_PATH"
  info "linked launcher: $INSTALL_PATH -> $src"
}
#endregion

#region post-install help
print_path_hint() {
  case ":${PATH}:" in
    *":$INSTALL_DIR:"*)
      info "run \`parlsp --help\` to get started"
      ;;
    *)
      info ""
      info "$INSTALL_DIR is not on your PATH. Add it with one of:"
      case "${SHELL:-}" in
        */zsh)
          info "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> \"\${ZDOTDIR:-\$HOME}/.zshrc\""
          ;;
        */bash)
          info "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc"
          ;;
        */fish)
          info "  fish_add_path $INSTALL_DIR"
          ;;
        *)
          info "  export PATH=\"$INSTALL_DIR:\$PATH\""
          ;;
      esac
      info ""
      info "then run \`parlsp --help\`"
      ;;
  esac
}
#endregion

main() {
  info "installing parlsp@${VERSION} -> $INSTALL_PATH"
  check_sbcl
  fetch_source
  if [ "$NO_BUILD" = "1" ]; then
    ensure_quicklisp
    install_launcher
    info "skipping build (--no-build); using launcher script"
  else
    ensure_quicklisp
    build_binary
  fi
  print_path_hint
  info "done"
}

main
