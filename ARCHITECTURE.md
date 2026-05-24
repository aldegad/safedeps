# Safedeps Architecture (v2)

> **Note on naming**: 이 repo 는 v1 시절 `npm-reorg-guard` 로 출시됐다. v2 부터 ecosystem 통합 + advisory-first 게이트를 도입하면서 제품/CLI 이름을 **`safedeps`** 로 rename 한다. 내부 post-install rollback engine 은 v1 의 `reorg-guard` 컨셉을 그대로 계승. 이 문서는 v2 의 SSoT.

기능 분리:
- **README.md** — 사용자 설치/사용 가이드 (rename 후 갱신 예정)
- **SKILL.md** — 스킬 메타 + hook 선언 (Claude/Codex skill loader 가 읽는 SSoT)
- **ARCHITECTURE.md** — 내부 흐름·설계 (이 문서)

---

## 0. 핵심 한 문장 (코덱시 합의)

> *Safedeps does not decide at install time from multiple live truths.*
> *It approves one dependency spec from provider evidence first, then the hook only enforces that approved spec; reorg remains the rollback layer if the install result diverges.*

번역: Safedeps 는 install 순간에 여러 라이브 truth 를 동시에 조회해서 결정하지 않는다. **사전에 provider evidence 로 안전한 dependency spec 을 먼저 승인** (approve) 하고, **hook 은 그 승인된 spec 과 명령이 일치할 때만 통과**시킨다. **reorg 는 install 결과가 spec 과 어긋날 때의 rollback layer** 로 남는다.

---

## 1. 통합 보안 우산 — Two Lanes, One Umbrella

safedeps 는 **두 시점**의 보안 게이트를 한 스킬 우산으로 소유한다. v1 `npm-reorg-guard`(install-time reorg)를 흡수한 데 이어, `security-release-gates`(release-time 검사)도 safedeps umbrella 로 흡수한다 (알렉스 2026-05-24 결정). "보안"이라는 큰 이름으로 한 파일에 몰아넣는 게 아니라, **gate 의 canonical owner 를 하나로** 두고 lane 별 책임 경계를 분리한다 (SRP 유지).

```text
┌──────────────────────────────────────────────────────────────────────┐
│                  safedeps — 통합 보안 우산 (one skill)                 │
│                                                                      │
│   INSTALL-TIME lane                    RELEASE-TIME lane              │
│   (개발 중 · 패키지 설치 시점)            (릴리스 · 배포 직전)            │
│   ─────────────────────                 ──────────────────            │
│   Phase 1  advisory gate                safedeps scan secrets         │
│            (OSV/KEV/GHSA)                  (gitleaks worktree/staged)  │
│   Phase 2  hook enforcement             safedeps audit deps           │
│            (PreToolUse ledger)             (npm audit / pip-audit)     │
│   Phase 3  reorg rollback               safedeps hooks install|check  │
│            (PostToolUse)                   (repo-local git hook)       │
│                                         safedeps git pre-commit       │
│   범위: 설치하려는 그 패키지              safedeps repo profile/privacy   │
│   단위, 설치 전 + 상시 hook                                            │
│                                         범위: repo 전체 트리, 릴리스 전  │
│   ↓ section 2~13 상세                    ← security-release-gates 에서   │
│                                            이식 (Phase B). 옛 release-  │
│                                            gate orchestrator 흡수.     │
│                                                                      │
│   공통 원칙: 공개 DB(OSV/KEV/GHSA) + 로컬 first + No silent fallback    │
│   (scanner fallback 은 observable + printed 일 때만 허용,             │
│    provider/scanner miss 는 fail-closed)                              │
└──────────────────────────────────────────────────────────────────────┘
```

- **INSTALL-TIME lane** = 이 문서 section 2~13 의 3-Phase advisory/hook/reorg 방어. per-package, proactive.
- **RELEASE-TIME lane** = `security-release-gates` 의 repo-tree 검사(secret scan, dependency audit, repo hook install/check, privacy profile)를 `safedeps scan|audit|hooks|git` command namespace 로 흡수. repo-specific policy(`.gitleaks.toml`, lockfile)는 대상 repo 에 남고, safedeps 는 실행·설치·검증 owner.

> 두 lane 은 시점·범위가 다르다(설치 전 개별 패키지 vs 릴리스 전 repo 전체). 한 우산 아래 두되 command namespace 로 분리해 SRP 를 지킨다.

### Install-time lane: 3-Phase Defense (상세)

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │                                                                     │
   │   Phase 1: ADVISORY GATE          Phase 2: HOOK ENFORCEMENT          │
   │   ────────────────────            ────────────────────               │
   │                                                                     │
   │   사용자 의도                       │                                 │
   │   (intent: 이 패키지 설치           │                                 │
   │    하고 싶다)                       │                                 │
   │      │                            │                                 │
   │      ▼                            │                                 │
   │   ┌─────────────┐    OSV.dev      │                                 │
   │   │ safedeps    │◄────primary─────┤                                 │
   │   │   check     │    CISA KEV     │                                 │
   │   │             │◄──hard-risk────┤                                 │
   │   │             │    GHSA         │                                 │
   │   │             │◄──enrichment───┤                                 │
   │   └──────┬──────┘                 │                                 │
   │          │                                                          │
   │          ▼                                                          │
   │   ┌──────────────────────┐                                          │
   │   │ approved spec ledger │                                          │
   │   │ .safedeps/           │                                          │
   │   │   approved-specs/    │                                          │
   │   │   <hash>.json        │                                          │
   │   │ • ecosystem          │                                          │
   │   │ • package@version    │                                          │
   │   │ • approved_at        │                                          │
   │   │ • expires_at         │                                          │
   │   │ • evidence sources   │                                          │
   │   └──────┬───────────────┘                                          │
   │          │                                                          │
   │          ▼                                                          │
   │                              ┌─────────────────┐                    │
   │                              │ 사용자 / Claude  │                    │
   │                              │ install 명령 발행 │                    │
   │                              │ (npm install ..) │                    │
   │                              └────────┬────────┘                    │
   │                                       │                             │
   │                                       ▼                             │
   │                              ╔═════════════════════════╗            │
   │                              ║ PreToolUse HOOK         ║            │
   │                              ║ safedeps-pre-guard.sh   ║            │
   │                              ╚════════╤════════════════╝            │
   │                                       │                             │
   │                              ledger 조회:                            │
   │                              "이 명령의 ecosystem +                  │
   │                               pkg@version 이 approved              │
   │                               spec 과 일치?"                         │
   │                                       │                             │
   │                              ┌────────┴────────┐                    │
   │                              ▼                 ▼                    │
   │                          match O          match X                   │
   │                              │                 │                    │
   │                              ▼                 ▼                    │
   │                       명령 실행          BLOCK + 안내                  │
   │                          │              ("safedeps                   │
   │                          │               check ... 먼저 해")          │
   │                          ▼                                          │
   │                  install 실행                                       │
   │                          │                                          │
   │                          ▼                                          │
   │                  ╔══════════════════════════════╗                  │
   │                  ║ PostToolUse HOOK             ║                  │
   │                  ║ safedeps-post-verify.sh      ║                  │
   │                  ╚════════╤═════════════════════╝                  │
   │                           │                                         │
   │                  lockfile diff vs                                   │
   │                  approved spec 비교                                  │
   │                           │                                         │
   │                  ┌────────┴────────┐                                │
   │                  ▼                 ▼                                │
   │              spec 과 동일       diverged                             │
   │                  │                 │                                │
   │                  ▼                 ▼                                │
   │              CONFIRM            REORG                               │
   │              (clean baseline)   (rollback to                        │
   │                                  last confirmed)                    │
   │                                                                     │
   │   Phase 3: POST-INSTALL SAFETY NET (v1 의 reorg engine 계승)         │
   │   ───────────────────────────────────────────────                   │
   │                                                                     │
   └─────────────────────────────────────────────────────────────────────┘
```

핵심 통찰:
- **Phase 1 = pre-install advisory gate** (새로 추가). vuln DB 조회 → 안전 spec 결정. 사용자/Claude 가 install 명령 *작성하기 전에* 끝남.
- **Phase 2 = hook enforcement**. hook 자체는 vuln DB 조회 안 함. **approved spec ledger 와의 일치만 검증**. 빠르고 결정론적.
- **Phase 3 = post-install rollback**. v1 reorg engine 그대로. install 결과가 approved spec 과 어긋나면 마지막 confirmed 로 복원.

---

## 2. Vulnerability DB — Source Hierarchy

```
┌──────────────────────────────────────────────────────────────────────┐
│  TIER 1 — PRIMARY (canonical truth)                                   │
│  ────────────────────────────────────────                             │
│  OSV.dev                                                              │
│    • multi-ecosystem (npm, pip, cargo, go, gem, maven, nuget, ...)    │
│    • package@version 질의 표준화                                       │
│    • Google 운영, 무료 API, JSON                                       │
│    • GHSA, RustSec, GoVulnDB 등 다 aggregate                          │
│    → 모든 advisory 의 1차 query target                                 │
├──────────────────────────────────────────────────────────────────────┤
│  TIER 2 — OVERLAY (hard-risk signal)                                  │
│  ────────────────────────────────────────                             │
│  CISA KEV (Known Exploited Vulnerabilities)                          │
│    • "실제 야생에서 exploit 확인" 만 추림                                │
│    • OSV 결과와 cross-reference: KEV 매치 시 hard-block (override 불가) │
│    → 일반 CVE vs "급박한 CVE" 의 구분선                                 │
├──────────────────────────────────────────────────────────────────────┤
│  TIER 3 — ENRICHMENT / CROSS-CHECK                                    │
│  ────────────────────────────────────────                             │
│  GitHub Advisory (GHSA)                                              │
│    • OSV 에 일부 들어오지만 first_patched_version /                    │
│      vulnerable_version_range 같은 metadata 가 개발자 친화             │
│    • "OSV 와 다른 결" 만 surface — discrepancy verifier 결              │
│  NVD                                                                  │
│    • CVE 원본, CVSS 점수, CPE 매핑, hasKev flag                        │
│    • 점수 기반 우선순위 계산                                            │
│  deps.dev (Google)                                                    │
│    • OSV 기반 + package graph metadata (depended_by, license, ...)    │
│    • transitive dep 위험 분석                                          │
│  Snyk DB (optional)                                                   │
│    • purl 기반 query, UI 풍부                                          │
│    • 무료 quota 한도, configured optional feed 만 사용                  │
└──────────────────────────────────────────────────────────────────────┘
```

설계 원칙: **canonical truth 는 OSV 하나**. 다른 source 는 enrichment 또는 overlay. 여러 라이브 source 를 \"동급 진실\" 로 두면 cross-fire 발생 — 우리는 OSV 를 truth 로 두고 KEV/GHSA/NVD/deps.dev 는 \"OSV 와 다르거나, OSV 가 못 본 신호\" 만 surface.

---

## 3. Approved Spec Ledger — SSoT

`~/.safedeps/approved-specs/<hash>.json`:

```json
{
  "hash": "sha256:abc123...",
  "ecosystem": "npm",
  "package": "@jackwener/opencli",
  "version": "1.7.16",
  "version_range": "^1.7.16",
  "approved_at": "2026-05-18T13:00:00Z",
  "expires_at": "2026-06-18T13:00:00Z",
  "approved_by": "user@example.com",
  "evidence": {
    "osv": { "queried_at": "2026-05-18T13:00:00Z", "vulnerabilities": [] },
    "kev": { "queried_at": "2026-05-18T13:00:00Z", "exploited": false },
    "ghsa": { "queried_at": "2026-05-18T13:00:00Z", "advisories": [] }
  },
  "transitive_specs": [
    { "package": "...", "version": "...", "spec_hash": "..." }
  ]
}
```

**핵심 필드**:
- `hash` — `(ecosystem, package, version)` 의 deterministic hash. hook 이 명령에서 같은 hash 추출 → ledger 조회.
- `approved_at` / `expires_at` — **lifecycle TTL**. 기본 30일. 만료 후 새 CVE 가능성 있어 자동 revoke + re-check 강제.
- `evidence` — 그 시점에 어느 source 가 무엇을 봤는지. audit trail.
- `transitive_specs` — direct 만 아니라 transitive dep 도 ledger 에 박아 \"sub-dep 의 zero-day\" 도 감지 가능.

**Lifecycle**:

```
   approve            install            confirm            re-check
   ───────            ───────            ───────            ────────
      │                  │                  │                  │
      ▼                  ▼                  ▼                  ▼
   ledger 신규       hook 통과         ledger.confirmed=true   daily cron
   approved_at=now   spec hash 일치     post-verify 일치        OSV re-query
   expires_at=+30d                                              │
                                                                ▼
                                                        ┌──────┴──────┐
                                                        ▼             ▼
                                                  여전히 clean    새 CVE 발견
                                                        │             │
                                                        ▼             ▼
                                                  expires_at      ledger revoke
                                                  연장             + 사용자 경고
                                                                  + (옵션) auto reorg
```

---

## 4. Runtime Flow — 3-Phase Detail

### Phase 1 — `safedeps check <ecosystem> <pkg>@<range>`

```
사용자 / Claude:
  "@jackwener/opencli ^1.7.0 깔고 싶음"
        │
        ▼
┌─────────────────────────────────────────────────────────┐
│ safedeps check npm "@jackwener/opencli@^1.7.0"           │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┴────────────────────────────┐
        ▼                                         ▼
   ┌──────────────┐                       ┌──────────────┐
   │ resolve      │                       │ ledger lookup │
   │ version      │                       │ "이미 approved?" │
   │ range →      │                       └───────┬──────┘
   │ candidate    │                               │
   │ versions     │                               ▼
   └──────┬───────┘                       ┌───────┴─────┐
          │                               ▼             ▼
          ▼                          hit (valid)    miss / expired
   ┌──────────────┐                      │              │
   │ OSV query    │                      ▼              ▼
   │ per version  │              "이미 안전, install   "새로 check"
   └──────┬───────┘               해도 됨"
          │
          ▼
   ┌──────────────┐
   │ KEV overlay  │
   │ GHSA cross   │
   └──────┬───────┘
          │
          ▼
   ┌─────────────────────────────────┐
   │ 결과 분류:                        │
   │ • clean (no vuln) → approve      │
   │ • patched_available → approve    │
   │   안전 버전으로 spec 재작성        │
   │   예: ^1.7.0 → ^1.7.16            │
   │ • KEV hit → HARD BLOCK            │
   │   "이 패키지는 실제 exploit 됨,    │
   │    설치 X. 대체 모듈: AAA, BBB"   │
   │ • CVE 있는데 patch X → WARN       │
   │   "취약점 있음, 사용자 결정 필요"  │
   └─────────────────────────────────┘
          │
          ▼
   approved spec ledger 신규 entry 작성
   sha256:abc123... = {ecosystem: npm, pkg, version, ...}
```

### Phase 2 — Hook Enforcement (PreToolUse / `safedeps-pre-guard.sh`)

```
Claude 가 Bash 실행 요청: "npm install @jackwener/opencli@^1.7.16"
        │
        ▼
   ┌─────────────────────────────────┐
   │ safedeps-pre-guard.sh           │
   │ 1. 명령 파싱:                    │
   │    ecosystem = npm               │
   │    pkg = @jackwener/opencli      │
   │    version_range = ^1.7.16       │
   │ 2. spec hash 계산                │
   │ 3. ledger 조회                   │
   └────────────┬────────────────────┘
                │
       ┌────────┴────────┐
       ▼                 ▼
   ledger hit          ledger miss
   (approved +         (또는 expired)
    not expired)            │
       │                    ▼
       ▼            ┌──────────────────────┐
   PASS             │ BLOCK + Claude 한테    │
   (명령 실행)       │ 안내:                  │
                    │ "이 패키지가 advisory  │
                    │  gate 통과 안 됨.      │
                    │  safedeps check ...    │
                    │  먼저 실행해서 spec    │
                    │  approve 해야 함"      │
                    └──────────────────────┘
```

### Phase 3 — Post-Install Rollback (PostToolUse / `safedeps-post-verify.sh`)

```
install 완료 → safedeps-post-verify.sh
        │
        ▼
   ┌─────────────────────────────────────────┐
   │ 1. lockfile 새 entry 추출                │
   │ 2. 각 entry 의 spec hash 계산             │
   │ 3. ledger 와 비교                         │
   │ 4. install script / native binary 검사    │
   │    (v1 reorg-guard 로직 그대로)           │
   └────────────┬────────────────────────────┘
                │
       ┌────────┴────────┐
       ▼                 ▼
   spec 과 동일       diverged
   + 의심 없음        (예: transitive dep
       │              이 ledger 에 없는
       ▼              버전으로 깔림,
   CONFIRM            install script 의심,
   (ledger 의         native binary 출현)
   confirmed=true)         │
                            ▼
                   REORG (v1 engine):
                   • lockfile ← 마지막 confirmed snapshot
                   • rm -rf node_modules
                   • npm install (재설치 = ledger 와 일치)
                   • reorg.log 기록
                   • Claude 한테 경고
```

---

## 5. Threat Model (v2 갱신)

```
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 1 — ADVISORY GATE (`safedeps check`)                          │
├─────────────────────────────────────────────────────────────────────┤
│ • 알려진 CVE 매칭 (OSV.dev 기반, multi-ecosystem)                     │
│ • KEV 매칭 시 hard-block (사용자 override 불가)                       │
│ • patched_available 시 안전 버전으로 spec auto-rewrite                │
│ • transitive dep 의 vuln 도 ledger 에 박아 sub-dep 침해 감지          │
├─────────────────────────────────────────────────────────────────────┤
│  PHASE 2 — HOOK ENFORCEMENT (`safedeps-pre-guard.sh`)                │
├─────────────────────────────────────────────────────────────────────┤
│ v1 의 hardcoded pattern 결도 유지 (defense-in-depth):                 │
│ • typosquat 명단 매치                                                 │
│ • curl|bash 류 pipe execution                                         │
│ • 비표준 --registry URL                                               │
│ • install script safety disabling                                     │
│ • eval / subshell indirection                                         │
│ + 새로운 enforcement:                                                  │
│ • spec hash 가 ledger 에 없거나 expired → BLOCK + advisory gate 안내   │
├─────────────────────────────────────────────────────────────────────┤
│  PHASE 3 — POST-INSTALL REORG (`safedeps-post-verify.sh`)            │
├─────────────────────────────────────────────────────────────────────┤
│ • install script 의 network/code execution/sensitive path 검사        │
│ • base64/hex obfuscation                                              │
│ • 비표준 registry resolved URL                                        │
│ • 50+ dep explosion                                                   │
│ • native binary 출현                                                  │
│ • lockfile entry 가 approved spec 과 diverged → REORG                 │
└─────────────────────────────────────────────────────────────────────┘
```

**막지 않는 것 (현재 한계)**:
- ledger 의 approved_at 이후 새로 발견된 zero-day — daily re-check 로만 catch 가능, install 시점엔 못 잡음.
- npm registry 자체의 손상.
- 사용자가 `--allow-unverified` 명시 우회한 경우 (observable, log 기록).

---

## 6. Provider Failure Modes (No Silent Fallback)

```
┌────────────────────────────────────────────────────────────────────┐
│  OSV.dev 응답 무 / timeout                                          │
│  ────────────────────                                               │
│  • 1차: provider cache (local TTL 24h) 사용                          │
│  • cache miss → fail-closed (block + "OSV 응답 없음, 재시도")        │
│  • 사용자 explicit `--allow-unverified` 시만 우회 + log            │
├────────────────────────────────────────────────────────────────────┤
│  CISA KEV 응답 무                                                   │
│  ────────────────────                                               │
│  • KEV 는 매일 1회 download (정적 catalog), 로컬 cache 만 사용       │
│  • 24h 이상 stale 시 경고                                           │
├────────────────────────────────────────────────────────────────────┤
│  GHSA / NVD 응답 무                                                 │
│  ────────────────────                                               │
│  • enrichment 결이라 fail-open 허용                                 │
│  • OSV 결과로만 진행 + log 에 "GHSA cross-check skipped"            │
└────────────────────────────────────────────────────────────────────┘
```

설계 원칙: **silent fallback 금지**. 모든 우회는 observable + log. canonical truth (OSV) 가 응답 못 하면 default = fail-closed.

---

## 7. State Layout — `~/.safedeps/`

```
~/.safedeps/
├── approved-specs/
│   ├── sha256-abc123.json         ← 한 (ecosystem, package, version) 당 한 파일
│   ├── sha256-def456.json
│   └── ...
│
├── snapshots/                     ← v1 reorg snapshot 그대로 계승
│   ├── 20260518-130000-xyz/
│   │   ├── package-lock.json
│   │   ├── yarn.lock
│   │   ├── pnpm-lock.yaml
│   │   ├── poetry.lock            ← v2 ecosystem 확장
│   │   ├── uv.lock
│   │   ├── Cargo.lock
│   │   ├── go.sum
│   │   ├── Gemfile.lock
│   │   └── meta.json
│   └── ...
│
├── confirmed_${dir_hash}          ← 프로젝트별 마지막 confirmed snapshot
│
├── cache/
│   ├── osv/                       ← OSV query 응답 cache (24h TTL)
│   │   └── npm-@jackwener-opencli-1.7.16.json
│   └── kev/                       ← CISA KEV daily catalog
│       └── kev-2026-05-18.json
│
├── locks/                         ← atomic state (TOCTOU 방지)
├── reorg.log                      ← REORG event 기록 (append-only)
└── advisory.log                   ← advisory gate event 기록 (block/approve)
```

설계 결정:
- `approved-specs/` = ledger SSoT, JSON-per-spec (atomic write).
- `snapshots/` = v1 결 그대로 + py/rust/go/ruby lockfile 추가.
- `cache/osv/`, `cache/kev/` = provider 응답 cache (TTL).
- `advisory.log` = advisory gate 의 모든 approve/block decision audit trail.

---

## 8. Multi-Ecosystem Support (v2 확장)

| Ecosystem | Manifest | Lockfile | safedeps check 명령 |
|---|---|---|---|
| npm | `package.json` | `package-lock.json` | `safedeps check npm <pkg>@<range>` |
| yarn | `package.json` | `yarn.lock` | `safedeps check npm <pkg>@<range>` (OSV 공통) |
| pnpm | `package.json` | `pnpm-lock.yaml` | `safedeps check npm <pkg>@<range>` |
| pip (Poetry) | `pyproject.toml` | `poetry.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (uv) | `pyproject.toml` | `uv.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (Pipenv) | `Pipfile` | `Pipfile.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (raw) | `requirements.txt` | (약함) | `safedeps check pypi <pkg>@<range>` |
| cargo | `Cargo.toml` | `Cargo.lock` | `safedeps check crates.io <pkg>@<range>` |
| go | `go.mod` | `go.sum` | `safedeps check go <pkg>@<range>` |
| ruby | `Gemfile` | `Gemfile.lock` | `safedeps check rubygems <pkg>@<range>` |
| maven | `pom.xml` | (해당 디렉토리) | `safedeps check maven <group>:<artifact>@<range>` |
| nuget | `*.csproj` | `packages.lock.json` | `safedeps check nuget <pkg>@<range>` |

각 ecosystem 의 typosquat 명단·install script 위험 패턴은 별도 정적 list 로. OSV.dev 가 ecosystem 정규화를 표준화해줘서 single API 결로 모두 cover.

---

## 9. 컴포넌트 책임 분리 (SoC)

```
┌─────────────────────────────────────────────────────────────────────┐
│  SKILL.md             — Claude/Codex skill loader 가 읽는 SSoT.       │
│                         hook 선언 + advisory gate 사용법 안내.         │
├─────────────────────────────────────────────────────────────────────┤
│  README.md            — 사용자 install 가이드.                         │
├─────────────────────────────────────────────────────────────────────┤
│  ARCHITECTURE.md      — 이 문서. 내부 흐름·설계.                       │
├─────────────────────────────────────────────────────────────────────┤
│  bin/safedeps         — CLI entry (advisory check, ledger 관리,        │
│                         재검증 등).                                    │
├─────────────────────────────────────────────────────────────────────┤
│  scripts/safedeps-pre-guard.sh — PreToolUse hook. ledger 일치 검증     │
│                         + v1 의 hardcoded pattern.                    │
├─────────────────────────────────────────────────────────────────────┤
│  scripts/safedeps-post-verify.sh — PostToolUse hook. lockfile diff +  │
│                         spec 비교 + reorg.                             │
├─────────────────────────────────────────────────────────────────────┤
│  lib/providers/       — OSV / KEV / GHSA / NVD / deps.dev / Snyk      │
│                         adapter. 하나의 query interface.               │
├─────────────────────────────────────────────────────────────────────┤
│  lib/ledger/          — approved spec ledger I/O. atomic write,        │
│                         hash 계산, TTL 검사.                           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 10. 비교 — 기존 도구들과 결 (정확화)

| 도구 | 결 | 동작 시점 | safedeps 와 차이 |
|---|---|---|---|
| `npm audit` | materialized lock 기반 취약점 보고 | post-install | spec 결정 / 차단 안 함, **보고만** |
| `pip-audit` / `cargo audit` / `bundler-audit` | 같은 결, 다른 ecosystem | post-install | 같음 |
| **socket.dev** | SaaS risk intelligence (behavioral + static) | pre-install + post-install | 클라우드 의존, 무료 quota 한도, **외부 SaaS** |
| **lavamoat** | runtime permission containment (sandbox) | runtime | install 전 차단 X, **무겁고 dev 단계 부담** |
| **pnpm `onlyBuiltDependencies`** | lifecycle script allowlist | install 단계 | typosquat / vuln DB X, **script 차단만** |
| **deps.dev** | package graph metadata | query only | active gate 아님, **데이터만** |
| **OSV-Scanner** | OSV 결 lockfile 스캔 | post-install (CI) | spec gate X, **lockfile 리포트만** |
| **GitHub Dependabot** | PR 기반 dep update 권장 | repo-level (PR) | local install 차단 X, **PR 단계만** |
| **`safedeps` (이것)** | **advisory gate + approved spec ledger + post-install reorg** | **pre-install + install + post-install** | **3-phase, multi-ecosystem, 로컬 first** |

차별점 요약:
- 다른 도구는 \"보고\" / \"sandbox\" / \"script 차단\" / \"PR 권장\" 중 하나에 집중.
- safedeps 는 **\"advisory gate (Phase 1) → hook enforcement (Phase 2) → reorg fallback (Phase 3)\" 의 3겹 defense-in-depth**.
- Snyk / socket.dev 와 달리 **SaaS 의존 X, 로컬 + 공개 DB (OSV/KEV/GHSA) 만**.

---

## 11. 운영 로그

```bash
# advisory gate decision (approve / block)
tail -f ~/.safedeps/advisory.log

# reorg event
tail -f ~/.safedeps/reorg.log

# 현재 approved specs
ls -lt ~/.safedeps/approved-specs/

# 특정 spec 의 evidence
cat ~/.safedeps/approved-specs/sha256-abc123.json | jq '.evidence'

# expired specs (만료된 거 재검증 필요)
find ~/.safedeps/approved-specs -name '*.json' -exec jq -r 'select(.expires_at < now) | "\(.package)@\(.version) expired \(.expires_at)"' {} \;

# OSV cache 비우기 (강제 re-query)
rm -rf ~/.safedeps/cache/osv/
```

---

## 12. v1 → v2 마이그레이션

```
v1 (npm-reorg-guard)                v2 (safedeps)
────────────────────                ──────────────

~/.npm-reorg-guard/        →        ~/.safedeps/
~/.claude/skills/                   ~/.claude/skills/
  npm-reorg-guard/         →          safedeps/
                                      (old local skill path is not canonical)

scripts/guard.sh           →        scripts/safedeps-pre-guard.sh
  (typosquat / pattern               + ledger lookup
   매칭만)                            + v1 pattern 유지
                                      + namespaced filename

scripts/verify.sh          →        scripts/safedeps-post-verify.sh
  (lockfile diff + reorg)            + approved spec diff
                                      + v1 reorg 유지
                                      + namespaced filename

(없음)                     →        bin/safedeps  ← 새 CLI
                                      check / approve / revoke /
                                      re-check / ledger

(없음)                     →        lib/providers/  ← OSV / KEV / GHSA / ...
(없음)                     →        lib/ledger/    ← approved spec I/O

GitHub repo:
  aldegad/npm-reorg-guard  →        aldegad/safedeps
                                      (GitHub redirect only)
```

v1 migration:
- v1 hook 등록 path (`~/.claude/skills/npm-reorg-guard/scripts/*.sh`) 는 canonical 이 아니다. settings 는 `~/.claude/skills/safedeps/scripts/*.sh` 로 갱신한다.
- v1 의 `~/.npm-reorg-guard/` 디렉토리 발견 시 `~/.safedeps/` 으로 마이그레이션한다 (snapshot chain 보존).
- v1 사용자는 `safedeps migrate` 한 줄로 ledger 신규 생성 + 기존 confirmed snapshot 들을 그대로 approved spec 으로 변환.

---

## 13. 한계 + 미래 방향

**현재 한계 (v2 첫 출시)**:
- approved_at 이후 발견된 zero-day 는 daily re-check 로만 catch.
- npm/PyPI 같은 registry 자체 손상 시 우리도 못 막음.
- KEV 는 24h 단위 update — 그 사이 새 KEV 등재 못 잡음.
- transitive dep 의 vuln 검사는 ledger 폭증 가능 (수백 개 dep). 최적화 필요.

**미래 확장**:
- **plugin model** — 사용자 정의 provider (회사 내부 vuln DB, private registry).
- **policy file** — `.safedeps.toml` 로 \"우리 팀 정책: KEV hit 자동 block, CVSS 7+ 는 사용자 컨펌\" 같이 명시.
- **CI mode** — `safedeps check --ci` 로 GitHub Actions / CircleCI 등에서 fail fast.
- **multi-machine ledger sync** — 팀 차원의 approved spec 공유.
- **deps.dev graph 활용** — transitive dep 의 \"위험 score\" 시각화.
- **AI agent integration** — Claude / Codex 가 \"이 패키지 알려진 vuln 있음, 대체 모듈 X 권장\" 결로 직접 제안.

---

*문서 history*: v1 (`npm-reorg-guard`) 2026-05-18 작성 → v2 (`safedeps`) 2026-05-18 재작성. 코덱시 (surface:195) 와 클로디시 (surface:61) peer-question 합의안 기반.
