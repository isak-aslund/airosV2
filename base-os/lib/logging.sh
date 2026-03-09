#!/bin/bash
# ============================================================================
# AirOS Build Script - Logging Library
# Description: Provides colored logging functions for build output
# ============================================================================

log_step() {
    echo -e "\n\033[1;32m==> $1\033[0m"
}

log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

log_warning() {
    echo -e "\033[1;33m[WARN]\033[0m $1"
}
log_warn() { log_warning "$@"; }

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1" >&2
}

log_fail() {
    log_error "$1"
    exit ${2:-1}
}
