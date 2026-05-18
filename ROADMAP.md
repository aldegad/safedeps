# Safedeps Roadmap

> 시간축 + 우선순위. **왜·어떻게** 는 `ARCHITECTURE.md`, **언제·뭐 먼저** 는 이 파일.

---

## 결정 SSoT

**스코프 = 개발 의존성만** (npm / pip / cargo / go / gem / maven / nuget).
OS-level (nginx / apt / brew / system binary) 은 **별도 도구로 분리**. SRP 측면 더 깔끔.

근거: dev 의존성과 OS 패키지는 운영 결이 다름.
- dev = "새 기능 → install 명령 → 매번 새 패키지 진입" (install 순간 게이트가 의미 큼).
- OS = "기존 패키지 security update" (cron 주기 audit + RSS 알람이 더 맞음).

→ safedeps = dev 의존성 install 단계 결.
→ OS-level 은 별도 (가칭 `infra-cve-monitor` — 미래 v3+).

---

## v1 (출시 완료)

**이름**: `npm-reorg-guard`
**Status**: shipped as v1. GitHub repo has since been renamed to `aldegad/safedeps`.

- npm ecosystem 전용.
- PreToolUse hook (guard.sh): typosquat / curl|bash / 비표준 registry 등 **hardcoded pattern** 차단.
- PostToolUse hook (verify.sh): lockfile diff + install script 검사 → 의심 시 **reorg** (rollback).
- 외부 vuln DB 조회 0. self-contained.

**한계**:
- npm 만.
- 알려진 CVE 검사 X (pattern matching 위주).
- adversarial 회피 가능.

---

## v2 — Safedeps (현재 작업 중)

**이름**: `safedeps`, 내부 engine = `reorg-guard` (v1 자산 보존).
**Status**: `ARCHITECTURE.md` v2 작성 완료, v2.1 provider/ledger 구현 시작.

### 핵심 변화
- ecosystem 통합: npm / yarn / pnpm / pip (poetry, uv, pipenv) / cargo / go / gem / maven / nuget.
- **외부 vuln DB 결합**: OSV.dev (primary) + CISA KEV (hard-risk overlay) + GHSA (cross-check). NVD / deps.dev / Snyk = enrichment.
- **3-phase defense**:
  1. Advisory Gate (`safedeps check`) — install 명령 *작성 전* vuln DB 조회 → 안전 spec 결정 → `~/.safedeps/approved-specs/<hash>.json` ledger 기록.
  2. Hook Enforcement (`safedeps-pre-guard.sh`) — ledger 일치 검증.
  3. Post-Install Reorg (`safedeps-post-verify.sh`) — v1 engine 그대로 (rollback fallback).
- Approved spec **TTL** (30일) + **daily re-check** cron (새 CVE 발견 시 revoke + 알람).
- **No silent fallback**: provider fail = fail-closed + `--allow-unverified` explicit override (observable).

### 구현 마일스톤

| 마일스톤 | 산출물 | 의존 |
|---|---|---|
| **v2.0-doc** ✅ | `ARCHITECTURE.md` v2 작성·push | — |
| **v2.0-roadmap** ✅ | 이 문서 | — |
| **v2.1-rename** ✅ | GitHub repo rename `aldegad/npm-reorg-guard` → `aldegad/safedeps` ✅. 로컬 repo/skill id/path `safedeps` ✅. `safedeps migrate` 로 legacy `~/.npm-reorg-guard` → `~/.safedeps` 이전 + legacy hook cleanup. | v2.0-doc |
| **v2.1-providers** ✅ | `lib/providers/` 신규 — OSV / KEV / GHSA adapter. 단일 query interface. 응답 cache (TTL 24h). | — |
| **v2.1-ledger** ✅ | `lib/ledger/` 신규 — approved spec JSON I/O (atomic write, hash 계산, TTL 검사). | v2.1-providers |
| **v2.1-cli** ✅ | `bin/safedeps` 신규 — `check`, `ledger`, `revoke`, `re-check`, `migrate`, `version` 서브커맨드. | v2.1-providers, v2.1-ledger |
| **v2.1-guard-patch** ✅ | `scripts/safedeps-pre-guard.sh` 갱신 — ledger 일치 검증 추가 + v1 pattern 유지. | v2.1-ledger |
| **v2.1-verify-patch** ✅ | `scripts/safedeps-post-verify.sh` 갱신 — approved spec 과 lockfile diff 비교 추가 + v1 reorg 유지. | v2.1-ledger |
| **v2.1-multi-ecosystem** ✅ | pip / cargo / go / gem / maven / nuget 명령 파싱 + lockfile snapshot. `safedeps-pre-guard.sh` 는 install 분류와 typosquat pattern 을 확장했고, `safedeps-post-verify.sh` 는 monitored dependency files 기준으로 rollback truth 를 공유한다. | v2.1-guard-patch |
| **v2.1-hook-rename** ✅ | hook 파일 namespacing (`guard.sh` → `safedeps-pre-guard.sh`, `verify.sh` → `safedeps-post-verify.sh`) + cross-engine installer (`scripts/install/install-safedeps-hooks.mjs`, ~/.claude + ~/.codex 자동 등록, idempotent, --uninstall). | v2.1-cli |
| **v2.1-recheck-cron** ✅ | daily re-check launchd — 전체 approved spec 재 query → 새 CVE/KEV/provider-skip 시 revoke + macOS 알림. | v2.1-providers, v2.1-ledger |
| **v2.1-tests** ✅ | end-to-end 테스트 — fixture provider 응답 → 명령 시뮬레이션 → ledger / hook / re-check / migration 동작 검증. | 모든 v2.1 |
| **v2.1-release** | npm package publish (`@aldegad/safedeps`) + GitHub release v2.1.0. | 모든 v2.1 |

### 2026-05-18 릴리즈 전 정리 메모

- npm package metadata 는 v2.1.0 기준으로 정합화한다 (`package.json` version + `bin.safedeps`).
- `npm test` 는 release smoke suite 를 실행한다. full fixture E2E 는 `v2.1-tests` 후속으로 남긴다.
- daily re-check 는 토큰을 쓰지 않는다. 알렉스가 opt-in 하면 macOS `launchd` user agent 로 `safedeps re-check --json` 을 매일 실행하는 구조가 기본이다. 네트워크는 OSV/CISA/GHSA provider query 에만 사용된다.
- 실제 local background job 은 `scripts/install/install-safedeps-recheck-agent.mjs` 로 atomic install 한다. wrapper 는 `~/.safedeps/recheck.log` 와 `~/.safedeps/recheck-alerts.jsonl` 를 쓰고, 새 CVE/KEV/revoke/provider-skip 이 있으면 macOS notification 을 띄운다.

### 후속 로드맵 — 전체 workspace inventory audit

전체 repo/lockfile inventory scan 은 safedeps v2.1 daily re-check 와 분리한다. 후보 설계는 최초 one-shot inventory scan 으로 workspace 의 manifest/lockfile 을 발견하고, 사용자가 채택한 spec 만 approved ledger 또는 별도 inventory ledger 에 넣은 뒤 주기 re-check 대상으로 삼는 방식이다. 이렇게 해야 safedeps 의 현재 책임인 install approval gate 와 이미 디스크에 존재하는 dependency audit 의 책임 소재가 섞이지 않는다.

### 우선순위

1. v2.1-release: commit / tag / GitHub release / npm publish.

---

## v3 (미래 — 알렉스 결정 시점)

- **plugin model** — 사용자 정의 provider (회사 내부 vuln DB, private registry).
- **policy file** — `.safedeps.toml` 로 \"우리 팀 정책: KEV hit 자동 block, CVSS 7+ 사용자 컨펌, 특정 패키지 allowlist\" 명시.
- **CI mode** — `safedeps check --ci` 로 GitHub Actions / CircleCI fail-fast.
- **transitive risk score** — deps.dev graph 통합. 직접 dep 만 아니라 transitive dep 의 \"위험 점수\" 시각화.

---

## v4+ (장기)

- **team-shared ledger** — multi-machine approved spec sync (회사 dev 모두가 같은 ledger 공유).
- **AI agent integration** — Claude / Codex 가 vuln 발견 시 \"대체 모듈 X 권장\" 직접 제안 (LLM-as-judge).
- **diff visualization UI** — 두 approved spec snapshot 사이의 dep tree diff 시각화.

---

## 명시적 NON-GOAL (이 도구는 하지 않는다)

- **OS-level CVE 감시** (nginx, apt 패키지, system binary). → 별도 도구 `infra-cve-monitor` 결로 분리.
- **컨테이너 이미지 스캔**. → Trivy / Grype.
- **runtime 권한 sandbox**. → lavamoat / firejail.
- **registry 자체의 손상 감지**. → registry 운영사 책임.
- **사용자 평판 분석 (behavioral)**. → socket.dev.

safedeps 의 결 = **\"개발 의존성 install 단계의 advisory + spec gate + rollback\"** 한 줄. 다른 결로 확장하지 않는다 — SRP 측면 다른 도구로 분리.

---

## 관련 미래 도구 (분리 권장)

| 도구 | 결 | 관계 |
|---|---|---|
| `safedeps` (이것) | dev 의존성 (npm/pip/cargo/...) install 단계 | 현재 작업 |
| `infra-cve-monitor` (가칭) | nginx / apt / OS package 주기적 audit + RSS 알람 | 미래 별 도구 |
| `container-scan-bridge` (가칭) | Trivy / Grype wrapper, 컨테이너 이미지 결 | 미래 별 도구 |

세 도구가 같은 결 (\"보안\") 의 다른 layer. 한 skill 에 통합하지 않고 분리.

---

## 변경 history

- 2026-05-18: ROADMAP.md 최초 작성. v1 → v2 결정 + v3 / v4 / NON-GOAL 명시. (코덱시 surface:195 합의 + 클로디시 surface:61 작성.)
