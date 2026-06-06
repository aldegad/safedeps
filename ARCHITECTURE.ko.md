# Safedeps 아키텍처

> 내부 설계와 런타임 흐름. 사용자 설치 가이드는 [`README.md`](./README.md), 스킬 매니페스트와 hook 선언은 [`SKILL.md`](./SKILL.md) 에 있다. *(English → [ARCHITECTURE.md](./ARCHITECTURE.md), SSoT)*
>
> **이름** — v1 시절 `npm-reorg-guard` 로 출시됐다. v2 에서 ecosystem 통합 + advisory ledger 를 도입하며 제품/CLI 이름을 **`safedeps`** 로 rename 했다. post-install rollback engine 은 v1 의 `reorg-guard` 설계를 그대로 계승하고, npm 에서는 PostToolUse effect gate 가 primary enforcement surface 다.

---

## 핵심 아이디어

> Safedeps 는 install 순간에 여러 라이브 truth 를 동시에 조회해 결정하지 않는다. provider evidence 로 안전한 dependency closure 를 *먼저* 승인하고, 그다음 post-install hook 이 실제 lockfile closure 를 권위로 삼는다. 미승인이거나 새로 취약해진 effect 는 reorg 가 롤백한다.

승인은 install **전**에 canonical advisory evidence 로, enforcement 는 install **후**에 디스크에 실제로 깔린 것으로 한다. npm 은 전체 closure(direct + transitive)를 OSV `/v1/querybatch` 로 검사하며 `pkg@version` 당 24시간 캐시를 둔다. 다른 ecosystem 의 closure 해석은 후속 작업이다.

---

## 1. 두 lane, 하나의 우산

safedeps 는 **두 시점**의 보안 게이트를 한 스킬 아래 소유한다. v1 `npm-reorg-guard`(install-time reorg)를 흡수한 데 이어 `security-release-gates`(release-time 검사, 2026-05-24)도 흡수했다. "보안"이라는 큰 이름으로 한 파일에 다 몰아넣는 게 아니라, **게이트의 canonical owner 를 하나로** 두되 lane 별 책임을 분리한다 (SRP).

```text
┌──────────────────────────────────────────────────────────────────────┐
│                  safedeps — 하나의 보안 우산                          │
│                                                                      │
│   INSTALL-TIME lane                    RELEASE-TIME lane              │
│   (개발 중 · 패키지 설치 시점)            (릴리스 · 배포 직전)            │
│   ─────────────────────                ──────────────────            │
│   advisory check  (npm: OSV batch)     safedeps scan secrets         │
│   fast command gate (PreToolUse)       safedeps audit deps           │
│   npm effect gate  (PostToolUse)       safedeps hooks install|check  │
│                                        safedeps git pre-commit       │
│   범위: 설치하려는 그 패키지              범위: repo 전체 트리            │
│                                        (security-release-gates 흡수)  │
│                                                                      │
│   공통: 공개 DB(OSV/KEV/GHSA) · 로컬 first · no silent fallback        │
│   (provider/scanner miss 는 fail-closed)                             │
└──────────────────────────────────────────────────────────────────────┘
```

- **Install-time lane** (아래 section 2–13) — advisory check, fast command guard, npm effect gate + reorg. per-package, proactive.
- **Release-time lane** — `security-release-gates` 의 repo-tree 검사(secret scan, dependency audit, repo hook install/check, privacy profile)를 `safedeps scan|audit|hooks|doctor` namespace 로 흡수. repo-specific policy(`.gitleaks.toml`, lockfile)는 대상 repo 에 남고, safedeps 가 실행·설치·검증 owner.

두 lane 은 시점·범위가 다르다(설치 전후 개별 패키지 effect vs 릴리스 전 repo 전체). 한 우산 아래 두되 command namespace 로 분리해 SRP 를 지킨다.

**release-time lane 의 secret 누출 쪽은 repo 별이고 opt-in 이다.** 탐지 policy 가 safedeps 가 아니라 대상 repo 에 있어서, repo 가 `.gitleaks` config 와 활성 `.githooks/pre-commit` 을 제공하기 전까지는 아무 것도 하지 않는다. `safedeps doctor` 가 그 빈틈을 메우는 repo-entry 진단이다: secret 누출 lane 의 각 조각(`.gitleaks` policy, `pre-commit`, `core.hooksPath`, scanner 가용성)과 전역 install-time gate 를 함께 보고하고, repo 별 lane 에 gap 이 있으면 non-zero 로 끝난다. `safedeps doctor --fix`(= `safedeps hooks init` 후 `safedeps hooks install`)가 `lib/gates/templates/` 의 시작 policy 를 scaffold 하고 hook 을 활성화한다. scaffold 는 **비파괴적**이라 repo 가 소유한 기존 config 를 덮지 않으며, "safedeps 는 *실행*을 소유하고 *policy* 는 소유하지 않는다"는 불변식을 지킨다. scaffold 된 `pre-commit` 은 두 검사를 돌린다. 비밀키 스캔(`safedeps scan secrets --staged`)은 매 커밋 돌고 fail-closed 다: safedeps 미해석이나 scanner 부재 시 silent skip 이 아니라 커밋을 막는다. npm 의존성 audit(`safedeps audit npm`)도 npm lockfile 이 있는 repo 면 매 커밋 돈다 — lockfile 이 바뀔 때만이 아니라 — 그래서 패키지를 깐 *뒤에* 공개된 CVE 가 어드바이저리 DB 재조회로 다음 커밋에 잡힌다. audit 은 보안 판정과 가용성 실패를 의미 있는 exit code 로 구분한다(0 clean / 1 취약 / 2 못 돌림): 실제 취약점은 **차단**(fail-closed)하고, 어드바이저리 DB 도달 불가 시에는 hook 이 **경고하고 커밋을 통과**시킨다 — 명시적이고 관측 가능한 가용성 failover(no-silent-fallback 불변식대로: 커밋 출력에 남고 canonical truth 를 바꾸지 않음)이며, 오프라인 커밋이 못 본 건 CI 와 데일리 re-check 가 다시 메운다.

**effect-primary 모델은 npm 한정이다.** `pip`, `cargo`, `go`, `gem`, `maven`, `nuget` 은 closure resolver 가 붙기 전까지 v2.1 command-gate + reorg 모델을 유지하며, PostToolUse closure 권위로 서술하지 않는다.

### Install-time 흐름

```
   intent ("이 패키지 설치하고 싶다")
      │
      ▼
   ┌─────────────┐     OSV.dev  ──canonical──►
   │ safedeps    │     CISA KEV ──hard-risk──►   advisory check
   │   check     │     GHSA     ──enrichment─►   (Phase 1)
   └──────┬──────┘
          │  approve
          ▼
   ┌──────────────────────┐
   │ approved-spec ledger │   ~/.safedeps/approved-specs/<hash>.json
   │ ecosystem · pkg@ver  │   + transitive_specs (npm closure)
   │ approved_at/expires  │
   └──────────────────────┘
          │
          ▼
   install 명령 발행 ──► PreToolUse hook (fast command guard, Phase 2)
                            │  ledger 일치?  ── miss ──► BLOCK + "먼저 safedeps check"
                            │  match ──► 실행
                            ▼
                        install 실행
                            │
                            ▼
                        PostToolUse hook (npm effect gate, Phase 3)
                            │  lockfile closure vs ledger + OSV batch
                            ├─ 승인 & clean ──► CONFIRM (새 안전 baseline)
                            └─ 미승인 / 취약 ──► REORG (마지막 confirmed 로 롤백)
```

- **Phase 1 — advisory check.** npm 은 temp dir 에서 `npm install <pkg>@<version> --package-lock-only --ignore-scripts` 로 스크립트 실행 없는 lockfile 을 만들어 전체 closure 를 뽑고, direct/transitive 를 OSV `/v1/querybatch` 로 묶어 조회한다. clean 이면 direct ledger entry 에 `transitive_specs` 를 기록한다.
- **Phase 2 — fast command gate.** PreToolUse hook 이 명령을 파싱해 명백한 미승인 install 을 막고 의존성 파일을 snapshot 한다. 에이전트에게 즉시 피드백을 주는 best-effort advisory layer 이며 최종 권위가 아니다. Claude Code 에서는 npm install 에 `--ignore-scripts` 를 붙여 rewrite(hook `updatedInput` 기능)하므로, 설치가 무실행으로 돌고 effect gate 가 closure 를 검증할 때까지 lifecycle script 가 안 돈다.
- **Phase 3 — npm primary effect gate.** PostToolUse hook 이 실제 `package-lock.json` closure 를 ledger 의 direct entry + `transitive_specs` 와 대조하고 OSV batch 로 재조회한다. 미승인·취약 패키지가 있으면 마지막 confirmed snapshot 으로 reorg 한다. 이 권위는 npm closure 한정이다.

---

## 2. Advisory source — canonical truth 하나

```
TIER 1 — PRIMARY (canonical truth)
  OSV.dev
    • multi-ecosystem (npm, pip, cargo, go, gem, maven, nuget, …)
    • package@version 질의 표준화 · 무료 JSON API (Google)
    • GHSA, RustSec, GoVulnDB 등 aggregate
    → 모든 advisory 의 1차 query target

TIER 2 — OVERLAY (hard-risk signal)
  CISA KEV (Known Exploited Vulnerabilities)
    • "실제 야생에서 exploit 확인" 만 추림
    • OSV 결과와 cross-reference; KEV 매치는 hard block (override 불가)
    → 일반 CVE 와 급박한 CVE 의 구분선

TIER 3 — ENRICHMENT / CROSS-CHECK
  GHSA      — 개발자 친화 patched-version metadata; OSV 와 다를 때만 surface
  NVD       — CVE 원본, CVSS 점수, KEV flag (점수 기반 우선순위)
  deps.dev  — OSV 기반 package graph metadata (transitive 위험)
  Snyk DB   — configured optional feed 만 (무료 quota 한도)
```

설계 원칙: **canonical truth 는 OSV 하나.** 나머지는 overlay 또는 enrichment. 여러 라이브 source 를 동급 진실로 두면 cross-fire 가 난다 — OSV 를 truth 로 두고 KEV/GHSA/NVD/deps.dev 는 OSV 와 다르거나 OSV 가 못 본 신호만 surface 한다.

---

## 3. Approved-spec ledger (SSoT)

`~/.safedeps/approved-specs/<hash>.json`:

```json
{
  "hash": "sha256:abc123…",
  "ecosystem": "npm",
  "package": "@jackwener/opencli",
  "version": "1.7.16",
  "version_range": "^1.7.16",
  "approved_at": "2026-05-18T13:00:00Z",
  "expires_at": "2026-06-18T13:00:00Z",
  "approved_by": "user@example.com",
  "evidence": {
    "closure_checked": true,
    "provider": { "type": "osv-querybatch", "results": [] },
    "closure": []
  },
  "transitive_specs": [
    { "ecosystem": "npm", "package": "…", "version": "…" }
  ]
}
```

핵심 필드:

- `hash` — `(ecosystem, package, version)` 의 deterministic hash. hook 이 명령에서 같은 hash 를 뽑아 ledger 를 조회한다.
- `approved_at` / `expires_at` — lifecycle TTL, 기본 30일. 만료 후엔 새 CVE 가능성이 있어 자동 revoke + re-check 강제.
- `evidence` — 승인 시점에 어느 source 가 무엇을 봤는지. audit trail.
- `transitive_specs` — direct entry 가 승인한 전체 transitive closure. npm effect gate 는 lockfile 에 있으면서 direct entry 에도 이 배열에도 없는 `pkg@version` 을 reorg 한다.

Lifecycle:

```
approve            install            confirm              re-check (daily)
───────            ───────            ───────              ────────────────
ledger 신규    ──►  hook 통과     ──►  post-verify 일치   ──►  OSV 재조회
approved_at=now    spec 일치          confirmed = true          │
expires_at=+30d                                                 ▼
                                                    여전히 clean ──► expiry 연장
                                                    새 CVE       ──► revoke + 경고 (+ 옵션 reorg)
```

---

## 4. 런타임 흐름 상세

### Phase 1 — `safedeps check <ecosystem> <pkg>@<range>`

```
safedeps check npm "@jackwener/opencli@^1.7.0"
        │
        ├─► ledger 조회 ── hit (valid) ──► "이미 안전, install 해도 됨"
        │                └ miss/expired ──► check 진행
        ▼
   range → concrete version(s) 해석
        │
        ▼
   OSV query  ──►  KEV overlay  ──►  GHSA cross-check
        │
        ▼
   분류:
     • clean              → approve
     • patched available  → approve, 안전 버전으로 spec 재작성 (^1.7.0 → ^1.7.16)
     • KEV hit            → HARD BLOCK ("실제 exploit 됨, 설치 X")
     • CVE, patch 없음     → WARN (사용자 결정 필요)
        │
        ▼
   approved-spec ledger 신규 entry 작성
```

npm 은 "OSV query" 가 **전체 resolved closure** 를 `/v1/querybatch` 한 번으로 돌고, 승인 entry 가 모든 transitive 를 `transitive_specs` 에 기록한다.

### Phase 2 — fast command guard (PreToolUse / `safedeps-pre-guard.sh`)

```
Claude: npm install @jackwener/opencli@^1.7.16
        │
        ▼
   명령 파싱 → ecosystem, package, version_range
   spec hash 계산 → ledger 조회
        │
        ├─ hit (approved, not expired) ──► PASS (명령 실행)
        └─ miss / expired ──────────────► BLOCK + "먼저 `safedeps check …`, 그다음 재시도"
```

guard 는 lockfile/manifest 도 snapshot 하고 v1 hardcoded pattern 차단(section 5)도 유지한다. 빠르고 advisory 일 뿐, 권위는 post gate 다.

### Phase 3 — npm primary effect gate + reorg (PostToolUse / `safedeps-post-verify.sh`)

```
install 완료 → safedeps-post-verify.sh
        │
        ▼
   실제 package-lock.json closure 읽기
   모든 pkg@version 을 ledger(direct entry + transitive_specs)와 대조
   전체 closure 를 OSV batch 로 재조회
   install script + native binary 검사 (v1 reorg-guard 로직)
        │
        ├─ 전부 승인·clean·무의심 ──► CONFIRM (새 안전 baseline)
        └─ 미승인 / 취약 / 의심 ──► REORG:
                 • lockfile ← 마지막 confirmed snapshot
                 • rm -rf node_modules; ledger 와 일치하게 재설치
                 • reorg.log 기록; 에이전트에 경고
```

---

## 5. Threat model

```
ADVISORY CHECK (safedeps check)
  • 알려진 CVE 매칭 (OSV, multi-ecosystem)
  • KEV 매치 → hard block (사용자 override 불가)
  • patched available → 안전 버전으로 spec auto-rewrite
  • transitive vuln 을 ledger 에 기록해 sub-dependency 침해 감지

FAST COMMAND GUARD (safedeps-pre-guard.sh)
  v1 hardcoded pattern (defense-in-depth): typosquat 명단 · curl|bash pipe ·
  비표준 --registry · install-script safety disabling · eval/subshell indirection
  + 빠른 advisory ledger check: 미승인/expired spec → block + advisory-gate 안내

npm PRIMARY EFFECT GATE + REORG (safedeps-post-verify.sh)
  • install script 의 network / code-execution / sensitive-path 접근
  • base64 / hex obfuscation
  • 비표준 registry resolved URL · 50+ dependency explosion · native binary
  • npm lockfile closure 가 approved spec / transitive_specs 와 diverged → REORG
```

**Install-script 타이밍.** 패키지의 `postinstall` 은 `npm install` *도중에* 실행된다. Claude Code 에서는 Phase 2 hook 이 `--ignore-scripts` 를 주입하므로 설치가 무실행이고, effect gate 가 closure 를 confirm 한 뒤에야(`npm rebuild`) 스크립트가 돈다 — 거부된 패키지의 스크립트는 한 번도 안 돈다. Codex CLI 는 `updatedInput` 기능이 없어 install 이 정상 실행되고, 악성 install script 가 사후 reorg 전에 1회 실행될 수 있다. (패키지의 *런타임* 코드는 두 엔진 모두 네 앱 실행 전에 제거된다; install-time lifecycle script 만 Codex 에서 이 창이 있다.)

**막지 않는 것 (현재 한계):**

- `approved_at` 이후 발견된 zero-day — daily re-check 로만 잡고, install 시점엔 못 잡는다.
- npm registry 자체의 손상.
- 사용자가 `--allow-unverified` 로 명시 우회한 경우 (observable, 로그됨).
- 같은 OS 사용자 권한으로 `~/.safedeps/approved-specs/` 를 직접 작성/수정하는 공격. ledger 는 로컬 convenience cache 이며, 서명/HMAC 또는 install-time 재조회가 도입되기 전엔 same-user 공격의 보안 경계가 아니다. (단 effect gate 의 OSV 재조회는 *알려진 취약* 패키지에 대한 위조 승인은 여전히 잡는다 — [`ROADMAP.md`](./ROADMAP.md) "Ledger 변조 내성" 참고.)

---

## 6. Provider 실패 모드 (no silent fallback)

```
OSV.dev — 응답 무 / timeout
  • 1차: 로컬 provider cache (24h TTL) 사용
  • cache miss → fail-closed (block; "OSV 응답 없음, 재시도")
  • explicit --allow-unverified 일 때만 우회, 로그됨

CISA KEV — 응답 무
  • KEV 는 하루 1회 download 하는 정적 catalog; 로컬 cache 만 사용
  • 24h 이상 stale 이면 경고

GHSA / NVD — 응답 무
  • enrichment 라 fail-open 허용
  • OSV 결과로만 진행 + "GHSA cross-check skipped" 로그
```

설계 원칙: **silent fallback 금지.** 모든 우회는 observable + 로그. canonical truth(OSV)가 응답 못 하면 default 는 fail-closed.

---

## 7. State layout — `~/.safedeps/`

```
~/.safedeps/
├── approved-specs/            ← ledger SSoT, (ecosystem, package, version) 당 JSON 한 개
│   ├── sha256-abc123.json
│   └── …
├── snapshots/                 ← reorg snapshot (v1 계승, 전 lockfile 로 확장)
│   └── <id>/ { package-lock.json, yarn.lock, pnpm-lock.yaml, poetry.lock, uv.lock,
│               Cargo.lock, go.sum, Gemfile.lock, meta.json }
├── confirmed_${dir_hash}      ← 프로젝트별 마지막 confirmed snapshot
├── cache/
│   ├── osv/                   ← OSV query 응답 (24h TTL)
│   └── kev/                   ← CISA KEV daily catalog
├── locks/                     ← atomic state (TOCTOU 방지)
├── reorg.log                  ← reorg event (append-only)
└── advisory.log               ← advisory-gate 결정 (approve / block)
```

- `approved-specs/` 는 ledger SSoT, spec 당 atomic JSON write.
- `snapshots/` 는 v1 설계 + Python/Rust/Go/Ruby lockfile 추가.
- `cache/osv/`, `cache/kev/` 는 provider 응답을 TTL 로 보관.
- `advisory.log` 는 모든 approve/block 결정의 audit trail.

---

## 8. Multi-ecosystem 지원

| Ecosystem | Manifest | Lockfile | `safedeps check` |
|---|---|---|---|
| npm | `package.json` | `package-lock.json` | `safedeps check npm <pkg>@<range>` |
| yarn | `package.json` | `yarn.lock` | `safedeps check npm <pkg>@<range>` |
| pnpm | `package.json` | `pnpm-lock.yaml` | `safedeps check npm <pkg>@<range>` |
| pip (Poetry) | `pyproject.toml` | `poetry.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (uv) | `pyproject.toml` | `uv.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (Pipenv) | `Pipfile` | `Pipfile.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (raw) | `requirements.txt` | (약함) | `safedeps check pypi <pkg>@<range>` |
| cargo | `Cargo.toml` | `Cargo.lock` | `safedeps check crates.io <pkg>@<range>` |
| go | `go.mod` | `go.sum` | `safedeps check go <pkg>@<range>` |
| ruby | `Gemfile` | `Gemfile.lock` | `safedeps check rubygems <pkg>@<range>` |
| maven | `pom.xml` | (디렉토리) | `safedeps check maven <group>:<artifact>@<range>` |
| nuget | `*.csproj` | `packages.lock.json` | `safedeps check nuget <pkg>@<range>` |

OSV 가 ecosystem 이름을 정규화해줘서 advisory-check 시점엔 single API 로 전부 cover 한다. ecosystem 별 typosquat 명단·install-script 위험 패턴은 별도 정적 list 다. npm effect gate(closure-vs-ledger enforcement)는 현재 npm 한정이고, 나머지는 command-gate + reorg 모델을 쓴다.

---

## 9. 컴포넌트 책임 분리 (SoC)

| 컴포넌트 | 책임 |
|---|---|
| `SKILL.md` | Claude/Codex skill loader 가 읽는 SSoT — hook 선언 + advisory-gate 사용법. |
| `README.md` | 사용자 install 가이드. |
| `ARCHITECTURE.md` | 이 문서 — 내부 흐름·설계. |
| `bin/safedeps` | CLI entry — advisory check, ledger 관리, re-check, migrate. |
| `scripts/safedeps-pre-guard.sh` | PreToolUse hook — ledger 일치 + v1 hardcoded pattern + snapshot. |
| `scripts/safedeps-post-verify.sh` | PostToolUse hook — closure-vs-ledger effect gate + reorg. |
| `lib/providers/` | OSV / KEV / GHSA (옵션 NVD / deps.dev / Snyk) adapter, 단일 query interface. |
| `lib/ledger/` | approved-spec ledger I/O — atomic write, hashing, TTL 검사. |
| `lib/npm/closure.sh` | lockfile 에서 npm closure 해석. |
| `lib/gates/` | release-time repo lane — `scan.sh`(gitleaks runner), `audit.sh`(npm lockfile audit), `hooks.sh`(`install`/`check`/`init`), `doctor.sh`(자세 진단 + `--fix`), `repo-profile.sh`(public/private 판별). *실행*을 소유하고 *policy* 는 repo 가 소유. |
| `lib/gates/templates/` | 시작용 `.gitleaks[.private].toml` + `.githooks/pre-commit`, `hooks init` 가 scaffold. repo 가 소유·튜닝하는 seed — 재실행 시 덮지 않음. |

---

## 10. 기존 도구와의 차이

| 도구 | 결 | 시점 | safedeps 와 차이 |
|---|---|---|---|
| `npm audit` | materialized lock 기반 취약점 보고 | post-install | 보고만, spec 결정/차단 없음 |
| `pip-audit` / `cargo audit` / `bundler-audit` | 같은 결, 다른 ecosystem | post-install | 같음 |
| socket.dev | SaaS risk intelligence (behavioral + static) | pre/post-install | 클라우드 의존, 무료 quota 한도, 외부 SaaS |
| lavamoat | runtime permission sandbox | runtime | install 전 차단 X, dev 단계 부담 |
| pnpm `onlyBuiltDependencies` | lifecycle script allowlist | install | typosquat/vuln DB X, script 차단만 |
| deps.dev | package graph metadata | query only | 데이터만, active gate 아님 |
| OSV-Scanner | lockfile 의 OSV 스캔 | post-install (CI) | spec gate X, lockfile 리포트만 |
| GitHub Dependabot | PR 기반 dep update | repo (PR) | local install 차단 X, PR 단계만 |
| **`safedeps`** | **advisory check + approved-spec ledger + npm effect gate + reorg** | **pre/install/post** | **closure 수준 enforcement, multi-ecosystem command guard, 로컬 first** |

요약: 다른 도구는 "보고" / "sandbox" / "script 차단" / "PR 권장" 중 하나에 집중한다. safedeps 는 advisory check → fast command guard → npm effect gate + reorg 를 defense-in-depth 로 쌓고, Snyk / socket.dev 와 달리 SaaS 의존 없이 로컬 CLI + 공개 DB(OSV/KEV/GHSA)만 쓴다.

---

## 11. 운영 로그

```bash
tail -f ~/.safedeps/advisory.log     # advisory-gate 결정 (approve / block)
tail -f ~/.safedeps/reorg.log        # reorg event
ls -lt ~/.safedeps/approved-specs/   # 현재 approved specs
jq '.evidence' ~/.safedeps/approved-specs/sha256-abc123.json   # 특정 spec 의 evidence
rm -rf ~/.safedeps/cache/osv/        # OSV cache 비우기 (강제 re-query)
```

---

## 12. Legacy / migration: v1 `npm-reorg-guard` → v2

| v1 (`npm-reorg-guard`) | v2 (`safedeps`) |
|---|---|
| `~/.npm-reorg-guard/` | `~/.safedeps/` |
| `~/.claude/skills/npm-reorg-guard/` | `~/.claude/skills/safedeps/` |
| `scripts/guard.sh` (pattern 매칭만) | `scripts/safedeps-pre-guard.sh` (+ ledger lookup, namespaced) |
| `scripts/verify.sh` (lockfile diff + reorg) | `scripts/safedeps-post-verify.sh` (+ approved-spec diff, namespaced) |
| — | `bin/safedeps` — 새 CLI (check / approve / revoke / re-check / ledger) |
| — | `lib/providers/`, `lib/ledger/` |
| GitHub `aldegad/npm-reorg-guard` | `aldegad/safedeps` (redirect only) |

마이그레이션:

- v1 hook path(`~/.claude/skills/npm-reorg-guard/scripts/*.sh`)는 canonical 이 아니다. settings 는 `~/.claude/skills/safedeps/scripts/*.sh` 를 가리킨다.
- `~/.npm-reorg-guard/` 디렉토리 발견 시 state 를 `~/.safedeps/` 로 마이그레이션한다 (snapshot chain 보존).
- v1 사용자는 `safedeps migrate` 한 번으로 ledger 생성 + 기존 confirmed snapshot 이전.

---

## 13. 한계와 미래 방향

**현재 한계:**

- `approved_at` 이후 발견된 zero-day 는 daily re-check 로만 잡는다.
- registry 자체(npm/PyPI/…) 손상은 막지 못한다.
- KEV 는 하루 1회 update — 그 사이 등재된 KEV 는 다음 refresh 까지 못 잡는다.
- transitive closure 검사는 ledger 를 수백 개로 키울 수 있어 최적화가 필요하다.

**미래 방향** ([`ROADMAP.md`](./ROADMAP.md) 참고):

- non-npm ecosystem 의 effect-기반 closure enforcement.
- Ledger 변조 내성 (OSV-as-authority + 변조 탐지; 로컬 서명 안 함).
- Plugin provider, `.safedeps.toml` policy file, CI mode, multi-machine ledger sync, 에이전트의 안전 대체 모듈 제안.
