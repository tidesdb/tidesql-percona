#!/usr/bin/env bash
# 
# install.sh - Build & install Percona Server with InnoDB and TidesDB(TideSQL)
#
# Supported platforms: Linux (Debian/Ubuntu, RHEL/Fedora, Arch), BSDs, macOS, Windows
# (MSYS2/Git Bash).
#
# Supported servers: Percona Server 8.0, 8.4 and 9.x.  The engine builds against each line from
# the one source; see doc/04-reference/compatibility.md for what differs between them.
#
# Flow:
#   1. Detect OS (Debian, RHEL, Arch, macOS, Windows)
#   2. Install system dependencies
#        - Linux      apt/dnf/pacman (cmake, compilers, zstd, lz4, snappy, ssl, etc.)
#        - macOS      Homebrew (cmake, ninja, zstd, lz4, snappy, etc.)
#        - Windows    vcpkg (zstd, lz4, snappy, pthreads)
#   3. Build & install TidesDB library
#        - Clone tidesdb at the requested version tag
#        - cmake Release build
#        - Install to --tidesdb-prefix (default /usr/local or C:/tidesdb)
#        - Update shared library cache (ldconfig on Linux)
#   4. Clone Percona Server source
#        - Checkout the requested tag, with its submodules
#        - Copy tidesdb/ storage engine plugin into storage/, and copy its test
#          suites into mysql-test/suite/ -- the server looks for a suite there, not
#          under the engine's own directory
#   5. Build Percona Server (full server)
#        - All default storage engines (InnoDB, MyRocks, MyISAM, MEMORY, CSV, etc.)
#        - All standard tools (mysql, mysqldump, mysqladmin, etc.)
#        - TidesDB plugin built as a MODULE via the copied source
#        - cmake points at --tidesdb-prefix so FIND_LIBRARY resolves
#        - Boost comes from the server tree on 8.4 and later, and is downloaded on 8.0
#   6. Install Percona Server to --percona-prefix
#   7. Setup
#        - Create mysql system user (Unix only)
#        - Write production my.cnf / my.ini (InnoDB tuning, logging, utf8mb4,
#          TidesDB plugin_load_add, client and mysqldump sections)
#        - Run mysqld --initialize-insecure to initialize the data directory
#        - Set proper file ownership (Unix only)
#   8. Print summary with start/connect/test commands
#
# Usage:
#  ./install.sh [OPTIONS]
#
# Options:
#   --tidesdb-version VERSION   TidesDB release tag        (default: the paired release)
#   --percona-version VERSION   Percona Server tag, or a release line such as 8.0, 8.4 or 9.7,
#                               which takes that line's newest tag  (default: newest 9.7 release)
#   --tidesdb-prefix  DIR       TidesDB install prefix     (default: platform-dependent)
#   --percona-prefix  DIR       Percona Server install prefix  (default: platform-dependent)
#   --build-dir       DIR       Working directory          (default: platform-dependent)
#   --percona-src     DIR       Use this Percona Server source tree instead of cloning one.  The
#                               tree must be the same version as the server the plugin will load
#                               into: a storage engine records the server's MYSQL_VERSION_ID and
#                               the server refuses a plugin whose id differs, patch releases
#                               included.
#   --jobs            N         Parallel build jobs        (default: auto-detected)
#   --skip-deps                 Skip system dependency installation
#   --skip-tidesdb              Skip TidesDB library build (use if already installed)
#   --skip-engines  ENGINES     Comma-separated list of storage engines to skip
#   --list-engines              List storage engines that can be skipped and exit
#   --rebuild-plugin            Rebuild only the TidesDB plugin (fast dev cycle)
#   --pgo                       Enable Profile-Guided Optimization (3-phase build)
#   --allocator  NAME           Memory allocator for libtidesdb.so: system (default), jemalloc, mimalloc, or tcmalloc.
#                               Only affects TidesDB's internal allocations; mysqld's allocator is unchanged.
#                               For a process-wide swap also LD_PRELOAD the allocator at mysqld startup.
#                               Note: --rebuild-plugin does not rebuild libtidesdb, so changing this flag
#                               requires a full install run (omit --rebuild-plugin) to take effect.
#   --help                      Show this help message
#
# Platform defaults:
#   Linux / macOS:
#     tidesdb-prefix  = /usr/local
#     percona-prefix  = /usr/local/mysql
#     build-dir       = /tmp/tidesql-build
#   Windows (MSYS2 / Git Bash):
#     tidesdb-prefix  = C:/tidesdb
#     percona-prefix  = C:/mysql
#     build-dir       = C:/tidesql-build
#
# Examples:
#  ./install.sh
#  ./install.sh --percona-version 8.0
#  ./install.sh --tidesdb-version v10.2.1 --percona-version Percona-Server-8.4.11-11
#  ./install.sh --tidesdb-prefix /opt/tidesdb --percona-prefix /opt/percona
#  ./install.sh --skip-deps --skip-tidesdb
#  ./install.sh --pgo          # Full PGO build (instrument -> train -> optimize)
#  ./install.sh --list-engines # Show which engines can be skipped
#  ./install.sh --skip-engines archive,blackhole,rocksdb
# 
set -euo pipefail

# Resolve the tidesql repo root (where this script lives) 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_os() {
    case "$(uname -s)" in
        Linux*)
            if [[ -f /etc/os-release ]]; then
                . /etc/os-release
                case "$ID" in
                    ubuntu|debian|pop|linuxmint|raspbian) echo "debian"  ;;
                    fedora|rhel|centos|rocky|alma|ol|amzn|scientific) echo "redhat" ;;
                    arch|manjaro|endeavouros) echo "arch" ;;
                    *)
                        # Fallback: check ID_LIKE for parent distro family
                        case "${ID_LIKE:-}" in
                            *debian*|*ubuntu*) echo "debian"  ;;
                            *rhel*|*fedora*|*centos*) echo "redhat" ;;
                            *arch*) echo "arch" ;;
                            *) echo "linux-unknown" ;;
                        esac
                        ;;
                esac
            else
                echo "linux-unknown"
            fi
            ;;
        Darwin*)  echo "macos"   ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        FreeBSD*) echo "freebsd" ;;
        OpenBSD*) echo "openbsd" ;;
        NetBSD*|DragonFly*) echo "netbsd" ;;
        *)        echo "unknown" ;;
    esac
}

OS="$(detect_os)"

# Platform-dependent defaults 
if [[ "$OS" == "windows" ]]; then
    DEFAULT_TIDESDB_PREFIX="C:/tidesdb"
    DEFAULT_PERCONA_PREFIX="C:/mysql"
    DEFAULT_BUILD_DIR="C:/tidesql-build"
else
    DEFAULT_TIDESDB_PREFIX="/usr/local"
    DEFAULT_PERCONA_PREFIX="/usr/local/mysql"
    DEFAULT_BUILD_DIR="/tmp/tidesql-build"
fi

# Fetch latest release versions from GitHub 
# Works on Linux, macOS, and Windows (MSYS2/Git Bash) using curl or wget
_fetch_url() {
    local url="$1"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" 2>/dev/null
    elif command -v wget &>/dev/null; then
        wget -qO- "$url" 2>/dev/null
    else
        echo ""
    fi
}

# The TidesDB release this TideSQL is paired with and tested against.  Pinned rather than resolved
# to whatever is newest: a TideSQL release stores data in one library's on-disk format, and the
# pairing is part of what the version means -- see VERSIONING.md.  --tidesdb-version overrides it
# for trying a different library, and the plugin's CMake still refuses a different major.
TIDESDB_PINNED_VERSION="v10.2.1"

get_latest_tidesdb_version() {
    local version
    version=$(_fetch_url "https://api.github.com/repos/tidesdb/tidesdb/releases/latest" \
        | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    if [[ -z "$version" ]]; then
        echo "${TIDESDB_PINNED_VERSION}"
    else
        echo "$version"
    fi
}

# The newest release line TideSQL is tested against.  Percona's later lines are left to an explicit
# --percona-version, since the engine has not been built or tested against them.
PERCONA_DEFAULT_LINE="9.7"

# The newest Percona Server tag in the release line named, such as 8.4.  Percona publishes
# each release as a Percona-Server-<version>-<build> tag on percona/percona-server.  The tags come
# from git rather than the GitHub tags API because that API pages at 100 entries in an order that
# is not newest-first, so a one-page read can miss the newest tag entirely; git ls-remote returns
# every tag in one request.
get_latest_percona_version() {
    local line="$1"
    local pattern="^Percona-Server-${line//./\\.}\\.[0-9]+-[0-9]+\$"
    local version
    local repo="https://github.com/percona/percona-server.git"
    version=$(git ls-remote --tags --refs "$repo" 2>/dev/null \
        | sed -E 's#.*refs/tags/##' \
        | grep -E "$pattern" \
        | sort -V | tail -1)
    if [[ -n "$version" ]]; then
        echo "$version"
        return
    fi
    # offline, fall back to the releases TideSQL 2.1.0 is tested against.  a line with none of
    # its own has no fallback, since another line's tag would build a server the caller did not
    # ask for.
    case "$line" in
        8.0)    echo "Percona-Server-8.0.46-37" ;;
        8.4)    echo "Percona-Server-8.4.11-11" ;;
        9.7)    echo "Percona-Server-9.7.2-2" ;;
        *)      return 1 ;;
    esac
}

TIDESDB_VERSION=""
PERCONA_VERSION=""
PERCONA_SRC=""
TIDESDB_PREFIX="${DEFAULT_TIDESDB_PREFIX}"
PERCONA_PREFIX="${DEFAULT_PERCONA_PREFIX}"
BUILD_DIR="${DEFAULT_BUILD_DIR}"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
SKIP_DEPS=false
SKIP_TIDESDB=false
REBUILD_PLUGIN=false
PGO_ENABLED=false
SKIP_ENGINES=""
# Memory allocator to build libtidesdb against.  One of:
#   system     glibc / platform default (no extra dep)
#   jemalloc   routes TidesDB allocations through jemalloc (pkg: libjemalloc-dev)
#   mimalloc   routes TidesDB allocations through mimalloc (pkg: libmimalloc-dev)
#   tcmalloc   routes TidesDB allocations through tcmalloc (pkg: libgoogle-perftools-dev)
# Note this affects only libtidesdb.so's internal allocations; mysqld's own
# allocator is unchanged.  When set, the installer resolves the allocator via
# ldconfig (so it finds it wherever the linker knows it, e.g. /usr/lib64 on
# RHEL or the Debian multiarch dir) and wires it into the generated cnf as
# [mysqld_safe] malloc-lib, so mysqld_safe preloads it automatically.  For a
# direct mysqld start, LD_PRELOAD that same resolved path.
ALLOCATOR="system"

# Ensure VCPKG_ROOT is set on Windows (needed even with --skip-deps) 
if [[ "$OS" == "windows" ]]; then
    if [[ -z "${VCPKG_ROOT:-}" ]]; then
        if [[ -d "C:/vcpkg" ]]; then
            VCPKG_ROOT="C:/vcpkg"
        fi
    fi
    export VCPKG_ROOT="${VCPKG_ROOT:-}"
fi

# Skippable storage engines 
# These are server storage engines that can safely be disabled to save build
# time and reduce compiler warnings.  InnoDB, MyISAM, MEMORY and CSV are NOT
# listed here because the server or mysql-test framework depends on them.
SKIPPABLE_ENGINES=(
    "archive:Archive engine (compressed, insert-and-read-only tables)"
    "blackhole:Blackhole engine (accepts writes, stores nothing)"
    "example:Example storage engine (stub, for engine authors)"
    "federated:Federated engine (tables backed by a remote MySQL server)"
    "ndb:NDB Cluster engine (shared-nothing clustering; a large build on its own)"
    "rocksdb:MyRocks engine (Percona's RocksDB-backed engine; a large build on its own)"
)

# CSV, InnoDB, MEMORY, MyISAM, MERGE, Performance Schema and TempTable are marked MANDATORY in
# the server's own CMake and cannot be dropped, so they are deliberately absent from the list
# above -- passing them to --skip-engines would produce a cmake variable the build ignores.


# Color helpers 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# Path to the installed libtidesdb shared library.  CMake installs to lib64 on
# RHEL/Fedora/SUSE and to lib on Debian and macOS, so probe both rather than
# assuming lib.  Prints the path and returns 0, or returns 1 if not found.
find_libtidesdb() {
    local d f
    for d in lib64 lib; do
        for f in "${TIDESDB_PREFIX}/${d}/libtidesdb.so" "${TIDESDB_PREFIX}/${d}/libtidesdb.dylib"; do
            [[ -e "$f" ]] && { printf '%s\n' "$f"; return 0; }
        done
    done
    return 1
}

# Parse arguments 
usage() {
    # the banner is the comment block at the top of this file, printed from line 2 up to the first
    # line that is not a comment.  the old range ended at the next comment line instead, which made
    # --help print its title and nothing else.
    sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

list_engines() {
    echo ""
    echo -e "${CYAN}Skippable storage engines:${NC}"
    echo -e "${CYAN}${NC}"
    for entry in "${SKIPPABLE_ENGINES[@]}"; do
        local name="${entry%%:*}"
        local desc="${entry#*:}"
        printf "  ${GREEN}%-14s${NC} %s\n" "$name" "$desc"
    done
    echo ""
    echo -e "Usage: ${GREEN}--skip-engines archive,blackhole,rocksdb${NC}"
    echo ""
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tidesdb-version)  TIDESDB_VERSION="$2";  shift 2 ;;
        --percona-version)  PERCONA_VERSION="$2";  shift 2 ;;
        --tidesdb-prefix)   TIDESDB_PREFIX="$2";   shift 2 ;;
        --percona-prefix)   PERCONA_PREFIX="$2";   shift 2 ;;
        --build-dir)        BUILD_DIR="$2";         shift 2 ;;
        --jobs)             JOBS="$2";              shift 2 ;;
        --skip-deps)        SKIP_DEPS=true;         shift   ;;
        --skip-tidesdb)     SKIP_TIDESDB=true;      shift   ;;
        --rebuild-plugin)   REBUILD_PLUGIN=true;    shift   ;;
        --skip-engines)     SKIP_ENGINES="$2";      shift 2 ;;
        --list-engines)     list_engines ;;
        --pgo)              PGO_ENABLED=true;       shift   ;;
        --allocator)
            ALLOCATOR="$2"
            case "$ALLOCATOR" in
                system|jemalloc|mimalloc|tcmalloc) ;;
                *) die "--allocator must be one of system|jemalloc|mimalloc|tcmalloc (got '$ALLOCATOR')" ;;
            esac
            shift 2 ;;
        --percona-src)        PERCONA_SRC="$2";         shift 2 ;;
        --help|-h)          usage ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

# The Percona Server source tree: the one the caller named, or the one this script clones.
PERCONA_SRC_GIVEN=false
if [[ -n "$PERCONA_SRC" ]]; then
    [[ -d "$PERCONA_SRC" ]] || die "--percona-src: no such directory: ${PERCONA_SRC}"
    # a stock MySQL tree has the same layout, and the plugin built against it would be refused by
    # the Percona server, so the check looks for the client library Percona renames.
    grep -qs perconaserverclient "$PERCONA_SRC/libmysql/CMakeLists.txt" \
        || die "--percona-src: ${PERCONA_SRC} is not a Percona Server source tree"
    PERCONA_SRC_GIVEN=true
else
    PERCONA_SRC="${BUILD_DIR}/percona-server"
fi

# Resolve versions.  TidesDB defaults to the release this TideSQL is paired with; Percona Server
# defaults to the newest release of the newest line TideSQL is tested against, so a patch release
# is picked up without pinning it.
if [[ -z "$TIDESDB_VERSION" ]]; then
    TIDESDB_VERSION="${TIDESDB_PINNED_VERSION}"
    info "TidesDB: using the paired release ${TIDESDB_VERSION} (override with --tidesdb-version)"
fi
# a release line alone, such as 8.4, names that line's newest tag.
[[ -z "$PERCONA_VERSION" ]] && PERCONA_VERSION="${PERCONA_DEFAULT_LINE}"
if [[ "$PERCONA_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    info "Fetching the newest Percona Server ${PERCONA_VERSION} tag from GitHub..."
    PERCONA_VERSION="$(get_latest_percona_version "${PERCONA_VERSION}")" \
        || die "--percona-version: no Percona Server ${PERCONA_VERSION} release found"
fi

# Auto-sizing box drawing 
# Usage:
# draw_box <border_color> <title> <array_varname>
# where <array_varname> is the name of a bash array holding the body lines.
# The box auto-sizes to fit the widest visible line (ANSI codes stripped).
_strip_ansi() { echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

draw_box() {
    local color="$1" title="$2" arr_name="$3"
    local -n _lines="${arr_name}"

    # Measure the widest visible line (title + all body lines)
    local max_w=0 plain
    plain="$(_strip_ansi "$title")"
    (( ${#plain} > max_w )) && max_w=${#plain}
    for line in "${_lines[@]}"; do
        plain="$(_strip_ansi "$line")"
        (( ${#plain} > max_w )) && max_w=${#plain}
    done

    # Box inner width = max visible line + 2 (1 space padding each side)
    local W=$max_w
    local border
    border="$(printf '═%.0s' $(seq 1 $((W + 2))))"

    _box_row() {
        local text="$1"
        plain="$(_strip_ansi "$text")"
        local pad=$(( W - ${#plain} ))
        (( pad < 0 )) && pad=0
        printf "${color}║${NC} %b%*s ${color}║${NC}\n" "$text" "$pad" ""
    }

    echo ""
    echo -e "${color}╔${border}╗${NC}"
    _box_row "${color}${title}${NC}"
    echo -e "${color}╠${border}╣${NC}"
    for line in "${_lines[@]}"; do
        _box_row "$line"
    done
    echo -e "${color}╚${border}╝${NC}"
    echo ""
}

# Print configuration 
_cfg_lines=(
    "TidesDB version  : ${GREEN}${TIDESDB_VERSION}${NC}"
    "Percona version  : ${GREEN}${PERCONA_VERSION}${NC}"
    "TidesDB prefix   : ${GREEN}${TIDESDB_PREFIX}${NC}"
    "Percona prefix   : ${GREEN}${PERCONA_PREFIX}${NC}"
    "Build directory  : ${GREEN}${BUILD_DIR}${NC}"
    "Parallel jobs    : ${GREEN}${JOBS}${NC}"
    "Detected OS      : ${GREEN}${OS}${NC}"
    "PGO build        : ${GREEN}${PGO_ENABLED}${NC}"
    "Allocator        : ${GREEN}${ALLOCATOR}${NC}"
)
if [[ -n "$SKIP_ENGINES" ]]; then
    _cfg_lines+=("Skip engines     : ${YELLOW}${SKIP_ENGINES}${NC}")
fi
_cfg_lines+=("TideSQL repo     : ${GREEN}${SCRIPT_DIR}${NC}")

draw_box "${CYAN}" "TIDESQL Installer" _cfg_lines

# Privilege helper (sudo on Unix only when needed, direct on Windows) 
# Uses sudo only when the target prefix directory is not writable by the
# current user, avoiding root-owned files in user-writable prefixes.
_needs_sudo() {
    local dir="$1"
    # Walk up to find the first existing ancestor
    while [[ ! -d "$dir" ]]; do
        dir="$(dirname "$dir")"
    done
    [[ ! -w "$dir" ]]
}

run_privileged() {
    if [[ "$OS" == "windows" ]]; then
        "$@"
    elif _needs_sudo "${PERCONA_PREFIX}"; then
        sudo "$@"
    else
        "$@"
    fi
}

run_privileged_tidesdb() {
    if [[ "$OS" == "windows" ]]; then
        "$@"
    elif _needs_sudo "${TIDESDB_PREFIX}"; then
        sudo "$@"
    else
        "$@"
    fi
}

install_deps() {
    if $SKIP_DEPS; then
        warn "Skipping dependency installation (--skip-deps)"
        return
    fi

    info "Installing system dependencies for ${OS}..."

    # Per-OS package name for the selected allocator (empty for 'system').
    local allocator_pkg=""
    case "$OS:$ALLOCATOR" in
        debian:jemalloc)  allocator_pkg="libjemalloc-dev" ;;
        debian:mimalloc)  allocator_pkg="libmimalloc-dev" ;;
        debian:tcmalloc)  allocator_pkg="libgoogle-perftools-dev" ;;
        redhat:jemalloc)  allocator_pkg="jemalloc-devel" ;;
        redhat:mimalloc)  allocator_pkg="mimalloc-devel" ;;
        redhat:tcmalloc)  allocator_pkg="gperftools-devel" ;;
        arch:jemalloc)    allocator_pkg="jemalloc" ;;
        arch:mimalloc)    allocator_pkg="mimalloc" ;;
        arch:tcmalloc)    allocator_pkg="gperftools" ;;
        macos:jemalloc)   allocator_pkg="jemalloc" ;;
        macos:mimalloc)   allocator_pkg="mimalloc" ;;
        macos:tcmalloc)   allocator_pkg="gperftools" ;;
    esac
    [[ -n "$allocator_pkg" ]] && info "Allocator ${ALLOCATOR} -> installing ${allocator_pkg}"

    case "$OS" in
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y -qq \
                build-essential cmake ninja-build bison flex \
                libzstd-dev liblz4-dev libsnappy-dev \
                libncurses-dev libssl-dev libxml2-dev \
                libevent-dev libcurl4-openssl-dev \
                libaio-dev libtirpc-dev libudev-dev \
                libldap2-dev libsasl2-dev libkrb5-dev libgflags-dev \
                pkg-config git gnutls-dev \
                ${allocator_pkg}
            ;;
        redhat)
            sudo dnf install -y \
                gcc gcc-c++ cmake ninja-build bison flex \
                libzstd-devel lz4-devel snappy-devel \
                ncurses-devel openssl-devel libxml2-devel \
                libevent-devel libcurl-devel \
                libaio-devel libtirpc-devel rpcgen systemd-devel \
                openldap-devel cyrus-sasl-devel krb5-devel gflags-devel \
                pkg-config git gnutls-devel \
                ${allocator_pkg}
            ;;
        arch)
            sudo pacman -Sy --noconfirm --needed \
                base-devel cmake ninja bison flex \
                zstd lz4 snappy \
                ncurses openssl libxml2 \
                libevent curl \
                libaio libtirpc rpcsvc-proto systemd-libs \
                libldap libsasl krb5 gflags \
                pkg-config git gnutls \
                ${allocator_pkg}
            ;;
        macos)
            if ! command -v brew &>/dev/null; then
                die "Homebrew is required on macOS. Install from https://brew.sh"
            fi
            brew install cmake ninja bison flex \
                snappy lz4 zstd gnutls \
                ${allocator_pkg}
            ;;
        windows)
            if [[ -z "${VCPKG_ROOT:-}" ]]; then
                die "vcpkg not found. Set VCPKG_ROOT or install to C:/vcpkg.\n" \
                    "  git clone https://github.com/Microsoft/vcpkg.git C:/vcpkg\n" \
                    "  C:/vcpkg/bootstrap-vcpkg.bat"
            fi

            info "Installing vcpkg packages..."
            "${VCPKG_ROOT}/vcpkg.exe" install \
                zstd:x64-windows lz4:x64-windows \
                snappy:x64-windows pthreads:x64-windows

            if ! command -v cmake &>/dev/null; then
                die "CMake not found. Install via: choco install cmake"
            fi
            ;;
        linux-unknown)
            warn "Unrecognized Linux distribution."
            warn "Install manually: cmake, build-essential/gcc, libzstd-dev, liblz4-dev,"
            warn "  libsnappy-dev, libncurses-dev, libssl-dev, libxml2-dev, libevent-dev,"
            warn "  libcurl-dev, libaio-dev, libtirpc-dev, libudev-dev, libldap2-dev, libsasl2-dev,"
            warn "  libkrb5-dev, libgflags-dev, bison, flex, pkg-config, git, gnutls-dev"
            warn "Then re-run with --skip-deps"
            die "Cannot auto-install dependencies for this distribution"
            ;;
        *)
            die "Unsupported OS. Install dependencies manually and re-run with --skip-deps"
            ;;
    esac

    ok "Dependencies installed"
}

# Build and install TidesDB library 
build_tidesdb() {
    if $SKIP_TIDESDB; then
        warn "Skipping TidesDB build (--skip-tidesdb)"
        # Quick check that the library exists at the expected prefix
        local found=false
        for libdir in lib64 lib; do
            for ext in so dylib a lib; do
                if ls "${TIDESDB_PREFIX}/${libdir}/libtidesdb"*.${ext} &>/dev/null 2>&1; then
                    found=true; break 2
                fi
            done
        done
        if ! $found; then
            if [[ "$OS" != "windows" ]] && ldconfig -p 2>/dev/null | grep -q libtidesdb; then
                found=true
            fi
        fi
        if ! $found; then
            warn "libtidesdb not found at ${TIDESDB_PREFIX}/lib - Percona Server build may fail"
        fi
        return
    fi

    info "Building TidesDB ${TIDESDB_VERSION}..."

    local tidesdb_src="${BUILD_DIR}/tidesdb-lib"

    if [[ -d "${tidesdb_src}" ]]; then
        info "Removing previous TidesDB source..."
        rm -rf "${tidesdb_src}"
    fi

    git clone --depth 1 --branch "${TIDESDB_VERSION}" \
        https://github.com/tidesdb/tidesdb.git "${tidesdb_src}"

    local cmake_args=(
        -S "${tidesdb_src}"
        -B "${tidesdb_src}/build"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="${TIDESDB_PREFIX}"
        -DTIDESDB_BUILD_TESTS=OFF
        -DBUILD_SHARED_LIBS=ON
    )

    case "$ALLOCATOR" in
        jemalloc)
            cmake_args+=(-DTIDESDB_WITH_JEMALLOC=ON)
            info "Building libtidesdb with jemalloc"
            ;;
        mimalloc)
            cmake_args+=(-DTIDESDB_WITH_MIMALLOC=ON)
            info "Building libtidesdb with mimalloc"
            ;;
        tcmalloc)
            cmake_args+=(-DTIDESDB_WITH_TCMALLOC=ON)
            info "Building libtidesdb with tcmalloc"
            ;;
    esac

    case "$OS" in
        macos)
            local sdk_root
            sdk_root="$(xcrun --show-sdk-path 2>/dev/null || true)"
            [[ -n "$sdk_root" ]] && cmake_args+=(-DCMAKE_OSX_SYSROOT="${sdk_root}")
            ;;
        windows)
            cmake_args+=(
                -G "Visual Studio 17 2022" -A x64
                -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
            )
            ;;
    esac

    cmake "${cmake_args[@]}"
    cmake --build "${tidesdb_src}/build" --config Release --parallel "${JOBS}"
    run_privileged_tidesdb cmake --install "${tidesdb_src}/build" --config Release

    # Show which allocator is actually linked so users can verify after a build.
    if [[ "$ALLOCATOR" != "system" ]]; then
        local installed_lib
        installed_lib="$(find_libtidesdb || true)"
        if [[ -n "$installed_lib" ]] && command -v ldd &>/dev/null; then
            local allocator_linkage
            allocator_linkage="$(ldd "$installed_lib" 2>/dev/null | grep -Eo '(jemalloc|mimalloc|tcmalloc)[^ ]*' | head -1 || true)"
            if [[ -n "$allocator_linkage" ]]; then
                ok "libtidesdb is linked against ${allocator_linkage}"
            else
                warn "Requested allocator ${ALLOCATOR} but none of libjemalloc/libmimalloc/libtcmalloc appears in \`ldd ${installed_lib}\`."
                warn "  Check cmake output above for missing packages."
            fi
        fi
    fi

    # Update shared library cache on Linux
    case "$OS" in
        debian|redhat|arch|linux-unknown)
            sudo ldconfig
            ;;
    esac

    ok "TidesDB ${TIDESDB_VERSION} installed to ${TIDESDB_PREFIX}"
}

# Clone Percona Server and copy TidesDB storage engine 
prepare_percona() {
    local mysql_src="${PERCONA_SRC}"

    if $PERCONA_SRC_GIVEN; then
        info "Using the Percona Server source tree at ${mysql_src} (not cloning)"
    else
        info "Cloning Percona Server (tag: ${PERCONA_VERSION})..."
        if [[ -d "${mysql_src}" ]]; then
            info "Removing previous Percona Server source..."
            rm -rf "${mysql_src}"
        fi
        # MyRocks's RocksDB, the coredumper and the KMIP keyring library come in as submodules,
        # and the server's cmake fails without them.
        git clone --depth 1 --branch "${PERCONA_VERSION}" \
            --recurse-submodules --shallow-submodules \
            https://github.com/percona/percona-server.git "${mysql_src}"
    fi

    info "Copying TidesDB storage engine plugin into Percona Server source..."
    cp -R "${SCRIPT_DIR}/tidesdb" "${mysql_src}/storage/"

    # The server's mtr resolves a suite name against mysql-test/suite, plugin/<suite>/tests and a few
    # internal/ paths -- it does not search storage/<engine>/mysql-test.  Without this the build is
    # green and the suite is simply never found, so the suites are placed where mtr looks.
    info "Installing the TideSQL test suites into the server's mysql-test tree..."
    local suite_dir="${mysql_src}/mysql-test/suite"
    mkdir -p "${suite_dir}"
    rm -rf "${suite_dir}/tidesdb" "${suite_dir}/tidesdb_rpl"
    cp -R "${SCRIPT_DIR}/tidesdb/mysql-test/tidesdb"     "${suite_dir}/tidesdb"
    cp -R "${SCRIPT_DIR}/tidesdb/mysql-test/tidesdb_rpl" "${suite_dir}/tidesdb_rpl"

    ok "Percona Server source prepared"
}

# The cmake arguments every build of the server takes, whichever way it is optimized.  Appends to
# the caller's cmake_args, which bash's dynamic scope makes visible here.
add_server_cmake_args() {
    # The server's own unit tests are not what this script builds for and roughly double the
    # build.  Percona's cmake would otherwise take the distribution's packaging flags on Debian
    # and RHEL, which add link time optimization the plugin is not built for.
    cmake_args+=(
        -DWITH_UNIT_TESTS=OFF
        -DWITH_PACKAGE_FLAGS=OFF
    )

    # Boost ships in the server tree from 8.4 on.  8.0 names an exact Boost release instead and
    # downloads it once into the build directory, where a later run finds it again.
    if [[ -d "${PERCONA_SRC}/extra/boost" ]]; then
        cmake_args+=(-DWITH_BOOST="${PERCONA_SRC}/extra/boost")
    else
        cmake_args+=(-DDOWNLOAD_BOOST=1 -DWITH_BOOST="${BUILD_DIR}/boost")
    fi

    # Disable skipped engines
    if [[ -n "$SKIP_ENGINES" ]]; then
        local _engines _eng
        IFS=',' read -ra _engines <<< "$SKIP_ENGINES"
        for _eng in "${_engines[@]}"; do
            _eng="$(echo "$_eng" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
            cmake_args+=("-DWITHOUT_${_eng}_STORAGE_ENGINE=1")
            info "Skipping storage engine: ${_eng}"
        done
    fi
}

build_percona() {
    info "Building Percona Server with InnoDB + TidesDB..."

    local mysql_src="${PERCONA_SRC}"
    local mysql_build="${mysql_src}/build"

    mkdir -p "${mysql_build}"

    # Full-featured Percona Server build with TidesDB added
    local cmake_args=(
        -S "${mysql_src}"
        -B "${mysql_build}"
        -DCMAKE_INSTALL_PREFIX="${PERCONA_PREFIX}"
        -DCMAKE_BUILD_TYPE=RelWithDebInfo
    )

    # Hint so the TidesDB plugin's FIND_LIBRARY / FIND_PATH succeed
    # (CMakeLists.txt uses ENV TIDESDB_ROOT in HINTS)
    export TIDESDB_ROOT="${TIDESDB_PREFIX}"

    add_server_cmake_args

    case "$OS" in
        macos)
            local sdk_root cc cxx
            sdk_root="$(xcrun --show-sdk-path 2>/dev/null || true)"
            cc="$(xcrun -find clang 2>/dev/null || true)"
            cxx="$(xcrun -find clang++ 2>/dev/null || true)"

            [[ -n "$cc" ]]       && cmake_args+=(-DCMAKE_C_COMPILER="${cc}")
            [[ -n "$cxx" ]]      && cmake_args+=(-DCMAKE_CXX_COMPILER="${cxx}")
            [[ -n "$sdk_root" ]] && cmake_args+=(-DCMAKE_OSX_SYSROOT="${sdk_root}")
            cmake_args+=(
                -DCMAKE_PREFIX_PATH="${TIDESDB_PREFIX}"
                "-DCMAKE_C_FLAGS=-Wno-nullability-completeness"
                "-DCMAKE_CXX_FLAGS=-Wno-nullability-completeness"
                -DWITH_SSL=system
                -G Ninja
            )
            ;;
        windows)
            cmake_args+=(
                -G "Visual Studio 17 2022" -A x64
                "-DCMAKE_PREFIX_PATH=${TIDESDB_PREFIX};${VCPKG_ROOT}/installed/x64-windows"
            )
            ;;
        *)
            cmake_args+=(-DCMAKE_PREFIX_PATH="${TIDESDB_PREFIX}")
            ;;
    esac

    cmake "${cmake_args[@]}"
    cmake --build "${mysql_build}" --config RelWithDebInfo --parallel "${JOBS}"

    ok "Percona Server build complete"
}

install_percona() {
    info "Installing Percona Server to ${PERCONA_PREFIX}..."

    local mysql_build="${PERCONA_SRC}/build"
    local build_config="RelWithDebInfo"
    if $PGO_ENABLED; then
        build_config="Release"
    fi

    run_privileged cmake --install "${mysql_build}" --config "${build_config}"

    register_mysql_client_lib

    ok "Percona Server installed to ${PERCONA_PREFIX}"
}

# Register the server's client library with the platform's dynamic linker so
# external tools that dlopen it (HammerDB's mysqltcl, sysbench-mysql, etc.)
# can find it without per-shell setup.  Percona builds the library stock
# MySQL calls libmysqlclient as libperconaserverclient on Unix, with the same
# interface, so a tool that asks for libmysqlclient by name needs a symlink
# to it.
#
# The mysql CLI itself is usually statically linked against the connector
# and so "the client works" even when the .so isn't on the linker's path --
# that fools you into thinking the install is healthy when third-party
# bindings will still fail at dlopen time.  This step closes that gap.
#
# Platform handling:
#   - Linux : write /etc/ld.so.conf.d/percona-tidesql.conf, run ldconfig.
#   - macOS : the dylib carries install_name=@rpath/libperconaserverclient.dylib so
#             tools linked at build time resolve via rpath.  Tools that
#             dlopen by bare filename need DYLD_LIBRARY_PATH; we print
#             the guidance instead of touching system state.
#   - Windows: same as macOS, with PATH and LoadLibraryEx (libmysql.dll).
register_mysql_client_lib() {
    case "$OS" in
        debian|redhat|arch|linux-unknown)
            local mysql_libdir=""
            local cand
            for cand in \
                "${PERCONA_PREFIX}/lib" \
                "${PERCONA_PREFIX}/lib64" \
                "${PERCONA_PREFIX}/lib/mysql" \
                "${PERCONA_PREFIX}/lib/x86_64-linux-gnu"; do
                if [[ -f "${cand}/libperconaserverclient.so" ]]; then
                    mysql_libdir="$cand"
                    break
                fi
            done

            if [[ -z "$mysql_libdir" ]]; then
                warn "Could not locate libperconaserverclient.so under ${PERCONA_PREFIX}"
                warn "  Tools that dlopen it (HammerDB, sysbench) may fail."
                warn "  Find the lib with:  find ${PERCONA_PREFIX} -name 'libperconaserverclient.so*'"
                return 0
            fi

            local ldconf=/etc/ld.so.conf.d/percona-tidesql.conf
            local need_write=1
            if [[ -f "$ldconf" ]] && grep -qxF "$mysql_libdir" "$ldconf" 2>/dev/null; then
                need_write=0
            fi
            # /etc/ld.so.conf.d always needs root regardless of where
            # PERCONA_PREFIX lives, so reach for sudo directly rather than
            # run_privileged (which gates on the install prefix being
            # root-owned).  If we cannot escalate or the write fails, fall
            # back to per-shell guidance instead of aborting the install.
            local ld_registered=0
            if (( need_write )); then
                info "Registering ${mysql_libdir} with ldconfig (writing ${ldconf})..."
                if [[ -w "$(dirname "$ldconf")" ]] && echo "$mysql_libdir" > "$ldconf" 2>/dev/null; then
                    ld_registered=1
                elif command -v sudo >/dev/null 2>&1 \
                     && echo "$mysql_libdir" | sudo tee "$ldconf" >/dev/null 2>&1; then
                    ld_registered=1
                else
                    warn "Could not write ${ldconf} (no permission and no sudo)."
                    warn "  Tools that dlopen libperconaserverclient will need:"
                    warn "    export LD_LIBRARY_PATH=${mysql_libdir}:\$LD_LIBRARY_PATH"
                fi
            else
                ld_registered=1
            fi

            if (( ld_registered )); then
                if command -v sudo >/dev/null 2>&1; then
                    sudo ldconfig 2>/dev/null || ldconfig 2>/dev/null || true
                else
                    ldconfig 2>/dev/null || true
                fi
                if ldconfig -p 2>/dev/null | grep -q 'libperconaserverclient\.so'; then
                    ok "libperconaserverclient is now resolvable via ldconfig"
                else
                    warn "ldconfig ran but libperconaserverclient still not resolvable."
                    warn "  Inspect:  ldconfig -p | grep libperconaserverclient"
                    warn "  Inspect:  cat ${ldconf}"
                fi
            fi
            ;;
        macos)
            info "macOS: skipping system-wide registration."
            info "  Tools linked against ${PERCONA_PREFIX}/lib/libperconaserverclient.dylib at"
            info "  build time pick it up via @rpath.  For tools that dlopen by"
            info "  bare filename, export DYLD_LIBRARY_PATH=${PERCONA_PREFIX}/lib"
            info "  in the shell that runs them."
            ;;
        windows)
            info "Windows: skipping system-wide registration."
            info "  Add ${PERCONA_PREFIX}/lib to your PATH so LoadLibraryEx"
            info "  finds libmysql.dll for tools that load it by bare name."
            ;;
        freebsd|netbsd|openbsd)
            # BSD ldconfig is similar in spirit to Linux's but lives in
            # different files and supports a live -m flag.  Try the most
            # appropriate path; the live add is sufficient for the current
            # process and any child it spawns until reboot.
            local mysql_libdir=""
            local cand
            for cand in "${PERCONA_PREFIX}/lib" "${PERCONA_PREFIX}/lib64"; do
                if [[ -f "${cand}/libperconaserverclient.so" ]]; then
                    mysql_libdir="$cand"
                    break
                fi
            done
            if [[ -z "$mysql_libdir" ]]; then
                warn "BSD: could not locate libperconaserverclient.so under ${PERCONA_PREFIX}"
                return 0
            fi

            case "$OS" in
                freebsd)
                    info "FreeBSD: ldconfig -m ${mysql_libdir}"
                    run_privileged ldconfig -m "$mysql_libdir"
                    # Persist across reboot by adding the dir to one of
                    # the standard conf files.  /usr/local/libdata/ldconfig
                    # is the modern snippets dir; fall back to editing
                    # /etc/ld-elf.so.conf if the snippets dir isn't there.
                    if [[ -d /usr/local/libdata/ldconfig ]]; then
                        local snip=/usr/local/libdata/ldconfig/tidesql-percona
                        echo "$mysql_libdir" | run_privileged tee "$snip" >/dev/null
                        ok "FreeBSD: persisted via ${snip}"
                    elif [[ -f /etc/ld-elf.so.conf ]]; then
                        if ! grep -qxF "$mysql_libdir" /etc/ld-elf.so.conf 2>/dev/null; then
                            echo "$mysql_libdir" | run_privileged tee -a /etc/ld-elf.so.conf >/dev/null
                            ok "FreeBSD: appended to /etc/ld-elf.so.conf"
                        fi
                    fi
                    ;;
                netbsd)
                    info "NetBSD: ldconfig -mr ${mysql_libdir}"
                    run_privileged ldconfig -mr "$mysql_libdir"
                    if [[ -f /etc/ld.so.conf ]] && \
                       ! grep -qxF "$mysql_libdir" /etc/ld.so.conf 2>/dev/null; then
                        echo "$mysql_libdir" | run_privileged tee -a /etc/ld.so.conf >/dev/null
                        ok "NetBSD: appended to /etc/ld.so.conf"
                    fi
                    ;;
                openbsd)
                    # OpenBSD's ldconfig only consults /etc/rc.conf's
                    # ldconfig=... and the per-boot hints file; there is
                    # no .d/ snippet dir.  Adding the dir is therefore an
                    # rc.conf edit which is too invasive for an installer
                    # to do automatically.  Print the exact command.
                    info "OpenBSD: append ${mysql_libdir} to the ldconfig= line in /etc/rc.conf"
                    info "  then run:  sudo ldconfig \$(cat /etc/rc.conf | sed -n 's/^ldconfig=\"\\(.*\\)\"/\\1/p')"
                    info "  or per-session:  export LD_LIBRARY_PATH=${mysql_libdir}:\$LD_LIBRARY_PATH"
                    ;;
            esac

            if command -v ldconfig >/dev/null 2>&1 && \
               ldconfig -r 2>/dev/null | grep -q 'libperconaserverclient\.so'; then
                ok "libperconaserverclient is now resolvable via ldconfig"
            fi
            ;;
        *)
            warn "Unknown OS '$OS' -- skipped libperconaserverclient registration."
            ;;
    esac
}

# Initialize Percona Server data directory & enable plugins 
setup_mysql() {
    local datadir="${PERCONA_PREFIX}/data"

    # Determine whether this is a system-level install (needs root/mysql user)
    # or a user-local install (run everything as current user).
    local use_mysql_user=false
    if [[ "$OS" != "windows" ]] && _needs_sudo "${PERCONA_PREFIX}"; then
        use_mysql_user=true
        # Ensure mysql user exists
        if ! id -u mysql &>/dev/null; then
            info "Creating mysql system user..."
            sudo useradd -r -s /bin/false -d "${datadir}" mysql 2>/dev/null || true
        fi
    fi

    local run_user
    if $use_mysql_user; then
        run_user="mysql"
    else
        run_user="$(id -un)"
    fi

    # Write config before init so mysqld --initialize-insecure can pick it up
    local cnf_file="${PERCONA_PREFIX}/my.cnf"
    if [[ "$OS" == "windows" ]]; then
        cnf_file="${PERCONA_PREFIX}/my.ini"
    fi

    if [[ ! -f "${cnf_file}" ]]; then
        info "Creating Percona Server configuration at ${cnf_file}..."

        local socket_line="" client_socket="" socket_path="" plugin_ext="so"
        local user_line=""
        if [[ "$OS" == "windows" ]]; then
            plugin_ext="dll"
        else
            socket_path="/tmp/mysql.sock"
            socket_line="socket  = ${socket_path}"
            client_socket="socket = ${socket_path}"
            user_line="user    = ${run_user}"
        fi

        # When --allocator selects a non-system allocator, locate the
        # matching shared library so we can wire it into mysqld_safe's
        # malloc-lib option. mysqld_safe LD_PRELOADs malloc-lib before
        # forking mysqld, which makes the allocator's TLS reservations
        # happen before the static TLS budget is exhausted, sidestepping
        # the "cannot allocate memory in static TLS block" failure when
        # the plugin pulls in libjemalloc/mimalloc/tcmalloc via dlopen.
        local mysqld_safe_section=""
        if [[ "$OS" != "windows" && "$ALLOCATOR" != "system" ]]; then
            local alloc_pattern alloc_lib=""
            case "$ALLOCATOR" in
                jemalloc) alloc_pattern='libjemalloc\.so\.2' ;;
                mimalloc) alloc_pattern='libmimalloc\.so(\.[0-9]+)?' ;;
                tcmalloc) alloc_pattern='libtcmalloc\.so(\.[0-9]+)?' ;;
            esac
            if [[ -n "$alloc_pattern" ]]; then
                alloc_lib=$(ldconfig -p 2>/dev/null \
                            | awk -v pat="$alloc_pattern" \
                                  '$1 ~ ("^"pat"$") {print $NF; exit}')
            fi
            if [[ -n "$alloc_lib" && -f "$alloc_lib" ]]; then
                mysqld_safe_section="
[mysqld_safe]
# Preload the ${ALLOCATOR} allocator before forking mysqld so the
# plugin's transitive libjemalloc/mimalloc/tcmalloc load does not run
# out of static TLS slots.
malloc-lib = ${alloc_lib}"
            else
                warn "Allocator ${ALLOCATOR} requested but ${alloc_pattern} not found via ldconfig; mysqld_safe malloc-lib will not be set"
            fi
        fi

        local cnf_content
        cnf_content="[mysqld]
basedir = ${PERCONA_PREFIX}
datadir = ${datadir}
port    = 3306
${socket_line}
${user_line}
pid-file = ${datadir}/mysql.pid
log-error = ${datadir}/mysql.err

# Networking
bind-address = 127.0.0.1
max_connections = 151

# InnoDB
default_storage_engine = InnoDB
innodb_buffer_pool_size = 256M
innodb_redo_log_capacity = 96M
innodb_flush_log_at_trx_commit = 1
innodb_file_per_table = ON

# Logging
slow_query_log = ON
slow_query_log_file = ${datadir}/slow.log
long_query_time = 2

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci

# TidesDB plugin - loaded at startup
plugin_load_add = ha_tidesdb.${plugin_ext}

# TidesDB settings (tune as needed)
tidesdb_flush_threads = 4
tidesdb_compaction_threads = 4
tidesdb_block_cache_size = 256M
tidesdb_max_open_sstables = 256
tidesdb_log_level = WARN
tidesdb_memtable_write_buffer_size = 256M

[client]
port = 3306
${client_socket}
default-character-set = utf8mb4

[mysqldump]
quick
max_allowed_packet = 64M

${mysqld_safe_section}"

        if [[ "$OS" == "windows" ]]; then
            mkdir -p "$(dirname "${cnf_file}")"
            echo "$cnf_content" > "${cnf_file}"
        else
            run_privileged mkdir -p "$(dirname "${cnf_file}")"
            if $use_mysql_user; then
                echo "$cnf_content" | sudo tee "${cnf_file}" > /dev/null
            else
                echo "$cnf_content" > "${cnf_file}"
            fi
        fi
        ok "Configuration written to ${cnf_file}"
    else
        warn "Config file already exists at ${cnf_file}, skipping"
    fi

    info "Initializing Percona Server data directory..."

    # Percona Server initializes its own data directory: mysqld --initialize-insecure creates the
    # mysql.* system tables and a passwordless root, with no separate bootstrap script.
    local mysqld_bin=""
    for candidate in \
        "${PERCONA_PREFIX}/bin/mysqld" \
        "${PERCONA_SRC}/build/runtime_output_directory/mysqld"; do
        if [[ -x "$candidate" ]]; then
            mysqld_bin="$candidate"
            break
        fi
    done

    if [[ -z "$mysqld_bin" ]]; then
        # Failing loudly here beats leaving a fully built server pointed at an empty data
        # directory, which only shows up later as "Table 'mysql.plugin' doesn't exist".
        error "Could not find mysqld. Looked in:"
        error "  ${PERCONA_PREFIX}/bin/"
        error "  ${BUILD_DIR}/percona-server/build/runtime_output_directory/"
        error "Cannot initialize the data directory. Aborting."
        exit 1
    elif [[ -d "${datadir}/mysql" ]]; then
        warn "Data directory already exists at ${datadir}, skipping initialization"
    else
        # --no-defaults keeps the initializing mysqld from reading ${cnf_file}, which already
        # carries `plugin_load_add = ha_tidesdb.so`.  That would make it dlopen the plugin and
        # pull in libjemalloc through libtidesdb; with jemalloc not preloaded into that process
        # the dlopen fails with "cannot allocate memory in static TLS block" and the data
        # directory is left empty.  Initialization needs only basedir, datadir and user, all
        # passed on the command line.
        local -a install_db_env=()
        if [[ "$ALLOCATOR" == "jemalloc" && "$OS" != "windows" ]]; then
            local jelib
            jelib=$(ldconfig -p 2>/dev/null \
                    | awk '/libjemalloc\.so\.2/ {print $NF; exit}')
            if [[ -n "$jelib" && -f "$jelib" ]]; then
                install_db_env+=("LD_PRELOAD=$jelib")
            fi
        fi

        if [[ "$OS" == "windows" ]]; then
            "${mysqld_bin}" \
                --no-defaults \
                --initialize-insecure \
                --basedir="${PERCONA_PREFIX}" \
                --datadir="${datadir}"
        elif $use_mysql_user; then
            sudo env "${install_db_env[@]}" "${mysqld_bin}" \
                --no-defaults \
                --initialize-insecure \
                --user=mysql \
                --basedir="${PERCONA_PREFIX}" \
                --datadir="${datadir}"
            sudo chown -R mysql:mysql "${datadir}"
        else
            env "${install_db_env[@]}" "${mysqld_bin}" \
                --no-defaults \
                --initialize-insecure \
                --user="${run_user}" \
                --basedir="${PERCONA_PREFIX}" \
                --datadir="${datadir}"
        fi
        ok "Data directory initialized"
    fi

    # Set proper ownership on Unix (only needed for system-level installs)
    if $use_mysql_user && [[ -d "${datadir}" ]]; then
        sudo chown -R mysql:mysql "${datadir}"
    fi
}

print_summary() {
    local cnf_name="my.cnf"
    local start_cmd="${PERCONA_PREFIX}/bin/mysqld_safe"
    local test_dir="${PERCONA_SRC}/build/mysql-test"

    # Use the correct connect user, root for system installs, current user otherwise
    local connect_user="root"
    if [[ "$OS" != "windows" ]] && ! _needs_sudo "${PERCONA_PREFIX}"; then
        connect_user="$(id -un)"
    fi
    local connect_cmd="${PERCONA_PREFIX}/bin/mysql -u ${connect_user}"

    if [[ "$OS" == "windows" ]]; then
        cnf_name="my.ini"
        start_cmd="${PERCONA_PREFIX}/bin/mysqld.exe"
    fi

    local _summary_lines=(
        ""
        "TidesDB installed to : ${CYAN}${TIDESDB_PREFIX}${NC}"
        "Percona installed to : ${CYAN}${PERCONA_PREFIX}${NC}"
    )
    if $PGO_ENABLED; then
        _summary_lines+=("Build type           : ${CYAN}Release + PGO${NC}")
    fi
    if [[ "$ALLOCATOR" != "system" ]]; then
        local _vlib
        _vlib="$(find_libtidesdb || echo "${TIDESDB_PREFIX}/lib/libtidesdb.so")"
        _summary_lines+=(
            "Allocator            : ${CYAN}${ALLOCATOR}${NC}"
            ""
            "Verify the allocator is linked into libtidesdb:"
            "  ldd ${_vlib} | grep -E 'jemalloc|mimalloc|tcmalloc'"
            ""
            "mysqld_safe already preloads ${ALLOCATOR} via the [mysqld_safe]"
            "malloc-lib line written into the cnf, so a normal start needs nothing"
            "extra.  To preload it manually for a direct mysqld start (resolves"
            "the real path wherever ldconfig knows it, e.g. /usr/lib64 on RHEL):"
            "  LD_PRELOAD=\$(ldconfig -p | awk '/lib${ALLOCATOR}\\.so/ {print \$NF; exit}') \\"
            "    ${start_cmd} --defaults-file=${PERCONA_PREFIX}/${cnf_name} &"
        )
    fi
    _summary_lines+=(
        ""
        "Start Percona Server:"
        "  ${start_cmd} \\"
        "    --defaults-file=${PERCONA_PREFIX}/${cnf_name} &"
        ""
        "Connect:"
        "  ${connect_cmd}"
        ""
        "Verify TidesDB plugin:"
        "  SHOW PLUGINS;"
        "  -- or if not auto-loaded:"
        "  INSTALL SONAME 'ha_tidesdb';"
        ""
        "Quick test:"
        "  CREATE TABLE t (id INT PRIMARY KEY) ENGINE=TIDESDB;"
        "  INSERT INTO t VALUES (1), (2), (3);"
        "  SELECT * FROM t;"
        "  DROP TABLE t;"
        ""
        "Run TidesDB test suite:"
        "  cd ${test_dir}"
        "  perl mtr --suite=tidesdb,tidesdb_rpl --parallel=4"
        ""
        "Add to PATH (optional):"
        "  export PATH=\"${PERCONA_PREFIX}/bin:\$PATH\""
        ""
    )

    draw_box "${GREEN}" "Installation Complete!" _summary_lines
}

# Rebuild only the TidesDB plugin (fast dev cycle) 
rebuild_plugin() {
    local mysql_src="${PERCONA_SRC}"
    local mysql_build="${mysql_src}/build"

    if [[ ! -d "${mysql_build}" ]]; then
        die "Percona Server build directory not found at ${mysql_build}.\n" \
            "  Run a full install first before using --rebuild-plugin."
    fi

    # Re-copy plugin source into the existing source tree.
    info "Copying TidesDB plugin source into Percona Server source tree..."
    cp -r "${SCRIPT_DIR}/tidesdb" "${mysql_src}/storage/"

    # And refresh the suites where Percona Server looks for them.  Copying the engine does not
    # carry them: Percona Server finds a suite under mysql-test/suite, never under the engine's
    # own directory, so a rebuild that skipped this would leave the previous build's
    # tests in place and quietly test the wrong thing.
    info "Refreshing the TideSQL test suites..."
    local suite_dir="${mysql_src}/mysql-test/suite"
    mkdir -p "${suite_dir}"
    rm -rf "${suite_dir}/tidesdb" "${suite_dir}/tidesdb_rpl"
    cp -R "${SCRIPT_DIR}/tidesdb/mysql-test/tidesdb"     "${suite_dir}/tidesdb"
    cp -R "${SCRIPT_DIR}/tidesdb/mysql-test/tidesdb_rpl" "${suite_dir}/tidesdb_rpl"

    # Point cmake at the TidesDB library
    export TIDESDB_ROOT="${TIDESDB_PREFIX}"

    # Build just the plugin target
    info "Building tidesdb plugin target (${JOBS} jobs)..."
    cmake --build "${mysql_build}" --target tidesdb --parallel "${JOBS}"

    # Find the built .so/.dylib/.dll and copy it into the installed plugin dir
    local plugin_ext="so"
    [[ "$OS" == "macos" ]]   && plugin_ext="dylib"
    [[ "$OS" == "windows" ]] && plugin_ext="dll"

    local built_so
    built_so="$(find "${mysql_build}" -name "ha_tidesdb.${plugin_ext}" -print -quit 2>/dev/null)"
    if [[ -z "$built_so" ]]; then
        die "Could not find ha_tidesdb.${plugin_ext} in ${mysql_build}"
    fi

    local plugin_dir="${PERCONA_PREFIX}/lib/plugin"
    if [[ ! -d "$plugin_dir" ]]; then
        plugin_dir="${PERCONA_PREFIX}/lib64/plugin"
    fi
    if [[ ! -d "$plugin_dir" ]]; then
        die "Plugin directory not found at ${PERCONA_PREFIX}/lib/plugin or lib64/plugin"
    fi

    info "Installing ha_tidesdb.${plugin_ext} -> ${plugin_dir}/"
    run_privileged cp -f "${built_so}" "${plugin_dir}/"

    ok "Plugin rebuilt and installed"

    # Determine config file & socket for restart hint
    local cnf_file="${PERCONA_PREFIX}/my.cnf"
    [[ "$OS" == "windows" ]] && cnf_file="${PERCONA_PREFIX}/my.ini"

    local _rebuild_lines=(
        ""
        "Plugin rebuilt : ${CYAN}${plugin_dir}/ha_tidesdb.${plugin_ext}${NC}"
        ""
        "Restart Percona Server to pick up the new plugin:"
        "  ${PERCONA_PREFIX}/bin/mysqladmin shutdown"
        "  ${PERCONA_PREFIX}/bin/mysqld_safe \\"
        "    --defaults-file=${cnf_file} &"
        ""
        "Run TidesDB test suite:"
        "  cd ${mysql_build}/mysql-test"
        "  perl mtr --suite=tidesdb,tidesdb_rpl --parallel=4"
        ""
    )

    draw_box "${GREEN}" "Plugin Rebuild Complete" _rebuild_lines
}

# PGO Phase 1 -- Instrument build 
pgo_instrument() {
    info "PGO Phase 1/3: Building Percona Server with profiling instrumentation..."

    local mysql_src="${PERCONA_SRC}"
    local mysql_build="${mysql_src}/build"
    local profile_dir="${BUILD_DIR}/pgo-profiles"

    mkdir -p "${profile_dir}"
    # Clean previous build to ensure instrumentation flags apply everywhere
    rm -rf "${mysql_build}"
    mkdir -p "${mysql_build}"

    local profraw="${profile_dir}/default-%m.profraw"

    local cmake_args=(
        -S "${mysql_src}"
        -B "${mysql_build}"
        -DCMAKE_INSTALL_PREFIX="${PERCONA_PREFIX}"
        -DCMAKE_BUILD_TYPE=Release
    )

    export TIDESDB_ROOT="${TIDESDB_PREFIX}"

    add_server_cmake_args

    case "$OS" in
        macos)
            local sdk_root cc cxx
            sdk_root="$(xcrun --show-sdk-path 2>/dev/null || true)"
            cc="$(xcrun -find clang 2>/dev/null || true)"
            cxx="$(xcrun -find clang++ 2>/dev/null || true)"

            [[ -n "$cc" ]]       && cmake_args+=(-DCMAKE_C_COMPILER="${cc}")
            [[ -n "$cxx" ]]      && cmake_args+=(-DCMAKE_CXX_COMPILER="${cxx}")
            [[ -n "$sdk_root" ]] && cmake_args+=(-DCMAKE_OSX_SYSROOT="${sdk_root}")
            cmake_args+=(
                -DCMAKE_PREFIX_PATH="${TIDESDB_PREFIX}"
                "-DCMAKE_C_FLAGS=-fprofile-instr-generate=${profraw} -Wno-nullability-completeness"
                "-DCMAKE_CXX_FLAGS=-fprofile-instr-generate=${profraw} -Wno-nullability-completeness"
                "-DCMAKE_EXE_LINKER_FLAGS=-fprofile-instr-generate"
                "-DCMAKE_SHARED_LINKER_FLAGS=-fprofile-instr-generate"
                "-DCMAKE_MODULE_LINKER_FLAGS=-fprofile-instr-generate"
                -DWITH_SSL=bundled
                -DWITH_PCRE=bundled
                -G Ninja
            )
            ;;
        windows)
            cmake_args+=(
                -G "Visual Studio 17 2022" -A x64
                "-DCMAKE_PREFIX_PATH=${TIDESDB_PREFIX};${VCPKG_ROOT}/installed/x64-windows"
            )
            warn "PGO is not supported on Windows (MSVC); falling back to normal Release build"
            ;;
        *)
            # -Wno-error instrumentation unlocks new -Wmaybe-uninitialized /
            # -Wformat-overflow warnings in bundled third-party code (pcre2,
            # NDB, etc.) that compile with -Werror on their own targets.
            cmake_args+=(
                -DCMAKE_PREFIX_PATH="${TIDESDB_PREFIX}"
                "-DCMAKE_C_FLAGS=-fprofile-generate=${profile_dir} -fprofile-update=atomic -Wno-error"
                "-DCMAKE_CXX_FLAGS=-fprofile-generate=${profile_dir} -fprofile-update=atomic -Wno-error"
                "-DCMAKE_EXE_LINKER_FLAGS=-fprofile-generate=${profile_dir}"
                "-DCMAKE_SHARED_LINKER_FLAGS=-fprofile-generate=${profile_dir}"
                "-DCMAKE_MODULE_LINKER_FLAGS=-fprofile-generate=${profile_dir}"
            )
            ;;
    esac

    cmake "${cmake_args[@]}"
    cmake --build "${mysql_build}" --config Release --parallel "${JOBS}"

    ok "PGO Phase 1/3: Instrumented build complete"
}

# PGO Phase 2 -- Train - run MTR to generate profile data 
pgo_train() {
    info "PGO Phase 2/3: Running TidesDB test suite to generate profile data..."

    local mysql_src="${PERCONA_SRC}"
    local mtr_dir="${mysql_src}/build/mysql-test"

    if [[ ! -f "${mtr_dir}/mtr" ]]; then
        die "MTR not found at ${mtr_dir}/mtr - instrumented build may have failed"
    fi

    # Run the tidesdb test suite as the training workload
    info "Running: perl mtr --suite=tidesdb --parallel=${JOBS}"
    (
        cd "${mtr_dir}" && \
        perl mtr --suite=tidesdb --parallel="${JOBS}" --force --retry=0
    ) || warn "Some MTR tests may have failed during PGO training (non-fatal)"

    local profile_dir="${BUILD_DIR}/pgo-profiles"
    local profile_count=0

    if [[ "$OS" == "macos" ]]; then
        # Clang generates .profraw files; merge them into a single .profdata
        profile_count="$(find "${profile_dir}" -name '*.profraw' 2>/dev/null | wc -l)"
        if [[ "${profile_count}" -eq 0 ]]; then
            die "No profile data generated in ${profile_dir} - PGO training failed"
        fi
        info "Merging ${profile_count} .profraw files..."
        xcrun llvm-profdata merge -output="${profile_dir}/default.profdata" \
            "${profile_dir}"/*.profraw
    else
        # GCC generates .gcda files
        profile_count="$(find "${profile_dir}" -name '*.gcda' 2>/dev/null | wc -l)"
        if [[ "${profile_count}" -eq 0 ]]; then
            die "No profile data generated in ${profile_dir} - PGO training failed"
        fi
    fi

    ok "PGO Phase 2/3: Training complete (${profile_count} profile files generated)"
}

# PGO Phase 3 -- Optimized rebuild using profile data 
pgo_optimize() {
    info "PGO Phase 3/3: Rebuilding Percona Server with profile-guided optimizations..."

    local mysql_src="${PERCONA_SRC}"
    local mysql_build="${mysql_src}/build"
    local profile_dir="${BUILD_DIR}/pgo-profiles"

    # Clean the build but keep the profile data
    rm -rf "${mysql_build}"
    mkdir -p "${mysql_build}"

    local profdata="${profile_dir}/default.profdata"

    local cmake_args=(
        -S "${mysql_src}"
        -B "${mysql_build}"
        -DCMAKE_INSTALL_PREFIX="${PERCONA_PREFIX}"
        -DCMAKE_BUILD_TYPE=Release
    )

    export TIDESDB_ROOT="${TIDESDB_PREFIX}"

    add_server_cmake_args

    case "$OS" in
        macos)
            local sdk_root cc cxx
            sdk_root="$(xcrun --show-sdk-path 2>/dev/null || true)"
            cc="$(xcrun -find clang 2>/dev/null || true)"
            cxx="$(xcrun -find clang++ 2>/dev/null || true)"

            [[ -n "$cc" ]]       && cmake_args+=(-DCMAKE_C_COMPILER="${cc}")
            [[ -n "$cxx" ]]      && cmake_args+=(-DCMAKE_CXX_COMPILER="${cxx}")
            [[ -n "$sdk_root" ]] && cmake_args+=(-DCMAKE_OSX_SYSROOT="${sdk_root}")
            cmake_args+=(
                -DCMAKE_PREFIX_PATH="${TIDESDB_PREFIX}"
                "-DCMAKE_C_FLAGS=-fprofile-instr-use=${profdata} -Wno-nullability-completeness"
                "-DCMAKE_CXX_FLAGS=-fprofile-instr-use=${profdata} -Wno-nullability-completeness"
                -DWITH_SSL=bundled
                -DWITH_PCRE=bundled
                -G Ninja
            )
            ;;
        windows)
            cmake_args+=(
                -G "Visual Studio 17 2022" -A x64
                "-DCMAKE_PREFIX_PATH=${TIDESDB_PREFIX};${VCPKG_ROOT}/installed/x64-windows"
            )
            ;;
        *)
            # Same -Wno-error reasoning as pgo_instrument, -fprofile-use can
            # still perturb warning output vs a vanilla Release build.
            cmake_args+=(
                -DCMAKE_PREFIX_PATH="${TIDESDB_PREFIX}"
                "-DCMAKE_C_FLAGS=-fprofile-use=${profile_dir} -fprofile-correction -Wno-error"
                "-DCMAKE_CXX_FLAGS=-fprofile-use=${profile_dir} -fprofile-correction -Wno-error"
                "-DCMAKE_EXE_LINKER_FLAGS=-fprofile-use=${profile_dir}"
                "-DCMAKE_SHARED_LINKER_FLAGS=-fprofile-use=${profile_dir}"
                "-DCMAKE_MODULE_LINKER_FLAGS=-fprofile-use=${profile_dir}"
            )
            ;;
    esac

    cmake "${cmake_args[@]}"
    cmake --build "${mysql_build}" --config Release --parallel "${JOBS}"

    ok "PGO Phase 3/3: Optimized build complete"
}

main() {
    mkdir -p "${BUILD_DIR}"

    # Fast path is we rebuild only the plugin and exit
    if $REBUILD_PLUGIN; then
        # Allocator choice is baked into libtidesdb.so by build_tidesdb().  The
        # rebuild-plugin path only recompiles ha_tidesdb.so against the already
        # installed library, so --allocator has no effect here -- warn so users
        # don't silently get a stale allocator.
        if [[ "$ALLOCATOR" != "system" ]]; then
            warn "--allocator=${ALLOCATOR} has no effect with --rebuild-plugin."
            warn "  libtidesdb.so keeps its prior allocator linkage; to change"
            warn "  allocators, re-run install.sh without --rebuild-plugin."
        fi
        rebuild_plugin
        return
    fi

    install_deps
    build_tidesdb
    prepare_percona

    if $PGO_ENABLED; then
        info "PGO enabled -- performing 3-phase build (instrument ⤍ train ⤍ optimize)"
        pgo_instrument
        pgo_train
        pgo_optimize
    else
        build_percona
    fi

    install_percona
    setup_mysql
    print_summary
}

main
