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

- npm 패키지 version 은 `package.json` 이 SSoT. `bin/safedeps` `SAFEDEPS_VERSION` 이 이를 따라가고, smoke 테스트는 `package.json` 을 읽어 대조한다 (현재 v2.18.0).
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

## v2.13 — pipe 위치 기반 hidden-install 판정 + guard 비용 복원 (출시 완료)

Status: v2.13.0 으로 출시.

pre-guard 의 hidden-install 탐지가 pipe-to-shell 을 raw 커맨드 텍스트 grep 으로 판정했다. 그 idiom 을 *인용만* 한 커맨드 — repro 라인을 적은 커밋 메시지 — 가 hidden install 로 거부됐고, 같은 날 두 워커가 이걸 밟았다. 수정은 무엇을 실행 pipe 로 볼 것인가를 바꾼다. 이 릴리스는 그 동작 변경을 기록하고, 수정이 들여온 guard 상수 회귀를 복원한다.

### 무엇이 바뀌었나

- **pipe 는 실행 자리에서만 인정한다.** pipe-to-shell 연산자는 자기 인용 레벨에서 따옴표 밖, heredoc 본문 밖에 있어야 한다. install 텍스트는 여전히 raw 로 찾는다 — 진짜 hidden install 에서는 구조상 producer 의 따옴표 안에 있기 때문이다. 외곽 인용이 내부 pipe 를 가리므로 같은 검사가 `sh -c` payload, `eval` payload, command substitution 에 재귀 적용된다.
- **소비자가 보게 될 판정 변화** (이 guard 는 다른 레포의 커밋을 막는 물건인데, 통과 기준이 바뀌고도 지금까지 버전 신호가 없었다):
  - *이제 허용:* `... install ... | sh` 를 텍스트로 인용한 커밋 메시지나 데이터 heredoc. 오탐 거부였다.
  - *이제 거부:* `sh -c "... | sh"` 와 `eval "... | sh"` 로 래핑된 piped install. 구 raw grep 은 shell 이름 뒤에 공백이나 줄끝을 요구해서, 닫는 따옴표가 붙은 형태(`| sh"`)가 탐지를 빠져나갔다. 진양성 탐지는 순증이다 — substitution·heredoc-redirect·plain-pipe 형태는 전에도 잡았고 지금도 잡는다.
- **검사 순서를 cheap-first 로 복원.** 수정은 quote-blank 실행 뷰(2차 문자 스캔)를 O(n) raw install-텍스트 grep 보다 먼저, 모든 커맨드에서 계산했다. 두 검사는 순수 술어라 논리곱 순서가 판정을 못 바꾼다 — 비용만 바꾼다. 이제 raw grep 이 먼저 돌고, install 텍스트가 아예 없는 대다수 커맨드는 스캔을 건너뛴다.

### 검증 / 실측 경계

- smoke 가 전체 케이스 집합을 덮는다: 인용 idiom 오탐 3건 allow, hidden install 6건(plain pipe, command substitution, `sh -c`, `eval`, heredoc redirect line) deny. 판정은 두 검사 순서 양방향으로 재생해 전 케이스 동일했다.
- 6KB 양성 커맨드의 guard 비용: 수정 전 1.5s, 수정 후 2.8s, 순서 스왑 후 1.4s. install 텍스트가 있으면 스캔이 돌아야 하고 6KB 기준 ~2.7s 를 유지한다.
- PreToolUse 훅 예산은 30s 다. 남아 있는 2차 스캐너(compound-command 분리, 이번에 안 건드림)가 커맨드 텍스트 약 29KB 근처에서 예산을 넘는다(28KB → 28s 실측). 이 경계는 이 릴리스 이전부터 있었고 — 수정 전엔 약 26KB — 선형화는 후속 작업으로 추적한다.
- **예산을 넘으면 fail-open 이다.** Claude Code 에서 실증(2026-08-04): 타임아웃을 넘긴 PreToolUse command 훅은 죽고 tool call 은 진행된다. 같은 훅이 예산 안에서 낸 deny 는 차단된다. 즉 크기 경계를 넘으면 이 guard 는 조용히 사라지고, 커맨드를 그 너머로 패딩하는 건 어렵지 않다. npm 은 PostToolUse effect gate 가 enforcement 권위로 남지만(자체 30s 예산), 나머지 ecosystem 은 command gate 가 primary 라서 — 스캐너 선형화를 편의가 아니라 보안 후속으로 추적하는 이유다. Codex CLI 의 타임아웃 동작은 미실측 — parity 를 가정하지 마라.
  - **v2.15.0 에서 양쪽 다 정정됐다.** fail-open 은 근원에서 닫혔다 — guard 가 런타임 예산이 만료되기 전에 자기 예산으로 답한다. 그리고 위의 npm 문장은 재본 적 없는 훅에 대한 가정이었다 — PostToolUse 도 자기 예산에서 죽는다(실측). 그래서 예산 너머에서는 npm 도 커버되지 않는다. v2.15.0 참조.

---

## v2.13.1 — 커맨드 게이트의 경계를 재고 문면화 (출시)

Status: v2.13.1 로 출시.

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
- v2.13 의 오탐 코퍼스는 그대로 통과: 인용된 관용구, `npm run`, `npx`

## v2.13.2 — 버전 없는 설치는 게이트를 안 거친다, 이제 그 사실이 기록된다 (출시)

Status: v2.13.2 로 출시.

v2.13.1 에서 carrier 경계를 재다가 발견했고, 그 릴리스가 닫은 것보다 크다. 원장 게이트는 파싱 가능한 `pkg@version` 피연산자에 대해서만 돈다. 버전을 빼면 spec 이 안 나오므로 게이트가 아예 안 돈다. `pip install evil`, `cargo add evil`, `go get example.com/evil`, `gem install evil`, `poetry add`, `uv add`, `bundle add`, `dotnet add package` 전부 통과다. 래핑도 필요 없다 — 공격자는 herestring 을 집을 필요 없이 버전만 안 적으면 된다.

안 보였던 이유가 둘이다. 코드가 밝힌 근거가 npm 모양이다 — 맨 `npm install` 은 새 패키지를 지목하지 않는 lockfile 설치라 통과가 npm 에서는 맞고, 효과 게이트가 어차피 결과를 잡는다. 그 논리가 커맨드 게이트가 권위인 생태계로 이식됐는데, 거기서 버전 없는 설치는 패키지를 지목하고 게이트 뒤에는 아무것도 없다. 그리고 방향이 뒤집혀 있다 — 숨김 경로는 spec 을 못 뽑으면 fail-closed 로 거부하는데 평문 경로는 똑같은 조건에서 허용한다. 한 파일 안에서 하나의 조건이 반대 방향으로 읽힌다.

### 무엇이 바뀌었나

- **게이트를 안 거친 설치가 기록을 남긴다.** 커맨드 게이트 뒤에 효과 게이트가 없는 생태계에서 버전 없이 패키지를 bare 피연산자로 지목한 설치는(피연산자 한정 범위가 남긴 구멍은 v2.14.1 에서 닫았다) `~/.safedeps/advisory.log` 에 생태계와 명령과 함께 `UNGATED` 를 남긴다. 지금까지는 흔적 없이 통과했고, 그건 "모든 우회는 관측 가능해야 한다" 는 불변식 위반이었다.
- **판정은 안 바꾼다.** 버전 없는 설치를 전부 거부하는 건 평범한 `cargo add x` 흐름을 막는 정책 변경이라 레포 소유자 결정으로 남긴다. 기록은 그 결정을 근거로 내릴 수 있게 하려고 있다.
- **침묵도 기록만큼 정밀하게 범위를 잡았다.** 파일 기반 설치(`-r`, `-c`, `-e`), 맨 lockfile 설치, npm, 그리고 **추출기가 읽는 형태로** 버전이 박힌 설치는 로그에 안 남는다. 마지막 단서가 중요하다 — 추출기는 `cargo add --vers` 는 읽지만 `cargo install --version` 은 못 읽어서, 버전이 있는데도 원장 게이트가 안 도는 경우가 있고 그때 기록이 찍히는 건 옳다. 평범한 설치마다 찍히는 기록은 배경 소음이고, 배경 소음은 없는 기록과 같다.

### 검증

- 68케이스 코퍼스를 `main` 과 대조: 판정 변화 0 — 기록은 verdict-neutral
- 양쪽 절반을 `scripts/test/consumer-forms.sh` 에 고정 — 버전 없는 지목 설치 10개 기록, 평범하거나 이미 게이트된 명령 12개 침묵
- 수리 없는 트리에 대고 뮤테이션 검증(첫 기록 assertion 에서 빨강)

---

## v2.14.0 — 훅 엔트리 셔틀: 깨진 체크아웃이 익명이기를 멈춘다 (출시)

Status: v2.14.0 로 출시.

설치된 훅은 스킬 심링크를 거쳐 레포 체크아웃을 라이브로 실행하므로, 체크아웃이 일시적으로 깨지면(머지 충돌 마커, 저장이 덜 된 편집, 파일 부재) 바로 다음 Bash 호출부터 훅 동작이 바뀐다. 2026-08-04 실제 머지 창에서 이 머신 모든 세션의 Bash 가 막혔고, 사람이 본 유일한 설명은 bash 파서 오류였다 — 무관한 세션 하나는 이 정전을 자기 쪽 인프라 결함으로 라우팅했다. 실패의 방향도 설계가 아니라 우연이었다: 파싱 오류는 하필 exit 2(양 엔진 차단)로 끝나지만, 파일 부재(127)와 런타임 크래시(1)는 비차단 훅 실패라서 설치 게이트를 조용히 없앤다.

### 무엇이 바뀌었나

- **등록되는 커맨드가 엔트리 셔틀** `scripts/safedeps-hook-entry.sh pre|post` 이 됐다. 건강한 훅은 그대로 통과한다(실측 오버헤드 ~7 ms, 베이스라인 ~34 ms). 훅이 비영 종료하면 셔틀이 깨짐을 분류하고(파싱 불가 / 크래시 / 부재), 체크아웃의 머지·리베이스 진행을 감지해 말하고, 폭("이 머신의 모든 세션")·원인·복구 경로를 담아 exit 2 로 끝난다.
- **훅 종료코드 계약이 명문화됐다**: 진짜 훅은 설계된 모든 경로에서 exit 0 이고 결정은 JSON 으로 나간다. 훅 스크립트의 의도적 비영 종료는 버그다(`AGENTS.md`).
- **셔틀 자신의 실패 모드는 가정이 아니라 실측이다**: 깨진 셔틀은 셔틀 이전의 status quo(원시 파싱 오류와 함께 차단)로 강등되며 더 넓어지지 않는다. 배터리로 고정.
- **워크플로 규칙**: main 체크아웃에서 머지 충돌을 풀지 않는다 — 워크트리에서 통합하고 `main` 은 fast-forward 로만 전진시킨다. 셔틀은 폭발을 줄이고, 규율은 창 자체를 없앤다.
- **`scripts/test/hook-entry.sh`** 가 계약 전체를 고정하고 `npm test` 에 합류했다. 인스톨러는 레거시 직접 경로 등록을 멱등하게 제거한다.

## v2.14.1 — 기록이 커버한다고 적힌 자리에 구멍이 있었다 (출시)

Status: v2.14.1 로 출시.

v2.13.2 의 기록이 note 3건과 함께 검증을 통과했다. 그중 둘이 문면이 아니라 동작이었고, 그 구분이 이 릴리스의 전부다. 문면으로 처리했으면 문장을 좁히고 구멍은 남았을 텐데, 그건 이 기록을 도입한 이유였던 불변식 위반이 코드에서 문서로 자리만 옮긴 것이다.

### 무엇이 바뀌었나

- **소스 플래그는 명령이 아니라 자기 인자를 소비한다.** `-r`·`-c`·`-e` 가 보이면 설치 전체를 침묵시켰다. 그런데 `-c` 는 애초에 소스 플래그가 아니다 — 제약 파일은 버전을 한정할 뿐 설치 대상은 명령줄에 따로 온다. 그래서 `pip install -c constraints.txt evil` 이 기록 없이 `evil` 을 설치했다. `-r requirements.txt evil` 과 `-e . evil` 도 같은 방식으로 침묵했다. 이제 각 플래그는 자기 인자 하나만 소비한다.
- **URL 의 `@` 는 버전이 아니다.** 이미 pin 된 토큰을 건너뛰려던 `@` 검사가 VCS URL 의 user 필드까지 잡아서, `git+ssh://git@host/evil.git` 은 기록되지 않고 `git+https://host/evil.git` 은 기록됐다 — 같은 설치가 전송 방식으로 갈렸다.
- **maven 은 좌표를 플래그에 싣는다.** `-Dartifact=<group>:<name>` 은 피연산자 순회에 아예 안 걸려서, maven 의 실제 관용구가 기록 밖에 있고 아무도 안 쓰는 형태(`mvn dependency:get evil`)가 안에 있었다. 이제 두 필드 좌표는 기록되고 세 필드는 침묵한다. maven 이 버전 없는 형태를 받는지는 확인 못 했다 — 측정 머신에 maven 이 없다 — 그리고 기록에서 미확인은 보고 쪽으로 푼다: 군더더기 한 줄의 비용은 한 줄이고, 빠진 한 줄의 비용은 불변식이다.
- **작업 트리 설치는 빠진다.** `pip install .` 과 `pip install ./pkg` 는 가져오는 게 아니라 트리에서 빌드하므로 패키지를 지목하지 않는다. `example.com/evil` 같은 모듈 경로는 로컬 경로가 아니라 계속 기록된다.
- **문서가 경계를 플래그로 설명하던 것을 그만뒀다.** 기준은 패키지를 지목하는지다. README 는 파일 기반 설치가 "패키지를 지목하지 않는다" 고 적었는데 `-c` 에는 처음부터 사실이 아니었다.
- **`SKILL.md` 도 이제 이 경계를 말한다.** 에이전트가 읽는 매니페스트인데 "설치 전에 check 를 돌려라" 라고만 하고 버전을 빼면 아무것도 검사되지 않는다는 사실을 말하지 않았다.

### 검증

- 106케이스 코퍼스를 v2.13.2 와 대조: 판정 변화 0 — 수리가 관측 층 안에 머문다
- 모든 경계를 `scripts/test/consumer-forms.sh` 에 양방향으로 고정. 커버리지가 아예 없던 maven·`git+ssh`·`-r <파일> <패키지>` 행 포함
- note 는 코드 재독이 아니라 기록의 가장자리를 적대적으로 탐침해서 나왔다

---

### v2.14.2 — 생태계별 플래그 표 (v2.14.1 의 패치)

v2.14.1 의 수리가 pip 의 플래그 표를 전 생태계에 적용했다. `-t` 와 `-f` 는 pip 에선 값을 받지만 go(`go get -t`)·gem(`--force`)·cargo 에선 불리언이라, 순회가 뒤따르는 패키지를 삼켰다. `go get -t example.com/evil` 은 침묵하고 `gem install --force evil` 은 기록됐다 — 같은 설치가 작성자가 고른 철자로 갈렸다. v2.14.1 이 `-c` 에서 진단한 바로 그 실수를 한 축 옆에서 반복한 것이다: 플래그를 의미가 아니라 형태로 묶었다. 작성자가 아니라 검증자가 잡았다.

값을 받는 플래그는 이제 생태계별로 갈라 판정하고, 모르는 플래그는 값을 안 받는다고 가정한다 — 그쪽으로 틀리면 군더더기 한 줄이지만 반대로 틀리면 이 기록이 잡으려던 설치를 놓친다. `-e` 는 이제 아무것도 소비하지 않는다. 그 인자를 다른 토큰과 똑같이 판정하므로 `-e .` 는 작업 트리 빌드로 빠지고 `-e git+ssh://…` 는 fetch 로 남는다. maven 좌표 플래그는 goal 양쪽 어디에 있든 읽는다.

경계 하나는 고치는 대신 의도로 고정했다: `mvn -Dartifact=… dependency:get` 은 install **인식**(`mvn dependency:get`)이 goal 앞의 플래그를 매치하지 않아 기록에 도달조차 못 한다. 그건 명령 인식의 몫이고, 그걸 넓히는 건 `ARCHITECTURE.md` 가 키우지 않기로 한 carrier 열거다.

v2.13.2 의 `git archive` 와 대조 검증: 판정은 불변이고, 그때 기록되던 registry-fetch 형태는 지금도 전부 기록된다. 기록에서 빠진 형태가 둘 있다 — `pip install .` 과 `pip install ./local-pkg` — 이건 v2.14.1 이 선언하고 배터리가 고정한 작업 트리 경계다(가져오는 게 아니라 트리에서 빌드한다). 이걸 "기록→침묵 0" 이라는 전역 주장으로 쓴 것이 이 플랜에서 두 번 반증돼서, 이제 주장 범위를 배터리가 실제로 검사하는 것에 맞춘다.

---

### v2.14.3 — 같은 클래스, 세 번째 (v2.14.2 의 패치)

v2.14.2 는 값 소비 플래그를 생태계별로 갈랐다고 발표했지만 실제로 게이트한 건 `-t` 와 `-f` 뿐이었다. `-r` 과 `-c` 는 무조건이었고, gem 의 `-r` 은 불리언 `--remote` 다 — 그래서 `gem install -r evil` 은 침묵하고 `gem install --remote evil` 은 기록됐다. 같은 설치가 철자로 갈리는 일이 이 플랜에서 세 번째이고, 이번엔 출하된 산문이 코드보다 뒤처진 게 아니라 앞서 있었다.

이제 표 전체를 pypi 계열로 게이트한다 — 이 철자들 중 어느 것이라도 인자를 소비하는 건 그 계열뿐이다.

검증 문장도 다시 쓰는 대신 범위를 바꿨다. "기록→침묵 0" 은 여기서 두 번 반증됐다. `pip install .` 과 `pip install ./local-pkg` 는 실제로 기록에서 빠졌고, 그건 v2.14.1 이 선언하고 배터리가 고정한 작업 트리 경계다. 이제 주장을 registry-fetch 형태로 좁혔다 — 그게 배터리가 실제로 검사하는 것이다. **작성자 자신의 코퍼스가 반증할 수 없는 전역 주장은 검증이 아니다.**

---

### v2.14.4 — 기록의 단형 함정 (v2.14.3 의 패치)

`--index-url` 은 pypi 값 소비 테이블에 있는데 단형 `-i` 가 빠져 있었다. 이건 설치를 숨긴 게 아니라 **없는 설치를 만들어냈다.** 미러 URL 이 피연산자로 읽혀서 `pip install -i <mirror> -r requirements.txt` 가 군더더기 기록을 남겼고 `pip install -i <mirror>` 도 그랬다. 이 플랜이 이미 고친 침묵 셋과 같은 결함이 반대 방향을 가리킨 것이고, 그래서 이제 배터리에 양방향이 다 들어간다. 한 방향만 고치면 반대쪽이 남는다.

같이 고친 것: "이미 버전이 박힌 설치는 안 남는다" 는 너무 셌다. 추출기는 `cargo add --vers` 는 읽지만 `cargo install --version` 은 못 읽어서, 버전이 있는데도 원장 게이트가 안 도는 경우가 있고 그때 기록이 찍히는 건 옳다. 이제 "추출기가 읽는 형태로 pin 된" 이라고 적고, 놀랍지만 참인 그 행을 배터리에 고정해 떠도는 줄로 안 읽히게 했다.

침묵 둘은 바꾸지 않고 고정만 했다: `pip install --index-url <url>` 단독은 패키지를 안 지목하고, `pip install /tmp/evil.whl` 은 파일시스템에서 설치한다. 둘 다 이미 맞았고 이제 조용히 어긋날 수 없다.

---

### v2.14.5 — 이상해 보이지만 참인 것을 고정하고, 못 세는 숫자를 그만 쓴다 (v2.14.4 의 패치)

verdict 밖에 있던 검증자 note 셋을 한 묶음으로 닫았다.

`bundle add evil --version 1.0.0` 은 cargo 형태와 **함께** 지목됐는데 cargo 행만 배터리에 실렸다. 둘 다 버전이 있는데도 기록된다 — 추출기가 `cargo add --vers` 는 읽지만 `cargo install --version` 도 `bundle add --version` 도 못 읽어서 원장 게이트가 실제로 안 돌기 때문이다. 이제 둘 다 고정한다. 이유도 같다: 참이지만 놀라운 기록이 떠도는 줄로 읽히면 안 된다.

`pip install --proxy <url> -r requirements.txt` 는 여전히 군더더기 기록을 남기고, 그걸 **고치지 않고 고정**했다. 모르는 플래그는 값을 안 받는다고 가정하는데, 반대로 가정하면 이 기록이 잡으려던 설치를 놓친다. 대신 값 테이블을 늘리는 건 이 작업이 네 번 데인 열거다. 이 행이 그 트레이드오프를 보이게 만든다 — 나중에 버그로 재발견되게 두지 않는다.

마지막 하나는 코드가 아니라 증거에 대한 것이다. 직전 릴리스가 스크래치 코퍼스에서 센 "159형태" 를 인용했는데 읽는 사람이 재구성할 수 없다. 실체 주장은 독립 재현으로 버텼지만 숫자는 장식이었고, **아무도 못 세는 숫자는 검증이 아니면서 검증처럼 읽힌다.** `AGENTS.md` 가 이제 재현 가능한 계수를 요구한다 — 배터리 형태 수, `npm test` 의 ok 줄 수, 아니면 커밋된 코퍼스.

---

## v2.15.0 — guard 가 자기 예산으로 답해서 런타임이 판정 중에 죽이지 못한다 (출시)

Status: v2.15.0 로 출시.

v2.13.0 이 30s 훅 예산을 넘기면 fail-open 이라는 사실을 기록하고, 그것을 스캐너 선형화의 근거로 남겼다. 거기서 멈춘 게 틀렸다. 선형화는 교차점을 밀 뿐 그 너머의 동작을 정하지 않고, 그 너머에서 게이트는 아무 말 없이 사라졌다. 커맨드를 ~30KB 로 패딩하는 게 공격의 전부였고, 커맨드 게이트가 advisory 가 아니라 권위인 `pip`·`cargo`·`go`·`gem` 에서는 스캐너를 전혀 몰라도 되는 보편 우회다.

런타임의 타임아웃 동작은 우리 소관이 아니다. 그게 발동하기 전에 답을 내는 것은 우리 소관이다.

### 무엇이 바뀌었나

- **guard 가 자기 예산을 갖는다** — 런타임 예산보다 작다(등록된 30s 대비 기본 20s). 판정을 자식에서 돌리고, 기한까지 답이 없으면 guard 가 대신 답한다: deny. 판정하지 못한 설치는 돌면 안 되기 때문이다. 런타임이 판정 중에 죽일 기회 자체가 없어지므로 fail-open 할 것이 남지 않는다.
- **그 deny 는 자기가 어떤 종류의 deny 인지 말한다.** "못 끝냈다" 와 "찾았다" 는 다른 주장이고, 구분 못 하는 독자는 게이트를 우회하는 법을 배운다. 사유는 `UNDECIDED, not unsafe` 로 시작해 아무것도 탐지되지 않았음을 밝히고 대신 무엇을 하면 되는지 말한다. 다른 모든 우회·불가용처럼 `advisory.log` 에 남는다.
- **engage 크기 아래 커맨드는 아무 비용도 안 낸다.** 커맨드가 예산 근처에 갈 만큼 커지기 전까지 이 기계장치는 정수 비교 하나다(기본 1KB, 30s 예산 대비 ~0.1s 실측 — 약 300배 여유). engage 크기는 성능 게이트지 보안 경계가 아니다. 보안 경계는 벽시계 예산이고, 이 숫자를 잰 머신보다 빠르든 느리든 정직하다.
- **마감은 자식의 프로세스 트리 전체에 집행되고 에스컬레이션한다.** 셸은 포그라운드 외부 명령이 도는 동안 시그널에 반응하지 않고, 판정의 비싼 부분이 정확히 그런 명령이다 — 그래서 자식 셸에만 시그널을 보내면 그 명령이 끝나는 시점에 닿는다(20s 예산에서 9.1s 지연 실측). 자체 예산이 만들려던 여유가 통째로 사라진다. 하위 프로세스는 이름 패턴이 아니라 자식 pid 에서 유도해 TERM 후 짧은 유예 뒤 KILL 한다. 버틸 수 있는 마감은 마감이 아니다.
- **첫 판본은 배터리가 못 보는 결함을 실었고, 어떻게 그랬는지가 기록할 값이다.** 시그널 받은 자식이 상태 락을 흘릴까 봐 `trap ... EXIT TERM INT` 를 "보험" 으로 넣었다. `trap` 에 시그널을 적으면 기본 처분이 대체되므로 자식이 마감에서 안 죽고 판정을 끝까지 했다 — 16KB 패딩 `pip install` 이 30s 런타임 예산에 대해 38.9s 에 답했다. 배터리의 예산 초과 케이스가 전부 1s 예산이라 마감이 스캔 초반(자식이 외부 명령 사이에 있어 시그널을 즉시 받는 구간)에 떨어졌고, 그래서 코퍼스가 초록으로 남았다. 지금 그 자리를 덮는 회귀는 마감이 스캔 깊숙이 떨어지도록 입력을 잡고(12KB / 11s 예산: 집행되면 ~12s, 아니면 ~17s) **초과분**을 단언한다 — 런타임이 실제로 신경 쓰는 양이 그것이다.
- **기한은 워치독 서브셸이 아니라 guard 자신이 폴링한다.** 워치독은 고정 간격으로 자야 하고, `sleep` 중인 워치독을 죽여도 그 sleep 이 끝나기 전에는 돌아오지 않는다 — 실측으로 그게 engage 된 모든 호출을 다음 정수 초로 올림했다(788ms 판정이 1050ms). 부모에서 폴링하면 50ms 에서 시작해 1s 까지 배로 늘어나므로 빠른 판정은 첫 스텝만 잃는다.

### 검증 / 실측 경계

- 개발 머신 비용 곡선: 1KB → 0.1s, 4KB → 0.68s, 8KB → 2.5s, 16KB → 9.6s, 24KB → 21.4s, 28KB → 29.3s, 32KB → 37.8s. 30s 런타임 예산은 28KB 와 32KB 사이에서 교차하며, v2.13.0 이 기록한 경계를 반대편에서 재현한다.
- 예산이 engage 된 상태에서 32KB 커맨드는 20s 예산 대비 ~20.2s 에 거부된다: 런타임 시계에 ~9.8s 를 남기고 답이 나온다. 초과분은 폴링 한 스텝(≤1s) 으로 묶인다.
- engage 지점의 기계장치 오버헤드, 같은 입력 양방향: 4KB 684ms → 820ms, 8KB 2482ms → 2623ms. engage 크기 아래에서는 자식도 없고 측정 가능한 변화도 없다.
- `scripts/test/self-budget.sh` 가 양방향을 고정하고 `npm test` 에 합류했다: 예산 초과 커맨드와 패딩된 `pip`/`cargo`/`go`/`gem` 설치는 거부되고, 그 거부는 undecided 로 표시되며 적발처럼 쓰이지 않고 `advisory.log` 에 남는다. 양성 커맨드·`npm run`·미승인 설치·engage 됐지만 예산 내인 커맨드는 종전과 똑같이 판정된다.
- 배터리는 자체 mutation 검사를 갖는다: 예산을 끄면 동일한 예산 초과 커맨드가 그대로 통과한다. 초안은 그 입력을 예산의 ~1.3배로 잡아 거짓 통과를 냈고, 그래서 커밋본은 ~5배 마진을 쓴다.

### npm 이 받쳐준다는 가정은 실측을 못 견뎠다

v2.13.0 은 커맨드 게이트의 예산을 넘어서도 npm 은 PostToolUse 효과게이트가 "여전히 집행 권위" 라고 적었다. 그건 아무도 재본 적 없는 훅에 대한 가정이었다. PreToolUse 에 썼던 같은 프로토콜로 2026-08-04 실측했다 — 샌드박스 프로젝트, 시작과 완료를 각각 기록하는 훅, 예산 내 통제군과 예산 초과 실험군:

- 통제군(5s 예산에 1s 작업): 시작하고 완료했다.
- 실험군(5s 예산에 20s 작업): 시작했고 완료하지 못했다.

**PostToolUse 도 자기 예산에서 죽는다.** 효과게이트는 같은 30s 로 등록돼 있고, 그 작업(`npm ci`, `npm install`, `npm rebuild`, closure 전체 OSV 배치)은 safedeps 가 통제하는 것이 아니라 사용자 프로젝트와 네트워크에 매인다. 그래서 npm 도 같은 노출을 갖고, 그 종류는 커맨드 게이트보다 나쁘다: pre 훅의 죽음은 판정 못 한 커맨드 하나를 통과시키지만, post 훅의 죽음은 롤백 도중에 떨어질 수 있다.

이번 릴리스는 그걸 고치지 않는다. 설치 후 게이트는 deny 할 수 없으므로("커맨드가 이미 돌았다") "못 끝냈다" 에 대한 답이 별개의 설계 문제이고, `safedeps/effect-gate-killed-mid-rollback` 으로 추적한다. 여기서 고친 것은 주장이다 — 문서가 더는 예산 너머에서 npm 이 커버된다고 말하지 않는다. 실제로 아니기 때문이다.

---

### v2.15.1 — 자체 예산에 상한이 생겼다. 사용자가 옮길 수 있는 경계는 경계가 아니라 기본값이니까 (v2.15.0 패치)

v2.15.0 의 주장 전체가 "가드가 런타임 예산 너머로 사라지는 대신 자기 예산 안에 답한다" 였다. 환경변수 하나가 그걸 무효화했다 — `SAFEDEPS_SELF_BUDGET_SECONDS` 에 상한이 없었고, 등록된 30s 훅 타임아웃 위의 값은 kill 권한을 런타임에 되돌려준다. 조용히, 그리고 릴리스 이전과 똑같은 fail-open 으로.

그런 값을 넣을 동기가 아주 평범하다는 점이 이걸 닫을 이유다. 큰 커맨드에서 `UNDECIDED` 거부를 만난 사람은 "예산이 짧네" 로 읽고 올린다. 무언가를 끄려는 의도는 전혀 없고, 그래도 경계는 사라진다.

- **값은 25s 로 클램프된다.** 클램프는 한 방향이다 — 더 낮은 값은 준 그대로 존중된다. 짧은 예산은 더 일찍 거부할 뿐이기 때문이다. `SAFEDEPS_RUNTIME_BUDGET_SECONDS`(30) 와 `SAFEDEPS_SELF_BUDGET_MAX_SECONDS`(25) 는 그들이 묶는 예산 바로 옆의 이름 있는 상수다.
- **30s 는 하드코딩이고, 그 이유를 상수 옆에 적었다.** 훅 페이로드는 런타임 예산을 싣지 않고 여러 settings 파일의 등록이 모두 발화하므로, 가드는 자기를 띄운 등록을 알 수 없다. 대신 safedeps 자신이 등록하는 숫자(인스톨러의 `PRE_HOOK_TIMEOUT_SECONDS`)를 명시하고, smoke 테스트가 두 상수를 함께 고정해 인스톨러만 바뀌고 가드가 낡은 숫자로 계산하는 상태를 막는다. 손으로 30s 아래로 고친 등록은 이 상수가 알 수 있는 범위 밖이다.
- **5s 여유는 반올림한 숫자가 아니라 가드가 예산 창 바깥에서 쓰는 비용이다.** 마지막 폴 스텝 대기 최대 1s, KILL 전 TERM 유예 최대 0.5s, reap·`jq`·프로세스 시작 약 0.1s. 구조적 최악 1.6s 이고, 실측 종단 초과분은 0.73~1.05s 로 커맨드 4KB 에서 256KB 까지 평평했다(2026-08-04, 30s kill 을 잰 것과 같은 머신).
- **클램프는 관측된다.** stderr 로 알리고, `advisory.log` 에 기록하고, `UNDECIDED` deny 사유에 명시한다. 조용히 깎으면 사용자는 자기가 준 값이 도는 줄 알고, 다음 이상 현상을 한 번도 참이었던 적 없는 숫자를 놓고 디버깅한다.

- **클램프 첫 판이 같은 구멍을 다른 문법으로 그대로 갖고 있었고, 크로스 검증이 릴리스 전에 잡았다.** `^[0-9]+$` 로 검증하고 마감은 원본 문자열을 `$(( ))` 에 넘겼는데, bash 산술이 그 정규식보다 넓은 문법을 받는다. 그래서 `+40`·` 40`·`0x28` 은 검증을 통과 못 해 클램프를 건너뛴 뒤 그대로 40 으로 평가됐다 — `+40` 에서 64KB 커맨드가 41s 동안 답을 내지 않았다. 런타임 kill 너머다. 한 값에 문법이 둘인 게 결함이고, 이제 값은 한 번 정규화되며(앞뒤 공백과 선행 `+` 는 친 사람 의도대로 읽는다) 산술에는 정규화된 숫자만 들어간다. 그 밖의 값은 예산이 아니라서 기본값을 쓰고, 클램프와 같은 채널로 알린다. `10#` 이 `08` 을 8진수 오류가 아니라 8 로 읽게 한다.

- **크로스 검증 2라운드가 같은 형태를 한 층 아래, 문법이 아니라 값의 범위에서 찾았다.** 문법을 하나로 만들어도 `^[0-9]+$` 는 자릿수를 세지 않고, bash 정수는 64비트라 조용히 감긴다. 음수로 감긴 값은 상한보다 크지 않아 클램프를 그대로 통과했고, 마감 곱셈이 한 번 더 감아 영영 오지 않는 시각을 만들었다 — 30자리 예산이 600s 를 넘겨도 답을 내지 않았다. 이제 자릿수를 산술 이전에 문자열 영역에서 검사한다. 아홉 자리를 넘으면 상한 위인 게 분명하므로 그대로 클램프한다 — "상한 위는 클램프한다" 는 규칙에 표기법에 따른 예외를 두지 않는다. 아홉 자리는 초로 약 31년이다.

검증: `scripts/test/self-budget.sh` 에 600s 예산 + 64KB 패딩된 `pip install` 케이스가 추가됐다. 이 입력의 자연 스캔은 개발 머신에서 300s 를 넘으므로 답을 런타임 30s 안으로 되돌릴 수 있는 것은 상한뿐이다 — 약 26s 에 `UNDECIDED` 로 거부되고 클램프가 세 곳 모두에 나타난다. 같은 64KB 케이스를 `" 40"` 으로 한 번 더 돌려 문법 수정을 종단으로 고정했고(41s 였던 것이 25~26s), `+40`·`0x28`·`abc`·`-5`·`4.5`·`08` 은 값싼 파싱 케이스로 건다. 오버플로 라운드로 64KB + 30자리 예산(자릿수 게이트 전 600s+, 후 26s), 64비트 경계값, 그리고 길이로 판정되면 안 되는 0 패딩 짧은 값을 추가했다. 상한 아래 값은 손대지 않고 알리지도 않는다. `scripts/test/smoke.sh` 는 가드의 런타임 예산 상수를 인스톨러가 등록하는 타임아웃에 고정하고, 상한이 그 아래인지 검사한다.

---

### v2.15.2 — engage 크기는 마감을 튜닝할 뿐, 더는 끄지 못한다 (v2.15.1 패치)

v2.15.1 이 예산에 상한을 씌웠다. 그런데 예산이 **돌지 말지를 정하는 조건**은 그대로 남았다: `SAFEDEPS_BUDGET_ENGAGE_BYTES`. 문제되는 커맨드보다 크게 올리면 판정이 마감 없이 인라인으로 돌아간다 — 예산이 안 움직이게 되면 사람이 다음으로 잡는 손잡이로 같은 fail-open 이 돌아온다. 실측: 32KB 패딩된 `pip install` 이 기본 engage 에서 21s, 올린 상태에서 198s. 런타임은 어느 쪽이든 30s 에 죽인다.

문이 열려 있다는 증거는 배터리 자신이었다 — mutation check 가 engage 크기를 올려 게이트를 껐고, 그건 사용자가 마찰을 줄일 때 하는 동작과 같다.

- **engage 크기를 4KB 로 클램프한다.** v2.15.0 비용 곡선에서 4KB 바로 아래 커맨드는 약 0.68s 에 판정되므로 런타임 예산의 약 44배 안쪽이다. 기본값 1KB 와 상한 사이의 튜닝은 본래 용도이고 그대로 남는다.
- **마감을 끄는 것은 이름이 다른 별개의 행위다.** `SAFEDEPS_BUDGET_DISABLED` 는 다른 일을 하지 않고, 발동할 때마다 stderr 와 `advisory.log` 에 자기를 알린다. 통과만 알고 결함을 잡는지는 모르는 테스트는 증거가 아니므로 off 스위치는 존재한다 — 다만 튜닝 레버와 같은 것이 아닐 뿐이다.
- **두 노브가 이제 하나의 리더를 쓴다.** v2.15.0·v2.15.1 에서 같은 방식으로 깨졌고, 손으로 짠 두 번째 파서는 다시 갈라지는 경로다. 공백·선행 `+`·선행 0·비숫자·산술이 담지 못하는 길이를 둘 다 똑같이 처리하고, 모든 낙하와 클램프를 알린다.
- **노브 리더가 너무 긴 입력을 파싱 전에 거절한다.** 이 리더는 자식 스폰 이전, 자기가 지키는 마감 바깥에서 돌고, 두 번 느린 길이었다. v2.15.1 의 0 제거 루프가 O(n²)였고(선행 0 4만 개 28.9s, 6만 개 63.2s), 그걸 대체한 정규식은 상수를 약 100배 줄였을 뿐 복잡도 클래스를 그대로 뒀다 — 입력이 두 배면 시간이 네 배였고(50k 0.34s, 400k 20.2s, 800k 88.0s) 0 50만 개는 여전히 종단 224s 였다. 1차 수리는 실패 지점을 한 자릿수 오른쪽으로 민 것뿐이다. 실제로 한계를 씌우는 건 **입력 길이 상한**이고, 어떤 패턴이 문자열에 닿기 전에 한 번의 값싼 통과로 판정된다 — 아홉 자리가 이미 초로 약 31년이라 도달 가능한 값 중 32자를 넘는 것은 없다. 거절된 값은 통째로 인용하지 않고 길이로 보고하므로, 패딩 1MB 가 stderr 1MB 가 되지 않는다.

검증: `scripts/test/self-budget.sh`(30 ok)가 engage 클램프(패딩된 설치가 여전히 예산으로 거부되어야 함), 두 채널 알림, 상한 내 조용한 튜닝, 비숫자 engage 의 기본값 낙하, mutation check 로서의 disable 경로, 그리고 0 50만 개 예산이 런타임 예산 안에 답하고 그 값이 통째로 인용되지 않고 길이로 보고되는 것을 고정한다.

여전히 열려 있고 고치지 않고 기록만 한 것: 값 하나로 **튜닝이 아니라 정본을 갈아치우는** 노브가 여럿이다 — `SAFEDEPS_OSV_API_URL`·`SAFEDEPS_KEV_CATALOG_URL`·`SAFEDEPS_GHSA_API_URL` 은 자문 출처를 옮기고, `SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON`·`SAFEDEPS_YARN_INFO_FIXTURE_NDJSON` 은 closure 해석을 통조림 데이터로 대체하며, `SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS` 는 승인을 영구화할 수 있고, `SAFEDEPS_ADVISORY_LOG` 는 모든 우회가 관측돼야 하는 그 채널 자체를 옮긴다. 테스트 seam 이자 미러 지원이고, 적어도 URL 쪽은 마찰 서사가 실재한다(osv.dev 를 막는 망). `safedeps/truth-source-knobs-have-no-declaration` 로 추적한다.

이번 릴리스가 닫은 것과 같은 형태의 노브가 하나 더 있고, 위 열거는 1차에서 그걸 놓쳤다: **`SAFEDEPS_BUDGET_CHILD`**. 부모가 스폰한 자식에게 세팅하는 재귀 마커라, 이걸 export 하면 부모가 자기를 자식으로 알고 마감을 통째로 건너뛴다 — 실측으로 12KB 패딩된 `pip install` 이 평소 3s, export 상태에서 32s 였고 stderr 에도 `advisory.log` 에도 아무것도 안 남는다. 상한이 없고, 이름이 off 스위치라고 말하지 않으며, engage 크기와 달리 우연히 도달할 마찰 서사도 없다. 크로스 검증이 이번에 넣은 클램프에서 90줄 안쪽에서 찾아냈다 — 방금 자기가 만든 변경 너머를 사람이 얼마나 못 보는지의 정직한 척도다. `safedeps/budget-child-marker-is-an-unnamed-off-switch` 로 추적한다.

---

### v2.15.3 — 부모/자식 마커가 환경 밖으로 나간다 (v2.15.2 패치)

v2.15.2 는 이 구멍을 암시가 아니라 이름으로 릴리스 노트에 싣고 나갔다: 부모가 스폰한 자식에게 세팅하는 마커 `SAFEDEPS_BUDGET_CHILD` 가 환경변수였다. export 하면 부모가 자기를 이미 자식으로 알고 마감을 통째로 건너뛴다 — 실측으로 12KB 패딩된 `pip install` 이 평소 3s, 마커 export 상태에서 32s 였고 런타임 kill 30s 너머인데 stderr 에도 `advisory.log` 에도 아무것도 안 남았다. 이름 붙은 스위치 옆의 두 번째 off 스위치, 상한도 이름도 기록도 없이.

크로스 검증이 v2.15.2 가 넣은 클램프에서 90줄 거리에서 찾아냈다 — 방금 자기가 만든 변경 너머를 사람이 얼마나 못 보는지의 정직한 척도다.

- **마커가 argv 로 다닌다.** 엔진은 인자를 넘기지 않는 `safedeps-hook-entry.sh` 를 통해 훅을 부르므로 환경에서 이 플래그로 가는 경로가 없다 — 세팅할 수 있는 유일한 프로세스는 자식을 스폰하는 그 프로세스다. 검사가 아니라 구조다.
- **옛 변수는 무시하되 침묵하지 않는다.** 마감을 끄던 신호가 아무 말 없이 무력해지면 반대 방향으로 실패한다 — export 한 사람은 마감이 꺼져 있다고 계속 믿는다. stderr 와 `advisory.log` 에 알리고, 의도적으로 끄려면 `SAFEDEPS_BUDGET_DISABLED` 를 쓰라고 가리킨다.
- **마감 기계장치는 그대로다.** 트리 kill 은 자식 자신의 pid 에서 하위를 유도하고 reap 은 그 pid 를 기다린다. 둘 다 마커를 읽지 않는다. 가정이 아니라 확인했다 — "구조적으로 닫힌다" 도 다른 주장과 같은 주장이기 때문이다.

검증: 실제 훅 경로(엔트리 shim)에 마커를 export 한 상태로 12KB 패딩된 `pip install` 이 2s 예산에서 3s 에 `UNDECIDED` 거부된다. 마감이 스캔 깊숙이 떨어지는 경우도 11s 예산을 1s 초과로 종전과 같고, 고아 프로세스를 남기지 않는다. `scripts/test/self-budget.sh`(32 ok)가 export 된 마커에도 마감이 살아있는 것과 두 채널 알림을 고정한다.

이게 랜딩하면서 v2.15.2 릴리스의 "Known gap" 항목은 닫힌다: 이 마감의 off 스위치는 하나이고, 이름이 있고, 기록된다.

---

### v2.15.4 — 수동 설치 문서가 설치기와 같은 것을 등록한다 (v2.15.3 패치)

`SKILL.md`·`README.md`·`README.ko.md` 는 수동 설치하는 독자에게 훅 커맨드로 `safedeps-pre-guard.sh` 와 `safedeps-post-verify.sh` 를 등록하라고 말했다. 설치기가 등록하는 것은 `safedeps-hook-entry.sh pre|post` 이고 `AGENTS.md` 도 셔틀이 등록 커맨드라고 못 박아 뒀다 — 셔틀이 생긴 이래로 문서는 도구가 실제로 하는 것과 다른 설치를 서술해 왔다. `README.md` 는 그 블록 200줄 위에서 셔틀을 설명하기까지 한다.

문서대로 해도 설치는 막히니까 깨져 보이지 않았다. 빠지는 건 셔틀의 존재 이유 전체다 — 체크아웃이 깨진 상태(머지 중, 저장이 덜 됨, 훅 크래시)를 조용히 꺼진 게이트가 아니라 설명이 붙은 fail-closed 거부로 바꾸는 것. 독자는 자기가 그 보호 없이 돌고 있다는 걸 알 방법이 없었다.

- **수동 JSON 이 셔틀을 등록한다.** 설치기가 쓰는 것과 같은 30s 타임아웃까지 포함하고, 왜 등록 커맨드가 훅이 아니라 셔틀인지 한 줄로 말한다.
- **`SKILL.md` 는 더 이상 frontmatter 에 훅을 선언하지 않는다.** 어느 런타임도 그 블록을 등록으로 읽지 않으므로, 그건 아무도 참으로 유지하지 않는 두 번째 설치 서술이었다 — 드리프트가 난 경로가 그것이다. 등록 채널은 설치기 하나다.
- **대조를 기계가 한다.** `scripts/test/smoke.sh` 가 설치기의 엔트리 훅 상수를 직접 읽고, 두 README 중 하나라도 `pre`·`post` 로 그 이름을 대지 않거나 훅 스크립트를 직접 등록하면, 또는 `SKILL.md` 가 자기 선언을 다시 키우면 빨강을 낸다.

문서에 적힌 커맨드를 엔진이 부르듯 실제로 실행해 검증했다 — `README.md` 의 그 문자열이 페이로드를 받아 미승인 `pip` 설치를 거부한다. 드리프트 검사는 옛 커맨드를 되돌려 빨강이 나는지로 mutation 검증했다.

---

### v2.15.5 — 드리프트 검사가 문자열이 아니라 값을 핀한다 (v2.15.4 패치)

v2.15.4 의 드리프트 검사는 인스톨러의 엔트리 훅 상수를 읽고 문서가 그 이름을 안 대면 실패했다. timeout 은 안 읽었다. 그래서 문서는 맞는 커맨드를, 인스톨러가 더는 쓰지 않는 숫자와 함께 계속 댈 수 있었다 — 그 릴리스가 닫은 결함이 한 필드 옆에 그대로 있었던 것이고, 발견 경로도 그거다. 릴리스 노트가 그걸 덮은 척하지 않고 알려진 한계로 이름 박아 뒀다.

- **timeout 을 커맨드처럼 핀한다.** 이벤트별로, 파일 아무 데서나가 아니라 커맨드 바로 옆 줄에서 읽는다. 가드가 이미 자기 상한 때문에 `PRE_HOOK_TIMEOUT_SECONDS` 를 읽고 있으므로, 이건 진실이 사는 자리를 늘리는 게 아니라 같은 상수를 세 번째로 읽는 일이다.
- **`SKILL.md` 는 훅 선언을 두지 않고, 그게 결정으로 기록됐다.** Claude 는 skill frontmatter hooks 를 실제로 문서화하고 그 스키마는 event-keyed + `matcher` + `command:` 다 — 다만 **스킬 라이프사이클 스코프라 스킬이 활성일 때만 돈다.** 이 게이트는 스킬 호출 여부와 무관하게 모든 Bash 호출을 판정해야 하므로 그 형태로는 못 싣는다. 그래서 드리프트 검사는 어느 스키마도 읽지 않는 legacy `script:` 형태에서만 실패하고, 문서화된 형태는 일부러 막지 않는다 — 동작하는 기능을 grep 으로 막는 것은 죽은 것을 치우는 것과 다르다. 판정은 `AGENTS.md` 가 들고 있다.

mutation 세 방향으로 검증했다: 인스톨러 상수만 옮기면 기존 가드 핀이 빨강, 문서 timeout 만 옮기면 새 검사가 빨강, 그리고 인스톨러 상수와 가드 상수를 **같이** 옮기면(정당한 예산 변경이 취하는 형태) 문서만 남겨지고 새 검사가 잡는다 — 옛 검사가 놓치던 경우가 그거다.

---

### v2.15.6 — 산문이 훅 예산을 한 번만 말하고, 그 한 번이 핀돼 있다 (v2.15.5 패치)

v2.15.5 는 등록 JSON 블록 둘 안의 timeout 을 핀했다. 그런데 그 숫자는 아무 검사도 읽지 않는 여섯 문장에서 계속 살고 있었다 — `SKILL.md`, README 둘, ARCHITECTURE 둘, `AGENTS.md`. 상수를 옮기면 문서는 인스톨러가 더는 쓰지 않는 숫자를 말하는 채로 남는다. 같은 드리프트가 또 한 칸 옆에 있었고, v2.15.5 노트가 그걸 덮은 척하지 않고 알려진 한계로 적어 뒀기 때문에 여기서 닫는다.

- **언어당 한 문장이 숫자를 말한다.** 그 숫자가 어디서 오는지 이미 설명하는 ARCHITECTURE 문단이고, smoke 가 그 문장을 `PRE_HOOK_TIMEOUT_SECONDS` 에 핀한다. 나머지 산문은 숫자를 쓰지 않고 예산을 가리킨다.
- **날짜가 붙은 측정 기록은 숫자를 유지한다.** "등록된 타임아웃에서 죽는다(측정 시점 30s, 2026-08-04)" 는 그 날의 사실이라 상수가 바뀌어도 틀리지 않는다. 다만 현재 설정으로 읽히지 않도록 썼다.
- **규칙은 표현 목록이 아니라 근접성이다.** 인스톨러의 그 숫자를 예산 단어 옆에 놓은 문장은 canonical 이거나 날짜 붙은 측정이어야 한다. 재진술의 표현 형태를 열거하는 건 이 레포가 두 번 데인 형태이고, 실제로 닫는 것은 재진술에서 숫자를 빼는 쪽이다.

한계를 그대로 적는다 — 한계를 모르는 검사는 커버리지로 오독되기 때문이다. 이걸 실제로 닫는 건 canonical 핀이고, 그건 산문이 어떻게 생겼든 동작한다. 근접성 규칙은 백스톱이고 새는 백스톱이다 — 문서 목록이 하드코딩이고, 숫자를 한 표기(`<N>s`)로만, 그것도 줄 중간에서만 잡으며, 줄 단위이고, 측정 예외가 날짜가 아니라 단어를 본다. 구조 축 둘(같은 이벤트에 두 번째 JSON 블록, `pre`/`post` 뒤바뀜)은 둘 다 바깥이고 문서 JSON 을 파싱해 인스톨러 출력과 대조해야 닫힌다. 전부 검사 옆에 적었다 — 이걸 믿을지 판단하는 사람이 보는 자리가 거기다.

격리 클론에서 mutation 검증했다: 인스톨러 상수 둘·가드 상수·JSON 블록 둘을 45 로 옮기고 canonical 문장만 30 으로 두면 빨강, `SKILL.md` 에 숫자를 되살리면 근접성 규칙이 빨강.

---

### v2.15.7 — 기록을 검사 밑에서 빼낼 수 없다 (v2.15.6 패치)

세 릴리스가 마감을 끌 수 있는 노브를 닫았다. 그 뒤의 전수 열거는 다른 계열을 목록으로만 남겨 뒀다 — 튜닝이 아니라 **정본을 갈아치우는** 노브들. 그중 최악이 `SAFEDEPS_ADVISORY_LOG` 다. `advisory.log` 는 모든 우회가 적히는 자리일 뿐 아니라, `re-check` 가 "이 승인이 실제로 있었나" 를 묻는 oracle 이기 때문이다.

실측: `suspected_forgery` 로 잡히던 위조 ledger 항목이, `SAFEDEPS_ADVISORY_LOG` 를 "그 승인은 있었다" 고 적힌 호출자 작성 파일로 돌리자 잡히지 않는다. 위조를 쓰는 그 환경이 검사에게 증거를 건넨다. 그리고 레포·문서·테스트·설치기 어디에서도 그 변수를 설정한 적이 없다 — 위조 검사가 의존하는 그 파일 하나를 열어두고만 있던 미사용 노브였다.

- **경로를 `SAFEDEPS_HOME` 에서 유도한다.** 기록과 ledger 가 같이 움직이거나 아예 안 움직이고, 그게 검사와 검사 대상을 한 신뢰 도메인에 두는 조건이다. 설정됐지만 무시된 변수는 stderr 와 canonical 로그에 보고된다 — 무언가를 하던 신호가 조용히 무력해지면 안 된다.
- **채널이 이제 구조적으로 하나다.** 훅은 늘 `$SAFEDEPS_HOME/advisory.log` 에 썼고 CLI 와 providers 는 변수를 존중했으므로, 도구의 어느 쪽이 말하느냐에 따라 관측 채널이 둘로 갈릴 수 있었다.
- **옮겨진 자문 출처는 금지가 아니라 고지 대상이다.** provider URL, closure fixture, 기본값 아닌 ledger TTL 은 실재하는 필요다 — osv.dev 를 막는 망의 미러, 이 스위트 자신이 쓰는 fixture. 각 이탈은 실행당 한 번 이름과 함께 `advisory.log` 에 적히고, 첫 provider 호출이 아니라 시작 시점에 적히므로 provider 에 닿지 않는 명령도 기록된다. 허용되지 않는 것은 옮겨진 정본으로 판정한 실행이 OSV 로 판정한 실행과 똑같이 보이는 쪽이다.

검증: e2e 위조 배터리에 relocation 케이스와 moved-source 기록 케이스가 추가됐고, 격리 클론에서 환경 override 를 되돌리는 mutation 으로 위조 케이스가 빨강이 되는 것을 확인했다.

---

### v2.15.8 — 고지가 훅 경로에도 있다 (v2.15.7 패치)

v2.15.7 은 옮겨진 자문 출처로 판정한 실행이 스스로 고지한다고 적었다. CLI 에서는 참이었다. PreToolUse 가드는 provider 스택을 sourcing 하지 않으므로 **말할 자리가 없었다** — 옮겨진 출처 아래서 돈 가드 실행이 아무것도 안 남겼다. 무해했던 이유는 가드가 아직 provider 도 fixture 도 안 탄다는 것뿐이고, 그건 코드가 바뀌는 날 사라지는 이유다. 주장이 이미 참인 자리에만 있는 채널은 채널이 아니다.

- **고지를 `lib/truth-sources.sh` 로 옮겼고** 가드가 자기 위치에서 순수 확장으로 경로를 구해 **무조건** sourcing 한다 — 환경변수도 없고, 모든 Bash 호출마다 도는 경로에 서브셸도 없다. 조건부로 만들려면 노브 목록을 읽을지 정하려고 호출부에서 노브 목록을 다시 적어야 하고, 사본이 둘이면 첫 번째가 낡는다. 크로스 검증이 1차 시도를 기각했는데 그 이유가 바로 앞 릴리스의 존재 이유였다 — 경로가 환경변수에서 왔고 읽을 수 없는 파일이 조용히 반환돼서, `/dev/null` 로 돌리면 옮겨진 출처 아래 실행이 아무것도 안 남겼다. 이름 없는 off 스위치를, 그것을 금지한 불변식 옆에서 다시 만든 것이다. 이제 읽을 수 없는 라이브러리는 두 채널로 고지되는 불가용이다. 그 파일을 편집하기 전에 알아야 할 결과가 하나 있다 — 모든 Bash 호출마다 sourcing 되므로 거기 파스 오류가 나면 가드가 죽고 엔트리 셔틀이 그걸 머신 전역 fail-closed 거부로 바꾼다. 침묵보다 막히는 쪽이 이 레포의 스탠스이지만, 70줄짜리 파일이 시사하는 것보다 넓은 blast radius 다.
- **기본값과 비교가 그 한 파일에 있다.** 중복이었다 — 실행이 대조되는 URL 과 대입받는 URL 이 따로 적혀 있었고, 그건 한 릴리스가 통째로 한 칸 옆에서 고쳤던 그 형태다.
- **노브 둘을 더 이름 붙였다.** `SAFEDEPS_NPM_OVERRIDES_JSON` 은 closure 판정이 접어 넣는 overrides 를 대체하고(e2e 자신의 단언 이름이 그렇게 말한다), `SAFEDEPS_RECHECK_FIXTURE_JSON` 은 일일 alert 이 읽는 re-check 출력을 대체한다. 둘 다 v2.15.7 열거 밖이었고, 그래서 그 목록을 완전한 것이 아니라 늘어나는 것으로 다시 적었다.

검증: 옮겨진 출처 아래 가드 실행이 그것을 기록하고 overrides 노브를 이름으로 댄다. 미이동 대조군은 스위트 자신의 fixture 를 해제해서 만들었으므로, 고지가 항상 뜨는 게 아니라 환경을 따라간다는 것을 단언한다.

---

### v2.16.0 — 효과 게이트가 평범한 프로젝트에서 완주하고, 끝나지 않은 롤백은 크게 말한다

v2.15.0 은 PostToolUse 도 PreToolUse 처럼 자기 예산에서 죽는다는 것을 재고 거기서 멈췄다. 노출은 **구조적**이라고만 기록됐는데, 효과 게이트가 실제로 어디서 30초를 넘는지 아무도 안 쟀기 때문이다. `scripts/measure/effect-gate-cost.sh` 로 커밋된 하니스로 이제 쟀고, 정직한 답은 "구조적" 보다 나빴다.

게이트는 두 축을 탄다. 하나는 프로젝트의 lockfile closure 다. 다른 하나는 누구의 설계도 아니었다 — 게이트가 closure 패키지마다 원장에 따로 물었고, 그 질문 하나하나가 승인 스펙 디렉터리 전체를 훑으면서 원장 파일당 `jq` 프로세스를 둘셋씩 띄웠다. O(closure × ledger) 다.

- 실제 738개 원장: closure 1 → 10.8초, 2 → 18.5초, **4 → 36.6초**
- 빈 원장, 1081개짜리 애플리케이션 lockfile: 256 → 24.0초, **512 → 72.0초, 1024 → 100.7초**

closure 4개는 거의 모든 실제 `npm install` 이다. 그래서 이 측정을 한 머신 기준으로 npm 의 "지연 탐지" 는 사실상 무탐지였고, 아무것도 승인 안 된 새 머신조차 평범한 애플리케이션 하나면 선을 넘었다.

- **원장은 closure 당 한 번 읽는다, 패키지당 한 번이 아니라.** 술어는 옮겨가지 않았다 — 단일파일 검증기와 새 인덱스가 **같은** jq 소스를 임베드하므로 "이 스펙을 원장이 승인하나" 의 구현은 빠른 사본과 느린 사본 둘이 아니라 여전히 하나다. 같은 하니스, 같은 원장, 같은 lockfile: closure 4개가 36.6초 → 2.1초, 원장 단계는 closure 4에서 512까지 ~0.23초로 평평하다. 랜딩 전에 이전 per-file 리더와 등가성을 대조했다 — 실제 원장에서 뽑은 60개 스펙(owner, transitive, absent), 60개 전부 동일 판정. 다만 그 코퍼스가 표현할 수 없는 의도된 변경이 하나 있으니 따로 적는다 — 자기 ecosystem 이 없는 transitive 항목이 예전엔 **질의된** ecosystem 을 상속했고 이제 **소유 항목의** ecosystem 을 상속한다. 더 엄격한 쪽이다. 크로스 검증이 그 코퍼스가 아니라 원장 스키마에서 생성해 갈라지는 두 경우를 찾아냈다. 둘 다 fail-closed 방향이고, 실제 원장에는 그런 항목이 없다.
- **손상된 원장 항목 하나가 인덱스를 비울 수 없다.** jq 는 파싱 못 하는 첫 파일에서 멈추므로, 인덱스는 파일을 청크로 넘기고 실패한 청크는 한 파일씩 재시도하며 무엇이 깨졌는지 이름을 댄다. 비워진 인덱스는 "아무것도 승인 안 됨" 으로 읽히고 그건 깨끗한 설치의 롤백이다 — 원장 파일 하나의 오타가 그 값을 치르면 안 된다.
- **남은 것은 주장이 아니라 범위로 적는다.** OSV/KEV 패스는 여전히 패키지당이다. 같은 머신에서 provider 캐시가 비어 있을 때 게이트는 이제 **390개** closure 근처에서 30초를 넘는다. 그 아래에서 npm 의 지연 탐지는 실재하고, 그 위에서는 런타임이 게이트를 죽이고 설치는 판정되지 않는다. 그 숫자는 호스트·네트워크·캐시의 속성이다 — 하니스를 커밋해 뒀으니 다음 독자는 이 숫자를 물려받지 말고 자기 것을 재라.

### 끊긴 롤백은 예전엔 아무것도 안 남겼다

게이트는 거부할 수 없다. PostToolUse 시점에는 설치가 이미 돌았다. 나쁜 closure 에 대한 게이트의 답은 롤백이고, 그 롤백은 `reorg.log` 기록과 메시지를 **맨 마지막** — `node_modules` 재빌드라는 가장 느린 단계 뒤 — 에 썼다.

두 실제 훅을 샌드박스에서 몰고 post 훅을 통제된 지점에서 죽이는 `scripts/measure/rollback-kill-state.sh` 로 측정했다:

- 롤백 전에 죽임: 플래그된 설치가 그대로 남고 `reorg.log` **0줄**
- 롤백 도중에 죽임: 프로젝트는 완전히 되돌아갔고 `reorg.log` **0줄**, 메시지 없음

둘째가 더 나쁘다. 첫째는 게이트가 안 돈 것처럼 보이지만, 둘째는 사용자의 설치가 아무 이유도 없이 스스로 취소된 것처럼 보인다. 사람이 게이트를 불신하고 우회하는 법을 배우는 경로가 그것이다.

- **의도를 행동 전에 적는다.** 프로젝트·스냅샷·사유·단계를 적은 저널 항목을 첫 파괴적 단계 **앞**에 쓰고, 롤백이 스스로를 보고한 뒤에 지운다. 자기 실행보다 오래 사는 항목이 **곧** 그 보고다.
- **다음 Bash 호출이 그것을 보고한다 — 한 번.** PostToolUse 는 설치뿐 아니라 모든 Bash 호출에 뜨므로 보고가 빨리 도착한다. 항목을 `~/.safedeps/rollback-incidents/` 로 옮기고, 완주한 롤백이 쓰는 그 `reorg.log` 에 `REORG INTERRUPTED` 를 덧붙이고, 어느 단계까지 갔고 무엇이 트리를 고치는지 말한다. 이후 모든 명령에서 잔소리하는 대신 한 번 보고하고 영구 보관한다.
- **이것은 원자성이 아니고 그렇게 주장하지도 않는다.** safedeps 는 npm 트리 재빌드의 원자성을 소유하지 않는다. 소유하는 것은 끝나지 않은 롤백이 조용한가다.
- **메시지 채널은 하나다.** 엔진은 이 훅의 stdout 을 단일 JSON 객체로 파싱하므로, 훅의 모든 메시지가 이제 한 emitter 로 나간다. 두 번째 객체는 추가 메시지가 아니라 잃어버린 메시지다.

### 검증

- `npm test` 초록. e2e 배터리에 양방향을 고정했다 — 끊긴 롤백은 보고되고, 로그에 남고, 인시던트로 보관되고, 반복되지 않는다. 완주한 롤백은 저널 항목을 안 남기므로 깨끗한 실행이 끊겼다고 울지 않는다.
- 원장 인덱스 판정을 owner·transitive·만료·폐기·부재 스펙에 걸쳐 고정했고, 인덱스를 비우면 안 되는 판독 불가 항목도 함께 고정했다.
- 측정 하니스 둘 다 서술이 아니라 커밋이다. 아무도 재현할 수 없는 숫자는 장식이기 때문이다.

### 알려진 갭

엔진이 훅만 죽이는지 프로세스 그룹째 죽이는지는 **안 쟀다**. 훅 프로세스만 죽였을 때는 그것이 띄운 `npm ci` 가 살아남아 트리를 완성했다. 런타임이 프로세스 그룹을 죽인다면 트리는 찢어진 채 남는다. 재려면 라이브 머신에 의도적으로 느린 훅을 등록해야 하는데, 이 레포는 그것 때문에 이미 한 번 Bash 가 머신 전역으로 막힌 적이 있어서 의도적으로 안 쟀다. 저널은 그 답에 의존하지 않는다 — 어느 쪽이든 기록은 첫 파괴적 행위 앞에서 쓰인다.

---

### v2.16.1 — 진행 중인 롤백은 실패한 롤백이 아니다 (v2.16.0 패치)

v2.16.0 은 첫 파괴적 행위 앞에 저널을 써서 끊긴 롤백을 크게 만들었다. 그 릴리스의 크로스 검증이 반대편을 찾았다 — 롤백이 도는 동안 그 항목은 **설계상** 디스크에 있고 훅은 모든 Bash 호출마다 저널을 읽으므로, 그 창에 들어온 무관한 명령이 잘 돌아간 롤백을 중단됐다고 보고했다. `scripts/measure/rollback-concurrent-report.sh` 로 재현했다 — 같은 로그에 `REORG INTERRUPTED` 와 `REORG executed` 가 같이 찍히고, incident 파일과 곧 멀쩡해질 트리를 고치라는 안내까지 남았다.

- **보고는 파일 존재가 아니라 생존으로 가른다.** '항목이 디스크에 있다' 와 '롤백이 안 끝났다' 가 같은 검사였다. 이제 다른 질문이고, 저널은 처음부터 소유자 pid 를 적어 왔다. 상태 락은 이 질문에 답할 수 없고 읽기를 락 안으로 옮기는 것도 아무것도 못 고친다 — 훅은 롤백이 시작되기 전에 락을 놓으므로 롤백은 락 없이 돌고 두 번째 훅은 같은 살아있는 항목을 읽게 된다.
- **판정 기본값은 보고하는 쪽이다.** 틀리는 두 방향이 대칭이 아니다. 죽은 롤백을 살아있다고 하면 진짜 보고가 사라지는데 그게 저널이 막으려던 침묵이고, 살아있는 롤백을 죽었다고 하면 소음이다. 그래서 '아직 돈다' 는 적극적 증거가 있을 때만 답하고, 소유자를 확인할 수 없으면 없는 것으로 친다. pid 재사용은 프로세스 시작 시각 하나로 갈린다 — 소유자는 항목을 쓰기 전에 이미 돌고 있었고, pid 는 이전 주인이 죽은 뒤에야 재사용된다.
- **레저 배치가 '못 돌았다' 와 '미승인 0건' 을 가른다.** jq 부재, closure 파일 부재·파싱 불가, 인덱스 생성 실패가 전부 행을 하나도 안 내놨고, 호출부에게 행 없음은 '전부 승인' 이다. 이전 per-package 형태는 같은 조건에서 fail-closed 였다. 상태가 과적재였던 게 원인이다(1 이 판정이자 에러였다). 이제 0 미승인 없음, 1 미승인 있음, 2 못 돌았음이고 이는 이 도구의 audit exit-code 계약과 같다. 호출부는 1 초과를 fail-closed 로 받는다.

검증: e2e 배터리에 양방향을 고정했다 — 도는 롤백은 침묵하고, 죽은 소유자와 재사용된 pid 는 둘 다 보고되며, 배치는 미승인·부재·파싱불가에 각각 1/2/2 를 낸다. 두 수리 다 옛 동작을 되살리는 뮤테이션으로 검산했고 새 검사가 빨개진다.

이번 패스에서 나온 발견 둘은 가정이 아니라 실제였다. 기존 '끊긴 롤백' 픽스처는 서브셸 안에서 항목을 만들었는데 거기서 `$$` 는 부모의 pid 다 — 살아있는 테스트 프로세스가 소유한 롤백을 서술하고 있었고, 아무도 그 필드를 안 읽는 동안만 통과했다. 그리고 배치 호출부의 1차 버전은 평범한 미승인 경로에서 훅을 죽였다. `set -e` 가 켜져 있고 그 상태가 1 이기 때문이다. 기존 reorg 테스트가 빨개지는 대신 조용해지는 형태로 그걸 잡았다 — 훅이 말하기 전에 죽었으니까.

---

### v2.16.2 — 좀비 소유자는 도는 소유자가 아니다 (v2.16.1 패치)

v2.16.1 은 미완 롤백 보고를 저널 항목을 쓴 프로세스의 생존으로 갈랐다. 크로스 검증이 수확되지 않은 소유자를 이론적 구멍으로 지적했지만 주장하지는 않았다 — bash 가 자기 자식을 즉시 수확해서 시연할 좀비를 못 만들었기 때문이다. `wait` 하지 않는 부모를 쓰면 바로 재현된다.

좀비는 이 판정의 모든 검사를 통과한다. 프로세스 테이블 항목을 유지하므로 `kill -0` 이 성공하고, 자기 시작 시각을 유지하므로 pid 재사용 비교도 통과한다. 실측: `stat = Z`, `kill -0` 통과, `lstart` 조회됨, 판정은 "아직 돈다".

침묵 방향이고, 한 번의 누락보다 나쁘다. 도달 경로가 바로 저널이 존재하는 이유 그 자체다 — 런타임이 롤백 도중 훅을 죽이고, 부모가 아직 수확하지 않았고, 항목의 pid 가 지금 좀비다. 좀비는 저절로 사라지지 않으므로 이후 모든 명령이 같은 답을 낸다. 보고가 미뤄지는 게 아니라 영영 사라진다.

- **프로세스 상태 `Z` 는 없는 것으로 친다.** 이미 보고 쪽을 기본값으로 두는 판정에 적극적 증거 검사를 하나 더한 것이다.

검증: e2e 배터리에 네 번째 방향이 붙었다 — 도는 소유자, 죽은 소유자, 재사용된 pid 에 이어 좀비 소유자도 보고된다. 테스트는 bash 가 아닌 부모로 자기 좀비를 직접 만들고, 플랫폼이 좀비를 못 만들면 좀비가 아닌 프로세스로 통과하는 대신 크게 실패한다. 상태 검사를 제거하는 뮤테이션으로 검산했고 빨개진다.

---

### v2.17.0 — 아무도 안 읽는 필드, 둘 중 어느 쪽도 아닌 상태, 그리고 초록을 내고 있던 검사

v2.16.x 라운드가 남긴 것 셋과 그 라운드가 만든 것 하나.

**아무도 안 읽는 필드는 아무도 검증하지 않는다.** 저널 필드들의 판독 사이트를 세니 판독자가 0인 것이 정확히 하나 나왔다 — `stage_at`. 그걸 찾아낸 규칙은 `pid` 에서 왔다. `pid` 는 한 릴리스 동안 적히기만 하고 안 읽혔고, 무언가가 마침내 그걸 읽는 순간 결함 두 개를 한꺼번에 내놨다(살아있는 소유자를 서술하던 픽스처, 그리고 좀비). incident 기록에 남아서 사람 눈에 보인다는 건 검증이 아니다 — `pid` 는 내내 보였다.

- **`stage_at` 은 지우지 않고 판독자를 붙였다.** 실재하는 질문에 답하기 때문이다. 이제 보고문이 마지막 단계에 언제 들어갔는지, 그게 롤백 시작 후 얼마 시점이었는지를 말한다. 다만 **그 단계에 얼마나 붙잡혀 있었는지는 일부러 주장하지 않는다** — 프로세스가 언제 죽었는지는 아무 데도 기록되지 않고, 보고는 몇 명령 뒤에 도착할 수 있어서 지금까지의 간격은 대부분 유휴 시간이다. 알 수 있는 부분만으로도 "파일 복원이 아직 돌던 중" 과 "재설치가 한참 돌던 중" 이 갈리고, 둘은 다른 복구다.

**정지한 소유자는 죽은 것도 도는 것도 아니다.** 이분법에 접으면 양쪽 다 틀린다. 없는 것으로 치면 `SIGCONT` 로 재개될 롤백이 미완으로 보고된다 — v2.16.1 이 닫은 오보다. 살아있는 것으로 치면 영원히 멈춘 롤백이 영원히 보고 안 된다 — v2.16.2 가 닫은 침묵이다. 비대칭 원칙도 여기엔 안 닿는다. "확인할 수 없는 소유자는 없는 것으로 친다" 는 확인 불가에 대한 규칙이고, 정지는 확인된 상태이면서 둘 중 어느 쪽도 아니다.

- **그래서 제3의 답을 준다.** 설치 전 가드가 "판정 못 했다" 를 안전/위험에 접지 않고 자기 답으로 만든 것과 같은 축이다. 사람이 먼저 할 일이 다르므로 보고문도 다르다 — 재개하거나 죽인 다음에 복구한다.
- **좀비 판정을 필드 앞에 고정하지 않는다.** `ps` 는 그 칸을 플랫폼마다 다르게 채우고, `Z` 는 상태 문자로만 나오므로 느슨한 매칭이 충돌할 수 없다.

**일관성 감사의 개념 존재 검사가 문서가 갈라지는 동안 초록을 내고 있었다.** `grep -lq` 는 파일 목록에서 첫 매치에 종료하므로, 문서 하나만 개념을 갖고 있어도 전체가 통과한다. 잡을 수 있는 건 "전부 동시에 잃었다" 뿐이고, 실제로 일어나는 문서 간 드리프트는 못 잡는다. v2.16.1 의 산문 드리프트를 검증자가 손으로 잡아야 했던 이유가 이것이다.

- **이제 파일별로 세고 어느 파일인지 말한다.** 불변식을 소유하는 `AGENTS.md` 도 대상에 넣었다. `SKILL.md` 에서 개념을 지우면 옛 형태는 초록인 채로 남고 새 형태는 그 파일을 지목한다.
- **천장을 숫자와 함께 검사 옆에 적었다.** 실제 드리프트 기준으로 어휘 검사는 3건 중 2건을 놓치고 1건을 잘못 잡는다 — ARCHITECTURE 둘은 드리프트 상태인데 무관한 절에서 온 `pid` 를 이미 갖고 있었고, 고쳐진 README 는 그 전문 용어 없이 새 명제를 말한다(사용자향 산문이라 일부러 그렇게 썼다). 그걸 빨갛게 만드는 검사는 바로 윗 절의 clean prose 규약과 서로를 밀어낸다. 명제 일치는 기계로 안 되며 재검이 맡는 것으로 기록했다 — 빈칸이 아니라 설계 결정이다.

검증: 새 동작 전부 뮤테이션으로 검산했다. 정지를 없음으로 접으면 정지 케이스가 빨개지고, `stage_at` 판독을 빼면 `stage_at` 케이스가 빨개진다. 두 번째 회귀가 존재하는 이유는 이 변경의 1차 버전에 그게 없었고 뮤테이션이 통과했기 때문이다 — 판독자를 붙이면서 검사를 안 붙이는 건 이 변경이 고치려는 결함을 그대로 반복하는 것이다.

---

### v2.17.1 — 검증 절차 자체가 공유 상태를 갖고 있었다 (v2.17.0 패치)

설치에 대한 safedeps 의 동작은 아무것도 안 바뀐다. 그것을 검사하는 기계 쪽이 바뀌었고, 거기에 이 도구가 찾으라고 만들어진 바로 그 종류의 격리 결함이 셋 있었다.

- **샌드박스 이름을 `mktemp` 가 짓는다.** 테스트 샌드박스 키가 다섯 군데에서 `$$-$RANDOM` 이었는데 `$$` 는 한 실행 안에서 상수라 격리가 `RANDOM` 하나에 걸려 있었다. `mkdir -p` 는 이미 있으면 성공하므로 충돌은 드문 게 아니라 **감지 불가**였다. 근거는 충돌 확률이 아니라 그 감지 불가라서, 호출 횟수가 바뀌어도 다시 따질 필요가 없다. 개수가 중요하다 — 크로스 검증은 두 곳을 지목했고, 1차 스윕에서 네 곳이 나왔고, 다섯 번째는 다른 스위트에 있었다.
- **정지-소유자 테스트가 더는 정지 프로세스를 흘리지 않는다.** 이 테스트는 프로세스를 정지시켰다 되살리는데, 그 사이에서 실행이 죽으면 영구 정지 고아가 남았다 — 실측 4개, 최고 65분 생존, 전부 cwd 가 플랜 워크트리라 finalize 가 제거 처방을 못 받았다. (검증이 잡아준 정정 — 그 상황에서 `git worktree remove` 자체는 exit 0 으로 지운다. 거부하는 기계는 git 이 아니라 kuma 의 live-cwd close gate 다.) 정지 상태를 판정하는 코드를 만들면서 정지 프로세스를 흘린 것이다. 이제 세 층이다: 평범한 종료용 EXIT trap, SIGKILL 용 마커 한정 스윕(SIGKILL 은 trap 을 무력화하고, 그건 이 레포의 가정이 아니라 기본 시나리오다), 그리고 자식을 워크트리 밖에서 띄워 살아남은 고아가 아무도 지우려는 디렉터리를 안 잡게 하는 것.
- **간헐적 `consumer-forms` 실패를 쫓는 하네스를 커밋했다.** 52회 중 3회, 서로 다른 단언 셋, 전부 같은 방향 — 조용해야 할 명령이 `UNGATED` 를 봤다. 그게 참이 되는 길은 샌드박스 오염이거나 판정 비결정이고, 둘은 정반대 수리를 요구한다. 기록이 명령을 적으니 보존된 한 줄이면 갈리는데, 스위트의 trap 이 샌드박스를 지워서 지금까지 모든 실패가 맹목 재실행이었다. 하네스는 그걸 보존하고, 조용한 케이스를 시끄럽게 바꿔 스위트가 먼저 빨개지는지 요구하는 `--self-test` 를 들고 있다.

원인은 여전히 미상이고 `mktemp` 변경이 그걸 없앴는지도 모른다. 이후 20회가 깨끗했지만 그건 약한 근거가 아니라 사실상 무근거다 — 관측 비율 52회 중 3회에서 **아무것도 안 고쳐도 20회 연속 0건이 30% 확률로 나온다.** p<0.05 로 개선을 주장하려면 51회가 필요하다. 이 변경의 근거는 원래 확률이 아니라 '충돌을 감지할 수단이 없다' 였으므로 저 숫자의 도움이 필요 없다.

`AGENTS.md` 에 검증 위생 절이 붙었다 — 뮤테이션은 플랜 워크트리가 아니라 사본에서 돌린다(검증자와 작성자가 같은 트리에 동시 쓰기를 하고, `git checkout --` 복원은 작성자의 미커밋 변경을 조용히 날린다), 그리고 0건을 인용하는 규칙 셋. 셋 다 먼저 틀린 방식으로 측정됐다 — 대조군 없는 하네스의 0건, 조건을 재지 않고 추정한 시행, 그리고 두 사람 사이를 오가며 단단해졌지만 출발점에는 측정이 없던 라벨. 그 뒤에 있는 실패 형태는 하나다: **정교화는 검증처럼 느껴진다.**

### v2.17.2 — 되돌릴 파일이 없는 롤백에서 post 훅이 죽지 않는다 (v2.17.1 패치)

*v2.18.0 에서 기록했다. v2.17.2 는 기록 없이 나갔다.*

- **`post-verify` 가 빈 배열에서 죽었다.** 게이트가 롤백할 이유는 있는데 되돌릴 파일이 없으면 빈 `ROLLED_BACK` 배열을 펼쳤고, bash 3.2 는 `set -u` 에서 이를 unbound 로 본다. 훅이 보고하는 대신 죽었고, 머신의 모든 세션에서 그랬다. 같은 파일이 다른 곳에서 이미 쓰던 방식으로 그 펼침을 막았다.
- **v2.16.0 부터 v2.17.1 까지의 변경도 이때 함께 나갔다.** 그 버전들은 태그도, 릴리즈도, npm 게시도 없었고 npm 은 2.15.8 에 머물러 있었다. `AGENTS.md` 의 배포 절차는 이 일 때문에 생겼다.

---

## v2.18.0 — 커맨드 게이트가 설치를 어떻게 쓰든 읽는다 (shipped)

바깥에서 온 보고 둘(GitHub #21·#22, @Seung-zedd)과 8월부터 멈춰 있던 플랜 하나 때문에, 커맨드 게이트를 패키지 매니저가 문서화한 표기와 셸이 허용하는 표기에 대고 쟀다. 대부분이 판정도 기록도 없이 통과했다. pip·cargo·go·gem·maven·nuget 에서는 커맨드 게이트가 유일한 관문이라 하나하나가 완전한 우회였다. npm 에서는 `--ignore-scripts` 재작성이 빠지는 비용이었다. 나중에 효과 게이트가 거부할 패키지가 이미 설치 스크립트를 돌린 뒤였다.

### 게이트가 알아보지 못하던 설치

v2.17.2 에 대고 쟀을 때, 승인되지 않은 버전을 박은 다음 형태가 모두 통과했다.

- **문서화된 별칭**: `pnpm i|upgrade|it`, `npm in|ins|inst|insta|instal|isnt|isntall|it|u|udpate|ic|cit|sit`, `yarn up`, `bun a`.
- **하위 명령과 옵션**: `yarn global add`, `yarn workspace <ws> add`, 동사 앞에 옵션이 둘 이상인 형태(`pip --quiet install`, `npm --silent --loglevel error install`, `cargo --locked install`, `gem --norc install`).
- **버전이 붙은 인터프리터**: `pip3.11 install`, `python3.11 -m pip install`, `py -3.11 -m pip install`.
- **실행기**: `npx <pkg>@<ver>`(6월부터 패턴이 한 글자 이름만 받았다), `npm exec|x`, `pnpx`, `bunx`, `bun x`, `uvx`, `uv tool install|run`, `pipx install|run`, `go run <모듈>@<버전>`, `dotnet tool install`, `cargo +<툴체인>`. 실행기마다 옵션을 그 실행기의 help 에서 가져오므로, 옵션 값을 패키지로 읽지 않는다. 값이 명령 치환이든, 공백 든 따옴표 경로든, 빈 값이든 통째로 읽는다(`uvx --python $(which python3) x==1`, `uvx --python "" x==1`). `bunx --help` 에는 없는 bun 의 `--cwd` 도 값을 받는 옵션으로 읽는다.
- **문장 위치**: `( ... )`, `{ ...; }`, `if ...; then ...`, `for ...; do ...`, `!`, `time`, `coproc`, `exec`, `env -i`, 그리고 이 키워드들 뒤의 `env`·`command`·변수 할당.
- **따옴표 안이나 플래그로 넘긴 spec**: `pip install "requests==2.0.0"`, 공백 든 요구사항(`pip install "requests == 2.0.0"`, pip 는 이것을 핀으로 읽는다), extras(`evil[x]==1.0.0`), `===`, `cargo install x --version 1`, `bundle add x --version 1`, `dotnet add <프로젝트> package X --version 1`, maven `-Dartifact=g:a:v`.
- **npm 자신의 줄임**: npm 은 명령이나 별칭의 고유한 줄임과 대시 붙은 명령의 camelCase 형태를 모두 받는다. 그래서 문서의 별칭 표는 처음부터 불완전했다: `npm upd x@1`, `npm install-te`, `npm installTest`, `npm si`. 이제 문법은 npm 파서(`lib/utils/cmd-list.js`)가 받는 집합을 담고, `scripts/measure/npm-verb-spellings.sh` 가 PATH 의 npm 으로 그 집합을 다시 만들어 문법에 없는 표기가 있으면 실패한다.
- **initializer**: `npm create|init <pkg>` 와 `pnpm|yarn|bun create` 는 매니저가 스스로 이름 붙인 패키지(대개 `create-<pkg>`)를 실행한다. 이제 이들은 실행기이고, 검사는 매니저마다 소스대로 실제로 실행되는 패키지를 가리킨다. 전에는 `pnpm create evil@1.0.0` 이 `evil` 승인만으로 통과했다. `npm init`·`npm init -y` 는 조용하다.
- **`npm link <pkg>`** 는 패키지를 전역으로 설치하므로 이제 전역 설치로 판정한다. 경로 인자는 로컬 디렉터리를 잇는 것이라 조용하다.
- **spec 에 붙은 리다이렉트**: `pip install requests==2.19.0>/dev/null` 은 `>/dev/null` 까지 버전으로 읽혔다. 이제 리다이렉트를 셸이 토큰을 나누는 방식대로 떼어 낸다.

동사 목록은 손으로 관리하는 사본이 일곱 벌이었고 서로 어긋나 있었다. 이제 `lib/install-grammar.sh` 가 문법을 한 번 정의하고, 두 훅의 모든 인식기가 그것을 읽는다. ARCHITECTURE.md 의 규칙은 그대로다. 매니저 자신의 표기와 셸의 문장 문법은 안에 있고, 인자를 그대로 실행하는 래퍼(`sudo`, `timeout`, `nohup`, `nice`, `xargs`)는 밖에 있으며, `scripts/test/consumer-forms.sh` 가 이들을 판정하지 않는 형태로 고정한다. `case` 갈래는 아래 렉서 전까지 이 목록에 있었고, 지금은 판정한다. `mvn -Dartifact=... dependency:get` 은 목표 앞의 옵션을 carrier 열거로 보는 해석 때문에 밖으로 고정돼 있었다. 옵션은 carrier 가 아니므로 이제 인식한다.

### 엉뚱한 신원으로 받은 승인

거부 메시지는 실행할 `safedeps check` 를 알려 주고, 에이전트는 그것을 스스로 실행한다. 세 가지 읽기가 엉뚱한 패키지를 가리켰다. 그래서 처방이 어떤 권고에도 나오지 않는 이름을 승인했고, 재시도가 통과했다.

- **Go 모듈 경로가 마지막 조각만 남았다.** `go get example.com/x@v1` 이 `check go x@v1` 을 처방했고, 그게 승인되면 `.../x@v1` 이면 무엇이든 통과했다.
- **모듈 아래 Go import 경로를 쓴 그대로 검사했다.** OSV 는 Go 권고를 모듈 경로로 저장하므로, `go install golang.org/x/text/cmd/gotext@v0.3.7` 은 깨끗하다고 나왔지만 `golang.org/x/text` v0.3.7 은 취약하다. 이제 check 가 경로의 모든 접두사를 OSV 에 묻고 답을 합친다.
- **모든 spec 이 명령에서 처음 나온 생태계로 검사됐다.** `npm run build && pip install evil==1` 은 `evil` 을 npm 패키지로 검사했다. 이제 각 spec 은 자신이 나온 문장의 생태계를 가진다.

### 따옴표와 백슬래시

스캐너는 따옴표 안을 공백으로 지우므로, 따옴표를 잘못 읽으면 그 뒤가 모든 판정 함수에게서 한꺼번에 사라진다. 네 가지 읽기가 그렇게 했다. `"a\\"` 를 이스케이프된 따옴표로 읽었고, 따옴표 밖 `\"` 를 여는 따옴표로 읽었고, 줄 이음(`pip \<줄바꿈>install ...`)을 두 줄로 판정했고, 여러 줄 따옴표 문자열을 줄마다 따로 스캔해 닫는 따옴표가 새 구역을 열었다. 마지막 것은 반대 방향으로도 작동해서, 둘째 줄에 설치 문구가 있는 커밋 메시지를 그 설치로 읽었다. 이제 백슬래시와 따옴표를 셸과 같은 규칙으로 읽고, 별칭 우회 관용구 `\pip install` 도 평범한 설치로 읽는다.

### 셸로 넘기는 파이프, 설치 옆에서 그리고 그 뒤에서

파이프 carrier 의 구멍 둘. 둘 다 v2.17.2 에 대고 쟀고, 커맨드 게이트가 권위인 생태계에서는 완전한 우회였다.

- **보이는 설치가 파이프 검사를 껐다.** 숨은 설치 검사는 게이트가 읽을 수 있는 설치가 명령에 하나도 없을 때만 돌았다. 그래서 `requests` 를 승인한 뒤 `pip install requests==2.0.0 && printf 'pip install evil==6.6.6' | sh` 는 `requests` 를 검사하고 `evil` 은 조회도 기록도 없이 실행했다. `npm ci && printf 'cargo install evil@6.6.6' | sh` 도 같았다. 이제 보이는 설치가 있어도 검사가 돈다. 게이트가 읽은 설치마다 매니저 단어를 지우고 남은 텍스트에 파이프 질문을 하므로, 보이는 설치가 숨은 설치로 세지지 않는다. 파이프로 넘긴 설치는 옆에 아무것도 없을 때와 똑같이 fail-closed 로 거부된다. 보이는 설치 옆에서 다른 설치 없이 스크립트를 셸로 넘기는 명령은 판정이 그대로다.
- **소비자 뒤에 공백이 있어야 했다.** `printf 'pip install evil' | sh; echo done` 이 판정 없이 통과했고, `| sh&&…`, `| sh|cat`, `(… | sh)`, `{ … | sh; }`, `| (sh)`, `| { sh; }`, `|& sh` 도 그랬다. 이제 소비자를 셸의 연산자와 그룹을 거쳐 읽는다. 따옴표로 감싼 셸 이름(`| "sh"`)은 경계 밖에 두고 그 자리에 고정했다.

### 이스케이프된 연산자와 문장 시작

이스케이프된 연산자는 셸에게 문자인데, 스캐너는 그것을 문법으로 넘겼다. 그래서 `echo true \; pip install evil | sh` 가 숨은 파이프 설치가 아니라 보이는 무버전 설치로 읽혀 기록 후 통과했고, `echo a \; pip install evil==6.6.6` 은 셸이 실행하지도 않는 설치로 거부됐다. 문법도 `!` 와 `{` 를 어디서나 문장 시작으로 쳐서 `echo ! pip install evil | sh` 가 같은 오독이었다. 이제 이스케이프된 연산자는 평범한 문자로 스캔되고, `!` 와 `{` 는 문장이 시작하는 자리에서만 문장을 연다.

### 실패한 스캐너는 빈 스캐너가 아니다

모든 판정 함수는 `set -e` 가 꺼진 조건이나 명령 치환 안에서 스캔을 읽는다. 그래서 실패한 `awk` 는 빈 텍스트를 돌려주었고, 빈 텍스트는 "설치 아님" 으로 읽혔다. 첫 수리는 실패를 기록하고 허용 출구 두 곳에서 두 번째 인식기로 다시 판정했다. 리뷰가 세 번 거부했고, 설계 판정이 이유를 쟀다. 두 번째 인식기는 `grep`·`sed`·join `awk` 를 거쳐서 대신 서야 할 도구와 함께 조용해졌다. raw 정규식은 스캔을 거친 인식기가 찾는 것을 다 찾을 수 없다. inert 재작성은 마지막 정산 뒤에서 명령을 읽었다. 읽기마다 하나씩 실패를 주입하자 통합 트리에서 3,530회 중 43회가 약해졌다.

이제 설계는 관문 하나다. 명령을 실행시키는 모든 경로는 마지막 읽기 뒤, 첫 부수효과(pending 상태, inert meta, allow) 앞에서 이 관문을 한 번 지난다. 읽기가 하나라도 실패했다면, 패키지 매니저 실행파일 이름이 대소문자 무관하게 어디든 있는 명령은 `UNDECIDED` 로 거부하고, 나머지는 실패를 stderr 와 `advisory.log` 에 남긴 채 실행한다. 판별은 문법의 실행파일 목록(`SAFEDEPS_G_EXECUTABLES`)에 대한 bash 자체 정규식이고 서브프로세스가 없다. 읽기가 실패한 뒤 적발을 보고할 deny 는 대신 `UNDECIDED` 를 보고한다. 일부가 빠진 텍스트에서 읽은 적발은 적발이 아니기 때문이다. inert 재작성은 관문 앞에서 정하고, 관문이 거부한 명령에는 아무것도 쓰지 않는다.

`scripts/measure/scan-failure-census.sh` 가 이것을 논증이 아니라 측정으로 만든다. 읽기를 하나씩, 그 읽기부터 끝까지, 종류별로, 그리고 `awk` 전부를 실패시킨 뒤, 각 실행을 무실패 실행과 비교해 약해진 판정, 잘못 표기된 판정, 관문 뒤의 읽기, deny 가 남긴 pending 상태를 센다. `npm test` 는 축약판을 돈다. v2.18.0 통합 트리에서 축약 census 는 macOS(bash 3.2)와 Linux(bash 5.2)에서 사례 32개, 실패 실행 3,041회를 돌았다. 두 곳 모두 약해진 판정, 잘못 표기된 판정, 오류, 관문 뒤의 읽기, deny 가 남긴 pending 상태가 0 이었고, 표시 없는 읽기, 목록에 없는 읽기, 불안정한 읽기도 0 이었다. 2,772회는 `UNDECIDED` 로 끝났고 269회는 무실패 판정을 지켰다.

`grep` 과 `sed` 에도 같은 클래스가 있었고, 이번 릴리즈보다 오래됐다. 판정 함수가 답하지 못한 grep·sed 를 "매치 없음" 으로 읽었다. 둘 중 하나가 실패하면 `pip install requests==2.0.0`, `npm install left-pad@1.3.0`, `cargo add serde@1.0.0` 가 판정 없이 통과했다. 이제 판정용 grep 은 "매치 없음"(1)과 "답하지 못함"(2 이상)을 가르는 래퍼 하나를 거치고, 뒤의 것을 기록한다. 정규화·러너 읽기·inert 재작성의 `sed` 실패도 기록한다. 관문은 이것들을 실패한 `awk` 와 똑같이 정산한다.

### 명령을 한 번에, 셸이 어휘를 나누는 방식대로 읽는다

상태기계 셋이 차례로 명령을 읽었고 서로 맞아야 했다. 줄 단위 heredoc 패턴, 줄 이음 처리, 따옴표 스캐너다. 리뷰 세 라운드 동안 셋은 맞지 않았다. heredoc 을 두 번 벗겼고, heredoc 이 아닌 곳에서 열었고(herestring, 산술 시프트, 따옴표 안 `<<EOF`), heredoc 인 곳에서 열지 않았다(숫자 구분자, heredoc 을 여는 줄에서 닫히는 여러 줄 문자열). 그때마다 그 뒤의 줄이 전부 게이트에서 사라졌다. 아래 115 형태 가운데 111 개는 bash, zsh 또는 에이전트 자신의 셸이 마지막 줄을 실행한다. v2.17.2 는 그 111 개 가운데 60 개를 판정 없이 통과시켰다. 지금은 0 이다. 각 수는 배터리와 형태 파일을 그 트리의 체크아웃에 복사해 `bash scripts/test/shell-reading.sh --count` 로 잰 값이다. 같은 클래스가 heredoc 옆에도 있었다. 주석 안 아포스트로피, `$'don\'t'` 이다. 따옴표 없는 구분자의 heredoc 본문 안 명령 치환은 셸이 실행하는 코드인데, 본문과 함께 지워졌다. `cat <<EOF`, 본문 줄 `$(pip install evil==6.6.6)`, `EOF` 가 판정 없이 통과했다.

이제 읽는 것은 `shell_lex` 하나다. 셸이 유지하는 어휘 상태를 따라가며 모든 바이트에 분류를 매기는 `awk` 한 패스다. 다른 리더는 모두 이 패스의 뷰를 받는다. 판정 함수는 따옴표 안·주석·heredoc 본문을 비운 scan 뷰를, payload 리더는 따옴표를 남긴 code 뷰를, 줄 단위 리더는 줄 이음을 없앤 joined 뷰를 읽는다. bash 와 zsh 가 다르게 읽는 곳은 갈림마다 축을 따로 두고, 명령이 세운 축의 모든 조합으로 판정한다. 두 갈림을 스위치 하나에 묶었을 때는 네 조합 중 둘만 판정했고, zsh 가 실제로 하는 읽기가 빠졌다(리뷰에서 잡힘). heredoc 본문도 같은 렉서가 걷는다. 그래서 본문 속 치환이 여러 줄에 걸치거나, 중첩되거나, `case` 를 담아도 읽힌다. 끝내 닫히지 않는 명령은 실패한 읽기라서, 패키지 매니저를 부르면 `UNDECIDED` 다. inert 재작성도 이제 scan 뷰에서 바이트 위치로 `--ignore-scripts` 를 놓는다. 리더가 scan·code 뷰에서 오프셋을 가져오고 뷰를 다시 읽기도 하므로, scan-contract 는 두 뷰가 명령의 바이트 길이를 지키고 두 번째로 읽어도 같은지를 기록된 모든 형태와 무작위 입력에서 확인한다. 이 검사가 scan 뷰가 두 번째 읽기에서 달라지는 두 경우를 찾았고, 둘 다 고쳤다. 이스케이프된 따옴표가 맨 따옴표로 남는 경우와, 비워진 구간 뒤의 `#` 이 주석이 되는 경우다.

`scripts/measure/shell-reading-forms.json` 은 형태마다 bash·zsh·sh·에이전트 자신의 zsh 래퍼가 낸 값을 기록한다. `npm test` 안의 `scripts/test/shell-reading.sh` 는 셸이 마지막 줄까지 실행하는 모든 형태에 적발을 요구하고, 데이터인 한 형태는 데이터로 남기를 요구한다. 리뷰 중에 분석기 규칙을 하나씩 빼 보았고, 변이마다 배터리 하나가 빨강을 냈다. 주석·따옴표·본문 상태, 두 산술 읽기, 두 갈림 축, 구분자 따옴표, `<<-` 탭, 숫자 구분자, 겹따옴표 안 중첩, heredoc 본문, case 패턴, 닫히지 않음 백스톱(이것은 consumer-forms 가 잡는다)이다. 분석기의 스캔은 릴리스 트리에서 `scripts/measure/scan-cost.sh` 로 재면 macOS 에서 8KB 0.05초, 32KB 0.12초, 64KB 0.21초이고 Linux 에서 0.02초, 0.05초, 0.08초다(장비는 아래 "빨라진 것" 에 있다).

### 읽기 하나가 셸 하나다: bash, zsh, dash

분석기는 명령을 셸 하나로 읽고, 거기서 표시한 갈림마다 읽기를 하나씩 더했는데, 그 집합은 닫힐 수 없었다. zsh 는 `((` 를 자리마다 정하므로 한 명령 안에 서브셸 `((` 와 산술 `((` 가 함께 있었다. 이어 붙이기 뒤의 리더들은 zsh 읽기를 bash 규칙으로 다시 분석해 그 줄을 한 번 더 숨겼다. zsh 와 에이전트 래퍼가 실행하는 `echo "${x:-'}"; <install>; echo "'}"` 가 판정 없이 통과했고, v2.17.2 는 이것을 거부했다. 리눅스에서 `sh -c` script 를 읽는 dash 는 `((` 는 bash 처럼, 아포스트로피는 zsh 처럼 읽는다. 이제 읽기 하나가 셸 하나이고, 명령을 읽는 모든 곳은 한 읽기 안에서 읽으며, 게이트는 합집합으로 판정한다. zsh·dash 읽기는 bash 읽기가 셸들이 다르게 읽는 자리를 지날 때만 돈다. `--ignore-scripts` 는 세 읽기가 npm 설치를 같은 자리에 둘 때만 넣고, 그렇지 않으면 명령은 `UNDECIDED` 다. 그 자리들의 표는 ARCHITECTURE.ko.md 에 있다.

검증: `scripts/measure/shell-reading-forms.json` 의 형태(186개)마다 macOS(bash 3.2, zsh 5.9, sh, dash, 에이전트 래퍼)와 리눅스(bash 5.2, dash 0.5.12)에서 잰 값이 있다. 셸이 형태의 마지막 줄을 실행한 곳마다 그 셸의 읽기에 그 줄이 보이고(셸 실행 925회), 게이트가 판정한다. 시드 고정 무작위 형태 400개(`scripts/measure/shell-reading-fuzz.sh`, 시드 20261001)에서 셸이 실행한 줄을 모든 읽기가 놓친 경우는 macOS(그런 형태 220개)와 리눅스(187개) 모두 0이고, 게이트가 통과시킨 것도 0이다. 주석 경계를 고친 뒤로 팔레트에 낱말 중간 `#`, `#` 앞의 줄 이음, glob 닫힘이 들어 있어서, 이 숫자가 그 전 팔레트의 249개·190개를 대신한다. 이 팔레트가 뽑은 형태 하나(heredoc 본문에서 열린 채 끝나는 산술 뒤의 설치)는 본문 끝에서 열린 맥락을 본문 데이터로 바꾸기 전까지 게이트를 통과했다. 읽기를 바꾼 변이 열 가지를 각각 사본에서 돌렸고, 모두 노린 행에서 배터리가 빨갛게 됐다. 판정 코퍼스와 무작위 명령 200개(시드 둘)를 이전 트리와 재생하면 판정 17개가 움직였고, 모두 pass 에서 deny 로 간 이름 있는 형태다. deny 에서 pass 로 간 것은 없다.

비용(리눅스 VM 의 `scripts/measure/scan-cost.sh`, 5회 중 최솟값, 부하 0.03–7.2, 이전 트리 대비): 설치가 없는 명령은 1–5% 안이다(부하가 오르는 중 한 칸 +11%). 셸들이 다르게 읽는 자리가 없는 거부된 설치는 3–9% 빠르다. 그런 자리가 있는 설치는 세 번 읽으므로 100B 1.8배, 8KB 2.0배, 32KB 2.3배, 128KB 2.7배가 든다(128KB 에서 17.0s 로 자체 예산 20s 안이다. 더 큰 명령은 전보다 일찍 예산을 넘고, 거기서는 `UNDECIDED` 다).

### 대입 접두 뒤의 설치

`FOO="a b" pip install evil==6.6.6` 은 v2.17.2 에서도, 이 릴리스의 모든 브랜치에서도 발견될 때까지 판정도 기록도 없이 통과했다. `FOO='a b'`, `FOO=$(printf x)`, 백틱, `FOO=a\ b`, `FOO=${BAR:-a b}`, `env FOO="a b"` 뒤의 같은 설치도 그랬다. 명령 게이트가 권위인 생태계에서는 완전한 우회였다. 접두를 벗기는 코드가 대입 값을 첫 공백이나 따옴표까지의 바이트로 읽었기 때문이다. 그래서 값에 공백이 있으면 접두가 설치 앞에 남았고, 설치는 끝내 인식되지 않았다. 이제 대입, `env`, `command`, `exec` 접두는 분석기에서 읽는다. 거기서는 값이 어떻게 따옴표를 치거나 중첩해도 한 단어다. 값 안의 치환에 든 설치는 여전히 읽고, 따옴표 친 값 안에서 이름만 나오는 설치는 데이터다.

파이프 옆에서는 같은 접두가 반대 방향의 오류를 냈다. `PIP_INDEX_URL=x pip install requests==2.0.0 && printf 'hi' | zsh -s` 는 `requests` 가 승인돼 있는데도 셸로 넘기는 설치로 거부됐다. 이제 blanking 단계는 접두를 건너뛰고, 매니저 단어를 온전한 단어로만 잡고, 그 설치 자신의 대입 이름과 평범한 값을 비운다.

### inert 플래그가 주석 안에 들어갔다

`npm ci # rebuild the lockfile` 이 `npm ci # rebuild the lockfile --ignore-scripts` 가 됐다. 셸은 주석을 버리므로 npm 은 플래그를 보지 못했고 lifecycle 스크립트가 돌았는데, meta 에는 억제됐다고 적혔다. heredoc 이나 둘째 줄도 같았다. 플래그가 종료 표시 뒤나 마지막 줄에 붙었다. 이제 명령에 따옴표 밖 `#`, 둘째 줄, 연결된 문장이 있으면 재작성을 설치 동사 바로 뒤에 넣는다. 첫 inert 릴리즈부터 그랬고, 위 설계 판정 중에 발견됐다.

동사는 셸이 실행하는 코드의 렉서 뷰에서 찾는다. 그래서 주석, 따옴표 안 문자열, heredoc 본문의 동사는 고쳐 쓰지 않는다. 그 뷰는 처음에 명령이 셸에 넘기는 script 를 빠뜨렸다. 보이는 설치 옆 `sh -c '...'` 안의 설치는, 보이는 설치가 inert 가 되는 동안 lifecycle 스크립트를 돌렸다(통합 중에 잡힘). 이제 플래그는 안쪽 셸이 읽는 바이트가 그대로인 `sh -c`, `bash -c`, `eval` script 안에도, 따옴표 안 치환 안에도 들어간다. 릴리스 이전부터 있던 틈도 함께 닫힌다. 단독 `sh -c 'npm install x'` 는 append 경로로 가서 플래그가 script 의 `$0` 이 됐다. 재작성이 닿지 못하는 npm 설치(이스케이프가 있는 겹따옴표 script, 셸로 파이프되는 heredoc)는 detect-and-rollback 으로의 다운그레이드로 기록한다.

### 효과 게이트가 보지 못하던 npm 설치

효과 게이트는 프로젝트의 `package-lock.json` 을 읽고, `UNGATED` 기록 면제는 프로젝트 안의 모든 npm CLI 설치가 거기에 기록된다고 가정했다. 실제 npm 과 lifecycle 스크립트가 흔적을 남기는 합성 패키지를 로컬 레지스트리에 붙여 종단으로 재 보니 그렇지 않은 형태가 여럿이었다.

- `--no-save`, `--save=false`, `npm_config_save=false`, `--package-lock false`, `npm_config_package_lock=false` 는 lockfile 을 그대로 두고 설치를 `node_modules/.package-lock.json` 에만 기록한다. 게이트는 프로젝트를 깨끗하다고 판정했고, 깨끗한 판정 뒤에 도는 inert rebuild 가 검증되지 않은 패키지의 preinstall·install·postinstall 을 실행했다.
- `-C <dir>` 과 `cd <dir> && npm install` 은 다른 디렉터리의 lockfile 에 기록하고, 게이트는 그것을 읽지 않았다.
- `npm_config_global=true` 는 전역에 설치하고, lockfile 도 기록도 없었다.

이제 게이트는 closure 를 lockfile 과 숨은 lockfile 의 합집합에서 읽고, 숨은 lockfile 이 있을 때만 프로젝트에 고정해(`--global=false --location=project`) rebuild 한다. 그래서 프로젝트 `.npmrc` 의 `global=true` 가 rebuild 를 전역으로 돌리지 못한다. 설치 전 게이트는 설치 문장마다 착지 위치를 따라가고(`-C`, 리터럴 `cd`·`pushd`, `env -C`), 따라가지 못하는 것은 기록한다. 기록 면제는 모든 설치 문장이 게이트가 읽는 곳에 떨어질 때만이다. 따옴표로 감싼 `--prefix`·`--cwd` 값은 셸처럼 읽는다. `scripts/test/lockless-forms.sh` 가 로컬 레지스트리에 대고 이 전부를 고정한다.

그 뒤 설치가 어디에 떨어질지 예측하는 방식이 리뷰 세 라운드에서 매번 조용한 통과를 남겼다. 실행되지 않은 `cd`, `command cd`, 심볼릭 링크로 걸린 워크스페이스 멤버다. 두 가지가 예측을 대신했다. 디렉터리는 npm 에게 물어 정한다. `npm prefix` 와 `npm root` 를 명령이 npm 을 돌리는 자리에서, 그 문장 자신의 인자와 환경으로 돌린다. 그 질문은 명령의 코드를 돌리지 않는다(아래). 그리고 설치는 그 디렉터리에 이번 호출의 설치 흔적이 있을 때만 읽은 것으로 친다. 명령 직전에 pre-guard 가 기준 파일을 touch 하고 그곳 두 lockfile 의 inode 를 적어 둔다. post 훅은 기준 파일보다 `find -newer` 한 lockfile, 또는 inode 가 바뀐 lockfile 을 흔적으로 친다. 둘 다 없으면 설치를 `UNGATED`("no install trace in <dir>")로 기록하고 그곳에서는 rebuild 하지 않는다. 그래서 틀린 예측은 조용한 통과가 아니라 기록이 된다. `scripts/test/install-dir-differential.sh` 가 237 가지 배치에서 게이트를 `npm prefix` 에 묶고, `scripts/test/effect-trace-grid.sh` 가 흔적을 종단으로 돌린다.

### 아무것도 저장하지 않는 설치도 출처와 설치 스크립트를 검사받는다

효과 게이트의 출처 검사(비표준·비보안 resolved URL)와 설치 스크립트 휴리스틱은 `package-lock.json` 이나 `package.json` 이 바뀔 때만 돌았다. 아무것도 저장하지 않는 설치는 둘 다 바꾸지 않는다: `npm install --no-save`, `npm_config_save=false npm install`, 명령줄에 이름을 댄 tarball. 그래서 승인된 이름과 버전을 단 tarball 이 `file:` 경로나 http URL 에서 오면 두 검사를 통과했고, Claude Code 에서는 무실행 설치 뒤 rebuild 가 그 스크립트를 돌렸다. 저장했다면 휴리스틱이 걸러 냈을 설치 스크립트를 가진 승인 패키지도 마찬가지였다. closure 검사는 이미 숨은 lockfile 을 읽었지만, 패키지를 이름과 버전으로 가리키고 사칭 패키지는 그 둘을 공유한다.

이제 두 검사는 두 npm 기록 중 하나가 담고 있지만 명령 전 어느 기록에도 없던 것을 읽는다. pre-guard 는 `package-lock.json` 사본 옆에 `node_modules/.package-lock.json` 사본도 떠 두고, post 훅은 두 기록을 두 사본과 함께 대조한다. 롤백은 원인이 된 출처를 기록 이름과 resolved URL 로 세 개까지 적는다.

동작이 둘 바뀐다:

- lockfile 도 설치된 트리도 없는 프로젝트에는 이전 기록이 없으므로, 첫 설치가 들인 것은 전부 새것이다. 공개 registry 밖의 출처(사설 registry, git URL, tarball)는 이제 거기서 롤백된다. lockfile 이 있는 프로젝트에 같은 의존성을 더할 때는 원래 그랬다. 전에 통과한 것은 비교할 스냅샷이 없었기 때문일 뿐이다.
- 커밋된 lockfile 은 기록대로 설치된다. 새로 clone 한 곳의 `npm ci`, 또는 lockfile 을 따르는 맨 `npm install` 은 lockfile 이 적은 출처를 고쳐진 것까지 그대로 설치한다. 커밋된 출처까지 검사하면 사설 registry, git URL, tarball 에서 설치하는 모든 프로젝트의 첫 `npm ci` 가 출처를 승인할 길 없이 롤백된다. 이것은 다음 릴리스로 남기고, README 와 ARCHITECTURE 가 경계로 적는다.

검증: `scripts/test/effect-trace-grid.sh` 1a 절, 실제 npm 과 로컬 레지스트리. 저장하지 않는 형태(C1, C3, C5, C6, H2)는 사칭 스크립트가 하나도 돌지 않고 롤백되며, 수정 전 트리에서는 빨강이다(리눅스, npm 10.8.2: 그 행들과 Codex C5 에서 기대 17개 실패). 저장하는 대조(C2, C4, H1)와 롤백되면 안 되는 행(C0, registry 의존성과 tarball 의존성을 가진 새 clone 의 `npm ci`, pull 한 lockfile 을 가진 설치된 트리)은 양쪽에서 그대로다. 50개 기준 개수 검사는 `package-lock.json` 에만 남는다. 이전 기록이 없으면 의존성이 50개를 넘는 프로젝트의 첫 설치가 모두 그 기준을 넘기 때문이다.

### 설치 스크립트는 트리 전체 검사로 허가된다

설치 스크립트는 두 곳에서 돌았고, 둘 다 트리 전체에 대해 돌았다. 무실행 설치 뒤의 rebuild 와, 롤백이 돌리던 재설치다. 둘 다 "이번 명령이 들인 것 중 거부된 것이 없다"는 판정으로 허가됐고, 그 판정의 구멍 셋이 연달아 스크립트 실행이 되었다. 마지막 것은 롤백이었다. 확정 스냅샷이 없는 프로젝트는 명령 전 상태로 롤백되는데, 그 상태에 거부된 패키지가 있으면 롤백의 `npm ci` 가 그 스크립트를 돌렸다. 커밋된 lockfile 에 그 패키지가 있는 새 clone(RB1), 승인 설치 전부터 lockfile 에 있던 경우(RB2), 앞선 `UNGATED` 설치가 써 넣은 경우(CH2b)다. 그래도 메시지는 "마지막 확정 안전 스냅샷으로 롤백했다"고 말했다. 같은 판정 때문에 rebuild 는 고쳐진 커밋된 lockfile 의 tarball(`npm ci` 의 L1, 맨 `npm install` 의 L2)과 앞선 `UNGATED` 설치가 링크한 디렉터리(CH1b)도 돌렸다.

그래서 허가를 변화분에서 떼어 트리에 옮겼다.

- rebuild 는 npm 이 rebuild 할 패키지가 전부 기록에 있고, `node_modules` 아래 패키지가 전부 공개 registry 의 https 출처로 기록돼 있거나(또는 부모가 묶은 것이거나), 그 밖의 디렉터리가 전부 선언된 워크스페이스 멤버일 때만 돈다. 아니면 rebuild 전체를 건너뛰고, 경고가 패키지나 디렉터리마다 종류를 붙여 지목한다. 이것으로 롤백하지는 않는다.
- 묶음 여부는 트리에서 읽는다. 중첩된 패키지는 부모가 이 검사를 스스로 통과하고, 디스크에 있는 부모 자신의 `package.json` 이 그것을 묶고, 그 패키지의 어느 기록도 공개 밖 출처를 적지 않을 때만 묶음으로 친다. lockfile 의 `inBundle` 은 읽지 않는다. 커밋된 기록이 그 필드를 적을 수 있고, 루트 프로젝트가 묶은 것에는 npm 이 직접 적는다. 두 경우 모두 http URL 의 tarball 이 묶음으로 통과했다(NB1, NB2).
- 롤백은 패키지 매니저를 부르지 않으므로 그 안에서는 스크립트가 돌지 않는다(CH3c, 아래 "롤백은 패키지 매니저를 부르지 않는다"). 확정 스냅샷이 없으면 메시지와 `reorg.log`, `advisory.log` 가 확정 스냅샷이 없었다는 것과 복원된 상태에 거부된 것이 남아 있을 수 있다는 것을 말한다. Codex 에서는 설치를 무실행으로 만들 수 없으므로, 설치 자신의 스크립트가 이미 돌았다는 것도 말한다.

사용자에게 보이는 변화: 트리에 공개 registry 에서 왔다고 기록되지 않은 패키지(사설 registry, git URL, tarball, `omit-lockfile-registry-resolved` 로 쓴 lockfile)나, 선언된 워크스페이스 멤버가 아닌 `file:` 디렉터리 의존성이 있는 프로젝트는 설치되지만 rebuild 되지 않는다. rebuild 는 전부 아니면 전무라서 승인된 패키지의 스크립트도 돌지 않는다. 경고가 무엇이 막았는지 지목하고, 사용자가 검토한 뒤 `npm rebuild` 를 돌린다. v2.17.2 에서는 커밋된 `file:` 디렉터리 의존성이 있는 프로젝트의 설치가 대신 롤백됐다(main 에서 npm 10.8.2 로 잼). 출처 승인과, 통과한 패키지만 rebuild 하는 것은 다음 릴리스로 남긴다.

검증: `scripts/test/effect-trace-grid.sh` 1d 절, 실제 npm 과 로컬 레지스트리(리눅스, npm 10.8.2). RB1, RB2, CH2b 와 Codex RB1 은 스크립트 없이 롤백되고 세 기록 모두에 "no confirmed snapshot" 이라고 적는다. CH3c 와 Codex CH3c 는 확정 스냅샷으로 롤백되고, `node_modules` 가 지워지며 스크립트가 돌지 않는다. CH1b, L1, L2, K4-K7, OM1 은 경고와 함께 남고 스크립트가 돌지 않는다. K8, K9, NS1 과 묶인 의존성을 가진 공개 패키지(BD1)는 조용히 rebuild 된다. 수정 전 트리에서는 RB1, RB1x, RB2, CH2b, CH1b, L1, L2 가 거부된 스크립트를 돌렸고, K4-K7 과 OM1 을 포함해 기대 47개가 실패했다. 출처·디렉터리 검사를 제거하면 그 행들이 빨개진다(CH1b, L1, L2). 변이 둘은 롤백이 아직 재설치를 하던 때에 쟀다. 롤백 `npm ci` 에 스크립트 켜기와 확정 스냅샷 없는 롤백 뒤 rebuild 이고, 둘 다 RB1, RB1x, RB2, CH2b 가 빨개졌다. 이제 롤백에는 변이할 npm 이 남아 있지 않고, 그 행들은 롤백이 npm 을 부르지 않는다는 것을 고정한다.

트리에서 읽는 묶음 판정도 같은 방식으로 쟀다(macOS, npm 11.19.0). 커밋된 lockfile 이 중첩된 sd-swapped@1.0.0 을 http tarball 로 보내면, 그 기록이 `inBundle` 이라 하든(NB1) 루트가 그 부모를 묶든(`npm ci` 의 NB2, `npm install` 의 NB2i, `npm install --no-save` 의 NB2n) 경고와 함께 설치되고 스크립트는 돌지 않는다. 의존성을 묶은 공개 패키지는 `bundleDependencies`(BD1)든 `bundledDependencies: true`(BD2)든 조용히 rebuild 되고, 묶인 기록이 다른 출처를 적으면 rebuild 되지 않는다(NB3). Codex 롤백 행(RB1x)은 메시지가 설치 자신의 스크립트가 이미 돌았다고 말하게 고정한다. 수정 전 트리에서는 NB1, NB2, NB2i, NB2n 이 가짜 tarball 의 스크립트 셋을 돌렸고 이 절의 기대 17개가 실패했다. `inBundle` 을 다시 믿게 한 변이는 같은 넷과 NB3 를 빨갛게 만든다(기대 14개).

### 공개 registry 기록은 바이트가 온 곳이 아니다

rebuild 의 트리 전체 검사와 출처 검사는 `https://registry.npmjs.org/` 위의 `resolved` URL 을 공개 registry 로 쳤다. npm 의 기본값 `replace-registry-host=npmjs` 는 그런 URL 을 npm 에 설정된 registry 에서 받고, 기록에는 URL 을 그대로 적는다. 그래서 커밋된 `.npmrc` 의 `registry=<아무 곳>` 이 승인된 이름과 버전을 다른 tarball 로 보냈다. 새 프로젝트(RH1)에서도, 커밋된 lockfile 에 가짜의 integrity 만 적힌 clone(RH2)에서도 그랬다. 명령 앞의 `npm_config_registry`(RH3)도 같았다. 두 lockfile 모두 공개 URL 을 적었고, 롤백도 경고도 없었으며, 무실행 설치의 rebuild 가 가짜의 스크립트를 돌렸다. 위에서 말한 "새 프로젝트의 첫 설치에서 사설 registry 출처는 롤백된다" 는 이 경우에 성립하지 않았다.

이제 npm 이 어디서 받는지를 설치가 어디에 떨어지는지처럼 npm 에게 묻는다.

- pre-guard 는 `npm prefix`, `npm root` 와 나란히 `npm config ls --json` 을 묻는다. 같은 디렉터리에서, 그 문장 자신의 인자와 환경으로, 같은 마감 안에서다. 이 답으로 설치를 차단하지는 않는다. 사내 registry, 미러, 프록시는 프로젝트나 사용자 `.npmrc`, `npm_config_registry` 로 설정되고, 아직 registry 를 승인할 길이 없다. 명령이 직접 적은 `--registry` 만 원래 있던 텍스트 검사가 여전히 차단한다. 워크스페이스 멤버에서는 npm 이 `npm config` 를 거부하므로(ENOWORKSPACES), npm 이 지목한 루트에서 묻는다. 설치가 프로젝트 설정을 읽는 곳이 거기다.
- post 훅은 명령 뒤에 자기가 읽은 디렉터리에서 다시 묻는다. 공개 URL 은 두 답이 모두 npm 이 거기서 받았다고 할 때만 공개 registry 를 보증한다. 명령이 직접 쓴 `.npmrc` 는 여기서 보인다. 어느 한 답이라도 공개 밖 registry 를 대면 설치는 그대로 두고, 아무것도 rebuild 하지 않으며, 롤백도 하지 않는다. 경고는 registry 를 이름 대고, 그 때문에 스크립트를 돌리지 않았다고 말하며, 에이전트가 직접 `npm rebuild <pkg>` 를 돌리기 전에 사용자에게 확인하라고 말한다. Codex 에서는 설치 자신의 스크립트가 훅보다 먼저 돌았으므로 경고가 그렇게 말한다.
- 답이 없으면 기본값으로 메우지 않는다. npm 이 없거나 실패하거나 늦은 경우, 그리고 보이지 않게 npm 의 환경을 바꿀 수 있는 앞선 문장(`source`, `.`, `eval`, `set -a`, `declare -x`, 따로 선 `npm_config_*` 대입)은 모두 답을 모름으로 남긴다. 모름이면 이유를 적은 경고와 함께 rebuild 를 건너뛰고(RH7), 롤백 사유로 삼지 않는다.
- 테스트 배터리의 로컬 registry 는 이름으로만 통과한다. `SAFEDEPS_NPM_TEST_REGISTRY` 는 loopback URL 하나만 받고, 그것을 설정한 실행은 매번 옮긴 advisory 출처와 함께 `advisory.log` 에 그 사실을 적는다.

사용자에게 보이는 변화: `.npmrc` 나 환경에서 정한 공개 밖 registry 에서 받는 npm 설치는 막히지 않는다. 그 registry 가 공개 registry URL 로 내준 것은 설치되지만, Claude Code 에서는 그 registry 를 믿는 사람이 직접 `npm rebuild` 를 돌리기 전까지 설치 스크립트가 돌지 않는다. 사내 registry, 공개 registry 의 미러나 프록시도 같은 처지다. registry 승인 경로는 다음 릴리스에 둔다. npm 설치 앞에서 파일을 source 하거나 `eval` 을 쓰는 명령은 자동 rebuild 를 받지 못한다.

경계: 두 질의가 모두 보지 못하는 곳에서 정한 registry 는 어느 답에도 없다. 훅 프로세스가 공유하지 않는 에이전트 셸의 환경, 그리고 명령이 썼다가 다시 지우는 `.npmrc` 다. 이때 rebuild 는 그 registry 가 준 것을 그대로 돌린다. ARCHITECTURE 에 rebuild 검사가 읽는 lockfile 필드마다 보증하지 못하는 것과 그것을 고정한 행을 표로 적었다.

검증: `scripts/test/effect-trace-grid.sh` 1d 절. 가짜를 내주는 두 번째 fixture registry 를 127.0.0.1 에 띄웠다(macOS 15.6.1, npm 11.19.0). RH1, RH2, RH3, RH3e, RH8(루트 `.npmrc` 아래의 워크스페이스 멤버), RH1w(명령이 쓴 `.npmrc`), RH2w 는 설치가 유지되고, 롤백되지 않으며, 스크립트가 돌지 않는다. 경고는 가짜 registry 를 이름 대고 rebuild 전에 사용자에게 확인하라고 말한다. Codex RH3 은 설치 자신의 스크립트가 이미 돌았다는 경고와 함께 유지된다. RH7(`source`)은 모름을 이름 대는 경고와 함께 유지된다. RH4(명령줄 `--registry`)는 아무것도 설치되기 전에 차단된다. 샌드박스 registry 에서 받는 승인된 설치 RH5 는 rebuild 된다. 최종 트리에서 격자는 부하 5–6 에서 379초에 통과하고, smoke 와 lockless-forms 도 함께 통과한다. 바뀌기 전, 새 행을 얹은 3e22fbc 에서는 RH1, RH2, RH3, RH3e, RH8, RH1w, RH2w, RH7 이 각각 가짜의 스크립트 셋을 돌렸다(기대 32개 실패). 먼저 나온 차단 설계(5566cc0)를 이 행들에 돌리면 기대 10개가 실패한다. RH1, RH2, RH3, RH3e, RH8, Codex RH3 을 차단하고, RH1w 를 롤백하며, RH1w·RH2w·RH7 의 경고가 registry 를 이름 대지도 사용자에게 물으라고 하지도 않는다. npm 의 답을 무시하고 공개 URL 만 믿게 하면 유지 행 여덟이 모두 다시 빨갛다. rebuild 가 각 행에서 가짜의 스크립트를 돌리고, Codex RH3 은 경고를 잃는다(기대 25개 실패). 대조와 변이는 나란히, 부하 4–12 에서 돌렸다. 이 변경의 첫 차단 버전은 같은 호스트에서 e2e 와 install-dir-differential 도 통과했다. 이번 라운드는 건드린 배터리만 돌렸다. 리눅스와 npm 10.8.2 는 재지 않았다.

### 바이트가 어디서 왔는지는 받을 때 기록한다

위 변경은 바이트를 받은 그 명령을 판정할 뿐, 다음 명령에는 아무것도 알려 주지 않았다. 가짜를 받아 온 설정이 사라지면 다음 명령이 그것을 rebuild 해 스크립트를 돌렸다. 한 번만 쓴 `npm_config_registry` 뒤의 승인 설치(P1), `.npmrc` 를 지운 뒤의 맨 `npm install`(P2), `node_modules` 를 지운 뒤 npm 캐시가 integrity 로 내준 `npm ci`(P3), 가짜가 든 채 확정된 스냅샷으로의 롤백(P4), 같은 머신에서 같은 lockfile 로 다른 프로젝트가 돌린 `npm ci`(P5)다. 두 lockfile 에서 `integrity` 를 지워도 그랬다(P7). 같은 종류의 반례가 세 번 연달아 나온 것이다. `inBundle`, `resolved`, rebuild 시점의 설정이 각각 "이 바이트는 어디서 왔나"를 바이트에 묶이지 않은 값으로 답했다.

- 이제 post 훅이 받는 것을 볼 때 그 사실을 기록한다. 설치가 두 lockfile 중 어디에든 새로 들인 integrity 가운데 npm 이 공개 registry 에서 받았다고 답하지 않은 것을 패키지, 받은 곳, 처음 받은 프로젝트와 함께 `~/.safedeps/npm-withheld` 에 적는다. 두 엔진 모두 롤백보다 먼저 적는다. npm 캐시가 integrity 로 바이트를 다른 프로젝트에 나르므로 기록은 머신 전역이고, 경로는 `SAFEDEPS_HOME` 에서만 나온다.
- 트리 전체 검사는 기록된 integrity 를 지닌 패키지와, integrity 가 없는 공개 registry 기록을 거부한다. rebuild 를 건너뛰고 롤백은 하지 않으며, 경고는 registry 와 처음 받은 프로젝트를 이름 대고 rebuild 전에 사용자에게 물으라고 말한다. 기록을 읽지 못하면 이유와 함께 rebuild 를 건너뛴다.
- 기록은 바이트가 트리를 떠날 때만 풀린다(P6). 이 버전에는 기록을 푸는 명령이 없다.
- "새로 들인" 은 명령 전 설치 트리와 다이제스트 하나씩 대조해 잰다. 기록의 첫 버전은 커밋된 `package-lock.json` 이 적은 integrity 도 모두 뺐다. 이미 기록된 바이트는 어느 registry 에서 받아도 같다는 이유였다. 커밋된 기록은 누가 받는 것을 본 fetch 가 아니다. 그래서 커밋된 `.npmrc` 나 일회성 `npm_config_registry` 를 거친 clone 의 `npm ci` 는 자기 경고가 사칭 registry 를 이름 댔는데도 아무것도 기록하지 않았고, 다음 명령이 사칭 패키지를 rebuild 했다. 맨 `npm install`(Q1), 승인 설치(Q2), 캐시에서 온 `npm ci`(Q3), 다른 프로젝트의 `npm ci`(Q4)다. 사칭 패키지의 sha512 를 트리가 이미 가진 다이제스트와 나란히 적은 integrity 는 통째로 통과했다(Q5). npm 이 가장 강한 알고리즘의 다이제스트 중 아무것이나 받기 때문이다. 비용: 사내 registry 에서 설치하는 clone 의 첫 `npm ci` 가 그 바이트를 기록한다.
- 명령 전 트리는 게이트가 관측한 만큼만 친다. 기록의 다음 버전은 pre-guard 가 떠 둔 `node_modules/.package-lock.json` 사본을 그 트리로 쳤는데, 그 파일도 누구나 커밋할 수 있는 기록이다. 사칭 integrity 를 적은 그 파일 하나만 담아 온 clone 에서는 경고가 registry 를 이름 대는 동안 사칭 registry 에서 받은 첫 fetch 가 기록에서 빠졌고, 같은 네 명령이 사칭 패키지를 rebuild 했다(HL1-HL4). 이제 post 훅은 프로젝트 디렉터리마다 거기서 마지막으로 판정한 트리 기록의 sha256 을 남기고(`~/.safedeps/npm-observed`), 사본은 그것과 같을 때만 친다. 그 안에서도 다이제스트를 하나만 적은 항목만 보증한다. 사칭 패키지의 sha512 를 공개 것과 나란히 적고 공개 registry 에서 설치한 항목이 사칭 다이제스트를 보증했다(DP1). 비용: 답을 모르는 설치는 훅이 관측하지 않은 트리의 패키지를 공개 것까지 모두 기록한다. 그래서 새로 clone 한 곳의 `set -a && npm ci` 하나, 또는 업그레이드 뒤 한 프로젝트에서 처음 돈 그런 설치가 그 트리 전체를 이 머신에서 보류한다(UK0a, UK1a). 거기서 평범한 설치가 한 번 돌고 나면 자기가 들인 것만 기록한다(UK2).
- 명령이 먼저 돌린 코드 뒤의 설치는 아무것도 기록하지 않는다. `source ~/.nvm/nvm.sh && npm ci` 는 npm 의 답을 모름으로 남겨, 위 규칙 아래에서 트리의 패키지를 모두 머신에서 보류했다(UK0, UK1). `source`, `.`, `eval` 이 돌리는 코드를 쥔 쪽은 이미 에이전트 셸에서 코드를 돌리므로, 기록은 그 쪽을 막아 주는 것이 없었다. 이제 pre-guard 는 코드만이 이유이고 나머지는 npm 이 모두 답했을 때 그 모름 답에 `cause: "sourced"` 를 단다. 그 호출에서는 여전히 설치 스크립트를 돌리지 않고 경고가 이유를 말하지만, 아무것도 기록하지 않고 트리를 관측된 상태로 남기지도 않는다. 그래서 npm 이 공개 registry 라고 답하는 다음 설치가 그 트리를 rebuild 한다. 게이트가 읽지만 재현할 수 없는 설정(`set -a`, `declare -x`, `npm_config_*` 대입)은 혼자든 `source` 옆이든 여전히 기록된다.
- npm 이 답한 registry 는 코드 뒤에서도 선다. 위 면제의 첫 판은 `source`, `.`, `eval` 뒤에 npm 이 준 답을 모두 sourced 모름으로 바꿨다. 그래서 `. /dev/null; npm_config_registry=<사칭> npm install x`, `eval true; export …`, `source /dev/null && export …` 는 npm 이 명령 자신의 단어에서 사칭 registry 를 답했는데도 아무것도 기록하지 않았고, 다음 승인 설치가 사칭의 스크립트 셋을 돌렸다(VB1-VB3). 이제 면제는 npm 이 공개 registry 라고 답했을 때만 선다. 다른 registry 를 적은 답은 그대로 서고, P1·EXP1 처럼 기록된다. `eval "export npm_config_registry=…"` 처럼 자기 글자에 `npm_config_*` 설정을 적은 코드는 게이트가 읽지만 재현할 수 없는 설정으로 쳐서 기록한다(EV1).
- 명령이 export 한 것은 이름이 무엇이든 질의에 실린다. pre-guard 는 문장 자신의 대입은 무엇을 가리키든 npm 질의에 실었지만, export 는 `npm_config_*` 설정을 가리킬 때만 실었다. npm 은 사용자 `.npmrc` 를 `HOME` 에서 읽는다. 그래서 `export HOME=<dir>; npm install x`, 같은 꼴의 `&&`, `HOME=<dir>; export HOME; …` 는 훅의 `HOME` 으로 물어졌다. 두 질의 모두 공개 registry 를 답했고, 첫 명령이 `<dir>/.npmrc` 의 registry 가 준 것의 스크립트를 rebuild 로 돌렸다(XH1-XH3). `declare -x HOME=<dir>` 는 답을 모름으로 남겨 기록됐다(XH4). 이제 `export`, `declare -x`, 대입 뒤의 맨 `export NAME` 은 값이 글자 그대로인 모든 이름을 싣는다. 문장 자신의 접두가 싣는 것과 같은 집합이다. 따로 선 줄의 대입도 싣는다. `HOME` 은 이미 export 되어 있기 때문이다(XH5). 그런 대입이 npm 에 닿지 않는다면 npm 은 훅의 환경으로 돌고, post 훅이 묻는 환경이 그것이다. 셸이 실행할 때 값을 정하는 export 는 답을 모름으로 남기고 기록된다(XU1). `declare -xi` 처럼 저장하는 값을 바꾸는 `declare -x` 는 여전히 게이트가 재현할 수 없는 설정이다(UK1d). 비용: `export PATH="…:$PATH" && npm ci` 도 이제 답이 모름이고, 훅이 관측하지 않은 트리에서는 패키지를 모두 기록한다.
- npm 에게 묻는 일은 명령의 코드를 하나도 돌리지 않는다. 질의는 명령 자신의 `PATH`, `NODE_OPTIONS`, npm 단어를 실었다. 그래서 `PATH=<dir> npm install x`, `NODE_OPTIONS=--require=<file> npm install x`, `<dir>/npm install x` 는 게이트가 아무것도 정하기 전에 판정 한 번에 명령의 코드를 세 번씩 돌렸고, 게이트가 결국 거부한 명령도 똑같이 돌렸다. 이 문제를 들인 질의가 이번 릴리스의 것이라 릴리스 전에 닫는다. 이제 질의는 언제나 훅의 `PATH` 에 있는 훅 자신의 npm 으로 돌고, npm 이 시작할 때 코드를 고르는 이름은 싣지 않는다. `PATH`, `NODE_OPTIONS`, `NODE_PATH`, `OPENSSL_CONF`, `OPENSSL_MODULES`, `LD_*`, `DYLD_*`, `BASH_ENV`, `npm_config_node_options` 다. 명령이 그중 하나를 설정하거나 unset 하거나, `env -i` 를 돌리거나, 훅 자신의 것이 아닌 경로로 npm 을 적으면, 그것은 명령이 npm 에게 쥐여 준 코드이고 `source` 와 같은 부류다. npm 이 공개 registry 를 답하면 그 명령의 스크립트는 경고와 함께 보류되고 아무것도 기록되지 않으며, npm 이 다른 registry 를 답하면 그 답이 그대로 기록된다. 위의 비용도 이로써 사라진다. `export PATH="…:$PATH" && npm ci` 는 더 이상 트리를 기록하지 않는다. `unset NAME` 은 질의에 `env -u NAME` 으로 실린다. 비용: `NODE_OPTIONS=--max-old-space-size=4096 npm ci` 는 자동으로 rebuild 되지 않는다.

사용자에게 보이는 변화: 공개 밖 registry 로 한 번 받은 패키지는, 미러라도, 머신의 어느 프로젝트에서도 자동 rebuild 되지 않는다. 미러는 공개 registry 와 같은 바이트를 내주기 때문이다. 막는 것은 없다. registry 승인은 다음 릴리스에 두며, 기록된 integrity 를 공개 registry 의 `dist.integrity` 와 비교하는 검사와 함께 이 비용을 없앤다.

경계: 게이트가 받는 것을 본 적 없는 바이트. 훅 밖에서 돈 설치, 명령 훅이 알아보지 못했거나 `UNGATED` 로 기록된 설치, npm 의 두 답이 보지 못하는 registry 는 기록 없이 npm 캐시에 바이트를 넣고, 그 integrity 를 적은 lockfile 은 거기서 그것을 설치한다. clone 이 `node_modules` 안에 담아 온 바이트도 기록 밖이다. 아무도 그것을 받지 않았기 때문이다. npm 이 공개 registry 라고 답했을 때 `source`, `.`, `eval` 뒤에 받은 바이트도 그렇다. source 한 파일이 npm 을 다른 registry 로 돌려놓았다면, npm 이 공개 registry 라고 답하는 다음 설치가 그 registry 가 준 것을 rebuild 한다(VB4). 그 registry 가 registry.npmjs.org URL 을 내주면 기록의 `resolved` 도 그것을 막지 못한다. 그 코드를 쥔 쪽은 이미 에이전트 셸에서 코드를 돌리므로 고른 경계다. 명령이 자기 `PATH` 나 npm 경로로 고른 npm 만 읽는 설정도 같다. safedeps 는 자기 npm 에게 묻고, 다른 npm 을 고른 쪽은 이미 그것을 돌린다.

검증: `scripts/test/effect-trace-grid.sh` 1d 절. 실제 npm, 샌드박스 registry, 가짜를 내주는 두 번째 픽스처 registry 로 돌렸다. 트리는 macOS 15.6.1, node v26.7.0, npm 11.19.0 에서 `nice` 로 돌렸고 load 는 3.8 에서 17.8 이었다. P1-P5, P1x(Codex 설치 뒤 Claude 설치), PU(`source` 뒤 설치)는 rebuild 없이 유지되고, 경고가 registry(또는 모름의 이유)와 처음 받은 프로젝트를 이름 댄다. P4 는 확정 스냅샷으로 롤백하고 아무것도 rebuild 하지 않는다. P7 은 integrity 없음 경고와 함께 유지된다. P0, P6 은 조용히 rebuild 된다. grid 는 실패 0(477초), lockless-forms 는 실패 0(340초), smoke 는 통과했다. 변경 전 트리(104a2fa)에 새 배터리를 넣으면 기대 24개가 실패했다. P1, P1x, P2, P3, P4, P5, P7, PU 에서 셋씩이고, 모두 가짜의 스크립트 셋을 돌렸다. P0, P6 은 통과했다. 변이 셋은 각각 예상한 곳에서만 빨갛다. 기록 조회를 빼면 P1-P5, P1x, PU(21), integrity 없음 조건을 빼면 P7(3), 기록을 프로젝트별 키로 하면 P5(3)다. 리눅스(bash 5.2.37, node v20.20.2, npm 10.8.2, load 2 미만)에서 grid 와 lockless-forms 는 각각 실패 0 으로 통과했다. 그 실행이 먼저 앞선 변경이 들인 pre-guard 크래시를 찾았다. 문장별 리더가 일찍 끝난 문장, 예컨대 `printf 'save=false\n' > .npmrc && npm install x` 의 `printf` 에서 `fetch` 를 비워 두지 않고 설정 안 된 채로 남겼다. bash 5 는 `set -u` 아래 설정 안 된 변수에서 멈추므로 그런 명령은 모두 fail-closed 로 거부됐고, 두 배터리는 첫 그런 형태에서 죽었다. macOS 의 bash 3.2 는 그 값을 빈 값으로 읽었다. 이제 문장의 다른 필드와 함께 초기화한다.

좁힌 기록의 검증: 1d 절의 Q1-Q5 행. 각 트리를 리눅스(bash 5.2.37, node v20.20.2, npm 10.8.2)와 macOS(bash 3.2.57, node v26.7.0, npm 11.19.0)에서 `nice` 로 차례로 돌렸다. 고친 트리는 두 곳 모두 grid 전체를 실패 0 으로 통과했다. 리눅스 574초(load 0.7 에서 6.1), macOS 466초(load 6.9 에서 4.0)다. Q1-Q5 는 rebuild 없이 유지되고, 경고가 registry 와 처음 받은 프로젝트를 이름 댄다. 공개 clone 의 첫 `npm ci` 는 조용히 rebuild 된다(K1). 변경 전 트리(d669147)에 새 배터리를 넣으면 두 호스트 모두 기대 15개가 실패했다. Q1-Q5 에서 셋씩이고, 모두 가짜의 스크립트를 돌렸다. 변이 둘은 두 호스트 모두 예상한 곳에서만 빨갛다. 커밋된 `package-lock.json` 을 명령 전 기록에 되돌리면 Q1-Q5(15), 다이제스트 하나로 항목 전체를 맞추면 Q5(3)다. 대조와 변이 둘은 1 절의 행을 뺀 채 돌렸다. npm 11.4.2 로 돌린 macOS 첫 시도는 이 행들에 닿기 전에 1 절의 모든 설치가 실패해 버렸다.

관측한 트리 기록의 검증: 1d 절의 HL1-HL4, DP1, UK0-UK2 행. 고친 트리는 리눅스(bash 5.2.37, node v20.20.2, npm 10.8.2, grid 632초, lockless-forms 378초, load 1.6 에서 6.9)와 macOS(bash 3.2.57, node v26.7.0, npm 11.19.0, grid 711초, lockless-forms 480초, load 14 에서 59) 모두에서 grid 전체와 lockless-forms 를 실패 0 으로 통과했다. HL1-HL4 와 DP1 은 rebuild 없이 유지되고, 경고가 registry 를 이름 댄다. 공개 clone 의 첫 `npm ci` 는 조용히 rebuild 되고(K1), 관측된 트리에서 답 모르는 설치 뒤의 승인 설치도 그렇다(UK2). UK2 는 rebuild 가 남긴 트리 기록이 여전히 해시와 맞는다는 것도 보여 준다. 변경 전 트리(4f61bba)에 새 배터리를 넣으면 두 호스트 모두 기대 17개가 실패했다. HL1-HL4 와 DP1 에서 셋씩이고 모두 가짜의 스크립트 셋을 돌렸으며, 나머지 둘은 이 변경이 들인 비용을 고정하는 UK0 이다. 변이 둘은 두 호스트 모두 예상한 곳에서만 빨갛다. pre-guard 의 사본을 무조건 믿으면 HL1-HL4 와 UK0(14), 다이제스트 둘을 적은 항목이 보증하게 하면 DP1(3)이다. 대조와 변이는 1 절과 1a 절의 행을 뺀 채 돌렸다. 행은 이 실행들 뒤에 지금의 이름을 받았고(이름만 바뀜), 그 뒤 1d 절은 두 호스트 모두 실패 0 으로 다시 통과했다.

source 뒤 기록의 검증: 1d 절의 SRC1-SRC3, EXP1, UK0, UK1, UK0a, UK1a, UK1d, UK1v, MX1, UK2 행. 고친 트리는 리눅스(bash 5.2.37, node v20.20.2, npm 10.8.2, 662초, load 0.1 에서 1.7)와 macOS(bash 3.2.57, node v26.7.0, npm 11.19.0, 747초, load 3.3 에서 15.5) 모두에서 grid 전체를 실패 0 으로 통과했다. 같은 코드로 lockless-forms 와 smoke 도 두 호스트에서 통과했다. 리눅스 380초와 61초, macOS 340초와 65초다. SRC1(`source`), SRC2(`.`), SRC3(`eval`)은 rebuild 없이 유지된다. 경고가 이유를 말하고, 보류 기록과 관측한 트리 해시는 그대로다. 같은 프로젝트의 다음 평범한 설치는 sd-approved 를 rebuild 한다. UK0 와 UK1 은 이제 다른 프로젝트에서 rebuild 된다. UK0a, UK1a, UK1d, UK1v, MX1, EXP1 은 여전히 기록의 경고와 함께 유지된다. `source` 뒤의 기록을 고정하던 PU 는 기록과 함께 뺐다. 변경 전 트리(a523398)에 새 배터리를 넣으면 두 호스트 모두 기대 17개가 실패했다. SRC1-SRC3 에서 넷씩, UK0 와 UK1 에서 둘씩, 그리고 MX1 이다. MX1 은 경고가 기록을 남기는 `set -a` 가 아니라 `source` 를 이름 댔다. 변이 셋은 두 호스트 모두 예상한 곳에서만 빨갛다. source 뒤에도 다시 기록하면 SRC1-SRC3, UK0, UK1(13)이고, SRC 행은 모두 기록에 쓰인 파일로 잡혔다. 모든 모름 답을 빼 주면 UK0a, UK1a, UK1d, UK1v, MX1(10)이다. 트리를 관측된 상태로 남기면 SRC1-SRC3(3)이다. 대조와 변이는 1 절과 1a 절의 행을 뺀 채 돌렸다.

코드 뒤에도 서는 답의 검증: 1d 절의 VB1-VB4, EV1 행, 그리고 SRC1-SRC3, EXP1. macOS 15.6.1(bash 3.2.57, node v26.7.0, npm 11.19.0)에서 고친 트리는 grid 전체를 실패 0 으로 통과했다(655초, load 4.6 에서 12.7). 그 곁에서 lockless-forms(ok 23, 401초), smoke(ok 54), scan-contract(ok 43), consumer-forms(ok 61)가 통과했고, quick census 는 weakened, mislabeled, after-gate, pending-on-deny 를 모두 0 으로 셌다(load 9 에서 25). 리눅스(bash 5.2.37, node v20.20.2, npm 10.8.2)에서도 같은 배터리가 같은 수로 통과했다. lockless-forms 는 408초, consumer-forms 는 558초, census 는 load 3.7 에서 7.4 였다. grid 의 첫 리눅스 런(749초, load 0.9 에서 1.2)은 VB4 의 검사 하나를 빼고 모든 행을 통과했다. 그 검사는 행의 두 번째 설치 뒤에 기록 디렉터리를 읽었는데, 그 설치는 공개이고 트리를 관측된 상태로 남기므로 테스트의 잘못이었다. 첫 명령 바로 뒤에 읽게 고친 뒤 macOS 와 아래 리눅스 런 셋에서 통과했다. VB1-VB3 은 아무것도 rebuild 하지 않고 유지되며, 경고가 registry 와 바이트를 처음 받은 프로젝트를 말한다. EV1 은 모름 답에 대한 기록의 경고와 함께 유지된다. SRC1-SRC3 은 여전히 다음 평범한 설치가 rebuild 한다. VB4 는 경계를 고정한다. 첫 명령은 아무것도 기록하지 않고, 다음 승인 설치가 경고 없이 사칭의 스크립트 셋을 rebuild 한다. 바꾸기 전 트리(fd74e4c)에 새 행을 붙이면 두 호스트 모두 기대 12개가 실패했다. VB1-VB3, EV1 에서 셋씩이고 모두 사칭 스크립트가 돌았으며, VB4 와 SRC1-SRC3 은 통과했다. 변이 둘은 두 호스트 모두 기대한 곳에서만 실패했다. 코드 뒤 npm 의 모든 답을 면제하면 VB1-VB3(9), `eval` 글자에 적힌 npm 설정을 무시하면 EV1(3)이다. 대조와 변이는 1 절과 1a 절의 행을 뺀 채, macOS 는 load 7 에서 25, 리눅스는 1 에서 7 에서 돌렸다.

export 가 싣는 것의 검증: 1d 절의 XH1-XH5, XC1-XC3, XU1 행과 UK1d. 이 행들은 `npm_config_userconfig` 를 풀고 샌드박스 userconfig 를 `$HOME/.npmrc` 에 둔 채 돈다. 그 변수가 `HOME` 보다 앞서기 때문이다. `.npmrc` 가 사칭 registry 를 가리키는 디렉터리를 하나 둔다. 고친 트리는 macOS 15.6.1(bash 3.2.57, node v26.7.0, npm 11.19.0, 870초, load 16.5 에서 19.3)과 리눅스 Debian 13(bash 5.2.37, node v20.20.2, npm 10.8.2, 817초, load 0.1 에서 0.8) 모두에서 grid 전체를 실패 0 으로 통과했다. 그 리눅스 런에는 고친 VB4 가 들어 있다. 리눅스에서는 그 곁에서 lockless-forms(ok 23), smoke(ok 54), scan-contract(ok 43), consumer-forms(ok 61)가 통과했고, quick census 는 weakened, mislabeled, after-gate, pending-on-deny 를 모두 0 으로 셌다(load 2.3 에서 6.1). XH1-XH5 는 첫 명령에서 아무것도 rebuild 하지 않고 유지되며, 다음 승인 설치는 registry 와 처음 받은 프로젝트를 적은 경고와 함께 보류된다. XU1 은 모름 답의 경고와 함께 유지된다. XC1-XC3 는 이전과 같다. 바뀌기 전 트리(e965c09)에 새 행을 넣으면 두 호스트 모두 21 개 기대가 실패했다. XH1, XH2, XH3, XH5, XU1 에서 넷씩이고, 거기서는 첫 명령과 다음 승인 설치가 모두 사칭의 스크립트 셋을 돌렸다. XH4 에서 하나이고, 그것은 모름 답으로 기록되어 아무것도 돌리지 않았다. XC1-XC3 와 UK1d 는 거기서도 통과했다. 변이 둘은 두 호스트에서 기대한 자리에서만 실패했다. export 에서 `npm_config_*` 이름만 싣게 하면 XH1, XH2, XH4, XU1 이 실패했다(16). XH3 은 여전히 통과했는데, `export HOME` 앞의 대입이 따로 실리기 때문이다. 따로 선 줄의 대입을 싣지 않게 하면 XH5 가 실패했다(4). 바뀌기 전 트리와 변이는 grid 전체를 돌렸고, load 는 macOS 에서 4 에서 24, 리눅스에서 1 에서 6 이었다.

npm 에게 묻는 일이 명령의 코드를 돌리지 않는다는 것의 검증: lockless-forms 1e 절(CX)과 effect-trace-grid 1d 절의 PX1-PX4, UN1 행. CX 행은 열 가지 꼴을 판정한다. 꼴마다 거부되어야 하는 미승인 고정 spec 과 통과되어야 하는 승인 spec 이 하나씩 있다. 꼴은 가짜 npm 을 `PATH` 앞에 두거나(npm 앞, 글자 그대로든 아니든, export, env(1)), 그 경로로 적거나, `NODE_OPTIONS` 로 네 자리에서 모듈을 먼저 불러온다. 두 코드 모두 돌면 파일에 한 줄을 남긴다. 수리한 트리는 판정 20번 어디에도 줄을 남기지 않았다. 바꾸기 전 트리(3b4eee9)에 새 행을 붙이면 그중 16번이 질의마다 한 줄씩 세 줄을 남겼고, 거부와 통과가 같았다. 줄이 없던 넷은 `$PATH` 꼴이다. 값이 실행할 때 정해져서 옛 질의가 아예 돌리지 않았다. 변이 둘은 기대한 곳에서만 실패했다. 코드 이름과 훅 자신의 `PATH` 를 둘 다 빼면(A2) 글자 그대로의 `PATH` 꼴 셋과 `NODE_OPTIONS` 꼴 넷이 실패했다(판정 14번). 경로로 적은 npm 은 거기서도 깨끗하다. pre-guard 가 더는 npm 단어를 질의에 넘기지 않기 때문이다. 코드 이름만 빼면(A) `NODE_OPTIONS` 꼴만 실패했다(판정 8번). 질의 끝에 붙는 훅의 `PATH` 가 혼자서 `PATH` 꼴을 막는다. lockless-forms 는 macOS(bash 3.2.57, node v26.7.0, npm 11.19.0)에서 돌았다. 수리본은 두 기계에서 24 ok 로 367s(load 7.4–11.0), 391s(load 8.7–13.2)에 통과했고, 대조와 변이는 load 5–10 에서 돌았다. Linux(Debian 13, bash 5.2.37, node v20.20.2, npm 10.8.2)에서는 수리본이 24 ok 로 426s 에 통과했고, 대조는 같은 판정 16번, A2 는 같은 14번에 줄을 남겼다(load 0.9–2.6). grid 에서 PX1(`export PATH="<dir>:$PATH" && npm ci`), PX2(npm 앞의 같은 것), PX3(`NODE_OPTIONS=--max-old-space-size=4096 npm ci`)은 첫 명령에서 아무것도 rebuild 하지 않고 이유를 말하며 기록과 관측 해시를 그대로 두고, 다음 평범한 설치가 rebuild 한다. PX4 는 export 한 `PATH` 옆에 사칭 registry 를 적고 기록된다. UN1 은 샌드박스의 `npm_config_userconfig` 를 unset 하고 기록된다. 수리한 트리는 macOS(bash 3.2.57, node v26.7.0, npm 11.19.0; 694s, load 1.7–8.7)와 Linux(Debian 13, bash 5.2.37, node v20.20.2, npm 10.8.2; 823s, load 0.9–1.8)에서 grid 전체를 실패 0 으로 통과했다. macOS 에서 바꾸기 전 트리에 새 행을 붙이면 기대 16개가 실패했다. PX1 과 PX2 각 4(기록되고 다음 설치가 rebuild 되지 않음), PX3 3(옛 질의가 `NODE_OPTIONS` 를 실어 첫 명령이 rebuild 함), PX4 1(모름으로 기록되어 경고가 registry 를 이름 대지 않음), UN1 4(두 명령 모두 사칭의 스크립트 셋이 돎)다. pre-guard 가 코드 이름을 보통 이름으로 읽고 질의는 여전히 그것을 빼면(B) PX1-PX4 만 실패했다(12, load 8–16). 첫 macOS 기계에서 smoke(54 ok), install-dir-differential(1 ok), scan-contract(43 ok)가 통과했다. Linux 에서는 smoke(54 ok), consumer-forms(61 ok)가 통과했고, quick census 는 weakened·mislabeled·after-gate·pending-on-deny 를 0 으로 셌다(load 0.9–2.6). e2e 는 첫 macOS 기계에서 검사 하나("post hook keeps verified inert rebuild success quiet")가 3b4eee9 에서도 실패하고, 원인은 모른다.

### 롤백은 패키지 매니저를 부르지 않는다

롤백은 예전에 `node_modules` 재설치로 끝났다. 복원한 lockfile 이 있으면 `npm ci`, 없으면 `rm -rf node_modules && npm install` 이었다. 워크트리 구성 중에는 프로젝트의 `node_modules` 를 다른 체크아웃의 것에 링크해 두는 것이 있고, `npm ci` 는 설치 전에 `node_modules` 가 가리키는 곳을 비운다. 그런 워크트리에서 롤백이 다른 체크아웃의 패키지를 지웠다.

재설치에 가드를 다는 것으로는 닫히지 않았다. 리뷰가 실제 npm 으로 세 라운드마다 새 길을 찾았다. `package.json` 이 없는 디렉터리에서 상위 프로젝트로 올라가는 것, 링크인 lockfile 을 대체 설치가 링크 너머로 저장하는 것, 프로젝트 밖에 있는 워크스페이스, 그리고 bin 링크가 자기 디렉터리에서 다시 쓰이는 `file:` 의존성이다. 원인은 매번 같았다. 손이 어디로 갈지는 npm 이 정하는데, 게이트가 그것을 예측하고 있었다.

그래서 롤백은 이제 npm 을 부르지 않는다:

- 스냅샷으로 뜬 lock·manifest 파일을 복원하고, 프로젝트 자신의 `node_modules` 가 실제 디렉터리면 지운다. 실제 디렉터리를 지우면 그 안의 링크가 지워질 뿐, 링크가 가리키는 것은 지워지지 않는다.
- 대상이 심볼릭 링크면 거부하고 이름을 남긴다. 메시지와 `reorg.log`(`REORG REFUSED`)가 어느 단계를 거부했는지와 링크가 어디로 가는지를 물리 경로로 말한다. 롤백은 나머지 단계를 계속한다.
- `node_modules` 는 명령이 프로젝트의 node 트리에 쓴 것이 보일 때만 지운다. 설치 흔적이 있거나, node 매니페스트·lockfile 이 명령 직전에 뜬 스냅샷과 다르거나, `node_modules` 에 그 스냅샷에 없던 패키지·바이너리가 있거나 그보다 새로울 때다. closure 는 명령이 바꿨든 아니든 판정되므로, 설치로 잘못 읽힌 명령이 closure 가 한 번도 승인되지 않은 프로젝트에서 되돌릴 것 없는 롤백에 이르렀고, 지우기가 프로젝트의 의존성을 함께 가져갔다. 롤백이 돌리던 재설치가 그것을 가리고 있었다. 시각은 `find -newer` 로 비교한다. bash 3.2 의 `-nt` 는 초 단위라, 패키지를 제자리에서 바꾼 실제 `npm ci` 가 스냅샷을 뜬 그 초 안에 끝났기 때문이다.
- 재설치는 다음 설치가 하고, 그 설치는 다른 설치처럼 게이트를 지난다.
- 메시지는 롤백이 무엇을 했는지와 지금 파일이 어떤 상태인지를 말하고, 명령은 주지 않는다. 안내도 재설치와 같은 식으로 틀렸다. 리뷰 세 라운드가 매번 안내된 `npm ci` 가 밖에 닿는 꼴을 찾았고, 마지막은 워크스페이스 멤버에서였다. 거기서 맨 `npm ci` 는 워크스페이스 루트를 비운다. 중단된 롤백의 보고도 같은 규칙을 따른다.
- 모든 문장은 디스크에서 읽은 사실이거나 safedeps 가 적용한 규칙이다. `yarn.lock` 옆에서 말한 "lockfile 없음" 과, 실제 npm 이 제자리에 머문 곳에서 말한 "npm 이 상위 프로젝트에서 일할 것" 은 둘 다 사실에 예측을 덧붙인 문장이었고, 둘 다 틀렸다.

사용자에게 달라지는 것: 롤백 뒤 프로젝트에는 다음 설치 전까지 `node_modules` 가 없다. 검증된 무실행 설치 뒤의 rebuild 는 safedeps 가 여전히 npm 을 부르는 유일한 자리이고, 프로젝트 루트의 `package.json`·lockfile·`node_modules` 가 링크면 그 링크를 사유로 대고 건너뛴다.

### 롤백이 하는 말은 디스크에 대고 검사한다

롤백 메시지는 원래 산문이었다. 리뷰 세 라운드가 그 안에서 거짓 절을 찾았고, 모양은 매번 같았다. safedeps 가 검사를 돌리거나 무언가를 한 뒤에, 확인하지 않은 결과가 따라붙었다. 사람이 문장을 읽어서는 막히지 않았다. 셋째 라운드 뒤에도 판정이 거짓 절 여섯을 더 쟀다.

그래서 롤백, 거부된 단계, 끝나지 않은 롤백의 보고, 건너뛴 rebuild 는 이제 닫힌 줄 집합만 낸다. 줄마다 자기 검사를 돌린 함수가 내고, safedeps 가 한 일이나 그 검사가 찾은 것만 말한다. 파일을 복원했는지 못 했는지, 지웠는지 못 지웠는지, 링크가 가리키는 물리 경로와 함께 거부한 단계, 스냅숏이 확정본인지, 또는 "The rollback changed nothing." 이다. 복원이 실패하면 그렇다고 말하고 롤백은 계속 간다. 전에는 훅이 거기서 멈췄다.

검사는 코드가 아니라 출력에 건다. e2e 는 post 훅이 내는 모든 줄을 오라클에 넘기고, 어느 줄을 읽을지 행이 고르지 않는다. 어떤 형식에도 맞지 않는 줄은 실행을 실패시킨다. 줄마다 그 주장을 훅이 아닌 코드가 디스크에서 다시 검사한다. `reorg.log` 항목도 같은 문법으로 읽고, 아무것도 출력하지 않은 호출은 `reorg.log` 에 아무것도 덧붙이면 안 된다. 사본에서 돌린 변이 서른두 개가 각각 오라클에서 빨강을 낸다.

`--ignore-scripts` 줄은 명령이 무엇을 실었는지가 아니라 safedeps 가 한 일을 말한다. 줄은 셋 중 하나다.

- "safedeps added --ignore-scripts to this install"
- "safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote"
- "safedeps did not add --ignore-scripts to this install"

명령에서 플래그를 읽는 방식은 리뷰에서 세 번 틀렸고, 매번 훅과 오라클이 함께 틀렸다. 둘이 셸 문장의 모델 하나를 같이 썼기 때문이다. 이제 pre-guard 가 자기가 쓴 명령을 기록하고, 줄은 버전 2 기록이 밝힌 사실에서만 나온다. v2.17.2 기록, 없는 기록, post 훅이 읽지 못하는 기록에는 줄이 없고, `advisory.log` 가 그 기록을 적는다.

post 훅이 쓸 수 없는 기록은 더 이상 훅을 끝내지 않는다. 스냅숏의 meta 파일이 없는 기록, 스냅숏을 가리키지 않는 기록, JSON 객체 하나가 아닌 기록은 전에는 아무 말 없이 훅을 끝냈고, 설치는 검증되지 않았다. 이제 훅은 `advisory.log` 에 한 줄을 남기고 명령을 백스톱으로 보낸다. 확정 스냅숏은 늘 훅이 판정한 프로젝트의 해시로 고르고, 기록이 담은 해시로는 고르지 않는다.

경계 둘은 닫지 않고 적는다. 기록은 호출을 가리키지 않는다. 같은 명령의 두 호출이 한 디렉터리에서 겹치거나, 앞선 호출이 post 훅에 닿지 못했으면, post 훅이 다른 호출의 기록을 쓸 수 있다. Claude Code 에서는 실패한 도구 호출이 PostToolUse 에 닿지 않아서 실패한 설치가 기록을 남긴다. Codex 에서는 닿는다. 기록을 호출에 묶는 일은 v2.18.1 몫이다. 두 엔진은 두 훅에 같은 `tool_use_id` 를 보낸다(Claude Code 2.1.288, Codex 0.160.0 실측).

### 백스톱은 node 트리에 쓴 명령만 되돌린다

백스톱은 pre-guard 가 설치로 읽지 않았지만 글자가 설치처럼 보이는 명령을 판정한다. 전에는 closure 검사를 돌리고 실패하면 롤백했다. 그래서 `grep -n "npm install" README.md` 가, pull 이나 승인 만료로 게이트 밖에서 closure 가 미승인이 된 프로젝트를 되돌리고 `node_modules` 를 지웠다. 승인 만료 하나로도 충분했고 pull 은 필요 없었다.

이제 백스톱은 먼저 이 명령이 프로젝트의 node 트리에 썼는지 묻는다. 명령이 돌기 직전에 pre-guard 가 npm lockfile 두 개의 inode 와 변경 시각을, 링크는 대상까지 따라가서 기록하고, 기준 시각을 남긴다. post 훅은 inode 나 변경 시각이 기록과 다른 lockfile, 생기거나 사라진 lockfile, 기준 시각 뒤에 바뀐 `node_modules` 아래의 무엇이든(`find -H -cnewer`)을 흔적으로 친다. 흔적이 있으면 전처럼 롤백한다. 없으면 `advisory.log` 에 `BACKSTOP UNTRACED` 한 줄만 남긴다.

기록은 호출에 묶인다. 두 엔진은 PreToolUse 와 PostToolUse 에 같은 `tool_use_id` 를 보내고(Claude Code 2.1.288·2.1.289, Codex 0.160.0 실측), pre-guard 는 기록 이름을 그것으로 짓는다. 기록이 있는 호출은 다른 상태를 읽기 전에 자기 기록만으로 판정한다. 기록이 없는 호출은 흔적이 있는 것으로 치고, 이는 예전 동작이다. 검사가 판정하지 못하는 것도 같다. 기준 시각 파일이 없거나, 기록이 손상됐거나, `node_modules` 걷기가 실패하거나 5초 마감을 넘기는 경우다. 기준 시각은 파일시스템이 초 단위로만 기록할 때만 2초 앞당긴다. 어디서나 앞당겼더니 grep 0.3초 전의 pull 을 grep 의 쓰기로 셌다.

이 설계는 리뷰에서 세 번 반려된 뒤에 섰다. 매번 기록이 디스크를 말하지 않거나 그 호출의 것이 아니었다. 어디서나 앞당긴 기준 시각, 자기 기록 대신 가장 오래된 기록 읽기, 링크를 따라가지 않고 읽은 링크된 lockfile, 자기 기록보다 먼저 읽은 다른 호출의 설치 기록이다.

### inert 플래그는 npm 이 읽는 자리에 두고, 지켜졌다고 주장하지 않는다

Claude 에서 pre-guard 는 승인된 npm 설치에 `--ignore-scripts` 를 넣어, closure 를 검증하기 전에 설치의 수명주기 스크립트가 돌지 않게 한다. 전에는 명령 어디든 `--ignore-scripts` 글자가 보이면 넣지 않았다. 그래서 `npm install x --ignore-scripts=false` 와 `npm install x && echo --ignore-scripts` 는 스크립트가 켜진 채 기록도 없이 돌았다. 이제 npm 설치 문장마다 그 문장의 인자를 읽는다.

npm 은 같은 설정의 마지막 값을 쓴다. 그래서 동사 바로 뒤의 플래그는 뒤에 오는 `=false` 에 지고, 끝에 둔 플래그는 `--cache` 같은 꼬리 옵션의 값이 된다. pre-guard 는 플래그를 놓은 뒤 npm 10·11 의 규칙으로 문장을 다시 읽고, `ignore-scripts` 가 마지막이면서 참이고 명령의 다른 단어가 뜻을 지키는 첫 자리를 쓴다. 셸이 실행 때 정하는 단어가 있는 문장은 그렇게 읽을 수 없다. 그런 문장은 플래그를 두 자리에 받고, `advisory.log` 가 그 사실을 적는다.

모든 재작성은 릴리스 자신의 자리도 지킨다. 한 문장 명령이면 끝에, 복합 명령이면 동사 바로 뒤다. 재작성에서 safedeps 의 다른 플래그를 지우면 v2.17.2 가 쓴 것과 정확히 같고, 테스트의 모든 재작성을 v2.17.2 훅이 실제로 낸 출력 기록과 맞춰 본다. 스크립트 면에서 어떤 재작성도 릴리스보다 나쁘지 않다.

보고는 설치 스크립트가 돌지 않았다고 말하지 않는다. 플래그가 지켜지는지는 명령 글자에 드러나지 않는 셸 상태가 실행 때 정한다. 사용자 rc 파일을 담은 에이전트 셸 스냅숏의 함수와 alias, `.zshenv`, `BASH_ENV`, 명령이 정의한 alias 나 함수가 그렇다. 평범한 `npm install x` 도 이런 것을 거쳐 스크립트를 돌릴 수 있다. 그래서 보고는 safedeps 가 한 일("safedeps added --ignore-scripts to this install")을 말하고, safedeps 가 문장을 읽지 못한 곳에서만 경고를 붙인다. 이 설계에 닿기까지 리뷰 세 라운드가 걸렸다. 라운드마다 실행 때 정해지는 단어의 한 종류를 닫았고(`$(…)`, 그다음 `~` 와 중괄호, 그다음 셸 상태), 그것을 끝낸 판정이 결함은 자리가 아니라 주장이라는 것을 찾았다.

### 매니저 이름은 대소문자를 가리지 않고 읽는다

`PIP install x` 와 `Npm install x` 는 파일시스템이 대소문자를 가리지 않는 macOS 에서 돈다. v2.17.2 는 이것들을 막았는데, 통합 브랜치는 기록 없이 통과시키기 시작했었다. 이제 매니저 이름은 인식기가 이미 읽던 대로 대소문자를 가리지 않고 읽는다.

### Windows: overrides 조회가 드라이브 루트에서 끝난다 (#21)

npm `overrides` 조회는 프로젝트에서 위로 올라가다 `/` 나 `.git` 에서만 멈췄다. Git Bash 에서 `dirname C:` 은 `C:` 이므로, Git 레포 밖에서는 루프가 끝나지 않았고 훅은 타임아웃에 죽었으며 설치는 그대로 진행됐다. 이제 `dirname` 이 자기 입력을 돌려주는 곳에서 멈춘다. Yarn 쪽 탐색이 이미 쓰던 검사다. POSIX 에서는 같은 고정점이 `.` 이고, 함수 단위 시험이 두 형태를 모두 고정한다. Windows 는 여전히 CI 밖이고, Windows 동작의 근거는 보고서의 추적이다.

### UNGATED 는 효과 게이트가 실제로 있는지를 기준으로 한다 (#22)

버전 없는 설치의 기록은 원장 생태계가 npm 이면 생략됐다. pnpm·yarn·bun 은 그 생태계를 공유하지만 효과 게이트가 읽는 `package-lock.json` 은 쓰지 않으므로, 버전 없는 `pnpm add x` 는 흔적을 남기지 않았다. 이제 면제 기준은 "효과 게이트가 결과를 읽는가", 즉 npm CLI 가 프로젝트 안에 하는 설치다. pnpm·yarn·bun, `npm i -g`, `--no-package-lock`, 패키지를 받아 오는 실행기는 기록되고, 프로젝트에 이미 있는 바이너리를 실행하는 실행기(`npx tsc`)는 받아 오는 게 없으므로 조용하다. 추출기가 spec 을 낸 패키지만 고정된 것으로 치고, 그 대조는 생태계와 이름을 함께 쓴다. 그래서 한 패키지는 고정하고 다른 패키지는 고정하지 않은 명령도, 한 생태계에서 고정한 이름을 다른 생태계에서 버전 없이 설치하는 명령도 기록된다.

### 빨라진 것

- **커맨드 스캐너가 선형이다.** 명령 길이의 제곱으로 느는 bash 문자 루프였다. v2.17.2 는 32KB 에서 스캔만 36.2초를 써서 30초 훅 예산을 넘겼다. 릴리스 트리에서 스캔만은 macOS(bash 3.2, BSD `awk`)에서 8KB 0.05초, 32KB 0.12초, 64KB 0.21초이고, Linux(bash 5.2, `mawk`)에서 0.02초, 0.05초, 0.08초다. 가드의 나머지는 아직 어디서나 선형이지는 않다. 데드라인을 끄면 설치 문구 없는 명령의 게이트 전체 비용이 같은 크기에서 Linux 는 0.25초, 0.47초, 0.82초지만 macOS 는 0.56초, 4.1초, 14.4초다. 64KB 까지는 20초 자체 예산 안이고, macOS 에서 더 큰 명령은 예산에 닿아 `UNDECIDED` 로 답한다.
- **설치가 든 명령이 더는 제곱으로 늘지 않는다.** "이 문장이 비었나" 를 보는 여섯 곳이 bash 패턴 치환을 썼고, 훅이 도는 macOS `/bin/bash` 3.2 에서 이 치환은 텍스트보다 훨씬 빨리 늘었다(2,000바이트 한 번에 4.99초). 통합 트리에서 npm 설치가 든 4KB 명령이 수리 전 43초, 수리 뒤 1초였다. 데드라인을 끄고 재면 설치가 든 명령은 Linux 에서 8KB 1.4초, 32KB 2.3초, 64KB 3.6초이고, macOS 에서 2.2초, 10.5초, 37.5초다. 20초 자체 예산을 넘으면 런타임이 죽이기 한참 전에 가드가 `UNDECIDED` 로 답하고, macOS 에서는 32KB 와 64KB 사이에서 그렇게 된다.

이 숫자는 릴리스 트리에서 돌린 `scripts/measure/scan-cost.sh --reps 3`(2026-10-04, 세 번 중 가장 좋은 값)이다. macOS 는 M1 MacBook(부하 1.1–4.6), Linux 는 프로젝트의 Debian VM(부하 0.8–0.9)이다. 다른 장비나 다른 트리의 숫자는 이 숫자가 아니다.

### 리눅스와 CI

ubuntu CI 작업은 2026-08-04 부터 빨간색이었고 macOS 작업은 초록이었다. 그래서 리눅스에서만 나는 결함 넷이 첫 결함 뒤에 숨어 있었다.

- self-budget 배터리는 스캔이 얼마나 느린지로 입력 크기를 정했는데, 선형 스캐너와 더 빠른 러너가 둘 다 그 전제를 무너뜨렸다. 이제 `PATH` 맨 앞에 둔 `awk` 로 판정을 붙잡고, 가드를 `TERM` 이 무시된 상태로 띄워 `KILL` 격상만 제때 답할 수 있게 한다. 배터리가 그 격상을 한 번도 시험하지 않은 채 통과해 왔다는 사실은 변이로 찾았다.
- 리눅스는 128KB 를 넘는 환경 문자열 하나를 거부하므로, 50만 자 예산 케이스는 가드를 띄우지도 못했고 하네스는 그 실행 실패를 `pass` 로 읽었다.
- advisory 로그의 오래된 잠금 검사가 BSD `stat -f` 를 먼저 물었다. 리눅스에서는 이것이 파일시스템 정보를 찍고 0 으로 끝나며, 그 뒤 산술식이 `set -u` 에서 죽었다.
- 원장 색인은 원장 파일 하나가 깨져 있으면 파일시스템의 디렉터리 순서에 따라 항목을 두 번 찍었다.

### 이 릴리즈에 함께 들어간 것

- **advisory 로그 크기를 압축으로 제한한다.** 더는 끝없이 자라지 않는다. `re-check` 가 진짜 승인과 위조를 가르려고 읽는 증거 줄은 온전히 남기고, 추적 줄은 보관한 뒤 정리한다.
- **전역 npm 승인이 프로젝트와 무관하다.** 세션이 `overrides` 가 있는 프로젝트에 있다는 이유로 승인된 전역 설치가 거부되지 않는다.

### v2.18.1 로 미룬 것

리뷰가 찾은 것이 한 릴리스가 닫을 수 있는 양을 넘었다. 아래는 서둘러 닫지 않고 적어 둔다.

- **렉서에서 명령이 시작하는 자리.** 예약어나 `!` 에 리다이렉트를 거쳐 붙은 명령(`if true; then>/dev/null pip install …`), zsh 의 `&!`, 셸로 읽은 `env -S` 문자열은 아직 명령으로 읽지 않는다. 모두 이번 릴리스 전부터 있던 것이고, 리뷰가 요구한 설계 판정은 v2.18.1 이 한다.
- **호출에 묶인 기록.** 설치 기록은 디렉터리와 명령으로 찾는다. 그래서 같은 명령의 두 호출이 겹치면 서로의 기록을 쓸 수 있고, 키가 맞지 않는 백스톱 항목은 그 호출을 기록 쪽으로 보낸다. 두 엔진은 두 훅에 같은 `tool_use_id` 를 보내고, v2.18.1 은 모든 기록을 그것으로 묶는다.
- **실패한 도구 호출.** Claude Code 는 실패한 호출에 PostToolUse 가 아니라 PostToolUseFailure 를 부르는데, safedeps 는 그것을 등록하지 않는다. 그래서 실패한 설치는 검증되지 않고 기록을 남긴다.
- **셸에 넘긴 스크립트 안의 대소문자 다른 npm.** `npm install x; sh -c "… && NPM ci"` 에서 보이는 설치는 플래그를 받고, 숨은 `NPM ci` 는 v2.17.2·main 처럼 기록 없이 스크립트를 돌린다. 지금 그 이름을 대소문자 무시로 읽으면 보이는 설치의 재작성까지 빠지므로, 둘을 다 지키는 배치 설계를 기다린다. 다른 명령에 파이프로 넘기는 heredoc 본문의 설치 문구(`npm install x && cat <<E | wc -l`)도 같다. 본문에 소문자 `npm install` 이 있으면 보이는 설치는 v2.17.2 처럼 플래그를 받지 못하고, main 은 플래그를 준다.
- **Codex 레지스트리 경고**는 엔진과 상관없이 "did not add" 뒤에 "(on Codex it cannot)" 을 붙인다.

### 검증

VERIFICATION_PARAGRAPH

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
