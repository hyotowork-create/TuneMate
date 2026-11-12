#!/usr/bin/env bash
# 공통 함수 — 다른 스크립트가 source 한다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

need_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "macOS 에서만 실행할 수 있습니다 (Xcode 가 필요)."
}

need_xcode() {
  local dev
  dev="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$dev" || "$dev" == *CommandLineTools* ]]; then
    die "Xcode 가 필요합니다. App Store 에서 Xcode 를 설치한 뒤 한 번 실행하고, 'sudo xcode-select -s /Applications/Xcode.app' 을 실행하세요."
  fi
  # `| head -1` 은 쓰지 않는다: head 가 먼저 끝나면 xcodebuild 가 SIGPIPE 로 죽고 pipefail 이 스크립트를 멈춘다.
  local v; v="$(xcodebuild -version)"; printf '%s\n' "${v%%$'\n'*}"
}

need_xcodegen() {
  if ! command -v xcodegen >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || die "Homebrew 가 없습니다. https://brew.sh 안내대로 설치한 뒤 다시 실행하세요."
    say "xcodegen 설치"
    brew install xcodegen
  fi
  xcodegen --version || true
}

generate_project() {
  say "Xcode 프로젝트 생성 (project.yml → TuneMate.xcodeproj)"
  xcodegen generate >/dev/null
  ok "TuneMate.xcodeproj"
}
