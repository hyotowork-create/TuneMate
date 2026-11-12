#!/usr/bin/env bash
# 내려받기용 맥 dmg 를 만든다: 유니버설(arm64+x86_64) Release 빌드 → 임시(ad-hoc) 서명 → dist/TuneMate-mac.dmg
# 사용:  scripts/make-dmg.sh
# Apple 공증을 받지 않으므로 받는 사람은 처음 열 때 '그래도 열기' 를 눌러야 한다(README 참고).
# 임시 서명에는 keychain-access-groups 같은 제한 권한을 넣을 수 없어 Resources/TuneMate-adhoc.entitlements 를 쓴다.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need_macos
need_xcode
need_xcodegen
generate_project

DD=".build/dd-mac-dmg"
say "macOS Release 유니버설 빌드"
xcodebuild -project TuneMate.xcodeproj -scheme TuneMate_macOS -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|BUILD" || true

APP="$DD/Build/Products/Release/TuneMate.app"
[[ -d "$APP" ]] || die "빌드 산출물이 없습니다: $APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/TuneMate.app"
ln -s /Applications "$STAGE/Applications"

say "임시 서명 (샌드박스 권한)"
codesign --force --deep --sign - --entitlements Resources/TuneMate-adhoc.entitlements "$STAGE/TuneMate.app"
codesign --verify --deep --strict "$STAGE/TuneMate.app"

ARCHS_OUT="$(lipo -archs "$STAGE/TuneMate.app/Contents/MacOS/TuneMate")"
[[ "$ARCHS_OUT" == *arm64* && "$ARCHS_OUT" == *x86_64* ]] || die "유니버설 빌드가 아닙니다: $ARCHS_OUT"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/TuneMate.app/Contents/Info.plist")"

mkdir -p dist
rm -f dist/TuneMate-mac.dmg
say "dmg 만들기"
hdiutil create -volname "TuneMate $VER" -srcfolder "$STAGE" -ov -format UDZO dist/TuneMate-mac.dmg >/dev/null
hdiutil verify dist/TuneMate-mac.dmg >/dev/null 2>&1 || die "dmg 검증 실패"
ok "dist/TuneMate-mac.dmg (버전 $VER, $ARCHS_OUT, $(du -h dist/TuneMate-mac.dmg | cut -f1 | tr -d ' '))"
shasum -a 256 dist/TuneMate-mac.dmg
