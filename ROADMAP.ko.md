# Safedeps 로드맵

> 시간축과 우선순위. **왜·어떻게** 는 [`ARCHITECTURE.md`](./ARCHITECTURE.md), **언제·뭐 먼저** 는 이 파일. *(English → [ROADMAP.md](./ROADMAP.md), SSoT)*

---

## 스코프

Safedeps 는 **개발 의존성 install** (npm / pip / cargo / go / gem / maven / nuget) 을 게이트한다. release 시점에는 repo 트리 secret scan, dependency audit, git hook install/check 도 실행한다 (옛 `security-release-gates` 에서 흡수한 lane).

스코프 밖: OS / 시스템 패키지, 컨테이너 이미지, 런타임 sandbox, registry 무결성, 평판 분석. 이들은 다른 보안 layer 라서 다른 도구에 둔다 — 경계는 [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 참고.

---

## v1 — `npm-reorg-guard` (출시 완료)

- npm 전용, self-contained, 외부 advisory DB 없음.
- PreToolUse hook: typosquat / `curl | bash` / 비표준 registry 패턴 차단.
- PostToolUse hook: lockfile diff + install script 분석 → 의심 시 reorg (rollback).

한계: npm 만, CVE 조회 없음 (패턴 매칭), 작정한 공격자는 회피 가능. GitHub repo 는 이후 `aldegad/safedeps` 로 rename 됨.

---

## v2 — `safedeps` (출시 완료, v2.1.x)

내부 engine 은 v1 `reorg-guard` 자산을 그대로 보존한다.

### 핵심 변화

- **멀티 ecosystem**: npm / yarn / pnpm / pip (poetry, uv, pipenv) / cargo / go / gem / maven / nuget.
- **외부 advisory DB**: OSV.dev (canonical) + CISA KEV (hard-risk overlay) + GitHub Advisory (enrichment).
- **3-phase 방어**:
  1. Advisory gate (`safedeps check`) — install 명령을 쓰기 전에 advisory DB 조회 → 안전한 spec 결정 → `~/.safedeps/approved-specs/` ledger 기록.
  2. Hook enforcement (`safedeps-pre-guard.sh`) — install 이 ledger 와 일치하는지 검증.
  3. Post-install reorg (`safedeps-post-verify.sh`) — v1 engine, 어긋나면 rollback.
- **Approved spec TTL** (30일) + **daily re-check** (새 CVE 발견 시 revoke + 알람).
- **No silent fallback**: provider 실패는 fail-closed, override 는 명시적이고 observable.

### 마일스톤 (전부 출시 완료)

| 마일스톤 | 산출물 |
|---|---|
| `v2.0-doc` | `ARCHITECTURE.md` v2 작성·push. |
| `v2.1-rename` | repo / skill id / path 를 `safedeps` 로 rename; `safedeps migrate` 가 legacy `~/.npm-reorg-guard` state 를 `~/.safedeps` 로 이전 + legacy hook 정리. |
| `v2.1-providers` | `lib/providers/` — OSV / KEV / GHSA adapter 를 단일 query interface 뒤에, 24h 응답 cache. |
| `v2.1-ledger` | `lib/ledger/` — approved spec JSON I/O (atomic write, hash, TTL 검사). |
| `v2.1-cli` | `bin/safedeps` — `check`, `ledger`, `revoke`, `re-check`, `migrate`, `version` 서브커맨드. |
| `v2.1-guard-patch` | `safedeps-pre-guard.sh` — v1 패턴 차단 위에 ledger enforcement 추가. |
| `v2.1-verify-patch` | `safedeps-post-verify.sh` — v1 reorg 위에 approved spec 과 lockfile diff 비교 추가. |
| `v2.1-multi-ecosystem` | pip / cargo / go / gem / maven / nuget 명령 파싱 + lockfile snapshot, 두 hook 이 rollback truth 로 공유. |
| `v2.1-hook-rename` | hook 파일 namespacing + cross-engine installer (`install-safedeps-hooks.mjs`, idempotent, `--uninstall`). |
| `v2.1-recheck-cron` | daily re-check LaunchAgent — 전체 approved spec 재조회, 새 CVE/KEV/provider-skip 시 revoke + 알림. |
| `v2.1-tests` | end-to-end 테스트 — fixture provider 응답으로 ledger / hook / re-check / migration 검증. |
| `v2.1-release` | npm publish (`@aldegad/safedeps`) + GitHub release. |

### 릴리즈 메모

- npm 패키지 version 은 `package.json` 이 SSoT. `bin/safedeps` `SAFEDEPS_VERSION` 이 이를 따라가고, smoke 테스트는 `package.json` 을 읽어 대조한다 (현재 v2.7.0).
- `npm test` 는 release smoke suite 를 실행한다. full fixture E2E 는 `v2.1-tests` 에 있다.
- daily re-check 는 LLM 토큰을 쓰지 않는다. opt-in 이며, macOS `launchd` user agent 가 매일 `safedeps re-check --json` 을 실행한다 (`install-safedeps-recheck-agent.mjs` 로 atomic install). `~/.safedeps/recheck.log` 와 `~/.safedeps/recheck-alerts.jsonl` 를 쓰고, 새 CVE/KEV/revoke/provider-skip 시 macOS notification 을 띄운다. 네트워크는 OSV / CISA / GHSA query 에만 쓴다.

## v2.2 — effect 기반 enforcement (npm)

상태: v2.2.0 으로 출시 (npm 우선).

### 핵심 변화

- **권위를 effect 로 이동**: PostToolUse 가 실제 `package-lock.json` closure 를 읽고, 설치된 모든 `pkg@version` 이 승인된 direct spec 또는 그 `transitive_specs` 안에 있는지 대조한다.
- **npm full closure 승인**: `safedeps check npm <pkg>@<version>` 이 temp dir 에서 `npm install --package-lock-only --ignore-scripts` 로 script 실행 없는 lockfile 을 만들고 full closure 를 추출한 뒤 OSV `/v1/querybatch` 로 묶어 조회한다.
- **batch + cache**: OSV batch 응답은 기존 single-package provider 와 같은 pkg@version 24h cache 에 다시 저장한다.
- **transitive blind trust 제거**: direct package 가 clean 이어도 transitive 가 미승인 또는 취약이면 승인하지 않는다. 전체 closure 가 clean 이고 ledger 에 기록돼야 한다.
- **PreToolUse 는 빠른 UX guard 로 강등**: 명령 파싱은 명백한 미승인 install 을 빠르게 막고 기존 bypass 회귀 커버리지를 유지하지만, primary enforcement 는 PostToolUse effect gate 다.
- **무실행 설치 (Claude Code)**: PreToolUse hook 이 hook `updatedInput` 기능으로 npm install 에 `--ignore-scripts` 를 붙여 rewrite → 설치가 무실행으로 돈다. PostToolUse 는 closure 가 clean 으로 검증된 뒤에만 `npm rebuild` 를 돌려, 거부된 패키지의 lifecycle script 는 한 번도 안 돈다. Codex CLI 는 `updatedInput` 이 없어 detect-and-rollback 을 유지한다.

### npm-only 경계

이번 phase 는 npm lockfile closure 만 다룬다. pip / cargo / go / gem / maven / nuget 은 각 ecosystem 별 closure resolver 와 script/no-execution 정책이 명시되기 전까지 v2.1 command/ledger/reorg 동작을 유지한다.

### 검증

- closure 승인 시 `transitive_specs` 기록
- `package-lock.json` 에 미승인 transitive package 출현 시 post-verify reorg
- 승인된 full closure install 은 false reorg 없이 통과
- heredoc / echo 텍스트는 install detection 을 trigger 하지 않음
- 기존 smoke + fixture E2E 회귀 suite green

### 현재 우선순위

1. `v2.2.0-release`: `safedeps-security-hardening` 머지 완료, `v2.2.0` 태그 (GitHub release + `npm publish`).

---

## v2.3 — secret 누출 lane doctor + scaffold (출시 완료)

상태: v2.3.0 으로 출시.

### 핵심 변화

- **`safedeps doctor`** — repo-entry 자세 점검. repo 별 secret 누출 lane(`.gitleaks` policy, `.githooks/pre-commit`, 활성 `core.hooksPath`, scanner 가용성)을 진단하고 전역 install-time gate 도 함께 보고한다. 기본 read-only, 에이전트용 `--json`, secret 누출 lane 에 gap 이 있으면 non-zero 로 끝난다.
- **`safedeps doctor --fix` / `safedeps hooks init`** — `lib/gates/templates/` 에서 시작용 `.gitleaks.toml`(또는 `.gitleaks.private.toml`)과 `.githooks/pre-commit` 을 scaffold 한 뒤 hook 을 활성화한다. 비파괴적: repo 가 소유한 기존 policy 는 덮지 않는다.
- **에이전트-as-보안역할 frame** — `SKILL.md` 가 `safedeps doctor` 를 repo-entry 단계로 둬서, 나중의 누출이 아니라 에이전트가 secret-lane 빈틈을 메우게 한다. 설치 스크립트는 repo 별 nudge 를 출력한다(자동 쓰기 없음 — policy 경계는 repo 에 둔다).
- **fail-closed 위임** — scaffold 된 `pre-commit` 은 `safedeps scan secrets --staged`(단일 canonical scanner 경로)에 위임한다. safedeps 미해석이나 scanner 부재 시 silent skip 이 아니라 커밋을 막는다.

### 설계 결정

- `doctor` 는 holistic 하되 **secret-lane 중심**이다: exit code 는 repo 별 lane 만 반영하고, 전역 의존성 gate 는 `deps` check 로 보고되지만 repo 결과를 gate 하지 않는다.
- safedeps 는 **실행**을, repo 는 **policy** 를 소유한다. 템플릿은 repo 가 튜닝하는 seed 로, 기존 Two Lanes 불변식과 정합한다.

### 검증

- `safedeps doctor` 가 미설정 repo 에 gap 을 표시하고 `--fix` 후 clean 으로 보고
- `hooks init` 가 재실행에 비파괴적(repo 편집 보존)
- pre-commit gate 가 커밋된 secret 을 막고, clean·`.env.example` placeholder 커밋은 통과(bypass 하네스 + 회귀)
- 기존 smoke + fixture E2E 회귀 suite green

---

## v2.4 — fail-closed 훅 + 공급망 하드닝 (출시 완료)

상태: v2.4.0 으로 출시.

### 핵심 변화

- **fail-closed 게이트** — PreToolUse/PostToolUse 훅이 못 돌 때 더는 `exit 0`(silent pass) 하지 않는다. lock 못 잡은 설치는 **deny**(fail-closed), 불가피한 `jq` 부재는 **명시적 allow-with-warning**, 그리고 그 결과를 `~/.safedeps/advisory.log` 에 기록한다(observable, no-silent-fallback 불변식). PostToolUse 는 못 돌린 게이트를 clean pass 가 아니라 **UNVERIFIED** 로 기록한다.
- **`SECURITY.md`** — 취약점 신고 정책, 지원 버전, 범위, 설계상 보안 속성(no SaaS, zero deps, no silent fallback).
- **CI 하드닝** — `actions/*` 를 commit SHA 로 pin; gitleaks 다운로드 checksum 검증; ShellCheck 게이트(error-clean); macOS + Linux matrix(v2.3 `stat` 수정이 cross-OS 커버리지 가치를 입증); zero-dependency 속성을 지키는 `npm pack` 검증 step.

### 검증

- lock 불가 설치는 fail-closed deny + `advisory.log` 기록
- jq 부재 시 install 같으면 deny(best-effort fail-closed)+기록, non-install 만 통과
- ledger 라이브러리 부재는 fall-through allow 대신 fail-closed deny
- ShellCheck(`--severity=error`) 전 셸 소스 clean
- 기존 smoke + e2e 회귀 suite Linux·macOS 양쪽 green

### v2.4.1 — 동시 설치 레이스 수정 (#5)

PreToolUse 가 PostToolUse 에 넘기는 pending 상태가 전역 `current_state` 파일 하나였어서, 한 프로젝트에서 설치 둘이 겹치면 서로 덮어써 effect gate 가 엉뚱한 설치를 검증(또는 하나를 누락)할 수 있었다. 이제 pending 을 **설치별로 키잉** — `dir_hash` + (inert rewrite 정규화한) command 해시 — 해서 같은 설치의 Pre/Post 는 같은 키를, 동시 설치는 서로 격리된 키를 갖는다. 동시성 하네스(설치 2개 → pending 2개; post 는 자기 것만 소비)로 가드.

---

## v2.5 — pre-commit 의존성 audit (shipped)

상태: v2.5.0 으로 출시.

### 무엇이 바뀌었나

- **pre-commit 의존성 audit** — scaffold 된 `.githooks/pre-commit` 이 이제 npm lockfile 이 있는 repo 면 비밀키 스캔과 함께 **매 커밋** `safedeps audit npm` 을 돌린다. 취약한 직접·*transitive* 의존성을 — 패키지를 깐 *뒤에* 공개된 CVE("그땐 안전해 보였는데 지금 발견됨")까지 포함해 — 다음 커밋에 잡는다. 데일리 re-check 를 기다리지 않고 어드바이저리 DB 를 다시 조회하기 때문. 실사용이 이걸 만들었다: Dependabot 이 놓친 transitive `hono` 취약점이 정확히 이렇게 잡혔다.
- **의미 있는 `audit npm` exit code** — `0` clean / `1` 취약 / `2` 못 돌림(lockfile 없음, npm/jq 부재, 어드바이저리 DB 도달 불가). **보안 판정**과 **가용성 실패**를 분리한다; npm audit 혼자서는 둘 다 exit 1 로 뭉갠다.
- **관측 가능한 오프라인 failover** — 어드바이저리 DB 도달 불가 시 hook 은 fail-close 하지 않고 **경고 후 커밋을 허용**(exit 2)한다. 네트워크 장애가 오프라인 커밋을 막지 않게. 실제 취약점(exit 1)은 여전히 **차단**. no-silent-fallback 불변식대로 failover 는 커밋 출력에 크게 남고, 오프라인 커밋이 못 본 건 CI 와 데일리 re-check 가 다시 메운다.

### 검증

- `audit npm` exit-code 계약(clean=0 / 취약=1 / 도달불가=2), 가짜 npm 으로 결정적 검증
- pre-commit 이 취약 의존성을 든 커밋을 차단; 어드바이저리 DB 도달 불가 시 경고 후 허용
- 기존 secret-lane + smoke + e2e 회귀 스위트 green 유지

---

## v2.6 — 영어 CLI 출력 + hook 하드닝 (shipped)

상태: v2.6.1 로 출시.

### 무엇이 바뀌었나 (v2.6.0)

- **에이전트 대상 CLI 출력 영어 단일화** — 에이전트가 읽는 모든 CLI·hook 메시지를 영어로 통일해, 동작이 운영자 로케일에 의존하지 않게 했다. README hero 에 데모 GIF 추가.

### v2.6.1 — hook timeout + install 오탐 하드닝

Codex PostToolUse hook 이 무관한 Bash 명령에서 ~600초 멈추는 현상이 관측됐다. 근본원인 3건을 라이브 전역 설정만이 아니라 repo SSoT(installer 와 hook)에서 고쳤다.

- **hook timeout 등록 + backfill.** installer 가 두 엔진 Pre/Post safedeps hook 에 `timeout`(30초)을 명시 기록하고 기존 등록에도 backfill 한다. 이전엔 timeout 없이 등록했고 idempotency 가 command 만 비교해, 재실행해도 빠진 timeout 을 못 채웠다. Codex 는 timeout cap 이 없어 무거운 hook 이 unbounded 로 돌았다.
- **install 탐지 오탐 제거.** `command_is_dependency_install` 이 더 이상 맨 `npx` / `npx --version` 을 install 로 잡지 않고, indirection catcher 는 `eval`·command-substitution 페이로드를 추출해 **실행 위치**로 판단한다 — raw 명령 어디든 `$(`/백틱 + `manager`…`verb` substring 이 있으면 잡던 방식을 버렸다. 그래서 `echo "npm install …"`, `grep`, heredoc/doc 텍스트, `X=$(date); echo "…npm install…"` 는 더 이상 snapshot 을 만들지 않는다. 진짜 위장 install(`eval "npm install …"`, `$(npm install …)`, `… | sh`)은 계속 ledger spec 으로 환원·차단되며, spec 추출 불가면 fail-closed.
- **legacy pending fallback 범위 제한.** PostToolUse 의 legacy/global pending fallback 은 pending 프로젝트가 명령의 cwd 와 일치하고 명령이 install 처럼 보일 때만 동작한다. 불일치면 관측 가능한 `post-verify SKIP` advisory 를 남기고 no-op — 무관한 명령에 대해 closure/OSV 검증을 타지 않는다.

### 검증

- installer 가 두 엔진에 30초 timeout 을 등록·backfill (e2e)
- false-positive corpus(grep / echo / heredoc / `node` / `npm run` / `npm view` / `npx --version` / command-substitution + 데이터 속 install 텍스트)는 snapshot 0; 위장 install indirection 은 계속 deny+snapshot (smoke)
- stale legacy pending + 무관 Bash 명령은 관측 가능한 skip 으로 no-op (e2e)
- 기존 smoke + e2e 회귀 스위트 green 유지; zero npm 의존성; effect-primary 는 npm-only 유지; no silent fallback

---

## v2.7 — 원격 PR governance opt-in (출시 완료)

상태: v2.7.0 으로 출시.

### 무엇이 바뀌었나

- **`doctor` 의 원격 repo 자세** — `safedeps doctor` 가 이제 `remote` lane 을 보고한다. 기존 보안 workflow 존재 여부를 감지하고 default branch 자세를 둘로 나눠 이름 붙인다: no-runner 직접 push 차단과 CI-backed required check.
- **비용 경계 명시** — `main` 직접 push 를 branch rule 로 막는 건 Actions 를 돌리지 않으므로 no-paid-CI 설정에서 권장한다. 원격 GitHub Actions, CI 의 gitleaks, required PR check 는 hosted runner minute 를 쓸 수 있으므로 safedeps 는 보고하고 제안만 한다. workflow 를 만들거나 branch protection 을 조회·변경하지 않고, 빠진 원격 check 를 repo 자세 실패로 보지도 않는다.
- **로컬 우선 fix 는 계속 자동** — `doctor --fix` 는 기존처럼 `.gitleaks` policy 와 repo-local pre-commit hook 을 scaffold 하지만, `.github/workflows` 는 만들지 않는다.
- **JSON schema 수정** — `doctor --json` 이 remedy 없는 `ok` row 도 유지한다(`remedy: null`). schema 는 `lane: "secret | deps | remote"` 를 문서화한다.

### 검증

- `doctor` 가 빠진 원격 workflow 를 opt-in `remote` gap 으로 보고, no-runner 직접 push 차단을 CI-backed required check 와 별도로 표시
- `doctor --fix` 가 `.github/workflows` 를 만들지 않고, 로컬 secret lane 이 고쳐진 뒤 `ok: true` 로 보고
- 기존 smoke + e2e 회귀 스위트 green 유지; zero npm 의존성; 비용이 생길 수 있는 원격 enforcement 는 opt-in 유지, no-runner 직접 push 차단은 권장 자세로 표시

---

## v3 (미래)

### Ledger 변조 내성

악성 패키지의 `postinstall`(사용자 권한 실행)이 "B 승인됨" ledger 엔트리를 위조해, 나중에 B 설치가 advisory 검사를 건너뛰게 하는 2차 공격을 방어한다. 패키지는 실행되기 *전*엔 이걸 못 하므로 install-시점 게이트를 닫는 게 1선 방어이고, 이건 이미 한 번 뚫린 뒤를 대비한 강화다.

접근 — **OSV 를 권위로, ledger 를 캐시로 강등** + 변조 탐지. 싸고 기존 인프라에 얹힘:

1. **enforcement / re-check 시점 재검증** — ledger 판정을 믿지 말고 저장된 evidence 를 OSV 로 재검증. evidence 없는(또는 OSV 가 취약이라 답하는) 위조 엔트리는 잡혀서 revoke. ledger 를 OSV SSoT 의 memoization 으로 강등.
2. **post-install 스캔에 `~/.safedeps/` 추가** — post-verify 가 이미 `~/.ssh` / `.env` 건드리는 `postinstall` 을 flag 함; `~/.safedeps/` 를 추가하면 ledger 에 쓰는 패키지가 reorg 를 유발 — 위조를 현행범으로.
3. **daily re-check 의 provenance 대조** — `advisory.log` 기록이 없는(= 진짜 `safedeps check` 가 안 돈) ledger 엔트리를 위조 의심으로 flag.

명시적 비채택: **암호화 ledger 서명은 안 함** — same-uid 공격자가 서명 키를 읽어 위조를 재서명할 수 있어 로컬 HMAC/서명은 실질 경계가 못 됨. 방어는 로컬 비밀이 아니라 authority-elsewhere(OSV) + 탐지.

### 기타 v3 작업

- **Plugin provider** — 사용자 정의 advisory source (사내 vuln DB, private registry).
- **Policy file** — `.safedeps.toml` 로 팀 정책 (KEV hit 자동 block, CVSS 7+ 사용자 컨펌, 패키지 allowlist).
- **CI mode** — `safedeps check --ci` 로 GitHub Actions / CircleCI fail-fast.
- **npm 밖 closure 확장** — pip / cargo / go / gem / maven / nuget closure resolver 와 명시적 no-script/no-build 정책.
- **Transitive risk score** — deps.dev graph 통합; 직접 dep 너머 위험 시각화.

## v4+ (장기)

- **Team-shared ledger** — multi-machine approved spec sync.
- **Agent remediation** — vuln 발견 시 Claude / Codex 가 더 안전한 대체 모듈 제안 (LLM-as-judge).
- **Diff visualization** — 두 approved spec snapshot 사이 dependency tree diff.

---

## 변경 history

- 2026-05-18: ROADMAP 최초 작성 — v1 → v2 결정 + v3 / v4 개요.
