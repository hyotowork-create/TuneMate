#!/usr/bin/env bash
# 맥 앱을 소스에서 빌드해 /Applications 에 설치한다.
# 사용:  scripts/install-mac.sh                  # 서명 없이(로컬 실행용). 애플리케이션 폴더에 설치
#        TEAM_ID=ABCDE12345 scripts/install-mac.sh   # 개발자 계정으로 자동 서명
#        DEST=~/Desktop scripts/install-mac.sh       # 설치 위치 변경
#        NO_INSTALL=1 scripts/install-mac.sh         # 빌드만 (dist/TuneMate.app)
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need_macos
need_xcode
need_xcodegen
generate_project

DEST="${DEST:-/Applications}"
DD=".build/dd-mac-release"
TEAM_ID="${TEAM_ID:-}"

SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "$TEAM_ID" ]]; then
  SIGN_ARGS=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
fi

say "macOS Release 빌드"
xcodebuild -project TuneMate.xcodeproj -scheme TuneMate_macOS -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" "${SIGN_ARGS[@]}" build 2>&1 \
  | grep -E "error:|warning: .*deprecated|BUILD" || true

APP="$DD/Build/Products/Release/TuneMate.app"
[[ -d "$APP" ]] || die "빌드 산출물이 없습니다: $APP"

mkdir -p dist
rm -rf dist/TuneMate.app
cp -R "$APP" dist/TuneMate.app
ok "dist/TuneMate.app"

if [[ -z "$TEAM_ID" ]]; then
  warn "서명 없이 빌드했습니다. 이 Mac 에서 소스로 빌드한 앱은 바로 실행되지만, 다른 Mac 으로 복사하면 Gatekeeper 가 막습니다 (Developer ID 서명·공증 필요)."
fi

if [[ -n "${NO_INSTALL:-}" ]]; then
  exit 0
fi

say "설치 → $DEST/TuneMate.app"
if [[ -w "$DEST" ]]; then
  rm -rf "$DEST/TuneMate.app"; cp -R dist/TuneMate.app "$DEST/"
else
  sudo rm -rf "$DEST/TuneMate.app"; sudo cp -R dist/TuneMate.app "$DEST/"
fi
ok "설치 완료. Launchpad 또는 'open \"$DEST/TuneMate.app\"' 로 실행하세요."
