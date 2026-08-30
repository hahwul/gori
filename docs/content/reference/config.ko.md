+++
title = "설정"
description = "settings.json 키와 GORI_HOME 저장소 레이아웃."
weight = 20
+++

gori는 전역 환경설정을 `settings.json`에, 각 프로젝트를 자체 SQLite 데이터베이스로 저장합니다. 전체 흐름은 [설정 가이드](/ko/getting-started/configuration/)를 참고하세요. 이 페이지는 키 단위 레퍼런스입니다.

## 저장소 레이아웃 {#storage-layout}

모든 것은 `GORI_HOME` 아래에 있습니다(`$GORI_HOME`이 설정되어 있고 비어 있지 않으면 그 값, 아니면 `~/.gori`):

| Path | Contents |
|------|----------|
| `settings.json` | 전역 환경설정 |
| `gori.db` | 기본 프로젝트 데이터베이스 |
| `projects/` | 이름이 지정된 프로젝트마다 하나의 하위 디렉터리, 각각 자체 DB 보유 |
| `ca/` | 루트 CA: `root.crt.pem`과 `root.key.pem` |
| `themes/` | 사용자 테마 |
| `wordlists/` | Fuzzer / miner 워드리스트 |
| `protos/` | gRPC 디스크립터 셋(`protoc --descriptor_set_out`). 자체 경로를 지정하지 않은 프로젝트가 여기서 읽습니다 |
| `active_project` | 가장 최근에 사용한 프로젝트 마커 |

## settings.json {#settingsjson}

`settings.json`은 JSON입니다. `gori settings` / `gori settings --edit`로 찾거나 편집합니다.

위치는 `--config PATH` → `$GORI_CONFIG` → `$GORI_HOME/settings.json` 순으로 결정되므로, CA·프로젝트 DB·테마·워드리스트를 옮기지 않고도 다른 설정으로 실행할 수 있습니다. 섹션 단위 이동은 [`gori settings export` / `import`](/ko/reference/cli/#profiles)로 합니다. 그중 `rewriter`·`scan_rules`·`decoder`·`statusline`·`editor` 다섯 섹션은 데이터가 아니라 명령을 담을 수 있어 프로필이 코드를 실어 나를 수 있습니다. 전달 양쪽 끝에서 [그 사실을 알려줍니다](/ko/reference/cli/#profiles-that-carry-commands).

### network {#network}

```json
{
  "network": {
    "bind_host": "127.0.0.1",
    "bind_port": 8070,
    "upstream_proxy": ""
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bind_host` | string | `127.0.0.1` | 전역 기본 리스닝 주소 (프로젝트에 `net.bind_host`가 없을 때 사용) |
| `bind_port` | integer | `8070` | 전역 기본 리스닝 포트 (프로젝트에 `net.bind_port`가 없을 때 사용) |
| `upstream_proxy` | string | `""` | 전역 기본 업스트림: 기존 `host:port`/`http://…` 또는 `socks5://…`/`socks5h://…`; 비어 있으면 직접 연결. 설정 시 프로젝트 `net.upstream_proxy`가 우선 |
| `verify_upstream` | bool | `true` | 시스템 CA 트러스트 스토어로 업스트림 TLS 인증서 검증(표준 위치에서 자동 탐색하며 `SSL_CERT_FILE` / `SSL_CERT_DIR` 존중; 스토어를 못 찾으면 HTTPS 검증 실패 — `SSL_CERT_FILE` 지정 또는 끄기). 토글하면 재시작 없이 실행 중인 프록시, 액티브 프로브, Repeater / Fuzzer / Miner 전송기에 즉시 반영됩니다. `--insecure-upstream`은 해당 세션에만 끈 상태로 시작 |
| `serve_landing` | bool | `true` | 내장 안내 / CA 다운로드 페이지 제공. 리슨 주소로 직접 접속한 경우와, 이미 프록시를 설정한 클라이언트가 예약 호스트 `http://gori.proxy/`(또는 `http://gori/`)로 접속한 경우 모두 해당 |
| `connect_timeout_secs` | integer | `30` | 업스트림 연결 타임아웃(초, 최소 `1`) |
| `io_timeout_secs` | integer | `30` | 업스트림 읽기 / 쓰기 유휴 타임아웃(초, 최소 `1`) |
| `capture_max_mib` | integer | `2` | 메시지당 저장하는 본문의 최대 크기(MiB). 더 큰 본문도 바이트 그대로 전달되며, 잘리는 것은 저장본뿐이고 실제 전송 크기는 기록됩니다 |
| `http2` | string | `"auto"` | `auto`는 원 서버의 ALPN을 반영하고, `off`는 모든 터널 연결을 HTTP/1.1로 강제합니다. 아래 [http2](#http2)를 참고하세요 |
| `strip_alt_svc` | bool | `false` | HTTP/3을 광고하는 `Alt-Svc` 응답 필드를 클라이언트에 도달하기 전에 제거하므로, 브라우저가 gori가 나르지 않는 전송으로 넘어갈 수 없습니다. 아래 [strip_alt_svc](#strip-alt-svc)를 참고하세요 |
| `tls_passthrough` | array | `[]` | 복호화하지 않고 그대로 중계할 호스트 목록. 아래 [tls_passthrough](#tls-passthrough)를 참고하세요 |

CLI `--listen` / `--port`는 현재 프로세스에 한해서만 이 값들을 오버라이드합니다(디스크에 기록되지 않음). [프로젝트별 오버라이드](#per-project-overrides)를 참고하세요.

#### http2 {#http2}

`auto`(기본값)는 원 서버의 ALPN을 반영합니다 — 원 서버가 HTTP/2를 지원할 때만 클라이언트에 h2를 광고합니다. `off`는 절대 광고하지 않으므로 모든 터널 연결이 HTTP/1.1 경로를 탑니다.

버전을 고정하는 것이 중요한 이유는 h1과 h2의 차이가 시험의 *대상*인 경우가 많기 때문입니다 — 요청 프레이밍, 헤더 이름 처리, 스머글링. 프로토콜을 고정하는 것이 그 차이를 분리하는 방법입니다.

이 설정이 생기기 전에는 구현 세부사항이 유일한 수단이었습니다. gori는 Match & Replace 규칙이 활성일 때 HTTP/1.1로 내려가므로, h1을 강제하려면 아무 동작도 하지 않는 규칙을 켜야 했습니다. 그러면 헤드 재작성도 함께 켜지고, 켜둔 것을 잊기도 쉽습니다.

`off`는 다음 터널 연결부터 적용되며, 원 서버 ALPN 프로브를 아예 생략합니다(원 서버당 연결 1개 절약). 다만 gori가 **정확성을 위해** 여전히 수행하는 다운그레이드는 덮어쓰지 않습니다. 활성 Match & Replace **body** 규칙과 **short circuit** 규칙은 이 설정과 무관하게 HTTP/1.1을 강제합니다. HTTP/2에서 Match & Replace는 헤드에 적용되고, 바디 재작성은 구현되어 있지 않으며 앞으로도 만들지 않습니다(HTTP/2 흐름 제어 때문에 바디 길이를 바꾸는 재작성은 그대로 실패하거나 스트림을 교착시킵니다). 그리고 h2 릴레이는 요청에 로컬에서 응답할 방법이 없습니다. 인터셉트, 헤드 규칙, Sandbox는 이제 아무것도 다운그레이드하지 않습니다. `CONNECT` 안의 평문 HTTP/2(`h2c`) 터널은 `off`일 때 중계하지 않고 거부합니다 — 클라이언트가 preface를 보내며 이미 h2를 확정했으므로 내릴 것이 없습니다.

모든 다운그레이드는 `gori.log`에 호스트당 한 번, 호스트 이름과 어떤 이유가 원인인지를 적습니다. 다운그레이드가 적용되는 동안 HTTP/2 전용 클라이언트(모든 gRPC 클라이언트)는 그 호스트에 연결할 수 없고, 그 이유가 적히는 곳은 이 로그 줄뿐입니다.

`force` 모드는 없습니다. 원 서버가 HTTP/2를 지원하지 않는 것으로 판명될 때의 폴백을 정의해야 하는데 그런 요구가 아직 없었습니다. 문자열 형태로 둔 덕분에 호환성 처리 없이 나중에 추가할 수 있습니다.

#### tls_passthrough {#tls-passthrough}

호스트가 일치하는 CONNECT는 `200`으로 응답한 뒤 불투명한 바이트 터널로 중계됩니다. 해당 호스트용 인증서를 발급하지 않고, 복호화하지 않으며, 아무것도 캡처하지 않습니다. 클라이언트는 gori가 경로에 없는 것과 똑같이 원 서버의 인증서를 직접 검증합니다.

인증서를 피닝하는 클라이언트(모바일 앱, 자동 업데이터, 데스크톱 에이전트)가 실제 대상과 프록시를 공유할 때 쓰는 탈출구입니다. 이 설정이 없으면 그 트래픽은 깨집니다. 스코프로는 해결되지 않습니다 — 스코프는 무엇을 *기록하고* 개입할지를 결정할 뿐 TLS를 가로챌지는 결정하지 않으므로, 스코프 밖 호스트도 복호화됩니다.

같은 경로 위의 **비-HTTP 프로토콜**(MQTT, AMQP, 데이터베이스 와이어 프로토콜 등 첫 바이트가 텍스트가 아닌 것)에 대한 답이기도 합니다. gori의 프록시는 HTTP를 말합니다. 그런 프로토콜을 가리키면 passthrough 없이는 gori가 TLS를 종료한 뒤 HTTP 요청이 아닌 바이트를 만납니다. 이제 그 경우 조용히 멈추지 않고, 관찰한 바이트를 담은 `not an HTTP request` 플로우로 기록하므로 무엇이 도착했는지 보고 passthrough를 택할 수 있습니다. 여기에 호스트를 추가하면 gori는 그것을 바이트 그대로 터널링합니다.

*텍스트* 줄로 시작하는 프로토콜(SSH의 `SSH-2.0-…` 배너, SMTP 인사말)은 **일부러 감지하지 않습니다**. 첫 줄만으로는 의도적으로 malformed하게 만든 요청 라인과 구분할 수 없고, gori는 그런 페이로드를 추측 대신 그대로 전달하기 때문입니다. 그런 연결은 여전히 head 타임아웃을 기다립니다. 이 경우에도 passthrough를 쓰세요.

판단할 바이트 자체가 없는 두 가지 경우도 여기로 옵니다. **서버가 먼저 말하는** 프로토콜(SMTP, IMAP, POP3, MySQL — *서버*가 먼저 인사)은 클라이언트가 접속만 하고 한 바이트도 보내지 않으므로 분류할 대상이 없습니다. 이제 읽기가 타임아웃되면 그 형태를 이름 붙인 `no request` 플로우로 기록되며, 예전처럼 조용히 죽지 않습니다. 리버스·트랜스페어런트 리스너에서는 그 플로우가 클라이언트가 향하던 원 서버를 이름으로 담습니다 — 리버스는 선언된 원 서버, 트랜스페어런트는 플랫폼이 답해 주는 커널 리다이렉트 정보입니다. 리다이렉트된 `:25`이나 `:143`이라면 그 이름이 곧 진단이자 여기에 등록할 호스트입니다. socks5 리스너에서는 핸드셰이크가 거기까지 진행된 경우 클라이언트가 요청한 목적지를 이름으로 담습니다. 그 전이라면 담을 이름 자체가 없습니다. 포워드 프록시 리스너에는 기록할 이름이 없으므로(이름을 실어 올 바이트가 도착하지 않았으므로) 그 경우의 안내는 해당 포트에서 gori를 빼라는 쪽입니다.

**`CONNECT` 안의 비-TLS 페이로드**(`ssh -o ProxyCommand='nc -X connect proxy:8080 %h %p'` — 흔한 사내 프록시 패턴)는 완성될 수 없는 TLS 핸드셰이크에 먹여지는 대신, 시작 바이트를 이름 붙인 플로우와 함께 거부됩니다. 호스트를 등록하면 동작합니다 — 등록된 호스트는 무엇을 말하는지 엿보지 않고 바이트 그대로 중계됩니다. 같은 peek이 이제 `h2c` 터널을 첫 바이트가 아니라 `PRI * HTTP/2.0` 프리페이스 전체로 식별하므로, 80 포트로 터널링한 평문 `POST`나 `PROPFIND`도 HTTP/2 릴레이로 넘어가지 않고 다른 해독 불가 페이로드와 똑같이 거부됩니다.

터널링된 원 서버로 향하는 클라이언트와 gori가 TLS 핸드셰이크를 완료할 수 없는 경우(대개 클라이언트가 아직 CA를 신뢰하지 않아서, 인증서를 피닝하는 클라이언트라면 항상) 호스트·포트·사유별로 한 번씩 `gori.log`에 남깁니다. `gori.proxy`의 CA 다운로드 페이지는 제외입니다 — 거기 오는 클라이언트는 애초에 CA를 아직 신뢰하지 않아서 오는 것이므로, 실패가 보고할 결함이 아니라 예상된 첫 단계입니다.

```json
{
  "network": {
    "tls_passthrough": ["updates.example.com", "*.push.apple.com"]
  }
}
```

패턴은 스코프 `host` 룰과 같은 문법입니다. `example.com`은 해당 호스트와 **그 서브도메인**까지 포함하고, `*.push.example.com`은 글롭(서브도메인만, 맨 호스트는 제외)이며, IPv6 리터럴은 대괄호 유무와 무관하게 일치합니다. 대소문자를 구분하지 않습니다. 항목은 호스트만 적습니다 — 스킴, 경로, `:port`가 붙은 항목은 저장 시 거부됩니다(그런 항목은 어떤 것과도 일치할 수 없기 때문입니다).

비어 있으면(기본값) 모두 가로챕니다. 이 설정이 생기기 전 gori의 동작과 같습니다. 평문 HTTP는 영향을 받지 않습니다 — 통과시킬 TLS가 없습니다.

우회된 호스트는 플로우를 남기지 않으므로, gori는 호스트별로 처음 중계할 때 로그에 한 줄을 남깁니다. History에서 빠진 호스트의 이유를 추적할 수 있게 하기 위함입니다. 목록은 Preferences → **Network & Tabs** → **Network** → **TLS passthrough**에서 쉼표로 구분해 편집합니다.

#### strip_alt_svc {#strip-alt-svc}

gori는 HTTP/3을 가로채지 않습니다. QUIC은 UDP이고 gori의 리스너는 전부 TCP 소켓이기 때문입니다. 그래서 원 서버가 `Alt-Svc: h3=":443"`으로 응답하는 것은 클라이언트를 gori가 읽을 수 없는 전송으로 초대하는 셈이고, 남는 것은 그냥 끊겨 버린 History뿐입니다. 이 설정을 켜면 gori는 `h3`(또는 `h3-…` 드래프트)을 광고하는 `Alt-Svc` 필드를 *클라이언트가 받는* 응답에서 제거합니다. HTTP/1.1과 HTTP/2 양쪽 모두에 적용되므로, 클라이언트가 읽는 응답에는 옮겨 갈 곳이 남지 않습니다.

기본값이 꺼짐인 것은 의도한 것입니다. gori가 시키지도 않은 응답 편집을 하는 경우는, 편집하지 *않으면* 자기가 무엇을 캡처했는지에 대해 거짓말을 하게 되는 때뿐입니다. `Sec-WebSocket-Extensions` 제거가 바로 그 경우입니다 — `permessage-deflate`가 협상되면 저장된 모든 프레임이 페이로드인 척하는 deflate 스트림이 되어 버립니다. 반면 그대로 둔 `Alt-Svc`는 gori가 기록하는 어떤 것도 망가뜨리지 않고, 클라이언트가 떠날 수 있다는 뜻일 뿐입니다. 그것은 눈앞의 시험에 대한 판단이므로, 사람이 직접 올리는 스위치로 둡니다.

**꺼 두면, 대신 그 사실을 알립니다.** h3를 광고하는 응답이 제거되지 않은 채 클라이언트에 도달하면, 이제 그 플로우에 증거와 설정을 함께 밝히는 안내가 남습니다 — *"kept 1 Alt-Svc HTTP/3 advertisement (`h3=":443"`) in this response — gori does not intercept HTTP/3, so a client acting on it leaves the proxy for a transport gori cannot see, and whatever it does there is missing from History rather than absent (settings network.strip_alt_svc is off)."* HTTP/1.1과 HTTP/2 양쪽에서, 제거 안내가 뜨던 바로 그 자리에 똑같이 뜹니다. 와이어 위의 바이트는 하나도 바뀌지 않습니다. 원 서버의 헤드는 그대로 클라이언트에 도달하고, 늘어나는 것은 플로우에 붙는 문장 하나뿐입니다. 호스트당 한 번씩 `gori.log`에도 한 줄이 남고, 패시브 프로브의 기존 `tech_http3` 핑거프린트가 여전히 호스트당 한 번 `Alt-Svc: <host> advertised HTTP/3` 이벤트를 올립니다(Probe 탭으로 바로 이동 가능). 즉 "어떤 호스트가 클라이언트를 데려가고 있나"라는 세션 단위 시야는 원래 있던 자리에 그대로 있습니다. 없던 것은 플로우 단위 기록이고, 이번에 채우는 것이 그것입니다 — 아무도 설명해 주지 않는 History의 구멍은 더 할 말이 없던 원 서버와 똑같이 읽히기 때문입니다.

제거는 **필드 단위**이고, h3를 광고하는 필드에만 적용됩니다. `Alt-Svc: clear`는 절대 제거하지 않습니다. RFC 7838 §3에서 그것은 캐시된 대체 경로를 *잊으라는* 지시이며, 여기서 도움이 되는 유일한 표기입니다. 평범한 `h2=":8443"` 대체 경로도 제거하지 않습니다 — 그것은 또 다른 TCP 포트이고, 여전히 gori를 통해 터널링되기 때문입니다.

제거는 Match & Replace보다 *먼저* 실행되므로, 헤더를 도로 넣는 응답 head 규칙이 이깁니다. 호스트 하나를 두고 운영자가 그렇게 말한 것이, 전체를 두고 올린 스위치보다 우선합니다.

HTTP/2에서는 대가가 있습니다. 필드를 하나 제거한다는 것은 gori가 그 응답의 헤더 블록을 다시 인코딩한다는 뜻인데, HPACK의 연결 단위 상태 때문에 그것은 되돌릴 수 없어서, 첫 제거 이후로 gori는 그 연결의 모든 응답 헤드를 다시 인코딩하고 그 연결에 대해서는 원 서버의 HPACK 압축을 포기합니다. 그 시점부터 해당 연결의 raw 프레임 로그에 남는 것은 원 서버의 HPACK이 아니라 gori의 HPACK이며, 플로우에 남는 안내가 그 사실을 그대로 밝힙니다. 트레일러 블록과 PUSH_PROMISE는 건드리지 않습니다. 둘 중 어디에 있는 `Alt-Svc`도 클라이언트가 실제로 따르지 않고, 거기까지 제거하면 원 서버가 원할 때마다 그 래치를 닫아 버릴 수 있기 때문입니다.

응답이 제거된 플로우에는 무엇을 지웠는지 밝히고 지운 값을 그대로 인용한 안내가 남습니다. History 상세 패널, `gori run history --format json`, MCP `get_flow` 도구에서 볼 수 있습니다. 이 스위치가 앗아 가는 것은 우회 경로이지 증거가 아닙니다 — 다만 그 증거가 있는 자리는 옮겨 갑니다. 패시브 프로브는 *저장된* 응답을 읽고 저장된 응답은 gori가 전달한 응답이므로, 제거를 켜고 나면 캡처된 플로우에서는 `tech_http3` 핑거프린트와 그 `Alt-Svc: <host> advertised HTTP/3` 이벤트 줄이 더 이상 뜨지 않습니다. 그 사실이 옮겨 간 자리가 플로우별 안내이고, 애초에 그 이벤트는 이제 일어날 수 없는 우회에 대한 경고였습니다. 영향을 받는 것은 캡처된 트래픽뿐입니다. gori가 스스로 유발한 응답 — Repeater 전송, Fuzz 스윕, Discover 크롤, MCP `send_request`, import — 은 프록시 경로를 지나지 않으므로 원 서버의 `Alt-Svc`를 그대로 갖고 있고 핑거프린트도 그대로 뜹니다. Repeater로 다시 보내 보면 그 광고가 다시 눈앞에 옵니다.

메울 수 없는 것이 셋 있습니다. [`tls_passthrough`](#tls-passthrough)에 등록된 호스트는 복호화되지 않으므로 gori가 편집할 응답 자체가 없습니다. 클라이언트는 `Alt-Svc` 없이도 h3 경로를 알아낼 수 있고 — DNS `HTTPS` 레코드가 그렇습니다 — 응답 쪽 제거로는 거기에 닿지 못합니다. 그리고 콜론 앞에 공백이 있는 필드명(`Alt-Svc : h3=…`)은 이 설정도, gori 자신의 헤더 투영도 인식하지 않습니다. 규격을 지키는 클라이언트도 그 필드는 거부합니다(RFC 9112 §5.1). 이 설정은 Preferences → **Network & Tabs** → **Network** → **Strip HTTP/3 Alt-Svc**에서 켜고 끕니다.

### listeners

기본 `network.bind_host` / `bind_port` 외에 프록시가 추가로 수신할 소켓입니다.

```json
{
  "listeners": [
    { "host": "192.168.1.10", "port": 8081, "mode": "proxy" },
    { "host": "127.0.0.1", "port": 8080, "mode": "transparent", "target_port": 80 },
    { "host": "127.0.0.1", "port": 8443, "mode": "transparent", "target_port": 443 },
    { "host": "0.0.0.0", "port": 9000, "mode": "reverse", "origin": "https://api.example.com" },
    { "host": "127.0.0.1", "port": 1080, "mode": "socks5" }
  ]
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `host` | string | — | 수신 주소. 필수 |
| `port` | integer | — | 수신 포트. 필수 |
| `mode` | string | `"proxy"` | `proxy`, `transparent`, `reverse`, `socks5` 중 하나. 알 수 없는 모드는 항목을 버립니다(`proxy`로 기본 처리하면 LAN 주소에 의도치 않은 포워드 프록시를 노출할 수 있으므로) |
| `target_port` | integer | `80` / `443` | transparent 전용. 클라이언트가 어느 포트로 접속했는지 커널이 알려주지 못할 때 쓸 업스트림 포트. 권고값입니다 — [투명 모드](#transparent-mode) 참고 |
| `origin` | string | — | reverse 전용, 필수. 전달할 절대 `http(s)` URL |
| `rewrite_host` | boolean | `false` | reverse 전용. 전달되는 `Host`를 origin의 authority로 교체 |

모드에 맞지 않는 필드는 무시하지 않고 **거부**합니다 — transparent가 아닌데 `target_port`, reverse가 아닌데 `origin` 또는 `rewrite_host`. 조용히 버리면 하지 않는 일을 하는 것처럼 읽히는 설정이 남기 때문입니다. 그래서 `socks5` 항목은 `host`, `port`, `mode`만 갖습니다. 나머지 세 필드는 전부 다른 두 모드의 것입니다.

기본 bind는 의도적으로 스칼라로 남겨 두었습니다. 그것은 "gori가 수신하는 주소"가 아니라 *클라이언트를 설정해 붙이는 포워드 프록시 엔드포인트*이고, 그건 본질적으로 단일값입니다. 상태바, statusline JSON, capture-status 사이드카, 라이브 rebind가 보고하는 대상은 계속 이것입니다. 추가 리스너는 대신 **인벤토리**로 다룹니다. 하나라도 설정되어 있으면 listen 칩 옆에 `listeners:N` 칩이 나타나고, 모드 · 주소 · origin · 상태를 담은 읽기 전용 목록을 엽니다. 하나라도 떠 있지 않으면 칩은 `listeners:N/M` 빨간색이 됩니다.

이 비대칭은 의도된 것입니다. 기본 bind는 gori가 사용자 몰래 옮길 수 있으므로(포트가 사용 중이면 다음 포트로 넘어갑니다) 알려 줘야 합니다. `listeners`의 주소는 전부 사용자가 직접 적은 것이므로 확인만 하면 됩니다.

추가 리스너가 바인드에 실패해도(특권 포트, 주소 사용 중) 기본 리스너의 캡처는 멈추지 않으며, 실패는 삼키지 않고 기록됩니다 — `listeners:N/M` 칩에 드러나고 목록이 이유를 밝힙니다. 다른 이유로 사용할 수 없는 항목(`origin` 누락, 모드에 맞지 않는 필드)도 실행 집합에서 빠지되 사라지지 않고 같은 목록에 표시됩니다. 기본 주소와 중복되는 항목은 건너뜁니다.

이 섹션은 시작할 때 읽고 **라이브로 반영하지 않습니다**. 편집한 뒤 저장하면 재시작이 필요하다는 알림이 뜹니다.

#### 투명 모드 {#transparent-mode}

투명 리스너는 자신이 원 서버와 통신한다고 믿는 클라이언트를 상대합니다. `CONNECT`도 절대 경로 대상도 없으므로 gori가 연결마다 목적지를 복구해야 하고, 서로 다른 절반을 답해 주는 두 출처를 씁니다.

**커널**은 리다이렉트 규칙이 목적지를 바꾸기 전에 클라이언트가 어디로 접속했는지를 여전히 기억하고 있고, gori는 연결마다 한 번 그것을 묻습니다.

- **Linux** — `getsockopt(SOL_IP, SO_ORIGINAL_DST)`, v6 연결이면 `SOL_IPV6` 형태. 항상 사용할 수 있으며, 리다이렉트로 들어온 연결이 아니면 그냥 답이 없을 뿐입니다.
- **macOS** — `/dev/pf`에 대한 `DIOCNATLOOK`. 이 디바이스는 root 전용이라 gori 자체가 root로 실행될 때만 동작합니다.

이 답은 **주소와 포트**입니다. 포트는 결정적입니다. 클라이언트가 실제로 연결한 포트이므로 `target_port`보다도, 클라이언트의 `Host` 헤더에 적힌 포트보다도 우선합니다. 주소는 클라이언트가 목적지를 뭐라고 불렀든 gori가 실제로 **접속하는** 곳입니다.

**클라이언트가 보낸 바이트**는 이름을 제공합니다 — 평문은 `Host` 헤더, HTTPS는 핸드셰이크 **이전에** ClientHello에서 읽는 TLS **SNI**. 이름이 있으면 gori는 계속 이름을 씁니다. 이후 모든 결정이 이름을 필요로 하기 때문입니다 — 발급할 leaf 인증서, 샌드박스 게이트, [passthrough 목록](#tls-passthrough), 원 서버 ALPN 프로브, 스코프 매칭, 그리고 History에 보이는 값. 커널의 주소가 이름 자리에 들어가는 것은 이름이 아예 없을 때뿐입니다.

그래서 둘은 경쟁하지 않습니다. 이름은 목적지를 식별하고 업스트림으로 바이트 그대로 전달되며, 주소는 어느 기계에 연결될지를 정합니다. `Host`로 거짓말하는 클라이언트도 자기가 요청한 이름의 인증서를 받고 History에도 그 이름으로 남습니다 — 다만 gori의 업스트림 연결을 다른 곳으로 옮기지는 못합니다.

[호스트명 오버라이드](#hostname-overrides)는 커널 주소보다 우선합니다. 이름으로 직접 적어 둔 매핑이기 때문입니다. 투명 모드의 목적지를 다른 곳으로 돌릴 수 있는 경로는 이것 하나뿐이고, 그러려면 본인 테이블에 항목을 넣어야 합니다.

어느 쪽이 목적지를 정했는지는 리스너마다 한 번(그리고 이후 바뀌면 다시 한 번) 로그에 남습니다. 목적지가 이상해 보일 때 추측하지 않고 따라갈 수 있도록.

방화벽으로 트래픽을 보내세요. Linux:

```bash
iptables -t nat -A OUTPUT -p tcp --dport 80  -j REDIRECT --to-port 8080
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 8443
```

macOS는 `pf`의 `rdr` 규칙을 사용합니다.

**`target_port`가 아직 있는 이유.** 커널 조회가 항상 답하지는 않습니다. Linux와 macOS 밖에는 수단 자체가 없고, macOS는 root가 필요하며, 리다이렉트 없이 리스너에 직접 들어온 연결은 복구할 이전 목적지가 없습니다. `target_port`는 그런 경우를 위해 적어 두는 폴백입니다 — 리다이렉트 규칙의 의도를 명시해 두는 것이라, `:443` 트래픽을 받는 리스너는 `target_port: 443`을 지정합니다. 커널이 답한 경우에는 이 값을 보지 않습니다.

**커널이 답하지 않을 때.** 위의 모든 것은 조회가 없던 시절의 동작으로 되돌아갑니다. 이름을 DNS로 해석하므로 `Host`로 거짓말하는(또는 오해를 부르는 SNI를 보내는) 클라이언트가 업스트림 dial을 원하는 호스트로 돌릴 수 있고, 포트는 `target_port`가 정합니다. 수단이 없는 플랫폼, root가 아닌 macOS, 그리고 리다이렉트 없이 리스너에 직접 들어온 연결이 여기에 해당합니다. 어느 출처가 정했는지는 로그에 남으므로 지금 어느 쪽인지 확인할 수 있습니다. 클라이언트가 흔들 수 없는 목적지가 배포 형태상 필요하다면 [reverse 모드](#reverse-mode)를 쓰세요. 목적지를 선언하고 클라이언트가 보낸 것은 아무것도 보지 않으며, 플랫폼도 root도 가리지 않습니다.

그 밖의 동작은 프록시 경로와 완전히 동일합니다. 플로우는 같은 프로젝트에 캡처되고, 스코프와 샌드박스가 적용되며, passthrough 목록도 지켜집니다. **SNI 없는** TLS 연결은 커널이 주소를 알려주면 이제 처리됩니다(gori가 그 IP로 leaf를 발급합니다). 주소도 없을 때만 끊고 한 번 로그를 남깁니다. 샌드박스가 배제한 호스트는 여전히 그냥 끊습니다 — TLS 클라이언트에게 403으로 답할 방법이 없기 때문입니다.

#### 리버스 모드 {#reverse-mode}

리버스 리스너도 자신이 원 서버와 통신한다고 믿는 클라이언트를 상대하지만, 원 서버가 유도되는 것이 아니라 **선언**됩니다. gori가 원 서버인 것처럼 응답하고 `origin`으로 전달합니다.

```json
{ "host": "0.0.0.0", "port": 9000, "mode": "reverse", "origin": "https://api.example.com" }
```

프록시를 아예 지정할 수 없는 클라이언트를 위한 모드입니다. 프록시 설정이 없는 모바일 앱, CI 단계, 어플라이언스 같은 것들. `CONNECT`도, 프록시 설정도, 방화벽 규칙도 필요 없습니다 — 클라이언트가 이 소켓에 닿기만 하면 됩니다.

목적지가 유도가 아니라 설정이므로 투명 모드의 실패 모드가 없습니다. `Host` 헤더가 없는 요청도 처리합니다. 다른 곳을 가리키는 `Host`가 와도 처리하고, 그대로 `origin`으로 전달합니다 — 라우팅에 그 헤더를 보지 않습니다.

`origin`은 `http` 또는 `https` 스킴을 가진 절대 URL이어야 하고, 포트는 스킴에서 기본값을 취합니다. `api.example.com:8443` 같은 형태는 `http`로 가정하지 않고 거부합니다 — 그 가정이 gori가 원 서버와 TLS로 말할지를 조용히 결정해 버리기 때문입니다. gori 자신의 기본 bind나 다른 리스너를 가리키는 origin은 저장 시점에 거부합니다. 타이핑만으로 만들 수 있는 전달 루프이기 때문입니다.

**TLS.** 클라이언트가 TLS로 열면 리스너가 종단하며, 클라이언트의 SNI가 아니라 **설정된** origin 호스트 이름으로 leaf 인증서를 발급합니다 — SNI를 읽으면 이 모드가 없애려는 유도를 그대로 되살리게 됩니다. 실무적으로는 클라이언트가 origin의 이름으로 이 소켓에 닿아야 한다는 뜻이고, 이는 통상적인 리버스 프록시 구성입니다(hosts 항목이나 DNS 레코드). 원 서버 쪽 연결은 origin의 스킴을 따르므로 `"origin": "http://127.0.0.1:3000"`이면 평문 백엔드 앞에 TLS를 세우게 됩니다.

**`rewrite_host`.** 통상적인 리버스 프록시는 `Host`를 업스트림 이름으로 바꿉니다. gori는 그것을 암묵적으로 하지 않습니다. 재작성은 라이브 경로에서 클라이언트가 보낸 바이트를 변형하는 일이므로 명시적으로 켜야 합니다. `rewrite_host: false`(기본값)이면 클라이언트의 `Host`가 바이트 그대로 원 서버에 도착합니다. 켜면 `Host`가 origin의 authority로 교체되고, 나머지 헤드는 그대로이며 중복된 `Host`는 하나로 합쳐집니다.

스코프는 다른 곳과 같습니다. 샌드박스와 `exclude` 룰은 그대로 적용되고, 요청마다 그리고 TLS 핸드셰이크 전에 검사합니다. `include` 목록은 여기서는 게이트가 아니라 캡처된 트래픽을 보는 렌즈로 남습니다 — 리버스 리스너는 클라이언트가 보낸 것을 전달할 뿐 스스로 요청을 만들지 않기 때문입니다.

#### SOCKS5 모드 {#socks5-mode}

SOCKS5 리스너(RFC 1928)는 목적지를 핸드셰이크에서 클라이언트로부터 받고, 그 뒤에 오는 것을 전부 가로챕니다 — TLS든, HTTP/2 prior knowledge든, 평문 HTTP든, 다른 리스너들과 마찬가지로 첫 바이트를 보고 갈라서 처리합니다. (한 가지는 의도적으로 다릅니다. 여기서는 TLS 판정을 한 바이트가 아니라 두 바이트로 합니다 — SOCKS 리스너는 HTTP가 아닌 프로토콜이 도착할 가능성이 가장 큰 곳이고(`ssh -D`가 대표적입니다), 첫 옥텟이 우연히 `0x16`인 페이로드를 끝낼 수 없는 TLS 핸드셰이크에 넘겨서는 안 되기 때문입니다.)

```json
{ "host": "127.0.0.1", "port": 1080, "mode": "socks5" }
```

프록시를 지정할 수는 있지만 HTTP 프록시는 지정할 수 없는 클라이언트를 위한 모드입니다. `ALL_PROXY=socks5://127.0.0.1:1080`, 프록시 설정이 SOCKS뿐인 런타임, SOCKS만 할 줄 아는 도구 같은 것들. gori는 이미 같은 프로토콜의 반대쪽 끝도 씁니다 — `"kind": "socks5"`인 [`upstream_rules`](#upstream_rules) 항목은 남의 SOCKS 프록시를 *거쳐서* 원 서버에 닿습니다. 같은 단어가 이 문서에 두 번, 서로 반대 방향으로 나오는 셈이고, 이쪽이 들어오는 방향입니다.

목적지가 **선언되어** 도착한다는 점이 투명 모드에 대한 이점입니다. 커널 리다이렉트 규칙이 필요 없고, SNI나 `Host` 헤더에서 목적지를 복구할 일도 없습니다. 평문 연결에서는 `Host`가 다른 곳을 가리키는 요청도 핸드셰이크가 말한 곳으로 나가고, History가 기록하는 authority도 핸드셰이크 쪽이며, 클라이언트의 헤더 자체는 바이트 그대로 전달됩니다. TLS 연결에서는 *이름*을 SNI가 대신 공급합니다 — leaf 인증서가 그 이름으로 발급되고, passthrough 목록과 샌드박스도 그 이름으로 매칭하며, History에 보이는 것도 그 이름입니다 — 그리고 연결은 핸드셰이크가 선언한 목적지로 dial 합니다. [투명 모드](#transparent-mode)가 이름과 주소를 나누는 것과 같은 구분입니다. SNI가 없는 ClientHello라면 두 가지 모두 선언된 목적지로 떨어집니다.

**NO-AUTH 전용.** gori가 지원하는 방식을 하나도 제시하지 않은 클라이언트에게는 RFC 1928의 `0xFF`로 그렇다고 알려 주고 연결을 닫습니다. 옆에 있는 포워드 프록시 리스너에도 인증이 없고, 비밀번호를 요구하는 SOCKS 리스너는 프로세스의 나머지 부분이 갖지 못한 접근 통제를 가진 척하는 셈이 됩니다.

**CONNECT 전용.** `BIND`와 `UDP ASSOCIATE`는 그냥 끊지 않고 응답 코드 `0x07`로 거부하므로, 클라이언트가 실제 원인을 보고할 수 있습니다. BIND는 클라이언트를 대신해 소켓을 열어야 하고 UDP ASSOCIATE는 데이터그램 릴레이인데, gori의 리스너는 전부 TCP 소켓입니다 — [HTTP/3에 손이 닿지 않는](#strip-alt-svc) 것과 같은 이유입니다.

gori가 `succeeded`로 답하기 전에 두 가지를 검사하고, 각각 연결을 끊는 대신 응답 코드 `0x02`("not allowed by ruleset")로 거부합니다. gori가 서빙 중인 소켓을 가리키는 목적지(이 리스너든, 형제 리스너든, 기본 bind든 — 이 프록시를 자기 자신을 거쳐 dial 하게 됩니다), 그리고 샌드박스가 배제하는 호스트입니다. 두 게이트는 같은 이유로 포워드 프록시의 `CONNECT` 경로에도 있습니다. 이 두 리스너에서는 클라이언트가 목적지를 대놓고 지목하지만, 투명 리스너는 커널이 먼저 정하고 그것이 없을 때만 클라이언트가 말한 쪽으로 떨어지기 때문입니다.

거부는 **모두** 이유를 담은 플로우로 프로젝트에도 기록됩니다. 잘못된 포트를 가리킨 클라이언트, UDP를 요청한 클라이언트, 애초에 SOCKS가 아닌 것으로 연결을 연 클라이언트 — 전부 이유 없이 닫힌 연결로 남지 않고 History에 나타납니다.

### upstream_rules

`network.upstream_proxy`는 catch-all 경로입니다. `host:port`, `http://…`(기존 `https://…` 표기 포함)는 HTTP CONNECT 프록시를 사용합니다. `socks5://…`는 대상 이름을 **로컬에서** 해석해 주소 리터럴을 보내고, `socks5h://…`는 호스트 이름을 `ATYP DOMAIN`으로 보내 **프록시가** 해석합니다. 둘 다 기본 포트는 1080입니다. URI 자격증명은 거부됩니다. Project 탭에서 직접 자격증명을 설정하거나 `username`과 `password_env`를 가진 `upstream_rules` 항목을 사용하세요.

캡처·재전송·스캔 엔진, 업데이트 확인, OAST 제공자 통신을 포함해 gori가 소유한 모든 네트워크 연결은 이 라우팅 결정을 사용합니다. 설정된 프록시가 잘못되었거나 연결할 수 없거나 터널을 거부하면 직결로 재시도하지 않고 실패합니다. 빈 프로젝트 고정값과 일치하는 `direct` 규칙은 명시적인 운영자 예외로 유지됩니다.

목적지별 규칙은 "`*.corp.internal`은 사내 프록시로, 나머지는 직결"을 표현하고 자격증명을 실으며 서로 다른 프록시를 선택할 수 있습니다.

규칙은 **순서가 있고 첫 일치가 이깁니다**. 구체적인 규칙을 위에 두세요. 편집은 `gori settings --edit`.

```json
{
  "upstream_rules": [
    { "host": "intranet.corp.internal", "kind": "direct" },
    {
      "host": "*.corp.internal",
      "kind": "http",
      "addr": "proxy.corp.internal:3128",
      "username": "alice",
      "password_env": "CORP_PROXY_PASS"
    },
    { "host": "*.onion", "kind": "socks5h", "addr": "127.0.0.1:9050" }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `host` | string | 호스트 패턴. 스코프 `host` 룰과 같은 문법 — `corp.internal`은 해당 호스트와 서브도메인, `*.corp.internal`은 글롭, `*`는 catch-all. 대소문자 무관 |
| `kind` | string | `direct`, `http`, `socks5`(로컬 DNS), `socks5h`(프록시 DNS). 알 수 없는 kind는 규칙을 버립니다(`direct`로 취급하면 의도한 프록시를 조용히 비활성화하게 되므로) |
| `addr` | string | 프록시 `host:port`. 포트 기본값은 `http`가 `8080`, 두 SOCKS kind가 `1080`. `direct`에는 없어야 합니다 |
| `username` | string | 선택. `http`는 HTTP Basic(RFC 7617), 두 SOCKS kind는 RFC 1929 교환으로 전송 |
| `password_env` | string | 선택. 비밀번호를 담은 **OS 환경변수의 이름** |

**전역 규칙 비밀번호는 `settings.json`에 저장되지 않습니다.** 사용자명과 환경변수 *이름*만 기록되고, 비밀번호는 dial 시점에 OS 환경에서 읽습니다. 따라서 `export CORP_PROXY_PASS=…`가 재시작 없이 반영됩니다. gori 자체의 `env` 섹션은 의도적으로 쓰지 않습니다 — 그 변수들은 `settings.json`에 평문으로 저장되므로, 결국 다른 경로로 비밀을 파일에 넣는 셈이고 설정 공유·내보내기([#439](https://github.com/hahwul/gori/issues/439))를 무의미하게 만듭니다. `$`가 포함된 `password_env`는 거부됩니다 — 값이 아니라 변수 이름을 담는 필드입니다. Project settings에서 직접 입력한 자격증명의 저장 방식은 [프로젝트별 오버라이드](#per-project-overrides)를 참고하세요.

스칼라와 규칙은 같은 DNS 구분을 사용합니다. `socks5`는 gori 호스트에서 대상 이름을 조회하고, `socks5h`는 프록시에 조회를 맡깁니다. Tor, 분할 DNS, 로컬에서 해석할 수 없는 이름을 아는 점프호스트에는 `socks5h`를 사용하세요. 로컬 조회가 실패하면 프록시에 연결하기 전에 중단되며 원 서버 직결로 폴백하지 않습니다.

우선순위(높은 것부터):

| 우선순위 | 출처 |
|----------|------|
| 1 (최상) | 프로젝트 `net.upstream_proxy` — 명시적 프로젝트 고정으로, 테이블을 통째로 건너뜁니다 |
| 2 | `upstream_rules`의 첫 호스트 일치 |
| 3 | `network.upstream_proxy` — 암묵적 catch-all |
| 4 (최하) | 직접 연결 |

규칙은 [호스트 오버라이드](#hostname_overrides) 적용 **이전의 원래 호스트명**에 대해 매칭됩니다 — 오버라이드는 어느 IP로 접속할지만 바꿉니다.

### outbound_tls

gori가 **거는** 연결의 목적지별 TLS 정책입니다 — 제시할 클라이언트 인증서, 협상할 프로토콜 범위와 암호군, 그리고 gori가 보내는 ClientHello의 형태([TLS 지문](#tls-fingerprint)). 순서가 있고 첫 일치가 이기며, 호스트 패턴 문법은 동일합니다. 편집은 `gori settings --edit`.

[`upstream_rules`](#upstream_rules)와 의도적으로 분리된 테이블입니다. 둘 다 목적지 호스트로 키를 잡지만 답하는 질문이 다르고, 합치면 가장 흔한 형태를 표현할 수 없게 됩니다 — "전부 사내 프록시 경유 + 한 호스트만 클라이언트 인증서"를 쓰려면 그 호스트 행에 프록시 주소를 중복해야 합니다. 하나의 first-match 테이블은 호스트당 한 행만 적용할 수 있기 때문입니다.

```json
{
  "outbound_tls": [
    {
      "host": "mtls.example.com",
      "client_cert": "/home/you/certs/client.crt.pem",
      "client_key": "/home/you/certs/client.key.pem"
    },
    {
      "host": "legacy-appliance.internal",
      "min_version": "tls1.0",
      "ciphers": "ALL:@SECLEVEL=0",
      "permissive": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `host` | string | 호스트 패턴. `upstream_rules`와 동일하며 `*`는 catch-all |
| `client_cert` | string | 제시할 PEM 인증서 체인 경로(상호 TLS) |
| `client_key` | string | 대응하는 PEM 개인키 경로. 둘 다 있어야 하거나 둘 다 없어야 합니다 |
| `min_version` | string | 협상할 최저 프로토콜: `tls1.0`, `tls1.1`, `tls1.2`, `tls1.3`. 비우면 기본값 |
| `max_version` | string | 협상할 최고 프로토콜. 값은 동일하며 비우면 기본값 |
| `ciphers` | string | TLS 1.2 이하용 OpenSSL 암호군 목록. 비우면 기본값 |
| `permissive` | bool | 망가진/레거시 서버 상대: OpenSSL security level을 0으로 낮추고 재협상을 허용합니다 |
| `preset` | string | 이름 붙은 브라우저 근사치: `chrome`, `firefox`, `safari`, `curl`. [TLS 지문](#tls-fingerprint) 참고 |
| `groups` | string | 지원 그룹/커브와 그 순서. 예: `X25519:P-256:P-384`. 비우면 기본값 |
| `sigalgs` | string | 서명 알고리즘과 그 순서. 예: `ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256` |
| `ciphersuites` | string | **TLS 1.3** 스위트. `ciphers`로는 닿을 수 없는 영역입니다 |
| `alpn` | array | 순서가 있는 ALPN 목록. 예: `["h2", "http/1.1"]`. `h2`와 `http/1.1`만 허용 — origin이 고른 것을 gori가 말할 수 있어야 합니다 |
| `session_tickets` | bool | `false`면 hello에서 `session_ticket` 확장을 뺍니다. 생략 = OpenSSL 기본값(켬) |
| `ocsp_stapling` | bool | `true`면 `status_request` 확장을 추가합니다 — 브라우저는 보내고 순정 OpenSSL은 보내지 않는 확장입니다. 생략 = 끔 |

**`min_version`이 필요한 이유.** gori는 기본 상태로 TLS 1.0/1.1만 지원하는 장비에 접근할 수 없고, `verify_upstream: false`로도 해결되지 않습니다 — 그건 인증서 *검증*을 끄는 것이지 프로토콜 협상과 무관합니다. Crystal의 TLS 클라이언트 컨텍스트가 생성자에서 TLS 1.0과 1.1을 비활성화하므로, 여기서 하한을 낮추는 것이 유일한 방법입니다. 레거시 장비는 보통 `permissive: true`도 함께 필요합니다 — 배포판이 OpenSSL을 옛 암호군을 아예 거부하는 security level로 빌드하기 때문입니다.

**인증서는 인라인 값이 아니라 파일 경로입니다.** 개인키는 공유·내보내기 대상인 `settings.json`에 들어갈 것이 아닙니다([#439](https://github.com/hahwul/gori/issues/439)). 패스프레이즈가 걸린 키는 저장 시 거부됩니다 — OpenSSL이 TUI가 점유한 터미널에 패스프레이즈를 물어보므로, gori가 그냥 멈춘 것처럼 보이게 됩니다. `openssl pkey -in key.pem -out plain.pem`으로 먼저 복호화하세요.

정책은 SNI 오버라이드가 아니라 **실제 접속한 호스트**로 조회합니다 — 인증서와 프로토콜 하한은 실제로 대화하는 장비에 속하는 반면, Repeater의 SNI 필드는 도메인 프론팅·vhost 테스트를 위해 의도적으로 이름을 다르게 보내는 기능입니다.

#### TLS 지문 {#tls-fingerprint}

프록시를 물리면 origin이 보는 ClientHello는 **브라우저가 아니라 gori의 OpenSSL 핸드셰이크**입니다. 안티봇 스택은 그 핸드셰이크를 JA3/JA4로 찍어서, 조금 전까지 멀쩡하던 트래픽에 챌린지나 `403`을 내주기 시작합니다 — 흔히 겪는 *"브라우저에선 되는데 프록시 끼면 막힘"*이 이것입니다. 위 필드들이 그 손잡이이고,

```bash
gori settings tls-fingerprint
```

가 확인 수단입니다. 실제 dial이 만드는 것과 같은 TLS 컨텍스트에서, gori가 각 목적지로 정말 보내는 ClientHello의 JA3/JA4를 출력합니다. OpenSSL은 *협상 결과*만 알려주므로, 이 명령이 없으면 이 설정들은 검증이 불가능합니다.

```json
{
  "outbound_tls": [
    { "host": "shop.example.com", "preset": "chrome" },
    {
      "host": "api.internal",
      "groups": "X25519:P-256",
      "sigalgs": "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256",
      "ciphersuites": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384",
      "alpn": ["h2", "http/1.1"],
      "ocsp_stapling": true
    }
  ]
}
```

**프리셋은 근사치이며, gori는 그 이상을 주장하지 않습니다.** 프리셋은 분류기가 읽는 *값 수준* 필드를 전부 채웁니다 — 암호군 목록과 순서, TLS 1.3 스위트, 지원 그룹, 서명 알고리즘, ALPN 쌍, 그리고 `session_ticket`/`status_request`가 아예 나타나는지 여부. 하지만 브라우저의 JA3를 바이트 단위로 재현하지는 **않으며**, 할 수도 없습니다:

- **확장 순서**는 OpenSSL의 것이고, OpenSSL은 자기 고정 순서로만 내보냅니다. JA3는 그 순서를 해시합니다.
- **GREASE**([RFC 8701](https://datatracker.ietf.org/doc/html/rfc8701)) 배치도 OpenSSL의 것입니다. 두 지문 모두 GREASE 값을 걸러내지만, 브라우저가 그것을 끼워 넣는 위치는 OpenSSL이 고르는 위치와 다릅니다.
- **포스트 퀀텀 키 셰어**(`X25519MLKEM768`) — 현재 Chrome·Firefox가 가장 먼저 제안하는 것 — 는 프리셋에서 의도적으로 뺐습니다. OpenSSL 3.5 이상에만 있고, 구버전 빌드에서 적용 자체가 실패하는 프리셋은 정직하게 불완전한 프리셋보다 나쁩니다. 빌드가 지원한다면 규칙의 `groups`에 직접 넣으세요.
- **SHA-1 서명 알고리즘** — Firefox와 Safari가 목록 맨 뒤에 레거시 폴백으로 아직 넣는 것 — 도 같은 이유로 뺐습니다. Debian·Ubuntu는 SHA-1 서명을 비활성화한 OpenSSL을 배포하므로, 이걸 넣으면 그 환경에서 프리셋 적용 자체가 거부됩니다. 요즘 origin은 이걸 고르지 않습니다.

다이제스트가 아니라 리포트가 출력하는 `JA4_r` 목록을 비교하세요 — 어떤 필드가 아직 다른지는 거기서만 보입니다. 바이트 단위 일치는 확장 순서와 GREASE를 제어할 수 있는 TLS 스택(BoringSSL, rustls, uTLS)이 있어야 하며, 그건 [#822 3단계](https://github.com/hahwul/gori/issues/822)이지 이 필드들이 하는 일이 아닙니다.

규칙 자신의 필드는 프리셋을 **덮어씁니다**. `{"preset": "chrome", "groups": "P-521"}`은 "Chrome 전부 + 내 그룹 목록"입니다.

**ALPN과 두 개의 leg.** gori는 그 소켓에서 자신이 무엇을 말할지에 따라 다른 ALPN을 제안합니다 — 복호화하는 터널에서는 `h2`, 자신이 HTTP/1.1을 말하게 될 leg(평문 포워드 프록시 dial, Repeater, WebSocket)에서는 아예 제안하지 않습니다. 설정한 `alpn` 목록은 앞쪽에서는 그대로 쓰이고, 뒤쪽에서는 `h2`가 **제거**됩니다 — 거기서 origin이 `h2`를 고르면 gori가 HTTP/2 연결에 HTTP/1.1을 써 넣게 되기 때문입니다. `gori settings tls-fingerprint`가 두 leg를 모두 보여주는 이유가 이것입니다.

잘못된 `groups`·`sigalgs`·`ciphersuites`·`alpn` 값은 실제로 그 문자열을 소비할 바로 그 OpenSSL에게 넘겨서 검사합니다. 이 테이블은 앱 안에 편집기가 없으므로(JSON을 직접 고칩니다) 검사는 **시작 시점**에 돌고, 규칙·설정·결과를 함께 알려 줍니다. origin 탓처럼 보이는 핸드셰이크 실패로 남겨 두지 않습니다:

```
⚠ settings: outbound TLS `groups` is not a group list this OpenSSL accepts: X25519:P-257 — the rule for api.internal; TLS dials to that destination will fail
```

TUI에서는 같은 문장이 알림으로 뜹니다. 잘못된 규칙은 그 목적지에만 영향을 주며, 나머지 규칙과 gori의 다른 기능은 그대로 동작합니다.

**이 테이블은 목적지 단위이고, 지문 A/B는 그렇지 않습니다.** "이 엔드포인트가 `chrome`일 때와 `curl`일 때 다르게 답하나?"는 같은 호스트 하나에 대한 질문이며, 전송 사이에 여기 규칙을 고치면 그 호스트로 가는 다른 모든 탭과 백그라운드 캡처의 핸드셰이크까지 함께 바뀝니다. 대신 Repeater 탭(`␣T`)과 fuzz 실행(`--tls-preset`)이 각자 자기 지문을 지정할 수 있고, dial 시점에 해석되며 이 테이블은 건드리지 않습니다 — [전송 단위 TLS 지문](/ko/reference/cli/#per-send-tls-fingerprints) 참고. 그런 오버라이드는 ClientHello 모양만 교체합니다. 여기 설정한 `client_cert`/`client_key`, `min_version`/`max_version`, `permissive`는 그대로 적용됩니다.

인바운드 지문 *위장*(클라이언트 자신의 핸드셰이크를 다른 것처럼 보이게 하는 것)은 이 섹션의 범위가 아닙니다 — 여기서는 gori가 거는 연결의 모양만 다룹니다.

### layout {#layout}

영역별 TUI 레이아웃 환경설정 (커맨드 팔레트 → **Settings: Layout**). 두 값 모두 공장 기본값이면 생략됩니다.

```json
{
  "layout": {
    "history_preview": false,
    "probe_preview": false,
    "issues_preview": false,
    "history_list_order": "newest",
    "sitemap_expand_depth": -1
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `history_preview` | bool | `false` | History 목록 페이지가 선택한 플로우의 하단 Req\|Res 미리보기를 표시 |
| `probe_preview` | bool | `false` | Probe 목록 페이지가 선택한 이슈의 하단 요약을 표시 |
| `issues_preview` | bool | `false` | Issues 목록 페이지가 선택한 이슈의 하단 요약을 표시 |
| `history_list_order` | string | `"newest"` | 목록 정렬: `"newest"`(최신이 위) 또는 `"oldest"`(오래된 것이 위) |
| `sitemap_expand_depth` | integer | `-1` | 재로딩 후 Sitemap 트리가 열리는 깊이: `-1` = 모두 펼침; `0`-`3` = 이 깊이보다 얕은 노드만 펼침 |

### statusline {#statusline}

TUI 맨 아래에 선택적으로 추가되는 행입니다 (Preferences → **General** → **Statusline**). 활성화하면 gori가 일정 간격으로 셸 명령을 실행하고 그 stdout을 해당 행으로 렌더링합니다. Claude Code의 상태 표시줄에서 영감을 받은 커스터마이즈 가능한 상태 바라고 생각하면 됩니다. 기본적으로 비활성화되어 있으며, 변경하기 전까지는 이 섹션이 `settings.json`에서 생략됩니다.

```json
{
  "statusline": {
    "enabled": true,
    "command": "printf 'proj:%s flows:%s' \"$(jq -r .project)\" \"$(jq -r .flows)\"",
    "interval": 3,
    "timeout": 10
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | statusline 행 표시 여부 |
| `command` | string | `""` | `/bin/sh -c`로 실행되는 셸 명령. stdout의 첫 줄이 행이 됨. 비어 있으면 `enabled`여도 행 자체를 잡지 않음 |
| `interval` | integer | `3` | 실행 간격 초 (최소 `1`) |
| `timeout` | integer | `10` | 한 번의 실행이 종료되기까지 허용되는 초 (최소 `1`). `interval`보다 커도 됨 |

명령의 stdout은 ANSI/SGR 색상 이스케이프(16색, 256색, truecolor, 그리고 볼드/밑줄 등)를 파싱하므로 색상이 있는 세그먼트를 만들 수 있습니다. 첫 줄만 사용되며, 출력은 터미널 너비로 잘립니다. UI를 절대 막지 않습니다.

`timeout`은 `interval`과 의도적으로 분리되어 있습니다. 실행은 겹치지 않으므로(이전 실행이 끝난 뒤에야 다음 실행을 띄웁니다) `interval`보다 느린 스크립트는 매번 죽는 대신 가능한 만큼만 천천히 갱신됩니다. `timeout`을 초과한 실행은 종료되고 행은 `⋯ (timed out)`이 됩니다.

아무것도 출력하지 못하고 실패한 명령은 행을 비워 두는 대신 종료 상태를 보고합니다 — 명령을 찾지 못했으면 `⋯ (exit 127)`, 시그널로 끝났으면 `⋯ (killed)`. 정상 종료했는데 출력이 없으면 행은 비어 있습니다(스크립트가 그렇게 할 수 있는 정당한 선택입니다). 어느 쪽이든 stderr는 버려집니다.

편집은 즉시 반영됩니다. `command` · `interval` · `timeout`을 저장하면 현재 간격이 끝나기를 기다리지 않고 다음 프레임에 다시 실행합니다.

각 실행은 라이브 세션을 설명하는 JSON 컨텍스트를 stdin으로 받으므로, 스크립트는 gori를 쿼리하지 않고도 프록시 상태를 표시할 수 있습니다:

```json
{
  "version": 1,
  "project": "acme",
  "capturing": true,
  "flows": 1234,
  "proxy": { "host": "127.0.0.1", "port": 8070, "addr": "127.0.0.1:8070" },
  "upstream": "",
  "upstream_rules": 0
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | integer | 컨텍스트 스키마 버전 (현재 `1`) |
| `project` | string | 활성 프로젝트 이름 |
| `capturing` | bool | 프록시가 현재 캡처 중인지 여부 |
| `flows` | integer | 캡처한 플로우 수 |
| `proxy.host` / `proxy.port` / `proxy.addr` | string / integer / string | 프록시가 실제로 리스닝 중인 주소 |
| `upstream` | string | **캐치올** 업스트림 프록시 주소/URI, 직접 연결이면 비어 있음. [업스트림 규칙](#upstream_rules)에 걸린 목적지는 다른 경로로 나가며, 이 필드는 그것을 반영하지 않음 |
| `upstream_rules` | integer | 적용 중인 [업스트림 규칙](#upstream_rules) 수. 0이 아니면 라우팅이 목적지별로 갈라지므로 `upstream` 하나로는 트래픽 경로를 설명할 수 없음 |

### display {#display}

메시지 본문과 화면 요소 설정입니다 (커맨드 팔레트 → **Settings: Display**). 모든 값이 기본값이면 섹션이 생략됩니다.

```json
{
  "display": {
    "detail_pane": "request",
    "history_time_format": "absolute",
    "show_gutter": true,
    "wrap_lines": true,
    "preview_body_kib": 64,
    "resource_meter": true,
    "terminal_title": "project"
  }
}
```

| 키 | 타입 | 기본값 | 설명 |
|-----|------|---------|-------------|
| `detail_pane` | string | `"request"` | History 플로우를 열었을 때 먼저 보여줄 페인: `"request"` 또는 `"response"` |
| `history_time_format` | string | `"absolute"` | History 목록의 시간 열: `"absolute"`(MM-DD HH:MM:SS) 또는 `"relative"`(3s/5m/2h) |
| `show_gutter` | bool | `true` | 메시지 본문 뷰의 줄번호 거터 |
| `wrap_lines` | bool | `true` | 메시지 페인보다 긴 줄을 다음 행으로 접어서 표시(줄번호는 첫 행에만). `false`면 한 줄을 한 행으로 그리고 커서를 따라 가로로 스크롤합니다 |
| `preview_body_kib` | integer | `64` | History 목록 미리보기가 읽는 본문 바이트 수 (표시 전용이며 캡처 상한과는 별개) |
| `resource_meter` | bool | `true` | 하단 바 맨 오른쪽에 표시되는 gori 자신의 CPU/메모리 |
| `terminal_title` | string | `"project"` | 터미널 창 제목: `"project"` → `Gori - <프로젝트> - <탭>`, `"tab"` → `Gori - <탭>`, `"off"` → gori가 제목을 건드리지 않음 (셸이나 tmux에 맡김) |

### hostname_overrides {#hostname-overrides}

전역 다이얼 맵(충돌 시 프로젝트 레벨 오버라이드가 우선). `/etc/hosts`와 같은 개념입니다:

```json
{
  "hostname_overrides": [
    { "host": "api.prod.internal", "ip": "10.0.0.42" }
  ]
}
```

Preferences → **Network & Tabs** → **Network** → **Hostname overrides**에서, 또는 프로젝트별 항목은 Project 탭에서 편집합니다. [Proxy & History](/ko/guide/proxy/#host-overrides)를 참고하세요.

### env {#env}

`$TOKEN` 같은 토큰은 Repeater, Fuzzer, Miner, Intercept, CLI, MCP에서 전송 시점에 확장됩니다:

```json
{
  "env": {
    "prefix": "$",
    "vars": [
      { "key": "TOKEN", "value": "eyJhbGciOi…" }
    ]
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `prefix` | string | `"$"` | 토큰 접두사 (`$KEY`) |
| `vars` | array | `[]` | 전역 키/값 쌍; 프로젝트 변수(Project 탭 → ENV)가 충돌 시 우선 |

[환경 변수](/ko/guide/repeater-and-fuzzer/#environment-variables)를 참고하세요.

### general {#general}

Preferences → **General** → **General**:

```json
{
  "general": {
    "clipboard_osc52": true,
    "confirm_quit": false,
    "repeater_record_history": true
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `clipboard_osc52` | bool | `true` | OSC 52 터미널 이스케이프로 복사. SSH 너머에서도 `y`가 로컬 클립보드에 도달합니다 |
| `confirm_quit` | bool | `false` | 종료 전에 확인 |
| `repeater_record_history` | bool | `true` | **TUI** Repeater 전송을 History에 플로우로 기록(SRC 열 `RPTR`). `gori run repeater send --record-history`와 MCP `send_request{record_history}`는 각자의 호출별 인자를 유지합니다 |

### notifications {#notifications}

백그라운드 작업(Miner, Fuzzer, Probe, Discover)이 결과를 알리는 방식입니다. Preferences → **General** → **Notifications**:

```json
{
  "notifications": {
    "bell": false,
    "toast": true,
    "retention": 100
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bell` | bool | `false` | 백그라운드 작업이 결과를 냈을 때 터미널 벨 울림 |
| `toast` | bool | `true` | 같은 이벤트에 대해 잠깐 나타나는 토스트 표시 |
| `retention` | integer | `100` | 알림 센터가 보관하는 알림 개수 |

### probe {#probe}

```json
{
  "probe": {
    "active_notify": "when-found"
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `active_notify` | string | `"when-found"` | 액티브 스캔의 알림 시점: `"when-found"`, `"always"`, `"off"` |

### discover {#discover}

Discover 실행의 저장된 기본값입니다. discover 옵션을 저장해야 기록되므로 그 전까지는 섹션이 없습니다:

```json
{
  "discover": {
    "containment": "scope-aware",
    "max_depth": 4,
    "concurrency": 20,
    "spider": true,
    "bruteforce": true,
    "extensions": false
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `containment` | string | `"scope-aware"` | 탐색이 벗어날 수 있는 범위: `"same-origin"`, `"scope-aware"`, `"host+subdomains"` |
| `max_depth` | integer | `4` | 스파이더 깊이 상한 |
| `concurrency` | integer | `20` | 동시 요청 수 |
| `spider` | bool | `true` | 응답에서 찾은 링크를 따라감 |
| `bruteforce` | bool | `true` | 워드리스트로 경로 무차별 탐색 |
| `extensions` | bool | `false` | 각 후보의 확장자 변형도 함께 시도 |

### mine {#mine}

Param Miner의 저장된 기본값입니다. mine 옵션을 저장해야 기록됩니다:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `locations` | array | `[]` | 주입 위치: `query`, `form`, `multipart`, `json`, `headers`, `cookies`. 비어 있으면 요청마다 자동 감지 |
| `concurrency` | integer | `10` | 동시 요청 수 |
| `notify` | string | `"when-found"` | `"when-found"`, `"always"`, `"off"` |

### scan_rules {#scan-rules}

직접 만든 Probe 매치 규칙으로, 모든 프로젝트에 걸쳐 전역으로 적용됩니다. 프로젝트 범위 규칙은 대신 프로젝트 데이터베이스에 저장됩니다. Probe → **Rules** → CUSTOM에서 편집합니다:

```json
{
  "scan_rules": [
    {
      "id": "a1b2c3d4",
      "title": "Internal hostname leak",
      "description": "Build-server hostname in a response body",
      "side": "response",
      "region": "body",
      "kind": "regex",
      "pattern": "build-\\d+\\.corp\\.internal",
      "severity": "medium",
      "enabled": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `id` | string | 생성 시 부여되는 무작위 hex 토큰 |
| `title` | string | 발견 항목 제목 |
| `description` | string | 발견 상세에 표시 |
| `side` | string | `request` 또는 `response` |
| `region` | string | `whole`, `header`, `body` |
| `kind` | string | `string`, `regex`, 또는 `exec`(argv — [프로세스 훅](/ko/guide/scripting/#프로세스-훅) 참고) |
| `pattern` | string | 매칭할 리터럴 또는 정규식, `kind`가 `exec`이면 실행할 명령 |
| `severity` | string | `info`, `low`, `medium`, `high`, `critical` |
| `enabled` | bool | 규칙 실행 여부 |

파싱은 관대합니다. `id`, `title`, `pattern`이 없는 항목은 버려지고, 허용 범위를 벗어난 `side` / `region` / `kind` / `severity`는 로드를 실패시키는 대신 가장 안전한 값으로 대체됩니다.

### retention {#retention}

프로젝트가 보관하는 캡처 히스토리의 양입니다.

```json
{
  "retention": {
    "max_flows": 100000
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_flows` | integer | `100000` | 프로젝트당 보관할 최신 플로우의 최대 개수. 초과분은 오래된 것부터 삭제됩니다. `0` = 무제한 |

retention은 **새 기능이 아닙니다** — gori는 프로젝트 DB가 무한히 커지지 않도록 항상 오래된 플로우를 정리해 왔습니다. 이 섹션이 추가하는 것은 그 상한을 **확인하고 변경할 수 있게** 하는 것입니다(이전에는 컴파일 타임 상수였습니다). 기본값은 이미 적용되고 있던 값과 같으므로, 직접 수정하기 전까지 동작 변화는 없습니다.

정리는 캡처 경로에서 수천 건의 insert마다 분산 실행되며, 삭제된 플로우의 WebSocket 메시지와 고아가 된 HTTP/2 프레임까지 연쇄 삭제합니다. 행이 실제로 삭제되면 로그에 한 줄을 남기므로, 사라진 플로우가 버그처럼 보이지 않고 이유를 추적할 수 있습니다.

상한을 올리면 다음 프로젝트 열기부터 적용됩니다. 내리더라도 디스크가 바로 회수되지는 않습니다 — prune은 DB 파일 **내부**의 페이지를 재사용 가능하게 만들 뿐 파일 크기를 줄이지 않으므로, 실제 파일 크기는 프로젝트 피커의 **Compress**(`VACUUM` 실행) 이후에 줄어듭니다.

캡처를 소유하지 않는 표면은 상한과 무관하게 절대 prune하지 않습니다 — `gori mcp`의 스토어, 삭제 미리보기용 개수 집계로만 여는 프로젝트, 새로 생성된 프로젝트.

### oast_providers {#oast-providers}

한 번 정의해두고 모든 프로젝트에서 재사용하는 OAST 프로바이더입니다. 프로젝트 전용 프로바이더는 프로젝트 데이터베이스에 저장되고, 여기 있는 것은 Preferences → **OAST providers**에서 편집하는 전역 목록입니다.

```json
{
  "oast_providers": [
    {
      "id": "3f9a2c11",
      "name": "team interactsh",
      "kind": "interactsh",
      "host": "oast.example.com",
      "token": "…",
      "enabled": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `id` | string | 생성 시 부여되는 무작위 hex 토큰. 직접 수정하지 마세요 |
| `name` | string | OAST 탭에 표시되는 이름 |
| `kind` | string | 프로바이더 종류. 예: `interactsh` |
| `host` | string | 프로바이더 호스트 |
| `token` | string | 프로바이더 인증 토큰(선택) |
| `enabled` | bool | 선택 가능 여부(기본값 `true`) |

프로바이더를 추가하기 전까지 이 섹션은 아예 기록되지 않습니다. `id`, `name`, `kind`, `host`가 빠진 항목은 로드할 때 버려집니다.

### update {#update}

프로젝트 피커의 "update available" 한 줄 안내를 뒷받침하는 시작 시 업데이트 확인입니다. gori가 자동으로 내보내는 유일한 외부 요청이며, 설치 자체는 `gori update`로만 진행합니다.

```json
{
  "update": {
    "check_enabled": true,
    "notified_version": "0.2.0",
    "latest_seen": "0.2.0",
    "checked_at": 1753600000
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `check_enabled` | bool | `true` | `false`로 두면 확인 자체를 건너뜀 |
| `notified_version` | string | `""` | 이미 안내한 최신 버전. 릴리스당 한 번만 표시하기 위한 표식 |
| `latest_seen` | string | `""` | 릴리스 피드에서 마지막으로 확인한 버전 |
| `checked_at` | integer | `0` | 마지막 성공 확인의 unix 초. 하루 동안 결과를 캐시 |

아래 셋은 gori가 관리하는 상태이고, 직접 수정할 값은 `check_enabled`뿐입니다. 기본 설치에서는 섹션 전체가 기록되지 않습니다.

### fuzzer {#fuzzer}

Fuzzer의 Payload 오버레이가 기억하는 워드리스트 경로입니다. 프로젝트 데이터가 아니라 임시 상태입니다.

```json
{
  "fuzzer": {
    "recent_wordlists": ["/usr/share/wordlists/params.txt"],
    "favorite_wordlists": ["/home/me/lists/api.txt"]
  }
}
```

| Key | Type | Description |
|-----|------|-------------|
| `recent_wordlists` | array | 최근 적용한 워드리스트 경로. 최신순이며 최대 10개 |
| `favorite_wordlists` | array | Path 필드에서 별표를 단 경로. 최근 목록보다 먼저 제안됨 |

워드리스트를 적용하거나 별표를 달기 전까지는 기록되지 않습니다.

### 그 외 섹션 {#other-sections}

| Section | Description |
|---------|-------------|
| `theme` | 활성 테마 이름 (기본값 `goridark`). [테마 가이드](/ko/guide/themes/) 참고 |
| `mouse` | 마우스 지원 토글 |
| `pretty_bodies` | 상세 뷰에서 JSON/XML 등의 본문을 pretty-print |
| `editor` | 외부 편집기 `command`와 Markdown 처리 |
| `tabs` | 표시/숨김할 TUI 탭 |
| `hostname_overrides` | 전역 host → IP 다이얼 맵. 위의 [hostname_overrides](#hostname_overrides) 참고 |
| `env` | Env 토큰 접두사와 전역 값. 위의 [env](#env) 참고 |
| `hotkeys` | 키바인딩 오버라이드 (`os` 계층 + `command_modifier` + `bindings`). [단축키 가이드](/ko/guide/hotkeys/) 참고 |
| `hooks` | 외부 프로세스 훅: `timeout_secs`(기본 5, 1~60으로 클램프)는 모든 이음매에서 훅 한 번이 받는 벽시계 예산입니다. [프로세스 훅](/ko/guide/scripting/#프로세스-훅) 참고 |
| `decoder` | 이름 붙인 Decoder 체인. 모든 프로젝트가 공유하며 체인 단계에서 이름으로 부를 수 있습니다(열려 있는 서브탭은 프로젝트 DB에 있습니다) |
| `rewriter` | 전역 Match & Replace 규칙. 모든 프로젝트에 적용되며 각 규칙의 기본 켜짐/꺼짐 상태는 프로젝트가 오버라이드할 수 있습니다. [전역 규칙과 프로젝트 규칙](/ko/guide/proxy/#reusing-a-rule-across-projects) 참고 |
| `colormarker` | 전역 History 행 색상 규칙. `rewriter`와 동일한 전역/프로젝트 분리 구조입니다. 표시 전용이며 트래픽을 수정하지 않습니다. [run colormarker](/ko/reference/cli/#run-colormarker) 참고 |
| `mine` | Param Miner의 저장된 기본값. 위 [mine](#mine) 참고 |
| `saved_views` | 전역 History **뷰** 라이브러리 — 이름 붙은 QL 쿼리를 렌즈로 적용하며, `rewriter`와 같은 전역/프로젝트 분리를 씁니다. [run views](/ko/reference/cli/#run-views) 참고 |
| `companion` | 마스코트 Miss Ring: `enabled`(기본 off), `placement`(`body` \| `bar`), `motion`(`lively` \| `calm`), `notices`. [Settings 가이드](/ko/guide/settings/) 참고 |
| `layout` | History / Probe / Issues 미리보기 + Sitemap 펼침 깊이. 위의 [layout](#layout) 참고 |
| `statusline` | 일정 간격으로 명령을 실행하는 하단 상태 행. 위의 [statusline](#statusline) 참고 |
| `display` | 기본 상세 페인, 목록 시간 형식, 줄번호 거터, `wrap_lines`(긴 줄 접기, 기본 켜짐), 미리보기 본문 상한, `resource_meter`(하단 바 맨 오른쪽 CPU/메모리 표시, 기본 켜짐), 그리고 `terminal_title` |

## 프로젝트별 오버라이드 {#per-project-overrides}

프로젝트는 전역 파일을 수정하지 않고도 자체 네트워크 설정을 고정할 수 있습니다. 이 값들은 프로젝트 데이터베이스에 저장되며(키 `net.bind_host`, `net.bind_port`, `net.upstream_proxy`, `net.upstream_destination_host`, `net.upstream_auth`, `net.connect_timeout_secs`, `net.io_timeout_secs`, `net.capture_max_mib`), **Project** 탭의 **Project settings** 서브탭에서 편집합니다.

**Destination host**는 프록시 라우팅을 대소문자를 구분하지 않는 하나의 호스트 패턴으로 제한합니다. 기본값 `*`는 모든 목적지를 프록시 대상으로 허용합니다. `example.com`은 해당 호스트와 서브도메인을 포함하고, `*.example.com`은 서브도메인만 포함합니다. 도메인, IPv4, IPv6 및 `*` 기반 IP 패턴을 사용할 수 있습니다. 일치하지 않는 목적지는 항상 직접 연결되며 `upstream_rules`나 `network.upstream_proxy`로 폴백하지 않습니다. 이 게이트는 프로젝트가 활성화된 동안 캡처, 재생, 스캐너, 업데이터 및 OAST 트래픽을 포함해 gori가 여는 모든 연결에 적용됩니다.

인증하려면 **Proxy protocol**을 고르고 **Proxy host**와 **Proxy port**를 입력한 뒤 **Proxy auth**를 켜고 **Username**과 **Password**를 입력합니다. **SOCKS5**는 대상 이름을 로컬에서, **SOCKS5H**는 프록시에서 해석합니다. HTTP는 Basic 인증을, 두 SOCKS 프로토콜은 RFC 1929 사용자명/비밀번호 인증을 사용합니다. NTLM은 지원하지 않습니다. 인증을 켜면 표시 중인 업스트림 주소가 전역 설정에서 상속된 값이더라도 항상 프로젝트에 고정됩니다. 따라서 나중에 전역 경로나 목적지 규칙이 바뀌어 자격증명이 다른 프록시로 전송되지 않습니다.

비밀번호는 **Password** 행에 포커스가 있어 편집하는 동안 표시되고, 포커스가 벗어나면 다시 마스킹됩니다. 캡처된 engagement 데이터와 함께 소유자 전용(`0600`) 프로젝트 SQLite 데이터베이스에는 평문으로 저장됩니다. 프로젝트에 비밀을 저장하면 안 되는 경우 `password_env`를 쓰는 전역 `upstream_rules` 항목을 사용하세요. 일치하는 목적지에서는 잘못되거나 업스트림 주소 없이 남은 프로젝트 인증 값이 원 서버 연결 전에 fail-closed 처리됩니다.

타임아웃과 캡처 상한 키는 머신 속성이 아니라 engagement 속성입니다 — 느린 내부 장비는 자체 유휴 타임아웃이 필요하고, 아주 큰 응답을 주는 대상은 자체 캡처 상한이 필요합니다. 어느 쪽이든 전역으로 올리면 다른 모든 프로젝트가 비용을 치릅니다.

**어느 표면에 어느 키가 적용되는가.** bind 키 둘은 gori가 리스닝 소켓을 여는 곳에서만 의미가 있고, 프록시 인증을 포함한 나머지 키는 gori가 밖으로 다이얼하거나 바디를 저장하는 모든 곳에 적용됩니다.

| 표면 | `bind_host` / `bind_port` | 업스트림 / 목적지 / 인증 / 타임아웃 / 캡처 상한 |
|------|---------------------------|-----------------------------------------------------------------------------------|
| TUI (`gori`) | 적용 — 프록시가 고정된 주소로 리슨 | 적용 |
| `gori run capture` | 적용 — 리슨하는 유일한 헤드리스 서브커맨드 (핀이 `--listen`/`--port`보다 우선) | 적용 |
| 그 외 모든 `gori run` 서브커맨드 | 미적용 — 바인딩하는 것이 없음 | 적용 |
| `gori mcp` | 미적용 — 서버가 리슨하지 않음 | 적용 |

열려 있는 프로젝트의 **유효 바인드 / 업스트림**:

| Priority | Source |
|----------|--------|
| 1 (최우선) | 설정되어 있으면 프로젝트 DB `net.bind_host` / `net.bind_port` / `net.upstream_proxy` / `net.upstream_destination_host` / `net.upstream_auth` / 타임아웃 / 캡처 상한 |
| 2 | CLI `--listen` / `--port` (전역 계층의 프로세스 한정 오버라이드) |
| 3 | `settings.json` `network.*` |
| 4 (최하위) | 공장 기본값 `127.0.0.1:8070` / 직접 연결 |

현재 전역 값과 같은 Project 탭 필드를 저장하면 해당 KV 키가 삭제되므로, 프로젝트는 중복을 고정하는 대신 이후의 전역 변경을 계속 상속합니다. **Destination host**에는 전역 대응 값이 없으며, 기본값 `*`를 저장하면 프로젝트 키가 삭제됩니다.

## 프로젝트와 데이터베이스 {#projects-database}

각 프로젝트는 최대 `retention.max_flows`개의 플로우를 보관하며(기본 100,000 — [retention](#retention) 참고), 그보다 오래된 것은 정리되어 파일 크기가 일정 수준에서 유지됩니다. 각 프로젝트는 SQLite 데이터베이스(`crystal-db` / `crystal-sqlite3` 사용)입니다. 여기에는 플로우, WebSocket 메시지, 스코프 규칙, 이슈, match 규칙, HTTP/2 프레임, repeater 및 fuzz 세션, 호스트 오버라이드, sitemap 태그, miner 세션, Probe 이슈가 담기고, 플로우 본문 전체를 훑는 전문 인덱스도 들어 있습니다. 저장하는 요청/응답 본문은 2 MiB로 상한이 걸려 있어, 더 큰 본문은 데이터베이스에서 잘리지만 실제 와이어 크기는 그대로 기록합니다. `--db PATH`로 어떤 프로젝트의 데이터베이스든 직접 지정하거나, `--project NAME`으로 이름이 지정된 프로젝트를 고릅니다.
