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

- npm 패키지 version 은 `package.json` 이 SSoT. `bin/safedeps` `SAFEDEPS_VERSION` 이 이를 따라가고, smoke 테스트는 `package.json` 을 읽어 대조한다 (현재 v2.12.1).
- `npm test` 는 release smoke suite 를 실행한다. full fixture E2E 는 `v2.1-tests` 에 있다.
- daily re-check 는 LLM 토큰을 쓰지 않는다. opt-in 이며, macOS `launchd` user agent 가 매일 `safedeps re-check --json` 을 실행한다 (`install-safedeps-recheck-agent.mjs` 로 atomic install). `~/.safedeps/recheck.log` 와 `~/.safedeps/recheck-alerts.jsonl` 를 쓰고, 새 CVE/KEV/revoke/provider-skip/위조-의심 시 macOS notification 을 띄운다. 네트워크는 OSV / CISA / GHSA query 에만 쓴다.

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

## v2.8 — 적대적 재검수 + 전역 설치 수정 (출시 완료)

상태: v2.8.1 로 출시.

### v2.8.0 — 적대적 재검수 (7건)

멀티에이전트 적대적 재검수(22건 제기 → 3렌즈 스켑틱 검증 → 7건 confirmed)에서 드러난 실제 갭을 모두 수정했고, 전부 재현 테스트로 확인했다:

- **파서 바이패스 (critical)** — leading whitespace 나 맨 `VAR=val ` env-prefix 가 install 분류기를 통째로 우회해 게이트·inert rewrite·snapshot·effect gate 를 한 번에 무력화했다. `normalize_install_text` 가 이제 모든 분류기가 거치는 단일 지점에서 leading whitespace 와 맨 할당 prefix 를 strip 한다(따옴표 값은 제외해 `msg="run npm install"` 은 non-match 유지).
- **`bun` 무게이트** — `bun add` / `bun install` 이 어느 분류기에도 없었다. install 패턴·ecosystem 감지(→ npm)·pipe 페이로드·lock-file set(`bun.lock` / `bun.lockb`)에 추가했다.
- **`--prefix` 우회** — 설치 디렉토리 override(`--prefix` / `--cwd` / `--dir` / `--install-dir`)를 effect gate 가 무시하고 cwd 를 clean 으로 오확정했다. snapshot·effect-gate 타깃을 실제 설치 디렉토리로 재지정한다(pending 키는 cwd 유지 → post hook 매칭 보존).
- **`producer | sh` 평문 파이프** — pipe-to-shell 탐지가 command-substitution 페이로드에만 돌았는데, 이제 raw 명령에도 돌아 `printf 'pip install x' | sh` 를 잡는다.
- **effect gate 가 파서 의존** — README 는 "커맨드-독립 backstop" 이라 광고했지만 실제로는 pending state 있을 때만 동작해 파서 맹점을 그대로 상속했다(문서-코드 drift). no-pending 분기를 진짜 커맨드-독립 backstop(live `package-lock.json` closure 체크)으로 전환했다. 자동 롤백은 confirmed baseline 이 있을 때만, 없으면 fail-loud.
- **`launchd` re-check DOA** — 복사된 런타임이 `lib/npm/closure.sh` 를 빼먹어 복사된 `bin` 이 `set -e` 하 `source` 단계에서 즉사, 일일 re-check 가 한 번도 안 돌았다. `closure.sh` 를 복사하고, 향후 lib 의존 추가 재발을 막는 post-install 런타임 smoke 가드를 넣었다.
- **compound inert 무력화** — `--ignore-scripts` 가 문자열 끝에 붙어 `npm install evil && npm run build` 에서 trailing 명령에 적용됐다(install 은 스크립트를 그대로 실행). 이제 compound 는 verb 직후 in-place 삽입하고, 불가 시 관측 가능한 detect-and-rollback 으로 다운그레이드한다.

### v2.8.1 — 전역 설치 경로 해석

`bin/safedeps` 가 `${BASH_SOURCE[0]}` 에서 repo dir 를 구할 때 심링크를 해석하지 않았다. 전역 설치(`npm i -g`, 또는 installer 의 `--link-bin` 로 만든 `~/.local/bin`)는 `<prefix>/bin/safedeps` 에 파일 심링크를 두므로, `dirname/..` 가 node prefix 로 풀려 모든 명령이 `source <prefix>/lib/providers/providers.sh: No such file or directory` 에서 죽었다. 부트스트랩이 이제 repo dir 를 구하기 전에 심링크 체인을 실제 스크립트까지 따라간다(이식 가능한 `readlink` 루프, `readlink -f` 아님). hook 은 영향 없었다 — skill 의 디렉토리 심링크를 통해 호출돼 `cd .../scripts && pwd` 가 이미 실제 repo 로 떨어지기 때문.

### 검증

- npm 스타일 전역 파일 심링크로 호출한 CLI 가 패키지 dir 를 해석하고 동작(smoke); 같은 호출이 수정 전 부트스트랩에서는 실패
- v2.8.0 회귀 세트: leading-space / env-prefix / bun / pipe bypass, compound in-place inert(#7), `--prefix` snapshot 타깃(#3), 커맨드-독립 backstop(#5)
- 기존 smoke + e2e 회귀 스위트 green 유지; zero npm 의존성; effect-primary 는 npm-only 유지; no silent fallback

---

## v2.9 — 멀티-ecosystem 의존성 audit (출시 완료)

상태: v2.9.0 으로 출시.

### 무엇이 바뀌었나

- **`safedeps audit` 가 npm / pnpm / yarn (Classic + Berry) / bun 을 커버.** pre-commit 의존성 audit 는 npm 전용이었다(`package-lock.json` / `npm-shrinkwrap.json` 만 읽어 pnpm/yarn/bun 프로젝트는 exit 2 — 판정 없음). 이제 `safedeps audit` 는 있는 lockfile 에서 ecosystem 을 자동 감지하고 각 도구의 네이티브 audit 에 위임한다. 이들은 전부 npm 레지스트리 advisory 엔드포인트를 조회하므로 audit lane 의 advisory source 가 ecosystem 간 일관되게 유지된다(install-time OSV 게이트는 그대로이며 여전히 npm-only).
- **lockfile 파싱이 아니라 네이티브 위임.** 각 ecosystem 의 `audit` 명령이 자기 lockfile 을 해석해 advisory 를 보고하고, safedeps 는 서로 다른 리포트 형태(npm/pnpm `.metadata.vulnerabilities`, yarn Classic NDJSON `auditSummary`, yarn Berry 의 `yarn npm audit` NDJSON advisory 스트림, bun 의 패키지별 advisory 객체)를 하나의 severity-count 판정으로 정규화한다. yarn 라우팅은 major 버전을 감지한다(Classic 1.x `yarn audit` vs Berry 2+ `yarn npm audit`). bun 은 lockfile 을 읽으므로 `node_modules` 가 필요 없다. 새 lockfile 파서가 없고 zero-dependency 속성이 유지된다(bun 의 바이너리 `bun.lockb` 를 파싱할 필요가 없다).
- **같은 exit-code 계약, 이제 ecosystem 별 + aggregate.** `0` clean / `1` 취약 / `2` 못 돌림(lockfile 없음, 도구/jq 부재, advisory DB 도달 불가)이 모든 ecosystem 에 적용된다. lockfile 이 여러 개 공존하면 aggregate 판정은 최악으로: 어디든 실제 취약점이 있으면 우선(1), 없으면 어디든 가용성 실패(2), 그것도 없으면 clean(0). 어떤 ecosystem 도 조용히 건너뛰지 않는다.
- **자동 감지 pre-commit.** scaffold 된 `.githooks/pre-commit` 이 이제 지원 lockfile 을 감지해 `safedeps audit`(ecosystem 인자 없이)를 돌린다. `safedeps audit <eco>` 는 명시적 단일 ecosystem 실행으로 남는다. offline failover 는 그대로: 실제 취약점은 차단, advisory DB 도달 불가는 경고 후 통과.

### 검증

- npm·pnpm·yarn Classic·yarn Berry·bun 의 exit-code 계약(clean=0 / 취약=1 / 도달불가=2)을 각 도구의 실제 리포트 형태를 내는 가짜 도구로 결정적 검증 — coexisting lockfile aggregate 동작 + bun 의 malformed/비표준/누락 severity fail-closed 처리 포함
- scaffold 된 pre-commit hook 이 취약한 pnpm 의존성을 든 커밋을 npm 과 동일하게 차단(라이브 통합)
- 라이브 레지스트리 sanity: 실제 npm/pnpm/yarn-Classic/bun clean audit 는 0; 실제 pnpm 취약 audit 는 1; 실제 Yarn Berry `yarn npm audit` 와 `node_modules` 없는 lockfile 기준 실제 bun audit 둘 다 취약 spec 에 1
- 기존 smoke + e2e 회귀 스위트 green 유지; zero npm 의존성; effect-primary 는 npm-only 유지; no silent fallback

### v2.9.1 — pre-guard spec 추출 false-positive 수정

PreToolUse 가드가 복합 명령의 *모든* 세그먼트에서 `pkg@version` 토큰을 추출해서, install 이 아닌 세그먼트(echo / 로그 줄, 경로, 주석)에만 등장한 토큰이 다른 곳의 진짜 install 에 엮여 잘못된 DENY 를 냈다 — 예: `echo "bumped left-pad@1.0.0"; npm install` 이 `left-pad@1.0.0` 설치인 것처럼 차단됐다. 이제 spec 추출이 세그먼트별 `command_is_dependency_install` 로 게이트된다: 자기 자신이 install 명령인 세그먼트만 operand 를 기여한다(npx/dlx 러너는 기존 operand 처리 유지). 진짜 install, 위장 install(`eval` / `$()` / `… | sh`), bypass corpus 는 여전히 DENY; echo-mention 케이스만 통과한다. 회귀 테스트가 복합(진짜 spec 만 명명)과 bare-install(false deny 없음) 둘 다 커버.

### v2.9.2 — daily re-check 알림이 ledger 위조 의심을 표면화

`safedeps re-check` 는 `advisory.log` 승인 기록이 없는 ledger 엔트리를 이미 `suspected_forgery` 로 flag 했지만, daily 알림 wrapper(`safedeps-recheck-alert.sh`)가 그 필드를 읽지 않았다: 위조 엔트리의 패키지가 clean 으로 조회되면 `still_clean` 으로 집계돼 어떤 알림 조건도 발화하지 않았고 flag 는 조용히 삼켜졌다 — invariant 가 금지하는 silent fallback 그 자체. 이제 wrapper 가 `suspected_forgery` 를 집계해 알림 트리거와 notification 메시지에 포함하고, alert 레코드에 flag 된 엔트리가 실린다. smoke 가 양방향을 커버한다: forgery-only fixture(다른 트리거 전부 0)는 반드시 알림, 완전 clean fixture 는 아무것도 추가하지 않아야 한다.

같은 릴리스의 cross-engine validator 검수가 provenance 검사 자체의 구멍 다섯을 더 잡았다(전부 재현 가능). (1) `advisory.log` 파일 자체가 없으면 검사가 통째로 우회됐다(`[[ -f advisory.log ]]` 가 파일 부재를 승인 증거로 취급) — 모든 정상 승인은 로그를 쓰므로, 이제 missing log = missing provenance 다. (2) ledger 의 `hash` 필드는 공격자가 쓸 수 있어, 정상 승인의 64자 hash 를 복사하면 *다른* 패키지의 위조 엔트리가 그 승인의 provenance 를 빌릴 수 있었다 — 이제 canonical hash 를 엔트리 자신의 spec 에서 재계산하고, 저장값-재계산값 불일치 자체를 flag 한다(`hash_spec_mismatch`). (3) 로그 대조가 substring `grep -F` 라 hash/package/version *접두사*(또는 빈 hash)가 정상 라인에 매칭됐다. (4) 전체-필드 수정을 처음엔 `awk -v` 로 했는데, awk 가 값의 백슬래시 이스케이프를 해석해 위조 package 필드 `fixture-p\141d` 가 `fixture-pad` 로 정규화돼 그 승인을 빌렸다. 이제 순수 bash 리터럴 필드 비교다 — substring 도, 이스케이프 해석도 없다. (5) canonical hash 가 세 필드를 개행으로 이어붙이므로, package/version 에 실제 개행(또는 다른 제어문자)을 주입하면 필드 경계가 밀려 다른 튜플이 정상 승인의 hash 로 붕괴할 수 있었다 — 제어문자가 든 스펙은 이제 hash·provenance 비교 전에 `malformed_spec` 으로 거부된다. e2e 회귀가 no-log·copied-hash·접두사·백슬래시-이스케이프·제어문자 위조와 정상-승인-무오탐 케이스를 커버한다.

---

## v2.10 — Yarn resolution 인지 check (출시 완료)

Status: v2.10.0 으로 출시.

`safedeps check` 가 npm 스펙을 published closure 만으로 판정해서, 루트 `resolutions` 로 취약한 transitive dependency 를 patch 한 Yarn Berry 프로젝트가 실제로는 설치하지도 않는 취약점 때문에 거부됐다. 그 프로젝트에 대해서는 published closure 가 틀린 truth 다. installed closure 가 맞다. 이제 대상 디렉터리가 비어있지 않은 루트 `resolutions` 를 가진 Yarn Berry 프로젝트면, `check` 는 registry 를 probe 하지 않고 그 프로젝트의 실제 `yarn.lock` 을 `yarn info -A -R --json` 으로 읽어 closure 를 해석한다. descriptor-to-locator resolution 의 소유권은 Yarn 에 그대로 두고, safedeps 는 lockfile resolution 을 재구현하는 대신 그 machine-readable graph 를 소비한다.

그 결과 나오는 승인은 전역이 아니라 project-scoped 다. ledger entry 가 가지는 `project_context` 의 `context_hash` 에 project directory, 루트 `resolutions`, `yarn.lock` content 가 접혀 들어가므로, 그 승인은 다른 프로젝트의 조회를 만족시킬 수 없고 `resolutions`/`yarn.lock` 변경 이후에도 살아남지 못한다. 불일치는 `context_mismatch` 로 거부한다. PreToolUse guard 도 같은 context 를 해석해 같은 hash 를 조회에 접어 넣는다. 나머지 fail-closed 동작은 그대로다. `resolutions` 는 선언됐는데 lockfile 을 쓸 수 없으면 invalid context 로 즉시 거부하고, resolved graph 에서 검증할 수 없는 package 는 published closure 가 clean 이어도 deny-only 로 남는다.

## v2.11 — Yarn candidate closure materialization (출시 완료)

Status: v2.11.0 으로 출시.

v2.10 은 이미 `yarn.lock` 에 있는 package 만 판정할 수 있었고, 그래서 정작 이 gate 가 존재하는 이유인 "추가하기 전에 dependency 를 검사한다"가 빠져 있었다. locator 가 없으면 `project-closure-unavailable` 로 떨어져 deny-only 가 됐고, 프로젝트 자신의 `resolutions` 로 안전하게 해석됐을 경우에도 새 Yarn dependency 의 정상 릴리스 경로가 막혔다.

### 무엇이 바뀌었나

- **Isolated candidate materialization.** locator 가 없으면 safedeps 가 `mktemp` 아래 private mirror 를 만들고 프로젝트의 canonical resolution input 만 복사한다. 루트와 workspace 의 `package.json`, `yarn.lock`, `.yarnrc.yml`, 그리고 `.yarn/releases`·`.yarn/plugins`·`.yarn/patches` 파일이다. `node_modules`, cache, unplugged package, install state, VCS 데이터는 복사하지 않는다. canonical resolution input 도 아니고, 임시 resolver 에 넘겨도 되는 것도 아니기 때문이다. candidate 는 mirror 의 manifest 에만 추가되고, Yarn 이 거기서 `yarn install --mode=update-lockfile --no-immutable` 로 해석한다. 이 공식 모드는 link 단계 없이 lock resolution 만 갱신하므로 candidate 의 lifecycle script 는 실행되지 않는다.
- **호출자 불변성.** 전 과정에서 호출자의 tree 는 read-only 다. safedeps 는 Yarn 실행 전후 모두 프로젝트 input 을 다시 hash 한다. 중간에 manifest, `resolutions`, config, lockfile 편집이 끼어들면 뒤섞인 프로젝트 상태에 대한 승인을 내주는 대신 candidate 를 무효화한다.
- **Provenance 로 묶인 승인.** ledger context 가 `yarn-project-materialized-lockfile` 이 되고 `materialization` 에 candidate locator, 묶인 `input_sha256`, `generated_lockfile_sha256`, 정확한 Yarn 명령, `isolation: "private-project-mirror"` 를 싣는다. `safedeps_ledger_validate_json` 은 이 필드 전부를 요구하고, `materialization.input_sha256` 이 context 의 `input_sha256` 과 다른 entry 를 거부한다. 따라서 승인의 truth 는 registry probe 도 낡은 lockfile 도 아니고, 호출자 자신의 input 을 hash 로 묶어 복사한 것에서 유도된 Yarn resolution 이다.
- **Fallback 없음.** input 복사, mirror 의 canonical input hash 대조, Yarn 호출, 생성된 lockfile 에서의 candidate 해석 중 하나라도 실패하면 `project-candidate-materialization-unavailable` 로 거부한다. published closure 를 대체물로 쓰지 않는다.

### 검증

- hermetic Yarn 프로젝트 fixture: isolated closure 가 patch 된 `sharp@0.35.3` / `postcss@8.5.21` 을 해석할 때만 candidate 가 승인되고, patch 안 된 `sharp@0.34.5` / `postcss@8.4.31` closure 는 거부된다
- materialization 불가는 ledger 승인도 published-closure probe 도 없이 거부한다. input 이나 lock context 가 바뀌면 거부한다
- 호출자 tree 와 lockfile hash 가 전후로 byte-identical 이고, 복사된 mirror input 에 nested `node_modules` 가 없음을 assert 한다
- 기존 smoke + e2e 회귀 green, npm dependency 0, effect-primary 는 npm 한정 유지

---

## v2.12 — npm `overrides` 인지, override 집합에 스코프 (출시 완료)

Status: v2.12.0 으로 출시.

`overrides` 는 취약한 transitive 를 고치는 npm 표준 처방인데, closure probe 가 빈 manifest 로 해석해서 그걸 아예 못 봤다. 그래서 이미 그 방식으로 고쳐놓은 레포가 여전히 거부됐다 — safedeps 가 올바른 수정을 벌준 셈이다. 이제 `check` 는 소비 레포의 `overrides` 를 찾아 probe 에 반영하고, 실제 설치와 같은 방식으로 transitive 를 해석한다.

### 무엇이 바뀌었나

- **overrides 가 probe 까지 간다.** 탐색은 `SAFEDEPS_NPM_OVERRIDES_JSON` 을, 없으면 작업 디렉터리에서 위로 올라가며 만나는 첫 번째 비어있지 않은 `overrides` 를 쓰고 저장소 루트에서 멈춘다. 구체 핀만 인정하고 `$`-reference 는 버린다(독립 probe 에서 의미 없음). 반영에 실패하면 조용히 버리지 않고 로그한다 — 검사가 더 엄격해질 뿐이지만, 설명 없는 거부는 관측 가능하지 않다.
- **경계가 워크트리를 포함한다.** 워크트리 루트의 `.git` 은 디렉터리가 아니라 파일이라, 디렉터리만 검사하면 그걸 지나쳐 상위의 overrides 를 주워왔다. 이제 Yarn project-context walk-up 과 같은 판정을 쓴다.
- **승인이 override 집합에 스코프된다.** overrides 를 반영하면 closure 가 소비 프로젝트의 함수가 되고, published-package 승인이 전역일 수 있는 건 오직 그것이 프로젝트 무관이기 때문이다. ledger entry 는 `npm-overrides-probe` 가 되어 project root, override 집합, 그 canonical hash, 그리고 둘을 합친 `context_hash` 를 싣고 키가 그 hash 를 포함한다. transitive 를 patch 한 레포에서 얻은 승인은 patch 하지 않은 레포의 검사를 더 이상 만족시키지 못한다. pre-guard 도 같은 키를 유도하므로 스코프된 승인은 게이트를 그대로 통과한다.

overrides 를 반영해도 취약점은 못 숨긴다. probe 가 각 override 를 구체 버전으로 해석하고 OSV 는 그 버전으로 조회되므로, 여전히 취약한 릴리스를 가리키는 override 는 다른 것과 똑같이 걸린다.

### 검증

- 승인 스코핑 실측·테스트: patched 집합은 승인, 같은 집합은 재사용, overrides 없는 레포는 거부, 다른 집합은 거부
- 여전히 취약한 버전을 가리키는 override 는 거부
- pre-guard 키 정합: 승인을 얻은 레포는 allow, 그 overrides 가 없는 레포는 deny
- hermetic e2e 가 npm 을 stub 해 resolved closure 가 probe manifest 에 의존하게 만들어 registry 접근 없이 전 경로를 고정. 스코핑과 주입 경로 둘 다 뮤테이션 검증
- ledger 는 override-set hash 가 없거나 집합이 빈 `npm-overrides-probe` 컨텍스트를 거부

---

## v2.12.1 — 커맨드 게이트의 경계를 재고 문면화 (출시)

Status: v2.12.1 로 출시.

구·신 코드가 똑같이 놓치는 셸 우회 5형태가 보고됐다. 답할 가치가 있는 질문은 "5형태를 잡을 수 있나" 가 아니라 "이것들이 통과하는 이유가 하나인가 다섯인가" 였다 — 자매 도구에서 같은 축의 열거가 5형태를 닫자 9형태를 뱉은 실측이 있었기 때문이다.

답은 하나다. 게이트는 인터프리터에게 텍스트를 넘기는 구문 carrier 를 인식해 설치를 판정하고, 그 인식은 한 인용 레벨에 적용되는 닫힌 열거다. 모든 미탐이 그 목록 바깥의 carrier 다. 그런데 "그 한 자리" 를 고쳐도 열거는 안 끝난다. 그 자리가 곧 열거이기 때문이다 — 보고된 5형태를 프로브하다 4형태가 더 나왔다(`| command sh`, 파일로 쓴 뒤 실행, `sh -c` 안에 중첩된 `eval`, 최상위 명령 치환). 5→9 성장이 한 세션에서 그대로 재현됐다.

### 무엇이 바뀌었나

- **수리는 하나이고, 그건 새 carrier 가 아니다.** `normalize_install_text` 는 "경로가 붙거나 `env` 가 앞에 붙은 호출은 맨 호출과 같다" 를 이미 선언하고 있다. 그게 설치 텍스트에는 적용되고 파이프의 소비자 쪽에서는 건너뛰어져서, 한 파이프의 양쪽이 "같은 호출" 의 정의를 서로 다르게 쓰고 있었다. 소비자를 정규화하면 `| /bin/sh`, `| /usr/bin/bash`, `| env sh`, `| env FOO=1 sh`, `| command sh`, 그리고 이것들을 `sh -c` 로 감싼 형태가 닫힌다. 새 개념 없고, 코퍼스의 다른 판정은 하나도 안 움직였다.
- **새 carrier 구문은 하나도 추가하지 않았다.** herestring, `xargs` 조립 명령줄, 파일로 쓴 뒤 실행, `sh -c` 안의 `eval`, 같은따옴표 중첩 `sh -c` 는 의도적으로 판정하지 않는다. 거기가 열거가 수렴 없이 자라는 자리이고, 두 종류의 변경을 가르는 규칙은 이제 `ARCHITECTURE.md` 에 적혀 있다.
- **생태계 비대칭을 문서화했다.** npm 에서 인식 못 한 carrier 는 **지연 탐지**다 — 효과 게이트의 인식기는 carrier 열거 없는 raw 텍스트 매치라 같은 명령에 발화하고 살아 있는 lockfile 을 읽는다. `pip`, `cargo`, `go`, `gem`, `maven`, `nuget` 은 커맨드 게이트 뒤에 아무것도 없어서 같은 형태가 `UNVERIFIED` 로만 기록되는 완전 미탐이다. 파서 갭을 npm 기준으로 읽던 것이 이번에 고친 오해다.
- **미끼를 갭에서 분리했다.** `sh -c "sh -c "…""` 는 이중 중첩처럼 읽히지만 바깥 따옴표가 안쪽에서 닫혀 아무것도 설치되지 않는다. `-I` 나 `-0` 없는 `xargs sh -c` 는 그 줄을 `$0` 으로 넘긴다. 보고된 5형태 중 둘은 적힌 그대로는 미끼였다.
- **`scripts/test/consumer-forms.sh`** 가 전부를 고정하고 `npm test` 에 합류한다.

### 검증

- 전체 코퍼스 판정 드리프트를 `1e33b65`(오탐 협착 이전), `main`, 이번 수리 이후 세 지점에서 측정: 협착은 아무것도 줄이지 않았고, 이번 수리는 6형태를 pass→deny 로 옮기고 그 외에는 아무것도 안 움직였다
- 모든 형태의 상태를 가짜 패키지 매니저에 대고 실행해서 증명 — 실제로 매니저에 도달하는 형태만 갭으로 계산
- npm 지연 탐지 주장은 기계 검증: 커맨드 게이트가 통과시킨 바로 그 래핑 명령이 효과 게이트 backstop 을 발화시킨다
- pypi 완전 미탐 주장도 기계 검증: `UNVERIFIED` 가 기록되고 rollback 은 생성되지 않는다
- 배터리는 수리 이전 트리에 대고 뮤테이션 검증(첫 정규화 assertion 에서 빨강)
- v2.12 의 오탐 코퍼스는 그대로 통과: 인용된 관용구, `npm run`, `npx`

## v3 (미래)

### Ledger 변조 내성

악성 패키지의 `postinstall`(사용자 권한 실행)이 "B 승인됨" ledger 엔트리를 위조해, 나중에 B 설치가 advisory 검사를 건너뛰게 하는 2차 공격을 방어한다. 패키지는 실행되기 *전*엔 이걸 못 하므로 install-시점 게이트를 닫는 게 1선 방어이고, 이건 이미 한 번 뚫린 뒤를 대비한 강화다.

접근 — **OSV 를 권위로, ledger 를 캐시로 강등** + 변조 탐지. 싸고 기존 인프라에 얹힘:

1. **enforcement / re-check 시점 재검증** — ledger 판정을 믿지 말고 저장된 evidence 를 OSV 로 재검증. evidence 없는(또는 OSV 가 취약이라 답하는) 위조 엔트리는 잡혀서 revoke. ledger 를 OSV SSoT 의 memoization 으로 강등. *(아직 미착수 — per-install 네트워크 비용 tradeoff.)*
2. **post-install 스캔에 `~/.safedeps/` 추가** — shipped: post-verify sensitive-path 스캔이 `~/.safedeps` / `SAFEDEPS_HOME` 을 건드리는 install script 를 flag 하므로, ledger 에 쓰는 패키지가 reorg 를 유발 — 위조를 현행범으로 (smoke: ledger-tamper fixture).
3. **daily re-check 의 provenance 대조** — shipped: `re-check` 가 `advisory.log` 기록이 없는 ledger 엔트리를 `suspected_forgery` 로 flag 하고(revoke 는 안 함), v2.9.2 부터 daily 알림 wrapper 가 이 flag 를 표면화한다.

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
