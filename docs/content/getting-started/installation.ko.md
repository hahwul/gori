+++
title = "설치"
description = "curl, Homebrew, AUR, Nix, Docker, 사전 빌드 바이너리, 또는 소스에서 gori를 설치합니다."
weight = 10
+++

gori는 [Crystal](https://crystal-lang.org/)로 작성되었습니다. 아래에서 사전 빌드된 채널을 고르거나, 플랫폼에 맞는 것이 없으면 [소스에서 빌드](#build-from-source)하세요. 모든 채널은 동일한 `gori` 바이너리를 설치합니다. 바이너리가 `PATH`에 올라가면 [설치 확인](#verify-the-installation)으로 넘어가세요.

## 빠른 설치 (curl) {#quick-install-curl}

macOS와 Linux용 한 줄 명령입니다. OS/아키텍처를 감지해 알맞은 [GitHub Release](https://github.com/hahwul/gori/releases/latest) 자산을 내려받고 `gori`를 `PATH`에 올립니다:

```bash
curl -fsSL https://gori.hahwul.com/install.sh | bash
```

`/usr/local`에 쓸 수 있으면 그 아래에, 아니면 `~/.local`에 설치합니다. `GORI_INSTALL_PREFIX`로 재정의할 수 있습니다. 설치 후에는 `gori update`가 바이너리를 스스로 업데이트합니다(설치를 담당하는 채널이 Homebrew / Snap / AUR인 경우 그쪽으로 안내합니다).

### GitHub rate limit에 걸린 경우 {#rate-limit}

설치 스크립트는 최신 릴리스가 무엇인지 GitHub API에 묻는데, 이 API는 **비인증 요청을 IP당 시간당 60회**만 허용합니다. 공용 CI나 NAT 뒤에서는 `403`이 돌아올 수 있습니다. 설치 스크립트와 `gori update` 모두 rate limit이 없는 릴리스 리다이렉트로 자동 폴백하므로 그대로 동작하며, `resolved v0.3.2 via ... (no API call)` 같은 줄이 보입니다.

인증 시 한도인 5000회/시간을 쓰려면 토큰을 먼저 export하세요. `curl` 앞에 붙이면 안 되고 반드시 export해야 합니다 — 스크립트는 파이프로 연결된 `bash`에서 실행되므로 `curl`에만 걸린 변수는 상속되지 않습니다:

```bash
export GITHUB_TOKEN=<personal access token>
curl -fsSL https://gori.hahwul.com/install.sh | bash
```

`GORI_GITHUB_TOKEN`과 `GH_TOKEN`도 동일하게 동작하며, `gori update`도 같은 변수를 읽습니다. 공개 저장소 읽기 권한만 있으면 됩니다.

### 직접 다운로드 (Dockerfile, CI) {#direct-download}

모든 릴리스에는 버전이 없는 사본도 함께 올라갑니다. 버전 조회도 API 호출도 없이 고정된 URL로 최신 빌드를 받을 수 있습니다. v0.2.0부터 제공되며, 그 이전 릴리스에는 버전이 붙은 이름만 있습니다:

```bash
# Linux x86_64 / arm64 — 정적 바이너리
curl -fsSL -o gori https://github.com/hahwul/gori/releases/latest/download/gori-linux-x86_64 && chmod +x gori

# macOS arm64 / x86_64 — gori와 lib/이 담긴 tarball
curl -fsSL -o gori.tar.gz https://github.com/hahwul/gori/releases/latest/download/gori-osx-arm64.tar.gz
```

버전이 붙은 이름(`gori-v0.3.2-linux-x86_64`)도 그대로 유지되니, 특정 빌드에 고정하려면 그쪽을 쓰세요.

각 릴리스에는 두 이름 체계를 모두 담은 `SHA256SUMS`도 함께 올라갑니다. 설치 스크립트와 `gori update`는 이 파일로 자동 검증하며, 직접 받은 파일을 확인하려면:

```bash
curl -fsSL -O https://github.com/hahwul/gori/releases/latest/download/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS       # Linux
shasum -a 256 -c --ignore-missing SHA256SUMS   # macOS
```

## Homebrew {#homebrew}

**macOS**(Apple Silicon 및 Intel)와 **Linux**(x86_64 및 arm64)에서 동작합니다:

```bash
brew install hahwul/gori/gori
```

이는 먼저 tap을 추가하는 것의 축약형이며, 다음과 같이 명시적으로 할 수도 있습니다:

```bash
brew tap hahwul/gori
brew install gori
```

macOS 보틀은 링크된 모든 dylib를 바이너리 옆에 함께 번들한 자립형 tarball이고, Linux 보틀은 정적 빌드입니다. 어느 쪽도 추가 Homebrew 의존성을 끌어오지 않습니다.

## Arch Linux (AUR) {#arch-linux-aur}

**x86_64**용 바이너리 패키지가 [AUR](https://aur.archlinux.org/packages/gori)에 게시되어 있습니다. 원하는 AUR 헬퍼로 설치하세요:

```bash
yay -S gori
# or
paru -S gori
```

## Nix {#nix}

이 저장소는 [플레이크(flake)](https://wiki.nixos.org/wiki/Flakes)이므로, 설치하지 않고 바로 실행할 수 있습니다:

```bash
nix run github:hahwul/gori
```

프로필에 설치하려면:

```bash
nix profile install github:hahwul/gori
```

NixOS / home-manager 설정에 입력(input)으로 고정할 수도 있습니다:

```nix
{
  inputs.gori.url = "github:hahwul/gori";

  # 이후 패키지 목록에서:
  #   inputs.gori.packages.${pkgs.system}.default
}
```

다른 채널과 달리 이 채널은 **소스에서 빌드**합니다. nixpkgs의 Crystal이 gori가 요구하는 버전보다 한 단계 낮아, 플레이크가 컴파일러를 직접 고정하며 첫 빌드는 그것까지 함께 컴파일합니다. 몇 분이 걸리고 이후로는 캐시됩니다. Brotli와 Zstd 디코딩이 포함되며 호스트에 따로 준비할 것은 없습니다.

Linux(x86_64 및 arm64)와 Apple Silicon macOS를 지원합니다. nixpkgs가 Intel macOS 지원을 중단했으므로, 그쪽에서는 [Homebrew](#homebrew)나 [사전 빌드 바이너리](#pre-built-binary)를 사용하세요.

`nix develop`을 실행하면 Crystal, shards, `just`와 링크되는 라이브러리가 갖춰진 셸로 들어갑니다. [gori 자체를 개발](https://github.com/hahwul/gori/blob/main/.github/CONTRIBUTING.md)하는 데 필요한 것이 모두 들어 있습니다.

## Docker {#docker}

멀티 아키텍처 이미지(x86_64 및 arm64)가 GitHub Container Registry에 [`ghcr.io/hahwul/gori`](https://github.com/hahwul/gori/pkgs/container/gori)로 게시되어 있습니다.

TUI는 터미널이 필요하므로 대화식으로 실행하세요. 설정과 루트 CA가 재시작 후에도 유지되도록 `/data`(컨테이너 내부의 `GORI_HOME`)에 볼륨을 마운트하고, 호스트에서 프록시에 접근할 수 있도록 `0.0.0.0`에 바인딩하세요:

```bash
docker run --rm -it \
  -v gori:/data \
  -p 8070:8070 \
  ghcr.io/hahwul/gori --listen 0.0.0.0
```

> `/data` 볼륨을 마운트하지 않으면 루트 CA가 매 실행마다 재생성되며, 매번 다시 신뢰해야 합니다. 기본 바인드 호스트는 `127.0.0.1`이라 컨테이너 외부에서 접근할 수 없으므로 `--listen 0.0.0.0`이 필요합니다.

헤드리스 하위 명령은 TTY가 필요 없습니다:

```bash
docker run --rm    -v gori:/data ghcr.io/hahwul/gori run history
docker run --rm -i -v gori:/data ghcr.io/hahwul/gori mcp
```

## 사전 빌드 바이너리 {#pre-built-binary}

macOS와 Linux용 독립 실행 바이너리가 모든 [GitHub Release](https://github.com/hahwul/gori/releases/latest)에 첨부됩니다.

| 플랫폼 | 자산 |
|----------|-------|
| Linux x86_64 | `gori-v*-linux-x86_64` |
| Linux arm64 | `gori-v*-linux-arm64` |
| macOS Apple Silicon | `gori-v*-osx-arm64.tar.gz` |
| macOS Intel | `gori-v*-osx-x86_64.tar.gz` |

### Linux {#linux}

Linux 바이너리는 정적으로 링크(musl)된 자립형입니다. 하나를 내려받아 실행 권한을 주고 `PATH`로 옮기세요:

```bash
chmod +x gori-v*-linux-x86_64
sudo mv gori-v*-linux-x86_64 /usr/local/bin/gori
```

### macOS {#macos}

macOS 아카이브는 자립형입니다. 의존 dylib를 모두 바이너리 옆의 `lib/` 폴더에 번들하고, 바이너리를 기준으로 상대 경로를 해석합니다. **`gori`와 `lib/`를 함께 두세요.** 안정적인 위치에 압축을 풀고 바이너리를 `PATH`에 링크하세요:

```bash
tar xzf gori-v*-osx-arm64.tar.gz          # extracts `gori` + `lib/`
sudo mkdir -p /usr/local/opt/gori
sudo cp -R gori lib /usr/local/opt/gori/
sudo ln -sf /usr/local/opt/gori/gori /usr/local/bin/gori
```

> 바이너리는 ad-hoc 서명되어 있습니다. Gatekeeper가 다운로드를 차단하면 격리 플래그를 지우세요: `xattr -dr com.apple.quarantine /usr/local/opt/gori`. [Homebrew](#homebrew)로 설치하면 이 문제를 피할 수 있습니다.

## 소스에서 빌드 {#build-from-source}

### 사전 요구 사항 {#prerequisites}

- **Crystal** `>= 1.21.0`
- **pkg-config**
- 리포지터리를 클론할 **Git**

#### 시스템 라이브러리 (Brotli / Zstd) {#system-libraries-brotli-zstd}

기본적으로 gori는 네이티브 디코더에 링크하여 `Content-Encoding: br`(Brotli)와 `zstd`로 전송된 HTTP 본문을 표시할 수 있습니다. 빌드 전에 설치하세요:

| 플랫폼 | 명령 |
|----------|---------|
| macOS (Homebrew) | `brew install brotli zstd` |
| Debian / Ubuntu | `sudo apt install libbrotli-dev libzstd-dev` |

### 빌드 {#build}

```bash
git clone https://github.com/hahwul/gori
cd gori
shards build --release
```

릴리스 바이너리는 `bin/gori`에 생성됩니다. `PATH`에 있는 위치로 옮기세요:

```bash
cp bin/gori /usr/local/bin/
```

### Brotli / Zstd 없이 빌드 {#building-without-brotli-zstd}

해당 라이브러리를 사용할 수 없다면 이를 빼고 빌드하세요. Gzip과 deflate 디코딩(Crystal 표준 라이브러리 제공)은 계속 동작하며, Brotli와 Zstd 본문은 디코드된 텍스트 대신 "decoder not built in" 안내를 표시합니다:

```bash
shards build --release -Dwithout_native_codecs
```

> 정의되지 않은 `BrotliDecoder*` 심볼 때문에 링크가 실패하면, `libbrotlidec`이 없거나 `pkg-config`가 찾지 못하는 것입니다. `brotli`를 설치하거나(위 참조) `-Dwithout_native_codecs`를 사용하세요.

## 설치 확인 {#verify-the-installation}

```bash
gori --version
```

`gori 0.3.2`이 표시되어야 합니다.

## 설치 없이 실행 {#run-without-installing}

개발 중에는 체크아웃한 위치에서 바로 실행할 수 있습니다:

```bash
shards run gori
```

## 다음 단계 {#next-steps}

이제 트래픽을 캡처할 준비가 되었습니다. [빠른 시작](/ko/getting-started/quick-start/)으로 이동하세요.
