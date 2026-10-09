+++
title = "Probe 스캔 룰"
description = "Probe 내장 스캔 룰 전체를 id별로: 무엇을 검사하는지, 범주, 액티브 룰의 플로우당 요청 비용."
weight = 35
+++

[Probe 스캐너](/ko/guide/scanning/#probe-the-scanner)에 내장된 룰을 룰 명령이 받는 id 기준으로 모두 나열합니다. 범주의 뜻과 패시브·액티브 스캔의 차이는 [스캐닝 가이드](/ko/guide/scanning/#probe-the-scanner)에서 설명합니다. 룰 하나를 켜거나 끄기 전에 이 페이지에서 찾아보세요.

여기 있는 목록은 새 프로젝트에서 `gori run probe rules`가 보여 주는 것과 같습니다. 이 명령, Probe 탭의 **Rules** 서브탭, MCP `list_probe_rules` 도구는 모두 같은 카탈로그를 읽습니다. 지금 실행 중인 빌드에서는 이쪽이 기준이고, 커스텀 룰과 이 프로젝트에서 꺼 둔 룰도 함께 보여 줍니다.

## 룰 켜고 끄기 {#managing}

스위치는 프로젝트 단위입니다. 내장 룰을 끄면 새로운 탐지만 멈추고, 이미 만든 발견은 Probe 목록에 그대로 남습니다.

| 어디서 | 방법 |
|---------|-----|
| TUI | Probe 탭 → **Rules** 서브탭: `t`로 커서 아래 룰을 토글하고, `/`로 목록을 필터링합니다 |
| CLI | `gori run probe rules enable <id>` / `disable <id>`. `gori run probe rules --kind active`는 한 종류만 나열합니다 |
| MCP | `set_probe_rule_enabled`, 상태를 읽을 때는 `list_probe_rules` |

```bash
gori run probe rules --kind active          # 액티브 룰과 켜진 룰
gori run probe rules enable sqli_time_based # 꺼진 채 출하되는 룰 켜기
gori run probe rules disable sri            # 시끄러운 패시브 체크 하나 끄기
```

룰 id는 발견 코드와 다릅니다. 룰 하나가 여러 종류의 발견을 올릴 수 있기 때문입니다. `security_headers`는 `missing_hsts`, `missing_csp` 등을 올립니다. `gori run probe issues`가 발견마다 코드를 출력하고, `gori run probe dismiss --code`는 룰 id가 아니라 그 코드를 받습니다.

## 패시브 룰 {#passive}

패시브 룰은 이미 캡처한 트래픽(History 플로우와 Repeater 전송 결과)을 읽기만 하고 아무것도 보내지 않습니다. 모두 켜진 채 출하됩니다.

| ID | 이름 | 범주 | 검사 내용 |
|----|------|----------|----------------|
| `tech` | Technology fingerprints | `tech` | 헤더와 본문에서 서버 소프트웨어, 프레임워크, 프로토콜(WebSocket, gRPC, GraphQL, SSE, HTTP/2, HTTP/3)을 식별합니다. |
| `secret_in_url` | Secrets in URL | `infoleak` | 요청 URL에 실린 자격 증명, 토큰, JWT를 표시합니다. URL에 있으면 로그, 방문 기록, Referer로 새어 나갑니다. |
| `security_headers` | Security headers | `headers` | HSTS, CSP(report-only만 있는 경우와 base-uri 누락 포함), X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, Cross-Origin-Opener-Policy가 없거나 약한지 확인합니다. |
| `mime_confusion` | MIME type confusion | `headers` | 본문 유형이 Content-Type과 어긋나 MIME 스니핑 XSS가 가능한 응답을 표시합니다(nosniff 없이 스니핑 가능한 타입으로 나가는 HTML 본문, text/html로 제공되는 JSON). |
| `cacheable_api` | Cacheable API responses | `headers` | 브라우저나 공유 캐시가 저장할 수 있는 JSON/API 응답을 표시합니다. 토큰이나 개인정보가 남을 수 있습니다. |
| `cookies` | Cookie flags | `cookies` | Set-Cookie 플래그, SameSite 값, Partitioned, 보안 접두사(`__Http-` 포함), 상위 Domain 범위를 확인합니다. |
| `cors` | CORS misconfiguration | `cors` | 와일드카드, null origin, 반사된 origin을 돌려주는 CORS 응답을 표시합니다. |
| `body_leaks` | Response body leaks | `infoleak` | 응답 본문에서 사설 IP, 스택 트레이스, 비밀 값, 혼합 콘텐츠, 안전하지 않은 폼 action을 찾습니다. |
| `auth` | Insecure authentication | `headers` | 평문 http://로 보내는 Basic 인증과 Bearer 토큰을 표시합니다. |
| `graphql_introspection` | GraphQL introspection | `infoleak` | 켜져 있는 GraphQL introspection을 탐지합니다. API 스키마 전체가 드러납니다. |
| `jwt` | JWT weaknesses | `headers` | Authorization/Cookie/Set-Cookie에 실린 JWT를 디코드해 alg:none, 비표준 알고리즘, 키 주입 헤더 파라미터(jku/x5u/jwk), 만료 누락, 민감한 클레임 이름을 표시합니다. |
| `sourcemap` | Source map exposure | `infoleak` | 소스맵을 가리키는 프로덕션 JavaScript를 표시합니다. 소스맵이 있으면 원본 소스를 복원할 수 있습니다. |
| `sri` | Missing Subresource Integrity | `headers` | 지원되는 integrity 메타데이터 없이 불러오는 크로스 오리진 스크립트와 스타일시트를 표시합니다(공급망 노출). |
| `directory_listing` | Directory listing | `infoleak` | Apache/nginx가 자동 생성한 디렉터리 인덱스를 탐지합니다. 누구에게나 파일 목록을 보여 줍니다. |
| `exposed_config` | Exposed configuration files | `infoleak` | 클라이언트에 제공되는 서버 설정·진단 파일을 탐지합니다: .env, .git/config, phpinfo(), .htpasswd, wp-config 자격 증명, Spring actuator env. |
| `serialized_object` | Serialized object exposure | `infoleak` | 쿠키, 파라미터, hidden 필드에 실린 네이티브 직렬화 블롭(Java, .NET BinaryFormatter/ViewState, PHP)을 탐지합니다. 안전하지 않은 역직렬화의 공격 표면입니다. |
| `debug_mode_exposed` | Debug mode exposed | `infoleak` | 프로덕션에서 닿는 프레임워크 디버그 모드, 대화형 디버거, 프로파일러를 탐지합니다(Symfony, Werkzeug/Flask, Django, Laravel, Rails, ASP.NET). |
| `subdomain_takeover` | Subdomain takeover (suspected) | `infoleak` | 호스팅 제공자가 백엔드 리소스가 주인 없는 상태라고 말하는 오류 페이지를 표시합니다(S3/GCS 버킷, GitHub Pages, Heroku, Pantheon, Shopify, Fastly, Azure, Zendesk, Vercel, Tumblr). 공격자가 가져갈 수 있는 dangling DNS 형태입니다. |
| `cleartext_credentials` | Cleartext credential submission | `headers` | http://로 요청 본문에 실려 제출된 비밀번호와, http://로 제공된 비밀번호 입력 필드를 표시합니다. |
| `shared_cache` | Shared-cache exposure | `headers` | 공개적으로 캐시 가능한 응답의 Set-Cookie와, Vary: Origin 없이 캐시된 반사 CORS origin을 표시합니다. |
| `internal_host_leak` | Internal host disclosed in a response header | `infoleak` | 응답 헤더에서 RFC 1918 주소와 내부 전용 호스트명(.local, .internal, .corp 등)을 찾습니다. |
| `ws_payloads` | WebSocket payload secrets | `infoleak` | WebSocket 텍스트·바이너리 프레임에서 노출된 비밀 값을 찾습니다. |
| `dom_xss` | DOM-based XSS (suspected) | `client` | 페이지/번들 스크립트의 같은 문장 안에서 DOM taint 소스(location.hash, document.URL, postMessage 데이터 등)가 실행 싱크(innerHTML, document.write, eval 등)로 흘러가는 경우를 표시합니다. |
| `dom_clobbering` | DOM clobbering (suspected) | `client` | 클로버링될 수 있는 전역을 신뢰하는 클라이언트 코드를 표시합니다: 이름으로 접근하는 HTMLCollection(document.forms[…], document.all[…])이나 window.X = window.X \|\| … 폴백 관용구. |
| `prototype_pollution` | Prototype pollution (suspected) | `client` | `__proto__`/`constructor.prototype`에 쓰거나 오염에 취약한 deep-merge API를 쓰는 클라이언트 코드, 그리고 `__proto__`/`constructor[prototype]` 파라미터를 실은 요청을 표시합니다. |
| `post_message` | Cross-origin messaging (postMessage) | `client` | origin 검사가 없는 message 핸들러, 와일드카드 대상 origin으로 보내는 postMessage(...), document.domain 완화를 표시합니다. |
| `api_docs_exposed` | API documentation exposed | `infoleak` | 프로덕션에서 닿는 Swagger UI, OpenAPI/Swagger 스펙, 대화형 GraphQL IDE(GraphiQL, Playground, ReDoc)를 탐지합니다. |
| `session_id_in_url` | Session identifier in URL | `infoleak` | 요청 URL에 실린 알려진 프레임워크 세션 식별자(PHPSESSID, JSESSIONID, ASP.NET_SessionId 등)를 표시합니다. 로그, 방문 기록, Referer로 새어 나갑니다. |
| `open_cross_domain_policy` | Permissive cross-domain policy | `cors` | 모든 origin에 접근을 허용하는(`domain="*"`) Flash/Silverlight 크로스 도메인 정책을 표시합니다. |
| `bare_lf_response` | Bare-LF response head | `headers` | 응답 헤드의 줄 끝이 CRLF가 아닌 단독 LF인 경우를 표시합니다. 파서마다 메시지 프레이밍을 다르게 읽을 수 있습니다(응답 desync / splitting의 전제 조건). |

## 액티브 룰 {#active}

액티브 룰은 직접 요청을 보냅니다. 자동 파이프라인은 프로젝트 스캔 모드가 `active`나 `aggressive`일 때만 이 룰을 실행합니다. 플로우별 **Run active scan**과 `gori run probe --active`는 어느 모드에서든 실행합니다. 기본적으로 안전한 메서드(`GET` / `HEAD`)만 다시 보내고, 고유한 표면마다 한 번씩만 테스트합니다. 두 룰은 의도적으로 예외입니다. `graphql_introspection_active`는 `POST` 엔드포인트를 `POST`로 유지하고(읽기 전용 쿼리), `insecure_http_methods`는 자체 `OPTIONS`와 `TRACE`를 보냅니다.

**비용**은 룰이 플로우 하나에 보내는 요청 수이며, Rules 서브탭이 행 옆에 보여 주는 값과 같습니다. **비고**는 기본값만으로는 실행되지 않는 룰을 표시합니다.

- **기본 비활성**: 꺼진 채 출하됩니다. 의도적으로 켜세요([위](#managing) 참고).
- **unsafe 필요**: 룰이 보내는 프로브가 모두 안전하지 않은 메서드라, unsafe 메서드를 허용하기 전에는(팝업의 **unsafe methods** 체크, `--unsafe`, AGGRESSIVE 모드) 아무것도 만들지 않습니다.
- **OAST 필요**: 켜져 있지만, 프로젝트에 페이로드를 찍어 낼 [OAST](/ko/guide/oast/) 리스너가 등록되기 전까지는 작동하지 않습니다. 그때까지 그 비용은 추정치에서 빠집니다.

| ID | 이름 | 범주 | 비용 | 비고 | 검사 내용 |
|----|------|----------|------|-------|----------------|
| `reflected_param` | Reflected parameter | `active` | 1 |  | 쿼리·폼·JSON 파라미터에 canary를 보내고, 인코딩되지 않고 반사되면 표시합니다(잠재적 XSS). |
| `cors_reflection` | CORS arbitrary origin | `cors` | 1 |  | 서버가 임의의 Origin을 Allow-Credentials: true와 함께 반사하는지 프로브합니다. |
| `forbidden_bypass` | Access-control bypass (IP headers) | `active` | 2 |  | 거부된(401/403) 요청을 위조한 클라이언트 IP 헤더와 함께 재전송하고, 2xx로 우회되면 표시합니다. |
| `nginx_alias_traversal` | NGINX alias traversal | `active` | 1–2 |  | 정적 자산을 접힌 `..`(/static../static/…) 경로로 다시 가져와, 바이트 단위로 같은 응답이 오면 표시합니다. |
| `backslash_powered` | Backslash-powered scanning | `active` | 4–8 |  | 쿼리·폼·JSON 파라미터마다 `\`와 `\\`를 덧붙여, 백슬래시 하나는 응답을 흔들지만 둘은 그렇지 않은 파라미터를 표시합니다(서버 측 문자열 해석). |
| `sqli_error_based` | Error-based SQL injection | `active` | 3–5 |  | 쿼리·폼·JSON 파라미터마다 SQL 구문을 깨는 페이로드를 덧붙이고, 깨끗한 baseline에는 없는 데이터베이스 오류 서명이 프로브 응답에 나타나면 표시합니다. |
| `sqli_boolean_based` | Boolean-based blind SQL injection | `active` | 4–8 |  | 파라미터마다 항상 참인 SQL 조건과 항상 거짓인 조건을 덧붙여, 참 쪽은 baseline과 같고 거짓 쪽은 달라지는 파라미터를 표시합니다(오류도 반사도 없는 블라인드 인젝션). |
| `sqli_time_based` | Time-based blind SQL injection | `active` | 6–10 | 기본 비활성 | 파라미터마다 서버 측 지연(SLEEP/pg_sleep/WAITFOR)을 주입하고, baseline과 점점 늘린 두 번의 지연에 걸쳐 응답 지연 시간으로 확인합니다. 일부러 기다리기 때문에 기본 비활성으로 출하됩니다. |
| `graphql_introspection_active` | GraphQL introspection (active) | `infoleak` | 1 |  | GraphQL 엔드포인트에 introspection 쿼리를 보내 스키마가 노출되는지 확인합니다. |
| `lfi_param_traversal` | Parameter path traversal | `active` | 3 |  | 파일 파라미터를 접힌 `..`(file=x/../doc) 경로로 다시 가져와, 바이트 단위로 같은 응답이 오면 표시합니다. |
| `open_redirect` | Open redirect | `active` | 1 |  | 리다이렉트 파라미터를 외부 호스트로 바꾸고, Location이 그대로 따라가면 표시합니다. |
| `host_header_injection` | Host header injection | `active` | 1 |  | 합성한 X-Forwarded-Host를 보내고, 그 값이 절대 URL의 authority로 반사되면 표시합니다. |
| `crlf_injection` | CRLF header injection | `active` | 1 |  | 요청 파라미터(쿼리/폼/JSON)에 인코딩된 CRLF와 헤더를 주입하고, 응답 헤더로 반사되면 표시합니다. |
| `path_normalization_bypass` | Access-control bypass (path normalization) | `active` | 6–7 |  | 거부된(401/403) 경로를 정규화 트릭으로 다시 요청하고, 2xx로 우회되면 표시합니다. |
| `url_rewrite_bypass` | Access-control bypass (URL-rewrite headers) | `active` | 3 |  | 401/403/404로 응답한 경로를 X-Original-URL/X-Rewrite-URL에 담아 /를 요청하고, 2xx로 제공되면 표시합니다. |
| `ssti` | Server-side template injection | `active` | 2 |  | 템플릿 산술 폴리글롯을 주입하고, 값이 평가되는 파라미터를 표시합니다. |
| `nextjs_action_no_auth` | Next.js server action missing authorization | `active` | 1 | unsafe 필요 | Next.js 서버 액션(Next-Action)을 세션 쿠키/Authorization을 뺀 채 재전송하고, 여전히 2xx로 성공하면 표시합니다. |
| `request_smuggling` | HTTP request smuggling / desync (CL.TE/TE.CL/TE.TE) | `active` | 8–10 | 기본 비활성 · unsafe 필요 | 불완전한 CL.TE/TE.CL/TE.TE 프레이밍 프로브를 보내고, 타이밍 행으로 프런트엔드/백엔드 디싱크를 표시합니다(aggressive+unsafe에서 차분 확인). 기본 비활성이며 POST 본문을 보냅니다. |
| `ssrf_oast` | Blind SSRF (out-of-band) | `active` | 1 | OAST 필요 | 쿼리, 폼, JSON의 URL 파라미터 하나를 OAST 페이로드로 향하게 하고, 서버가 콜백을 걸면 발견으로 올립니다. |
| `cmd_injection_oast` | Blind OS command injection (out-of-band) | `active` | 1 | OAST 필요 | 명령/진단 파라미터에 셸 브레이크아웃 OAST 페이로드를 덧붙이고, 서버의 셸이 콜백을 걸면 발견으로 올립니다. |
| `xxe_oast` | XML external entity (out-of-band) | `active` | 1 | OAST 필요 · unsafe 필요 | XML 본문에 외부 파라미터 엔티티 하나를 추가합니다. OAST 콜백이 오면 해석된 것으로 확인합니다. unsafe 옵트인이 필요합니다. |
| `rfi_oast` | Remote file inclusion (out-of-band) | `active` | 1 | OAST 필요 | 포함형 파라미터 하나를 언어 표식이 담긴 OAST 리소스로 향하게 하고, 서버가 콜백을 걸면 발견으로 올립니다. |
| `ratelimit_bypass` | Rate-limit bypass (spoofed client IP) | `active` | 2 |  | 레이트리밋에 걸린(429) 요청을 위조한 클라이언트 IP 헤더와 함께 재전송하고, 처리되면 표시합니다. |
| `forbidden_method_bypass` | Access-control bypass (HTTP method) | `active` | 2–5 |  | 거부된(401/403) 리소스를 메서드 대소문자 변형으로, unsafe에서는 대체 메서드와 메서드 오버라이드 헤더로도 다시 요청해 2xx로 우회되면 표시합니다. |
| `insecure_http_methods` | Insecure HTTP methods | `active` | 2 |  | OPTIONS와 TRACE를 보내 Cross-Site Tracing(TRACE)과 Allow 헤더에 광고된 위험한 메서드를 표시합니다. |

## 커스텀 룰 {#custom}

직접 만든 매치 룰은 같은 카탈로그의 `custom` 범주에 `custom_p_7` 같은 id로 들어갑니다. 룰마다 문자열, 정규식, 명령 중 하나로 모든 캡처 플로우의 한 영역을 검사합니다. Rules 서브탭(`a`), `gori run probe rules add`, MCP `create_probe_rule` 도구로 추가합니다. 필드는 [Probe: 스캐너](/ko/guide/scanning/#probe-the-scanner)를, 명령 형태는 [프로세스 훅](/ko/guide/scripting/#process-hooks)을 보세요.
