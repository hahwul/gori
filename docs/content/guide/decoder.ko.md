+++
title = "Decoder"
description = "TUI 안에서 다단계 파이프라인으로 데이터를 인코드, 디코드, 해시, 변환합니다."
weight = 40

[extra]
group = "워크벤치"
+++

**Decoder** 탭은 데이터를 인코드, 디코드, 해시, 변환하는 스크래치 워크벤치입니다. 입력을 붙여넣고, 변환기 체인을 구성하고, 중간 결과와 최종 결과를 읽습니다.

<figure class="tui-shot">
  <img src="/images/tui/decoder.svg" alt="base64-encode 후 upper 체인을 실행하며 각 단계의 중간 결과를 보여주는 INPUT, CHAIN, PIPELINE, OUTPUT 패널을 갖춘 gori Decoder 탭">
  <figcaption><strong>Decoder</strong> 워크벤치: 입력, 변환기 체인, 단계별 파이프라인, 그리고 아래의 최종 출력.</figcaption>
</figure>

## 레이아웃 {#layout}

네 개의 카드가 위에서 아래로 쌓입니다.

| 패널 | 역할 |
|------|------|
| **INPUT** | 소스 텍스트(편집 가능) |
| **CHAIN** | 파이프라인 스펙: `|`, `>`, `,`(모두 동등)로 구분된 변환기 이름 |
| **PIPELINE** | 각 단계당 한 줄과 그 중간 출력 |
| **OUTPUT** | 최종 결과(text / hex / base64 표시 모드) |

여러 변환을 **서브탭**으로 열어둘 수 있습니다(space 메뉴에서 생성, 이름 변경, 복제, 닫기).

## 체인 구성 {#building-a-chain}

CHAIN 줄에 변환기 이름을 입력합니다. 단계는 왼쪽에서 오른쪽으로 실행됩니다.

```text
url-decode | base64-decode | jwt-decode
hex-encode | upper
gzip-decompress | json-unescape
```

별칭은 기본 이름과 동일하게 동작합니다(`b64` → `base64-encode`, `url` → `url-encode`, 등). 이름이 모호할 때 자동완성이 도와줍니다.

체인을 이름으로 저장하고(space 메뉴의 **Save chain by name**) 나중에 다시 불러올 수 있습니다. 기본값도 설정의 `decoder` 섹션에 유지됩니다.

## 변환기 {#converters}

| 범주 | 예시 |
|----------|----------|
| **Encoding** | `base64-encode` / `base64-decode`, `base64url-encode`, `url-encode` / `url-decode`, `hex-encode` / `hex-decode`, `base32`, `ascii85`, `base58` |
| **Compression** | `gzip-compress` / `gzip-decompress`, `zlib-compress` / `zlib-decompress` |
| **Token** | `jwt-decode` (헤더 + 페이로드; 서명은 표시되지만 검증하지 않음) |
| **Hash** | `md5`, `sha1`, `sha256`, `sha512` |
| **Escape** | `html-escape` / `html-unescape`, `json-escape` / `json-unescape`, `unicode-escape` / `unicode-unescape` |
| **Text** | `rot13`, `upper`, `lower`, `reverse` |

OUTPUT은 바이너리 결과를 위해 표시 모드(text → hex → base64)를 순환할 수 있습니다. READ 모드에서 `y`로 복사하거나 space 메뉴를 사용하세요.

## 언제 사용하는가 {#when-to-use-it}

- 플로우를 변형하지 않고 History에서 JWT나 중첩된 Base64 블롭을 디코드합니다
- Fuzzer 페이로드 프로세서에 쓸 변환을 미리 구성합니다
- Repeater 요청을 작성하면서 값을 빠르게 해시하거나 URL 인코드합니다

Decoder는 네트워크 트래픽을 보내지 않습니다. 순수한 로컬 변환입니다.

## 다음 단계 {#next-steps}

- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/): 페이로드 프로세서는 비슷한 인코드/해시 단계를 사용합니다
- [Proxy & History](/ko/guide/proxy/): JWT / SAML / GraphQL은 캡처된 플로우에서도 인라인으로 디코드됩니다
- [Hotkeys](/ko/guide/hotkeys/): Decoder 범위의 동작을 재지정합니다
