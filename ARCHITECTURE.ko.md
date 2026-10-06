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

**같은 우회가 생태계마다 심각도가 다르고, 그 차이가 핵심이다.** npm 에서 이 경계의 비용은 **지연 탐지**다. 효과 게이트는 npm 이 쓰는 살아 있는 lockfile(`package-lock.json` 과 `node_modules/.package-lock.json`)을 읽고, 그 자신의 설치 인식기는 carrier 열거 없는 raw 텍스트 매치라서 커맨드 게이트가 지나친 바로 그 명령에 발화한다. 인식 못 한 carrier 라도 프로젝트의 node 트리에 썼다면 결국 closure 검사와 rollback 으로 끝난다. `pip`, `cargo`, `go`, `gem`, `maven`, `nuget` 에는 커맨드 게이트 뒤에 closure resolver 가 없으므로 같은 carrier 가 **완전 미탐**이다. post hook 은 명령을 인식하지만 검사할 수단이 없어서 `UNVERIFIED` 만 기록한다. "커맨드 게이트가 이 형태를 파싱하지 않는다" 를 npm 기준으로 읽으면 뭔가가 여전히 지켜보고 있다고 결론짓게 된다. 커맨드 게이트가 권위인 생태계에서는 아무것도 없다.

**npm 의 "지연 탐지" 는 효과 게이트가 완주하는 동안만 성립하고, 그 범위는 주어진 것이 아니라 실측된 구간이다.** 게이트는 30s 로 등록돼 있고 런타임이 거기서 죽인다. 비용은 프로젝트 lockfile closure 에 매이고, 예전에는 머신의 approved-spec 레저에도 매였다 — 게이트가 closure 패키지마다 레저에 따로 물었고, 그 질문 하나하나가 레저 디렉토리 전체를 훑었다. 738개짜리 레저에서는 **closure 4개**에서 30s 를 넘었다. 즉 거의 모든 설치에서 npm 의 지연 탐지는 탐지가 아니었다. v2.16.0 은 패키지마다가 아니라 closure 당 한 번 레저를 읽고, 레저 축은 평평해진다(측정한 모든 closure 크기에서 0.23s). 남은 것은 패키지별로 도는 OSV/KEV 패스다. 같은 머신, cold provider 캐시 기준으로 게이트는 이제 closure **390개** 근처에서 30s 를 넘는다. 그 아래에서 npm 의 지연 탐지는 실제이고, 그 위 — 큰 애플리케이션의 lockfile — 에서는 게이트가 죽고 탐지는 일어나지 않는다. 문제가 되는 머신에서 `scripts/measure/effect-gate-cost.sh` 로 직접 재라. 넘는 지점은 호스트·네트워크·캐시에 따라 움직인다.

**롤백 도중에 게이트가 죽어도 그 사실이 더는 사라지지 않는다.** 롤백은 lock·manifest 파일을 복원한 뒤 프로젝트 자신의 `node_modules` 를 지우는데(예전에는 지우고 다시 만들었다), 예전에는 `reorg.log` 항목과 메시지를 그 전부가 끝난 뒤에야 썼다. 중간 어디서 죽어도 0줄이 남았다 — 프로젝트가 이미 완전히 되돌아간 지점에서도 그랬고, 그러면 사용자의 설치가 아무 설명 없이 사라진다. 이제 게이트는 첫 파괴적 행위 앞에서 롤백 저널 항목을 쓰고 롤백이 자기 보고를 마친 뒤에 지운다. 그래서 자기 실행보다 오래 살아남은 항목 자체가 곧 보고다. 다음 PostToolUse 가 그것을 영구 incident 기록으로 옮기고, 완주한 롤백이 쓰는 바로 그 `reorg.log` 에 `REORG INTERRUPTED` 를 덧붙이고, 어느 단계까지 갔는지, 소유 프로세스가 일하고 있지 않다는 것을 어느 검사가 보였는지, `node_modules` 가 무엇인지, 감시 대상 파일 가운데 스냅샷과 다른 것이 무엇인지를 말한다. 명령도 원인도 주지 않는다. '오래 살아남았다' 는 파일이 있다는 뜻이 아니라 그것을 쓴 프로세스가 없다는 뜻이다 — 진행 중인 롤백은 설계상 자기 항목을 들고 있으므로, 보고는 항목에 적힌 pid 가 사라졌는지로 가른다(v2.16.1). 상태 락은 그 판정을 대신할 수 없다. 훅이 롤백 시작 전에 락을 놓기 때문에 롤백은 락 없이 돈다. 이건 원자성이 아니다 — safedeps 는 npm 트리 재빌드의 원자성을 소유하지 않는다 — 미완의 롤백이 조용하지 않고 크게 남는다는 보장이다. `scripts/measure/rollback-kill-state.sh` 와 e2e 배터리의 양방향 회귀가 고정한다.


이 경계는 실수가 아니고, 넓히는 것도 공짜가 아니다. 이 레포의 두 인식기는 의도적으로 정반대의 정밀도 트레이드를 한다. 효과 게이트의 오탐 비용은 closure diff 한 번이라 인식기가 일부러 느슨하다. 커맨드 게이트의 오탐은 **사용자의 명령을 거부**하므로 인식기가 정밀해야 하고, 열거되지 않은 carrier 는 바로 그 정밀도를 통과한다. npm 의 권위를 애초에 효과 게이트로 옮긴 것과 같은 결론이다. 명령 텍스트는 fail-closed 권위가 될 수 없다. 텍스트로 판정한다는 건 열거해야 하는 구문으로 판정한다는 뜻이기 때문이다.

**백스톱은 흔적을 남긴 명령만 롤백한다.** 효과 게이트의 오탐 비용은 closure diff 한 번보다 컸다. 백스톱의 패턴(`lib/install-grammar.sh` 의 `SAFEDEPS_G_BACKSTOP_RE`)은 아무것도 설치하지 않는 명령에도 걸린다: `grep -n "npm install" README.md`, `git log --grep="npm install"`, `npm run shell:install`. 확정 스냅샷이 있고 closure 가 게이트 밖에서 미승인이 된 프로젝트에서, 이런 명령이 프로젝트를 롤백하고 `node_modules` 를 지웠다. pull 이나 checkout 이 closure 를 그렇게 만들고, 디스크에 아무 변화 없이 30일 뒤 만료되는 승인도 그렇게 만든다. npm 의 숨은 lockfile 을 읽어 `node_modules` 를 남기려던 세 번의 시도는 같은 방식으로 실패했다. 믿은 기록이 디스크를 말하지 않았다(bun 과 pnpm 은 그 파일을 쓰지 않고, npm 자신의 검사도 패키지 안을 보지 않는다). 그래서 백스톱은 더 이상 기록으로 판정하지 않는다. 패턴에 걸리고 렉서가 설치로 읽지 않은 모든 명령 직전에, pre-guard 는 그 도구 호출의 항목을 쓴다. cwd 의 `package-lock.json`, `node_modules/.package-lock.json`, `node_modules` 의 inode 와 두 lockfile 의 상태 변경 시각을 파일 시스템이 남기는 해상도 그대로 적고, 기준선 파일을 하나 만든다. 각 값은 경로 자신의 것이고, 경로가 심볼릭 링크면 링크가 가리키는 것의 값도 함께 적는다. 링크된 lockfile 을 거쳐 쓰면 링크가 아니라 대상의 상태 변경 시각이 바뀌고, 항목이 링크의 것만 담던 동안 그런 쓰기는 흔적이 없었다(lumi r2 S1). 다른 파일로 다시 건 링크는 inode 가 다른 새 링크다. 백스톱은 명령이 node 트리에 썼는지를 디스크에 묻는다. 흔적은 inode 가 바뀐 lockfile 이나 `node_modules`, 전에 있었는데 사라진 것, 전에 없었는데 생긴 것, 변경 시각이 적어 둔 것과 다른 lockfile, 그리고 기준선 뒤에 상태가 바뀐 `node_modules` 안의 무엇이든이다(`find -H node_modules -cnewer <baseline>`. 쓰는 쪽이 정할 수 없는 변경 시각을 읽는다). 1초 아래까지 시각을 남기는 곳에서는 기준선을 2초 앞으로 맞추지 않는다. 예전에는 모든 파일 시스템에서 2초 앞으로 맞췄고, 그러자 grep 0.3초 전의 pull 이 grep 의 흔적으로 세어져 grep 이 `node_modules` 를 지웠다(lumi r1 R1). 한 메시지 안 Bash 두 호출의 간격은 0.16초로 측정됐다. pre-guard 는 방금 만든 기준선 파일과, 프로젝트의 lockfile 과 `node_modules` 의 변경 시각으로 해상도를 잰다. 링크의 대상도 포함한다. 이 모두에 1초 아래 부분이 있지 않으면 트리의 어느 부분은 초 단위로 남기고, 거기서 같은 초 안의 쓰기는 기준선보다 새롭지 않으므로, 기준선을 전처럼 2초 앞으로 맞춘다. 예전에는 1초 아래 시각을 지닌 부분 하나로 충분했고, lockfile 은 나노초를 남기고 `node_modules` 는 초 단위 마운트에 있는 트리에서 기준선의 초 안의 쓰기를 놓쳤다(lumi r2 P3, 실제 HFS+ 마운트에서 5번 중 2번). 비용은 반대쪽으로 든다. exFAT 처럼 100분의 1초까지 남기는 파일 시스템은 읽기 100번에 한 번꼴로 0 인 소수부를 내고, 그런 읽기마다 기준선을 앞으로 맞춘다. 그런 파일 시스템에서는 걸린 명령 전 2초 안의 게이트 밖 변경이 여전히 그 명령의 흔적으로 세어지고, 그 기준선보다 새로운 lockfile 도 그렇다. 어느 규칙이 적용됐는지는 항목에 적힌다. 항목은 도구 호출 하나의 것이다. 이름은 호출의 top-level `tool_use_id` 다. 한 호출의 두 훅이 모두 받고 다른 호출은 받지 않는 값이다. 프로브 훅으로 잰 결과 Claude Code 2.1.288 과 2.1.289 는 `toolu_...` 를, Codex CLI 0.160.0 은 `exec-<uuid>` 를 PreToolUse 와 PostToolUse 에 같게 보낸다. post 훅은 자기 호출의 항목만 읽는다. post 훅이 돌지 않은 호출은 항목을 남긴다. pre-guard 가 통과시킨 뒤 거부된 호출과 실행 중에 취소된 호출이 그렇고, `PostToolUseFailure` 가 등록되지 않은 곳에서는 Claude Code 의 실패한 호출도 그렇다. Claude Code 는 성공한 호출에만 PostToolUse 를 돌린다(없는 경로의 `ls` 는 실패하고, 일치가 없는 grep 은 실패하지 않는다). 설치기는 post 훅을 `PostToolUseFailure` 에도 등록한다. 그 항목은 뒤 호출의 기준선을 옮기지 않는다. 어느 뒤 호출도 그것을 읽지 않기 때문이다. 하루가 지나면 나이 청소가 지운다. 전에는 백스톱이 프로젝트와 명령이 같은 가장 오래된 항목을 읽었고, 실패한 호출 하나가 그 명령의 모든 뒤 호출을 직전 호출부터 판정하게 만들었다(lumi r1 P1). `tool_use_id` 가 없거나 평범한 단어가 아닌 훅 입력에는 항목이 없으므로, 그런 엔진에서 백스톱은 걸린 모든 명령을 항목이 생기기 전처럼 판정한다. 흔적이 없으면 closure 검사도 롤백도 하지 않고, 아무것도 찾지 못한 검사를 `advisory.log` 에 `BACKSTOP UNTRACED` 로 남긴다. clean 백스톱처럼 사용자 메시지는 없다. 흔적이 있으면 전과 같다. 흔적 항목은 pre-guard 의 설치 기록이 아니므로, 백스톱의 머리말은 여전히 기록을 찾지 못했다고 말한다. post 훅은 어떤 기록을 찾기 전에 이 호출의 흔적 항목을 먼저 읽는다. pre-guard 는 한 호출에 기록 아니면 항목 하나만 쓰고, 항목은 호출의 `tool_use_id` 를 이름으로 지닌다. 그러니 항목이 있는 호출은 설치로 읽히지 않았고 기록이 없다. 그런 호출은 항목에 무엇이 담겼든 자기 항목만으로 판정하고, 어떤 기록도 읽거나 지우지 않는다. 이 순서 전에는 항목이 있는 호출이 스냅숏이 사라진 다른 호출의 기록이나 빈 legacy 기록으로 판정됐고, 아무것도 설치하지 않은 명령이 프로젝트를 롤백하고 `node_modules` 를 지웠다(lumi r3 REC). 기록(스냅숏에 meta 파일이 없는 것, 스냅숏을 가리키지 않는 것, JSON 객체 하나가 아닌 것)을 거쳐 백스톱에 오는 명령은 그 호출에 항목이 없을 때뿐이고, 거기서는 흔적이 있는 것으로 친다. closure 를 검사하고, 통과하지 못한 closure 는 롤백한다. 입력에 `tool_use_id` 가 없는 호출과 pre-guard 가 항목을 쓰지 못한 호출이 그렇다. 항목이 다른 디렉터리나 명령에 대해 잡힌 호출, 이를테면 pre-guard 가 post 훅이 가리키는 디렉터리의 부모에서 돈 호출도 기록을 읽지 않는다. 흔적이 있는 것으로 치고, 머리말은 기록을 찾지 못했다고 말한다. 전에는 기록 쪽으로 넘어가 다른 호출의 기록으로 판정됐다(MM, lumi r4). 어느 설치 기록이 어느 설치 호출의 것인가는 그 호출의 `tool_use_id` 가 정한다(5절, 보고의 검사). 검사가 가르지 못하는 것은 모두 흔적으로 친다. 그게 예전 동작이다: 항목 없음(죽었거나 이보다 오래된 pre-guard, 또는 `tool_use_id` 가 없는 입력), 읽을 수 없거나 다른 디렉터리·명령에 대해 잡힌 항목, 사라진 기준선, 실패하거나 기한 안에 끝나지 않은 걷기. 아무것도 찾지 못한 걷기는 모든 항목을 방문하므로 기한이 있다(`SAFEDEPS_BACKSTOP_WALK_SECONDS`, 5초. 낮출 수는 있고 올릴 수는 없다). `scripts/measure/backstop-walk-cost.sh` 가 아무것도 찾지 못하는 걷기를 캐시가 데워진 채로 쟀다: M1 Mac 의 bash 3.2 에서 25만 항목 1.4초, 50만 3.0초, 100만 14초, 리눅스 VM 에서 100만 2.4초. 그래서 그 Mac 에서는 50만 항목 안팎의 트리까지 읽고, 더 큰 트리는 전처럼 판정한다. pre-guard 는 설치로 읽지 않은 명령마다 grep 한 번, 패턴에 걸린 명령에는 항목 하나를 치른다. 부하 0.7 의 리눅스 VM 에서 `scripts/measure/backstop-walk-cost.sh pre` 를 15회씩, 64903ac(흔적 검사 전)와 2f889da 에서 번갈아 두 번 돌린 가드 중앙값은 `ls -la` 가 전 0.131초·0.129초, 뒤 0.142초·0.155초, 위 grep 이 전 0.152초·0.170초, 뒤 0.220초·0.227초였다. `ls -la` 의 차이에는 두 트리 사이 grammar 브랜치의 변경도 들어 있다. 부하 4 의 M1 Mac 에서는 0.144초에서 0.147초로, 0.171초에서 0.255초로 늘었다. 이 값은 621b0dd 에서 잰 것이고, 항목이 lockfile 의 변경 시각을 담고 `tool_use_id` 로 이름 붙기 전이다. 두 측정 모두 항목이 링크의 대상을 읽기 전의 것이고, 그 읽기는 걸린 명령마다 `stat` 과 `ls` 프로세스를 몇 개 더한다. 흔적은 디렉터리의 것이라, 명령이 도는 동안 다른 프로세스가 `node_modules` 에 쓰면(dev server 의 캐시 등) 걸린 명령은 쓴 것으로 읽힌다. `scripts/test/e2e.sh` 의 어느 행도 게이트 밖 변경 뒤에 기다리지 않는다. pull 바로 뒤의 grep, lockfile 을 제자리에서 쓴 바로 뒤의 grep, 원장 만료 뒤의 `git log` 는 아무것도 롤백하지 않는다. 항목을 남긴 호출 뒤의 grep 과 그 뒤의 모든 grep 도 그렇고, 다른 호출의 기록(온전한 것이든 스냅숏이 사라진 것이든)이나 pre-#5 pre-guard 가 남긴 기록 옆에서 항목을 지닌 호출도 그렇다. pre-guard 가 읽지 못한 설치, 링크된 lockfile 을 거친 쓰기, 다른 파일로 다시 건 lockfile 링크, `node_modules` 에만 쓴 것, `tool_use_id` 가 없는 호출, 초 단위 파일 시스템을 흉내 낸 곳의 grep, 기한을 넘긴 걷기는 롤백된다. 나노초를 남기는 lockfile 옆, 초 단위를 흉내 낸 `node_modules` 에 쓴 것은 흔적이다. `scripts/test/effect-trace-grid.sh` 5절은 실제 npm 으로 같은 것을 돌린다: 아무것도 설치하지 않는 스크립트의 `npm run` 은 `node_modules` 를 남기고, `sd-victim` 을 설치하는 스크립트의 `npm run` 은 롤백된다.

커맨드 게이트를 고칠 때의 규칙이 여기서 나온다. 게이트가 이미 선언한 규칙을 그것을 건너뛴 자리에 적용하는 것은 범위 안이다. `| /bin/sh` 와 `| env sh` 를 `| sh` 로 정규화하는 것은 "경로가 붙거나 `env` 가 앞에 붙은 호출은 맨 호출과 같다" 는 게이트 자신의 기존 선언을, 생산자 쪽에만 적용되던 것을 파이프의 소비자 쪽에도 적용한 것이다. 두 가지가 더 같은 움직임이다(v2.18.0). 소비자를 셸의 연산자와 그룹을 거쳐 읽으므로, `| sh; echo`, `(… | sh)`, `|&` 는 게이트가 이미 이름 붙인 그 파이프다. 검사가 셸 이름 뒤에 공백을 요구해서 이들은 판정 없이 통과했었다. 파이프가 넘기는 복합 명령도 끝까지 읽는다(v2.18.1). `| { :; sh; }`, `| if true; then sh; fi`, 반복문 안의 모든 명령은 누군가 다 읽을 때까지 파이프를 읽으므로, 그 안에서 명령 자리에 선 셸이 소비자다. `||` 는 파이프가 아니다. 그 뒤의 셸은 호출자의 입력을 읽는다. 그리고 보이는 설치가 더는 파이프 검사를 끄지 않는다. `pip install requests==2.0.0 && printf 'pip install evil' | sh` 는 `requests` 를 검사하고 `evil` 은 검사 없이 실행했다. 보이는 설치 옆에서도 게이트는 보이는 설치가 없을 때 하는 파이프 질문을 같은 텍스트에 한다. 보이는 설치를 포함한 명령 전체와, 그 안의 `sh -c`·`eval`·치환 스크립트 각각이다. 보이는 설치의 단어를 먼저 떼어 내지 않는다. 떼어 내는 시도가 세 번 있었고, 매번 단독 검사는 거부하고 설치 옆 검사는 통과시키는 파이프가 남았다. 온전한 단어 검색은 `printf '\npip install evil' | sh` 를, 단어 시작 검색은 `%spip` 와 `cut -c2-` 를 놓쳤고(v2.18.0), 설치 자신의 단어를 떼어 내는 방식은 `echo "$_ install evil" | sh` 를 놓쳤다. 셸이 설치의 마지막 단어를 생산자에게 넘기기 때문이다. 생산자는 명령 자신의 텍스트를 `$_`, exec 문자열, `ps`, 파일로 읽을 수 있고 게이트는 그 길을 열거할 수 없다. 그래서 보이는 설치의 어떤 단어도 셸에 닿지 않는다고 주장할 수 없다. 비용은 설치와 상관없는 셸 파이프를 설치와 한 명령에 섞는 명령이다. 그 명령은 거부되고, 둘은 따로 실행해야 한다(v2.18.1). 인식기에 새 carrier 구문을 추가하는 것은 범위 밖이다. 거기가 열거가 수렴 없이 자라는 자리다.

파서 갭을 npm 기준으로 읽던 오해는 한 군데가 아니었다. 원장 게이트 자체가 파싱 가능한 `pkg@version` 피연산자를 조건으로 걸려 있고, 코드가 밝힌 그 근거도 npm 모양이다 — 맨 `npm install` 은 새 패키지를 지목하지 않는 lockfile 설치라 통과시키는 게 **npm 에서는** 맞다. 그런데 `pip install evil` 은 lockfile 설치가 아니다. 패키지를 지목한다. 같은 논리가 이 커맨드 게이트가 권위인 생태계로 그대로 이식됐고, 거기서 그건 버전 없는 설치가 아예 검사되지 않는다는 뜻이다.

방향도 뒤집혀 있는데, 이건 열거로는 절대 안 나오는 부분이다. 숨김 경로는 spec 을 못 뽑으면 거부하고, 평문 경로는 똑같은 조건에서 허용한다. 한 파일 안에서 하나의 조건이 반대 방향으로 읽힌다 — `printf 'pip install evil' | sh` 는 fail-closed 로 거부되는데 `pip install evil` 은 그냥 진행된다.

이 경우는 이제 생태계와 명령을 담은 `UNGATED` 기록을 남긴다. 기록 면제의 기준은 원장 생태계가 아니라 효과 게이트가 결과를 실제로 읽는지다. pnpm·yarn·bun 은 npm 과 원장 생태계를 공유하지만 게이트가 읽는 `package-lock.json` 은 쓰지 않고, v2.18.0 전까지는 그래서 버전 없는 `pnpm add x` 가 기록 없이 통과했다(GitHub #22). 이제 면제는 lockfile 이 기록하는 npm CLI 설치뿐이고, 그것도 PostToolUse 훅이 그 기록을 맡기 때문이다. 게이트가 본 곳에 흔적을 남기지 않은 npm 설치는 무엇을 지목했든 거기서 `UNGATED` 로 기록된다(아래 "디렉터리는 게이트가 볼 곳이다"). 패키지를 받아 오는 실행기는 여기서 기록되고, 프로젝트에는 링크만 떨어지는 `npm link <pkg>` 도 그렇다. 프로젝트에 이미 있는 바이너리를 실행하는 실행기는 받아 오는 게 아니므로 기록되지 않는다. "읽는다" 의 정의는 하나다. 기록은 `resolve_install_targets` 가 나열한 문장을 걷는데, 게이트가 읽을 디렉터리를 고르는 것도 같은 걸음이고, 각 문장은 자기 종류를 함께 싣는다(`guard_effect_gate_reads`). v2.18.0 전에는 기록이 따로 정의를 가졌다. npm 이 `package-lock.json` 을 쓰지 않게 하는 플래그 목록이었고, 둘은 양쪽으로 어긋났다. 목록은 그때 게이트가 읽지 않던 `--no-save` 와 `--save=false` 를 빠뜨렸다. 그리고 지금 게이트가 npm 의 숨은 lockfile 로 읽는 `--no-package-lock` 을 담고 있었다. `sh -c` 나 `eval` payload 안의 npm 설치는 기록된다. 어디에 떨어지는지가 payload 안에서 정해지기 때문이다. 기록의 단위는 피연산자이고, 기록은 각 문장을 spec 추출기와 같은 파싱으로 읽는다. 추출기가 바로 그 토큰에서 spec 을 읽었을 때만 그 피연산자를 고정된 것으로 친다. 그래서 한 패키지는 고정하고 다른 패키지는 버전 없이 지목한 명령이 기록되고, 한 패키지를 고정한 뒤 같은 패키지를 버전 없이 다시 지목한 명령도 같은 문장이든 다른 문장이든 기록된다(`pnpm add x@1 && pnpm add x`). 그 전까지 기록은 두 번째 파서였다. 추출기에게 이름으로 물었고, 이름 키를 좁힐 때마다(토큰 모양, 이름, 생태계와 이름) 같은 이름의 고정이 버전 없는 설치를 여전히 조용하게 만들었다. 같은 분리가 반대 방향으로도 났다. `gem install rails -v 7.1.0` 의 버전을 버전 없는 패키지로 기록했다. 파싱이 하나라서 오독도 드러난다. 추출기가 토큰을 잘못 읽으면 그 토큰은 추출기가 낸 spec 이 아니므로 기록된다. 기록 줄에는 기록한 피연산자가 하나하나 적힌다. 해가 없는 기록 몇 가지는 없애지 않고 선언해 둔다. 없애려면 게이트에 없는 런타임 지식이 필요하기 때문이다. `pip install x==1 x` 를 pip 가 고정 버전으로 푸는 경우, 고정해서 설치한 패키지를 다시 설치해 아무것도 바뀌지 않는 경우, 앞 문장이 설치할 바이너리를 실행기가 부르는 경우, 기록이 모르는 플래그가 값을 받는 경우다. 판정은 하나도 안 바뀐다. 버전 없는 설치를 전부 거부하는 건 평범한 작업 흐름을 깨는 정책 변경이라 레포 소유자 소관으로 남기고, 기록은 그 결정을 추측이 아니라 근거로 답할 수 있게 만드는 것이다. 기록의 침묵도 소음만큼 의도적으로 범위를 잡았고, 기준은 어떤 플래그가 붙었는지가 아니라 패키지를 지목하는지다. 맨 lockfile 설치는 지목하지 않고, 가져오는 게 아니라 작업 트리에서 빌드하는 `pip install .` 도 마찬가지다. 소스 플래그는 자기 인자만 소비하며 어떤 플래그가 값을 받는지는 도구의 속성이다 — pip 의 `-r`·`-c`·`-t`·`-f` 는 받지만 gem 의 `-r` 은 `--remote` 이고 go 의 `-t` 는 불리언이다. 평범한 설치마다 찍히는 기록은 배경 소음이고 배경 소음은 없는 기록과 같지만, 플래그만 보이면 침묵하는 기록은 더 나쁘다 — 없는 커버리지를 있는 것처럼 읽히게 한다.

**어느 파일, 어느 디렉터리를 읽느냐가 그 자체로 우회였다.** 면제는 플래그 철자로 판정됐고, 게이트는 명령이 시작된 디렉터리의 `package-lock.json` 만 읽었다. npm 11.19.0 을 로컬 레지스트리에 붙여, lifecycle 스크립트가 흔적을 남기는 합성 패키지로 쟀다.

| 형태 | npm 이 기록한 곳 | v2.18.0 전 | 지금 |
|---|---|---|---|
| `--no-save`, `--save=false`, `npm_config_save=false`, `.npmrc` 의 `save=false` | `node_modules/.package-lock.json` 에만 | 깨끗하다고 확인한 뒤 `npm rebuild` 가 패키지 스크립트를 돌림 | 롤백, 스크립트 안 돎 |
| `--no-package-lock`, `--package-lock false`, `npm_config_package_lock=false` | `node_modules/.package-lock.json` 과 `package.json` | 같음(`--no-package-lock` 은 `UNGATED` 로도 기록됨) | 롤백, 스크립트 안 돎 |
| `npm -C sub install x`, `cd sub && npm install x`, `cd sub; npm install x` | `sub/package-lock.json` | 깨끗하다고 확인, rebuild 도 안 됨 | 롤백 |
| 훅 cwd 가 `src/`(`package.json` 없음)나 워크스페이스 멤버일 때 `npm install x` | 프로젝트나 워크스페이스 루트의 lockfile | 아무것도 읽지 않음, 기록 없음 | 롤백 |
| `npm_config_global=true npm install x` | npm 전역 prefix, lockfile 없음 | 깨끗하다고 확인, 기록 없음 | `UNGATED` 기록 |
| 프로젝트나 사용자 `.npmrc` 의 `global` 또는 `location=global` | npm 전역 prefix, lockfile 없음 | 깨끗하다고 확인, 기록 없음 | `UNGATED` 기록, 파일 명시 |
| `.npmrc` 의 `global=0`, 또는 거기 둔 `location=global` 과 명령의 `--location=project` | `node_modules`, 두 lockfile 어디에도 없음 | 깨끗하다고 확인한 뒤 `npm rebuild` 가 패키지 스크립트를 돌림 | `UNGATED` 기록, rebuild 는 경고와 함께 건너뜀 |
| 같은 설정으로 이미 기록된 패키지를 설치하거나 갱신 | `node_modules` 에는 새 버전, 두 lockfile 에는 옛 버전 | 깨끗하다고 확인한 뒤 `npm rebuild` 가 새 버전의 스크립트를 돌림 | `UNGATED` 기록, rebuild 는 두 버전을 적은 경고와 함께 건너뜀 |
| 워크스페이스에서 `npm install x -w packages/a` | 루트 lockfile 들과 `packages/a/package.json` | 멤버 키를 미승인 패키지 `packages` 로 읽었고, 롤백 뒤에도 `x` 가 디스크에 남음 | 멤버 manifest 까지 롤백 |

그래서 게이트는 npm 이 설치하는 디렉터리에서 npm 의 두 기록을 모두 읽고, 그 디렉터리가 어디인지는 npm 에게 묻는다. `resolve_install_targets` 는 명령이 npm 을 돌리는 곳까지 따라간다. 존재하는 디렉터리로 가는 리터럴 `cd`, 또는 `env -C` 다. 거기서 설치 명령 자신의 인자와 명령이 주는 환경으로 `npm prefix` 와 `npm root` 를 돌린다(`lib/npm/ask.sh`). 돌리는 것은 훅의 `PATH` 에 있는 자기 npm 이고, 명령이 고른 코드로는 돌리지 않는다. npm 이 시작할 때 코드를 고르는 이름은 싣지 않는다. `PATH` 는 npm 과, npm 의 `#!/usr/bin/env node` 가 띄우는 node 를 고른다. `NODE_OPTIONS` 는 모듈을 먼저 불러온다. `NODE_PATH` 는 npm 이 옆에서 찾지 못한 모듈을 내준다. `OPENSSL_CONF` 와 `OPENSSL_MODULES` 는 node 가 시작할 때 불러오는 provider 라이브러리를 가리킨다. `LD_*` 와 `DYLD_*` 는 동적 로더에 닿는다. `BASH_ENV` 는 npm 이 bash 스크립트일 때 먼저 돈다. `npm_config_node_options` 는 스크립트의 `NODE_OPTIONS` 가 된다(`safedeps_npm_code_name`). 앞의 넷은 node 26.7.0 으로 쟀고, 나머지는 로더·OpenSSL·bash 문서가 말하는 것이다. 질의는 전에 이것들을 실었고 npm 단어도 실었다. 그래서 `PATH=<dir> npm install x`, `NODE_OPTIONS=--require=<file> npm install x`, `<dir>/npm install x` 는 판정 한 번에 명령의 코드를 세 번씩 돌렸고, 게이트가 결국 거부한 명령도 똑같이 돌렸다. 들여보낼지 정하려고 명령의 코드를 돌리는 게이트는 이미 그것을 들여보낸 것이다. 그 밖에 명령이 대입하고 export 하고 unset 한 것은 싣고, `unset NAME` 은 `env -u NAME` 으로 싣는다. `npm prefix` 는 로컬 prefix 를 답한다. 가장 가까운 `package.json` 이나 `node_modules` 까지 올라가는 npm 의 걸음, 워크스페이스 루트, npm 이 읽는 모든 `.npmrc`, `--prefix` 나 `-C` 가 거기 다 들어 있다. `npm root` 는 npm 이 설치해 넣는 디렉터리를 답하고, 그것이 `<prefix>/node_modules` 일 때만 프로젝트 설치다. 그 밖은 lockfile 이 쓰이지 않는 npm 전역 prefix 다. 두 질의는 나란히 돌고, 한 명령의 모든 설치를 합쳐 8초 기한을 둔다.

이것은 npm 의 규칙을 bash 로 옮긴 사본을 대신한 것이고, 그 사본이 이유다. 사본은 판마다 어딘가에서 npm 과 갈렸고, 갈릴 때마다 조용히 통과했다. 이름 붙은 디렉터리를 설치 디렉터리로 삼았을 때는 `cd src && npm install x` 가 프로젝트의 lockfile 에 기록하는 동안 게이트가 `src` 를 읽었다. 그것을 고친 워크스페이스 리졸버는 심링크를 풀었는데 npm 은 풀지 않는다. 루트의 글롭이 `packages/a -> ../real/a` 로 닿는 멤버 `real/a` 에서 npm 은 `real/a` 에 설치했고, 리졸버는 루트로 올라가 깨끗하다고 읽고 패키지를 디스크에 남겼다(검증 2회차, F1). 세 번째 사본은 세 번째 방식으로 틀렸을 것이다. 이제 `scripts/test/install-dir-differential.sh` 가 검증자의 레이아웃 237개와 명령 형태 18개에서 게이트를 `npm prefix` 에 묶고, 차이를 하나도 허용하지 않는다.

npm 이 답할 수 없으면 게이트는 이유를 기록하고 cwd 를 본다. 다른 방식으로 디렉터리를 고르지는 않는다. 설치가 거기 있었는지는 흔적이 정한다(아래). 이유는 훅의 `PATH` 에 npm 이 없을 때, npm 이 실패할 때(읽을 수 없는 `workspaces` 값을 npm 이 거부하면 설치도 실패한다), 기한 안에 답하지 않을 때, 그리고 명령이 셸이 실행 시점에 정하는 것(`cd "$DIR"`, `npm install "$PKG"`, 변수에서 값을 받는 export)이나 이 게이트가 재현하지 않는 `env` 옵션을 npm 에 넘길 때다. 마지막 이유는 질의 자신의 플래그다. 질의는 `--global=false` 가 `-g` 보다 나중에 읽히도록 자기 플래그를 설치의 단어 뒤에 붙이는데, 마지막 단어가 다음 단어를 값으로 받는 설치(`npm install x --cache`)는 그 플래그를 값으로 가져갔다. npm 은 게이트가 명령을 판정하는 동안 프로젝트 안에 `--json` 과 `--global=false` 디렉터리를 만들었다. 그래서 설치의 단어 뒤에 시험 단어 하나를 붙여 읽고(`safedeps_npm_read_args`), 그 단어가 값이나 피연산자가 되면 npm 에게 묻지 않는다. 설치 자신은 다르다. 한 문장 `npm install x --cache` 는 끝에 7d66f8c 의 플래그를 그대로 두고(바닥, 아래), npm 은 그것을 캐시 디렉터리로 받아 프로젝트에 `--ignore-scripts` 를 만든다. 7d66f8c 의 재작성도 그랬다. 거기서 `-C` 면 설치가 `./--ignore-scripts` 로 간다. 스크립트는 돌지 않고(앞의 플래그가 남는다), 게이트는 뒤의 경우를 흔적이 없는 설치로 기록한다. npm 은 시작할 때 캐시 디렉터리도 만들기 때문에, 설치 자신의 `--cache dir` 때문에 질의가 `dir` 을 만들었다. 질의마다 자기 임시 디렉터리 안의 캐시를 쓰고, 그 캐시는 질의가 묻는 어떤 답도 바꾸지 않는다. 워크스페이스 선택자(`-w`, `--workspace`, `--workspaces`)는 질의에서 뺀다. npm 은 `prefix` 와 `root` 에서 이것들을 거부하고, `loadLocalPrefix` 는 `workspaces` 가 false 일 때만 읽으며, 그 false 는 남긴다. 단어는 셸이 나누는 방식대로 읽으므로 따옴표 친 `--prefix "/tmp/x y"` 는 한 경로다. 환경변수 `npm_config_prefix` 는 프로젝트 설치를 옮기지 않고, npm 도 그렇게 답한다. 재 보니 cwd 프로젝트에 떨어졌다. `scripts/test/lockless-forms.sh` 가 표의 모든 행을 종단으로 돌리고, 수리 전 트리에서는 빨강이다.

**npm 은 출력의 일부를 가리므로, 가려진 답은 읽기만 하고 경로로 쓰지 않는다.** npm 11.19.0 은 출력에서 UUID 나 npm 토큰처럼 생긴 것을 모두 `***` 로 덮고, 경로도 예외가 아니며, 끄는 설정이 없다. 세션 UUID 아래의 프로젝트에서 `npm prefix` 는 `.../***/project` 라고 답했다. 에이전트의 스크래치 디렉터리가 흔히 그런 자리에 있다. 게이트는 거기서 프로젝트를 찾다가 승인된 설치를 막았다. 가리지 않은 경로를 npm 에게 따로 물을 방법은 없다. 그래서 게이트는 가려진 답을 cwd 에서 위로 올라가는 디렉터리들과 맞춰 본다. npm 이 스스로 찾는 로컬 prefix 는 늘 그중 하나다. 각 `***` 를 경로 한 조각 안의 숨은 부분으로 볼 때 똑같이 읽히는 디렉터리가 정확히 하나일 때만 답을 그 디렉터리로 받는다. 그렇지 않으면 npm 은 어디인지 말하지 않은 것이고, 대상은 그 이유와 함께 `?` 다. cwd 아래나 다른 곳을 가리키는 가려진 `--prefix` 가 그렇다. 다른 곳을 가리키는 `--prefix` 가 우연히 cwd 위의 디렉터리와 똑같이 읽히면 게이트는 그 디렉터리를 보게 되고, 거기에는 설치의 흔적이 없으므로 `UNGATED` 로 기록된다. differential 은 UUID 이름 디렉터리 아래의 형태 8개를, 같은 레이아웃을 가리지 않은 쌍둥이에서 npm 이 낸 답에 묶고, `scripts/test/effect-trace-grid.sh` 가 그것들을 종단으로 돌린다.

**`.npmrc` 는 명령에 드러나지 않게 설치를 옮기고, 그것은 npm 이 읽는다.** 설치가 어디에 떨어지는지는 npm 의 답이므로 npm 이 읽는 모든 `.npmrc` 가 거기 들어 있다. 전역 npmrc 와 내장 npmrc 도 그렇다. 그중 어디에든 `global=true` 가 있으면 `npm root` 가 전역 트리를 답하고, 그 설치는 `UNGATED` 로 기록된다. 떨어진 곳에 npm 이 기록을 남기는지는 다른 질문이고, npm 은 설치 전에 그것에 답할 수 없다. 설치를 옮기지 않고 그 질문에 답하는 설정이 둘 있다. 재 보니 `global=0`, 그리고 `--location=project` 옆의 `location=global` 은 패키지를 프로젝트의 `node_modules` 에 놓고 두 lockfile 어디에도 적지 않았다. 그래서 pre-guard 는 그 질문 하나를 위해 두 파일의 `global` 과 `location` 을 여전히 읽는다. npm 의 로컬 prefix 에 있는 프로젝트 파일, 그리고 `--userconfig`, `npm_config_userconfig`, `~/.npmrc` 순으로 정해지는 사용자 파일이다. 읽는 방식은 실측에서 npm 이 읽은 방식을 따른다. 키는 대소문자를 가리고, 마지막 줄이 이기며, 프로젝트 파일이 사용자 파일보다 앞선다. 설치를 기록에 남긴 값은 `global=false`, `global=null`, `location=user`, `location=project` 뿐이었으므로, 그 밖의 값은 모두 기록 밖으로 읽는다. 이 읽기는 디렉터리를 고르지 않는다. 게이트가 읽을 설치를 `UNGATED` 로 바꿀 수만 있고, 그쪽으로 틀리면 대가는 한 줄이다. 설치는 기록할 뿐 검사하지 않는다. 검사하려면 npm 이 놓은 곳에서 패키지를 이름으로 찾아야 하는데, 이는 경계로 남긴다. 전역 npmrc 와 내장 npmrc 의 같은 두 설정은 이 질문을 위해 읽지 않는다.

**디렉터리는 게이트가 볼 곳이고, 읽었는지는 설치의 흔적이 말한다.** npm 에게 물으면서 npm 이 설치를 어디에 놓는지는 고쳐졌다. 하지만 npm 이 어느 디렉터리에서, 어떤 환경으로 도는지는 셸이 정하고, 검증 3회차에서 텍스트를 다시 잘못 읽은 형태가 나왔다. `false && cd sub; npm install x` 는 cwd 에 설치하는데 게이트는 실행되지 않은 `cd` 를 따라 `sub` 를 읽었다. `command cd sub`, `builtin cd sub`, `eval cd sub`, `case` 갈래 안의 `cd` 는 `sub` 에 설치하는데 게이트는 cwd 를 읽었다. 매번 설치가 건드리지 않은 디렉터리를 읽고 깨끗하다고 확인해 설치를 읽지 않은 채 통과시켰다. 1·2회차도 같은 모양이었다. 이어진 설계 판정이 세 라운드의 형태와 새 형태를 종단으로 돌려 Claude Code 의 조용한 통과 21행을 셌고, 철자 목록으로는 닫히지 않는다는 것을 확인했다. 명령이 텍스트에 드러나지 않게 npm 이 읽는 것을 바꿀 수 있기 때문이다(`npm init -y`, 명령이 쓰는 `.npmrc`, 상속된 `CDPATH`). 그래서 이제 예측은 볼 곳만 고르고, 설치가 거기 있었는지는 PostToolUse 훅이 정한다.

명령이 돌기 직전에 pre-guard 는 기준 파일을 touch 하고, 고른 디렉터리에 있는 npm lockfile 두 개의 inode 를 적어 둔다. 명령 뒤에 기준 파일보다 `find -newer` 한 lockfile, 또는 inode 가 바뀐 lockfile 이 이 명령의 흔적이다. npm 은 무언가를 설치한 모든 설치에서 `node_modules/.package-lock.json` 을 다시 썼다. 이미 있던 것을 다시 설치할 때도 내용은 같고 mtime 만 바뀌었고, `npm ci` 는 파일을 바꿔 놓았다. 그래서 내용도 초 단위 시각도 쓸모가 없다. no-op 재설치는 둘 다에서 아무것도 보이지 않고, 기준 파일을 touch 한 그 초 안에 끝나는 일이 잦다. 두 lockfile 어디에도 흔적이 없으면 그 설치를 `UNGATED` 로 기록하고, 아무것도 찾지 못한 검사를 그대로 적는다: `no install trace in <dir>: neither npm lockfile there is newer than the baseline taken before this command or has another inode`. 거기서는 rebuild 를 돌리지 않으며, Claude Code 에서는 safedeps 가 rebuild 를 돌리지 않았다고 사용자에게 알린다. 이 검사는 npm 을 띄우지 않는다. dry run 이나 실패한 설치를 다른 곳에 간 설치와 구별하지 못하므로, 기록은 검사를 적고 원인은 대지 않는다. 그것은 소음이지 통과가 아니다.

흔적 하나는 npm 문장 하나에 답한다. 한 명령에 lockfile 을 쓰는 문장이 둘이면 앞 문장의 흔적이 뒤 문장의 오착지를 가렸다. `npm install a; command cd sub; npm install b` 는 두 디렉터리의 lockfile 을 모두 썼고, 게이트는 자기가 읽은 쪽에서 흔적을 찾았다. 그래서 lockfile 을 쓰는 npm 문장(읽기·실행·배포만 하는 하위 명령을 뺀 전부)이 둘 이상이면, 그 사이에 비활성 문장(`echo`, `printf`, `tail`, `head`, `grep`, `ls`, `cat`, `true`, 치환 없이, `/dev/null` 이나 다른 디스크립터 말고는 리다이렉트 없이)만 있고 어느 문장도 스스로 옮기지 않을 때만(디렉터리·전역 플래그, `npm` 앞의 `npm_config_*` 설정이나 다른 단어, 그룹, 실행 시점 단어) 흔적 하나를 나눠 쓴다. 다른 npm 설치 옆에서 `sh -c`, `eval`, `$(...)` 안에 든 npm 설치도 옮긴 것으로 친다. 그 밖에는 명령을 `UNGATED` 로 기록하고, 사이에 무엇이 있었는지 적는다.

예측 쪽에도 바뀐 것이 하나 있다. 실행되지 않을 수 있는 `cd`, 즉 `&&`·`||` 뒤나 `if`·`while`·`until`·`for`·`case` 본문 안의 `cd` 는 그 뒤의 `&&` 사슬 안에서만 유효하다. 그 사슬의 모든 문장은 `cd` 가 성공했을 때만 돌기 때문이다. 사슬을 벗어나면 디렉터리는 그 앞의 것이다. 이로써 `false && cd sub; npm install x` 의 롤백이 돌아오고, `cd X || exit` 은 여전히 따라간다. 실제로 실행된 조건부 `cd`(`[ -d sub ] && cd sub; npm install x`)는 이제 읽히지 않고 기록된다. 흔적이 판정하는 지금, `cd` 를 더 잘 읽는 일은 안전이 아니라 커버리지, 곧 `UNGATED` 줄을 줄이는 일이다.

`scripts/test/effect-trace-grid.sh` 가 격자를 종단으로 돌린다. 모든 행은 롤백되거나 기록되고, Claude 행 어디서도 승인되지 않은 패키지의 스크립트가 돌지 않으며, 무언가를 설치한 17형태는 흔적을 남기고 조용히 확인되고, 기준 파일의 초 안에 끝난 no-op 재설치도 잡힌다. 같은 배터리를 이 변경 전 트리에서 돌리면 조용한 통과 행이 드러난다.

**설치 문법은 그 규칙을 한 곳에서 적용한다.** v2.18.0 은 인식기를 매니저가 문서화한 표기와 셸이 허용하는 표기에 대고 쟀고, 대부분이 판정도 기록도 없이 통과했다: 별칭(`pnpm i`, `npm isntall`, `yarn up`, `bun a`), 동사 앞의 옵션 여러 개(`pip --quiet install`), 버전이 붙은 인터프리터(`pip3.11`), 실행기(`npx <pkg>@<ver>` 는 한 글자 이름만 맞았고 `npm exec`·`bunx`·`uvx`·`pipx run` 은 몰랐다), 문장 위치(`( ... )`, `then`, `do`, `!`, `time`), 따옴표로 감싼 spec, 플래그로 넘긴 버전(`cargo install x --version 1`). 이 가운데 carrier 는 하나도 없다. 전부 설치 명령 그 자체다. 동사 목록은 손으로 관리하는 사본이 일곱 벌이었고 서로 어긋나 있었다. 그래서 이제 `lib/install-grammar.sh` 가 문법을 한 번 정의하고 두 훅의 모든 인식기가 그것을 읽는다. 설치를 인자 그대로 실행하는 래퍼(`sudo`, `timeout`, `nohup`, `nice`, `xargs`)는 일부러 뺐다. 인자를 실행하는 프로그램 목록은 수렴하지 않으므로, 이것도 carrier 와 같은 논거다.

spec 을 읽는 방식 두 가지가 엉뚱한 신원을 검사했고, 에이전트는 거부 메시지의 처방을 스스로 따르므로 둘 다 우회였다. Go 모듈은 마지막 경로 조각만 남았다. 그래서 `go get example.com/x@v1` 이 `safedeps check go x@v1` 을 처방했고, 이것은 어떤 권고에도 나오지 않는 이름이라 승인된 뒤 `.../x@v1` 이면 무엇이든 통과시켰다. 또 모든 spec 이 명령에서 처음 나온 생태계로 검사됐다. 그래서 `npm run build && pip install evil==1` 은 `evil` 을 npm 패키지로 검사했다. 이제 Go spec 은 모듈 경로 전체를 쓰고, 각 spec 은 자신이 나온 문장의 생태계를 가진다. 같은 일을 한 읽기가 셋 더 있었고, 셋 다 검사하면 승인됐다. 버전 플래그를 동사 뒤에서 처음 나온 플래그 아닌 토큰에 묶었기 때문에, 패키지 앞에 있는 옵션의 값이 패키지 자리를 차지했다. `gem install --source <url> rake -v 13.0.0` 은 `check rubygems <url>@13.0.0` 을 처방했고, `cargo install --root <dir> …` 와 `dotnet tool install --tool-path <dir> …` 는 디렉터리로 같은 처방을 냈다. 그 뒤로는 같은 옵션과 버전을 단 설치가 전부 통과했다. 숫자로 시작하는 이름은 첫 글자부터 읽혔거나(`poetry add 3to2@1.1.1` 이 `to2` 를 검사했다) 아예 읽히지 않았다(`pip install 3to2==1.1.1`). 그리고 npm 별칭 `left-pad@npm:evil-pkg` 는 `left-pad@npm` 을 처방했는데, 이것은 어느 패키지도 가리키지 않아 영영 승인되지 않는다. 이제 버전 플래그는 동사의 모든 피연산자에 묶인다. 옵션의 값은 매니저 자신의 도움말이 그 옵션에 필수 값이 있다고 적은 경우에만 뺀다. 그래서 그 목록에 빠진 옵션이 있어도 검사가 하나 늘 뿐 패키지를 건너뛰지 않는다. 이름은 통째로 읽고, 별칭은 그 대상으로 읽는다. 실행기의 옵션은 버전 플래그 없이도 같은 일을 했다. 패키지 앞의 옵션은 전부 건너뛰고 그다음 토큰을 패키지로 잡았다. 그래서 `uvx --python 3.12 ruff==0.1.0` 은 ruff 를 검사 없이 실행하고 `pypi:3.12` 를 기록했고, `npx --cache /tmp/c evil@1.0.0` 은 캐시 디렉터리로 같은 일을 했다. 이제 실행기마다 자기 도움말이나 정의에서 읽은 표가 있다. 어떤 옵션은 패키지를 지목한다(`--from`, `--spec`, `--package`). 어떤 옵션은 그 옆에 패키지를 더한다(`--with` 이고, 이제 이것도 검사한다). 나머지는 패키지가 아닌 값을 받는다. 표만으로 안 되는 파서가 둘 있었고, 둘 다 파서 자체에 대고 쟀다. `npm exec` 는 인자를 nopt 에 넘기는데, nopt 는 불리언 옵션이 뒤따르는 `true`·`false` 를 받게 한다. 반면 npx 는 자기 첫 패스에서 그 토큰을 패키지로 만든다. 그리고 pipx 는 긴 옵션의 줄임을 받아들이므로 `--pyth` 는 `--python` 이다.

**명령어 철자는 매니저의 파서가 받아들이는 것이고, `create` 는 그것이 실행하는 패키지로 검사한다.** npm 은 명령어를 문서의 별칭 목록에서 읽지 않는다. `deref`(lib/utils/cmd-list.js)는 camelCase 단어를 대시 형태로 읽고, 명령이나 별칭의 고유한 줄임을 모두 받는다. 그래서 `npm upd`, `npm install-te`, `npm installTest`, `npm exe`, `npm cr` 은 모두 패키지를 설치하거나 실행한다. 별칭을 베낀 문법은 이것들을 하나도 판정하지 않고 통과시켰다. 이제 `lib/install-grammar.sh` 의 npm 철자는 `deref` 가 각 명령에 대응시키는 집합이다. `scripts/measure/npm-verb-spellings.sh` 가 PATH 의 npm 에서 그 집합을 다시 만들고, 문법에 없는 철자를 npm 이 받아들이면 실패한다. 매니저별 `create` 는 피연산자를 고쳐 쓴 뒤 실행하는 실행기다. `npm init vite` 는 `create-vite` 를, `npm init @usr/foo@2.0.0` 은 `@usr/create-foo@2.0.0` 을, `npm init @usr` 는 `@usr/create` 를 실행한다. pnpm 은 이미 `create-` 로 시작하는 이름을 그대로 두고, Yarn 2+ 는 `create` 나 `create-*` 인 이름을 그대로 두지만 Yarn 1 은 그러지 않으며, bun 은 bunx 에 넘기는 이름마다 접두어를 붙인다. 처방과 기록은 각 매니저의 소스에서 읽은 대로 고쳐 쓴 패키지를 가리킨다. `vite@5.0.0` 을 처방했다면 실행되지도 않는 패키지를 승인하고 `create-vite@5.0.0` 은 검사하지 않았을 것이다. Yarn 1 과 Yarn 2+ 가 갈리는 경우에는 둘 다 검사한다. 명령만으로는 어느 yarn 이 돌지 알 수 없기 때문이다. initializer 없는 `npm init` 은 `package.json` 을 쓰기만 하고 아무것도 받아 오지 않으므로 조용하다. `npm link`(`ln`)는 인자마다 npm-package-arg 로 읽고, 전역 트리에 없는 것을 하나하나 npm 의 전역 prefix 에 설치한 뒤 프로젝트에 링크한다(lib/commands/link.js:92-104). 레지스트리 인자(이름, 버전, 범위, 태그, `npm:` 별칭)는 레지스트리에서 받아 오므로, 인자들 사이 어디에 있든 버전을 고정하면 검사하고 고정하지 않으면 `UNGATED` 로 기록한다. 인식기는 첫 인자만 읽었기 때문에 앞에 놓인 경로가 뒤의 패키지를 가렸다. `npm link ./lib evil@1.0.0` 은 evil 을 전역에 설치하고 그 설치 스크립트를 실행했지만 판정도 기록도 없었다. 경로나 tarball 은 로컬 코드를 링크하고, git·URL 인자는 레지스트리 패키지를 지목하지 않는다. 이것들은 조용하고, 인자 없는 `npm link` 도 그렇다. `scripts/measure/npm-link-operands.sh` 가 이 읽기를 npm-package-arg 자체와 대조한다. 그리고 리다이렉트는 어디에 있든 셸의 것이다. bash 는 단어 중간에 있는 따옴표 밖의 `>`·`<` 도 연산자로 읽으므로, `pip install requests==2.19.0>/dev/null` 은 고정된 패키지를 설치한다. 단어 맨 앞의 연산자만 리다이렉트로 보던 리더는 단어 전체를 버전 없는 피연산자로 읽고 아무것도 검사하지 않았다.

**단어는 셸이 끝내는 곳에서 끝나므로, 설치의 마지막 단어는 연산자에 붙어 있을 수 있다.** 셸은 공백과 `;`, `&`, `|`, `)`, `<`, `>`, 그리고 닫는 백쿼트에서 단어를 끝낸다. 그래서 `npm ci; echo x` 는 `npm ci ; echo x` 와 똑같이 npm 에 `ci` 라는 단어를 넘긴다. 인식기는 마지막 단어를 공백이나 줄 끝에서만 끝냈다. 그래서 동사가 연산자에 붙은 설치는 v2.17.2, 7d66f8c, v2.18.0 어디서도 설치가 아니었다. `npm ci; echo x`, `(go get)`, `dotnet package update&& dotnet build`, `mvn -Dartifact=g:a:1.0.0 dependency:get;` 는 검사도 기록도 `--ignore-scripts` 도 받지 않았다. npm 은 그 뒤에 백스톱이 클로저를 판정했다. pip, cargo, go, gem, maven, nuget 에는 이 게이트가 유일하므로 완전히 놓친 것이다. 이제 `lib/install-grammar.sh` 의 `SAFEDEPS_G_END` 가 그 단어 끝이고, 모든 인식기가 그것을 읽는다. 렉서는 연산자인 `(` 에서도 단어를 끝낸다(아래). 어느 셸도 거기서 앞 단어를 넘기지 않으므로, 그것을 끝으로 읽어도 인식기가 넓어질 뿐이다. 백쿼트 안의 설치는 전에도 치환 본문에서 읽혔다. 닫는 백쿼트가 더하는 것은 그 설치의 `--ignore-scripts` 다(`` echo `npm ci` ``). 패턴은 닫는 백쿼트와 여는 백쿼트를 구별하지 못하고, 여는 백쿼트는 단어를 잇는다. `` npm ci`echo x` `` 는 npm 에 `cix` 를 넘긴다. 인식기는 이것을 `npm ci` 로 읽는데, 이 과잉 읽기의 비용은 기록 하나다. 가드는 전처럼 명령을 실행하게 두고, `advisory.log` 에 한 줄을 남긴다. 재작성은 동사 앞의 백쿼트를 읽고 그 자리에 플래그를 넣지 않으므로, 이 명령을 `npm ci` 로 바꾸지 않는다.

zsh 는 `{` 묶음을 닫는 `}` 에서도 단어를 끝낸다. 그곳에서 `{ npm ci}` 는 `npm ci` 를 실행하고(zsh 5.9 실측), bash 와 dash 는 그 묶음을 거부한다. 묶음 밖에서는 zsh 가 그런 `}` 를 거부하고, bash 는 단어에 남겨 npm 에 `ci}` 를 넘기는데, npm 은 이것을 명령으로 받지 않는다. 이 끝의 첫 판은 붙은 `}` 를 모두 끝으로 읽었고, 재작성을 거치며 실행되는 것이 바뀌었다. `npm ci}` 는 `npm ci --ignore-scripts} --ignore-scripts` 가 되었는데 bash 는 이것을 `npm ci` 로 실행한다. `{ npm ci}` 는 `{ npm ci --ignore-scripts} --ignore-scripts` 가 되었는데 zsh 는 이것을 파싱하지 못한다. 그래서 어느 `}` 가 묶음을 닫는지는 렉서가 정한다(`shell_lex` 의 `group_close`). 렉서는 자기 워크가 연 `{` 묶음을 센다. 어느 `{` 가 묶음을 여는지는 워크의 답이고, 그 뒤에 명령 시작을 두는 답과 같다. zsh 는 구분자나 예약어 뒤뿐 아니라 `function f`, `f()`, `()`, `repeat 1`, `for i (1)` 의 목록 뒤에서도 묶음을 연다. 첫 판은 워크 옆에 따로 둔 바이트 규칙으로 묶음을 셌고, 그 규칙은 구분자와 예약어만 알았다. 워크가 그 머리들을 읽게 되자, 그 규칙에서는 `function f { npm ci}; f` 가 묶음을 닫지 않았고 `}` 는 문자가 되었다. 그래서 공백 형태는 읽히는데 붙은 형태만 아무 기록 없이 통과했다(판정 tookdaki-20261005-144303, N2). `scripts/test/consumer-forms.sh` 는 그 붙은 형태 각각을 npm 과 maven 에서 공백 형태와 같게 묶어 둔다. 열린 묶음이 없을 때 붙은 `}` 는 인식기와 재작성이 읽는 뷰에서 문자(`%`)다. `%` 는 분석기에서 아무 역할이 없는 바이트다. `_` 는 이름의 바이트라서 `}=(` 를 다시 읽으면 배열 대입 `_=(` 가 되었다. 그래서 어떤 인식기도 `npm ci}` 를 `npm ci` 로 읽지 않고, 재작성도 받지 않는다. zsh 묶음을 닫는 `}` 는 `}` 로 남고, 문장을 끝내며, 플래그를 `}` 앞에 받는다(`{ npm ci --ignore-scripts}`). zsh 는 이것을 플래그와 함께 실행하고, bash 는 여전히 거부한다. 추출기가 읽는 단어도 거기서 끝나므로 `{ mvn -Dartifact=g:evil:1.0.0 dependency:get}` 는 공백 형태와 같이 검사된다. 그 `}` 를 단어 안의 묶음 문자로 읽었을 때는 goal 이 이름을 잃어 설치가 검사되지 않았다. bash 읽기는 텍스트 끝에서 bash 가 묶음을 열어 둔 채일 때만 그런 `}` 를 zsh 처럼 읽는다. 그때 bash 는 그 텍스트를 거부하고 아무것도 실행하지 않기 때문이다. `{ npm ci}; }` 처럼 bash 가 뒤에서 묶음을 닫으면, bash 는 `npm ci}` 를 실행하고 zsh 는 마지막 `}` 를 거부한다. 그러면 읽기마다 재작성이 달라지므로 그 명령은 `UNDECIDED` 다. 여러 줄에 걸친 묶음(한 줄에 `{`, 다음 줄에 `npm ci}`)에는 따로 할 것이 없다. 렉서가 명령을 통째로 읽기 때문이다. 이 판정은 워크가 단어를 읽는 최상위에서 한다. 치환 안의 `}` 는 그 본문을 페이로드로 읽는 곳에서 정한다. 인식기는 `` echo `{ npm ci}` `` 를 거기서 설치로 읽고, 재작성도 거기서 읽는다. `npm` 과, 렉서가 페이로드 읽기에 맡긴 `}` 를 함께 가진 치환 본문은 페이로드로 읽힌다. 자기 최상위에서, 같은 읽기 안에서다(`inert_subst_bodies`). 그 플래그는 substs 단위를 거쳐 명령으로 돌아간다. 그래서 `` echo `{ npm ci}` `` 는 `` echo `{ npm ci --ignore-scripts}` `` 가 되고, zsh 는 이것을 플래그와 함께 실행한다. 재작성은 전에 그런 본문을 명령의 일부로 읽었고, 거기서 그 `}` 는 문자다. `}` 가 동사에 붙으면 그 설치는 플래그를 받지 않고 floor 에 머문 것으로 기록되었다. `x=$( { npm ci --ignore-scripts=false} )` 처럼 `}` 가 마지막 단어에 붙으면, npm 이 `false}` 를 true 로 읽으므로 그 문장은 이미 true 로 읽혔다. 플래그도 기록도 없었고, zsh 는 그 설치의 스크립트를 실행했다. 둘은 한 클래스의 두 모양이었다. 그래서 재작성은 이제 인식기가 읽는 곳에서 본문을 읽고, `}` 의 모양마다 따로 다루는 경우는 없다. 그런 본문은 그것이 놓인 텍스트의 깊이에서, 상한 없이 읽힌다. 본문은 언제나 그 텍스트보다 짧으므로 읽기는 끝난다.

인식기가 읽는 뷰는 이스케이프된 연산자의 백슬래시를 공백으로 지우므로, 셸이 npm 에 `ci;` 를 넘기는데도 `npm ci\;` 는 전처럼 `npm ci` 로 읽힌다. 아무것도 설치하지 않는 명령을 재작성하는 비용이 드는 과잉 읽기다. `scripts/measure/glued-verb-reading.sh` 는 매니저마다 설치의 마지막 단어를 각 연산자에 붙인 형태와 연산자 앞에 공백을 둔 형태로 쓰고, 둘 다 가드에 묻고, bash·zsh·dash 가 매니저에게 넘기는 단어를 출력한다. 또 모든 재작성을 매니저 대역과 함께 세 셸에서 실행한다. 셸마다 원래 명령에서 넘긴 단어에 `--ignore-scripts` 만 더한 단어를 대역에 넘겨야 하고, 원래 명령을 거부한 곳에서만 재작성을 거부해야 한다. 455개 형태(매니저 13종의 설치 35개 × 끝 13가지) 중 v2.17.2(bb0787d)는 70개를 공백 형태와 다르게 읽었고 171개는 어느 쪽으로도 읽지 않았다. 이 트리는 하나도 다르게 읽지 않고, 읽지 않는 것도 없다(macOS, npm 11.19.0, 부하 4~7. `--tree` 로 다른 체크아웃을 잰다). 재작성 49개는 각각 셸마다 원래 명령에서 넘긴 단어에 `--ignore-scripts` 만 더해 넘기고, 원래 명령을 거부한 곳에서만 거부된다. 예외는 하나다. `{ npm install evil@1.0.0}` 에서는 7d66f8c 가 한 문장짜리 설치에 붙인 플래그가 닫는 `}` 뒤에 서고, zsh 는 7d66f8c 의 재작성을 거부했듯이 이 재작성도 거부한다. 표는 그 행을 `floor-zsh` 로 적는다. 그중 84개는 패키지를 지목하지 않고 npm 설치도 아닌 설치(`go get;`, `pnpm install;`)라서 읽히든 안 읽히든 두 형태 모두 아무 응답도 받지 않는다. 표는 이것들을 일치가 아니라 silent 로 적는다. `nogroup}` 형태 35개는 공백 형태가 없으므로 재작성만으로 판정한다. 셸에 먹이는 heredoc(본문에 설치가 든 `bash <<E`)은 열거 밖의 운반체이므로 표는 그것을 출력만 하고 판정하지 않는다.

**스캐너는 따옴표와 백슬래시를 셸과 같은 규칙으로 읽고, 실패한 스캔은 빈 스캔이 아니다.** 모든 판정 함수가 따옴표 안을 공백으로 지우는 `command_scan_text` 를 읽으므로, 셸이 실행하는 텍스트를 지우면 그 텍스트가 모두에게서 한꺼번에 사라진다. v2.18.0 전까지 네 가지 읽기가 그렇게 했다: `"a\\"` 를 이스케이프된 따옴표로 읽었고, 따옴표 밖 `\"` 를 여는 따옴표로 읽었고, 줄 이음을 두 줄로 나눴고, 여러 줄 따옴표 문자열을 줄마다 따로 스캔해 닫는 따옴표를 여는 따옴표로 읽었다. 이제 큰따옴표 안의 백슬래시는 짝으로 소비되고, 따옴표 밖에서는 다음 바이트를 이스케이프하며(이스케이프된 `;`·`|` 는 문장의 끝이 아니라 문자다), 작은따옴표 안에서는 아무 일도 하지 않는다. 이스케이프된 줄바꿈은 셸이 앞뒤 바이트를 잇는 자리에서 빼고, 따옴표 안의 줄바꿈은 문장을 끝내지 않는다. spec 리더도 같은 분석에서 단어를 받는다(아래). 전에는 따옴표 문자만 지우고 백슬래시를 모두 남겼다. 그래서 evil 6.6.6 을 설치하는 `pip install ev\il==6.6.6` 은 버전 없는 피연산자로 기록될 뿐 검사되지 않았고, `pnpm add ev\il@6.6.6` 은 `check npm il@6.6.6` 을 처방했다. 또 모든 판정 함수가 `set -e` 가 꺼진 자리에서 스캔을 읽기 때문에, 실패한 스캔은 "설치 아님" 으로 읽혔다. 이제 모든 awk 읽기가 실패를 기록하고, 판정이 기대는 grep·sed 도 기록한다(2 이상으로 끝난 grep 은 답하지 못한 것이지 매치 없음이 아니다). 관문 하나가 그것을 정산한다. 명령을 실행시키는 모든 경로는 마지막 읽기 뒤, 첫 부수효과(pending 상태, inert meta, allow) 앞에서 이 관문을 한 번 지난다. 읽기가 실패했다면, 패키지 매니저 실행파일 이름이 대소문자 무관하게 어디든 있는 명령은 `UNDECIDED` 로 거부하고, 나머지는 실패를 기록한 채 실행한다. 이 판별은 `SAFEDEPS_G_EXECUTABLES` 에 대한 bash 자체 정규식이고 서브프로세스가 없다. 대신 서는 도구들이 바로 실패한 도구이기 때문이다. 이전 판별은 두 번째 인식기를 grep·sed·join awk 로 다시 돌렸고, 그 도구들과 함께 조용해졌으며, 스캔을 거친 인식기가 찾는 것을 다 찾지도 못했다(리뷰 세 라운드). 읽기가 실패한 뒤 적발을 보고할 deny 는 대신 `UNDECIDED` 를 보고한다. `scripts/measure/scan-failure-census.sh` 가 읽기를 하나씩, 그리고 한꺼번에 실패시키고, grep 과 sed 호출도 같은 방식으로 실패시켜 약해진 것을 센다. census 는 읽기를 표식으로 찾으므로, 가드가 표식 없는 awk 를 부르면 그것도 실패로 센다. 이름을 모르는 읽기는 실패시킬 수 없는 읽기다. `npm run test:release` 가 그 축약판을 돈다(`npm test` 는 census 를 빼고 돈다). 축약판은 sed 호출은 하나씩 실패시키지만, grep 호출을 하나씩 실패시키는 일은 전체 census 에 맡긴다. 축약 부분집합이 그 실행을 아직 포함하던 e238f13 에서는 실패 실행 5,083 중 1,126 이었다. 그 모드가 찾은 grep 자리 둘은 `scripts/test/scan-contract.sh` 의 행이 그 호출을 하나씩 실패시켜 지킨다.

**명령은 셸이 어휘를 나누는 방식대로 한 번에 읽는다.** awk 프로그램 하나(`shell_lex`)가 셸이 유지하는 어휘 상태를 따라간다. 홑·겹·`$'...'` 따옴표, 이스케이프, 주석, heredoc 연산자와 본문, 산술, 명령·매개변수 치환, 백틱, 줄 이음이다. 명령을 읽는 모든 곳은 이 한 번의 분석에서 뷰를 받는다. 탐지 판정은 scan 뷰를 읽는데, 따옴표 안·주석·heredoc 본문이 공백이다. payload 리더는 명령이 셸에 넘기는 script 와 치환의 본문을, 렉서가 자르는 대로 하나씩 읽는다. 구분자에 따옴표가 없는 heredoc 본문 안의 치환은 셸이 실행하므로 살아 있는 코드다. 본문도 같은 분석기가 걸으므로, 그 안의 치환은 여러 줄에 걸치거나 중첩되거나 case 문을 담아도 읽힌다. 줄 단위로 따로 읽던 스캐너는 셋 다 놓쳤다(리뷰에서 발견). 문장이 시작할 수 있는 접두(대입, 대상을 포함한 리다이렉션, 옵션·대입을 단 `env`, `command`, `exec`)도 설치를 대조하기 전에 같은 분석에서 읽는다. 그래서 값은 어떻게 따옴표를 치거나 중첩해도 한 단어다. 정규식이 값을 첫 공백이나 따옴표까지의 바이트로 읽던 동안 `FOO="a b" pip install ...` 과 `FOO=$(cmd arg) pip install ...` 은 판정 없이 통과했다. 이 분석기는 차례로 돌며 서로 맞아야 했던 상태기계 셋(줄 단위 heredoc 패턴, 줄 이음 처리, 따옴표 스캐너)을 대신했다. 리뷰 세 라운드 동안 셋은 맞지 않았다. heredoc 을 두 번 벗겼고, heredoc 이 아닌 곳에서 열었고(herestring, 산술 시프트, 따옴표 안 `<<EOF`), heredoc 인 곳에서 열지 않았다(숫자 구분자, heredoc 을 여는 줄에서 닫히는 여러 줄 문자열). 그때마다 그 뒤의 줄이 전부 게이트에서 사라졌다. `scripts/measure/shell-reading-forms.json` 은 형태마다 셸들이 낸 값을 기록하고, `scripts/test/shell-reading.sh` 는 셸이 마지막 줄까지 실행하는 모든 형태에 판정을 요구한다. `scripts/measure/shell-reading-measure.sh` 가 셸 값을 다시 잰다.

**명령은 셸마다 한 번씩 읽는다. bash, zsh, dash 다.** 셸들은 몇 군데에서 같은 텍스트를 다르게 나누고, 한 셸이 실행하는 줄이 다른 셸에게는 따옴표 안, heredoc 본문, 산술일 수 있다. 그래서 분석기에는 읽기가 셋 있고, 읽기 하나가 셸 하나다. 명령을 읽는 모든 곳은 한 읽기 안에서 읽는다. 한 리더가 다른 리더에게 넘기는 텍스트(`sh -c` script, 치환의 본문, 문장)도 같은 읽기로 분석하고, 다른 읽기로 분석하지 않는다. 게이트는 합집합으로 판정한다. 어느 읽기에서 나온 발견이든 발견이고, 대상과 spec 은 모든 읽기의 것이며, 명령이 `UNDECIDED` 인 것은 닫히는 읽기가 하나도 없거나 한 읽기의 단계가 실패했을 때뿐이다. 읽기들은 셸이 갈리는 첫 자리까지 바이트마다 같고, bash 읽기는 그 자리에 같은 상태로 닿는다. 그래서 bash 읽기가 먼저 돌고, 나머지 둘이 필요한지를 bash 읽기가 말한다. 그런 자리에 닿지 않는 명령은 읽기 하나로 끝난다.

명령을 고치는 것은 읽는 것과 다르다. `--ignore-scripts` 는 모든 셸이 읽는 텍스트를 바꾸므로, 모든 읽기가 npm 설치를 같은 자리에 둘 때만 넣는다. 그렇지 않으면 명령은 `UNDECIDED` 이고, 사유는 셸들이 이 명령의 npm 설치 자리를 다르게 읽는다고 말한다. 어느 읽기든 설치를 본 자리마다 플래그를 넣으면 다른 셸이 데이터로 읽는 텍스트를 고치게 된다. heredoc 구분자가 그런 자리의 하나이고, 그러면 셸이 다음에 읽는 것이 바뀐다.

이 설계는 첫 읽기에서 모은 갈림마다 읽기를 하나씩 두던 방식("축")을 대신했다. 읽기를 셸로 만든 라운드가 그 방식이 닫힐 수 없는 이유를 실측했다. zsh 는 `((` 를 자리마다 정하므로, 한 명령 안에 서브셸 `((` 와 산술 `((` 가 함께 있었고(형태 M1), 명령 전체에 거는 스위치로는 그것을 따라갈 수 없다. 이어 붙이기 뒤의 리더들은 zsh 읽기를 bash 규칙으로 다시 분석해 그 줄을 한 번 더 숨겼다(형태 SL1: zsh 와 에이전트 래퍼가 실행하는 `echo "${x:-'}"; <install>; echo "'}"`). 리눅스에서 `sh -c` script 를 읽는 dash 는 `((` 는 bash 처럼, 아포스트로피는 zsh 처럼 읽는다(형태 D1). inert 설치에도 같은 틈이 있었다. bash 가 따옴표 안으로 읽은 `npm ci` 를 zsh 는 플래그도 기록도 없이 실행했고, meta 는 inert 라고 했다(형태 I2, I3).

| 자리 | bash | zsh | dash | 형태 |
|---|---|---|---|---|
| `((` | 짝 없는 첫 `)` 까지 따옴표를 존중하며 미리 읽는다. 뒤에 `)` 가 또 있으면 산술, 아니면 서브셸, 없으면 열린 산술 | 같은 미리 읽기, 단 맨 따옴표는 글자 | 늘 서브셸 | B1, M1, QM, D1, LA1-LA5 |
| `$((` | `((` 와 같음 | `((` 와 같음 | 늘 산술 | Z2, A7 |
| 산술 안의 따옴표 | 따옴표 | 글자 | 글자 | QM, QM2, SL2 |
| `$[` | 산술 | 산술 | 평문. 그 안의 따옴표·주석·heredoc 은 그대로 그것 | KD1-KD3 |
| `"${...}"` 안의 `'` | 따옴표 | 글자 | 글자 | P4, SL1, SL3, D1 |
| `$'...'` | ANSI-C 문자열. `\'` 는 닫지 않음 | ANSI-C 문자열 | `$` 와 홑따옴표 문자열 | AC1, AC2 |
| `&>` | 두 출력을 함께 돌리는 리다이렉션 하나 | 두 출력을 함께 돌리는 리다이렉션 하나 | 명령을 끝내는 `&`, 그리고 다음 명령이 시작하는 `>` | AM1, AM2, 시작 AR1-AR13 |
| `>`, `>>`, `>&`, `&>` 뒤의 `!` | 대상 단어의 시작 | 연산자의 일부(`>!` 는 덮어쓰기). 그래서 공백 뒤 다음 단어가 대상 | 대상 단어의 시작 | ZB1 |
| `$(...)` 안에서 `)` 가 바로 붙은 heredoc 구분자 | 본문을 끝내고, `)` 는 코드 | 본문 | 본문 | A2, HC1-HC3 |
| 인자 자리 `(...)` 안이나 그 바로 뒤의 `#` | 주석 아님: 치환 안에서 bash 3.2 는 뒤 줄을 실행하고, bash 5.2 는 파싱 오류 | glob 단어, 주석 아님 | 파싱 오류 | G5, ZG1 |
| 단어에 붙은 `(` | 단어의 일부: glob 묶음(extglob, 또는 치환 안의 bash 3.2. 그 밖에서 bash 5.2 는 파싱 오류) | 단어의 일부: glob 묶음이나 한정자 | 연산자 | 단어 WG1-WG11, WE1-WE3 |
| 단어 맨 앞의 `=(` | zsh 가 읽는 대로 읽는다(bash 는 파싱 오류) | 임시 파일을 거치는 프로세스 치환: 한 단어이고 본문이 실행된다 | zsh 가 읽는 대로 읽는다(dash 는 파싱 오류) | 단어 WZ1-WZ9 |
| `NAME[...]=` 첨자 안의 공백 | 대입 단어의 일부 | 단어를 끝낸다 | 단어를 끝낸다 | 단어 WA18 |
| `<N-M>`(어느 숫자든 생략 가능) | 리다이렉션 둘 | 숫자 범위 glob: 단어의 바이트 | 리다이렉션 둘 | 격자 RW-z-numeric |
| 리다이렉션 연산자에 붙은 숫자(`12>f`) | 디스크립터, 자릿수 제한 없음 | 한 자리가 디스크립터이고, 그보다 길면 숫자가 따로 단어다 | zsh 와 같다 | 시작 HA18, `echo 12>/dev/null` 실측 |
| 명령 앞의 `noglob`, `nocorrect`, `-`, `builtin` | 명령과 그 인자 | 프리커맨드 수식어: 다음 단어가 명령 | 명령과 그 인자 | 단어 WK1-WK14 |
| `repeat N`, `for NAME (WORDS)`, `foreach`, `[[ ... ]]`, `((...))`, `}`, `always` 뒤의 명령 | 명령 아님 | 명령 | 명령 아님 | 시작 N5, N6, N9, X4-X7 |
| `coproc NAME` 뒤의 복합 명령(`{`, `if`, `while` 등) | 본문을 연다 | 낱말 | 낱말 | 시작 U1, CP1-CP6 |
| case 갈래의 `;;&` 와 `;|` | `;;&` 가 갈래를 끝낸다 | `;|` 가 갈래를 끝낸다 | 둘 다 아님 | 시작 셸 행 |
| 명령 첫 단어에 붙은 `{` | 그 단어의 바이트 | 그룹 여는 말: 명령은 그 뒤에서 시작한다 | 그 단어의 바이트 | 시작 HA12-HA17 |
| `&!` | `&` 다음에 `!` 로 시작하는 단어 | 목록 종결자 하나: 그 뒤의 명령은 거기서 시작한다 | bash 와 같다 | 시작 HB1-HB5 |

미리 읽기는 이스케이프, `$(...)`, `${...}`, 백틱을 각자의 따옴표 규칙으로 통째로 건너뛴다. 마지막 다섯 행은 명령이 시작하는 자리(아래)다. 그 형태는 `scripts/test/consumer-forms.sh` 의 시작 행(셸마다 실행한 결과를 단다)과 `scripts/test/scan-contract.sh` 의 셸 행에 있다. 그 앞의 여섯 행은 단어가 끝나는 자리(아래)다. 그 형태는 `scripts/test/consumer-forms.sh` 의 단어 행과 리다이렉션 격자의 단어 꼴에 있다. 나머지 칸마다 `scripts/measure/shell-reading-forms.json` 에 형태가 있고, macOS(bash 3.2, zsh 5.9, `/bin/sh`, `/bin/dash`, 그리고 `setopt` 줄이 있는 에이전트 래퍼와 없는 래퍼)와 리눅스(bash 5.2, dash 0.5.12)에서 잰 값이 있다. `scripts/test/shell-reading.sh` 는 읽기마다 자기 셸을 따르게 한다. 셸이 형태의 마지막 줄을 실행했으면 그 셸의 읽기에도 그 줄이 보여야 한다. 게이트에는 그 형태에 대한 판정을 요구한다. `scripts/test/scan-contract.sh` 는 bash 읽기가 갈림을 보고하지 않은 곳에서는 나머지 두 읽기의 뷰가 bash 뷰와 바이트까지 같은지를, 기록된 형태와 무작위 입력에서 확인한다. `scripts/measure/shell-reading-fuzz.sh` 는 이 자리들로 만든 시드 고정 무작위 형태를 실제 셸에서 돌린다.

끝내 닫히지 않는 명령(열린 따옴표, 종결어 없는 heredoc)은 분석기가 끝내지 못한 명령이므로 실패한 읽기로 다룬다. 패키지 매니저를 부르면 `UNDECIDED` 다. 사용자 rc 파일이 켜는 셸 옵션과 별칭, 잰 것 밖의 셸과 판, bash 자신의 파싱 오류는 모델링하지 않는다. npm 이 `--ignore-scripts` 를 지키는지도 같은 셸 상태가 정한다. 에이전트 셸 스냅숏의 함수나 별칭, `.zshenv`(`zsh -c` 는 늘 읽는다), `BASH_ENV`, 또는 명령이 스스로 정의한 함수나 별칭은 npm 이 받는 단어를 바꿀 수 있고, 실측에서 각각 평범하게 다시 쓴 `npm install` 을 `ignore-scripts` false 로 만들었다. 이것은 명령 텍스트 어디에도 없으므로 텍스트를 읽어서는 정할 수 없고, safedeps 는 그것을 주장하지 않는다. 기록은 safedeps 가 무엇을 붙이고 돌렸는지를 말하고, 재작성은 7d66f8c 의 재작성을 담으므로(위), 이 상태가 설치에서 빼앗을 수 있는 것은 7d66f8c 에서 빼앗을 수 있던 것을 넘지 않는다. 그중 하나는 실측했다. bash 는 `$((` 를 치환으로 받으면 그 치환의 끝을 heredoc 을 읽지 않고 찾는데, 그 뒤에 bash 가 실행하는 줄이 bash 읽기에서는 숨을 수 있다. 시드 고정 무작위 형태 400 개에서 이것이 macOS 와 리눅스에서 똑같이 한 번 나왔다(F346). zsh·dash 읽기에는 그 줄이 보였으므로 게이트가 판정했다. macOS 에서는 반대쪽으로 충실하지 않은 형태도 하나 있다(F19). 산술을 연 채 끝나는 heredoc 본문 뒤의 줄을 zsh 가 실행하는데 zsh 읽기가 닫히지 않는다. bash·dash 읽기에는 그 줄이 보여서 게이트가 판정했다.

**문장과 치환이 어디서 끝나는지도 분석기가 정한다.** `case` 패턴은 `)` 에서 끝나고, 그 `)` 는 인식기가 읽는 뷰에서 문장 경계다. 그래서 case 갈래 안의 설치도 판정한다. 문법 정규식은 그 `)` 를 다른 `)` 와 구별할 수 없어서 case 갈래는 게이트 밖에 있었다. 명령 치환의 본문도 분석기에서 받는다. `$(...)` 는 셸이 구분하는 대로, 백틱 본문은 셸처럼 이스케이프를 풀어서(`\`` 는 중첩) 받는다. 첫 `)` 에서 본문을 자르던 문자열 탐색을 대신한다. 프로세스 치환의 본문도 그렇다. 셸이 같은 방식으로 실행하기 때문이다(아래). `((` 는 명령이 시작하는 자리만이 아니라 어디에 있든 정한다. 명령 위치를 손으로 열거하던 규칙은 heredoc 이 뒤의 줄을 삼키게 했다(리뷰에서 발견). `#` 은 낱말 처음에서만 주석을 연다. 이것은 앞 바이트의 문자가 아니라 앞 토큰의 질문이다. 이스케이프되지 않은 공백, 개행, 연산자 뒤에서만 주석이고, 이스케이프된 바이트, `$(...)`·`$((...))`·프로세스 치환·zsh glob 낱말을 닫는 `)` 뒤에서는 낱말의 일부다(`echo $(echo a)#b` 는 잰 셸 모두에서 `a#b` 를 찍는다). 줄 이음은 바이트가 아니다. 셸이 토큰을 나누기 전에 지우므로 그 앞 바이트가 정한다(`a \` 다음 줄 `#x` 는 주석, `a\` 다음 줄 `#x` 는 낱말 `a#x`). 분석기가 바이트만 보고 그런 `#` 을 주석으로 읽었고, 치환의 닫는 괄호를 삼킨 주석이 뒤 줄을 숨겼다(형태 G1-G4). 줄 이음을 바이트로 읽자 주석이 낱말이 되어 그 따옴표가 뒤 줄을 숨겼다(LC1-LC3). 서브셸이나 산술 명령의 `)` 는 토큰을 끝내므로 그 뒤 `#` 은 어디서나 주석이다(G7, G8). `#` 앞 바이트의 종류마다 답을 형태 WB1-WB22 가 셸마다 잰 값으로 고정한다. 백틱 본문을 여는 주석은 닫는 백틱에서 끝나고, 같은 줄에서 닫히는 치환 안에서 연 heredoc 에는 본문이 없다.

**명령이 어디서 시작하는지도 분석기가 정한다.** 인식기는 문장 시작을 정규식으로 찾았다. 구분자 뒤에, 명령 앞에 올 수 있는 예약어(`{`, `!`, `then`, `do`, `time` 등)를 사슬로 붙인 것이다. 사슬은 명령 앞의 낱말만 이름 붙일 뿐, 그 자리에 명령을 두는 셸의 상태는 보지 못한다. v2.18.0 의 리뷰 세 라운드는 매번 사슬이 놓친 다음 형태를 찾았다. 함수 본문이 통과했고(`f() { pip install evil==1.0.0; }; f`), 이름이 여럿인 함수(`f g() {`, `function f g {`), `time -p {`, `coproc NAME {`, zsh 단축형(`for i (1) {`, `repeat 1 {`, `if [[ 1 ]] pip install ...`, `} always {`), `for ((i=0;i<1;i++)) {` 도 통과했다. 마지막 형태는 결함을 하나 더 드러냈다. 문장 분할이 산술 안의 `;` 에서 잘라서, 명령 전체에 맞는 정규식이 있어도 어느 문장에서도 설치를 찾지 못했다. 이제 분석기가 셸 문법 상태를 따라 낱말을 걷고, 명령이 시작하는 자리를 모두 찾는다. 구분자, case 패턴, 예약어, 함수 머리, `time` 과 그 옵션, `coproc`, zsh 단축형 뒤가 그 자리다. 함수 머리는 빈 `()`, `function NAME... {`, 그리고 다른 복합 명령 바로 앞의 `function NAME` 이다. bash 5 는 `function WORD function_body` 로 읽기 때문이다. `function f if pip install evil==1.0.0; then :; fi; f` 는 거기서 설치를 실행하고, 걸음이 이 형태를 읽기 전까지 통과했다. bash 3.2, zsh, sh, dash 는 이 형태를 파싱하지 못하고, bash 5 도 이름이 둘이면 파싱하지 못한다. 그래서 이 규칙은 공유되며 시작을 더하기만 한다. 본문이 서브셸인 경우(`f() ( pip install evil==1.0.0 ); f`, `function f ( ... )`, bash 의 `coproc NAME ( ... )`)는 `()` 에 붙어 있든 아니든 그 `(` 에서 시작한다. 이 시작이 없으면 문장이 함수 이름에서 시작해서, 추출기는 설치를 `f` 의 인자로 읽었다. 명령 자리에 선 서브셸 앞에 그 문장의 낱말이 있으면 어디서나 마찬가지다. `function f { (pip install ...); }` 의 `{`, `for i do (...)` 의 `do`, `if (true) then (...)` 의 `then` 뒤에는 시작을 실을 낱말이 없다. 그래서 문장이 `function`, `for`, `if` 에서 시작했고, 그 안에서 매니저를 읽지 못했고, 이 꼴들은 main 에서 통과했다. bash, zsh, dash 는 자기가 가진 꼴을 실행한다. 이제 걸음은 그런 `(` 에서 명령을 시작한다. 앞 단어에 붙어 있어도(`do(`, `then(`) 마찬가지다. 서브셸의 `)` 뒤도 명령이 시작할 수 있는 자리로 읽는다. `(true)` 뒤에 `then` 이 올 수 있는 것이 그래서다. 인자 사이의 `(` 는 서브셸을 열지 않고, 그 `)` 는 아무것도 끝내지 않는다. 함수 머리는 괄호 사이에 공백을 둘 수 있다(`f( ) { ... }`. bash 와 dash 가 실행한다). case 갈래는 패턴의 `)` 바로 뒤에서 시작한다. 맨 위가 아닌 `;`, `&`, `|` 는 산술 안이든 치환 안이든 아무것도 끝내지 않는다. 설치 패턴은 구분자에만 고정하고, 시작 자리마다 구분자 하나로 받는다(아래). 명세 추출기와 `resolve_install_targets` 가 함께 쓰는 문장 분할도 같은 시작 자리에서 자른다. 그래서 인식기와 추출기는 읽기마다 같은 문장 시작을 읽는다.

시작 자리도 분석기가 정하는 다른 모든 것처럼 읽기에 속한다. 규칙마다 그 형태를 가진 셸의 것이고, 셸마다 실제로 재서 정했다. zsh 만 `}` 를 어디서든 닫는 괄호로, `always`, `repeat`, `foreach`, `for NAME (WORDS)`, `[[ ... ]]` 나 `((...))` 바로 뒤의 명령, `case WORD {`, case 갈래를 끝내는 `;|` 를 읽는다. bash 만 복합 명령 앞의 `coproc NAME`(`coproc WORD shell_command`: `{`, `if`, `while` 등)과 `;;&` 를 읽는다. 모든 읽기가 함께 쓰는 규칙은 시작을 더하기만 할 수 있고, 그 규칙이 없는 셸은 그 형태를 파싱하지 못한다. dash 는 `f() pip install ...` 를 실행하고 bash 는 실행하지 않으며, dash 에는 `function` 이 아예 없다. bash 읽기는 자기 시작 자리가 zsh 나 dash 와 다를 곳에서 `DIVERGE` 를 말한다. 그래서 `repeat 1 { pip install x; }` 를 찾는 zsh 읽기가 돈다. 같은 낱말이 인자로 오면 아무것도 열지 않는다(`echo { pip install x }`, `echo then pip install x`). 명령 앞의 대입과 리다이렉션은 명령에 붙어 있다. `npm_config_global=true` 와 `npm install` 사이에 시작을 두면 대입이 설치에서 떨어져 `UNGATED` 기록이 사라졌다. 맨 앞에 오는 리다이렉션은 시작 자리를 자기가 가진다. 둘 다 설치를 대조하기 전에, 걸음이 찾은 모든 시작 자리에서 명령의 다른 접두와 함께 떼어 낸다. 다른 자리의 리다이렉션은 공백으로 지운다(아래). 처음에는 리다이렉션을 전혀 떼지 않았다. 그래서 모든 셸이 실행하는 `2>/dev/null pip install evil==1.0.0` 은 시작과 설치 사이에 낱말 하나를 두었고 판정 없이 통과했다. 대입은 구분자나 예약어 뒤에서만 뗐다. 접두를 떼는 곳이 시작 자리를 따로 찾았기 때문이다. 그래서 `function f { FOO=1 pip install evil==1.0.0; }; f` 도 같은 방식으로 통과했다. dash 에는 `&>` 가 없다(위 표). `&` 에서 명령을 끝내고 `>` 에서 다음 명령을 시작한다. 그래서 `echo a &>/dev/null pip install evil==1.0.0` 은 데비안과 우분투의 `/bin/sh` 인 dash 에서 설치를 실행한다. 모든 읽기가 그 자리를 리다이렉션으로 읽었고 어느 읽기도 `DIVERGE` 를 말하지 않아서 통과했다. 문장 분할도 `&>` 를 따로 판단했는데, 이제 뷰에서 읽는다. 시작 자리는 scan 뷰에 쓰지 않는다. scan 뷰에 시작을 쓴 시제품은 그 뷰의 멱등성과, 그 뷰를 읽는 파이프 검사(`| { sh; }`)를 깼다. inert 재작성에는 따로 시작 자리가 필요 없다. 실행되는 코드 안의 npm 설치 동사를 전부 고쳐 쓰고, 고쳐 쓸지는 읽기마다 recognize 뷰를 읽는 인식기가 답한다. 그래서 일부 셸만 파싱하는 형태는 위의 일치 규칙을 따른다. `time -p { npm install x; }` 와 case 갈래는 모든 읽기에서 플래그를 받고, `repeat 1 { npm install x; }` 나 `for ((i=0;i<1;i++)) { npm install x; }` 는 `UNDECIDED` 다. 그 형태를 파싱하지 못하는 읽기에는 맞춰 볼 설치가 없기 때문이다. 이 설계의 판정은 60개 형태를 bash 3.2, bash 5, zsh, sh, dash 에 대고 쟀다. 어떤 셸이든 실행하는 38개 가운데 이전 릴리스는 17개를 거부했고, 분석기의 시작 자리는 38개를 모두 거부한다. 데이터 형태 17개에는 새 기록이 하나만 생긴다. zsh 는 `echo () pip install x` 를 `echo` 라는 함수의 정의로 읽으므로 기록한다. zsh 의 `case x {` 는 닫히지 않는 case 로 읽으므로 `UNDECIDED` 다. 형태와 셸마다 실행한 결과는 `scripts/test/consumer-forms.sh` 가, 시작 자리의 규칙과 그 규칙이 기대는 셸 실행은 `scripts/test/scan-contract.sh` 가 지킨다.

**시작 자리는 두 바이트 사이의 자리이고, 걸음은 그것을 자리로 넘긴다.** 걸음의 첫 설계는 시작 자리를 바이트로 넘겼다. 걸음이 시작 자리를 찾으면, stmts 뷰가 그 앞 바이트 위에 `;` 를 썼다. 앞 토큰에 붙은 명령에는 그런 바이트가 없다. 리뷰 세 라운드가 매번 그런 다음 자리를 찾았고, 수리마다 이웃 토큰의 바이트를 하나씩 더 빌렸다. case 패턴의 `)`, 머리를 닫는 `)`, zsh 의 붙은 `{` 였다. 네 번째 자리는 빌릴 수가 없었다. 예약어, `!`, 머리 닫힘, zsh 의 `{` 에 리다이렉트·대입·프리커맨드가 붙으면 시작 자리는 그 접두의 첫 바이트다(`if true; then>/dev/null pip install evil==1.0.0; fi`, `!>/dev/null pip install ...`, zsh `{X=1 pip install ...; }`). 그리고 인식기가 읽는 텍스트는 그 접두를 떼어 낸다. 접두는 첫 렉싱이 이미 바꾼 텍스트를 두 번째로 렉싱해서 뗐고, 두 번째 렉싱은 남은 바이트에서 시작 자리를 다시 찾다가 `thenpip` 을 만났다. 모든 셸이 그 설치를 실행한다. simple command 문법(POSIX `cmd_prefix` 와 `Bang`, bash·zsh 의 확장, 프리커맨드)에서 생성해 매뉴얼의 복합 명령 자리마다 넣은 표는, 어떤 셸이든 실행하는데 게이트가 기록 없이 통과시킨 이런 꼴 403개를 찾았다. 그중 108개는 macOS 네 셸 모두가 실행한다. 그중 111개를 main 에 물었더니 모두 통과했다. 이 클래스의 판정(bamdori-20261004-224625)은 걸음을 그대로 두고, 시작 자리가 읽는 쪽에 닿는 방식을 바꿨다.

이제 걸음은 시작 자리마다 사건 하나를 넘긴다. 사건은 두 바이트 사이의 자리다. 명령이 시작하는 자리(접두가 있으면 그 첫 바이트)에 하나, 명령 단어를 읽는 자리에 하나다. 모든 리더가 사건을 받고, 바이트에서 시작 자리를 찾는 리더는 없다. 인식기는 recognize 뷰를 읽는다. stmts 바이트에서 명령마다 접두를 떼고, 나머지 최상위 리다이렉트를 공백으로 지우고, 줄 이음을 빼고, 구분자가 아직 서 있지 않은 시작 자리마다 `;` 를 끼워 넣는다. 문장 분할은 같은 시작 자리에서 자른다(stmtcuts 뷰). 그리고 bash 읽기는 세 걸음의 사건 집합을 비교하므로, 한 셸만 읽는 시작 자리도 그 셸의 읽기를 불러온다. 바이트를 빌리던 규칙은 모두 지웠다. 어떤 바이트에서 단어가 시작하는지를 묻던 읽기 둘도 이제 걸음에게 묻는다. 리다이렉트에 붙은 디스크립터 단어(zsh `{2>/dev/null pip install x; }`)와 첨자 대입(zsh `{a[1]=x pip install x; }`)은 걸음이 명령을 시작하는 자리에서 시작한다. zsh 와 dash 는 리다이렉트 연산자 앞의 숫자 한 자리만 디스크립터로 읽고, bash 는 몇 자리든 읽는다(실측: zsh 와 dash 에서 `echo 12>/dev/null` 은 `12` 를 /dev/null 로 출력한다). 그래서 zsh 에서 `repeat 12>&1 pip install x` 는 설치를 열두 번 실행하고, bash 읽기는 거기서 `DIVERGE` 를 말한다. zsh 는 `&!` 를 목록 종결자 하나로 읽는다. 그래서 `true&!pip install x` 는 zsh 에서만 설치를 실행하고, bash 와 dash 는 `!pip` 을 명령 이름으로 읽는다. 다른 셸이 명령을 읽는 자리에 zsh 프리커맨드 수식어가 오면(`exec -- noglob pip install x`) bash 읽기는 그때도 `DIVERGE` 를 말한다. 예전에는 두 번째 렉싱이 우연히 그 말을 했다.

**리더는 명령이나 payload 를 렉싱하고, 뷰의 출력은 렉싱하지 않는다.** 위에서 recognize 뷰를 텍스트를 한 번 렉싱한 뷰라고 적었지만 그렇지 않았다. 인식기는 다른 렉싱이 이미 만든 명령의 joined 뷰를 렉싱했다. 착지 판정, spec 추출기, 쓰는 문장 귀속, inert 읽기도 joined 뷰나 code 뷰를 거쳐 그렇게 했고, 추출기는 unprefixed 뷰를 거쳐 한 번 더 했다. joined 뷰는 heredoc 본문과 종결자 줄을 공백으로 지웠지만, 따옴표 없는 본문 안의 살아 있는 코드는 셸이 실행하므로 남겼다. 그것을 다시 렉싱하면 `cat <<E`, `$(date)`, `E`, `pip install evil==6.6.6` 이 `$(date)   pip install evil==6.6.6` 으로 읽혔다. 치환이 이름인 명령에 설치가 인자로 붙은 꼴이다. 실측한 셸은 모두 그 설치를 실행하고(macOS bash 3.2, GNU bash 5.2, zsh, sh, dash. 리눅스 bash, dash), 게이트는 기록 없이 통과시켰다. v2.18.1 과 v2.18.0 도 같았다. 거기 있는 npm 설치는 `--ignore-scripts` 없이 돌았고, 메시지에 `$(date)` 가 든 `git commit -F - <<EOF` 는 에이전트가 흔히 쓰는 명령이다(판정 buri-20261005-145152). 이제 각 리더는 쓴 그대로의 명령을 읽기마다 한 번 렉싱하고, 필요한 뷰를 모두 그 렉싱에서 받는다. recognize 뷰, pieces 뷰(문장 분할이 자르는 자리에서 자르고, 문장마다 인용 제거 뒤의 단어를 접두를 넣은 것과 뺀 것으로, 그리고 그 문장의 recognize 바이트를 준다), 그리고 문장 분할이 단어를 읽는 stmtraw 뷰다. stmtraw 뷰에서는 본문과 그 안의 살아 있는 코드가 공백이고 줄 이음은 건너뛴다. 리더가 렉싱하는 다른 텍스트는 payload 하나뿐이다. 명령이 `sh -c` 나 `eval` 에 넘기는 script 와 각 치환의 본문이고, 안쪽 셸이 자기 script 로 읽는 것이다. joined 뷰와 pieces 뷰의 줄 단위 읽기는 없앴으므로, 그것을 다시 렉싱할 리더가 없다. `scripts/test/scan-contract.sh` 는 이것을 주석이 아니라 구조로 붙든다. awk shim 이 가드 실행의 모든 렉싱을 기록하고, 렉싱한 텍스트는 모두 명령이거나 payload 이거나 그 둘의 온전한 문장(문장, 또는 플래그를 넣은 inert 읽기의 문장)이어야 한다. 허용하는 payload 는 꼴마다 셸이 실행하는 대로 손으로 적은 것이고, 코드에서 가져오지 않는다. 명령의 live 뷰를 다시 렉싱하게 바꾼 사본에서는 이 검사가 빨강이 되고, `scripts/test/consumer-forms.sh` 의 이 꼴 행들도 함께 빨강이 된다.

`scripts/test/scan-contract.sh` 는 모든 리더가 기대는 계약을 지킨다. 기록된 셸 꼴, 생성한 첫 자리의 고른 표본, 무작위 입력의 사건 하나하나를 읽기마다 본다. 사건은 최상위 코드에 서고, 따옴표·치환·산술·heredoc 안에는 서지 않는다. 명령의 접두와 명령 단어 사이에는 시작 자리가 없다. 인식기는 명령 단어마다 구분자 바로 뒤에서 읽는다. 그리고 문장 분할은 거기서 자른다. 리다이렉트 격자의 첫 자리도 이제 손으로 고른 넷이 아니라 생성한 것이다(`scripts/measure/redirection-grid.sh` 의 `FIRSTS`, `scripts/measure/first-place-grid.sh` 가 읽는 목록). 이로써 격자는 8438 꼴이고, 그중 7047 꼴은 셸 하나라도 실행하며, `check` 는 그 꼴마다 패키지를 짚는 판정을 요구한다. 셸이 아닌 문법으로 읽히는 페이로드 둘은 다음 플랜으로 넘기고, `scripts/test/consumer-forms.sh` 에 통과로 고정해 둔다. env(1) 이 자기 규칙(옵션, `--`, `\_`, `#`)으로 나누는 `env -S STRING` 을 페이로드 리더는 스크립트로 읽고, zsh 글롭 한정자 안의 코드(`*(e:'...':)`)는 어느 리더도 읽지 않는다.

**분석기가 리더에게 넘기는 것은 렌더링이거나 숫자다.** 구조는 두 모양으로 분석기를 떠난다. 렌더링은 명령의 바이트 하나마다 바이트 하나를 낸다. scan, stmts, recognize, live, flat, noredir, code, wordends 가 그렇다. 거기서 코드가 아닌 바이트는 공백이나 `_` 가 되고(묶음을 닫지 않는 `}` 는 `%`), 리더가 구조로 읽는 바이트(`;` `&` `|` 줄바꿈, 괄호)는 셸이 구조로 읽는 자리에만 남고, 명령이 쓰는 바이트로는 그것을 옮길 수 없다. 레코드는 리더가 구분 바이트에서 자른다. 레코드가 명령의 바이트를 내용으로 실으면 명령이 그 구분자를 쓸 수 있고, 그러면 리더는 셸이 자르지 않는 곳에서 자른다. payload 에서 이 일이 두 번 났다. `sh -c`·`eval` script 와 치환 본문은 한 줄에 하나씩 나갔고, payload 안의 줄바꿈이 그것을 갈랐다. 그다음에는 각각 \035 로 끝났고, payload 안의 \035 가 그것을 갈랐다. 반쪽은 따로 렉싱됐고, 그 바이트 뒤의 설치는 아무 기록 없이 통과했다(판정 buri-20261005-181919: `x=$(echo "<\035>"; pip install evil==6.6.6)` 와 v2.18.1 이 거부하던 다섯 꼴. \035 를 담은 `sh -c`·`eval` script 는 v2.18.1 부터 같은 식으로 통과했다). 구분자를 escape 하면 그 바이트는 닫히지만 부류는 남는다. 레코드마다 구분자마다 기억해야 하고, 같은 부류가 두 번 반려된 것이 바로 그 기억 때문이다. 그래서 payload 뷰는 숫자를 낸다. 종류(`S` 는 `sh -c` script, `E` 는 `eval` 이나 `env -S` script, `B` 는 치환 본문) 다음에, 렉싱한 텍스트의 a 번째 바이트부터 n 바이트를 뜻하는 ` a:n` 과, escape 가 풀었거나 이어 붙이며 넣은 바이트를 코드로 적은 ` #c#c...` 가 온다. 리더는 쥔 텍스트를 자른다(`lex_payload_build`). 자리를 잡을 수 없는 단위(텍스트 밖, 또는 1-127 밖의 코드)는 실패한 읽기다. payload 는 리더 사이를 bash 배열로 다니고, 구분자가 있는 흐름으로는 다니지 않는다. scan-contract 가 알파벳을 붙든다. 두 뷰의 모든 줄은 `!` 이거나 `^[BSE]( [0-9]+:[0-9]+| #[0-9]+(#[0-9]+)*)*$` 에 맞고, 모든 단위가 텍스트 안에 있어야 한다. 기록된 셸 꼴, payload 자리 넷의 제어 바이트 전부, payload 문법과 0x01-0x7f 의 모든 바이트를 섞은 무작위 입력에서 잰다.

| 통로 | 구조를 싣는 방식 | 명령의 바이트가 구분자가 될 수 있나 |
|---|---|---|
| scan, stmts, recognize, live, flat, noredir, code, wordends | 렌더링 | 아니다. 코드가 아닌 바이트는 공백이나 `_` 이고, 묶음을 닫지 않는 `}` 는 `%` 다. |
| stmtcuts | 첫 줄의 오프셋, 그다음 stmts 렌더링 | 아니다. |
| events, cwords | `\037` 필드. `fbyte` 가 `\037` `\036` 줄바꿈을 공백으로 바꾼다 | 아니다. |
| pieces | `\037` 필드, 한 줄에 하나. `pbyte`·`wbyte` 가 `\037` `\036` 탭 줄바꿈을 공백이나 `\002` 로 바꾼다 | 아니다. `\035` 는 지나가서 착지 레코드의 마지막 필드에 들어가고, 그 리더들은 그 필드를 통째로 읽는다. |
| substs, cscripts | 숫자(위) | 아니다. 이번 릴리스 전까지는 payload 바이트를 싣고 \035 로 끝났다. |
| payload 작업 목록(`command_payload_raw_texts`) | bash 배열 | 아니다. 모든 payload 를 그 script 와 치환까지 세 단계 따라간다. 전에는 script 를 그 안의 script 로만 따라가서, `sh -c 'x=$(pip install evil==6.6.6)'` 의 치환은 어느 리더도 읽지 않았다. script 가 무엇을 담든 그랬다(v2.18.1 까지 모든 트리). |
| 문장(`command_statements`) | `\035` 필드, 단어는 `\037` 로 잇는다. 줄 이음은 stmtraw 뷰에서 `\001` | 아니다. 단어 안의 `\037`·`\035` 는 pieces 뷰처럼 `\002` 이고, 명령이 쓴 `\001` 은 stmtraw 뷰에서 `\002` 다. 전에는 그것을 줄 이음으로 읽었다(`c<\001>d` 를 `cd` 로). 이것들은 착지에만 닿는다. 제어 바이트 코퍼스에서 위조한 단어 경계가 움직인 판정은 없었다(판정 lumi-20261005-183050). 이 단어의 따옴표 제거는 아직 따로 있는 리더(`words_of`)이고, 아래 목록에 있다. |
| 착지 레코드(`resolve_install_targets`) | `\035` 필드, 한 줄에 하나 | 아니다. npm 이 답한 디렉터리에 `\035` 나 줄바꿈이 있으면 모르는 곳(`?`, 기록됨)으로 읽고, 설명 필드는 그 자리에 공백을 둔다. fetch 필드는 JSON 한 줄이다. |
| `INERT_READ_REST` | `\035`·`\036` 으로 npm 단어를 잇는다 | 이론상 그렇다. 그 바이트를 담은 단어를 중화하지 않는다. 측정하지 않았고, 이번 릴리스의 inert 설치 플랜에 남겼다. |
| inert 범위 탐색기(`inert_payload_spans`) | `sh -c`·`eval` 머리를 자기 grep 으로 찾고 그 뒤 첫 따옴표까지 | 레코드가 아니라 script 의 두 번째 리더다. 자리를 못 잡는 꼴은 기록되는 강등이다. 이번 릴리스의 inert 플랜과 함께 cscripts 레코드로 옮긴다. |

렉싱 사실은 어느 뷰가 묻든 같다. `$'...'` escape 표는 pieces 뷰에서만 적재됐다. 그래서 cscripts 뷰는 `sh -c $'echo a\npip install evil==6.6.6'` 을 백슬래시와 `n`, 곧 `echo` 뒤의 한 문장으로 읽었고, 그 설치는 v2.18.1 부터 아무 기록 없이 통과했다. 이제 모든 뷰에서 적재한다. 아직 그 사실을 내는 뷰에서만 계산하는 것이 넷 있다. 두 뷰가 다른 답을 낼 수 있는지와 함께 적는다.

| 사실 | 계산하는 뷰 | 두 뷰가 다를 수 있나 |
|---|---|---|
| 문장 시작(`starts_all`) | recognize, stmtcuts, events, cwords, unprefixed, pieces, 닫히는 읽기에서 | 그렇다. 다음 행을 거쳐서다. `fdword` 가 시작을 읽는다. |
| 리다이렉트(`redirs`, `fdword`) | pieces, cscripts, stmts, recognize, stmtcuts, cwords 는 늘. noredir, live, flat 은 닫히는 읽기에서 | 그렇다, 두 곳. 닫히지 않는 읽기에서 noredir·live·flat 은 리다이렉트를 하나도 지우지 않고 나머지는 지운다. 그런 명령은 어느 뷰를 판정에 읽기 전에 `UNDECIDED` 다. 그리고 zsh 가 붙은 것으로 읽는 `{` 뒤의 디스크립터 단어(`{2>/dev/null pip install x; }`)는, 시작을 아는 뷰에서는 리다이렉트의 일부이고 그 밖의 뷰(noredir, live, flat, stmts, cscripts)에서는 앞 단어의 바이트다. 그래서 그 뷰들은 다른 뷰가 지우는 `2` 를 남긴다. 판정을 움직이는지는 측정하지 않았다. |
| 접두(`prefixes`) | unprefixed, recognize, cwords, pieces, 닫히는 읽기에서 | 그것을 다른 뷰의 답과 견주는 리더가 없다. cscripts 뷰는 접두 단어를 남기고 모든 단어에서 셸 이름을 찾으므로, 더 찾을 수만 있다. |
| 배열 대입(`AR`) | 시작 뷰들 | 아니다. 시작만 그것을 읽는다. |

**spec 추출기의 단어도 분석기에서 받는다.** 추출기는 설치 문장을 단어로 읽는다. 리다이렉트를 빼고, 셸의 따옴표 제거를 하고, 문장을 `;`·`|`·`&` 에서 자른 것이다. v2.18.0 전까지는 셋이 각자 리더를 가졌고, 리더마다 따옴표 모델을 따로 가졌다. 분석기의 모델을 흉내 낸 사본이었다. `'...'`·`"..."`·백슬래시만 아는 awk 는 `"$(echo ">'")"` 나 `$'...\'>'` 안의 `>` 를 리다이렉트로 읽고 줄 끝까지를 그 대상으로 가져갔다. 그래서 뒤의 고정 설치가 검사 없이 통과했다. 그 awk 가 대신한 sed 는 단어 맨 앞의 리다이렉트만 읽어서, 따옴표 친 대상을 피연산자로 남겼다. 자르기는 따옴표를 아예 읽지 않아서, `pip install --log "a;b" evil==1.0.0` 은 `evil==1.0.0` 을 설치가 아닌 조각에 남겼다. 사본마다 어딘가에서 틀렸고, 틀린 곳은 조용한 통과였다. 이제 셋 모두 분석기의 바이트 분류를 읽는다. 리다이렉트는 최상위 코드의 연산자 바이트이고, 따옴표는 분석기가 최상위에서 연 곳에서 벗기며, `$'...'` 이스케이프는 풀고, 자르는 자리는 최상위 코드의 구분자다. `scripts/measure/word-reading-forms.json` 은 단어 형태마다 bash·zsh 가 매니저 대역에게 넘긴 argv 를 기록하고, `scripts/test/scan-contract.sh` 는 추출기의 단어가 그 argv 이기를 요구한다. 단어 안에서 추출기가 자를 바이트(공백이나 묶음 문자)는 표지로 남기고, 빈 단어는 표지 하나로 남긴다. 그래서 단어는 한 단어로 남고, 빈 단어도 제자리를 지킨다. 공백에서 자르면 `uvx --python $(which python3) ruff==0.1.0` 과 `uvx --python "" evil==1.0.0` 은 둘 다 옵션에 엉뚱한 값을 주었고, 핀은 검사 없이 지나갔다. 그다음 spec 리더는 단어를 매니저처럼 읽는다. 양 끝의 공백은 건너뛰고, Python 요구사항이면 안의 공백도 모두 건너뛴다. 그래서 `pip install "requests == 2.19.0"` 은 PEP 508 이 말하는 대로 핀이다. 셸의 읽기에 아직 못 미치는 곳이 하나 있고, 흉내 내지 않고 이름을 붙여 둔다. 값이 로캘에 달린(`\u`, `\U`, `\c`) 또는 평범한 한 바이트가 아닌 `$'...'` 이스케이프는 실패한 읽기이고, 그 설치는 `UNDECIDED` 다. 인식기는 별개다. 인식기는 recognize 뷰를 읽는데, scan 뷰처럼 따옴표 친 단어가 비어 있다. 그래서 셸이 따옴표를 벗겨 만드는 명령어 단어(`'pip' install`)와, 따옴표 친 패키지 뒤에 옵션만 오는 러너(`npx "evil@1.0.0"`)를 알아보지 못한다. v2.17.2 도 둘 다 놓쳤다. 그것들을 셸처럼 읽는 것은 플랜 safedeps/command-words-read-as-the-shell-dequotes 의 몫이다.

**리다이렉션은 셸이 읽는 대로 읽고, 인식기는 리다이렉션을 뺀 문장을 읽는다.** 리다이렉션은 연산자, 그 앞에 붙은 파일 디스크립터 단어, 대상 단어로 이뤄지고, 분석기는 셋 다 셸의 규칙대로 읽는다. 디스크립터 단어는 숫자이거나, 중괄호 안의 이름이다. bash 4.1 이상과 zsh 는 이 이름을 셸이 디스크립터를 열어 넣는 변수로 읽는다. `{fd}` 를 명령 이름으로 읽던 때는 `{fd}>/dev/null pip install evil==1.0.0` 이 판정 없이 통과했고, bash 5 는 이 설치를 실행한다. bash 3.2 와 dash 는 `{fd}` 를 낱말로 읽지만, 모든 읽기가 디스크립터로 읽는다. 그래서 그 셸들에는 실행하지 않는 명령을 보여 줄 수만 있다. heredoc 연산자에 붙은 디스크립터 단어(`0<<E`)는 연산자의 일부다. 대상은 셸이 자르는 대로 한 단어이고, 프로세스 치환은 안에 무엇이 있든 한 단어다. `< <(true) pip install evil==1.0.0` 의 대상은 `<` 에서 잘려 빈 단어가 됐고, 그래서 `<(true)` 가 명령 이름 자리에 섰다. bash 3.2, bash 5, zsh 는 이 설치를 실행한다. zsh 는 `>` 뒤의 `!` 를 연산자의 일부로 읽고, bash 와 dash 는 대상의 시작으로 읽는다(위 표). 그래서 `!` 뒤의 공백이 대상을 옮기는 곳에서 bash 읽기가 `DIVERGE` 를 말한다.

인식기는 모든 문장을 리다이렉션을 공백으로 지운 채 읽는다. spec 추출기가 읽는 문장과 같다. 예전에는 리다이렉션이 맨 앞에 올 때만 뗐다. 그래서 매니저와 동사 사이의 리다이렉션은 추출기는 읽는데 모든 인식기에게서 설치를 가렸다. `pip 2>/dev/null install evil==1.0.0`, `cargo 2>&1 add`, `gem >/dev/null install`, `npm >/dev/null install evil@1.0.0` 이 모든 셸에서 판정 없이 통과했고, npm 꼴은 수명주기 스크립트를 실행했다. inert 재작성은 같은 리다이렉션을 지운 live 뷰를 읽는다. 그래서 그 동사를 찾아 원래 명령에서 바로 뒤에 `--ignore-scripts` 를 넣는다. 대상 안에 치환이 있으면 뷰가 하나 더 필요했다. live 뷰는 그 본문을 남긴다. 셸이 본문을 실행하고, 그 안의 npm 설치에도 플래그가 따로 필요하기 때문이다. 그래서 `npm >$(echo f) install x` 에서는 본문이 npm 과 동사 사이에 서 있었고, 동사를 찾지 못했고, 명령은 플래그도 기록도 없이 수명주기 스크립트를 실행했다. 모든 셸에서 그랬고 main 에서도 그랬다. 이제 재작성은 flat 뷰도 읽는다. live 뷰에서 리다이렉션을 통째로 공백으로 지운 뷰이고, 거기서 동사를 찾는다. 리다이렉션 대상이 플래그 행세를 하지도 못한다. `npm install x > --ignore-scripts` 는 이미 플래그가 있는 설치로 읽혀 재작성되지 않았다. 프로세스 치환의 본문은 실행되므로 명령 치환처럼 payload 이고, 그 안의 설치는 추출기에 닿는다. 이것으로 조용한 통과가 하나 더 닫혔다. `cat <(pip install evil==1.0.0)`, `tee >(pip install evil==1.0.0)`, `diff <(cargo add evil@1.0.0) x` 에서 인식기는 설치를 찾았지만 추출기는 그 spec 을 보지 못했고, 명령은 ledger 검사 없이 통과했다. npm 꼴은 `--ignore-scripts` 만 붙어 허용됐다. 설치가 없는 평범한 프로세스 치환(`diff <(sort a) <(sort b)`, `while read l; do echo "$l"; done < <(ls)`)은 판정 없이 그대로 지나간다.

**단어가 어디서 끝나는지는 걸음의 깊이가 정하고, 다른 것은 정하지 않는다.** 셸 문법은 단어 안에 괄호를 둔다. 배열 대입의 값(`a=(x y)`, `a+=(x)`), glob 묶음이나 한정자(`/dev/(null|zero)`, `*.py(N)`, bash 의 `@(a|b)`), 프로세스 치환, zsh 의 `=(...)` 가 그렇다. 분석기의 걸음은 그 문법을 따른다. 그런데 단어를 자르던 함수 `word_sep` 는 정해 둔 바이트 집합으로 답했고, 그래서 그런 단어 안의 공백이나 `)` 가 단어를 끝냈다. 두 답이 어긋난 곳에서는 단어 뒤의 문장을 어느 인식기도 읽지 않았다. `a=(x) pip install evil==1.0.0` 은 bash 와 zsh 에서 실행된다. 게이트는 명령 자리에서 `x)` 를 읽고 통과시켰고, npm 꼴은 `--ignore-scripts` 도 잃었다. main 은 이 꼴을 막았으므로, 접두를 분석기로 옮긴 릴리스의 회귀였다. 세 부류는 main 에서도 통과했다. 치환 안 case 패턴의 `)` 가 값이나 대상을 끝냈다(`>$(case a in a) echo f;; esac) pip install ...`). zsh 의 `=(...)` 와 대상 안의 glob 한정자는 `(` 에서 잘렸다(`< =(true) pip install ...`, `>/dev/null(N) pip install ...`). 그리고 zsh 의 프리커맨드 수식어는 명령으로 읽혔다(`noglob pip install ...`).

이제 그 괄호 하나하나가 `$(...)` 처럼 걸음의 스택에 올라가는 문맥이고, 닫힐 때까지의 모든 바이트는 중첩 안에 있다. 프로세스 치환은 자기를 여는 `<` 나 `>` 를 단어 안으로 가져간다. case 패턴의 닫힘은 맨 위에서만 구분자다. 주석은 자기가 선 문맥의 깊이를 가진다. 그래서 배열 원소 사이의 주석은 배열 밖의 어떤 단어도 끝내지 않는다. `word_sep` 와 pieces 뷰는 깊이를 읽고, 자기 바이트 집합을 두지 않는다. 깊이 말고 걸음에 필요한 것은 매뉴얼에서 닫힌 목록으로 가져온다. 대입 단어는 이름, 있으면 첨자, 그리고 `=` 나 `+=` 다. bash 는 첨자의 대괄호를 안에 무엇이 있든 짝지어 읽는다. 그래서 `a[1 + 1]=x pip install ...` 은 bash 에서만 설치를 실행하고, bash 읽기는 그 공백을 단어의 일부로 읽는다. zsh 의 프리커맨드 수식어는 여섯 개다. `-`, `builtin`, `command`, `exec`, `nocorrect`, `noglob` 이다. 모든 셸에 있는 둘은 이미 읽고 있었고, 나머지 넷은 zsh 읽기에서 접두이자 시작이다. zsh 는 `<N-M>` 도 숫자 범위 glob 으로 읽는다. 그래서 `pip >f<1-2> install ...` 은 zsh 에서 대상 하나와 설치이고, bash 와 dash 에서는 리다이렉션 둘이다. 셸이 갈리는 곳에서는 bash 읽기가 `DIVERGE` 를 말한다(위 표). 그리고 예약어는 온전한 한 단어일 때만 예약어다. 글자만 보고 읽으면 `>f-do(.)` 의 `do` 와 `>f!(x)` 의 `!` 가 각각 뒤에 명령을 두었고, 그 뒤의 `(` 가 `pip >f!(x) install ...` 의 동사를 가져갔다.

걸음은 자기 답도 검사한다. 어느 `(` 가 단어에 속하는지는 분석하면서 정하고, 일부는 그 앞의 바이트를 보고 정한다. 명령이 어디서 시작할 수 있는지는 걸음이 문법에서 정한다. bash 읽기의 세 걸음 어디에도 명령 자리가 없는 곳에 연산자로 남은 `(` 가 있거나, 걸음이 명령 이름으로 읽는 단어 안에 단어 괄호가 있으면, 둘 중 하나가 명령을 잘못 읽은 것이다. 그러면 그 읽기는 실패이고, 패키지 매니저를 부르는 명령은 `UNDECIDED` 다. 이 검사는 위의 꼴을 하나도 닫지 않으며, 꼴을 닫는 것이 이 검사여서도 안 된다. 이 검사가 `!` 경우를 찾았을 때 그 꼴에는 자기 규칙이 생겼다. 검사는 둘이 다음에 어긋날 곳을 위해 남아 있다.

**인식기는 분석기가 단어를 끝내는 곳에서 단어를 끝낸다.** 설치 패턴마다 매니저나 동사를 `([[:space:]]|$)` 로, 자기 집합으로 끝냈다. 분석기는 `;`, 연산자, 괄호에서도 단어를 끝내므로 `npm ci;`, `(npm install)`, `then npm ci; fi`, `npm ci&& ...`, `npm ci|tail` 은 어느 인식기에도 설치가 아니었다. 검사도, `--ignore-scripts` 도, pending 상태도 없었다. 모든 셸이 이 꼴을 실행하고, v2.17.2 도 이미 통과시켰다. 이제 모든 인식기가 단어를 `SAFEDEPS_G_END` 로 끝낸다. 이것은 자기 판단이 아니다. stmts 뷰는 분석기가 단어를 끝내는 바이트를 모두 공백, `;` `&` `|`, `(` `)` `<` `>` 중 하나로 출력하고, scan-contract 가 기록된 꼴과 무작위 입력에서 분석기 자신의 답(`wordends` 뷰)에 대어 그것을 검사한다. 같은 라운드에서 목록 셋을 한 곳씩으로 옮겼다. 명령 단어 앞의 경로는 그 끝의 실행 파일로 읽는다. 경로가 어디를 가리키든 그렇다(`.venv/bin/pip`, `$VENV/bin/pip`, `/usr/bin/env`). 예전 sed 는 자기 시작·끝 집합의 바이트 사이에서 절대 경로만 읽었다. 셸인 단어는 매뉴얼에서 가져온 닫힌 목록 하나(`SAFEDEPS_G_SHELLS`)이고, `-c` 스크립트 리더, 파이프 검사, 경로 떼기가 그것을 읽는다. 한 리더는 sh 로 끝나는 이름을 모두 셸로 읽었고 다른 리더는 셋만 알았다. 그래서 `printf 'pip install x' | dash` 가 통과했다. 그리고 `command`, `exec`, `env` 의 옵션은 각 매뉴얼대로 읽는다. `--` 가 옵션을 끝내고, `exec -aa` 는 이름 `a` 이며, `env -P DIR` 는 값을 받고, `env -S STRING` 은 `eval` 뒤의 단어처럼 스크립트로 읽는다. 이것은 셸의 문법이지 env(1) 의 문법이 아니고, 둘이 다르게 나누는 문자열은 통과한다(밝혀 둔 경계, 위). `time` 은 `-p` 를 받고, `time` 이 /usr/bin/time 인 dash 에서는 `--` 까지의 옵션을 받으며 `-o` 와 `-f` 는 값을 받는다. 걸음과 접두 리더가 같은 단어를 건너뛴다. 생성한 격자가 찾은 두 자리도 시작이다. zsh 는 첫 단어에 붙은 `{` 를 그룹 여는 말로 읽고(`{pip install x; }` 는 zsh 에서만 실행된다), case 패턴 닫힘에 붙은 서브셸(`*)(pip install x);;`)은 그 팔을 시작한다. 머리를 닫는 `)` 에 붙은 명령(zsh `for i (1)pip install x`, `if ((1))pip install x`)은 다른 명령처럼 그 `)` 와 첫 바이트 사이에서 시작한다.

아직 자기 집합이나 목록을 가진 리더가 있다. 아래에 모두 적고, 각각 어느 쪽으로 틀리는지 적는다. 자기 집합을 가졌는데 이 목록에 없는 리더는 결함이다.

| 리더 | 가진 것 | 방향 |
|---|---|---|
| 파이프 검사, `PIPE_SHELL_CONSUMER_RE` | 파이프 뒤에서 명령이 시작하는 자리: 공백, `(`, `{`, recognize 뷰가 끼운 `;`. recognize 뷰가 떼는 프리커맨드 뒤 | 파이프 바로 뒤의 첫 명령인 셸만 읽는다. 파이프 뒤 복합 명령 안의 다른 자리에 있는 셸은 통과한다. 그룹이나 서브셸의 뒤쪽(`printf 'pip install x' \| { :; sh; }`, `\| (cd /; sh)`, `\| { true && sh; }`)이나 복합 명령이 여는 몸(`\| if true; then sh; fi`, `\| while :; do sh; break; done`, `\| for i in 1; do sh; done`, `\| case a in a) sh;; esac`)이 그렇다. 모두 macOS bash 3.2, zsh, sh, dash 에서 설치를 실행하는데 통과한다. 회귀가 아니다. main 과 v2.17.2 도 통과시킨다. 복합 명령의 어느 명령이 파이프를 읽는지 알려면 걸음이 필요하다. 알려진 한계이고 후속 플랜이 있다. |
| 설치 패턴의 옵션 값, `SAFEDEPS_G_O` | 값은 `;` `&` `\|` 나 공백에서 끝난다 | 넓은 쪽. `(` `)` `<` `>` 나 지워진 따옴표를 넘어 읽을 수 있어서 패턴이 더 많이 맞는다. 분석기가 이어 가는 단어를 끝내는 일은 없다. |
| 좁은 옵션 꼴, `SAFEDEPS_G_OPTS`(inert 위치, `python -m pip`) | 값은 다음 공백까지, 옵션 이름은 `[A-Za-z0-9_.-]` | 값은 넓은 쪽. 그 집합 밖의 옵션 이름은 매칭을 끝내므로 재작성이 동사를 못 찾는다. 기록되는 강등이지, 조용한 통과가 아니다. |
| 피연산자 모양(`SAFEDEPS_G_OPERAND`, npm-package-arg 모양, `go run`, `yarn workspace`, `mvn`, `dotnet`) | 인자 하나는 다음 공백까지 | 넓은 쪽. 인자가 `;` 나 `)` 를 달고 갈 수 있지만 단어는 여전히 `SAFEDEPS_G_END` 에서 끝난다. |
| 원문 검사(`SAFEDEPS_G_RAW_INSTALL_RE`, PostToolUse 백스톱, jq 없을 때의 검사) | 아무도 분석하지 않은 텍스트 위의 자기 단어 경계 | 일부러다. 분석기에 물을 수 없을 때를 대신한다. 느슨해서 넓은 쪽이다. |
| 파이프 안 설치 텍스트, `PIPE_MANAGER_RE` | 그 인용 수준에서 데이터인 텍스트 위의 매니저 이름 | 일부러, 느슨하게. scan-contract 가 이름을 `SAFEDEPS_G_EXECUTABLES` 에 맞춘다. |
| npm 흔적의 inert 머리 판정(리다이렉트 없는 `echo`, `printf`, `tail` 등) | 리다이렉트를 찾기 전에 `/dev/null` 리다이렉트와 디스크립터 복제를 지우는 자기 sed | 좁은 쪽이지만 해가 없다. 리다이렉트가 `/dev/null` 로 시작하는 이름의 파일을 쓰는 명령을 inert 로 볼 수 있는데, 그 파일은 lockfile 일 수 없다. |
| 명세 추출기의 묶음 지우기(`guard_extract_specs`) | 문장 단어의 `(`, `)`, `{`, `}` 를 공백으로 지운다 | 중괄호 확장으로 만든 명세(`pip install {evil,x}==1.0.0`)는 쓰인 대로 읽히지 않는다. 설치는 `UNGATED` 기록과 함께 통과한다. 조용한 통과보다 넓은 쪽이다. |
| 문장의 명령 단어(`safedeps_manager_read_once`) | 묶음, `!`, 예약어, `command`, `exec`, `time`, 대입, 옵션을 단 env 를 건너뛴다 | 넓은 쪽. 매니저 이름이 아닌 단어만 건너뛴다. 문장 분할이 걸음의 시작 자리에서 자르므로 이제 예약어로 시작하는 문장은 드물다. 걸음이 명령으로 읽는 `command` 와 `exec` 때문에 목록이 남는다. |
| inert 범위 찾기, `inert_payload_spans` | `-c` 앞의 자기 셸 이름 넷 | `ksh -c '...'` 나 `env -S` 문자열 안의 npm 설치는 제자리에서 재작성되지 않는다. 기록되는 강등이다. inert 설치는 이 릴리스의 다른 플랜이 다시 만드는 중이다. |
| `--ignore-scripts` 의 플래그·pending 키 검사 | 플래그 단어 둘레의 자기 경계 | 같은 플랜에서 설치의 argv 를 읽는 것으로 바뀌는 중이다. |
| 가드 끝의 의심 메모(`curl ... \| sh`, `npm config set ignore-scripts false`, `--registry`) | 원문 경계 | 권고 사유일 뿐이다. 레지스트리 검사는 `--registry=https://registry.npmjs.org;` 를 공개가 아닌 레지스트리로 읽는다. 넓은 쪽. |
| 분석기 안의 역방향 읽기(`cmdpos`, `namehead`, `wordstart`, `forlist`) | `(` 나 단어 앞의 바이트를 읽어 그것이 무엇인지 정한다 | 걸음이 그 답을 검사하고, 어긋나는 곳에서는 읽기를 실패로 둔다. 걸음으로 접는 일은 이 릴리스 뒤로 계획되어 있다. |

산술 `for ((...))` 머리 뒤의 npm 설치는 재작성되지 않고 `UNDECIDED` 다. dash 는 `((` 를 서브셸 둘로 읽으므로 읽기마다 설치가 다른 자리에 있고, 모든 셸에 맞는 재작성 하나가 없다. fail-closed 다.

`scripts/test/consumer-forms.sh` 는 어느 셸이든 실행하는 90 꼴에 패키지를 이름 짓는 판정을 요구하고, 꼴마다 실행한 셸을 단다(macOS bash 3.2, zsh, sh, dash, `setopt` 줄이 있는 에이전트 래퍼와 없는 래퍼, GNU bash 5.2). 같은 단어가 데이터인 꼴과, 단어 괄호가 든 평범한 명령(`files=(src/*.ts); npm run lint`, `ls *.ts(N)`)에는 기록 없는 통과를 요구한다. `scripts/test/scan-contract.sh` 는 모든 단어 괄호의 깊이, 두 닫힌 목록, 그리고 셸이 실제로 `(` 를 읽는 모든 자리에 대한 걸음의 검사를 고정한다.

`scripts/measure/redirection-grid.sh` 는 bash, zsh, dash 매뉴얼이 나열하는 모든 연산자를 리다이렉션이 설 수 있는 모든 자리에 넣고, 그중 넷 뒤에는 대상 단어 여러 개를 넣는다. 그 대상 단어는 손으로 고른 것이었고, 그 뒤의 리뷰는 아무도 고르지 않은 단어를 찾았다. 그래서 단어도 생성한다. 매뉴얼이 단어를 무엇으로 만들 수 있다고 하는지를 표로 두고(87 행, 행마다 매뉴얼 절: bash Quoting, Brace Expansion, Tilde Expansion, Shell Parameter Expansion, Command Substitution, Arithmetic Expansion, Process Substitution, Pattern Matching, Arrays, Shell Parameters, zsh Array Parameters, Process Substitution, Filename Generation, Glob Qualifiers, Precommand Modifiers), 그런 단어가 서는 모든 자리에 넣는다. 대입 접두의 값, 리다이렉션 대상(붙여서, 공백 뒤에, 명령 단어와 인자 사이에, 구분자 뒤에, 함수 본문 안에), 그리고 설치 단어가 데이터인 echo 의 인자다. 이 표는 릴리스 전에 꼴 셋을 더 찾았다. zsh 의 `<N-M>`, 예약어로 읽힌 `do`, 그리고 대상 안 치환 속 주석이 대상을 끝내던 것이다(거기서 판정은 다른 리더 덕에 유지됐고, 읽기는 틀렸다). 명령 자리에 서브셸이 서는 자리도 같은 방식으로 생성한다. `{`, 함수 머리, `do`, `then`, `else`, `!`, `time`, `coproc`, case 갈래, `if`, `while`, `until` 뒤에, `(` 앞에 공백을 둔 꼴과 앞 낱말에 붙인 꼴을 각각 두고, 그 `)` 뒤에 올 수 있는 예약어도 하나씩 둔다. 모두 61 꼴이다. 그중 58 꼴은 어느 셸이든 실행하고, 꼴마다 `UNDECIDED` 가 아니라 설치를 읽은 판정을 요구한다. 나머지 셋은 데이터다. 걸음이 이 자리들을 읽기 전에는 58 꼴 중 여덟이 통과했다. 각 꼴을 셸에서 실행해 재는데, 매니저 자리에는 정확한 설치 인자일 때만 표시를 남기는 대역을 둔다. 그리고 어느 셸이든 설치를 실행하는 곳에는 판정을 요구한다. 커밋된 격자는 8438 꼴이고, 그중 7047 꼴은 아홉 셸 열(macOS bash 3.2, zsh, sh, dash, `setopt` 줄이 있는 에이전트 래퍼와 없는 래퍼, GNU bash 5.2, Linux bash 5.2 와 dash) 중 적어도 하나에서 설치를 실행한다. 데이터 꼴 450 개는 어디서도 실행하지 않는다(`&>` 로 시작하는 연산자는 데이터 자리가 아니다. dash 가 그 `&` 에서 명령을 끝내기 때문이다). `check` 는 앞의 꼴마다 판정을, 뒤의 꼴마다 통과를 요구한다. 격자는 측정 자체의 결함도 찾았다. 대역 이름을 딴 표시 파일이 대소문자를 가리지 않는 볼륨에서 대역 자신과 일치했고, bash 5.2 는 꼴에 끼워 넣는 연산자의 `&` 를 일치한 텍스트로 읽어서 Linux 가 같은 이름 아래 다른 꼴을 만들었다. 그래서 측정 스크립트는 표시가 "아니오" 라고 말할 수 있는지 먼저 확인하고, `check` 는 생성한 꼴과 커밋된 꼴을 비교한다.

**어느 단어가 명령이고, 어느 것이 값이고, 어느 것이 패키지인지는 매니저의 문법이 정하고, 한 번만 읽는다.** 셸 단어가 어디서 시작하고 끝나는지는 분석기가 말한다. 그중 어느 단어가 매니저의 명령이고, 어느 단어가 옵션 값이고, 어느 단어가 패키지인지는 매니저 자신의 파서가 답할 질문이다. v2.18.0 전까지는 리더 넷이 이 질문에 저마다 답했다. 인식 정규식은 값을 받을 수도 있는 옵션을 두 가지로 다 읽어 보고, 둘 다 맞으면 하나를 골랐다. 그래서 `npm --prefix x install evil@1.0.0` 은 `npm x`(exec)로 읽혀 고정 설치가 원장 검사 없이 허용됐고, `bun --cwd x add evil@1.0.0` 도 `bun x` 로 읽혀 같은 식으로 통과했다. 추출기는 매니저 넷의 값 옵션만 알았다. 그래서 `cargo --config x install evil --version 1.0.0` 은 검사 없이 통과했고, `pip --cache-dir x install evil==1.0.0` 은 `install` 이라는 패키지를 기록했다. 기록 워크는 동사처럼 생긴 첫 단어를 동사로 잡았다(`pnpm --dir x add` 가 `npm:add` 를 기록). 착지 판정은 `--prefix`·`--cwd`·`--dir`·`--install-dir` 를 어디에 있든 읽었다. 그리고 runner 리더는 `go run` 뒤 첫 단어를 모듈로 읽어 `go run ./cmd user@example.com` 이 `go:./cmd` 를 기록했다. 넷 다 매니저 문법의 사본이었고, 저마다 어딘가에서 틀렸다.

이제 리더는 `lib/install-grammar.sh` 의 `safedeps_manager_read` 하나다. 문장의 단어마다 역할을 준다. 매니저, 명령 단어, 옵션, 옵션 값, 피연산자, runner 가 실행하는 패키지, runner 가 실행하는 프로그램의 인자 중 하나다. 역할은 같은 파일에 있는 매니저별 표에서 읽는다. 표에는 명령 경로(`uv pip install`, `yarn workspace <name> add`, `dotnet add <project> package`)와 값을 받는 옵션이 명령별·종류별로 있다. 종류는 평범한 값, 디렉터리, 모든 피연산자를 고정하는 버전, 패키지(`npx --package`, `pip -e`), 실행되는 패키지 옆에 더해지는 패키지(`uvx --with`)다. 각 항목의 출처는 그 매니저의 도움말이나 소스이고, 표 옆에 적어 두었다. 명령 뒤에서는 표에 없는 옵션을 값을 받지 않는 것으로 읽으므로 그 값은 피연산자가 된다. 그 대가는 검사나 기록 하나이고, 패키지를 건너뛰는 일은 없다. 명령 앞에서는 그런 옵션 뒤 단어를 그 옵션의 값으로도, 원래 그대로의 단어로도 읽고, 게이트는 두 읽기를 다 판정한다. `bun --zzz x add evil@1.0.0` 은 bun 이 `x add` 를 실행하든 evil 을 설치하든 검사된다. 추출기, 기록, npm 이 아닌 설치의 착지, runner 리더는 모두 이 역할만 읽는다. 인식 정규식은 이제 "설치일 수 있다"만 말하는 거름망이다. 옵션 자리에서 값이 scan 뷰의 여러 단어에 걸칠 수 있게 했다. 치환이 scan 뷰에서 그렇게 보이기 때문이다. 그래서 거름망은 리더가 찾는 설치보다 넓기만 하고 좁지는 않다.

npm 의 역할은 npm 자신의 파서에서 온다. npm 은 인자를 nopt 와 `@npmcli/config` 의 옵션 타입으로 읽는다. 그래서 리더는 npm 의 표를 가지고 nopt 를 그대로 따라 한다. 값 타입과 Boolean 타입, `=` 값, `--no-`, 유일한 약어, shorthand 전개가 다 들어 있다. npx 는 자기 패스를 먼저 돌린다. 스위치로 모르는 옵션이면 다음 단어를 값으로 가져가고, 그 결과를 npm 에 넘긴다. `scripts/measure/npm-option-reading.sh` 는 PATH 의 npm 에서 표를 만들고, nopt 자체를 인자 목록 사천 개에 돌려 대조한다. 표는 npm 11.19.0 의 것이다. GitHub CI 와 많은 머신이 쓰는 npm 10.8.2 는 그중 26개 옵션을 정의하지 않는다. npm 10 에게는 그 옵션 뒤 단어가 값이 아니라 명령이나 피연산자다. `npm --min-release-age install evil@1.0.0` 은 npm 10 에서 evil 을 설치한다. 그래서 그런 옵션이 하나라도 있는 문장은 npm 10.8.2 의 정의로 한 번 더 읽고, 게이트는 두 읽기의 합집합을 판정한다. 다른 버전의 npm 은 표와 대조하고, 표와 다르게 정의된 옵션을 그 버전의 경계로 이름 붙여 보고한다.

다른 매니저의 표도 물어볼 수 있는 곳에서는 매니저와 대조한다. 항목이 빠지면 검사 하나가 늘어난다. 매니저가 스위치로 읽는 옵션이 표에 있으면 패키지 하나를 잃는다. 그 옵션 뒤 단어를 값으로 가져가는데, 그 단어가 패키지면 아무것도 그것을 검사하지 않는다. bun 표의 한 초안은 bun 의 실행용 옵션(`bun --help` 의 `--print`, `--eval`, `--preload`, `--port` 등 서른 개 남짓)을 bun 의 모든 명령에 걸어 두었다. bun 은 설치할 때 이 옵션들을 스위치로 읽는다. 그래서 `bun add --print evil@1.0.0` 은 검사도 기록도 없이 통과했다. `scripts/measure/manager-option-reading.sh` 는 PATH 에 있는 npm 밖 매니저마다 한 형태를 어떻게 읽는지 묻고, 리더의 역할을 그 답과 비교한다. bun 은 합성 로컬 패키지로 실제로 돌리고, 레지스트리 설정은 모두 닫힌 포트로 둔다. pip 은 pip 자신의 파서에 묻고, python 은 실행해 보고, uv·cargo·go 는 도움말을 읽는다. 매니저는 설치하는데 리더가 값으로 읽는 단어가 하나라도 있으면 실패한다. bun 1.4.2 에서 두 가지가 나왔다. bun 은 `-` 로 시작하지 않는 첫 단어를 명령으로 잡는다. 그래서 명령 앞에서는 어떤 옵션도 값을 받지 않고(`bun --cwd x add y` 는 `bun x add y` 를 실행한다), 리더는 그런 단어를 두 가지로 다 읽는다. 그리고 `-c, --config` 는 `=` 뒤에서만 값을 받는다. 명령 자신의 항목을 `*` 보다 먼저 찾고, 한 옵션을 둘 다에 적지 않는다. 그래서 명령의 읽기가 매니저 전체 항목으로 정해지는 일은 없다. pnpm, yarn, pipx, poetry, pipenv, gem, bundle, dotnet, mvn 은 설치되지 않은 곳에서 이름을 붙여 건너뛰고, 그 표는 도움말과 소스가 말하는 그대로 둔다. 한 매니저의 두 버전이 옵션 하나를 다르게 정의하면 npm 처럼 문장을 두 가지로 다 읽는다. poetry 1.8.5 는 `add --optional` 을 스위치로 읽고, poetry 2.x 는 extra 이름을 받는 옵션으로 읽는다. 그래서 `poetry add --optional evil==1.0.0` 은 1.8.5 에서 evil 을 추가하고, 게이트는 그것을 검사한다.

단어별 리더는 게이트 자신의 셸 안에서 돈다. 그래서 어느 것도 실패해서 "spec 없음"으로 읽힐 수 없다. `scripts/test/scan-contract.sh` 가 이 리더들이 프로세스를 띄우지 않는지 확인한다. 문법은 예시가 아니라 철자로 고정한다. `scripts/test/manager-variants.sh` 는 값이 설 수 있는 자리마다 값을 아홉 가지로 써 넣는다. 자리는 명령 앞의 매니저 옵션, 명령의 옵션, runner 의 옵션, runner 패키지 뒤의 단어다. 그리고 판정, 처방, 기록이 어느 철자에서나 같기를 요구한다. bun 의 실행용 옵션도 하나씩 bun 의 모든 설치 철자에서 패키지 바로 앞에 놓아 본다. 표 자체도 확인한다. 명령의 항목을 먼저 읽는지, 모든 범위가 리더가 닿는 명령 경로인지 본다. `scripts/measure/tuple-replay.sh` 는 이 세 답을 두 리비전에서 다시 내 보고, 움직인 행이 빠진 검사나 기록, 가짜 검사나 기록, 이유가 붙은 판정 이동 중 하나로 분류되지 않으면 실패한다.

**셸에 넘기는 script 는 셸이 넘기는 단어 그대로 읽는다.** `sh -c`·`eval` 리더는 전에 payload 를 따옴표 친 단어 하나로, 첫 짝 따옴표까지 읽었다. 그 지점을 넘어 이어지는 단어(안에 이스케이프된 따옴표가 있거나(`sh -c "echo \"hi\"; pip install ..."`), 따옴표가 더 붙어 있거나, ANSI-C 단어거나, 이스케이프가 든 따옴표 없는 단어)는 읽은 데까지만 읽혔고, 셸이 그 뒤에서 실행하는 설치는 판정 없이 통과했다. 그런 단어를 모두 읽기 실패로 표시하는 바닥이 그것을 막았지만, 평범한 명령까지 `UNDECIDED` 로 만들었다. 실측 30개 중 24개였고, `bash -c "cd \"$dir\" && npm run build"` 도 그 안에 있었다. 이제 리더는 렉서 뷰(`cscripts`)에서 script 를 받는다. 이 뷰는 셸이 단어를 자르는 자리에서 자르고 셸의 따옴표 제거를 적용하며, script 안의 script 도 읽는다. 우회 형태는 모두 그것이 실행하는 설치로, 실제 처방과 함께 판정된다. 평범한 명령은 통과하고, 따옴표 안에 적힌 `sh -c` 는 데이터다. 렉서가 값을 정할 수 없는 ANSI-C 이스케이프만 여전히 읽기 실패다.

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
- **Phase 3 — npm primary effect gate.** PostToolUse hook 이 `package-lock.json` 과 npm 의 숨은 `node_modules/.package-lock.json` 에서 읽은 실제 closure 를 ledger 의 direct entry + `transitive_specs` 와 대조하고 OSV batch 로 재조회한다. 미승인·취약 패키지가 있으면 마지막 confirmed snapshot 으로 reorg 한다. 이 권위는 npm closure 한정이다.

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

**guard 는 자기 예산을 따로 갖는다.** 런타임은 이 훅에 고정 예산을 주고(인스톨러가 등록한다) 그게 지나면 죽인 뒤 tool call 을 그대로 진행시킨다 — Claude Code 에서 실측(2026-08-04). 커맨드 스캔은 길이에 대해 초선형이었고 그 예산은 패딩만으로 닿았다: 여기 실측으로 커맨드 텍스트 28KB 가 29s, 32KB 가 38s 였다. 스캔은 v2.18.0 부터, macOS 에서 판정 전체는 v2.18.1 부터 선형이지만 비용은 여전히 커맨드와 함께 늘어서, 충분히 큰 커맨드는 그래도 예산에 닿는다. 그 선을 넘으면 게이트가 아무 말 없이 사라졌고, `pip`·`cargo`·`go`·`gem` 처럼 이 게이트가 advisory 가 아니라 권위인 생태계에서는 스캐너를 전혀 몰라도 되는 우회다.

런타임의 타임아웃 동작은 safedeps 소관이 아니지만, 그게 발동하기 전에 답을 내는 것은 소관이다. guard 는 판정을 자식 프로세스에서 `SAFEDEPS_SELF_BUDGET_SECONDS`(기본 20) 아래 돌리고, 그 자식이 기한까지 답을 못 내면 guard 가 대신 답한다: deny — 판정하지 못한 설치는 돌면 안 되기 때문이다. 그 deny 가 지켜야 할 두 가지 — fail-closed 이지만 **적발이 아니다**(사유가 `UNDECIDED, not unsafe` 로 시작하고 아무것도 탐지되지 않았음을 명시한다. "못 끝냈다" 와 "찾았다" 를 구분 못 하는 독자는 게이트를 우회하는 법을 배운다), 그리고 다른 모든 우회·불가용과 마찬가지로 `advisory.log` 에 기록된다.

**그 예산은 낮추는 것만 된다.** `SAFEDEPS_SELF_BUDGET_SECONDS` 는 25s 상한으로 클램프된다. 낮추는 쪽은 자유다 — 짧은 예산은 더 일찍 거부할 뿐이다. 반대로 런타임 예산 이상의 값은 예산이 아니다: 런타임이 훅을 먼저 죽이고 tool call 은 그대로 진행되는, 이 기계장치가 없애려던 바로 그 fail-open 이다. 그리고 그 값을 올릴 동기는 아주 자연스럽다 — 큰 커맨드에서 `UNDECIDED` 를 만난 사람은 "예산이 짧네" 로 읽고, 보안 경계를 끌 의도 없이 끈다. 사용자가 옮길 수 있는 경계는 경계가 아니라 기본값이다. 클램프는 예산이 실제로 작동하는 지점에서 알린다 — stderr, `advisory.log`, 그리고 deny 사유. 조용히 깎으면 사용자는 한 번도 참이었던 적 없는 숫자를 놓고 디버깅하게 된다.

값은 무엇이 비교되기 전에 정규화되고, 산술에는 정규화된 숫자만 들어간다. 이 순서가 핵심이다 — bash 산술은 `^[0-9]+$` 검사보다 넓은 문법을 받으므로, 정규식으로 검증하고 마감은 원본 문자열을 소비하면 `+40`·` 40`·`0x28` 이 클램프를 건너뛴 뒤 그대로 40 으로 평가된다. 공백 하나로 fail-open 이 복원되는 것이다. 앞뒤 공백과 선행 `+` 는 친 사람의 의도대로 읽고, 그 밖의 값은 예산이 아니므로 기본값으로 돌아간다 — 상한 안쪽이고, 클램프와 같은 채널로 알린다.

크기보다 길이를 먼저, 그것도 문자열 영역에서 검사한다. bash 정수는 64비트이고 조용히 감기기 때문이다. 음수로 감긴 값은 상한보다 크지 않으므로 클램프를 그대로 통과하고, 밀리초로 곱하면 한 번 더 감겨 영영 오지 않는 마감이 된다 — 실측으로 30자리 예산이 600s 를 넘겨도 답을 내지 않았다. 어느 방향으로 감기는지가 값에 따라 갈리므로 감김에 기댈 수 있는 건 없다. 그래서 아홉 자리를 넘는 숫자는 산술이 보기 전에 자릿수로 클램프한다 — 아홉 자리는 초로 약 31년이라 실제 예산에서 한참 멀고, 마감 곱셈이 감당할 수 있는 범위 안쪽으로도 한참 여유가 있다.

**30s 는 어디서 오고, 무엇이 이 숫자를 낡게 만드나.** 훅 페이로드는 런타임 예산을 싣지 않고, 여러 settings 파일의 훅 등록이 모두 발화하므로 가드는 자기를 띄운 등록이 어느 것인지 런타임에 알 수 없다. 대신 할 수 있는 것은 safedeps 자신이 등록하는 숫자를 명시하는 것이다 — `scripts/install/install-safedeps-hooks.mjs` 의 `PRE_HOOK_TIMEOUT_SECONDS`, 30s, 실측 kill 시각과 일치한다. smoke 테스트가 두 상수를 함께 고정하므로, 인스톨러가 바뀌었는데 가드만 낡은 숫자로 상한을 계산하는 상태는 나올 수 없다. 상한과 런타임 예산 사이 5s 는 가드가 **예산 창 바깥에서** 쓰는 비용이다: 마감을 지나 최대 폴 스텝 하나(요청한 1s 에, 부하가 그 sleep 하나에 더하는 만큼), KILL 전 TERM 유예 최대 0.5s, 프로세스 시작·reap·`jq` 에 약 0.1s — 한가한 머신에서 구조적 최악 1.6s 이고, 실측 종단 초과분은 0.73~1.05s 로 커맨드 4KB 에서 256KB 까지 평평했다(2026-08-04, 마감이 시계를 읽기 전). 등록된 타임아웃을 손으로 30s 아래로 고친 사용자는 이 상수가 알 수 있는 범위 밖이다.

**마감은 시계를 읽는다.** 예전에는 폴링이 요청한 sleep 시간을 더해서 마감을 쟀다. 부하가 걸린 머신에서는 sleep 이 요청보다 오래 걸리므로, 실제 대기는 폴링마다 부하가 더한 만큼 예산을 넘겼다. 런타임 예산을 넘기면 훅이 죽고 설치는 판정 없이 진행된다. 이제 가드는 bash 의 `SECONDS` 를 읽는다. bash 3.2(macOS 가 훅을 돌리는 셸)에도 있고, 읽는 데 프로세스가 들지 않는다. 기준은 가드 자신이 시작한 시점이다. 런타임의 타이머는 판정이 아니라 훅과 함께 시작하기 때문이다. bash 는 `SECONDS` 를 환경변수에서 초기화하므로, 가드는 값 자체가 아니라 시작 값과의 차이만 비교한다. 그렇지 않으면 export 한 `SECONDS` 가 또 하나의 off 스위치가 된다. 초 단위라서 예산이 최대 1초 일찍 끝날 수는 있어도 늦게 끝나지는 않고, 일찍 끝나면 더 일찍 거부할 뿐이다. 폴링은 여전히 50ms 에서 시작해 1s 까지 두 배씩 늘어난다. 그래서 빠른 판정은 전과 똑같이 빨리 답하고, 마감은 많아야 폴 스텝 하나만큼 늦는다. 요청한 sleep 의 합은 벽시계에 기대지 않으므로 두 번째 한도로 남는다. 회귀: `scripts/test/self-budget.sh` 의 부하 머신 행들. 모든 sleep 을 세 배로 늘려서 확인한다.

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
   실제 closure 읽기: package-lock.json + node_modules/.package-lock.json
   모든 pkg@version 을 ledger(direct entry + transitive_specs)와 대조
   전체 closure 를 OSV batch 로 재조회
   설치가 두 기록 중 어디에든 새로 들인 것을 명령 전 기록과 대조해
     검사: install script, resolved 출처 (v1 reorg-guard 로직)
   설치가 들인 바이트 가운데 npm 이 공개 registry 에서 받았다고 답하지 않은 것을
     integrity 로 기록 (머신 전역, 롤백보다 먼저)
   native binary 검사
        │
        ├─ 전부 승인·clean·무의심 ──► CONFIRM (새 안전 baseline)
        └─ 미승인 / 취약 / 의심 ──► REORG:
                 • lockfile ← 마지막 confirmed snapshot, 없으면 명령
                   직전 snapshot (그렇다고 알림)
                 • 프로젝트 자신의 node_modules(실제 디렉터리)를 지움,
                   명령이 프로젝트의 node 트리에 쓴 것이 있을 때만;
                   패키지 매니저는 돌지 않는다 — 다음 설치가 게이트를 지나
                   다시 깐다(심볼릭 링크면 거부하고 이름을 남긴다)
                 • reorg.log 기록; 에이전트에 경고
```

**기준점은 마지막으로 검증된 설치가 남긴 상태, 그것도 검사가 읽은 그대로다.** post-verify 는 검사가 프로젝트를 읽기 전에 lock·manifest 파일을 새 스냅샷(`verified-<id>`, `verified_from` 이 설치 전 스냅샷을 가리킨다)으로 복사한다. CONFIRM 때 프로젝트를 그 사본과 비교하고, 모든 파일의 바이트가 그대로일 때만 스냅샷의 `meta.json` 을 쓰고 `confirmed_${dir_hash}` 를 그것으로 옮긴다. 예전에는 설치 전 스냅샷을 확정했기 때문에 기준점이 설치 한 번만큼 뒤처져 있었다. 로컬 레지스트리에 실제 npm 으로, Claude Code 와 Codex 양쪽에서 측정했다: 승인된 `npm install a` 다음 승인되지 않은 `npm install b` 는 `package.json`, `package-lock.json`, `node_modules` 어디에도 `a` 가 없는 프로젝트로 롤백됐고, 승인 설치를 하나 더 하면 빠지는 쪽은 처음이 아니라 마지막으로 검증된 설치였다. `scripts/test/lockless-forms.sh` 가 둘 다 고정하며, 기준점을 앞으로 옮기려고 넣었던 검증된 `npm install` 한 번은 더 이상 필요 없다.

복사를 검사 앞에 두는 이유는, 검사 뒤에 뜬 사본은 그때 프로젝트에 있던 것을 무엇이든 기록했기 때문이다. 같은 배터리에서 일정을 고정해 측정했다: 다른 Bash 호출의 미승인 설치가 closure 검사와 복사 사이에 끝나자 그 설치가 기준점에 들어갔다. 그 설치 자신의 롤백은 그것을 지우지 못했고, 롤백의 `npm ci` 가 그 설치 스크립트를 실행했다. 배터리는 이 일정을 Claude Code 에서 고정한다. 거기서는 `npm rebuild` 가 검사와 기록 사이에 있다. Codex 에는 그 자리에 rebuild 가 없어서 창이 더 짧을 뿐 모양은 같고, 같은 코드가 닫는다(미측정). 사본을 검사에 묶는 것은 비교다. 비교가 없으면 복사와 closure 검사 사이에 바뀐 파일이, 검사가 다른 것을 읽었는데도 기록된다. 위의 고정 일정은 복사만으로도 기준점에 들어가지 않으므로, 배터리는 비교가 내는 메시지로 비교를 고정한다. 비교하는 것은 검사 전과 후의 바이트가 같은가이다. 그 사이에 바뀌었다가 같은 바이트로 되돌아온 변화는 보지 못하지만, 기록되는 바이트는 여전히 양 끝에서 프로젝트가 담고 있던 그것이다.

기준점이 무엇인지에서 경계 셋이 나온다:

- **파일이지 `node_modules` 가 아니다.** 롤백은 `node_modules` 를 지우고, 다음 설치가 복원된 파일로 그것을 다시 만든다. 그래서 아무것도 저장하지 않은 검증된 설치(`--no-save`)는 기준점에 들어가지 않고, 이후 롤백에서 그 패키지는 `node_modules` 와 함께 사라진다.
- **게이트 전체를 통과한 설치만 기준점을 옮긴다.** 명령과 무관한 백스톱은 npm closure 검사만 돌리므로, 파서가 놓친 설치를 clean 으로 판정하면 기록하고 그대로 두지만 확정하지는 않는다. 이후 롤백은 그 이전 기준점으로 돌아간다.
- **기록하지 못한 기준점은 움직이지 않는다.** 복사가 실패한 경우, `meta.json` 을 쓰지 못한 경우, 검사가 도는 동안 파일이 바뀐 경우가 모두 여기에 든다. 어느 경우든 포인터는 그대로 두고, `advisory.log` 에 이유를 남기고, 이후 롤백이 이 설치까지 되돌린다는 사실을 사용자에게 알린다. 새 스냅샷의 `meta.json` 은 rename 으로 마지막에 쓰이고 모든 판독자가 그것을 요구하므로, 중간에 죽은 실행이 파일이 빠진 기준점을 남기는 일은 없다. 다만 복사한 파일은 남고, 정리되지 않는다. 정리는 `*_meta.json` 을 열거하는데, `meta.json` 이 없는 스냅샷은 검사가 도는 동안 진행 중인 실행이 들고 있는 것이기도 하다. 디스크만 봐서는 둘을 구별할 수 없고, 진행 중인 것을 정리하면 그 `meta.json` 이 빠진 파일 위에 쓰이게 된다. 그래서 죽은 실행이 치르는 값은 작은 파일 몇 개만큼의 디스크이지, 잘못된 기준점이 아니다. `meta.json` 전에 죽은 설치 전 스냅샷도 같은 식으로 남는다.

**이 게이트도 같은 예산을 받고 같은 방식으로 죽는다 — 가정이 아니라 실측이다.** PreToolUse 동작을 확정한 그 프로토콜로(샌드박스 프로젝트, 시작과 완료를 각각 기록하는 훅, 예산 내 통제군과 예산 초과 실험군) 쟀더니, 5s 예산에 20s 작업을 준 PostToolUse 훅은 시작만 하고 끝내지 못했고 1s 통제군은 끝냈다. 위 작업은 safedeps 가 통제하는 것이 아니라 사용자 프로젝트와 네트워크에 매인다: `npm ci`, `npm install`, `npm rebuild`, 그리고 closure 전체에 대한 OSV 배치.

그래서 "효과게이트가 커맨드 게이트를 받쳐준다" 는 문장은 예산 **안에서만** 참이고, 실패의 종류는 더 나쁘다: 죽은 pre 훅은 판정 못 한 커맨드 하나를 통과시키지만, 죽은 post 훅은 롤백 도중에 떨어질 수 있다. 시간이 다했을 때 pre 훅의 답은 deny 지만(Phase 2), 설치 후 게이트는 deny 할 수 없다 — 커맨드가 이미 돌았다. 그래서 그 답은 별개의 설계 문제이고 `safedeps/effect-gate-killed-mid-rollback` 으로 추적하며 여기서 풀지 않는다. Codex CLI 의 타임아웃 동작은 두 훅 모두 여전히 미측정이라 parity 를 가정하지 않는다.

### Phase 0 — 설치되는 커맨드는 엔트리 셔틀이다 (`safedeps-hook-entry.sh`)

두 엔진 모두 훅 이벤트당 하나의 커맨드를 등록한다: `…/skills/safedeps/scripts/safedeps-hook-entry.sh pre|post`. 이 경로는 매 Bash tool call 마다 `~/.claude`/`~/.codex` 스킬 심링크를 거쳐 라이브 레포 체크아웃으로 해석된다. 작업트리가 곧 런타임이다. 그래서 머지 중·편집 중·업데이트 중인 체크아웃은 훅 동작을 즉시 바꾸는데, 셔틀이 생기기 전에는 그다음에 벌어지는 일이 우연한 종료코드로 결정됐다. bash 문법 오류(머지 충돌 마커)는 exit 2 로 끝나고 두 엔진 모두 이를 차단 deny 로 취급해서, 이 머신의 모든 세션이 파서 메시지 한 줄만 남기고 Bash 를 잃었다(2026-08-04 실제 발생). 파일 부재는 exit 127, 런타임 크래시는 exit 1 — 둘 다 *비차단* 훅 실패라서, 그런 형태의 깨짐은 설치 게이트를 조용히 통째로 없앴다.

셔틀은 두 결과를 모두 설계된 것으로 만든다. 진짜 훅은 의도된 모든 경로에서 exit 0 이므로(결정은 JSON 으로 나간다), 비영 종료는 곧 소스 자체가 아프다는 뜻이다. 셔틀은 깨짐을 분류하고(파싱 불가 / 크래시 / 부재), 체크아웃에 머지·리베이스가 진행 중인지 확인해 그렇다고 말한 뒤, 머신 전체라는 폭·원인·복구 경로를 담은 메시지와 함께 exit 2 로 끝난다. fail-closed 는 fail-closed 로 남는다 — 익명이기를 멈출 뿐이고, fail-open 형태들은 침묵하기를 멈춘다.

셔틀은 자기가 멈추는 경우에도 답한다. bash 는 프로세스를 하나라도 띄우지 못하면 스크립트를 끝낸다. bash 3.2 는 곧바로 128 로, bash 5 는 15초쯤 재시도한 뒤 254 로 종료한다. 두 엔진은 둘 다 비차단 실패로 읽으므로, 프로세스가 바닥난 머신에서는 tool call 이 게이트 없이 실행됐다. 같은 조건이 진단을 틀리게 만든 적도 있다. `dirname` 안의 fork 가 실패해 셔틀이 자기 위치를 `/` 로 잡았고, 훅이 그곳 체크아웃에서 빠졌다고 보고했다. 이제 셔틀은 위치를 매개변수 확장으로 구하고, 메시지는 내장 명령으로 쓰며, 자기가 고르지 않은 모든 종료를 EXIT 트랩에서 설명이 붙은 exit 2 로 바꾼다. bash 3.2 와 bash 5.2 실측: 전에는 exit 128 과 254, 후에는 fork 실패를 밝히는 거부다. `scripts/test/hook-entry.sh` 는 프로세스 한도 1 로 이 조건을 실제로 재현한다. root 는 그 한도를 받지 않으므로 거기서는 그 행이 건너뛰었다고 스스로 말한다.

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
  비표준 registry (--registry, 또는 npm 자신의 답) · install-script safety disabling · eval/subshell indirection
  + 빠른 advisory ledger check: 미승인/expired spec → block + advisory-gate 안내

npm PRIMARY EFFECT GATE + REORG (safedeps-post-verify.sh)
  • install script 의 network / code-execution / sensitive-path 접근
  • base64 / hex obfuscation
  • 비표준 registry resolved URL · 50+ dependency explosion · native binary
  • npm lockfile closure 가 approved spec / transitive_specs 와 diverged → REORG
```

**Install-script 타이밍.** 패키지의 `postinstall` 은 `npm install` *도중에* 실행된다. Claude Code 에서는 Phase 2 hook 이 `--ignore-scripts` 를 주입한다. 설치를 무실행으로 두고, effect gate 가 closure 를 confirm 한 뒤에야(`npm rebuild`) 스크립트가 돌게 하며, 거부된 패키지의 스크립트는 돌지 않게 하려는 것이다. 이것은 재작성의 목적이지 safedeps 가 약속할 수 있는 것이 아니다. npm 이 그 플래그를 지키는지는 명령에 보이지 않는 셸 상태가 정하므로(아래 경계 참고), 기록은 safedeps 가 플래그를 붙였다고만 말하고 스크립트가 하나도 돌지 않았다고는 말하지 않는다. 플래그는 npm 이 참으로 읽는 자리에 붙고, 그 자리는 가정하지 않고 확인한다. npm 은 같은 옵션의 마지막 값을 따르므로, 동사 바로 뒤에 넣은 플래그는 뒤에 오는 `--ignore-scripts=false`, npm 이 펼치는 줄임말(`--no-ignore`, `--ign=false`), 셸이 실행 때 펼치는 단어에 모두 졌다. 그래서 먼저 시도하는 자리는 각 npm 설치의 마지막 인자 뒤, `--`·리다이렉션·주석·문장 끝 앞이다. 그 자리도 틀렸다. 마지막 단어가 다음 단어를 값으로 받는 옵션(`--cache`, `-C`, `--reg`, `--fetch-retries`)이면 플래그가 그 값이 되었고, 설치는 기록 없이 스크립트를 돌렸다(npm 11.19.0). 그래서 각 자리에 플래그를 둔 문장을 다시 읽고(`safedeps_npm_read_args`, 두 npm 버전), ignore-scripts 가 참이고 위치 단어·옵션 값·다른 스위치가 전과 같을 때만 그 자리를 쓴다. 자리는 마지막 인자에서 동사 쪽으로 거슬러 시도하므로, `x --cache` 는 `--cache` 앞에 플래그를 받는다. 재작성은 언제나 safedeps 가 설치의 단어를 읽기 전의 재작성, 곧 7d66f8c 의 재작성도 담는다. 모든 동사 바로 뒤의 플래그, 그리고 7d66f8c 가 끝에 붙이던 명령(`;&|()`$`·주석·heredoc 없는 한 문장: `inert_release_appends`)이면 끝의 플래그다. 이것이 바닥이고, 먼저 읽어 보지 않는다. 바닥은 참인 플래그를 더하거나, 7d66f8c 의 플래그가 그랬듯 동사 뒤의 `true`·`false` 를 값으로 가져갈 뿐이다. 7d66f8c 는 이번 릴리스 주기의 트리이고 공개된 v2.17.2(bb0787d)가 아니다. 재작성이 셸처럼 읽을 수 없는 텍스트 안의 npm 설치는 v2.17.2 가 넣던 자리에 플래그를 받는다. 그 텍스트는 백슬래시·백쿼트·`$(` 가 든 큰따옴표 `sh -c`·`bash -c`·`zsh -c`·`dash -c`·`eval` 스크립트, 다른 셸에 넘기는 스크립트(`ksh -c`, 여기의 어느 읽기도 그 문법을 따르지 않는다), 그리고 다른 명령에 파이프로 넘기는 heredoc 본문이다. 거기서는 뒤에 공백이 오거나 줄의 끝인 npm 설치 동사마다 바로 뒤에, 쓰인 텍스트 그대로 플래그를 넣는다(`inert_unread_offsets`). 그 텍스트가 어디서 시작하고 끝나는지는 렉서의 `classes` 뷰가 말한다. 그래서 이스케이프된 따옴표, 자기 따옴표를 가진 치환, 붙은 따옴표가 그 안에 남고, 따옴표 안에 중첩된 코드는 명령의 읽기에 맡긴다. 명령의 다른 설치는 읽어서 정한 자리를 그대로 갖고, 명령은 `advisory.log` 에 플래그를 아무도 읽지 못한 것으로 기록된다(`ignore_scripts_unread: true`). v2.18.0 은 그런 명령에 읽을 수 있는 설치까지 포함해 `--ignore-scripts` 를 하나도 주지 않았고, v2.17.2 는 그것들에 플래그를 주었다. `scripts/measure/inert-downgrade-grid.sh` 가 같은 꼴에서 두 트리를 잰다. 그 텍스트에서 뒤에 공백이 오지 않는 동사(`sh -c "cd \"d\" && npm ci"`)는 v2.17.2 에서처럼 플래그를 받지 못한다. 재작성이 읽지 않은 설치의 기록은 명령 바이트에 대한 허용 목록이고, 입력은 둘이다. 바이트, 그리고 재작성이 읽은 동사다. 동사는 그 `npm` 이 그것을 읽은 텍스트, 곧 명령이나 재작성이 읽은 스크립트의 명령 단어일 때만 읽은 것으로 친다. 처음, 구분자·`(`·백쿼트 뒤, 명령이 뒤따르는 예약어(`then`, `do`, `!`) 뒤가 그 자리다. 인식기가 벗기는 접두(대입, 리다이렉션, `env` 와 그 옵션, `command`, `exec`)는 빼고 보며, 그 자리에 있는 경로의 마지막 조각(`./node_modules/.bin/npm`)도 친다. 그 자리는 렉서의 `cmdword` 뷰에서 읽는다. 이 뷰는 걷기가 문장 시작마다 따로 뗀 접두를 제자리에서 공백으로 바꾸므로, 뷰의 오프셋이 곧 명령의 오프셋이다. 재작성이 닿지 못하는, 치환 안에 중첩된 `}` 에 붙은 동사도 읽은 것이 아니므로, 기록은 그것이 지키는 바닥 옆에서 그 동사를 본다. 붙은 스크립트 단어의 첫 따옴표 덩어리 안의 동사와, v2.17.2 가 넣던 자리에 플래그를 받은 동사는 읽은 것이 아니다. 그다음 읽은 `npm` 을 모두 가리고, 명령 자신의 주석(class `m`)을 공백으로 바꾸고, 따옴표와 백슬래시를 모두 뺀 텍스트를 읽고, 셸 자신의 따옴표 제거로 한 단계씩 세 단계까지 다시 읽는다. 넘겨받은 스크립트가 윗단계가 남긴 텍스트를 읽는 것과 같다. `$'...'` 는 그것을 읽는 단계에서 그 자리에서 푼다. 그래서 풀린 바이트는 양옆 텍스트와 이어지고(`n$'\x70'm`), 풀린 줄바꿈은 줄을 시작하며(`true$'\n'npm ci`), 작은따옴표로 싼 here-string 안의 ANSI-C 문자열은 그것을 넘겨받은 셸이 푼다. 그중 어디든 영문자·숫자·`_`·`-` 가 아닌 바이트로 끝나는 npm 설치 동사가 남으면 명령을 기록한다(`inert_bytes_left_unread`). 그 동사는 인식기의 것이다. `npm`, 인식기의 옵션 문법(`SAFEDEPS_G_O`, 값은 비어 있거나 여러 단어일 수 있다. npm 이 `--heading=` 과 `--heading 'a b'` 를 그렇게 읽는다), 그리고 동사다. `npm` 앞에는 아무것도 없어도 된다. 옵션에 명령을 붙여 받는 프로그램이 거기서 읽기 때문이다(`env -S'npm ci x'`, `env -Snpm\ ci\ x`). 셸이 계산하는 단어(`$(...)`, `${...}`, `<(...)`, `>(...)`, 백쿼트) 안에 재작성이 읽지 않은 `npm` 이 있어도, 설치 동사가 있든 없든 명령을 기록한다. bash 의 `hash -p "$(command -v npm)" n && n ci x` 는 어느 바이트도 npm 을 쓰지 않은 문장에서 npm 을 돌린다. npm 이나 그 명령이 설 자리에 셸이 계산하는 단어가 있어도 명령을 기록한다(`inert_dynamic_command_word`). 명령과 그것이 넘기는 스크립트·치환(각각 쓴 그대로 렉싱하고, noredir 뷰에서 그 접두를 제자리에서 공백으로 바꾼 `noprefix` 뷰로 읽는다), 그리고 위의 따옴표 제거가 만든 텍스트의 모든 문장의 명령 단어와(이 텍스트에서는 `<` 를 줄바꿈으로 읽어 셸에 넘기는 here-string·heredoc 본문이 자기 문장을 시작한다. `$(echo npm) ci`, `{npm,ci,x}`, `bash <<< 'npm $V x'`), 명령 단어가 npm 인 문장에서 npm 이 자기 명령으로 읽는 단어다. 그 단어는 옵션이 먼저 오지 않으면 `npm` 바로 뒤 단어이고, 옵션이 먼저 오면 그 뒤의 어느 단어든 된다(`npm $V x`, `npm "$@"`, `npm c? x`). 단어가 계산되는지는 `shell_expands` 의 허용 목록을 단어마다 읽어 정한다(아래). 이 절은 전에 `$` 와 백쿼트를 찾았다. 확장하는 것의 목록이었고, 중괄호·glob·틸드가 그것을 지나갔다. 예약어(`{`, `}`, `!`, `[[`)와 홀로 선 `[` 는 쓴 그대로 읽고, case 패턴은 명령 단어가 아니다. 따옴표 제거로 만든 텍스트는 리더가 렉싱하는 것 중 명령도 payload 도 아닌 유일한 텍스트로, 리더는 뷰의 출력을 렉싱하지 않는다는 규칙의 예외다. 명령과 모든 payload 에서 계산되는 단어를 찾지 못한 뒤에만 읽으므로 거기서 찾은 것은 기록을 더할 뿐이고, scan-contract 의 렉싱 추적은 그 마커를 단 하나의 예외로 이름 붙인다. 어느 쪽이든, 명령의 다른 설치가 플래그를 받았으면 플래그를 아무도 읽지 못한 것으로, 아무것도 받지 않았으면 강등으로 기록된다. 이미 플래그를 가진 설치만 옆에 있을 때도 강등이다. 기록은 전에 텍스트가 셸에 닿는 길을 나열했다. 스크립트 단어, 그다음 `npm` 을 담은 읽지 않은 텍스트, 그다음 읽은 동사를 가린 뒤에도 인식기가 찾는 설치 동사였다. 세 검토 라운드가 매번 그 목록을 지나는 길을 찾았고, 세 번째는 여럿을 찾았다. `-c` 앞뒤의 셸 옵션, here-string, 프로세스 치환, 파일에 써서 돌리는 스크립트, 인자를 실행하는 builtin, 따옴표나 이스케이프가 붙은 명령 단어다. `scripts/measure/inert-record-gen.py` 가 셸 자신의 옵션·builtin·예약어 표와 bash(1)·zsh(1) 의 리다이렉션·확장 절에서 그런 꼴을 만들고, 5b5a775 는 그 1,856꼴 중 806꼴에서 플래그 없는 npm 호출을 기록 없이 내보냈다. 그 꼴들은 npm 문장을 `npm ci x` 로 고정했고, 네 번째 검토는 읽은 동사의 정의가 npm 과 셸의 읽기보다 좁은 곳을 둘 찾았다. 비어 있거나 두 단어인 옵션 값과 `npm` 앞에 붙은 바이트가 동사를 가렸고, 명령 단어 밖에서 셸이 계산하는 단어는 보지 않았다. 그래서 생성기는 npm 문장 자신의 단어도 바꾼다(G5: 옵션 꼴, 계산된 동사, `npm` 앞의 바이트). 길의 목록은 `shell_expands` 가 대신한 확장 목록처럼 거부 목록이다. 그래서 기록은 이제 재작성이 읽은 것만 통과시킨다. 앞으로 찾을 결함은 빠진 길이 아니라 읽은 동사의 정의에 있다. 텍스트 종류를 더하지 말고 그 정의를 고친다. 대가는 소음이다. 설치 옆의 데이터인 설치 텍스트, 곧 `echo`, 커밋 메시지, 파일에 쓰는 heredoc 안의 텍스트도 기록되고(`scripts/measure/inert-record-data.jsonl` 25꼴 중 22꼴), 주석은 기록되지 않는다. 경계는 다른 프로그램이 실행 중에 계산한 텍스트, alias, 그리고 인식기다. 명령이 도는 동안 다른 프로그램이 만드는 텍스트(`printf '\156pm ci' | sh`, `base64 -d | sh`, `rev | sh`)에는 설치를 쓰는 바이트가 없으므로 그것은 effect gate 가 확인할 몫이다. alias 가 npm 에 묶은 이름은 npm 을 쓰지 않은 문장에서 npm 을 돌리고, bash 는 스크립트에서 `shopt -s expand_aliases` 뒤에만 alias 를 쓴다. 인식기가 npm 설치로 부르지 않는 명령은 재작성도 기록도 되지 않는다. `scripts/measure/inert-record-invariant.sh` 가 이 규칙을 출력의 성질로 검사한다. 격자, `scripts/measure/inert-record-forms.json`, 그리고 gen·variant·data 집합의 꼴마다 한 트리의 pre-guard 를 거치고, 실제로 돌 명령을 스텁 npm 과 함께 bash 와 zsh 로 돌린다. 플래그 없는 npm 호출을 하는 꼴은 `advisory.log` 에 inert 기록이 있어야 한다. 실행마다 디렉터리 `d` 를 담은 새 작업 디렉터리를 쓰고, 호스트에 없는 셸은 `/bin/sh` 로 넘기는 스텁이며, stderr 에 "not found" 가 나온 실행은 `vac` 로 나열하고, `scripts/measure/inert-record-reach.tsv` 가 적은 수보다 npm 호출이 적은 꼴은 실행을 실패시킨다. 그래서 npm 에 닿지 않아 통과하는 행이 없다. gen 꼴은 모두 설치 하나와 npm 호출 하나이므로, 두 셸 모두에서 npm 호출이 둘보다 적은 gen 꼴도 `vac` 로 나열한다. 인식기가 npm 설치로 부르지 않는 꼴은 따로 나열하고 통과로 세지 않으며, 계산되는(`cmp`) 꼴도 그렇다. 거꾸로 v2.17.2 는 이번 릴리스가 플래그를 주는 꼴을 놓쳤다. 끝에 붙인 플래그가 셸의 `$0` 이 되던 한 문장 `sh -c` 가 그렇다. 통과하는 자리가 없는 문장은 바닥만 남기고 기록되는 downgrade 다. 전에는 재작성을 통째로 잃었고, 그것은 7d66f8c 보다 적었다. 설치가 그런 텍스트 안에만 있고 그 안의 어느 동사에도 플래그를 넣을 수 없어 읽을 자리가 아예 없으면, 7d66f8c 가 끝에 붙였던 명령은 그래도 7d66f8c 의 재작성, 곧 끝의 플래그를 받는다. 그리고 플래그를 아무도 읽지 못한 downgrade 로 기록된다(`ignore_scripts_unread: true`). `guard_reading_inert` 에서 재작성을 내지 않는 모든 경로가 이것을 묻는다. 전에는 그런 명령에 재작성이 없었고, `npm ci eval "\npm"` 은 프로젝트의 `postinstall` 을 돌렸다. 7d66f8c 의 `npm ci eval "\npm" --ignore-scripts` 는 하나도 돌리지 않았다(npm 11.19.0). 그래서 safedeps 가 넣은 플래그 가운데 몇을 지우면 같은 명령의 7d66f8c 재작성이 된다. 셸이 단어를 어떻게 하든 npm 은 적어도 7d66f8c 가 준 단어를 받는다. `scripts/test/lib/release-floor.sh` 가 smoke 와 lockless 가 보는 모든 재작성에서 이것을 검사하고, 대조는 `scripts/test/inert-release-rewrites.json` 에 적어 둔 7d66f8c 자신의 출력이다. 동사 뒤 플래그 하나만으로는 7d66f8c 의 재작성이 아니다. 한 문장 명령이면 7d66f8c 는 끝에 붙였고, 읽은 자리 뒤의 단어가 `--no-ignore-scripts` 로 바뀌면 남는 것은 그 끝 플래그다(`alias -g --cache=--no-ignore-scripts` 아래 `npm install x --cache` 에서 7d66f8c 의 끝 플래그는 참으로 남고, 동사 뒤 플래그와 `--cache` 앞 플래그는 둘 다 진다). 동사 뒤 플래그가 npm 의 읽기를 바꾸는 자리(`npm install true`)에서 그것을 빼던 예외는 없앴다. `alias -g left-pad@1.3.0='left-pad@1.3.0 --cache'` 아래에서 그 예외는 플래그 하나만 남겼고 별칭의 `--cache` 가 그것을 가져갔다. 7d66f8c 의 동사 뒤 플래그는 거기서 남았다. 설치를 그대로 두는 것은 그 설치 자신의 인자가 옵션을 참으로 남기고 7d66f8c 도 그대로 두었을 때뿐이고, 인자는 문법의 nopt 리더(`safedeps_npm_read_args`)로 읽는다. 7d66f8c 는 따옴표 밖에 `--ignore-scripts` 글자가 있을 때만 명령을 건너뛰었으므로, 따옴표 친 `"--ignore-scripts"` 나 `--no-no-ignore-scripts` 는 7d66f8c 의 재작성을 그대로 받는다. 그래서 다른 옵션의 값인 단어(`--cache --ignore-scripts`)는 세지 않는다. 문장의 단어는 쓴 그대로의 문장을 한 번, 문장 전체를 한꺼번에 렉싱해 읽으므로, 따옴표 안의 줄바꿈·줄 이음·주석을 셸처럼 읽는다. 한 줄씩 읽으면 `--message "a<줄바꿈>--ignore-scripts"` 가 플래그로 읽혔다. 예전 가드는 명령 어디서든 그 글자를 찾았고, `npm install x --ignore-scripts=false` 나 `npm install x && echo --ignore-scripts` 는 아무 기록 없이 설치 스크립트를 돌렸다. 스크립트를 요청한 설치도 비활성으로 만들고, `advisory.log` 가 그렇게 말한다. 동사 앞의 `--` 는 그런 자리를 남기지 않으므로, 그 설치는 끝을 찾지 못한 설치처럼 바닥만 남기고 기록되는 downgrade 다. 셸이 실행 때 정하는 단어가 있는 문장은 그렇게 읽을 수 없다. 그 단어는 ignore-scripts 를 정하는 옵션일 수도, 다음 단어를 받는 옵션일 수도, `--` 일 수도 있다. 그런 단어가 무엇인지는 펼쳐지는 것의 목록이 아니라 허용 목록으로 정한다(`shell_expands`). 따옴표 밖의 모든 바이트가 영문자, 숫자, `._/@:+,=%-`(`SAFEDEPS_SHELL_INERT_BYTES`) 중 하나이고 단어가 `~` 나 `=` 로 시작하지 않을 때만 쓴 그대로 읽는다. 그 밖의 바이트는 어디에 있든 그 단어를 셸이 실행 때 정하는 단어로 만든다. 이 집합은 bash 매뉴얼이 드는 순서의 셸 확장과, zsh 와 dash 가 더하는 것이 건드리지 않고 남기는 바이트다. brace(`{`), tilde(단어 머리의 `~`, zsh 의 이름 디렉터리 `~name`, `a=x:~` 처럼 `=` 나 `:` 뒤의 `~`), zsh 의 `=cmd`(단어 머리의 `=`), parameter·command·arithmetic 치환(`$`, 백쿼트), process substitution(`<(`, `>(`, zsh 의 `=(`), pathname(`*`, `?`, `[`, 명령이 켜면 bash 의 extglob `@(...)`, zsh 의 대안 `(a|b)`·한정자·숫자 범위, extendedglob 이면 `^`·`#`·단어 안의 `~`), history(`!`, `^`)다. 단어 분할은 이것들이 만든 것에만 작용한다. 표는 집합의 근거이고 판정은 집합이다. 그래서 표가 빠뜨린 확장도 그 단어를 동적으로 만든다. 바이트는 그 바이트가 놓인 인용 안에서 읽는다. 집합은 리다이렉션·주석·인용된 글자가 빈칸인 문장의 flat 뷰로, 큰따옴표 안에서도 펼쳐지는 `$` 와 백쿼트는 인용 제거 뒤의 단어로 읽는다. 여기에는 먼저 거부 목록 둘이 있었고, 둘 다 확장 한 종류씩을 놓쳤다. 첫째는 `$`·백쿼트·glob 은 알았지만 틸드는 몰랐다. 그래서 `HOME=--cache; npm install x ~` 는 쓴 그대로 읽혔고, 플래그는 `~` 뒤에만 갔고, 셸은 거기서 npm 에 `--cache` 를 건넸고, 설치는 기록 없이 스크립트를 돌렸다. 그 목록의 `{` 도 한 번도 걸리지 않았다. 리더가 쓰던 pieces 뷰는 단어 안의 묶음 글자를 단어 안 빈칸으로 바꾸므로, `{--cache,}` 는 중괄호 없이 도착했다(7d66f8c 도 같은 구멍이었다). 둘째는 확장 단계를 나열했지만 zsh 의 이름 디렉터리, 대안 glob, bash 의 extglob 을 놓쳤다. 집합의 비용은 아무것도 펼쳐지지 않는 자리의 기록이다. 따옴표 없는 `foo@~1.2.3`·`foo@^1.2.3`, bash 가 npm 에 단어로 건네는 `}` 는 동적으로 읽힌다. 그런 설치는 두 플래그를 그대로 두고 기록되며, 스냅숏 meta 는 플래그가 읽히지 않은 채 들어갔다고 적는다(`ignore_scripts_unread: true`). 그러면 PostToolUse 훅이 하는 말에 한 줄이 더해진다. "safedeps did not read all of the command it wrote as the shell will". 이 줄은 safedeps 가 읽지 못한 것을 말한다. 전에는 "so the install's own scripts may have run" 을 덧붙였는데, 아무것도 확인하지 않은 귀결이었고, `echo` 안의 설치 동사 옆에서는 참도 아니었다. 이 필드는 그 경고를 더할 수만 있다. 이 필드가 없는 기록은 그 밖에 아무것도 주장하지 않는다. 그런 문장에는 플래그를 동사 뒤(뒤의 단어만 되돌릴 수 있다)와 마지막 인자 뒤(앞의 단어만 되돌릴 수 있다) 두 곳에 두고, `advisory.log` 에 플래그를 아무도 읽지 못한 설치로 기록한다. 실행 때 정해지는 단어 하나가 둘 중 한 종류이면 두 플래그 중 하나는 남는다(`npm ci $(printf -- --)` 는 스크립트를 하나도 돌리지 않는다). 실행 때 정해지는 단어 둘, 또는 따옴표 없이 쪼개져 덮어쓰기와 값 옵션이 되는 단어 하나는 둘 다 무력화할 수 있다. 이것이 명령 가드의 실행 시점 단어 경계이고, 조용하지 않고 기록된다. Codex CLI 는 `updatedInput` 기능이 없어 install 이 정상 실행되고, 악성 install script 가 사후 reorg 전에 1회 실행될 수 있다. (패키지의 *런타임* 코드는 두 엔진 모두 네 앱 실행 전에 제거된다; install-time lifecycle script 만 Codex 에서 이 창이 있다.) 플래그는 bash, zsh, dash 가 모두 npm 설치를 같은 자리로 읽을 때만 넣는다. 그렇지 않으면 반쯤 inert 인 명령 대신 `UNDECIDED` 다(위의 읽기 참고).

rebuild 는 게이트가 읽은 트리만 다룬다. `--global=false --location=project --prefix <게이트가 읽은 디렉터리>` 로 돈다. 프로젝트 `.npmrc` 에 `global=true` 가 있을 때 평범한 `npm rebuild` 는 npm 전역 트리를 rebuild 해서, 아무도 검증하지 않은 전역 설치 패키지의 스크립트를 돌렸다. 앞의 두 플래그는 각각 혼자서는 `global=true` 와 `location=global` 중 하나에 졌고, 둘을 함께 줘야 둘 다 버텼다. `--prefix` 가 없으면 npm 은 설치할 때처럼 도는 곳에서 위로 올라간다. 워크스페이스 멤버에서 `npm install x --no-workspaces` 를 돌린 뒤, 게이트는 멤버의 lockfile 을 읽었는데 거기서 돈 `npm rebuild` 는 워크스페이스 루트를 rebuild 했을 것이다.

그리고 `node_modules` 에 `.package-lock.json` 이 없거나, npm 이 rebuild 할 트리에 어느 lockfile 에도 기록되지 않은 패키지나 패키지 버전이 있으면 rebuild 를 경고와 함께 건너뛴다. 그 트리에 무엇이 있는지는 같은 플래그로 npm 에게 묻는다. `npm query '*'` 는 `npm rebuild` 와 같은 방식으로 트리를 읽어 모든 패키지를 위치·이름·버전으로 답하고, 각각을 두 lockfile 이 그 위치에 기록한 것과 대조한다. 이것은 bash 로 `node_modules` 를 걷던 방식을 대신했는데, 그 방식은 두 번 npm 이 rebuild 하는 것보다 적게 걸었다. 하나는 기록된 키를 그 아래 패키지로 여긴 것이다. 프로젝트 `.npmrc` 에 `global=0` 이 있을 때 `npm install x` 는 기록된 1.0.0 위에 1.0.1 을 쓰고 두 lockfile 은 1.0.0 으로 남겼다. 그래서 게이트는 승인된 버전을 읽었고, `npm rebuild` 는 다른 버전의 스크립트를 돌렸다. 다른 하나는 링크에서 멈춘 것이다. `npm rebuild` 는 `file:` 의존성을 따라 그 대상의 `node_modules` 까지 rebuild 하는데, 프로젝트의 어느 lockfile 도 그것을 기록하지 않는다. 그래서 프로젝트의 승인된 설치가 링크된 라이브러리에 기록 없이 놓인 패키지의 스크립트를 돌렸다(검증 2회차, F2). npm 의 질의는 그 패키지를 `../lib/node_modules/x` 로 답하고, 경고가 그것을 지목한다. 링크는 거기서 노드가 아니고, 그 대상이 노드다. 이름은 lockfile 이 이름을 기록했거나 위치가 이름을 함의할 때 대조하며, `npm:` 별칭에 그것이 필요하다. 질의가 실패하거나 10초 안에 답하지 않아도 rebuild 를 건너뛴다. 그때는 트리를 모른다. `npm query` 는 npm 8.16 이상이 필요하고, 그보다 오래된 npm 에서는 모든 rebuild 가 그 경고와 함께 건너뛰어진다. 건너뛴 rebuild 는 경고이지 롤백이 아니다. 기록 밖의 설치는 이미 `UNGATED` 로 기록돼 있고, 이런 설치에 집행을 걸지는 따로 정할 일이다.

**스크립트 실행 허가는 변화분 판정이 아니라 트리 전체 검사에서 나온다.** 스크립트는 예전에 두 곳에서 돌았고, 둘 다 트리 전체에 대해 돌았다. 무실행 설치 뒤의 rebuild 와, 롤백이 돌리던 재설치다. 둘 다 "이번 명령이 들인 것 중 거부된 것이 없다"는 판정으로 허가됐다. 그러자 그 판정의 구멍이 모두 스크립트 실행이 되었고, 세 번 연달아 그랬다. 숨은 lockfile 을 열지 않은 리더, 링크를 버린 리더, 아무도 검증하지 않은 대상으로 간 롤백이다. 롤백은 이제 npm 을 아예 부르지 않는다. 아래 워크스페이스 단락 다음 단락이 그 내용이다. rebuild 에는 위의 기록 검사에 조건 둘을 더해, `npm query` 와 두 lockfile 에서 노드마다 읽는다. `node_modules` 아래 패키지는 그 기록이 전부 공개 registry 의 출처를 적어야 한다. 값의 앞머리를 scheme 과 host 로 읽으며, 출처 검사와 같은 패턴이다. 아니면 그 노드가 들어 있는 부모 패키지가 묶은 것이어야 한다. 묶음 여부는 lockfile 의 `inBundle` 이 아니라 트리에서 읽는다. 커밋된 lockfile 은 그 필드를 마음대로 적을 수 있고, 루트 프로젝트 자신의 `bundleDependencies` 가 이름을 대면 npm 이 숨은 lockfile 에 그 필드를 직접 쓴다. 실측으로 두 경우 모두 승인된 이름과 버전을 단 http URL 의 tarball 이 묶음으로 통과했고 rebuild 가 그 스크립트를 돌렸다(NB1, NB2). 그래서 `<parent>/node_modules/<name>` 의 패키지는 세 조건이 모두 맞을 때만 묶음으로 친다. 부모가 `node_modules` 아래에 있고 이 검사를 스스로 통과한다. 디스크에 있는 부모 자신의 `package.json` 이 `bundleDependencies` 나 `bundledDependencies` 에 그 이름을 적는다(npm 이 읽는 대로, `true` 면 그 이름이 dependencies 에 있을 때). 중첩된 패키지의 어느 기록도 공개 registry 밖의 출처를 적지 않는다. 루트 프로젝트나 워크스페이스 멤버가 묶은 것은 다른 의존성처럼 검사한다. 묶인 패키지 안에 다시 중첩됐는데 그 부모가 이름을 대지 않은 패키지는, npm 은 묶음으로 치지만 여기서는 치지 않는다. 그러면 rebuild 를 경고와 함께 건너뛴다. 안전한 방향이다. `node_modules` 밖 디렉터리는 프로젝트 `package.json` 이 워크스페이스로 선언한 멤버여야 한다. 한 노드라도 통과하지 못하면 rebuild 전체를 건너뛰고, 경고가 노드마다 종류를 붙여 지목한다. 기록 밖, 공개 registry 에서 왔다고 기록되지 않음, 선언된 워크스페이스 멤버가 아닌 디렉터리다. 이것으로 롤백하지는 않는다. 이 검사는 승인된 이름을 다른 tarball 로 보내도록 고친 커밋된 lockfile 을 `npm ci` 나 맨 `npm install` 로 설치한 경우(L1, L2)와, 앞선 `UNGATED` 설치가 링크한 디렉터리(CH1b)에서 rebuild 를 막는다. 세 행 모두 전에는 rebuild 가 스크립트를 돌렸다. 커밋된 `file:` 디렉터리 의존성, tarball 이나 git 출처, 출처를 적지 않는 `omit-lockfile-registry-resolved` 가 있는 프로젝트에서도 rebuild 가 멈춘다. 이런 프로젝트는 설치되지만 rebuild 되지 않는다(`scripts/test/effect-trace-grid.sh` 1d 절: K2-K7, OM1). 워크스페이스 멤버, nested 설치 전략, 공개 패키지에 묶인 의존성은 rebuild 된다(K8, K9, NS1, BD1, BD2). 다른 tarball 로 보낸 중첩 패키지는 커밋된 기록이 `inBundle` 이라 하든 루트가 그 부모를 묶든 설치되고 rebuild 되지 않는다(NB0-NB2n).

**공개 registry 기록은 npm 이 실제로 어디서 받았는지와 대조한다.** 위의 출처 검사는 `resolved` 를 읽는데, `resolved` 는 registry 를 따로 정하지 않았을 때 npm 이 받을 곳을 말할 뿐이다. npm 의 기본값 `replace-registry-host=npmjs` 는 모든 `https://registry.npmjs.org/` URL 을 npm 에 설정된 registry 에서 받고, 기록에는 URL 을 그대로 적는다. 테스트 배터리가 쓰는 로컬 registry 도 바로 이 동작에 기댄다. 그래서 커밋된 `.npmrc` 의 `registry=<아무 곳>` 이나 명령 앞의 `npm_config_registry` 가 승인된 이름과 버전을 다른 tarball 로 보냈다. 두 lockfile 모두 공개 URL 을 적었고, rebuild 는 그 가짜의 스크립트를 돌렸다. 새 프로젝트(RH1), 커밋된 lockfile 에 가짜의 integrity 만 적힌 clone(RH2), 명령의 환경(RH3) 모두에서다. npm 이 어디서 받는지는 npm 의 설정이 정하므로, 설치가 어디에 떨어지는지처럼 npm 에게 묻는다. `npm config ls --json` 은 npm 이 읽는 모든 층의 `registry`, `replace-registry-host`, 모든 `@scope:registry` 를 한 번에 보여 준다. pre-guard 는 이것을 `npm prefix`, `npm root` 와 나란히, 같은 디렉터리에서 그 문장 자신의 인자와 환경으로, 같은 마감 안에서 묻는다(`lib/npm/ask.sh`, fetch facts). 이 답으로 설치를 차단하지는 않는다. 사내 registry, 미러, 프록시가 바로 이렇게 설정되고, 아직 registry 를 승인할 길이 없어 차단하면 그 사용자에게 할 수 있는 일이 남지 않는다. 명령이 직접 적은 `--registry` 는 텍스트 검사가 여전히 차단한다. 답은 pending 상태에 실려 가고, post 훅은 명령 뒤에 자기가 읽은 디렉터리에서 다시 묻는다. 명령이 직접 쓴 `.npmrc` 는 명령 전에는 없고, 롤백의 재설치는 훅의 환경으로 돌기 때문이다. 공개 URL 을 판정하는 모든 검사(rebuild 의 트리 전체 검사, 설치가 새로 들인 출처의 검사)는 이어서 npm 이 그 host 를 바꿨는지를 묻는다. 이것은 npm 의 답에 npm 의 규칙을 적용한 것이다. `replace-registry-host` 가 `always` 이거나 그 host 를 가리키면 host 가 바뀌고, 바이트는 기본 `registry` 에서 온다. 두 답이 모두 바이트가 공개 registry 에서 왔다고 할 때만 그 기록이 공개 registry 를 보증한다. 스코프 패키지에는 그 스코프의 registry 도 판정한다. npm 11.19.0 은 기록된 URL 을 스코프 registry 에서 받지 않지만(pacote 가 tarball 받기에 기본 registry 를 넘긴다), 판정해도 잃는 것은 많아야 rebuild 하나다. 답이 없으면 기본값으로 메우지 않는다. npm 이 없거나 실패하거나 마감을 넘긴 경우, npm 이 출력하지 않는 값(자격 증명이 든 값), 보이지 않게 npm 의 환경을 바꿀 수 있는 앞선 문장(`source`, `.`, `eval`, `set -a`, 저장하는 값을 바꾸는 `declare -xi`, 따로 선 `npm_config_*` 대입, 셸이 실행할 때 값을 정하는 export)은 모두 답을 모름으로 남긴다. pre-guard 가 묻는 환경은 명령이 export 하거나, 따로 선 줄에서 대입하거나, npm 앞에 붙인 모든 이름이다. 값이 글자 그대로면 `npm_config_*` 가 아니어도 싣는다. npm 은 사용자 `.npmrc` 를 `HOME` 에서 읽기 때문이다. npm 설정만 싣던 export 갈래는 `export HOME=<dir>; npm install x` 를 훅의 `HOME` 으로 물었다. 두 질의 모두 공개 registry 를 답했고, rebuild 는 `<dir>/.npmrc` 가 가리키는 registry 가 준 것을 돌렸다(XH1-XH3. `declare -x` 는 답을 모름으로 남겼다, XH4). 명령이 export 하지 않은 대입도 싣는다. `HOME` 은 이미 export 되어 있기 때문이다(XH5). 그 대입이 npm 에 닿지 않는다면 npm 은 훅의 환경으로 돌고, post 훅이 묻는 환경이 바로 그것이므로 어느 쪽이든 두 답 중 하나는 npm 의 답이다. 다만 `source`, `.`, `eval` 만 있을 때 npm 이 다른 registry 를 답했다면 그 답이 그대로 선다(아래). 모름이면 이유를 적은 경고와 함께 rebuild 를 건너뛴다. 롤백은 하지 않는다. 오지 않은 답을 이유로 롤백하면 평범한 설치까지 되돌리게 된다. 공개 밖이라고 알려진 registry 도 차단하지 않은 것과 같은 이유로 롤백하지 않는다. 설치는 그대로 두고 아무것도 rebuild 하지 않는다(RH1-RH3e, RH1w, RH2w, RH8). 경고는 그 때문에 safedeps 가 `npm rebuild` 를 돌리지 않았다고 말하고, registry 를 이름 대며, 에이전트가 직접 `npm rebuild <pkg>` 를 돌리기 전에 사용자에게 확인하라고 말한다. "npm rebuild 를 직접 돌리라"고만 들은 에이전트는 이 검사가 막은 스크립트를 그대로 돌리기 때문이다. Codex 에서는 safedeps 가 `--ignore-scripts` 를 더할 수 없고, 경고는 safedeps 가 그것을 더하지 않았으므로 설치의 스크립트가 이미 돌았을 수 있다고 말한다(RH3x). safedeps 가 플래그를 요청했는데 post 훅이 받은 명령이 safedeps 가 쓴 명령이 아니면, 경고는 그 사실을 대신 말한다(RH3c). 경고는 safedeps 가 한 일을 말하고, npm 이 한 일은 말하지 않는다. registry 승인 경로는 다음 릴리스에 둔다. 로컬 테스트 registry 는 이름으로만 통과한다. `SAFEDEPS_NPM_TEST_REGISTRY` 는 loopback URL 하나만 받고, 그것을 설정한 실행은 매번 옮긴 advisory 출처와 함께 `advisory.log` 에 그 사실을 적는다.

**바이트가 어디서 왔는지는 받을 때 기록하고, 그 뒤에는 찾아본다.** 위 문단은 바이트를 받은 그 명령을 판정한다. 다음 명령에 대해서는 아무것도 말하지 않는다. 다음 명령은 같은 기록을 다른 설정으로 읽거나, 설정 없이 읽는다. 한 번만 쓴 `npm_config_registry` 나 경고 뒤에 지운 `.npmrc` 는 가짜를 공개 URL 아래 디스크에 남겼고, 다음 승인 설치가 그것을 rebuild 했다(P1, P2). `node_modules` 를 지운 뒤의 `npm ci` 도 그랬다. npm 캐시가 integrity 로 같은 바이트를 돌려주기 때문이다(P3). 가짜가 든 채 확정된 스냅샷으로의 롤백도(P4), 같은 머신에서 같은 lockfile 로 다른 프로젝트가 돌린 `npm ci` 도(P5) 그랬다. 같은 종류의 반례가 세 번 연달아 나온 것이다. 묶음 면제는 `inBundle` 을, 출처 검사는 `resolved` 를, 이번에는 rebuild 시점의 설정을 읽었다. 셋 다 "이 바이트는 어디서 왔나"를 바이트에 묶이지 않은 값으로 답했다. npm 이 바이트에 묶는 값은 `integrity` 하나다. npm 은 바이트를 풀 때 이 값으로 검사하고, 캐시도 이 값을 키로 쓴다.

그래서 post 훅은 받는 것을 볼 때 그 사실을 기록한다. 명령 뒤에 두 lockfile 중 어디에든 있고 명령 전 설치 트리에는 없던 integrity 다이제스트를 고른다. 그중 npm 이 공개 registry 에서 받았다고 답하지 않은 것을 `${SAFEDEPS_HOME}/npm-withheld` 에 적는다. 공개 registry 기록인데 npm 이 다른 곳에서 받았다고 했거나 답하지 못한 것(모름, 단 명령이 먼저 돌린 코드 뒤는 아래처럼 뺀다), 공개 registry 밖의 출처, 그리고 출처가 아예 없어 npm 이 설정된 registry 에서 받은 것이다. 기록에는 패키지, 받은 곳, 처음 받은 프로젝트가 들어간다. 두 엔진 모두 reorg 판정 전에 적으므로 롤백이 기록을 지우지 않는다. 실행마다 파일 하나를 임시 이름으로 쓰고 이름을 바꿔 넣는다. 기록은 머신 전역이다. 바이트를 다른 프로젝트로 나르는 캐시가 머신 전역이기 때문이고, 프로젝트별 기록은 P5 를 놓쳤다(변이로 실측). 경로는 `advisory.log` 처럼 `SAFEDEPS_HOME` 에서만 나온다.

"명령 전 설치 트리"는 pre-guard 가 떠 둔 `node_modules/.package-lock.json` 사본이고, 게이트가 관측한 만큼만 그렇다. 사본은 파일이 적은 것을 옮길 뿐이고, 그 파일은 `package-lock.json` 처럼 누구나 커밋할 수 있는 기록이다. 커밋된 `package-lock.json` 을 이미 있던 것으로 치자, 커밋된 `.npmrc` 나 일회성 `npm_config_registry` 를 거친 clone 의 `npm ci` 는 자기 경고가 사칭 registry 를 이름 댔는데도 아무것도 기록하지 않았다. 그 뒤 맨 `npm install`, 승인 설치, 캐시에서 온 `npm ci`, 다른 프로젝트의 `npm ci` 가 각각 사칭 패키지를 rebuild 했다(Q1-Q4). 커밋된 트리 기록은 뒤에 바이트가 하나도 없이 같은 일을 했다. 사칭 integrity 를 적은 `node_modules/.package-lock.json` 하나만 담아 온 clone 에서는 사칭 registry 에서 받은 첫 fetch 가 기록에서 빠졌고, 같은 네 명령이 그것을 rebuild 했다(HL1-HL4). 그래서 post 훅은 프로젝트 디렉터리마다 거기서 마지막으로 판정한 트리 기록의 sha256 을 `${SAFEDEPS_HOME}/npm-observed` 에 남긴다. 경로는 기록과 같은 방식으로 파생한다. 남기는 것은 설치가 명령 중에 쓴 트리 기록이고, 그 안의 integrity 를 모두 판정했고 기록할 것을 모두 썼을 때뿐이다. pre-guard 의 사본은 그 해시와 바이트 단위로 같을 때만 명령 전 트리로 친다. 그러면 그 안의 integrity 는 각각 기록됐거나, 그것을 들인 실행에서 npm 이 공개 registry 에서 받았다고 답했거나, 같은 규칙으로 이미 있던 것이다. 다른 사본은 아무것도 아닌 것으로 친다. 관측한 사본 안에서도 다이제스트를 하나만 적은 항목만 보증한다. npm 은 integrity 가 적은 가장 강한 알고리즘으로 바이트를 검사하고 그 알고리즘의 다이제스트 중 아무것이나 맞으면 받으므로, 사칭 패키지의 sha512 를 공개 것과 나란히 적고 공개 registry 에서 설치한 항목은 사칭 다이제스트에 대해 아무것도 말하지 않는다(DP1). 판정이 다이제스트 단위인 것도 같은 이유다. 사칭 패키지의 sha512 를 트리가 이미 가진 다이제스트와 나란히 적은 커밋 integrity 는 통째로 통과했다(Q5).

비용은 답이 공개 registry 가 아닌 설치가 치른다. 훅이 관측하지 않은 트리에서 그런 설치는 트리가 가진 integrity 를 모두 기록한다. 사내 registry 나 미러라면 그 트리는 대부분 그 registry 가 내준 것이고, 그것은 받을 때 어차피 기록된다. 답을 모르면 공개 패키지까지 들어간다. 새로 clone 한 곳의 `set -a && npm ci` 는 그 트리의 패키지를 모두 이 머신에서 보류한다(UK1a, `declare -xi` 와 `npm_config_*` 대입은 UK1d 와 UK1v). 이 버전 이전에 설치했거나, 훅 밖에서 설치했거나, 마지막 게이트 안 설치 뒤 다른 무언가가 트리 기록을 다시 쓴 트리에서의 첫 그런 설치도 같다(UK0a). 그 뒤로 그 패키지 중 하나라도 담은 트리는 자동으로 rebuild 되지 않고, v2.18.0 에는 그것을 풀 방법이 없다. npm 이 공개 registry 라고 답한 설치는 아무것도 기록하지 않고 트리를 관측된 상태로 남기므로, 그 뒤의 답 모르는 설치는 자기가 들인 것만 기록한다(UK2). 행은 패키지 하나로 잰다. 실제 트리에서는 그 안의 패키지 전부다. npm 이 한 번이라도 공개 registry 에서 받았다고 답한 다이제스트를 모두 빼면 이 비용이 줄지만, npm 이 검사하지 않은 다이제스트는 다시 DP1 의 문제라서 registry 를 승인하는 릴리스로 넘긴다.

**명령이 먼저 돌린 코드 뒤의 설치는 아무것도 기록하지 않는다. npm 이 다른 registry 를 답하면 예외다.** 명령이 npm 에게 쥐여 준 코드도 같다. 위의 코드 이름을 설정하거나 unset 한 것, env 가 npm 을 자기 경로에서 찾게 하는 `env -i`, 훅 자신의 것이 아닌 경로로 적은 npm 이다. 질의는 그 코드를 하나도 돌리지 않으므로 답은 훅의 npm 의 것이지 명령의 npm 의 것이 아니고, `source` 뒤의 답이 명령의 npm 의 것이 아닌 까닭도 같다. 전에는 버전 관리자가 쓰는 꼴인 `export PATH="<dir>:$PATH" && npm ci` 가 원인 없는 모름이어서, 훅이 관측한 적 없는 트리의 모든 패키지를 기록했다(PX1-PX3; 같은 명령에 사칭 registry 를 적은 PX4 는 기록된다). `source ~/.nvm/nvm.sh && npm ci` 는 에이전트가 흔히 치는 명령이고, 위 규칙 아래에서는 트리 전체를 머신에서 보류했다. 거기서 답을 모르는 까닭은 `source`, `.`, `eval` 이 게이트가 읽지 않는 코드를 돌리기 때문이다. 그 코드를 쥔 쪽은 이미 에이전트 셸에서 `curl … | sh` 를 포함해 코드를 돌리므로, 기록은 그 쪽을 막아 주는 것이 없다. 그래서 그것만이 이유이고 게이트가 읽을 수 있는 것에 대해 npm 이 공개 registry 라고 답했을 때, pre-guard 는 모름 답에 `cause: "sourced"` 를 단다. post 훅은 여전히 rebuild 를 건너뛰고 경고가 이유를 말한다. 그다음 pre-guard 의 답을 기록에서 빼고, 트리를 관측된 상태로 남기지 않는다. 그래서 여기서 다음 설치는 트리 전체를 새것으로 친다. post 훅 자신의 답은 그대로 쓰므로, 다른 registry 를 적은 프로젝트 `.npmrc` 는 전처럼 기록된다. npm 이 공개 registry 라고 답하는 다음 설치는 트리를 rebuild 한다(SRC1-SRC3, UK0, UK1). npm 이 공개가 아닌 registry 를 답했다면 그 답은 명령 자신의 단어에서 나왔고, 코드는 그것을 되돌릴 수 없다. 그래서 그 답은 npm 이 준 그대로 서고 다른 답처럼 기록된다(VB1-VB3). 이 면제의 첫 판은 그 답을 sourced 모름으로 바꿔 놓아서, `npm_config_registry=<사칭> npm install x` 앞에 아무 일도 하지 않는 `. /dev/null;` 을 붙이면 아무것도 기록되지 않았고 다음 승인 설치가 사칭 바이트를 rebuild 했다. 게이트가 읽지만 재현할 수 없는 설정은 코드가 아니라 설정이므로, 혼자든 `source` 옆이든 전처럼 기록된다(UK0a, UK1a, UK1d, UK1v, MX1). 자기 글자에 npm 설정을 적은 코드도 그렇다. `eval "export npm_config_registry=…"`, 또는 그것을 말하는 here-string 을 넘긴 `.` 가 그 예다(EV1).

트리 전체 검사는 기록된 integrity 를 지닌 `node_modules` 아래 패키지를 거부하고, 그 바이트를 처음 어디서 받아 어느 프로젝트에 들였는지 말한다. integrity 가 아예 없는 공개 registry 기록도 거부한다. 기록과 맞춰 볼 수가 없기 때문이다. 두 lockfile 의 `integrity` 를 지우자 가짜가 rebuild 됐다(P7). 기록을 읽지 못하면 rebuild 를 건너뛰고 이유를 말한다. 기록은 바이트가 트리를 떠날 때만 풀린다. 공개 registry 에서 다시 설치하면 다른 integrity 의 다른 바이트가 오고, 전처럼 rebuild 된다(P6). v2.18.0 에는 기록을 푸는 명령이 없다. registry 를 확인한 사람이 직접 `npm rebuild` 를 돌린다. registry 승인은 다음 릴리스에 둔다. 기록된 integrity 를 그 이름과 버전의 공개 registry `dist.integrity` 와 비교하는 내용 검사도 함께다. 그때까지는 미러로 한 번 받은 패키지가 어느 프로젝트에서도 자동 rebuild 되지 않는다. 미러는 공개 바이트를 내주기 때문이다. 그 때문에 차단하거나 롤백하는 것은 없다. 기록은 같은 사용자 아래의 로컬 상태라 ledger 와 같은 경계를 가진다. 같은 사용자 공격자는 기록을 지울 수 있다.

rebuild 검사가 읽는 lockfile 필드가 각각 무엇을 보증하고 무엇을 못 하는지:

| 필드 | 보증하는 것 | 보증하지 못하는 것과 그것을 고정한 행 |
| --- | --- | --- |
| `resolved` | registry 를 정하지 않았을 때 npm 이 받을 곳, 그리고 출처의 종류(registry, tarball, git, 디렉터리) | 바이트가 거기서 왔다는 것. npm 은 host 를 설정된 registry 로 바꾼다(RH1-RH3, RH1w, RH2w). 커밋된 URL 을 누가 검사했다는 것(L1, L2) |
| `integrity` | 디스크의 바이트가 npm 이 풀 때 검사한 바이트라는 것. 그래서 보류한 바이트의 기록을 찾는 키다(P1-P5) | 그 바이트가 공개 registry 의 것이라는 것. 커밋된 lockfile 은 이 값을 마음대로 적는다(RH2, RH2w). 그래서 커밋된 integrity 는 바이트를 기록에서 뺄 이유가 아니고(Q1-Q4), 커밋된 트리 기록도(HL1-HL4), 다른 다이제스트 옆에 적힌 다이제스트 하나도 아니다(Q5). 게이트가 판정한 트리 기록 안에서도 다이제스트 둘을 적은 항목은 어느 쪽도 보증하지 않는다(DP1). 값이 없는 기록은 맞춰 볼 수 없으므로 통과하지 않는다(P7) |
| `inBundle` | 게이트가 읽지 않는다. 묶음은 디스크의 부모 `package.json` 에서 읽는다 | 패키지가 부모 안에 들어 왔다는 것. 커밋된 기록이나 루트의 `bundleDependencies` 가 이 값을 정한다(NB1, NB2, NB2i, NB2n) |
| `link` | npm 이 거기에 기록된 대상을 가리키는 심링크를 두었다는 것 | 대상이 프로젝트의 것이라는 것. 아무도 승인하지 않은 `file:` 디렉터리(K4-K7, CH1b, A1-A4). 링크로 기록된 자리에 실제 노드가 있지 않다는 것도 보증하지 않으며, 검사는 그것을 기록 밖으로 보고한다(LK1) |
| `version`(와 `name`) | ledger 와 OSV 가 판정한 것 | 디스크에 있는 것. `.npmrc` 하나로 기록된 1.0.0 위에 1.0.1 이 쓰였다. 검사는 `npm query` 의 버전을 기록과 대조한다(`scripts/test/lockless-forms.sh` 의 `global=0` 행) |

**출처 검사와 설치 스크립트 검사는 설치가 새로 들인 것을 두 기록 모두에서 읽는다.** 두 검사는 예전에 `package-lock.json` 이나 `package.json` 이 바뀔 때만 돌았고, 숨은 lockfile 을 읽는 것은 closure 검사뿐이었다. 아무것도 저장하지 않는 설치는 두 파일 모두 바꾸지 않는다. 그래서 승인된 이름과 버전을 단 tarball 이 `file:` 경로, http URL, 또는 tarball 인자에서 `--no-save` 나 `npm_config_save=false` 와 함께 오면 두 검사를 통과했고, 무실행 rebuild 가 그 스크립트를 돌렸다. 저장했다면 휴리스틱이 걸러 냈을 설치 스크립트를 가진 승인 패키지도 마찬가지였다(검증자 4회차). closure 는 도움이 되지 않았다. closure 는 패키지를 이름과 버전으로 가리키고, rebuild 전제조건도 그렇기 때문이다.

이제 두 검사는 두 기록 중 하나가 담고 있지만 명령 전 어느 기록에도 없던 것을 읽는다(`collect_npm_new_records`, `safedeps_npm_new_records`). pre-guard 는 원래 떠 두던 `package-lock.json` 사본 옆에 `node_modules/.package-lock.json` 사본도 떠 둔다. 임시 이름을 거쳐 복사하고 원본은 건드리지 않는다. 원본의 mtime 과 inode 가 설치 흔적이기 때문이다. 출처는 이전 기록 어디에도 그 resolved URL 이 없을 때 새것이다. 설치된 패키지는 이전 기록 어디에도 같은 키에 같은 버전·resolved URL·integrity 로 없을 때 새것이다. 그래서 승인된 설치 위에 같은 경로로 덮어쓴 tarball 도 새것으로 센다. 새 출처는 비표준·비보안 URL 검사로 간다. 출처는 값이 `https://registry.npmjs.org/` 나 `https://registry.yarnpkg.com/` 으로 시작할 때만 공개 registry 다. 부분 문자열 검사는 `file:registry.npmjs.org/x.tgz` 를 registry 로 통과시켰다. 새 패키지의 `package.json` 은 설치 스크립트 휴리스틱으로 간다. 이 파일들은 `jq` 한 번으로 읽는다. 50개 기준 개수 검사는 `package-lock.json` 에만 남는다. 이전 기록이 없으면 의존성이 50개를 넘는 프로젝트의 첫 설치가 모두 그 기준을 넘기 때문이다.

이전 기록 둘은 차례로가 아니라 함께 읽는다. 트리 기록을 먼저 대조하면 `package-lock.json` 이 다른 플랫폼용으로 적어 둔 선택 패키지를 설치할 때마다 다시 들이는 것으로 읽힌다. 그리고 동료에게서 pull 한 lockfile 의 새 출처가 다음 `npm ci` 에서 새것으로 읽히는데, 이는 아래의 커밋된 lockfile 경우다. 링크도 읽는다. npm 은 디렉터리 의존성을 링크와 그 대상(`node_modules/x {resolved: "../x", link: true}` 와 `../x`)으로 기록하고, 저장 여부와 상관없이 두 기록 모두에 남긴다. 그리고 `npm rebuild` 는 링크를 거쳐 대상의 설치 스크립트를 돌린다. 그래서 설치가 새로 들인 링크는 공개 registry 밖의 새 출처이고, 그 대상은 설치 스크립트 휴리스틱으로 간다. 링크를 빼면 `npm install ../dir` 이 통과하고 rebuild 가 그 디렉터리의 스크립트를 돌렸다(검증 5회차). 예외는 워크스페이스 멤버 하나다. 프로젝트의 `package.json` 이 워크스페이스로 선언한, 프로젝트 안의 디렉터리는 프로젝트의 일부이고, rebuild 는 `npm install` 처럼 그 스크립트를 돌린다. 패턴이 게이트가 읽지 않는 글롭(부정 패턴 같은)을 쓰면 어떤 디렉터리도 멤버로 치지 않는다. 그런 프로젝트에 새로 더한 멤버는 롤백되고, `advisory.log` 가 이유를 적는다. 프로젝트 자신의 항목도 같은 이유로 뺀다. lockfile 도 설치된 트리도 없는 프로젝트에는 이전 기록이 없으므로, 첫 설치가 들인 것은 전부 새것이다. 그래서 공개 registry 밖의 출처는 그 첫 설치에서 롤백된다. lockfile 이 있는 프로젝트에 같은 의존성을 더할 때는 원래 그랬고, 전에 거기서 통과한 것은 비교할 스냅샷이 없었기 때문일 뿐이다. 롤백은 그런 출처를 기록 이름과 resolved URL 로 적는다.

워크스페이스에서는 루트 lockfile 이 각 멤버를 경로(`packages/a`)로 기록한다. 폐쇄성은 `node_modules` 밖의 키를 모두 건너뛴다. 그 키들은 패키지 이름이 아니라 프로젝트의 디렉터리이기 때문이다. 패키지 이름으로 읽으면 `packages/a` 가 미승인 패키지 `packages` 가 됐다. 그리고 멤버에 설치하면 멤버의 `package.json` 이 바뀌므로, 스냅샷은 모든 멤버의 manifest 를 보관한다. 그게 없을 때 `npm install x -w packages/a` 의 롤백은 루트 lockfile 을 복원했고, `npm ci` 가 멤버의 새 의존성 때문에 거부했으며, 대체 재설치가 `x` 를 다시 놓았다.

스냅샷은 설치가 쓸 것 같은 멤버가 아니라 모든 멤버를 보관한다. `npm install` 이 어느 멤버를 쓰는지는 npm 이 정할 일이고, 그것을 추측하면 npm 규칙을 bash 로 옮긴 사본이 하나 더 생긴다. 그 비용을 감당하게 하는 것은 프로세스 수다. 모든 manifest 가 `tar` 복사 한 번으로 `<snapshot id>_members/` 에 들어가고 `shasum` 한 번으로 해시된다. 그래서 훅은 멤버 10개에서도 1000개에서도 같은 프로세스를 띄운다. `scripts/test/workspace-snapshot-count.sh` 가 `PATH` 의 모든 명령에 심을 끼워 그 수를 센다. 시간과 달리 이 수는 부하에 흔들리지 않는다. 멤버마다 `cp` 와 `shasum` 을 하나씩 돌리던 때는 멤버 1000개 워크스페이스의 판정에 20-33초가 걸렸다. 런타임의 30초 kill 을 넘는 시간이고, 그러면 명령이 판정 없이 실행된다. 한 머신(macOS arm64, npm 11.19.0)에서 `scripts/measure/npm-ask-cost.sh` 로 잰 pre-guard 전체 시간은 바꾸기 전 멤버 100·300·1000개에서 2.7초·5.5초·19.5초(부하 18-21), 바꾼 뒤 중앙값 0.9초·1.0초·1.7초(부하 22-31)였다. 다른 곳에 인용하기 전에 다시 재야 한다. 복사가 실패하면 되돌릴 방법 없이 설치를 돌리지 않고, 판정 불가로 거부한다.

**롤백은 패키지 매니저를 부르지 않는다.** 스냅샷으로 뜬 파일을 복원하고, 프로젝트 자신의 `node_modules` 가 실제 디렉터리면 지운다. 재설치는 다음 설치가 하고, 그 설치는 다른 설치처럼 게이트를 지난다. 대상이 심볼릭 링크면 거부하고 이름을 남기며(`reorg.log` 의 `REORG REFUSED`) 따라가지 않는다. 롤백은 나머지 단계를 계속한다. 롤백은 예전에 재설치를 했고, 그 재설치는 방식마다 아무도 확인하지 않은 곳으로 갔다. 프로젝트 `.npmrc` 에 `global=true` 가 있을 때 평범한 재설치는 프로젝트 자체를 전역 prefix 에 설치하고 프로젝트의 `node_modules` 를 빈 채로 남겼다. 설치할 lockfile 이 없거나 `npm ci` 가 실패하면 `package.json` 을 다시 해석했다. 재 보니 `^1.0.0` 범위가 승인 뒤에 게시된 1.0.1 로 풀렸고, 재설치가 그 스크립트를 돌렸다. 확정 스냅샷이 없는 프로젝트는 명령 직전에 뜬 스냅샷으로 롤백되고, 그것은 아무도 검증하지 않았다. 재 보니 커밋된 lockfile 에 미승인 패키지가 있는 새 clone 은 바로 그 lockfile 로 롤백되었고, `npm ci` 가 그 패키지의 스크립트를 돌렸다(RB1). 승인 설치 전부터 lockfile 에 그 패키지가 있던 경우(RB2)와 앞선 `UNGATED` 설치가 넣은 경우(CH2b)도 같았다. 플래그와 `--ignore-scripts` 가 여기까지는 닫았다. 그 뒤 리뷰가 어떤 플래그로도 덮이지 않는 길을 찾았다. `npm ci` 는 링크된 `node_modules` 가 가리키는 곳을 비우고, `package.json` 이 없는 곳에서 npm 은 상위 프로젝트로 올라가고, 대체 설치는 링크 너머로 lockfile 을 저장하고, `npm ci` 는 프로젝트 밖에 있는 워크스페이스를 비우고, `file:` 의존성의 bin 링크는 그 의존성의 디렉터리에서 다시 쓰인다. 세 라운드가 매번 새 길을 찾았고, 그래서 롤백은 npm 에게 손이 어디로 가는지 묻기를 그만뒀다. 롤백 뒤 메시지는 어떤 경로를 복원하고 지웠는지, 그 뒤 `package.json`·`package-lock.json`·`npm-shrinkwrap.json` 을 검사한 결과가 무엇인지를 말한다. 재설치 명령은 주지 않는다. 재설치가 어디에 쓸지는 npm 이 정하기 때문이다. 확정 스냅샷 없는 롤백 뒤에는 메시지와 `reorg.log`, `advisory.log` 가 그 스냅샷이 이 명령 전에 뜬 것이고 어떤 확정 스냅샷도 그것을 가리키지 않는다고 말한다. 롤백 전에 무엇이 돌았는지는 엔진마다 다르고, 기록은 훅이 본 것을 말한다. Claude Code 에서는 "safedeps added --ignore-scripts to this install" 이다. Codex 에서는 "safedeps did not add --ignore-scripts to this install; the command this hook received does not carry it" 이다(RB1x).

**롤백이 하는 말은 닫힌 한 벌의 줄이다.** 롤백 메시지, 거부된 단계, 무실행 설치 뒤에 건너뛴 rebuild, 끝나지 않은 롤백의 보고는 `lib/gates/report-facts.sh` 의 함수로 만든다. 함수마다 불릴 때 자기 검사를 돌리고 그 결과를 찍으므로, 검사 없이 있는 줄이 없다.

| 형식 | 그 뒤의 검사 |
|---|---|
| `Rollback snapshot: <id>, a confirmed snapshot` | 프로젝트의 확정 기록이 `<id>` 를 가리킨다 |
| `Rollback snapshot: <id>, taken before this command; no confirmed snapshot names it` | `<id>` 는 pre-guard 가 이 명령 전에 뜬 스냅샷이고, 확정 기록은 그것을 가리키지 않는다 |
| `restored <path>` / `not restored <path>: cp exit <n>; <path> differs from the snapshot` / `...; <path> does not exist` | `cp` 뒤에 스냅샷과 바이트 비교 |
| `not restored <path>: <path> exists and is not a regular file` | `cp` 전의 경로 검사. 디렉터리에 `cp` 하면 그 안에 파일을 쓰고 0 으로 끝난다 |
| `removed <path>` / `not removed <path>: rm exit <n>; <path> exists` | `rm` 뒤에 경로 검사 |
| `refused restore of <path>: <fact>` / `refused removal of <path>: <fact>` | 경로가 심볼릭 링크이고 링크가 가리키는 물리 경로를 적는다. 또는 프로젝트 디렉터리가 풀리지 않는다 |
| `<path> exists` / `<path> does not exist` / `<path> is a symbolic link to <physical path>` | 경로 검사 |
| `<dir>/package.json has the key workspaces` | 그 파일에 대한 `jq` |
| `kept <path>` 와 그 아래 줄 | 설치 흔적 없음, 롤백이 시작될 때 명령 전 스냅샷과 다른 node manifest·lockfile 없음, 명령 전 목록에 없는 `node_modules`·`.bin` 항목 없음, 명령 전 스냅샷보다 새로운 것 없음. 검사 하나가 줄 하나다. 링크인 `node_modules` 는 pre-guard 와 여기서 모두 링크를 따라가 목록을 만들고(`find -H`), 남긴 링크는 `kept` 바로 다음 줄에서 링크라고 말한다 |
| 이유 줄 하나, 그 다음 `removed <path>/node_modules` | 같은 검사 가운데 쓰기를 처음 보인 것 하나를 한 줄로: 설치 흔적이 있는 lockfile, 달랐던 node 파일, 목록에 없는 패키지나 `.bin` 항목, 스냅샷보다 새로운 경로, 또는 명령 전 스냅샷이 없음 |
| `The rollback changed nothing.` | 어떤 단계도 `cp` 나 `rm` 을 돌리지 않았다. 실패한 `rm -rf` 는 지울 수 있는 것을 지우고, 실패한 `cp` 는 파일을 비울 수 있다 |
| `no install trace in <dir>: ...` | lockfile 을 기준 파일과 비교했거나, 기준 파일이 없다 |
| `safedeps added --ignore-scripts to this install` / `safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote` / `safedeps did not add --ignore-scripts to this install` | pre-guard 가 명령을 고쳐 썼다는 기록과 그 쓴 명령(스냅샷 meta 의 `updated_command`)을, post 훅 입력의 명령과 비교한 결과. 명령에서 플래그를 읽지 않는다. post 훅이 기록을 찾지 못한 호출에는 `--ignore-scripts` 줄이 없다. backstop 은 기록을 찾지 못해서 돌고, 머리말에 그렇게 말하며(`this hook found no record of this command from before it ran`), safedeps 가 한 일을 말하지 않는다. 기록을 쓰지 못한 pre-guard 는 고쳐 쓴 명령을 내보내지 않고 그 사실을 `advisory.log` 에 남긴다. 기록을 읽지 못한 post 훅도 `--ignore-scripts` 줄을 말하지 않고 그 사실을 `advisory.log` 에 남긴다. 예전에는 읽기에 실패하면 `did not add` 로 떨어졌다. 줄은 기록이 밝힌 사실로만 내고, 사실을 밝히는 것은 버전 2 기록(`"record": 2`, v2.18.0 부터 씀)뿐이다. `did not add` 는 `ignore_scripts_injected` 가 JSON false 여야 하고, `added` 나 `asked` 는 그것이 true 이고 `updated_command` 가 문자열이어야 한다. 다른 모양은 줄을 내지 않는다. 기록 파일 없음, 다른 버전이나 버전 없는 기록(v2.17.2 의 false 는 고쳐 쓰지 않았다는 뜻이 아니었다. 기록 쓰기가 실패해도 고쳐 쓴 명령이 나갔다. 그 true 에는 명령이 없다), 문자열 `"true"`, null 명령이 그렇다. 그때 advisory.log 는 그 기록이 safedeps 가 명령을 고쳐 썼는지 밝히지 않는다고 적는다. 줄을 내는 분기는 기본값으로 닿지 않는다 |
| `... did not run npm rebuild: <fact>` / `... ran npm rebuild: exit <n>` | 링크인 루트 npm 파일, 없는 흔적, 또는 rebuild 의 종료 코드 |
| 끝나지 않은 롤백 보고의 `Rollback snapshot: <id>, a confirmed snapshot` / `Rollback snapshot: <id>; no confirmed snapshot names it` | 보고를 쓰는 시점의 프로젝트 확정 기록 |
| `Journal:`, `Owner:`, `<path> differs from the snapshot <id>` 와 끝나지 않은 롤백 보고의 나머지 줄 | 저널 항목, 소유 프로세스에 답한 검사, 감시 대상 파일과 스냅샷의 비교. 같은 파일은 줄이 아니다 |
| `Details log: <path>` / `Incident record: <path>` / `Rollback log: <path>` | 파일이 있다. 없으면 줄이 `is not a file` 로 끝난다 |

이 검사들의 pre-guard 기록, 이 명령 전에 뜬 스냅샷, 설치 흔적의 기준선은 post 훅이 쓴 pending 상태의 것이고, 그 상태는 이 호출 자신의 것이다. pre-guard 는 그것을 `pending/id-<tool_use_id>.json` 으로 두고, `tool_use_id` 를 적은 호출의 post 훅은 그 파일만 읽는다(두 훅의 id 읽기는 `lib/gates/call-id.sh` 하나다). v2.18.1 전에는 `--ignore-scripts` 와 공백을 뺀 디렉터리와 명령으로 찾았다. 그래서 같은 디렉터리에서 겹친 같은 명령의 두 호출은 서로의 기록으로 말했고(밤토리 r19 X1), post 훅이 돌지 않은 호출은 그 명령의 다음 호출이 소비하는 기록을 남겼다. 확정 스냅숏이 없으면 롤백은 그 앞선 호출의 스냅숏으로 되돌렸고, 두 호출 사이에 고친 내용이 사라졌다(O2). `tool_use_id` 를 적지 않은 훅 입력은 지금도 그 키로 맞추고, 두 훅이 `advisory.log` 에 그 사실을 적는다. Claude Code 는 도구 호출이 성공한 뒤에만 PostToolUse 를 부르고, 실행된 뒤 실패한 Bash 호출에는 같은 `tool_use_id` 와 `tool_response` 대신 `error` 를 담아 PostToolUseFailure 를 부른다(https://code.claude.com/docs/en/hooks, 2026-10-04 확인). 설치기는 post 훅을 둘 다에 등록하므로, 실패한 설치도 판정되고 그 기록이 쓰인다. post 훅은 `tool_response` 도 `error` 도 읽지 않는다. Codex 는 실패한 Bash 호출에도 PostToolUse 를 부르고 PostToolUseFailure 는 문서에 없으므로(https://learn.chatgpt.com/docs/hooks), Codex 설정에는 PostToolUse 만 들어간다. pre-guard 가 통과시킨 뒤 거부된 호출과 실행 중에 취소된 호출은 여전히 post 훅이 돌지 않는다. 그 기록은 24시간 청소를 기다리고, 다른 호출은 읽지 않는다. pre-#5 pre-guard 가 기기에 하나 두던 기록(`current_state`, `current_snapshot_id`)은 어느 호출도 가리키지 않으므로 읽지 않는다. 맞지 않는 호출에서는 "SKIP ... bounded no-op" 을 남기고 판정 없이 훅을 끝냈다. 기록이 스냅숏보다 오래 남을 수도 있다. pending 상태는 24시간 가고, 스냅숏 정리는 최신 열 개를 넘는 meta 를 지운다. 기록이 가리키는 스냅숏에 meta 파일이 없는 호출은 backstop 으로 간다. `advisory.log` 가 그 기록을 적고, backstop 머리말은 기록을 찾았으나 그 스냅숏에 meta 파일이 없다고 말한다. 기록이 스냅숏을 아예 가리키지 않는 호출, 즉 손상된 pending 상태도 같은 길로 backstop 에 가고, 머리말은 기록이 스냅숏을 가리키지 않는다고 말한다. v2.18.0 전에는 post 훅이 두 곳 모두에서 아무 말 없이 끝났고, 설치는 판정되지 않았다(밤토리 r23, 첫 커밋부터 있었다). JSON 객체 하나가 아닌 기록도 backstop 으로 가고, 머리말이 그렇다고 말한다. 그 필드를 `set -e` 아래에서 jq 로 읽었으므로 그런 기록은 훅을 끝냈고, 그 자리에 남은 기록은 24시간 동안 그 명령을 부를 때마다 훅을 다시 끝냈다. `project_dir` 가 없는 기록은 페이로드의 `cwd` 에서 판정한다. 전에는 훅 자신의 작업 디렉터리를 썼으므로, 게이트는 명령이 돌지 않은 디렉터리를 판정했고 그곳을 롤백할 수 있었다. 확정 스냅숏은 기록의 `dir_hash` 가 아니라 post 훅이 판정하는 프로젝트에서 계산한 해시로 찾는다. 그래서 프로젝트와 해시는 늘 한 디렉터리를 가리킨다. pre-guard 는 둘을 한 디렉터리에서 쓰므로 건전한 기록의 판정은 그대로다. 프로젝트 X 와 프로젝트 Z 의 해시를 적은 손상된 기록은 Z 의 확정 스냅숏을 X 에 복원했다(밤토리 J, 실측: X 의 `package.json` 이 Z 의 것이 됐다).

줄은 경로 안에 무엇이 있는지, 왜 그렇게 됐는지, npm 이 무엇을 할지, 다음에 무엇을 하라는지를 말하지 않는다. 이 보고는 거짓 문장으로 세 번 반려됐고, 세 번 모두 참인 사실 뒤에 붙은 절이 거짓이었다. `rm -rf` 가 도중에 실패한 뒤 "node_modules is still there, with whatever this install wrote in it" 은 `rm` 이 거의 비운 디렉터리를 두고 한 말이었다. "The verified packages' install scripts have not run" 은 명령 자신의 `npm rebuild` 가 스크립트를 돌린 뒤에 나왔다. "Most likely the hook hit the runtime's timeout" 은 읽기 전용 lockfile 때문에 `cp` 가 실패한 뒤에 나왔고, 그 `cp` 는 `set -e` 아래에서 롤백 도중에 훅을 끝냈다. 마지막 것은 롤백 자체의 결함이기도 했다. 이제 실패한 복원은 한 줄이 되고 롤백은 계속 간다. 문장을 읽는 것으로는 수렴하지 않았다. 문장 전수를 세 번 읽은 뒤에도 거짓 절 여섯을 더 쟀고, 그런 절을 넣은 변이 둘이 스위트 전체를 통과했다. 검사가 금지어 목록이었기 때문이다.

그래서 검사는 출력에 건다. `scripts/test/e2e.sh` 는 post 훅이 찍은 모든 줄을 `scripts/test/lib/report-oracle.sh` 에 넘긴다. 어느 줄을 읽을지 행이 고르지 않는다. 틀 줄은 통째로 일치해야 한다. 나머지 줄은 앵커를 건 형식 하나에 맞아야 하고, 그 형식의 주장은 훅의 코드가 아닌 코드로 디스크에서 다시 검사한다. 설치 흔적과 소유 프로세스의 상태는 훅이 돌기 전에 적어 둔다. 어느 형식에도 맞지 않는 줄은 실행을 실패시킨다. 끝의 형식 표는 형식마다 줄 수를 세고, 한 번도 나오지 않은 형식이 있으면 실패한다. 그래서 값이 둘인 사실은 형식 둘이고 둘 다 행이 있다. reorg.log 항목도 같은 문법으로 읽는다. 오라클은 메시지의 줄이 요구하는 항목을, 즉 종류마다의 틀과 메시지 자신의 줄을 순서대로 만들고, 훅이 덧붙인 항목은 정확히 그것이어야 한다. 로그에만 있는 줄이나 거부, 두 기록이 다르게 적은 사유는 빨강이다. advisory.log 는 롤백 줄 둘과, 호출에 `--ignore-scripts` 줄이 없는 까닭을 말하는 줄 둘(기록을 읽지 못함, 기록이 사실을 밝히지 않음)만 읽는다. 롤백 줄은 각각 메시지의 줄을 되풀이해야 한다. 나머지는 운영 로그라 검사하지 않는다. 오라클은 롤백 주변의 디스크도 읽는다. 훅 전에 프로젝트 최상위 항목 목록을 떠 두고, 롤백 뒤에 바뀐 항목은 모두 단계 줄이 이름을 대야 한다. "The rollback changed nothing." 은 바뀌지 않은 목록이 필요하다. `kept` 는 훅 전 검사가 모두 쓰기를 보이지 않아야 하고, 앞에 사유 줄이 없어야 하며, 바로 뒤에 검사 줄이 순서대로 와야 한다. 메시지를 내지 않은 호출은 reorg.log 에 아무것도 덧붙이지 않아야 한다. post 훅이 이 로그에 쓰는 곳은 넷(롤백, 거부된 단계, confirm 경고, 중단된 롤백의 보고)이고, 넷 모두 메시지를 낸다. `node_modules` 의 package.json 목록은 훅과 다른 방법인 Python 의 디렉터리 순회로 읽는다(`scripts/test/lib/report-oracle-read.py`). 훅과 오라클이 같은 틀린 검사를 하고 일치한 일이 있었기 때문이다(밤토리 r16, F1).

둘 다 줄을 위해 셸 명령을 읽지 않는다. 명령이 `--ignore-scripts` 를 다는지는 예전에 둘 다 읽었다. 훅은 설치 문법으로, 오라클은 Python 의 `shlex` 와 `npm config get ignore-scripts <words>` 로 읽었다. 두 번째 판독기는 검사를 독립시키지 못했다. 둘은 셸 문장의 모델 하나를 같이 썼고, 세 라운드가 같은 명령에서 둘 다 틀린 것을 찾았다. 부분 문자열(F2), 그다음 `npm_config_ignore_scripts` 의 대입이나 export 와 프로젝트 `.npmrc` 다(F3). 그래서 이제 줄은 safedeps 가 한 일만 말한다. pre-guard 는 플래그를 넣을 때 자기가 쓴 명령을 기록하고, 훅은 받은 명령이 바이트 하나 다르지 않게 그 명령일 때만 "added" 라고 말하며, 오라클은 같은 주장을 두 문자열을 `cmp` 로 비교해 검사한다. 두 문자열은 훅의 `jq` 가 아니라 Python 으로 읽는다.

어느 기록이 이 명령의 것인가는 훅과 오라클이 둘 다 읽는 사실이고, 밤토리 r18(F4)까지 둘은 같은 방법으로 읽었다. pre-guard 는 `sh -c 'npm ci'` 를 `sh -c 'npm ci --ignore-scripts'` 로 고쳐 썼고, post 훅이 그 명령으로 계산한 키는 pre-guard 의 키와 달랐다. backstop 은 롤백하고, safedeps 가 쓴 명령에 "did not add" 라고 말했다. 오라클도 같은 키로 기록을 찾았고, 찾지 못했고, 동의했다. 이제 backstop 은 `--ignore-scripts` 줄을 말하지 않고, 오라클은 다른 방법으로 기록을 읽는다. 아직 어느 호출도 쓰지 않은 기록, 즉 훅이 돌기 전에 있던 pending 상태의 기록이 safedeps 가 훅이 받은 명령을 그대로 썼다고 말하면 "did not add" 는 빨강이다. 모든 기록은 너무 넓다. 전부 훑었더니 플래그를 스스로 단 e2e 의 Codex 행이 빨강이 됐다. 앞선 Claude 고쳐 쓰기가 같은 바이트를 썼기 때문이다. 그래서 이 호출의 기록만 훑는다. 기록은 그것을 쓴 호출의 `tool_use_id` 를 담고, 오라클은 훅 입력에서 이 호출의 id 를 Python 으로 읽는다(`report-oracle-read.py` 의 `call`). 그 id 를 담은 기록, 또는 id 를 적지 않은 호출이라면 id 를 담지 않은 기록이 이 호출의 것이다. 훅이 소비한 기록도 이 호출의 것이어야 하고, 아니면 빨강이다. v2.18.1 전에는 기록에 호출을 가리키는 것이 없었고, post 훅은 디렉터리와 명령으로 기록을 찾았다. 그래서 같은 명령의 두 호출이 같은 디렉터리에서 겹치면 서로의 기록으로 말했고(밤토리 r19, X1: Codex 호출이 Claude 의 고쳐 쓰기를 두고 "added" 라고 했고, Claude 호출은 "did not add" 라고 했다), 오라클은 각 호출이 가져간 기록을 읽고 둘 다에 동의했다. e2e 의 OV1 행이 그 두 호출을 돌린다. B 의 post 훅이 먼저 돌고, 키로 찾으면 A 의 기록이 먼저 나오게 해 두며, 각 post 훅은 자기 기록으로 말한다. OV2 는 자기 기록이 없는 호출이 다른 호출의 기록을 가져가지 않음을, O2 는 post 훅이 돌지 않은 호출의 기록으로 판정되지 않음을, MM 은 흔적 항목을 지닌 호출이 어떤 기록도 읽지 않음을 붙잡는다. backstop 메시지에 `--ignore-scripts` 줄이 있으면 빨강이다. 기록은 쓰일 때도 검사한다. e2e 는 pre-guard 를 `pre_hook` 으로 돌리고, 오라클은 pre-guard 자신의 출력에서 고쳐 쓴 명령을 읽는다. 그 호출이 쓴 기록은 그 명령을 바이트 그대로 담아야 하고, 고쳐 쓴 명령을 내지 않은 호출은 고쳐 썼다는 기록을 쓰지 않아야 한다. 호출 전에 이미 있던 기록을 쓴 것도 빨강이다. 한 프로젝트에서 1초 안에 돈 두 호출은 스냅숏 id `<초>_<디렉터리 해시>` 를 같이 썼다. 그래서 둘째 호출이 첫째의 기록과 lockfile 사본 위에 자기 것을 썼고, 첫째 호출의 post 훅은 둘째의 기록으로 말했다(밤토리 r19, SAME). 훅과 오라클은 덮어쓴 같은 기록을 읽고 동의했다. 이제 호출마다 자기 id 를 잡는다. pid 를 붙이고 첫 파일을 배타적으로 만들므로, 그 1초 안에 다시 쓰인 pid 는 다른 이름을 얻는다. 기록을 쓰지 못한 고쳐 쓰기는 예전에는 그대로 나갔다. 이제 pre-guard 는 그것을 내보내지 않으므로, 거기서도 "did not add" 가 참이다. post 훅이 읽지 못한 기록도 예전에는 "did not add" 로 말했다. 이제 그 호출에는 `--ignore-scripts` 줄이 없고, 오라클은 읽기 실패를 훅이 아니라 그 실패를 만든 행에게서 안다. 그런 호출에 `--ignore-scripts` 줄이 있으면 빨강이고, advisory.log 에 기록을 읽지 못했다고 한 번 말하지 않아도 빨강이다. 읽기가 실패하지 않은 호출이 그렇게 말하면 빨강이다. 그 뒤로도 네 라운드 연속, 줄에 필요한 사실이 없는 기록을 빠진 필드로 답한 경우가 나왔다(기록을 못 찾음, 읽기 실패, 객체 하나가 아닌 파일, `updated_command` 가 없는 v2.17.2 기록을 "asked" 로 말함, 밤토리 r22 U3). 그래서 이제 줄은 자기 사실이 버전 2 기록에 밝혀져 있어야 한다(위 형식 표의 행). 오라클은 이 규칙을 훅의 `jq` 프로그램이 아니라 Python 으로 파싱한 기록에서 읽는다(`report-oracle-read.py` 의 `said`). 기록이 자기 사실을 밝히지 않은 줄은 빨강이다. 줄이 있어야 할 메시지에 줄이 없으면, 기록이 두 사실 중 어느 것도 밝히지 않거나 읽을 수 없고 advisory.log 가 그중 무엇인지 한 번 말할 때만 빨강이 아니다. e2e 는 pre-guard 가 쓴 기록을 사실을 밝히지 않는 모양마다(v2.17.2 의 true 와 false, 문자열 `"true"`, null 이나 숫자인 명령, 버전 3, 문자열 `"2"` 인 버전) 그리고 객체 둘로 고쳐 쓰고, 모두 줄이 없다. 기록 파일 없음은 사실 함수를 직접 부르는 행이다. post 훅은 시작할 때 meta 가 없는 기록을 backstop 으로 보내고 backstop 은 `--ignore-scripts` 줄을 말하지 않으므로, 보고 전에 사라진 기록만 거기에 닿는다. backstop 의 세 머리말은 자기가 말하는 기록에 묶인다. 훅이 기록을 소비했는데 "found no record" 라고 하면 빨강이다. "found a pre-guard record, and the snapshot it names has no meta file" 은 훅이 소비한 기록의 meta 가 Python 으로 봐서 파일이 아닐 때만 빨강이 아니다. "found a pre-guard record, and the record names no snapshot" 은 훅이 소비한 기록의 스냅숏 id 가 Python 으로 읽어 비었거나, 없거나, 문자열이 아닐 때만 빨강이 아니다. 훅도 기록의 필드를 문자열일 때만 읽으므로, 스냅숏 id 5 는 둘 모두에게 스냅숏을 가리키지 않는 기록이다(행 G. 전에는 훅이 "5" 로 읽었다). "found a pre-guard record, and the record is not one JSON object" 은 훅이 소비한 기록을 Python 이 JSON 객체 하나로 읽지 못할 때만 빨강이 아니다. 그런 호출은 메시지가 있든 없든 advisory.log 에 그 기록을 꼭 한 번 적는다(e2e 의 행 A 부터 D, U1 부터 U3, G). 행 E 는 pre-#5 pre-guard 가 남긴 기록을 읽지 않음을 붙잡는다. 오라클은 호출 전에 그런 파일을 적어 두고, 훅이 그것을 소비하면 빨강이다. 롤백의 단계 줄은 그 호출이 판정한 프로젝트 밖을 가리키면 빨강이다. `project_dir` 가 없는 기록에서 그 프로젝트는 페이로드의 `cwd` 다(행 F 와 F2. 훅은 다른 프로젝트에서 시작한다). 오라클은 그 프로젝트의 해시를 Python 의 md5 로 직접 계산하고 기록의 `dir_hash` 는 읽지 않는다. 전에는 읽었고, 다른 프로젝트의 해시를 적은 기록에서 훅과 같은 답을 냈다(행 J). Claude Code 2.1.288 에서 재 보니 PostToolUse 훅은 `updatedInput` 의 명령을 바이트 그대로 받았다. 따옴표, 탭, 비 ASCII 바이트도 그대로였다. 그래서 safedeps 가 고쳐 쓰는 경로의 줄은 "added" 다. e2e 의 행 대부분은 그 경로가 아니다. 행은 명령으로 pre-guard 를 돌린 뒤 post 훅에 고쳐 쓰기 전의 명령을 행이 적은 그대로 넘긴다. 고쳐 쓰기를 적용하지 않은 런타임이 보낼 명령이고, 거기서 줄은 "asked" 다. 이 줄에 관한 행만 post 훅에 pre-guard 가 쓴 명령을, 또는 행이 같은 바이트로 적은 명령을 넘긴다.

대조군은 `scripts/test/report-mutations.sh` 다. 변이 서른여섯을 사본에서 하나씩 돌리고, 모두 오라클에서 빨강이어야 한다. 아홉은 사실 뒤의 조언, npm 을 예측하는 사유, 디렉터리 안에 무엇이 있다는 주장, 보지 않고 보고한 제거, 함수 밖에서 만든 줄, 확정 스냅샷을 주장하는 머리말, 검사 없는 상태 줄, 기록을 읽지 않고 확정이라 부른 스냅샷, 추정한 원인이다. 일곱은 리뷰에서 나왔다. 모든 롤백에 덧붙인 산문, reorg.log 에만 있는 줄, 메시지의 사유에만 붙인 절, kept 로 보고한 실패한 제거, 줄 없이 지운 `node_modules`, `node_modules` 줄이 빠진 중단 보고, 메시지에서 뺀 거부다. 둘은 F1 을 되살리고, safedeps 가 쓴 명령이 아닌 명령에 "added" 라고 말한다(F2). 하나는 메시지를 내지 않은 호출에서 reorg.log 항목을 덧붙인다(LogSilent). 셋은 밤토리 r18 의 기록 클래스다. backstop 이 safedeps 가 한 일을 말하고(F4. 버전 2 규칙 뒤로는 backstop 의 없는 기록이 스스로 줄을 내지 않아, 이 변이는 그것이 남기는 advisory.log 줄에서 빨강이다), 기록이 safedeps 가 쓴 명령 대신 받은 그대로의 명령을 담고(MarkOrig), 기록 없이 고쳐 쓴 명령이 나간다(MarkSkip). 하나 더는 훅이 기록을 읽지 못했는데 "did not add" 라고 말하고(Unread), 또 하나는 1초 안의 두 호출에 다시 스냅숏 id 하나를 준다(Same). 둘은 사실을 밝히지 않는 기록에 다시 "did not add" 로 답하고(Default), 다른 버전이나 버전 없는 기록을 버전 2 로 읽는다(Version). 하나는 버전을 문자열로 읽어 `"2"` 를 받아들인다(XStr2, 밤토리 r23. `"2"` 행이 생기기 전에는 스위트를 통과했다). 둘은 기록의 스냅숏에 meta 파일이 없을 때(Gone), 그리고 기록이 스냅숏을 가리키지 않을 때(Empty) 다시 아무 말 없이 훅을 끝낸다. 마지막 셋은 JSON 객체 하나가 아닌 기록을 아무 말 없이 치우고(NotObject), `project_dir` 가 없는 기록을 훅 자신의 작업 디렉터리에서 판정하고(NoDir. 오라클은 프로젝트 밖의 경로를 적은 단계 줄로 본다), 기록의 `dir_hash` 로 확정 스냅숏을 고른다(RecordHash. 오라클은 프로젝트의 확정 기록이 가리키지 않는 확정 스냅숏으로 본다). 넷은 호출의 기록이다. KeyRecords 는 모든 기록을 다시 디렉터리와 명령으로 두고 찾아, OV1 에서 Codex 호출이 Claude 호출의 기록을 소비한다. IdFallsBackToKey 는 자기 기록이 없는 호출에 그 키로 찾은 기록을 주어, OV2 에서 그 호출이 `tool_use_id` 를 적지 않은 호출의 기록을 소비한다. Legacy 는 pre-#5 의 `current_snapshot_id` 를 다시 읽는다. CodexEverywhere 는 Claude Code 호출에 다시 "(on Codex it cannot)" 를 붙인다. 여덟은 줄이 아니고, e2e 가 오라클이 아니라 깨진 행에서 빨강이어야 한다. NoIdSilent 는 호출이 `tool_use_id` 를 적지 않았다는 `advisory.log` 줄을 뺀다. 나머지 일곱은 백스톱의 흔적 검사를 깬다. TraceNever 는 흔적을 하나도 찾지 않아 pre-guard 가 읽지 못한 설치가 남는다. TraceAlways 는 어디서나 흔적을 찾아 grep 이 프로젝트를 롤백한다. WalkOff 는 걷기를 빼서 `node_modules` 에만 쓴 것이 남는다. PullAlways 는 모든 파일 시스템에서 기준선을 2초 앞으로 맞춰 pull 바로 뒤의 grep 이 프로젝트를 롤백한다. Oldest 는 항목을 프로젝트와 명령으로 두고 가장 오래된 것을 읽어, 실패한 호출의 항목이 뒤의 grep 으로 프로젝트를 롤백하게 한다. LinkLstat 은 링크된 lockfile 의 대상이 아니라 링크 자신의 상태 변경 시각을 읽어, 링크를 거쳐 쓴 것이 남는다(lumi r2 S1). AnySubsecond 는 노드 트리의 파일 전부가 아니라 하나라도 1초 미만 시각을 지니면 기준선을 그대로 두어, `node_modules` 가 초 단위만 지니는 트리를 당기지 않은 기준선에서 걷는다(lumi r2 P3). 기록을 찾지 못한 곳에서만 흔적 항목을 읽던 EntryAfterRecord(lumi r3 REC 전의 순서)는 뺐다. 이제 호출은 항목이나 기록 중 하나만 지니므로 어느 행도 두 순서를 가르지 못하고, 그것이 대신하던 결함은 KeyRecords 다.

덮지 못하는 것은 주장하지 않고 적는다. 오라클은 읽은 줄 하나하나를 검사한다. 어떤 줄을 골랐는지는 검사하지 않으므로, 참인 줄이 오해를 부를 수 있고 줄이 빠질 수도 있다. 빠진 줄은 오라클이 디스크나 기록으로 그 줄이 있어야 했다는 것을 알 때만 잡힌다. 바뀐 최상위 항목, reorg.log 에 있는 거부, 보고의 `node_modules` 줄이 그렇다. 오라클은 훅과 코드를 공유하지 않지만, 둘이 같은 검사를 틀리면 통과한다. 줄은 쓰인 때에 참이고 그 뒤는 아니다. 비교하는 목록은 프로젝트 최상위다. 그래서 그 아래, 중첩 디렉터리나 워크스페이스 멤버의 변화는 그것을 말하는 줄로만 잡힌다. 워크스페이스 멤버의 복원된 `package.json` 은 그 줄로 검사하게 되어 있지만, e2e 에 그것을 복원하는 행이 없어 이 스위트에서는 그 검사가 돌지 않는다. `kept` 아래의 패키지 목록은 `node_modules` 아래 세 단계까지 읽고, 더 깊이 쓰인 패키지는 훅의 목록에도 오라클의 목록에도 없다. "Detected problems" 아래의 사유는 검사들 자신의 문자열이고 문법 밖이다. 오라클은 메시지와 reorg.log 가 같은 사유를 담는지만 보므로, 사유 자체를 바꾸면 통과한다. 효과 게이트의 rebuild 경고("review it, then run `npm rebuild` yourself if it is what you expect", "confirm with the user before running")는 의도한 지시이고 지금도 문장이다. 오라클은 각각을 접두 완전 일치로, 나올 수 있는 블록과 이 스위트가 보일 수 있는 최대 줄 수(지금은 일곱 모두 0)와 함께 받고, 그 사실은 디스크가 아니라 기록 파일에서 나오므로 형식은 후속 플랜의 몫이다.

**막지 않는 것 (현재 한계):**

- `approved_at` 이후 발견된 zero-day — daily re-check 로만 잡고, install 시점엔 못 잡는다.
- npm registry 자체의 손상.
- `.npmrc` 가 옮기거나 기록 밖에 둔 설치. 그런 설치는 `UNGATED` 로 기록하되 검사하지는 않는다. npm 이 읽는 어느 `.npmrc` 에서든 전역 트리는 npm 이 답하고, 프로젝트 설치를 기록 밖에 두는 설정은 프로젝트와 사용자의 `.npmrc` 에서 읽는다. 전역 npmrc 와 내장 npmrc 의 그런 설정은 읽지 않으므로, 거기서 기록 밖에 둔 설치는 기록되지 않는다. 어느 쪽이든 패키지와 바이너리는 검증 없이 놓인다. 스크립트는 돌지 않는다. 설치는 무실행이고, npm 이 rebuild 할 트리에 어느 lockfile 에도 기록되지 않은 패키지나 패키지 버전이 있으면 rebuild 를 건너뛴다.
- 게이트가 본 곳에 흔적을 남기지 않은 npm 설치. 텍스트에 드러나지 않은 무언가가 다른 곳으로 보낸 설치, 그리고 설치 디렉터리를 npm 에게 물을 수 없었는데(훅의 `PATH` 에 npm 이 없거나, 실패하거나, 8초 안에 답하지 않거나, 셸이 실행 시점에 정하는 값을 받은 경우) cwd 에 떨어지지 않은 설치다. `UNGATED` 로 기록하되 검사하지는 않는다. dry run 과 실패한 설치도 같은 기록이 된다. 흔적으로는 둘을 구별할 수 없기 때문이다.
- 설치가 남기지 않은 흔적. 흔적은 명령의 것이 아니라 디렉터리의 것이다. 명령이 도는 동안 같은 디렉터리에 다른 npm 이 쓰면 흔적이 생기고, 명령이 스스로 lockfile 을 건드려도 생긴다. 뒤의 것은 같은 사용자 공격자이고, 원장의 경계와 같은 경계다. 초 단위 mtime 만 남기는 파일 시스템에서는 기준 파일의 초 안에 쓰인 lockfile 이 흔적으로 보이지 않으므로, 거기서는 그 설치가 `UNGATED` 로 기록된다. 소음이지 통과가 아니다.
- npm 의 두 답이 보지 못하는 곳에서 정한 registry. 에이전트 셸의 환경에는 있지만 훅 프로세스의 환경에는 없는 경우, 명령이 `.npmrc` 를 썼다가 다시 지우는 경우다. 이때 rebuild 는 그 registry 가 공개 URL 로 준 것을 그대로 돌린다. 명령 자신이 export 하거나 대입한 것은 이름이 무엇이든 질의에 실린다(XH1-XH5). 앞선 문장이 보이지 않게 npm 의 환경을 바꿀 수 있으면, 셸이 실행할 때 값을 정하는 export 를 포함해, 답은 모름이 되고 rebuild 를 건너뛴다. npm 이 설정에서 읽는 공개 밖 registry 는 사내 registry 나 미러라도 차단하지 않는다. 그 registry 가 공개 registry URL 로 내준 것은 설치되고, 스크립트는 돌지 않는다. 그 바이트는 integrity 로 기록되므로 머신의 어느 트리도 그것을 담고 있으면 자동 rebuild 되지 않고, v2.18.0 에는 그 기록을 풀 길이 없다. registry 를 확인한 사람이 rebuild 하고, 다음 릴리스가 registry 를 승인할 수 있을 때까지 그 바이트의 자동 rebuild 는 꺼져 있다. registry 자신의 URL 로 기록된 것은 전처럼 비표준 출처다. Codex 에서는 설치 중에 이미 돌았다. registry 승인은 다음 릴리스에 둔다.
- 게이트가 받는 것을 본 적 없는 바이트. 보류한 바이트의 기록은 post 훅이 받는 것을 볼 때만 쓰인다. 훅 밖에서 돈 설치, 명령 훅이 알아보지 못한 설치, `UNGATED` 로 기록된 설치, 그리고 npm 의 두 답이 보지 못하는 registry(위)가 받은 바이트는 기록 없이 npm 캐시에 들어가고, 그 integrity 를 적은 lockfile 은 공개 URL 아래 거기서 그것을 설치한다. clone 이 `node_modules` 안에 담아 온 바이트는 애초에 아무도 받지 않았으므로 아무것도 그것을 기록하지 않고, rebuild 는 그 바이트를 있는 그대로 믿는다. 바이트 없이 담아 온 트리 기록은 기록에서 아무것도 빼지 못한다. 기록에서 빠지는 것은 게이트가 판정한 트리 기록에만 기댄다(HL1-HL4). P1-P7, Q1-Q5, HL1-HL4, DP1 이 닫은 종류의 반례는 여기서만 나올 수 있다.
- npm 이 공개 registry 라고 답했을 때, 명령이 먼저 돌린 코드 뒤에 받은 바이트. `source`, `.`, `eval` 뒤의 설치는 rebuild 되지 않지만 그 바이트도 기록되지 않는다. 그 코드가 npm 을 다른 registry 로 돌려놓았다면, 예컨대 source 한 파일이 `npm_config_registry` 를 export 했다면, npm 이 공개 registry 라고 답하는 다음 설치가 그 registry 가 준 것을 rebuild 한다(VB4). 기록의 `resolved` 는 그것을 막지 못한다. registry.npmjs.org tarball URL 을 내주는 registry 는 그 URL 아래에서 받아지고 그 URL 로 기록된다(RH1 과 같다). 놓친 것이 아니라 고른 것이다. 그 코드를 쥔 쪽은 npm 없이도 이미 에이전트 셸에서 코드를 돌린다. 코드를 누가 썼든 같고, 명령이나 앞선 명령이 쓴 파일도 마찬가지다. 명령 안에 적힌 설정은 앞에 어떤 코드가 돌든 기록된다. npm 앞의 `npm_config_registry=…` 나 그것의 `export` 는 npm 이 답하고(EXP1, VB1-VB3), 자기 글자에 npm 설정을 적은 `eval` 은 설정으로 친다(EV1).
- 명령이 고른 npm 이 읽는 설정. 명령이 자기 `PATH` 로 npm 을 돌리거나 경로로 적으면 safedeps 는 자기 npm 에게 묻는다. 그래서 명령의 npm 만 읽는 전역·내장 `.npmrc` 는 어느 답에도 없다. 그 npm 의 설정이 다른 registry 를 가리키면 그 명령의 스크립트는 보류되고 아무것도 기록되지 않으며, npm 이 공개 registry 라고 답하는 다음 설치가 그 registry 가 준 것을 rebuild 한다(VB4 와 같다). 까닭도 같다. 그 npm 을 고른 쪽은 이미 에이전트 셸에서 그것을 돌린다.
- 커밋된 lockfile 의 출처. 출처 검사는 설치가 새로 들인 것을 명령 전의 기록과 대조해 읽고, 커밋된 `package-lock.json` 도 그 기록 중 하나다. 그래서 새로 clone 한 곳의 `npm ci`, 또는 lockfile 을 따르는 맨 `npm install` 은 lockfile 이 적은 출처를 그대로 설치한다. 승인된 이름과 버전을 다른 tarball 로 보내도록 고친 출처도 포함된다. clone 이 `node_modules` 에 담아 온 트리 기록도 같다. 출처 검사는 그것도 명령 전의 기록으로 읽는다. 그 스크립트는 돌지 않는다. rebuild 의 트리 전체 검사가 그 출처를 찾아 rebuild 를 건너뛴다. 없는 이전 기록을 빈 기록으로 읽으면 설치 자체를 잡지만, 사설 registry, git URL, tarball 에서 설치하는 모든 프로젝트의 첫 `npm ci` 도 롤백된다. 출처를 승인할 길이 아직 없으므로 그것은 사용자에게 보이는 정책 변경이고, 다음 릴리스로 남긴다. 설치 스크립트 휴리스틱도 설치가 새로 들인 것만 읽으므로, 이미 기록에 있는 승인된 공개 registry 패키지는 다시 읽지 않는다(v2.17.2 와 같다).
- 아무도 승인하지 않은 출처나 디렉터리가 트리에 있는 프로젝트의 자동 rebuild. 공개 registry 에서 왔다고 기록되지 않은 패키지, 출처가 없는 기록(`omit-lockfile-registry-resolved`), 선언된 워크스페이스 멤버가 아닌 `file:` 디렉터리 의존성이 그것이다. rebuild 는 전부 아니면 전무라서 승인된 패키지의 스크립트도 돌지 않고, 사용자가 경고가 지목한 것을 검토한 뒤 `npm rebuild` 를 돌린다. v2.17.2 는 커밋된 `file:` 디렉터리 의존성이 있는 프로젝트의 설치를 롤백했다(npm 10.8.2 로 잼). 출처 승인과, 통과한 노드만 rebuild 하는 것은 다음 릴리스로 남긴다.
- lockfile 을 쓰는 npm 문장 둘 사이에 무언가가 있으면, 둘 다 게이트가 본 곳에 떨어졌더라도 `UNGATED` 로 기록된다. 규칙은 그 둘을 구별하지 못하고, 기록 쪽으로 틀린다.
- Codex CLI 에서는 흔적을 남기지 않은 설치가 떨어진 곳에서 이미 스크립트를 돌렸다. 남는 것은 기록뿐이다(기존 Codex 비대칭).
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
├── confirmed_${dir_hash}      ← 프로젝트별 기준점: 마지막으로 검증된 설치가 남긴 상태
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
