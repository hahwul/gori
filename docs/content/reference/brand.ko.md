+++
title = "브랜드 키트"
description = "gori 마크, 그 뒤의 팔레트, 그리고 월페이퍼 — 모두 바로 내려받을 수 있습니다."
weight = 40
+++

이 페이지의 파일은 이 사이트가 실제로 쓰는 것들입니다. 헤더의 마크를 우클릭하면
같은 로고 다운로드가 메뉴로 열립니다. 이 페이지는 거기에 팔레트와 월페이퍼를
더하고, 어떤 변형을 어디에 써야 하는지 정리합니다.

## 마크 {#mark}

변형 세 가지, 각각 SVG·PNG·WebP로 제공합니다. 래스터 파일은 512 × 512이고,
SVG는 `0 0 512 512` viewBox 위에 그려져 있어 어떤 크기로도 확대됩니다.

<div class="art-gallery">
  <figure>
    <img src="/images/gori.png" alt="gori 마크: 하나의 띠로 그려진 맞물린 두 개의 고리, 단색 브랜드 골드">
    <figcaption><strong>Mark</strong> — 단색 <code>#d9c28b</code><br>
      <a href="/images/gori.svg" download="gori-logo.svg">SVG</a> ·
      <a href="/images/gori.png" download="gori-logo.png">PNG</a> ·
      <a href="/images/gori.webp" download="gori-logo.webp">WebP</a></figcaption>
  </figure>
  <figure>
    <img style="--plate:#faf9f7" src="/images/gori_dark.png" alt="같은 gori 마크를 검은 실루엣으로만 채운 형태">
    <figcaption><strong>Mono</strong> — 단색 <code>#000000</code><br>
      <a href="/images/gori_dark.svg" download="gori-logo-mono.svg">SVG</a> ·
      <a href="/images/gori_dark.png" download="gori-logo-mono.png">PNG</a> ·
      <a href="/images/gori_dark.webp" download="gori-logo-mono.webp">WebP</a></figcaption>
  </figure>
  <figure>
    <img src="/images/gori_white.png" alt="같은 gori 마크를 옅은 크림에서 짙은 청동으로 흐르는 금박 그러데이션으로 채운 형태">
    <figcaption><strong>Gradient</strong> — 금박 그러데이션<br>
      <a href="/images/gori_white.svg" download="gori-logo-gradient.svg">SVG</a> ·
      <a href="/images/gori_white.png" download="gori-logo-gradient.png">PNG</a> ·
      <a href="/images/gori_white.webp" download="gori-logo-gradient.webp">WebP</a></figcaption>
  </figure>
</div>

| 변형 | 이럴 때 쓰세요 |
|------|----------------|
| **Mark** | 기본. 밝은 배경에서도 어두운 배경에서도 버티는 단색 골드이며, 파비콘 크기로 줄여도 살아남습니다 |
| **Mono** | 단색 인쇄, 이미 색이 많은 밝은 배경, 또는 골드가 다른 색과 부딪히는 자리 |
| **Gradient** | 크게 쓸 때만. 표지 슬라이드, 스티커, 히어로 이미지용입니다. 램프는 `#f7ecd0 → #e9d49d → #d9c28b → #8c7458`이고, 96 px 아래로 내려가면 뭉개집니다 |

파일 이름은 각각 `gori`, `gori_dark`, `gori_white`이고, 헤더의 다운로드 메뉴는
이 셋을 각각 **Mark**, **Dark**, **Color**로 부릅니다.
`gori_white`는 흰색 마크가 아니라 *그러데이션*입니다. 파일 이름이 이 라벨보다
먼저 생겼고 다른 곳들이 이 경로를 참조하고 있어 이름은 그대로 둡니다. 어두운
배경용으로 뒤집은 흰색 마크는 없습니다. 어두운 배경에는 단색 골드를 쓰세요.

## 컬러 {#colours}

<div class="swatches">
  <div class="swatch" style="--c:#d9c28b"><b aria-hidden="true"></b><span><em>Brand gold</em>#d9c28b</span></div>
  <div class="swatch" style="--c:#f7ecd0"><b aria-hidden="true"></b><span><em>Gold highlight</em>#f7ecd0</span></div>
  <div class="swatch" style="--c:#c8a860"><b aria-hidden="true"></b><span><em>Leaf gold</em>#c8a860</span></div>
  <div class="swatch" style="--c:#8a6a28"><b aria-hidden="true"></b><span><em>Deep gold</em>#8a6a28</span></div>
  <div class="swatch" style="--c:#0a0a0b"><b aria-hidden="true"></b><span><em>Ink</em>#0a0a0b</span></div>
  <div class="swatch" style="--c:#080a11"><b aria-hidden="true"></b><span><em>Indigo-black</em>#080a11</span></div>
  <div class="swatch" style="--c:#6c7eb2"><b aria-hidden="true"></b><span><em>Cloud indigo</em>#6c7eb2</span></div>
  <div class="swatch" style="--c:#faf9f7"><b aria-hidden="true"></b><span><em>Paper</em>#faf9f7</span></div>
</div>

터미널과 이 사이트는 하나의 팔레트를 씁니다. 그래서 대부분의 값에 자리가 둘
있습니다.

| 컬러 | Hex | 역할 | 값이 사는 곳 |
|------|-----|------|--------------|
| Brand gold | `#d9c28b` | 마크, 그리고 지금 주목받는 것을 감싸는 포커스 테두리 | `gori.svg`의 fill, `goridark` 테마의 `focus_gold`, 사이트 워드마크 그러데이션의 마지막 스톱 — 한 값이 세 곳에 |
| Gold highlight | `#f7ecd0` | 그러데이션 마크에서 빛을 받는 모서리 | `gori_white.svg`의 첫 스톱 |
| Leaf gold | `#c8a860` | 이 사이트의 링크·구분선·강조 | 사이트의 `--accent` |
| Deep gold | `#8a6a28` | 밝은 캔버스에서 같은 역할을 하되 읽히도록 낮춘 값 | `goriday`의 `focus_gold`. 이 사이트는 `#a8791f`를 씁니다 |
| Ink | `#0a0a0b` | 터미널 캔버스 | `goridark`의 `bg` |
| Indigo-black | `#080a11` | 이 사이트의 캔버스 — 같은 밤을 한 톤 푸르게 | 사이트의 `--bg` |
| Cloud indigo | `#6c7eb2` | 월페이퍼의 구름·물결 선묘 | 사이트의 `--cloud-rgb` |
| Paper | `#faf9f7` | 두 표면 모두의 밝은 캔버스 | `goriday`의 `bg`, 사이트의 라이트 `--bg` |

TUI에서 기능적인 색을 유지하는 것은 HTTP 상태뿐이며, 그건 브랜드가 아니라 테마의
결정입니다. 기본 제공 팔레트 서른 개는 [테마 가이드](/ko/guide/themes/)에 있습니다.

## 월페이퍼 {#wallpaper}

먹과 금박, 그리고 붓으로 그린 구름 선묘. 팔레트 전체를 여기서 샘플링했습니다.
두 가지 컷이며, 존재하는 크기는 이게 전부입니다.

<div class="art-gallery">
  <figure>
    <img src="/images/gori-wallpaper.webp" alt="양식화된 구름과 물결을 먹과 금으로 그린 어두운 월페이퍼. 가운데에 금색 gori 마크와 워드마크가 있다">
    <figcaption><strong>마크 포함</strong> — 1984 × 992<br>
      <a href="/images/gori-wallpaper.webp" download="gori-wallpaper.webp">WebP</a></figcaption>
  </figure>
  <figure>
    <img src="/images/wallpaper.webp" alt="같은 먹과 금의 구름·물결 그림에서 로고를 뺀 버전">
    <figcaption><strong>로고 없음</strong> — 1152 × 768<br>
      <a href="/images/wallpaper.webp" download="gori-wallpaper-plain.webp">WebP</a></figcaption>
  </figure>
</div>

## 사용 {#usage}

gori는 Apache-2.0이고, 그 라이선스가 덮는 것은 코드지 마크가 아닙니다. 이 파일들은
gori를 가리키는 데 쓰세요. 글, 발표, 비교 표, gori와 연동되는 무언가에 다는 배지
같은 것들입니다.

마크를 다시 칠하거나, 새로 그려 흉내 내거나, 여러분 프로젝트·제품의 마크로 삼는
것은 삼가 주세요. gori가 무언가를 보증하는 것처럼 보이게 쓰는 것도 마찬가지입니다.
애매하면 [물어보세요](https://github.com/hahwul/gori/issues).
