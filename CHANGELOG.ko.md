# Changelog

[English](CHANGELOG.md)

## Unreleased

- 외부 `file` 명령어를 스크립트와 텍스트를 무시하고 최대 20개의 정렬된 `.bin` 대상 및 심볼릭 링크에 대해 일관된 이미지 헤더를 직접 읽는 감독되는 코어 자식 프로세스로 대체하여 ELF, Mach-O, PE 이미지를 확인합니다. 후보는 실행 없이 엄격히 읽기만 수행하며 로드 가능성이나 안전성을 보증하지 않습니다. 검사 불능 시 fail-closed 롤백이 트리거됩니다. 코어 프로세스는 이제 `file`을 제외한 `npm`, `curl`, `gzip`, 자체 판정 및 네이티브 검사 자식 프로세스로 실행됩니다.
- 순환 optional peer 의존성으로 인해 npm 11.6.0 이전 버전에서 발생하는 probe 실패에 대해, probe overrides에서 대상 패키지를 자체 버전으로 고정하는 두 번째 해석을 추가했습니다. 해당 closure는 핀을 제거한 두 번째 실행에서 npm이 lockfile을 변경하지 않고 유지함을 확인하는 경우에만 판정되며, 그렇지 않으면 `npm_closure_resolution_failed`를 보고합니다.
