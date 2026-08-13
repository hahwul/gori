+++
title = "데이터 디코드와 변환"
description = "변환기를 파이프라인으로 이어 붙여 — 디코드하고, 또 디코드하고, 해시하고 — 각 단계의 출력을 지켜본 뒤, 재사용하도록 저장합니다."
weight = 60

[extra]
group = "워크벤치"
+++

**Decoder**는 값을 변환기 체인에 통과시킵니다 — base64, URL, JWT, 해시, 압축 — 한 번에 한 단계씩, 각 단계의 출력을 보여 주면서요. 이 플레이북은 체인을 만들고, 어디서 성공하고 어디서 깨지는지 읽고, 이름을 붙여 저장해 다음 값을 키 한 번으로 통과시킵니다. 몇 분이면 되고 트래픽을 전혀 보내지 않습니다. 이 워크벤치 전체가 로컬 변환이라, 대상도 스코프도 승인된 호스트도 필요 없습니다.

> **시작하기 전에.** gori를 실행해 두세요([Quick Start](/ko/getting-started/quick-start/)로 도달합니다). 캡처도, 프로젝트 스코프도, 네트워크 대상도 필요 없습니다 — Decoder는 당신의 머신을 벗어나지 않으므로 승인할 호스트가 없습니다.

## 1. Decoder 열고 입력 붙여넣기 {#1-open-the-decoder-and-paste-input}

**Decoder** 탭을 엽니다(탭 바에서, 또는 `Ctrl-P` → **Go to Decoder**). 네 개의 카드가 위에서 아래로 쌓입니다. **INPUT**(원본 텍스트), **CHAIN**(변환기 스펙), **PIPELINE**(단계별 한 행씩), **OUTPUT**(최종 결과). 커서를 **INPUT**에 두고 다룰 값을 붙여넣습니다 — 쿠키, 토큰, 캡처한 플로우에서 떼어 온 Base64 블롭.

열려 있는 각 변환은 **서브탭**이며, 서브탭은 프로젝트와 함께 저장됩니다. 그래서 열어 둔 스크래치 패드는 그 프로젝트를 다시 열 때 돌아오고, 다른 프로젝트로 따라가지 않습니다.

**체크포인트.** 붙여넣은 값이 INPUT 패널에 놓여 있습니다.

## 2. 체인 만들기 {#2-build-a-chain}

**CHAIN** 줄에 변환기 이름을 `|`, `>`, 또는 `,`(모두 동일)로 구분해 입력합니다. 단계는 왼쪽에서 오른쪽으로 실행되며, 각 단계의 출력이 다음 단계로 들어갑니다:

```text
base64-decode | jwt-decode
```

결과를 해시하거나 다시 인코딩하는 단계를 붙이세요 — `sha256`, `url-encode`, `hex-encode`. 별칭은 기본 이름으로 해석되고(`b64` → `base64-encode`), 자동완성이 애매한 이름을 채워 줍니다. 전체 목록은 인코딩, 진법, 압축, `jwt-decode`, 해시(`md5` … `sha512`, `crc32`), 이스케이프/텍스트 변환을 아우릅니다. `gori run decoder list`(또는 [Decoder 가이드](/ko/guide/decoder/#converters))가 각각을 카테고리와 방향과 함께 출력합니다.

같은 체인이 헤드리스로도 실행되며, 값은 인수나 stdin에서 받습니다:

```bash
gori run decoder 'base64-decode | jwt-decode' "$TOKEN"
echo -n secret | gori run decoder 'sha256 | hex-encode'
```

<figure class="tui-shot">
  <img src="/images/tui/decoder.svg" alt="INPUT, CHAIN, PIPELINE, OUTPUT 패널에서 base64-decode 다음 jwt-decode 체인을 실행하며 각 단계의 중간 결과를 보여 주는 gori Decoder 탭">
  <figcaption><strong>Decoder</strong> 워크벤치: 입력, 변환기 체인, 그리고 단계별 파이프라인과 그 아래 최종 출력.</figcaption>
</figure>

**체크포인트.** PIPELINE에 각 변환기가 자기 행으로, 만들어 낸 중간 출력과 함께 나열됩니다.

## 3. 파이프라인과 최종 출력 읽기 {#3-read-the-pipeline-and-final-output}

PIPELINE은 체인을 디버깅하는 곳입니다. 위에서 아래로 읽으세요. 각 행은 한 단계의 출력이고, 마지막 행이 OUTPUT으로 들어갑니다. 어떤 단계가 다룰 수 없는 입력을 받으면 — Base64가 아닌 텍스트에 `base64-decode`, 토큰이 아닌 것에 `jwt-decode` — 그 행이 읽히던 데이터가 쓰레기나 오류로 바뀌는 지점이고, 그 아래 모든 행은 하류의 잡음입니다. 단계를 고치거나 체인 순서를 바꾼 뒤 다시 읽으세요.

바이너리 결과의 경우 OUTPUT은 표시 모드를 순환합니다(text → hex → base64). 그래서 텍스트로는 비어 보이는 바이트가 hex로는 읽힙니다. 최종 값은 READ 모드에서 `y`로, INS에서 INPUT을 편집하는 중이라면 `Ctrl-Y`로 복사합니다.

**체크포인트.** 출력이 처음 어긋나는 PIPELINE 행을 정확히 짚을 수 있습니다 — 또는 모든 행이 깨끗하고 OUTPUT이 기대한 값을 담고 있음을 확인합니다.

## 4. 이름 붙인 체인 저장·재사용 {#4-save-and-reuse-a-named-chain}

다시 쓸 체인에는 이름을 붙일 값어치가 있습니다. `Ctrl-S`(또는 space 메뉴의 **Save chain by name**)로 저장하세요. 이미 있는 이름으로 저장하면 갱신됩니다. 나중에 `Ctrl-O`로 불러오면 저장한 모든 항목 위로 피커가 열리며 — 각 이름이 그 스펙과 나란히 표시됩니다 — 타이핑으로 필터하고 `Ctrl-X`로 강조된 항목을 삭제합니다.

이름 붙인 체인은 설정의 `decoder` 섹션에 살고 모든 프로젝트가 공유합니다. 체인은 레시피이고, 그것에 통과시키는 것은 프로젝트에 남습니다. 저장한 이름은 그 자체로 **변환기**이기도 합니다 — 한 단계로 입력하면 그 전체 스펙이 그 자리에서 실행됩니다. Decoder에서든, Repeater나 Fuzzer의 `§…§` 마커 위에서든, `gori run decoder`에서든, 인수 하나에 동일한 체인을 실행하는 MCP `decode` 도구를 통해서든요.

**체크포인트.** 저장한 체인이 모든 표면에서 새 입력에 다시 실행됩니다 — 불러오기 피커, CLI, 그리고 다른 체인 안의 한 단계로서.

## 다음 단계 {#next-steps}

- [JWT 공격](/ko/playbooks/attack-a-jwt/): `jwt-decode`를 넘어 토큰의 클레임을 편집하고 다시 서명하기
- [Decoder](/ko/guide/decoder/): 전체 변환기 표, 서브탭, 저장 체인 규칙
- [CLI Reference](/ko/reference/cli/#run-decoder): `gori run decoder`의 모든 옵션
