# Safedeps

> **모든 install 을 미확정 블록으로 본다 — `safedeps` 는 안전한 것만 승인하고, 그렇지 않으면 reorg 한다.**
>
> OSV / CISA KEV / GitHub Advisory 로 의존성 spec 을 사전 승인하고, Claude Code 와 Codex CLI 의 hook 에서 실제 설치 closure 를 강제하며, 승인과 어긋난 install 은 자동으로 마지막 안전 snapshot 으로 롤백한다.

*Detailed reference → [README.md](./README.md) (영문, SSoT)*

---

## "reorg" 는 뭐고 왜 그 비유인가

블록체인에서 **reorg (재편성)** 은 미확정 블록 시퀀스를 무효화하고 마지막 확정된 안전 상태로 체인을 되돌린다. `safedeps` 는 같은 원리를 `node_modules` 에 적용한다 — 모든 install 은 일련의 공급망 보안 검사를 통과하기 전까지는 **미확정 블록 후보** 로 취급된다. 의심스러우면 도구가 **reorg** 를 수행한다 — lock 파일, `package.json`, `node_modules` 를 마지막 확정된 안전 snapshot 으로 되돌린다.

수동 리뷰 없음. 잔여 악성 코드 없음. 완전 자동.

---

## 두 lane

`safedeps` 는 두 보안 lane 을 소유한다 (전체 설계: [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1):

- **install-time** (이 README 의 초점) — advisory gate + approved-spec ledger + PreToolUse/PostToolUse hook + post-install reorg. 패키지 단위, 설치 전.
- **release-time** — `safedeps gates run`, `safedeps scan secrets [--repo|--worktree|--staged]`, `safedeps audit npm`, `safedeps hooks install|check`. repo 트리 secret scan, 의존성 audit, repo-local git hook 설치/검사 (push/release 전). repo-specific policy(gitleaks config, privacy 경로)는 대상 repo 에 남고 safedeps 는 실행 owner. *(옛 `security-release-gates` 흡수.)*

---

## 어떻게 동작

```
                         PreToolUse                          PostToolUse
                  (safedeps-pre-guard.sh)          (safedeps-post-verify.sh)
                            |                                    |
  install cmd ──> [ Advisory / ledger gate ] ──> [ Execute ] ──> [ Verify ]
                     |              |                          |       |
                  미승인이면      lock / manifest          깨끗?     의심?
                  block         snapshot                   |       |
                                                       Confirm   REORG
```

### 3 단계 구성

1. **Phase 1 — Advisory Gate** (사용자 또는 에이전트 단계): `safedeps check <ecosystem> <pkg>@<range>` 로 OSV (canonical) + CISA KEV (hard-risk overlay) + GHSA (enrichment) 를 조회. npm 은 temp dir 에서 `npm install --package-lock-only --ignore-scripts` 로 script 실행 없는 lockfile 을 만들고 full closure 를 OSV `/v1/querybatch` 로 조회한다. 안전한 direct spec 과 `transitive_specs` 를 `~/.safedeps/approved-specs/<hash>.json` 에 30일 TTL 로 기록.
2. **Phase 2 — 빠른 command guard** (`safedeps-pre-guard.sh`): PreToolUse hook 이 install 명령 본문의 `pkg@version` 토큰을 승인 ledger 와 매칭하고 snapshot 을 준비한다. miss / expired 면 modern PreToolUse decision JSON 으로 차단하고, 에이전트가 다음에 실행할 `safedeps check ...` 명령을 reason 에 박는다 (PATH 에 있으면 `safedeps`, 없으면 절대경로 — 그대로 실행 가능) → 에이전트는 그 메시지 받아 check → 다시 install 의 자동 루프. PATH 심링크 없이도 self-contained.
3. **Phase 3 — Effect Gate + Reorg** (`safedeps-post-verify.sh`): install 후 실제 npm `package-lock.json` closure 전체를 direct ledger + `transitive_specs` 와 대조하고 OSV batch 로 재확인한다. 미승인/취약/provider fail-closed 또는 의심 install script / native binary 가 있으면 마지막 confirmed snapshot 으로 자동 reorg.

---

## 어떤 명령을 보호하는가

| Ecosystem | 매칭하는 명령 |
|---|---|
| npm / pnpm / yarn | `npm install`, `npm add`, `pnpm add`, `yarn add`, `npx`, `pnpm dlx`, `yarn dlx` 등 |
| pip / poetry / uv / pipenv | `pip install`, `poetry add`, `uv add`, `uv pip install`, `pipenv install` |
| cargo | `cargo add`, `cargo install` |
| go | `go get`, `go install` |
| ruby | `gem install`, `bundle add` |
| maven / nuget | `mvn dependency:get`, `dotnet add package` |

---

## 설치

### 1) GitHub clone (skill 본체 설치, canonical)

```bash
git clone https://github.com/aldegad/safedeps.git
cd safedeps
node scripts/install/install-safedeps-hooks.mjs
```

Cross-engine installer 가 `~/.claude/skills/safedeps` 와 `~/.codex/skills/safedeps` 로 심볼릭 링크하고, `~/.claude/settings.json` 과 `~/.codex/hooks.json` 의 PreToolUse / PostToolUse hook 을 idempotent 하게 등록한다. backup-before-write. `--uninstall` 로 제거 가능.

### 2) npm 패키지 (CLI 편의 설치)

```bash
npm install -g @aldegad/safedeps
safedeps version
```

npm 은 표준 `bin` 엔트리로 `safedeps` 를 PATH 에 올린다. **에이전트 skill / hook 등록은 별도** — Claude Code / Codex 에서 자동 enforcement 가 필요하면 설치 후 한 번 더:

```bash
cd "$(npm root -g)/@aldegad/safedeps"
node scripts/install/install-safedeps-hooks.mjs
```

### 일일 재검증 (macOS LaunchAgent, 옵션)

```bash
node scripts/install/install-safedeps-recheck-agent.mjs install --hour 9 --minute 0
```

매일 1회 `safedeps re-check --json` 을 돌려 ledger 의 모든 승인 spec 을 재조회. LLM 토큰은 안 쓴다 (OSV / CISA / GHSA provider 호출만). 새 CVE / KEV / provider skip 이 발견되면 spec 을 revoke 하고 macOS notification 을 띄운다.

---

## 실제 supply-chain 공격에 어떻게 대응되나

| 사건 | 어떤 체크가 잡는가 |
|---|---|
| `event-stream` (2018) — `postinstall` 의 난독화 코드가 암호화폐 지갑 키 유출 | install script 분석 (난독화 + 네트워크 액세스 탐지) |
| `ua-parser-js` 탈취 (2021) — `preinstall` 이 cryptominer 다운로드·실행 | install script 분석 (네트워크 + 코드 실행) |
| `colors` / `faker` sabotage (2022) — 비정상적 dep 폭증 | dep explosion 검사 |
| typosquat 캠페인 (`crossenv`, `babelcli` 등) | pre-flight typosquat 패턴 매칭 |
| dependency confusion — 사내 패키지명을 public 에 더 높은 버전으로 publish | 비표준 registry 탐지 + 큰 dep 변경 검사 |

---

## 로그와 snapshot

| 경로 | 내용 |
|---|---|
| `~/.safedeps/advisory.log` | Advisory gate 의 모든 approve / block 결정 |
| `~/.safedeps/reorg.log` | Reorg 이벤트 history (timestamp, 사유, 되돌린 파일) |
| `~/.safedeps/approved-specs/` | 승인된 spec JSON 들 (per hash) |
| `~/.safedeps/snapshots/` | install 전 lock / manifest snapshot |
| `~/.safedeps/confirmed_<dir>` | 프로젝트별 마지막 confirmed snapshot id |
| `~/.safedeps/recheck.log` | 일일 재검증 wrapper 로그 |
| `~/.safedeps/recheck-alerts.jsonl` | 재검증으로 발견된 새 CVE / KEV / revoke 알람 jsonl |

---

## 다른 도구와 뭐가 다른가

`safedeps` 는 **AI 에이전트가 코딩 중 install 명령을 작성하는 순간**에 끼어드는 도구다. CI 스캔, PR 권장, runtime sandbox 처럼 다른 시점에서 동작하는 도구들과 핵심 차별점이 여기 있다.

전형적인 흐름:

1. 에이전트가 `npm install foo@1.2.3` 같은 명령을 작성한다.
2. PreToolUse hook 이 그 spec 이 승인 ledger 에 있는지 확인. 없으면 install 을 **차단**하고, 다음에 실행할 정확한 `safedeps check npm foo@1.2.3` 명령을 reason 에 박아 에이전트에게 돌려준다.
3. 에이전트가 그 안내를 받아 `safedeps check` 를 호출 → OSV / CISA KEV / GitHub Advisory 조회 → 안전하면 **허용목록 (ledger) 에 박는다**. KEV 매치면 hard-block (override 불가), CVE 에 patch 가 있으면 안전 버전으로 자동 narrow.
4. 다시 install 시도 → 이번엔 ledger 매치되어 **통과**.
5. install 후 PostToolUse hook 이 lockfile / install script / native binary 를 검증. 어긋나면 마지막 안전 snapshot 으로 **자동 reorg**.

이 흐름으로 일반적인 package-manager install 명령은 실행 전에 advisory 통과를 거치게 된다. 다만 hook 은 best-effort 명령 휴리스틱이지 sandbox 가 아니다. 비정상 wrapper/interpreter 경로나 같은 사용자 권한으로 로컬 safedeps 상태를 조작하는 공격은 ledger 서명/강화 전까지 trust boundary 밖이다. SaaS 의존 없이 로컬 + 공개 DB (OSV / KEV / GHSA) 만 쓴다.

---

## Legacy 마이그레이션 (v1 사용자만)

v1 시절 이름이 `npm-reorg-guard` 였고 state 디렉토리가 `~/.npm-reorg-guard/` 였다. v2 로 rename 되면서 state 도 `~/.safedeps/` 로 옮겨야 하는데, 그 1회 이전을 자동화한 명령이 있다:

```bash
safedeps migrate
```

- `~/.npm-reorg-guard/` 가 있으면 snapshot chain / confirmed / log 들을 `~/.safedeps/` 로 복사하고 legacy 디렉토리를 archive 처리.
- 없으면 no-op (v2 처음 깐 사용자는 무관).

---

## 라이선스

[Apache License 2.0](LICENSE)
