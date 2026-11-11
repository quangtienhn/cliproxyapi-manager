#!/usr/bin/env bash
# ==============================================================================
# Common Shell Utilities for CLIProxyAPI Easy Installer
# ==============================================================================

# Strict mode helper
init_strict_mode() {
  set -euo pipefail
  IFS=$'\n\t'
}

# Color formatting (if terminal attached)
if [[ -t 1 ]]; then
  C_RESET="\033[0m"
  C_RED="\033[1;31m"
  C_GREEN="\033[1;32m"
  C_YELLOW="\033[1;33m"
  C_BLUE="\033[1;34m"
  C_CYAN="\033[1;36m"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
fi

log_info() {
  printf "${C_BLUE}[INFO]${C_RESET} %s\n" "$*"
}

log_ok() {
  printf "${C_GREEN}[OK]${C_RESET} %s\n" "$*"
}

log_warn() {
  printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*" >&2
}

log_err() {
  printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2
}

# Architecture normalization: x86_64 -> amd64, aarch64/arm64 -> arm64
detect_architecture() {
  local raw_arch
  raw_arch=$(uname -m 2>/dev/null || echo "unknown")
  case "$raw_arch" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    armv7l|armhf)
      echo "armhf"
      ;;
    *)
      echo "unsupported ($raw_arch)"
      return 1
      ;;
  esac
}

# OS detection: Debian, Ubuntu, etc.
detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    echo "unknown"
    return 1
  fi
  # shellcheck source=/dev/null
  local ID="" VERSION_ID=""
  ID=$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  VERSION_ID=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  echo "${ID}:${VERSION_ID}"
}

# Redact sensitive values from strings or files
redact_sensitive() {
  sed -E \
    -e 's/(secret|password|token|key|api_key|management_key)[[:space:]]*[:=][[:space:]]*[^ ,"]+/\1: [REDACTED]/gI' \
    -e 's/(gho_[A-Za-z0-9_]{10})[A-Za-z0-9_]+/\1[REDACTED]/g' \
    -e 's/(bearer[[:space:]]+)[A-Za-z0-9_.-]+/\1[REDACTED]/gI'
}

# Parse key=value state securely without arbitrary shell execution
parse_strict_kv() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  grep -E '^[A-Z0-9_]+=[A-Za-z0-9._/-]+$' "$file" || true
}
