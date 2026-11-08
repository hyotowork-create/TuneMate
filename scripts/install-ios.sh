#!/usr/bin/env bash
# 케이블로 연결한 iPhone·iPad 에 앱을 빌드해 설치한다 (Apple ID 필요, 무료 계정도 가능).
# 사용:  TEAM_ID=ABCDE12345 scripts/install-ios.sh                 # 연결된 기기가 하나면 자동 선택
#        TEAM_ID=ABCDE12345 DEVICE="내 iPad" scripts/install-ios.sh   # 기기 이름 또는 UDID
#        BUNDLE_ID=kr.example.tunemate ...                        # 번들 ID 충돌 시 바꿈
#        scripts/install-ios.sh                                   # TEAM_ID 없으면 Xcode 를 열고 수동 절차를 안내
# Team ID 는 Xcode → Settings → Accounts → 계정 선택 → Team 열의 괄호 안 10자리, 또는 developer.apple.com/account → Membership.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need_macos
need_xcode
need_xcodegen
generate_project

TEAM_ID="${TEAM_ID:-}"
BUNDLE_ID="${BUNDLE_ID:-app.tunemate.TuneMate}"
DEVICE="${DEVICE:-}"
DD=".build/dd-ios-device"

if [[ -z "$TEAM_ID" ]]; then
  # project.yml 에 적힌 Team ID 사용
  TEAM_ID="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*"([A-Z0-9]{10})".*/\1/p' project.yml | head -1)"
fi

if [[ -z "$TEAM_ID" ]]; then
  warn "TEAM_ID 가 없어 Xcode 를 엽니다. 수동 절차:"
  cat <<'TXT'
  1. Xcode → Settings(⌘,) → Accounts → + → Apple ID 로그인 (무료 계정 가능)
  2. 왼쪽 TuneMate → TARGETS TuneMate_iOS → Signing & Capabilities
     → 'Automatically manage signing' 체크 → Team 선택
  3. 아이패드를 케이블로 연결 → 아이패드에서 '이 컴퓨터를 신뢰'
     → 설정 → 개인정보 보호 및 보안 → 개발자 모드 켜기 → 재시동
  4. Xcode 상단 기기 선택에서 아이패드 → ⌘R
  5. 아이패드에 '신뢰하지 않는 개발자' 가 뜨면 설정 → 일반 → VPN 및 기기 관리 → 개발자 앱 → 신뢰
  6. 첫 실행 때 마이크·로컬 네트워크·알림 허용
  무료 계정은 7일마다 다시 ⌘R 해야 합니다. 다음부터는 TEAM_ID=... 로 이 스크립트를 쓰면 자동입니다.
TXT
  open TuneMate.xcodeproj
  exit 0
fi

say "연결된 기기 찾기"
LIST="$(xcrun devicectl list devices 2>/dev/null | awk 'NR>2 && $0 !~ /simulated/ && NF>0')"
if [[ -z "$LIST" ]]; then
  die "케이블로 연결된 iPhone/iPad 가 없습니다. 연결 후 '이 컴퓨터를 신뢰' 를 누르고 개발자 모드를 켰는지 확인하세요."
fi
echo "$LIST"
if [[ -n "$DEVICE" ]]; then
  UDID="$(echo "$LIST" | grep -F "$DEVICE" | grep -oE '[0-9A-F-]{25,}' | head -1 || true)"
else
  UDID="$(echo "$LIST" | grep -oE '[0-9A-F-]{25,}' | head -1 || true)"
  [[ "$(echo "$LIST" | wc -l | tr -d ' ')" == "1" ]] || warn "기기가 여러 대입니다. 첫 기기를 씁니다. DEVICE=이름 으로 지정할 수 있습니다."
fi
[[ -n "$UDID" ]] || die "기기 식별자를 찾지 못했습니다."
ok "대상 기기 $UDID"

say "iOS 빌드 (자동 서명, Team $TEAM_ID, 번들 $BUNDLE_ID)"
xcodebuild -project TuneMate.xcodeproj -scheme TuneMate_iOS -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build 2>&1 \
  | grep -E "error:|BUILD" || true

APP="$DD/Build/Products/Debug-iphoneos/TuneMate.app"
[[ -d "$APP" ]] || die "빌드 산출물이 없습니다. 번들 ID 충돌이면 BUNDLE_ID=kr.본인이름.tunemate 처럼 바꿔 다시 실행하세요."

say "설치"
xcrun devicectl device install app --device "$UDID" "$APP"
say "실행"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" || warn "자동 실행 실패 — 기기에서 직접 열어 주세요. '신뢰하지 않는 개발자' 가 뜨면 설정 → 일반 → VPN 및 기기 관리 → 신뢰."
ok "끝. 첫 실행 때 마이크·로컬 네트워크·알림을 허용하세요."
