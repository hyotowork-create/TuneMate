#!/usr/bin/env bash
# 한 줄 설치 (맥):  curl -fsSL https://raw.githubusercontent.com/OWNER/TuneMate/main/install.sh | bash
# 저장소를 ~/TuneMate 에 받아(이미 있으면 갱신) 맥 앱을 빌드해 /Applications 에 설치한다.
# 환경변수:  TUNEMATE_REPO=계정/저장소 (기본 hyotowork-create/TuneMate), TUNEMATE_DIR=받을 폴더, TEAM_ID, DEST
set -euo pipefail
REPO="${TUNEMATE_REPO:-hyotowork-create/TuneMate}"
DIR="${TUNEMATE_DIR:-$HOME/TuneMate}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS 에서만 설치할 수 있습니다. iPhone/iPad 는 맥에서 scripts/install-ios.sh 로 넣습니다." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git 이 없습니다. 'xcode-select --install' 후 다시 실행하세요." >&2; exit 1; }

if [[ -d "$DIR/.git" ]]; then
  echo "▶ $DIR 갱신"; git -C "$DIR" pull --ff-only
else
  echo "▶ https://github.com/$REPO → $DIR"; git clone "https://github.com/$REPO.git" "$DIR"
fi
exec bash "$DIR/scripts/install-mac.sh"
