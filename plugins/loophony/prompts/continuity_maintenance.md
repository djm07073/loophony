Loophony 연속 실행 유지보수 작업이다. 사용자 입력을 기다리지 말고 아래 범위에서 진단·복구한다.

1. `http://127.0.0.1:8787/api/v1/state`, launchd의 `com.loophony.daemon`, 최근 daemon 로그를 확인한다.
2. Loophony가 중단됐거나 health가 비정상이면 원인을 진단하고 `/Users/leojin/dev/agents/loophony`에서 최소 수정, 관련 테스트, build 후 서비스를 재시작한다. 기존 미커밋 변경은 보존한다.
3. Linear 프로젝트 `ProbEdge: Option Pricing for Prediction Markets`와 루트 `HFT-88`을 읽고 Active stage, 미해결 `symphony-quant` Todo/In Progress, 최근 Quant Workpad/Human Input/checkpoint를 확인한다.
4. daemon이 정상인데 `running=0`, `queued=0`이고 루트 목표가 완료되지 않았다면 끊어진 handoff로 판정한다. 현재 Active stage와 정확히 일치하는 후속 Candidate가 없을 때만 한국어 Todo Candidate 하나를 생성한다. 부모 HFT-88, label `symphony-quant`, 기존 assignee, 선행 증거, bounded objective, 결정론적 acceptance checks, 반증 테스트, non-goals를 포함하고 재조회 검증한다. 중복 이슈를 만들지 않는다.
5. 현재 이슈가 후속 Candidate 없이 잘못 Done이 된 경우, 관련 Workpad/checkpoint 증거를 확인한 뒤 안전하면 In Progress로 복구하거나 정확히 하나의 후속 Candidate를 생성한다. Canceled/Cancelled/Duplicate는 변경하지 않는다.
6. Loophony에 즉시 refresh를 요청하고 다음 이슈가 dispatch되는지 확인한다. 실제 research 작업은 daemon worker가 담당하며 이 유지보수 세션이 대신 실행하지 않는다.
7. 문제가 반복되면 재시작만 반복하지 말고 재현 테스트를 먼저 추가한 뒤 Loophony 코드를 수정한다. `mise exec -- make all` 또는 위험에 비례한 관련 검증을 통과해야 한다.
8. credential을 출력·복사·기록하지 않는다. live/paper order, 자금 이동, SC-04 이후 단계 실행은 금지한다. Linear 기록은 한국어로 쓴다.
9. 매 실행 결과를 `/Users/leojin/.local/share/loophony/logs/codex-continuity-last.md`에 요약하고, 조치가 없으면 관찰 증거와 `healthy/no-op`만 기록한다.

최종 목표는 daemon 프로세스 생존이 아니라 HFT-88의 허가된 Active stage에 정확히 하나의 실행 Candidate가 존재하고 Loophony가 이를 계속 dispatch하는 상태다.
