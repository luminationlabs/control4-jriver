#!/usr/bin/env bash
set -e

# JRiver Media Center - Control4 Driver Build Script
# Builds a Control4 .c4z driver package using the official driverpackager tool

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
DRIVERPACKAGER_DIR="${PROJECT_DIR}/.driverpackager"
DRIVERPACKAGER_REPO="https://github.com/snap-one/drivers-driverpackager.git"
C4ZPROJ="driver.c4zproj"
DRIVER_VERSION="1.0.0"
DRIVER_FILE_NAME="jriver_media_center"
# NOT versioned. Composer derives a driver's asset namespace from the package
# filename, so controller://driver/<name>/... only resolves when the .c4z is
# named exactly <name>.c4z. A versioned filename silently breaks every bundled
# icon. The release version lives in driver.xml's <version> instead.
OUTPUT_NAME="${DRIVER_FILE_NAME}.c4z"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_requirements() {
    info "Checking requirements..."

    # Check Python 3
    if ! command -v python3 &> /dev/null; then
        error "Python 3 is required but not installed. Please install Python 3."
    fi
    success "Python 3: $(python3 --version)"

    # Check Git (for downloading driverpackager)
    if ! command -v git &> /dev/null; then
        error "Git is required but not installed. Please install Git."
    fi
    success "Git: $(git --version | head -n1)"

    # Check lxml Python module
    if ! python3 -c "import lxml" 2>/dev/null; then
        warn "Python module 'lxml' is required for driverpackager"

        # Try different installation methods based on OS and Python version
        info "Attempting to install lxml..."

        # Method 1: Try with --user and --break-system-packages (Python 3.11+)
        if python3 -m pip install lxml --user --break-system-packages --quiet 2>/dev/null; then
            success "lxml installed successfully (--break-system-packages)"
        # Method 2: Try with just --user flag (older Python)
        elif python3 -m pip install lxml --user --quiet 2>/dev/null; then
            success "lxml installed successfully (--user)"
        # Method 3: Try with homebrew (macOS)
        elif command -v brew &> /dev/null && brew list python-lxml &>/dev/null 2>&1; then
            info "lxml already installed via Homebrew"
        elif command -v brew &> /dev/null; then
            warn "Attempting to install via Homebrew..."
            if brew install python-lxml 2>/dev/null; then
                success "lxml installed via Homebrew"
            else
                error "Failed to install lxml via Homebrew. Try manually: brew install python-lxml"
            fi
        else
            error "Failed to install lxml. Please install manually:
  macOS:    brew install python-lxml
  Linux:    apt install python3-lxml  (or)  dnf install python3-lxml
  Manual:   python3 -m pip install lxml --user --break-system-packages"
        fi

        # Verify installation worked
        if ! python3 -c "import lxml" 2>/dev/null; then
            error "lxml installation failed. Please install manually (see error above)."
        fi
    fi
}

install_driverpackager() {
    if [ -d "$DRIVERPACKAGER_DIR" ]; then
        info "Driverpackager already installed at $DRIVERPACKAGER_DIR"
        return 0
    fi

    info "Installing driverpackager from GitHub..."
    git clone --depth 1 "$DRIVERPACKAGER_REPO" "$DRIVERPACKAGER_DIR"

    if [ ! -f "${DRIVERPACKAGER_DIR}/dp3/driverpackager.py" ]; then
        error "Failed to install driverpackager. Expected file not found."
    fi

    success "Driverpackager installed successfully"
}

validate_lua() {
    if ! command -v luacheck &> /dev/null; then
        warn "luacheck not found. Skipping Lua validation."
        warn "Install with: brew install luacheck (macOS) or apt install lua-check (Linux)"
        return 0
    fi

    info "Validating Lua syntax..."

    # Run luacheck and capture result
    if luacheck driver.lua; then
        success "Lua validation passed - no issues found"
        return 0
    fi

    # Check exit code: 0 = ok, 1 = warnings, 2 = errors
    local exit_code=$?
    if [ $exit_code -eq 1 ]; then
        warn "Lua validation completed with warnings (non-fatal)"
        return 0
    else
        error "Lua validation failed with errors. Fix above before building."
        return 1
    fi
}

clean() {
    info "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    success "Build directory cleaned"
}

build() {
    info "Building JRiver Media Center Control4 driver..."

    # Ensure build directory exists
    mkdir -p "$BUILD_DIR"

    # Remove any stale .c4z so the post-build "find" can't pick up a previous package
    rm -f "$BUILD_DIR"/*.c4z

    # Check if .c4zproj exists
    if [ ! -f "$C4ZPROJ" ]; then
        error "Project file $C4ZPROJ not found"
    fi

    # Check if driverpackager is installed
    if [ ! -d "$DRIVERPACKAGER_DIR" ]; then
        warn "Driverpackager not found. Installing..."
        install_driverpackager
    fi

    # Run driverpackager
    info "Running driverpackager..."
    python3 "${DRIVERPACKAGER_DIR}/dp3/driverpackager.py" \
        -v \
        "$PROJECT_DIR" \
        "$BUILD_DIR" \
        "$C4ZPROJ"

    # Find the generated .c4z file (driverpackager uses driver name from XML)
    GENERATED_C4Z=$(find "$BUILD_DIR" -name "*.c4z" -type f | head -n1)

    if [ -f "$GENERATED_C4Z" ]; then
        # Normalise the packager's output name. It already matches OUTPUT_NAME
        # whenever driver.c4zproj and DRIVER_FILE_NAME agree, and moving a file
        # onto itself is an error under GNU mv while BSD mv quietly allows it --
        # so skip the move rather than relying on which one is installed.
        if [ "$GENERATED_C4Z" != "${BUILD_DIR}/${OUTPUT_NAME}" ]; then
            mv "$GENERATED_C4Z" "${BUILD_DIR}/${OUTPUT_NAME}"
        fi
        success "Driver built successfully: ${BUILD_DIR}/${OUTPUT_NAME}"

        # Asset paths in driver.xml resolve relative to the c4z's www/ directory,
        # and a wrong one fails silently at runtime. Verify rather than discover
        # it on a Navigator.
        if [ -f "${PROJECT_DIR}/tools/verify-package.py" ]; then
            if ! python3 "${PROJECT_DIR}/tools/verify-package.py" "${BUILD_DIR}/${OUTPUT_NAME}"; then
                error "Package references assets that are not in it."
            fi
        fi

        # Show file info
        info "Package size: $(du -h "${BUILD_DIR}/${OUTPUT_NAME}" | cut -f1)"
        info "SHA256: $(shasum -a 256 "${BUILD_DIR}/${OUTPUT_NAME}" | cut -d' ' -f1)"
    else
        error "Build failed - output file not created"
    fi
}

show_help() {
    cat << EOF
JRiver Media Center - Control4 Driver Build Tool

Usage:
  ./build.sh [command]

Commands:
  (no args)    Build the driver (default)
  clean        Remove build artifacts
  validate     Validate Lua syntax (requires luacheck)
  install      Install/update driverpackager
  help         Show this help message

Examples:
  ./build.sh              # Build driver
  ./build.sh clean        # Clean then build
  ./build.sh validate     # Check Lua syntax only

Output:
  ${BUILD_DIR}/${OUTPUT_NAME}

Requirements:
  - Python 3 (required)
  - Git (required)
  - luacheck (optional, for validation)

EOF
}

# Main script logic
case "${1:-}" in
    clean)
        clean
        ;;
    validate)
        check_requirements
        validate_lua
        ;;
    install)
        check_requirements
        install_driverpackager
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        check_requirements
        build
        ;;
    *)
        error "Unknown command: $1. Use './build.sh help' for usage."
        ;;
esac
