# 튠메이트 (TuneMate) — 예배당 AI 음향 튜닝 앱

> 기획서: `docs/PLAN.md` (2026-10-30)
> TOPP PRO·SEIKAKU와 무관한 독립 앱입니다.

iPhone·iPad·MacBook 하나의 SwiftUI 코드로 **측정 → 보정 EQ 산출 → 하울링 검출·억제 → AI 대화형 진단 → (프로토콜 검증 뒤) 믹서 자동 적용**을 처리합니다.


> ⚠️ **시험판(0.1)** — 실제 믹서·측정 마이크(UMIK-1)로는 아직 시험하지 않았습니다. 기본은 **제안 모드**(사람이 「적용」을 눌러야 바뀜)이고, DM24.8은 쓰기가 막혀 있습니다. 예배 중에는 쓰지 말고 리허설에서 먼저 확인하세요.

## 내려받기 (Mac)

[Releases](https://github.com/hyotowork-create/TuneMate/releases/latest)에서 `TuneMate-mac.dmg`를 받아 열고, `TuneMate`를 「응용 프로그램」으로 끌어 넣습니다.
Apple 공증을 받지 않은 앱이라 처음 열 때 경고가 뜹니다: **시스템 설정 → 개인정보 보호 및 보안 → 「그래도 열기」**를 한 번 누르면 됩니다.
iPhone·iPad 판은 아직 배포하지 않습니다(아래 「설치」의 소스 빌드만 가능).

## 구성

```
TuneMate/
├─ Package.swift                 Swift Package (TuneMateCore 라이브러리 + TuneMateApp 실행 파일 + 테스트)
├─ project.yml                   XcodeGen 정의 — iPhone·iPad·Mac 앱 타깃 (Xcode 있는 Mac 에서 생성)
├─ Sources/TuneMateCore/
│  ├─ DSP/        FFT(vDSP), 로그 스윕, 디컨볼루션(상호상관 정렬), 로그 격자 응답·1/N옥타브 스무딩, UMIK-1 보정 파일, RTA, 바이쿼드
│  ├─ Tuning/     목표 곡선, PEQ 응답, AutoEQ(컷 우선·부스트 한도·딥 제외·밴드 수 제한), 하울링 검출기, 노치 배치
│  ├─ Mixer/      공통 MixerDriver · 시뮬레이터 · DM24Kit(명세 YAML·프레임 코덱·드라이버) · OSC(X32/M32·X-Air/MR) · Yamaha RCP · 모델 식별/탐색
│  ├─ Safety/     운영 모드, 한도 정책, 변경안(상대값→절대값), 게이트, 스냅샷·변경 로그, 실행기(되돌리기)
│  ├─ AI/         공급자 중립 LLM 계층 — Claude(Messages API)·ChatGPT(Chat Completions)·Gemini(generateContent), 도구 11개, 도구 실행기, 세션, Keychain
│  ├─ Audio/      AVAudioEngine 측정 입출력(측정 모드), WAV 내보내기, 가상 예배당(시뮬레이션)
│  ├─ Persistence/ 측정 세션·설정 JSON 저장소
│  └─ Resources/dm248-protocol.yaml   DM24.8 프로토콜 명세 템플릿 (status: unverified)
├─ Sources/TuneMateApp/          SwiftUI 화면: 측정·보정·하울링·AI 대화·믹서·설정 + 승인 시트
├─ Tests/TuneMateCoreTests/      Swift Testing 61개 (DSP 정확도, AutoEQ, 하울링, 안전 게이트, 프로토콜 코덱, OSC/RCP, AI 공급자, 종단 파이프라인)
└─ docs/                         아키텍처·현장 절차·진행 기록
```

## 어떤 기기에 설치하나

| 기기 | 필요 OS | 설치 방법 | 맡는 일 |
|---|---|---|---|
| 콘솔 아이패드 (공식 DM24.8 앱이 깔린 것) | iPadOS 17 이상 | 맥에 케이블 연결 → `scripts/install-ios.sh` | 지시함·작은 창(PiP)으로 공식 앱과 함께 쓰기, 믹서 연결(공개 프로토콜 믹서) |
| 아이폰 | iOS 17 이상 | 위와 같음 | 좌석을 돌며 측정·하울링 감시·AI 대화, 콘솔 아이패드로 지시 보내기 |
| 맥 | macOS 14 이상 (인텔·애플 실리콘) | dmg 내려받기 또는 `install.sh` | 측정마이크(UMIK-1) 측정·보정 계산·리포트 |

- 공식 DM24.8 앱은 **아이패드 전용**입니다. 아이폰에는 깔 수 없으므로 '공식 앱 위에 작은 창' 방식은 아이패드에서만 씁니다. 아이폰의 튠메이트는 그대로 동작합니다.
- 아이폰·아이패드는 웹에서 내려받아 설치할 수 없습니다(한국). Xcode 가 있는 맥과 케이블, Apple ID 가 필요합니다. 무료 Apple ID 는 7일마다 다시 설치해야 합니다.
- UMIK-1 은 USB-C 단자에 바로 꽂습니다. 라이트닝 단자 기기는 카메라 어댑터가 필요합니다.

## 설치

**맥 (소스에서 빌드, Xcode 필요)**

```bash
curl -fsSL https://raw.githubusercontent.com/hyotowork-create/TuneMate/main/install.sh | bash
```
저장소를 `~/TuneMate` 에 받아 Release 빌드 후 `/Applications/TuneMate.app` 으로 설치합니다. 이미 받았다면 `scripts/install-mac.sh`. 소스에서 빌드하므로 서명 없이도 바로 실행됩니다(빌드된 앱을 다른 Mac 에 복사하면 Gatekeeper 가 막습니다).

**iPhone·iPad (맥 + 케이블, Apple ID 필요)**

```bash
TEAM_ID=XXXXXXXXXX scripts/install-ios.sh
```
무료 Apple ID 로도 됩니다(7일마다 재설치, 기기당 앱 3개). Team ID 는 Xcode → Settings → Accounts 에서 확인. `TEAM_ID` 없이 실행하면 Xcode 를 열고 수동 절차를 안내합니다. 번들 ID 충돌 시 `BUNDLE_ID=kr.본인.tunemate` 추가. iOS 는 한국에서 웹 다운로드 설치가 불가하며, 여러 사람에게 배포하려면 TestFlight(유료 개발자 계정) 또는 App Store 를 씁니다.

**내려받기용 dmg 만들기 (배포하는 사람용)**

```bash
scripts/make-dmg.sh
```
유니버설 Release 빌드를 임시 서명해 `dist/TuneMate-mac.dmg` 로 만듭니다. 릴리스에 올리는 dmg 는 이 스크립트로 만든 것입니다.

**개발 환경 준비**

```bash
scripts/bootstrap.sh
```

## 빌드·테스트

**Xcode 27 설치된 Mac (iPhone·iPad·Mac 모두)**

```bash
brew install xcodegen && xcodegen generate && open TuneMate.xcodeproj
```
- 타깃: `TuneMate_iOS`(iPhone·iPad), `TuneMate_macOS`. 2026-10-30 기준 iPhone 17·iPad Pro 11-inch 시뮬레이터 빌드와 iPhone 실행을 확인했습니다.
- 명령줄: `xcodebuild -project TuneMate.xcodeproj -scheme TuneMate_iOS -destination 'platform=iOS Simulator,name=iPhone 17' build`
- 테스트는 SwiftPM으로 돌립니다 (`swift test`, 61개). Xcode 안에서는 Test Navigator의 패키지 테스트(TuneMateCoreTests)로 실행합니다.
- `project.yml`에 마이크·로컬 네트워크 권한 문구, 샌드박스·Keychain 권한이 들어 있습니다. TestFlight 배포 시 `DEVELOPMENT_TEAM`을 채웁니다. iOS에서 믹서 UDP 브로드캐스트 탐색을 쓰려면 `com.apple.developer.networking.multicast` 권한을 Apple에 신청해 주석을 풉니다.

**Command Line Tools만 있는 Mac (예비 경로)**

```bash
make build    # swift build --sdk MacOSX26.5.sdk
```
```bash
make test     # swift test + Testing 매크로 플러그인 경로
```
macOS 27 SDK에서는 SwiftUI `@State`가 매크로라 CLT 툴체인으로는 앱 타깃이 컴파일되지 않습니다. 26.5 SDK를 지정하면 됩니다. Xcode가 있으면 그냥 `swift build` / `swift test` 로 됩니다.

## 사용 흐름 (Phase 1 — 지금 바로 가능)

1. **설정** → AI 공급자(Claude / ChatGPT / Gemini) 중 하나의 본인 API 키 저장. 요금제가 낮으면 **경제형** 등급(Haiku 5.5 / gpt-5-mini / Gemini Flash-Lite)으로 두고, 측정 분석만 표준·정밀로 올립니다. 모델 ID는 공급자 콘솔 기준으로 바꿀 수 있습니다.
2. **측정** → 마이크 선택(UMIK-1·내장·시뮬레이션). UMIK-1이면 보정 파일을 설정에 붙여넣기. 좌석 5~8곳을 "이 위치 측정". 믹서 USB 재생으로 신호를 낼 때는 "스윕 WAV 내보내기"로 파일을 만들어 재생해도 됩니다(비동기 재생은 상호상관으로 정렬).
3. **보정** → 측정/목표/예상 응답 차트, 보정 표(대상·밴드·Hz·dB·Q). 믹서가 연결되지 않았으면 **표 복사**해 아이패드 공식 앱에 직접 입력. 연결됐으면 **믹서에 적용(변경안)** → 승인 → 적용 → 같은 위치 재측정으로 검증.
4. **하울링** → 감시 시작. 좁고 지속하며 커지는 피크만 후보로 올립니다(하모닉이 함께 솟으면 감점). 후보마다 채널을 고르고 **노치 −3 dB**(채널 빈 PEQ 밴드 → 없으면 메인 EQ, 최대 −12 dB, 한도에 닿으면 게인 낮추기 안내). 리허설 자동 모드에서는 한도 안 노치가 바로 적용됩니다.
5. **AI 대화** → "1번 마이크 목소리가 안 들려요" 같은 말. AI는 상대값(±dB)만 제안하고, 모든 변경은 안전 계층(한도·모드·승인·스냅샷)을 지납니다.
6. **믹서** → 모델 선택·IP 입력·연결, 네트워크 탐색(X32/M32·X-Air/MR는 `/xinfo`, Yamaha는 RCP `devinfo`), 운영 모드(제안/리허설 자동/예배 잠금), 되돌리기, 변경 로그.

## 실제 장비 연결 절차

1. **측정마이크**: UMIK-1 을 USB-C 로 연결 → 측정 탭 '입력 장치' 목록에서 선택(UMIK 이름이 보이면 자동 선택) → **입력 확인(레벨)** 으로 RMS/피크가 −40~−6 dBFS 에 들어오는지 확인. 클립·무신호 안내가 뜹니다. 첫 측정 전 마이크 권한을 묻습니다.
2. **믹서**: 믹서 탭 → 모델 선택 → IP 입력 → **연결 테스트**. 응답이 오면 모델·펌웨어·왕복 시간이 표시되고, 응답 모델이 다르면 자동으로 바꿉니다. 없으면 원인 안내(같은 네트워크, 포트, 원격 제어 설정). 그다음 **연결**.
   - X32/M32: UDP 10023 `/xinfo`. X-Air/MR: UDP 10024. Yamaha: TCP 49280 `devinfo`. DM24.8: 명세 포트 확정 전에는 테스트 불가 메시지.
   - '네트워크에서 믹서 찾기'는 255.255.255.255 와 서브넷 브로드캐스트를 모두 씁니다. iOS 에서는 멀티캐스트 권한이 필요합니다.
3. **연결 유지**: OSC 는 9초마다 `/xremote` 갱신, 요청 응답은 0.8초(연결 시 2.5초) 안에 없으면 시간 초과로 보고합니다. 네트워크 경로가 없으면 바로 실패로 알립니다.
4. **검증 방법**: `Tests/TuneMateCoreTests/RealTransportTests.swift` 가 127.0.0.1 에 가짜 X32(UDP) 서버를 띄워 실제 Network.framework 경로로 연결·쓰기·읽기를 확인합니다.

## 믹서를 직접 제어할 수 없을 때 — 지시 전달 (콘솔 아이패드)

DM24.8처럼 프로토콜이 미검증이거나 믹서가 연결되지 않은 경우, 측정 기기(iPhone·iPad·Mac)가 **수정 지시 카드**를 만들어 콘솔 아이패드의 튠메이트로 보냅니다(MultipeerConnectivity, 같은 Wi-Fi 또는 블루투스).
- 보내는 곳: 보정 탭 '콘솔 아이패드로 지시 보내기', 하울링 후보의 '지시 보내기', 승인 시트의 '지시로 보내기'.
- 받는 곳: 지시함 탭. 항목별 체크리스트, '읽어주기'(한국어 음성), '완료 알리기'(보낸 기기에 확인 표시). 콘솔 아이패드에서는 공식 DM24.8 앱과 Split View 로 나란히 두고 입력합니다.
- 연결된 기기가 없으면 이 기기의 지시함에 보관됩니다.

## 한 아이패드에서 공식 앱과 함께 쓰기

iOS 는 다른 앱을 직접 조작하지 못하므로, 같은 아이패드에서는 세 가지로 연동합니다.
1. **작은 창(PiP)**: 지시함 → '작은 창으로 띄우기'. 체크리스트가 영상처럼 작은 창에 그려져 공식 DM24.8 앱이 전체 화면이어도 그 위에 남습니다. 항목을 체크하면 창 내용이 바로 갱신됩니다.
2. **알림 배너**: 새 지시가 오면(다른 기기에서, 또는 보정 탭 '지시함에 넣기') 알림이 떠서 공식 앱을 쓰는 중에도 보입니다.
3. **Split View**: 공식 앱과 튠메이트를 나란히.
직접 제어(공식 앱 없이 적용)는 Phase 0 프로토콜 판정 뒤에 열립니다.

## 기기 연동 (콘솔 아이패드 + 측정 기기)

지시함에서 '연결 켜기'를 누른 기기들끼리 다음이 자동으로 오갑니다.
- **콘솔 상태**: 믹서에 연결된 기기(기본적으로 '이 기기를 콘솔로 사용' 켜짐)가 연결 여부·모델·운영 모드·믹서 상태를 알립니다.
- **원격 적용**: 믹서에 연결되지 않은 기기에서 '적용'을 누르면 변경안이 콘솔 기기로 가고, 콘솔의 안전 한도·승인 시트를 거쳐 적용된 뒤 결과가 돌아옵니다. AI 대화의 쓰기 도구, 하울링 노치, 자동 억제, 링아웃도 같은 경로를 씁니다.
- **측정 결과**: 측정이 저장될 때마다 연결된 기기에 공유됩니다(보정 탭 '측정 결과를 다른 기기와 공유'로 수동 전송도 가능). 받은 기기의 AI 분석에도 쓰입니다.
- **채널 이름표·공간 정보**, **하울링 후보**(감시 중인 기기 → 다른 기기)도 공유됩니다.
- 믹서에 직접 연결할 수 없는 DM24.8(미검증)에서는 원격 적용도 똑같이 차단되고, 지시 카드만 전달됩니다.

권장 배치: 콘솔 아이패드 = 공식 앱 + 튠메이트(Split View, 콘솔 역할·지시함·하울링 감시), 맥북 = UMIK-1 측정·보정 계산·AI 분석, 아이폰 = 좌석 돌며 하울링 감시·AI 대화.

## 튜닝 루프·하울링 자동 억제 (기획서 8장)

- **검증 루프**: 보정 적용 → '검증 측정 시작' → 같은 위치 재측정 → 자동 판정(수렴 / 개선 중 / 정체 / 최대 3회). 예상과 실측이 2 dB 이상 다르면 EQ 미반영을 의심하라고 알립니다. '다음 회차 계산'은 관찰한 모델 오차를 반영해 다시 계산합니다.
- **자동 억제**: 하울링 탭 토글. 리허설 자동 모드 + 믹서 연결 시 신뢰도 70% 이상 후보에 한도 안 노치를 자동 적용(같은 주파수 5초 쿨다운, 세션당 12개).
- **링아웃 도우미**: 채널을 고르고 게인을 올리는 동안 먼저 우는 주파수를 모아 한 번에 노치 변경안을 만듭니다(빈 밴드를 겹치지 않게 배정).
- **스냅샷·씬**: 믹서 탭에서 자동 백업 목록 복원, 씬 번호·이름으로 저장.
- **리포트**: 보정 탭 '리포트 내보내기'(Markdown: 위치·보정표·1/3옥타브 편차·반복 회차·판정).

## 믹서 지원 현황

| 믹서 | 프로토콜 | 상태 | 모델 식별 |
|---|---|---|---|
| TOPP PRO DM24.8 | 비공개 → `dm248-protocol.yaml` 역분석 | **미검증 — 읽기·제안만, 쓰기 차단.** Phase 0 캡처 뒤 명세를 채우고 `status: verified`로 바꾸면 자동 적용이 열림. 펌웨어 불일치 시 쓰기 차단 | 명세 포트 응답(추정) |
| Behringer X32 / Midas M32 | OSC UDP 10023 (공개) | 구현 (페이더 곡선·EQ 로그 스케일·센드·헤드앰프·씬·미터 블롭) | `/xinfo` 브로드캐스트 |
| Behringer XR18/XR16/XR12, Midas MR18/MR12 | OSC UDP 10024 (공개) | 구현 (`/lr`, `/bus/n`, `/-snap`) | `/xinfo` |
| Yamaha DM7 / DM3 (TF·CL·QL 계열) | RCP 텍스트 TCP 49280 | 페이더·온/오프·센드·이름 구현. EQ·게인·팬텀 주소는 기기 확인 전까지 쓰기 차단 | `devinfo productname` |
| Allen & Heath SQ | MIDI over TCP 51325 | 미구현 (식별 자리만) | — |
| 시뮬레이터 | — | DM24.8 구성(24ch·8aux·4밴드)으로 전체 흐름 시험 | — |

## 안전장치 (기획서 7장)

- 모드: **제안(기본)** 사람이 적용 버튼 / **리허설 자동** 한도 안 즉시 적용 / **예배 잠금** 읽기 전용
- 한도: 한 번에 +3 dB, 메인 출력 상한 0 dB, 뮤트 2채널, EQ ±12 dB, 노치 −3 dB씩 최대 −12 dB (설정에서 변경)
- 팬텀·씬 불러오기·라우팅은 항상 사람 확인. 프리앰프 게인도 확인.
- 모든 변경 직전 자동 스냅샷 + 변경 로그 + 원클릭 되돌리기
- AI는 절대값 대신 상대값만 넘기고, 현재값 읽기·계산·쓰기는 앱이 한 번에 처리
- 미검증 프로토콜(DM24.8) 믹서에는 어떤 모드에서도 쓰지 않음

## Phase 0 (DM24.8 역분석) — 운영자이 할 일

`docs/FIELD_GUIDE.md`의 A 체크리스트대로 패킷을 캡처해 `.pcapng`와 기록표를 전달하면, 해독 결과를 `Sources/TuneMateCore/Resources/dm248-protocol.yaml`에 채웁니다. 코드 수정 없이 파일만 바뀝니다.
Go 기준: 평문 바이너리 + 같은 조작 → 같은 패킷 + 재전송 시 같은 동작. No-go면 Phase 1(측정·분석·수동 적용)까지만 유지합니다.

## 아직 안 된 것

- 실제 하드웨어(UMIK-1·X32·DM24.8)와의 연결 시험 — 로컬 소켓 가짜 서버와 시뮬레이터로만 검증했습니다. 실기기 앞에서 '연결 테스트' 결과를 알려 주시면 맞춥니다.
- 실제 iPhone·iPad 기기 설치·TestFlight (개발자 계정 Team ID 필요). 시뮬레이터 빌드·실행은 확인함.
- DM24.8 미터 스트림, 출력 딜레이, 메인 EQ 종류·밴드 수 (기획서 12장 확인 항목)
- Mac용 MCP 서버(선택 사항), Allen & Heath SQ 드라이버, Mac 공식 앱 UI 자동화(접근성 API) 검토
- REW 대조 측정 (Phase 1 완료 판정 기준)

## 라이선스

MIT (LICENSE 파일)
