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
│                                        optional PR required checks   │
│   범위: 설치하려는 그 패키지              범위: repo 전체 트리            │
│                                        (security-release-gates 흡수)  │
│                                                                      │
│   공통: 공개 DB(OSV/KEV/GHSA) · 로컬 first · no silent fallback        │
│   (provider/scanner miss 는 fail-closed)                             │
└──────────────────────────────────────────────────────────────────────┘
```

- **Install-time lane** (아래 section 2–13) — advisory check, fast command guard, npm effect gate + reorg. per-package, proactive.
- **Release-time lane** — `security-release-gates` 의 repo-tree 검사(secret scan, dependency audit, repo hook install/check, privacy profile)를 `safedeps scan|audit|hooks|doctor` namespace 로 흡수. repo-specific policy(`.gitleaks.toml`, lockfile)는 대상 repo 에 남고, safedeps 가 로컬 실행·설치·검증 owner. 원격 repo 자세는 opt-in 이고 비용 경계로 나눈다: default branch 직접 push 를 막는 no-runner branch rule 은 권장하고, Actions-backed workflow 와 required status check 는 별도 비용 가능 opt-in 으로 둔다.

두 lane 은 시점·범위가 다르다(설치 전후 개별 패키지 effect vs 릴리스 전 repo 전체). 한 우산 아래 두되 command namespace 로 분리해 SRP 를 지킨다.

**release-time lane 의 secret 누출 쪽은 repo 별이고 opt-in 이다.** 탐지 policy 가 safedeps 가 아니라 대상 repo 에 있어서, repo 가 `.gitleaks` config 와 활성 `.githooks/pre-commit` 을 제공하기 전까지는 아무 것도 하지 않는다. `safedeps doctor` 가 그 빈틈을 메우는 repo-entry 진단이다: secret 누출 lane 의 각 조각(`.gitleaks` policy, `pre-commit`, `core.hooksPath`, scanner 가용성)과 전역 install-time gate 를 함께 보고하고, repo 별 lane 에 gap 이 있으면 non-zero 로 끝난다. `safedeps doctor --fix`(= `safedeps hooks init` 후 `safedeps hooks install`)가 `lib/gates/templates/` 의 시작 policy 를 scaffold 하고 로컬 hook 을 활성화한다. scaffold 는 **비파괴적**이라 repo 가 소유한 기존 config 를 덮지 않으며, "safedeps 는 *실행*을 소유하고 *policy* 는 소유하지 않는다"는 불변식을 지킨다. scaffold 된 `pre-commit` 은 두 검사를 돌린다. 비밀키 스캔(`safedeps scan secrets --staged`)은 매 커밋 돌고 fail-closed 다: safedeps 미해석이나 scanner 부재 시 silent skip 이 아니라 커밋을 막는다. 의존성 audit(`safedeps audit`)도 지원 lockfile — npm·pnpm·yarn·bun, 있는 lockfile 에서 자동 감지해 각 ecosystem 의 네이티브 audit 에 위임 — 이 있는 repo 면 매 커밋 돈다 — lockfile 이 바뀔 때만이 아니라 — 그래서 패키지를 깐 *뒤에* 공개된 CVE 가 어드바이저리 DB 재조회로 다음 커밋에 잡힌다. audit 은 보안 판정과 가용성 실패를 의미 있는 exit code 로 구분한다(0 clean / 1 취약 / 2 못 돌림): 실제 취약점은 **차단**(fail-closed)하고, 어드바이저리 DB 도달 불가 시에는 hook 이 **경고하고 커밋을 통과**시킨다 — 명시적이고 관측 가능한 가용성 failover(no-silent-fallback 불변식대로: 커밋 출력에 남고 canonical truth 를 바꾸지 않음)이며, 오프라인 커밋이 못 본 건 CI 와 데일리 re-check 가 다시 메운다.

**원격 enforcement 는 의도적으로 opt-in 이고 비용 인식형이다.** `doctor` 는 repo 에 보안 workflow 가 이미 있는지 보고하고 default branch 자세를 둘로 나눠 이름 붙인다: branch rule 로 직접 push 를 막는 것(no runner minutes)과 Actions-backed PR status check 를 요구하는 것(hosted runner minute 사용 가능). branch protection 을 조회하거나 바꾸지 않고 `doctor --fix` 는 `.github/workflows` 를 만들지 않는다. 로컬 pre-commit 검사는 개발자 머신에서 돌지만, 원격 GitHub Actions, CI 의 gitleaks, required PR check 는 no-cost bundle 밖이다. JSON schema 는 이 권고를 `lane: "remote"` check 로 유지하고, `gaps`/`ok` 는 로컬 secret 누출 lane 에만 묶는다.

**effect-primary 모델은 npm 한정이다.** `pip`, `cargo`, `go`, `gem`, `maven`, `nuget` 은 closure resolver 가 붙기 전까지 v2.1 command-gate + reorg 모델을 유지하며, PostToolUse closure 권위로 서술하지 않는다.

#### 생태계마다 권위가 어디에 있나

커맨드 게이트는 "이 명령이 설치인가" 를 인터프리터에게 텍스트를 넘기는 구문 형태를 인식해서 판정한다. 아는 형태는 `sh -c`, `eval`, 명령 치환, 셸로 들어가는 파이프다. 이건 열거이고, 셸이 인터프리터로 텍스트를 보내는 방법은 무한하므로 그 목록에는 경계가 있다. herestring, `xargs` 가 조립한 명령줄, 파일로 쓴 뒤 실행하는 스크립트는 모두 그 바깥이다. 목록을 늘리면 형태가 줄어드는 게 아니라 더 나온다.

**같은 우회가 생태계마다 심각도가 다르고, 그 차이가 핵심이다.** npm 에서 이 경계의 비용은 **지연 탐지**다. 효과 게이트는 살아 있는 `package-lock.json` 을 읽고, 그 자신의 설치 인식기는 carrier 열거 없는 raw 텍스트 매치라서 커맨드 게이트가 지나친 바로 그 명령에 발화한다. 인식 못 한 carrier 라도 결국 closure 검사와 rollback 으로 끝난다. `pip`, `cargo`, `go`, `gem`, `maven`, `nuget` 에는 커맨드 게이트 뒤에 closure resolver 가 없으므로 같은 carrier 가 **완전 미탐**이다. post hook 은 명령을 인식하지만 검사할 수단이 없어서 `UNVERIFIED` 만 기록한다. "커맨드 게이트가 이 형태를 파싱하지 않는다" 를 npm 기준으로 읽으면 뭔가가 여전히 지켜보고 있다고 결론짓게 된다. 커맨드 게이트가 권위인 생태계에서는 아무것도 없다.

**npm 의 "지연 탐지" 는 효과 게이트가 완주하는 동안만 성립하고, 그 범위는 주어진 것이 아니라 실측된 구간이다.** 게이트는 30s 로 등록돼 있고 런타임이 거기서 죽인다. 비용은 프로젝트 lockfile closure 에 매이고, 예전에는 머신의 approved-spec 레저에도 매였다 — 게이트가 closure 패키지마다 레저에 따로 물었고, 그 질문 하나하나가 레저 디렉토리 전체를 훑었다. 738개짜리 레저에서는 **closure 4개**에서 30s 를 넘었다. 즉 거의 모든 설치에서 npm 의 지연 탐지는 탐지가 아니었다. v2.16.0 은 패키지마다가 아니라 closure 당 한 번 레저를 읽고, 레저 축은 평평해진다(측정한 모든 closure 크기에서 0.23s). 남은 것은 패키지별로 도는 OSV/KEV 패스다. 같은 머신, cold provider 캐시 기준으로 게이트는 이제 closure **390개** 근처에서 30s 를 넘는다. 그 아래에서 npm 의 지연 탐지는 실제이고, 그 위 — 큰 애플리케이션의 lockfile — 에서는 게이트가 죽고 탐지는 일어나지 않는다. 문제가 되는 머신에서 `scripts/measure/effect-gate-cost.sh` 로 직접 재라. 넘는 지점은 호스트·네트워크·캐시에 따라 움직인다.

**롤백 도중에 게이트가 죽어도 그 사실이 더는 사라지지 않는다.** 롤백은 lock·manifest 파일을 복원한 뒤 `node_modules` 를 지우고 다시 만드는데, 예전에는 `reorg.log` 항목과 메시지를 그 전부가 끝난 뒤에야 썼다. 중간 어디서 죽어도 0줄이 남았다 — 프로젝트가 이미 완전히 되돌아간 지점에서도 그랬고, 그러면 사용자의 설치가 아무 설명 없이 사라진다. 이제 게이트는 첫 파괴적 행위 앞에서 롤백 저널 항목을 쓰고 롤백이 자기 보고를 마친 뒤에 지운다. 그래서 자기 실행보다 오래 살아남은 항목 자체가 곧 보고다. 다음 PostToolUse 가 그것을 영구 incident 기록으로 옮기고, 완주한 롤백이 쓰는 바로 그 `reorg.log` 에 `REORG INTERRUPTED` 를 덧붙이고, 어느 단계까지 갔는지와 무엇으로 복구하는지를 말한다. 이건 원자성이 아니다 — safedeps 는 npm 트리 재빌드의 원자성을 소유하지 않는다 — 미완의 롤백이 조용하지 않고 크게 남는다는 보장이다. `scripts/measure/rollback-kill-state.sh` 와 e2e 배터리의 양방향 회귀가 고정한다.


이 경계는 실수가 아니고, 넓히는 것도 공짜가 아니다. 이 레포의 두 인식기는 의도적으로 정반대의 정밀도 트레이드를 한다. 효과 게이트의 오탐 비용은 closure diff 한 번이라 인식기가 일부러 느슨하다. 커맨드 게이트의 오탐은 **사용자의 명령을 거부**하므로 인식기가 정밀해야 하고, 열거되지 않은 carrier 는 바로 그 정밀도를 통과한다. npm 의 권위를 애초에 효과 게이트로 옮긴 것과 같은 결론이다. 명령 텍스트는 fail-closed 권위가 될 수 없다. 텍스트로 판정한다는 건 열거해야 하는 구문으로 판정한다는 뜻이기 때문이다.

커맨드 게이트를 고칠 때의 규칙이 여기서 나온다. 게이트가 이미 선언한 규칙을 그것을 건너뛴 자리에 적용하는 것은 범위 안이다. `| /bin/sh` 와 `| env sh` 를 `| sh` 로 정규화하는 것은 "경로가 붙거나 `env` 가 앞에 붙은 호출은 맨 호출과 같다" 는 게이트 자신의 기존 선언을, 생산자 쪽에만 적용되던 것을 파이프의 소비자 쪽에도 적용한 것이다. 인식기에 새 carrier 구문을 추가하는 것은 범위 밖이다. 거기가 열거가 수렴 없이 자라는 자리다.

파서 갭을 npm 기준으로 읽던 오해는 한 군데가 아니었다. 원장 게이트 자체가 파싱 가능한 `pkg@version` 피연산자를 조건으로 걸려 있고, 코드가 밝힌 그 근거도 npm 모양이다 — 맨 `npm install` 은 새 패키지를 지목하지 않는 lockfile 설치라 통과시키는 게 **npm 에서는** 맞다. 그런데 `pip install evil` 은 lockfile 설치가 아니다. 패키지를 지목한다. 같은 논리가 이 커맨드 게이트가 권위인 생태계로 그대로 이식됐고, 거기서 그건 버전 없는 설치가 아예 검사되지 않는다는 뜻이다.

방향도 뒤집혀 있는데, 이건 열거로는 절대 안 나오는 부분이다. 숨김 경로는 spec 을 못 뽑으면 거부하고, 평문 경로는 똑같은 조건에서 허용한다. 한 파일 안에서 하나의 조건이 반대 방향으로 읽힌다 — `printf 'pip install evil' | sh` 는 fail-closed 로 거부되는데 `pip install evil` 은 그냥 진행된다.

이 경우는 이제 생태계와 명령을 담은 `UNGATED` 기록을 남긴다. 판정은 하나도 안 바뀐다. 버전 없는 설치를 전부 거부하는 건 평범한 작업 흐름을 깨는 정책 변경이라 레포 소유자 소관으로 남기고, 기록은 그 결정을 추측이 아니라 근거로 답할 수 있게 만드는 것이다. 기록의 침묵도 소음만큼 의도적으로 범위를 잡았고, 기준은 어떤 플래그가 붙었는지가 아니라 패키지를 지목하는지다. 맨 lockfile 설치는 지목하지 않고, 가져오는 게 아니라 작업 트리에서 빌드하는 `pip install .` 도 마찬가지다. 소스 플래그는 자기 인자만 소비하며 어떤 플래그가 값을 받는지는 도구의 속성이다 — pip 의 `-r`·`-c`·`-t`·`-f` 는 받지만 gem 의 `-r` 은 `--remote` 이고 go 의 `-t` 는 불리언이다. 평범한 설치마다 찍히는 기록은 배경 소음이고 배경 소음은 없는 기록과 같지만, 플래그만 보이면 침묵하는 기록은 더 나쁘다 — 없는 커버리지를 있는 것처럼 읽히게 한다.

측정은 `scripts/test/consumer-forms.sh` 가 들고 있다. 게이트가 잡는 형태, 의도적으로 판정하지 않는 형태, 각 미탐의 생태계별 결과, 그리고 그만큼 중요한 세 번째 집합인 **미끼**를 고정한다. `sh -c "sh -c "…""` 는 이중 중첩처럼 읽히지만 바깥 따옴표가 안쪽에서 닫혀서 아무것도 설치되지 않고, `-I` 나 `-0` 없는 `xargs sh -c` 는 그 줄을 스크립트가 아니라 `$0` 으로 넘긴다. 배터리는 각 형태를 가짜 패키지 매니저에 대고 실제로 실행해서 판정하므로, 실제로 매니저에 도달하는 형태만 갭으로 계산된다.

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
  ],
  "project_context": null
}
```

핵심 필드:

- `hash` — `(ecosystem, package, version)` 의 deterministic hash. `project_context.context_hash` 가 있으면 함께 접어 넣는다. hook 이 명령(과, 있다면 살아있는 project context)에서 같은 hash 를 뽑아 ledger 를 조회한다.
- `approved_at` / `expires_at` — lifecycle TTL, 기본 30일. 만료 후엔 새 CVE 가능성이 있어 자동 revoke + re-check 강제.
- `evidence` — 승인 시점에 어느 source 가 무엇을 봤는지. audit trail.
- `transitive_specs` — direct entry 가 승인한 전체 transitive closure. npm effect gate 는 lockfile 에 있으면서 direct entry 에도 이 배열에도 없는 `pkg@version` 을 reorg 한다.
- `project_context` — 일반 published-package 승인은 `null`, Yarn 프로젝트의 resolved closure 에서 온 승인이면 `{ type, context_hash, project_root, manifest_path, lockfile_path, input_sha256, input_files }` (4장 "Yarn project-scoped closure" 참고). `context_hash` 는 project directory, 루트 `resolutions`, `yarn.lock` content, canonical input set 의 hash 다. `type` 은 package 가 이미 project lockfile 에 있었으면 `yarn-project-lockfile`, candidate 를 isolated mirror 에서 해석했으면 `yarn-project-materialized-lockfile` 이다. materialized 쪽은 `materialization { candidate, input_sha256, generated_lockfile_sha256, command, isolation }` 을 추가로 가진다. `safedeps_ledger_validate_json` 은 이 필드들을 필수로 요구하고, `materialization.input_sha256` 이 context 의 `input_sha256` 과 다르면 entry 를 거부한다.

`project_context.type` 은 published-package probe 가 소비 레포의 npm `overrides` 를 반영했을 때 `npm-overrides-probe` 도 된다. 이 컨텍스트는 `project_root`, `overrides_source`(manifest 경로 또는 `env`), `overrides_sha256`, 그리고 `overrides` 자체를 싣는다. `context_hash` 는 project root 와 canonical(키 정렬) override 집합의 hash 라, 동등한 두 집합은 같은 키를 공유한다. `safedeps_ledger_validate_json` 은 이 필드들을 필수로 요구하고 override 집합이 빈 entry 는 거부한다. 근거는 이렇다 — published-package 승인이 전역일 수 있는 건 오직 그것이 프로젝트 무관이기 때문이다. `overrides` 를 반영하면 resolved closure 가 소비 프로젝트의 함수가 되므로, 그 승인은 Yarn project closure 와 같은 방식으로 키가 잡혀야 한다. 그러지 않으면 transitive 를 patch 한 레포에서 얻은 승인이 patch 하지 않은 레포의 검사를 만족시키고, 그 레포의 실제 설치는 취약한 버전을 해석한다. `overrides` 가 없는 레포는 컨텍스트가 붙지 않고 기존 전역 승인 그대로다.

**Project-scoped isolation.** `project_context` 가 있는 승인은 `(ecosystem, package, version)` 에 더해 `context_hash` 로도 키가 잡히므로, 같은 spec 의 package-only 승인과는 다른 ledger path 에 놓이고 다른 프로젝트나 `resolutions`/`yarn.lock` 이 바뀐 이후의 같은 프로젝트에서는 조회에 성공하지 못한다 (hash 가 함께 바뀌므로). `safedeps_ledger_check` 는 호출자의 살아있는 context hash 를 저장된 값과 비교해 다르면 `reason: "context_mismatch"` 로 거부한다 — 승인이 프로젝트 경계를 조용히 넘어가는 일은 없다.

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

**Yarn project-scoped closure.** 새로운 published-package probe 로 넘어가기 전에, `lib/npm/closure.sh` 의 `safedeps_npm_yarn_project_closure` 가 먼저 canonical Yarn project context 를 찾는다.

```
project context 해석 (cwd 에서 위로 탐색, .git 경계에서 중단):
        │
        ├─► package.json 에 비어있지 않은 루트 `resolutions` + 옆에 yarn.lock
        │        │
        │        ├─► yarn.lock 에 `__metadata:` marker 없음 ──► INVALID CONTEXT (fail-closed)
        │        └─► 유효한 Berry lockfile
        │                 │
        │                 ▼
        │        context_hash = sha256(project_root, sha256(resolutions), sha256(yarn.lock))
        │                 │
        │                 ▼
        │        `yarn info -A -R --json` → 전체 project locator graph
        │                 │
        │                 ▼
        │        요청된 `pkg@npm:version` locator 부터 traverse
        │                 │
        │                 ├─► locator 발견  ──► resolved project closure (approve 가능)
        │                 └─► locator 없음   ──► candidate 를 materialize (아래 참고)
        │                                        ├─► materialize 성공 ──► generated closure (approve 가능)
        │                                        └─► 실패 ───────────► project-candidate-materialization-unavailable
        │                                                              (거부; published closure 는 쓰지 않음)
        │
        └─► 이 Git worktree 에 resolutions/yarn.lock 없음 ──► 일반 npm package-only check
```

descriptor-to-locator resolution 은 Yarn 소유다. safedeps 는 lockfile resolution 을 재구현하지 않고 `yarn info` 의 machine-readable graph 를 그대로 소비한다. context 가 resolve 되면 approved-spec ledger entry 가 `project_context` (3장) 를 함께 가져, 승인이 그 프로젝트 하나로 한정되고 다른 프로젝트로 새거나 `resolutions`/`yarn.lock` 변경 이후에도 살아남지 못한다.

**Yarn candidate materialization.** locator 가 `yarn.lock` 에 없다는 건 대개 그 package 를 아직 추가하지 않았다는 뜻이고, 그게 바로 일반적인 pre-install check 상황이다. `safedeps_npm_yarn_materialize_candidate_closure` 는 그 candidate 를 거부하거나 published closure 로 되돌아가는 대신 isolated mirror 에서 해석한다.

```
project lockfile 에 locator 없음
        │
        ▼
   mktemp private mirror ◄── canonical input 만 복사:
        │                     루트 + workspace package.json, yarn.lock, .yarnrc.yml,
        │                     .yarn/{releases,plugins,patches}
        │                     (node_modules, cache, unplugged, install state, VCS 는 절대 복사 안 함)
        ▼
   mirror 안에서 input 을 다시 hash; 호출자의 input_sha256 과 같아야 함
        │
        ▼
   candidate 를 MIRROR manifest 에만 추가
        │
        ▼
   `yarn install --mode=update-lockfile --no-immutable` (link 단계 없음, lifecycle script 없음)
        │
        ▼
   호출자 input 을 다시 hash ── 바뀌었나? ──► 무효화 (동시 프로젝트 편집)
        │
        ▼
   생성된 lockfile 위에서 `yarn info -A -R --json` → candidate closure
        │
        ▼
   project_context.type = "yarn-project-materialized-lockfile"
   + materialization { candidate, input_sha256, generated_lockfile_sha256, command, isolation }
```

전 과정에서 호출자의 tree 는 read-only 이고 mirror 만 변경된다. Yarn 실행 전후의 input recheck 가 read/copy race 를 닫는다. 중간에 manifest 나 lockfile 편집이 끼어들면 뒤섞인 프로젝트 상태에 대한 승인을 내주는 대신 candidate 를 무효화한다. 승인의 truth 는 registry probe 도 아니고 호출자의 낡은 lockfile 도 아니다. 호출자 자신의 input 을 hash 로 묶어 복사한 것에서 유도된 Yarn resolution 이며, input hash 와 생성된 lockfile hash 둘 다 ledger evidence 로 기록된다. 모든 실패 경로(input 복사, context drift, Yarn 호출, candidate 해석 불가)는 `project-candidate-materialization-unavailable` 로 거부한다. published-closure fallback 은 없다.

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

**guard 는 자기 예산을 따로 갖는다.** 런타임은 이 훅에 고정 예산을 주고(인스톨러가 등록한다) 그게 지나면 죽인 뒤 tool call 을 그대로 진행시킨다 — Claude Code 에서 실측(2026-08-04). 커맨드 스캔은 길이에 대해 초선형이라 그 예산은 패딩만으로 닿는다: 여기 실측으로 커맨드 텍스트 28KB 가 29s, 32KB 가 38s 였다. 그 선을 넘으면 게이트가 아무 말 없이 사라졌고, `pip`·`cargo`·`go`·`gem` 처럼 이 게이트가 advisory 가 아니라 권위인 생태계에서는 스캐너를 전혀 몰라도 되는 우회다.

런타임의 타임아웃 동작은 safedeps 소관이 아니지만, 그게 발동하기 전에 답을 내는 것은 소관이다. guard 는 판정을 자식 프로세스에서 `SAFEDEPS_SELF_BUDGET_SECONDS`(기본 20) 아래 돌리고, 그 자식이 기한까지 답을 못 내면 guard 가 대신 답한다: deny — 판정하지 못한 설치는 돌면 안 되기 때문이다. 그 deny 가 지켜야 할 두 가지 — fail-closed 이지만 **적발이 아니다**(사유가 `UNDECIDED, not unsafe` 로 시작하고 아무것도 탐지되지 않았음을 명시한다. "못 끝냈다" 와 "찾았다" 를 구분 못 하는 독자는 게이트를 우회하는 법을 배운다), 그리고 다른 모든 우회·불가용과 마찬가지로 `advisory.log` 에 기록된다.

**그 예산은 낮추는 것만 된다.** `SAFEDEPS_SELF_BUDGET_SECONDS` 는 25s 상한으로 클램프된다. 낮추는 쪽은 자유다 — 짧은 예산은 더 일찍 거부할 뿐이다. 반대로 런타임 예산 이상의 값은 예산이 아니다: 런타임이 훅을 먼저 죽이고 tool call 은 그대로 진행되는, 이 기계장치가 없애려던 바로 그 fail-open 이다. 그리고 그 값을 올릴 동기는 아주 자연스럽다 — 큰 커맨드에서 `UNDECIDED` 를 만난 사람은 "예산이 짧네" 로 읽고, 보안 경계를 끌 의도 없이 끈다. 사용자가 옮길 수 있는 경계는 경계가 아니라 기본값이다. 클램프는 예산이 실제로 작동하는 지점에서 알린다 — stderr, `advisory.log`, 그리고 deny 사유. 조용히 깎으면 사용자는 한 번도 참이었던 적 없는 숫자를 놓고 디버깅하게 된다.

값은 무엇이 비교되기 전에 정규화되고, 산술에는 정규화된 숫자만 들어간다. 이 순서가 핵심이다 — bash 산술은 `^[0-9]+$` 검사보다 넓은 문법을 받으므로, 정규식으로 검증하고 마감은 원본 문자열을 소비하면 `+40`·` 40`·`0x28` 이 클램프를 건너뛴 뒤 그대로 40 으로 평가된다. 공백 하나로 fail-open 이 복원되는 것이다. 앞뒤 공백과 선행 `+` 는 친 사람의 의도대로 읽고, 그 밖의 값은 예산이 아니므로 기본값으로 돌아간다 — 상한 안쪽이고, 클램프와 같은 채널로 알린다.

크기보다 길이를 먼저, 그것도 문자열 영역에서 검사한다. bash 정수는 64비트이고 조용히 감기기 때문이다. 음수로 감긴 값은 상한보다 크지 않으므로 클램프를 그대로 통과하고, 밀리초로 곱하면 한 번 더 감겨 영영 오지 않는 마감이 된다 — 실측으로 30자리 예산이 600s 를 넘겨도 답을 내지 않았다. 어느 방향으로 감기는지가 값에 따라 갈리므로 감김에 기댈 수 있는 건 없다. 그래서 아홉 자리를 넘는 숫자는 산술이 보기 전에 자릿수로 클램프한다 — 아홉 자리는 초로 약 31년이라 실제 예산에서 한참 멀고, 마감 곱셈이 감당할 수 있는 범위 안쪽으로도 한참 여유가 있다.

**30s 는 어디서 오고, 무엇이 이 숫자를 낡게 만드나.** 훅 페이로드는 런타임 예산을 싣지 않고, 여러 settings 파일의 훅 등록이 모두 발화하므로 가드는 자기를 띄운 등록이 어느 것인지 런타임에 알 수 없다. 대신 할 수 있는 것은 safedeps 자신이 등록하는 숫자를 명시하는 것이다 — `scripts/install/install-safedeps-hooks.mjs` 의 `PRE_HOOK_TIMEOUT_SECONDS`, 30s, 실측 kill 시각과 일치한다. smoke 테스트가 두 상수를 함께 고정하므로, 인스톨러가 바뀌었는데 가드만 낡은 숫자로 상한을 계산하는 상태는 나올 수 없다. 상한과 런타임 예산 사이 5s 는 가드가 **예산 창 바깥에서** 쓰는 비용이다: 마지막 폴 스텝을 기다리는 데 최대 1s, KILL 전 TERM 유예 최대 0.5s, reap·`jq`·프로세스 시작에 약 0.1s — 구조적 최악 1.6s 이고, 실측 종단 초과분은 0.73~1.05s 로 커맨드 4KB 에서 256KB 까지 평평했다. 등록된 타임아웃을 손으로 30s 아래로 고친 사용자는 이 상수가 알 수 있는 범위 밖이다.

마감은 자식 셸이 아니라 **자식의 프로세스 트리 전체**에 집행된다. 셸은 포그라운드 외부 명령이 도는 동안 시그널에 반응하지 않고 판정의 비싼 부분이 정확히 그런 명령이라, 셸에만 시그널을 보내면 그 명령이 끝나는 시점에야 닿는다 — 20s 예산에서 9.1s 지연 실측이고, 이는 자체 예산이 만들려던 여유를 통째로 소진한다. 하위 프로세스는 이름 패턴이 아니라 자식 pid 에서 유도해 TERM 후 짧은 유예 뒤 KILL 한다. 같은 이유로 가드는 `EXIT` 만 트랩하고 `TERM` 은 절대 트랩하지 않는다 — `trap` 에 시그널을 적는 순간 기본 처분이 대체되고, TERM 을 트랩한 자식은 자기 마감에서 살아남는다.

`SAFEDEPS_BUDGET_ENGAGE_BYTES`(기본 1KB) 이상인 커맨드만 추가 프로세스 비용을 낸다. 그 아래에서는 판정이 예산의 약 300배 안쪽에서 끝나므로 이 기계장치는 에이전트의 모든 Bash 호출에 얹히는 순수 오버헤드일 뿐이다. 이 engage 크기는 성능 게이트지 보안 경계가 아니다 — 보안 경계는 벽시계 예산이고, 그건 이 숫자를 잰 머신보다 빠르든 느리든 정직하게 유지된다.

**그런데 상한 없이 올릴 수 있는 성능 게이트는 off 스위치다.** engage 크기는 마감 전체에 걸린 유일한 조건이라, 문제되는 커맨드보다 크게 올리면 그 커맨드들에서 마감이 통째로 사라진다 — 실측으로 32KB 패딩된 `pip install` 이 기본 engage 에서 21s, 올린 상태에서 198s 였고, 런타임은 어느 쪽이든 자기 예산에서 훅을 죽인다. 그래서 4KB 로 클램프한다. 그 선 바로 아래 커맨드도 약 0.68s 에 판정되므로 런타임 예산의 약 44배 안쪽이다. 기본값 1KB 와 그 상한 사이의 튜닝은 이 노브의 본래 용도이고 그대로 남는다. 클램프는 예산 쪽과 같은 3채널로 알린다.

스폰된 자식에게 자기가 자식임을 알리는 마커는 환경변수가 아니라 argv 로 다닌다. 환경변수였을 때 그건 이름 없는 두 번째 off 스위치였다 — export 하면 부모가 자기를 이미 자식으로 알고 마감을 건너뛰었고, 3s 에 답하는 입력이 32s 가 되면서 stderr 에도 `advisory.log` 에도 아무것도 안 남았다. 엔진은 인자를 넘기지 않는 shim 을 통해 훅을 부르므로 argv 는 환경이 닿을 수 없는 채널이다. 옛 변수는 여전히 감지해서 "무시됨" 으로 보고한다 — 마감을 끄던 신호가 조용히 무력해지는 것도 같은 종류의 침묵이기 때문이다.

마감을 끄는 것은 이름이 다른 별개의 행위다: `SAFEDEPS_BUDGET_DISABLED`. 배터리에는 이게 필요하다 — 통과만 알고 결함을 잡는지는 모르는 테스트는 증거가 아니라서, mutation check 가 마감 없는 경우를 만들어낼 수 있어야 한다. 그걸 engage 크기로 하면 튜닝과 비활성화가 같은 동작이 되고, 그게 바로 마찰 조정이 아무도 결정하지 않은 채 경계를 지우는 경로다. off 스위치는 다른 일을 하지 않고, 이름이 하는 일을 말하며, 발동할 때마다 기록된다. 회귀: `scripts/test/self-budget.sh`.

**기록을 검사 밑에서 빼낼 수 없다.** `advisory.log` 는 모든 우회와 불가용이 적히는 자리이고, `re-check` 는 그 파일을 "이 승인이 실제로 있었나" 의 oracle 로도 읽는다. 경로가 `SAFEDEPS_ADVISORY_LOG` 에서 오는 동안에는, 위조 ledger 항목을 쓰는 그 환경이 oracle 에게 자기가 만든 증거를 건넬 수 있었다 — 실측으로 `suspected_forgery` 로 잡히던 항목이, 변수를 "그 승인은 있었다" 고 적힌 호출자 작성 파일로 돌리자 잡히지 않았다. 이제 경로는 `SAFEDEPS_HOME` 에서 유도되므로 기록과 그것이 보증하는 ledger 는 같이 움직이거나 아예 안 움직인다. 설정됐지만 무시된 변수는 stderr 와 로그 양쪽에 그 사실을 말한다.

**옮겨진 출처로 판정한 실행은 그렇다고 말한다 — 모든 경로에서, 그리고 그 목록은 완전성 주장이 아니다.** `SAFEDEPS_OSV_API_URL`(또는 KEV/GHSA URL, closure fixture, 기본값 아닌 ledger TTL)을 다른 곳으로 돌리는 것은 실재하는 필요다 — osv.dev 를 막는 망의 사내 미러, 테스트 스위트의 fixture. 그래서 아무것도 금지하지 않는다. 잘못된 것은 옮겨진 정본으로 답한 실행이 OSV 로 답한 실행과 똑같이 보이는 쪽이다. 각 이탈은 실행당 한 번, 이름과 함께 `advisory.log` 에 기록된다. 그 고지는 provider 스택이 아니라 `lib/truth-sources.sh` 에 있다 — PreToolUse 가드도 같은 말을 할 수 있어야 하는데, 모든 Bash 호출마다 provider 스택을 sourcing 할 수는 없기 때문이다. 가드는 그 파일 하나만, 그것도 무언가 실제로 설정됐을 때만 읽는다. 기본값과 비교가 같은 파일에 있으므로 실행은 자기가 대입받은 값과 대조된다. 거기 열거된 노브 집합은 **발견된 범위**다 — 그중 둘은 스스로 완전하다고 적은 앞선 열거 뒤에 검증자가 찾아냈다. 그래서 늘어나는 목록으로 적어 뒀다.

npm ecosystem 명령이면 guard 도 위와 같은 Yarn project context 를 해석해(`SAFEDEPS_NPM_PROJECT_DIR` 를 project directory 로 고정) 그 `context_hash` 를 ledger 조회에 접어 넣는다 — 그래서 project-scoped 승인은 그 프로젝트 안에서만 guard 를 통과한다. context 가 invalid 하면(resolutions 는 있는데 lockfile 을 못 씀) package-only 조회로 넘어가지 않고 명령을 그대로 거부한다.

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

**이 게이트도 같은 예산을 받고 같은 방식으로 죽는다 — 가정이 아니라 실측이다.** PreToolUse 동작을 확정한 그 프로토콜로(샌드박스 프로젝트, 시작과 완료를 각각 기록하는 훅, 예산 내 통제군과 예산 초과 실험군) 쟀더니, 5s 예산에 20s 작업을 준 PostToolUse 훅은 시작만 하고 끝내지 못했고 1s 통제군은 끝냈다. 위 작업은 safedeps 가 통제하는 것이 아니라 사용자 프로젝트와 네트워크에 매인다: `npm ci`, `npm install`, `npm rebuild`, 그리고 closure 전체에 대한 OSV 배치.

그래서 "효과게이트가 커맨드 게이트를 받쳐준다" 는 문장은 예산 **안에서만** 참이고, 실패의 종류는 더 나쁘다: 죽은 pre 훅은 판정 못 한 커맨드 하나를 통과시키지만, 죽은 post 훅은 롤백 도중에 떨어질 수 있다. 시간이 다했을 때 pre 훅의 답은 deny 지만(Phase 2), 설치 후 게이트는 deny 할 수 없다 — 커맨드가 이미 돌았다. 그래서 그 답은 별개의 설계 문제이고 `safedeps/effect-gate-killed-mid-rollback` 으로 추적하며 여기서 풀지 않는다. Codex CLI 의 타임아웃 동작은 두 훅 모두 여전히 미측정이라 parity 를 가정하지 않는다.

### Phase 0 — 설치되는 커맨드는 엔트리 셔틀이다 (`safedeps-hook-entry.sh`)

두 엔진 모두 훅 이벤트당 하나의 커맨드를 등록한다: `…/skills/safedeps/scripts/safedeps-hook-entry.sh pre|post`. 이 경로는 매 Bash tool call 마다 `~/.claude`/`~/.codex` 스킬 심링크를 거쳐 라이브 레포 체크아웃으로 해석된다. 작업트리가 곧 런타임이다. 그래서 머지 중·편집 중·업데이트 중인 체크아웃은 훅 동작을 즉시 바꾸는데, 셔틀이 생기기 전에는 그다음에 벌어지는 일이 우연한 종료코드로 결정됐다. bash 문법 오류(머지 충돌 마커)는 exit 2 로 끝나고 두 엔진 모두 이를 차단 deny 로 취급해서, 이 머신의 모든 세션이 파서 메시지 한 줄만 남기고 Bash 를 잃었다(2026-08-04 실제 발생). 파일 부재는 exit 127, 런타임 크래시는 exit 1 — 둘 다 *비차단* 훅 실패라서, 그런 형태의 깨짐은 설치 게이트를 조용히 통째로 없앴다.

셔틀은 두 결과를 모두 설계된 것으로 만든다. 진짜 훅은 의도된 모든 경로에서 exit 0 이므로(결정은 JSON 으로 나간다), 비영 종료는 곧 소스 자체가 아프다는 뜻이다. 셔틀은 깨짐을 분류하고(파싱 불가 / 크래시 / 부재), 체크아웃에 머지·리베이스가 진행 중인지 확인해 그렇다고 말한 뒤, 머신 전체라는 폭·원인·복구 경로를 담은 메시지와 함께 exit 2 로 끝난다. fail-closed 는 fail-closed 로 남는다 — 익명이기를 멈출 뿐이고, fail-open 형태들은 침묵하기를 멈춘다.

실측 비용: Bash call 당 ~7 ms (가드 베이스라인 ~34 ms 위). 남는 창도 정직하게 적는다: 셔틀 자신이 깨지면 셔틀 이전의 status quo 로 강등된다(원시 파싱 오류와 함께 차단 — 더 넓어지지는 않는다). 셔틀은 활발히 개발되는 가드와 달리 작고 거의 안 바뀌는 파일이다. 체크아웃 전환 중 셔틀 파일이 없는 밀리초 창은 비차단 침묵 실패로 남는다 — 훅 파일 부재에 대한 셔틀 이전 동작과 같다. 이 전부의 회귀 배터리가 `scripts/test/hook-entry.sh` 다.

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
- 설정된 Claude/Codex hook 경로 밖에서 사람이 직접 실행한 package-manager install. 이런 변경은 release-time gate 가 backstop 으로 잡을 수 있지만, install-time approval 을 증명하지는 않는다.
- 같은 OS 사용자 권한으로 `~/.safedeps/approved-specs/` 를 직접 작성/수정하는 공격. ledger 는 로컬 convenience cache 이며, 서명/HMAC 또는 install-time 재조회가 도입되기 전엔 same-user 공격의 보안 경계가 아니다. (단 effect gate 의 OSV 재조회는 *알려진 취약* 패키지에 대한 위조 승인은 여전히 잡는다 — [`ROADMAP.md`](./ROADMAP.md) "Ledger 변조 내성" 참고.)

---

## 6. Provider 실패 모드 (no silent fallback)

```
OSV.dev — 응답 무 / timeout
  • 1차: 로컬 provider cache (24h TTL) 사용
  • cache miss → fail-closed (block; "OSV 응답 없음, 재시도")
  • install-time CLI bypass flag 는 없다; OSV 또는 cache 가 응답할 때 재시도한다

CISA KEV — 응답 무
  • KEV 는 하루 1회 download 하는 정적 catalog; 로컬 cache 만 사용
  • 24h 이상 stale 이면 경고

GHSA / NVD — 응답 무
  • enrichment 라 fail-open 허용
  • OSV 결과로만 진행 + "GHSA cross-check skipped" 로그
```

설계 원칙: **silent fallback 금지.** canonical truth(OSV)가 응답하지 못하고 cache 도 없으면, safedeps 는 secondary truth 나 숨은 bypass 를 만들지 않고 fail-closed 한다.

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

OSV 가 ecosystem 이름을 정규화해줘서 advisory-check 시점엔 single API 로 전부 cover 한다. ecosystem 별 typosquat 명단·install-script 위험 패턴은 별도 정적 list 다. npm effect gate(closure-vs-ledger enforcement)는 현재 npm 한정이고, 나머지는 command-gate + reorg 모델을 쓴다. npm 으로 라우팅되는 lockfile 중 project-scoped closure resolution(4장 Phase 1)을 받는 건 Yarn 하나뿐이며, 루트 `resolutions` entry 가 있을 때만이다. 일반 npm 은 published-package probe 를 쓰되, 소비 레포에 `overrides` 가 있으면 그것을 probe 에 반영하고 그 승인을 override 집합에 스코프한다(4장 Phase 1). pnpm 은 항상 순수 published-package probe 를 쓴다.

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
| `lib/ledger/` | approved-spec ledger I/O — atomic write, hashing, TTL 검사, project-context-scoped key. |
| `lib/npm/closure.sh` | lockfile 에서 npm closure 해석, 더해 Yarn project context/closure 해석 (루트 `resolutions` + `yarn info`) 과 isolated candidate materialization. |
| `lib/gates/` | release-time repo lane — `scan.sh`(gitleaks runner), `audit.sh`(멀티-ecosystem lockfile audit — npm/pnpm/yarn/bun, 각 네이티브 도구에 위임), `hooks.sh`(`install`/`check`/`init`), `doctor.sh`(자세 진단 + `--fix`), `repo-profile.sh`(public/private 판별). *실행*을 소유하고 *policy* 는 repo 가 소유. |
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
- Yarn project-scoped closure 는 `PATH` 상의 Yarn CLI 와 Yarn Berry lockfile(`__metadata:` 존재)이 필요하다. Yarn Classic(`yarn.lock` v1)이나 루트 `resolutions` 가 없는 workspace 는 일반 npm package-only check 로 떨어진다.
- candidate materialization 은 추가로 Yarn 이 mirror 를 offline 또는 network 로 해석할 수 있어야 하고, 루트 manifest 의 `workspaces` 패턴이 평범한 상대 glob 이어야 한다. 절대경로, 루트를 벗어나는 경로, `**`, 부정(`!`) 패턴은 추측하지 않고 거부하며 candidate 는 deny 된다.

**미래 방향** ([`ROADMAP.md`](./ROADMAP.md) 참고):

- non-npm ecosystem 의 effect-기반 closure enforcement.
- Ledger 변조 내성 (OSV-as-authority + 변조 탐지; 로컬 서명 안 함).
- Plugin provider, `.safedeps.toml` policy file, CI mode, multi-machine ledger sync, 에이전트의 안전 대체 모듈 제안.
