# 아키텍처 메모

## 데이터 흐름

측정마이크 → `MeasurementAudioEngine.runSweep` → `Deconvolution.impulseResponse`(스펙트럼 나눗셈 + 상호상관 정렬) → `TransferFunction.magnitudeSpectrum` → `FrequencyResponse`(로그 격자, 48 ppo) → `MicrophoneCalibration.apply` → `MeasurementSession.positions`
→ `FrequencyResponse.spatialAverage` → `AutoEQ.compute`(1/6옥타브 스무딩, 레벨 정렬, 컷 우선, 부스트 한도, 딥·어깨 제외, 밴드 수 제한, 중복 방지) → `EQAssignment` 표 / `ChangeProposal(.autoEQ)`
→ `ChangeExecutor.submit` → `SafetyGate.evaluate`(모드·한도·항상 확인·미검증 프로토콜) → 스냅샷 → `MixerDriver.setEQBand…` → `ChangeLog`

하울링: 입력 탭 → `RealTimeAnalyzer`(Hann, 8192) → `FeedbackDetector.process`(돌출 ≥12 dB, 지속 ≥6프레임, 증가 ≥2 dB, 하모닉 감점) → `NotchPlanner.plan` → `ChangeProposal(.feedbackSuppressor)` → 같은 경로.

AI: `AssistantSession.send` → `AssistantContext.systemPrompt`(채널 이름표·공간·측정 요약·모드) + `AssistantTools.all` → `LLMProvider.complete`(Anthropic / OpenAI / Gemini 중 하나) → tool_use → `AssistantToolExecutor.execute` → 쓰기 도구는 전부 `ChangeExecutor` → 승인이 필요하면 `approvalHandler`(UI 시트) → 결과를 다음 턴에 되돌려 줌.

## 믹서 드라이버 계층

`MixerDriver` 프로토콜(dB 단위) 아래:
- `MockMixerDriver` — 메모리 상태, 미터 시뮬레이션
- `DM24Driver` — `ProtocolSpec`(YAML) + `FrameCodec` + `ByteTransport`(TCP/UDP·루프백). `status != verified` 또는 파라미터 `verified: false` 또는 펌웨어 불일치면 쓰기 거절.
- `BehringerOSCDriver` — `OSCClient` 위, X32·X-Air 방언(`BehringerDialect`). 값 변환은 X32 OSC 문서의 페이더 곡선·로그 스케일.
- `YamahaRCPDriver` — TCP 텍스트 `set/get MIXER:Current/...`, 1/100 dB. `verifiedParameters` 밖은 거절.
- `MixerDiscovery` — UDP 브로드캐스트 `/xinfo`(10023·10024, BSD 소켓), Yamaha `devinfo`, DM24.8 명세 포트. `MixerIdentifier`가 모델 문자열 → `MixerModel`.
- `MixerDriverFactory.make(for:)`

## 왜 이렇게

- 필터 수치는 코드가 계산하고 AI는 해석·우선순위만 맡는다 (기획서 5·7장).
- 상대값만 받는 이유: AI가 현재값을 모른 채 절대값을 쓰면 위험하다. `ChangeResolver`가 스냅샷 기준으로 절대값을 만든다.
- 프로토콜 명세를 YAML로 분리한 이유: 펌웨어 업데이트 시 파일만 교체, 디컴파일 코드는 저장소에 넣지 않음(법적 검토).
- 시뮬레이션 방은 인과적 IIR(바이쿼드) 체인이다. 영위상 응답으로 만들면 디컨볼루션 창에서 딥이 깎여 테스트가 현실과 달라진다.
