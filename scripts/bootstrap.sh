#!/usr/bin/env bash
# 개발 환경 준비: Xcode·xcodegen 확인 → 프로젝트 생성 → 테스트.
# 사용:  scripts/bootstrap.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need_macos
need_xcode
need_xcodegen
generate_project

say "테스트 (swift test)"
swift test 2>&1 | tail -1
ok "준비 끝. 'open TuneMate.xcodeproj' 로 Xcode 에서 열거나 scripts/install-mac.sh · scripts/install-ios.sh 를 실행하세요."
