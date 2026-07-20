+++
title = "설정"
description = "gori가 데이터를 저장하는 위치, 네트워크 설정 방법, 그리고 루트 CA를 다룹니다."
weight = 40
+++

gori는 전역 환경설정을 JSON 설정 파일에 보관하고, 각 프로젝트를 자체 SQLite 데이터베이스로 저장합니다. 이 페이지는 첫날 필요한 핵심만 다룹니다. 무엇이 어디에 있는지, 프록시가 어떻게 바인딩되는지, 클라이언트가 gori의 CA를 어떻게 신뢰하는지입니다. 키 단위 전체 설명은 [설정 레퍼런스](/ko/reference/config/)를 참고하세요.

## gori 홈 디렉터리 {#the-gori-home-directory}

gori가 기록하는 모든 것은 하나의 트리 `GORI_HOME` 아래에 있습니다. 해당 환경 변수가 설정되어 있고 비어 있지 않으면 `$GORI_HOME`으로, 아니면 `~/.gori`로 해석됩니다. 여기에는 `settings.json`(전역 환경설정), `projects/` 아래의 프로젝트 데이터베이스, `ca/`의 루트 CA, 그리고 `themes/`와 `wordlists/`가 담깁니다. 전체 트리는 [저장소 레이아웃](/ko/reference/config/#storage-layout)을 참고하세요.

한 세션 동안 격리된 홈을 사용하도록 gori를 지정하려면:

```bash
GORI_HOME=/tmp/gori-scratch gori
```

## 전역 설정 {#global-settings}

전역 환경설정은 `settings.json`에 저장됩니다. 경로를 출력하거나 `$EDITOR`에서 열려면:

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in your editor
```

파일을 직접 편집할 일은 거의 없습니다. 파일에 담기는 모든 항목은 하나의 화면, **Preferences** 모달에서 편집할 수 있으며, 네 개의 서브탭(General, Appearance, Editor & Keys, Network & Tabs)으로 묶여 있습니다.

| 여는 방법 | 도착 지점 |
|-----------|-----------|
| 어디서나 `Ctrl-,` | 그룹 스트립. 그룹을 먼저 고릅니다 |
| 상단 바의 `⚙` 칩 | `Ctrl-,`와 동일 |
| `Ctrl-P` → **Settings: …** 항목 | 해당 섹션의 필드로 바로 |

`Ctrl-,`는 프로젝트 선택기에서도, 즉 프로젝트를 열기 전에도 동작하므로 첫 실행에서 테마를 정할 수 있습니다. 저장한 변경은 재시작 없이 즉시 적용됩니다. 모든 섹션과 필드는 [설정 가이드](/ko/guide/settings/)를, 그 아래의 키는 [설정 레퍼런스](/ko/reference/config/)를 참고하세요.

## Network {#network}

기본적으로 프록시는 `127.0.0.1:8070`에서 수신하며 대상에 직접 연결합니다. 이를 바꿀 수 있는 곳은 세 군데이며, 우선순위가 높은 순서대로:

1. **프로젝트별** — **Project** 탭에서 한 프로젝트의 바인드 주소, 포트, 업스트림을 고정합니다. 해당 프로젝트에 한해 우선합니다.
2. **CLI 플래그** — `--listen` / `--port`는 현재 프로세스에 한해 전역 기본값을 재정의하며 디스크에 기록되지 않습니다.
3. **`settings.json`의 `network`** — 공유되는 기본값으로, 첫 실행 마법사와 Preferences → **Network**가 편집합니다.

아무것도 설정되지 않으면 공장 기본값은 `127.0.0.1:8070`, 직접 연결입니다. 모든 키는 [network](/ko/reference/config/#network)를, 정확한 우선순위는 [프로젝트별 재정의](/ko/reference/config/#per-project-overrides)를 참고하세요.

## 루트 CA {#the-root-ca}

HTTPS를 인터셉트하려면 클라이언트가 gori의 루트 인증서를 신뢰해야 합니다. 이 인증서는 `~/.gori/ca`에 `root.crt.pem`과 `root.key.pem`으로 보관됩니다.

```bash
gori ca                       # print the certificate path
gori ca --pem                 # print the PEM to stdout
gori ca --ca-dir /path        # use a custom CA directory
gori ca regenerate --yes      # replace the root CA (scripts/CI; voids prior trust)
```

TUI 커맨드 팔레트(**Regenerate CA certificate**)에서, 또는 대화식으로 `gori ca regenerate`(`regenerate`를 입력해 확인)로 CA를 교체할 수도 있습니다. 두 경로 모두 확인 절차를 거치는데, 교체하면 이전에 발급된 모든 신뢰가 무효화되기 때문입니다. 이미 실행 중인 gori는 재시작 전까지 기존 CA를 유지합니다.

### 자체 CA 사용하기 {#bring-your-own-ca}

CA 하나를 팀이나 여러 머신에서 재사용하려면, 루트를 외부에서 생성한 뒤 가져오세요(인증서 **및** 키: gori는 키로 리프 인증서에 서명하고, 클라이언트는 인증서만 신뢰합니다):

```bash
openssl ecparam -genkey -name prime256v1 -out root.key.pem
openssl req -x509 -new -key root.key.pem -days 3650 -subj "/CN=my ca" -out root.crt.pem
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

같은 동작을 팔레트(**Import CA certificate**)에서도 할 수 있습니다. gori는 가져오기 전에 키가 인증서와 일치하는지, 그리고 그 인증서가 CA인지 확인합니다. 신뢰용으로는 `root.crt.pem`만 배포하고, `root.key.pem`은 비밀로 유지하세요. [`gori ca import`](/ko/reference/cli/#gori-ca-import)를 참고하세요.

팔레트의 **Open browser** 동작은 이미 CA를 신뢰하고 프록시를 경유하는 격리된 프로파일로 설치된 브라우저를 실행합니다([빠른 시작](/ko/getting-started/quick-start/) 참조).

## 전체 레퍼런스 {#full-reference}

모든 설정 키는 [설정 레퍼런스](/ko/reference/config/)를, 모든 명령줄 플래그는 [CLI 레퍼런스](/ko/reference/cli/)를 참고하세요.
