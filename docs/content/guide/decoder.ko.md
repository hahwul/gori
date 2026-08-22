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

여러 변환을 **서브탭**으로 열어둘 수 있습니다(space 메뉴에서 생성, 이름 변경, 복제, 닫기). 열린 서브탭은 **프로젝트**에 저장되므로 그 프로젝트를 다시 열면 그대로 복원되고, 다른 프로젝트로는 넘어가지 않습니다.

## 체인 구성 {#building-a-chain}

CHAIN 줄에 변환기 이름을 입력합니다. 단계는 왼쪽에서 오른쪽으로 실행됩니다.

```text
url-decode | base64-decode | jwt-decode
hex-encode | upper
gzip-decompress | json-unescape
```

별칭은 기본 이름과 동일하게 동작합니다(`b64` → `base64-encode`, `url` → `url-encode`, 등). 이름이 모호할 때 자동완성이 도와줍니다.

체인을 이름으로 저장하고(space 메뉴의 **Save chain by name** 또는 `Ctrl-S`) 나중에 다시 불러올 수 있습니다. 저장 입력창은 서브탭 이름으로 채워져 열리고, 이미 있는 이름으로 저장하면 그 항목을 갱신합니다. **Load a saved chain**(`Ctrl-O`)은 저장해 둔 목록을 피커로 열어 이름 옆에 체인 내용을 함께 보여 주므로, 무슨 이름으로 저장했는지 외우고 있을 필요가 없습니다. 타이핑으로 걸러 볼 수 있고, `Ctrl-X`는 선택한 항목을 라이브러리에서 지웁니다. 두 항목 모두 탭 안 어디서든 space 메뉴에 나옵니다 — 서브탭 스트립, 탭 바, 각 패널 안 전부.

이름을 붙인 체인은 설정의 `decoder` 섹션에 저장되어 모든 프로젝트에서 공유됩니다. 체인은 조리법이고, 거기에 통과시킨 내용은 프로젝트에 남습니다. Rewriter는 같은 경계를 다르게 긋습니다. 규칙 자체가 [전역이거나 프로젝트 범위](/ko/guide/proxy/#reusing-a-rule-across-projects)입니다.

저장한 이름은 그 자체로 **변환기**이기도 합니다. 체인의 한 단계로 이름을 적으면 저장해 둔 체인 전체가 그 자리에서 실행됩니다.

```
myenc > url-encode
```

이 탭에서만이 아니라 gori가 체인을 받는 모든 곳에서 동작합니다. Repeater 나 Fuzzer의 `§…§` 마커에서 여는 `Ctrl-Y` 체인 편집기, `gori run decoder`, MCP의 `decode` 도구 전부 해당합니다. 자동완성은 저장한 이름을 기본 변환기와 나란히 보여 주고, `gori run decoder list`에는 `saved` 범주로 나옵니다.

저장한 체인끼리 서로 부를 수도 있습니다. 순환 정의는 멈추지 않고 그 단계가 이유와 함께 실패하며, 기본 변환기가 이미 쓰고 있는 이름(별칭 포함)은 저장 단계에서 거부됩니다. 기본 변환기가 계속 이겨야 하기 때문입니다. 라이브러리가 `base64-decode`를 가릴 수 있게 되면 모든 프로젝트에 이미 있는 체인의 의미가 바뀝니다.

## 변환기 {#converters}

| 범주 | 예시 |
|----------|----------|
| **Encoding** | `base64-encode` / `base64-decode`, `base64url-encode`, `url-encode` / `url-decode`, `hex-encode` / `hex-decode`, `base32`, `ascii85`, `base58`, `base36`, `base62`, `quoted-printable`, `punycode-encode` / `punycode-decode` |
| **Number bases** | `decimal-encode` / `decimal-decode`, `binary-encode` / `binary-decode`, `octal-encode` / `octal-decode` |
| **Compression** | `gzip-compress` / `gzip-decompress`, `zlib-compress` / `zlib-decompress`, `deflate-raw` / `inflate-raw` (헤더 없는 RFC 1951), `brotli-decompress`, `zstd-decompress` |
| **Serialization** | `msgpack-decode`, `cbor-decode` — 바이너리 문서를 JSON 텍스트로 렌더 |
| **Token** | `jwt-decode` (헤더 + 페이로드; 서명은 표시되지만 검증하지 않음) |
| **Hash** | `md5`, `sha1`, `sha224`, `sha256`, `sha384`, `sha512`, `crc32` |
| **Escape** | `html-escape` / `html-unescape`, `json-escape` / `json-unescape`, `unicode-escape` / `unicode-unescape`, `xml-escape` / `xml-unescape`, `c-string-escape` / `c-string-unescape`, `shell-escape`, `powershell-escape` |
| **Text** | `rot13`, `rot47`, `upper`, `lower`, `reverse`, `homoglyph`, `typo` |

`brotli-decompress`와 `zstd-decompress`는 압축 해제 전용이며, 이는 빠뜨린 것이 아니라 의존성의 모양 그대로입니다. gori는 brotli의 *디코더* 라이브러리를 링크하고 libzstd의 압축 해제기만 감쌉니다 — 프록시에게 필요한 것은 원 서버가 보낸 것을 읽는 일이기 때문입니다. 둘 다 `Content-Encoding`이 쓰는 `br`, `zstd` 별칭을 받고, 잘린 스트림도 견딥니다(캡처 상한에 걸린 플로우에서 본문을 복사해 오면 흔한 경우입니다). `-Dwithout_native_codecs`로 빌드한 gori도 이름은 그대로 알고 있으며, 오타라고 답하는 대신 그런 빌드라는 사실을 알려 줍니다.

`msgpack-decode`와 `cbor-decode`는 남이 쓴 바이너리 문서를 읽어 JSON으로 렌더합니다. 한 방향이고, 그 방향이 필요한 쪽입니다. 여기서 JSON은 *투영*이지 재인코딩이 아닙니다. JSON에 담을 자리가 없는 것은 접어 없애지 않고 이름을 달아 돌려줍니다(바이트 문자열은 `{"$bin": …}`, CBOR 태그는 `{"$tag": …}`, MessagePack 확장은 `{"$ext": …}`, JSON 숫자로는 정확하지 않은 정수는 10진 문자열). 입력이 도중에 끊긴 문서는 읽은 데까지 렌더하고 멈춘 자리를 `{"$partial": …}`로 표시합니다 — 캡처 상한에 잘린 본문에서 흔한 경우입니다. 투영에는 모호함이 하나 따라옵니다. 문서 자신의 맵 키가 문자 그대로 `$bin`이나 `$tag`이면 래퍼와 같은 모양으로 렌더됩니다. 그런 본문 하나를 막자고 모든 본문의 모든 키를 이스케이프하면 흔한 본문이 오히려 읽기 어려워집니다.

몇 가지는 한 방향으로만 동작하며 체인으로 되돌릴 수 없습니다. `shell-escape`와 `powershell-escape`는 값을 따옴표 리터럴로 감싸고, `homoglyph`는 ASCII 글자를 시각적으로 닮은 유니코드 문자로 바꿉니다(굳어진 대응 문자가 없는 글자는 그대로 둡니다). `typo`는 변환이 아니라 생성기입니다. 글자 누락, 인접 글자 자리바꿈, QWERTY 이웃 키로 만든 오타 변형을 한 줄에 하나씩 내놓습니다.

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
