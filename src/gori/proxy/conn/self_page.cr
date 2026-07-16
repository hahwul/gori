require "html"

module Gori::Proxy
  # The self-serve landing page ClientConn returns when a browser hits the proxy
  # listener DIRECTLY (origin-form request to gori's own address, no proxy config) —
  # the Caido/Burp-style welcome + CA-certificate download that replaces the bare
  # 502 self-loop refusal. Pure request->response bytes (no IO, no capture) so it is
  # trivially testable; ClientConn just writes what `respond` returns and closes.
  #
  # A light landing treatment in gori's own brand (docs/static/css/style.css): the
  # indigo night + gold accent, dark-first with a warm-paper light variant, and the
  # "gori" wordmark set in Unicode script glyphs so it reads as a display face with
  # NO external font. Everything is inlined — the page is written straight to the raw
  # proxy socket, so it can pull nothing remote (no fonts, images, or scripts).
  module SelfPage
    # The wordmark, in Mathematical Bold Script glyphs (U+1D4F0 g, U+1D4F8 o,
    # U+1D4FB r, U+1D4F2 i). A self-contained display face — no webfont needed —
    # paired with a visually-hidden "gori" so assistive tech reads it correctly.
    WORDMARK = %(<span aria-hidden="true">𝓰𝓸𝓻𝓲</span><span class="sr">gori</span>)

    # Map a request-target path to the resource it serves. Query/fragment are
    # stripped so `/ca.pem?x=1` still downloads. Unknown paths 404 (so a browser's
    # incidental probes don't masquerade as certs).
    def self.route(target : String) : Symbol
      path = target
      if q = path.index('?')
        path = path[0, q]
      end
      if h = path.index('#')
        path = path[0, h]
      end
      case path
      when "", "/"                   then :index
      when "/ca.pem", "/gori-ca.pem" then :pem
      when "/ca.der", "/ca.crt",
           "/gori-ca.der" then :der
      when "/favicon.ico" then :favicon
      else                     :not_found
      end
    end

    # Build the complete HTTP/1.1 response bytes for `target`. `pem`/`der` are nil
    # when there's no MITM CA to hand out (blind-tunnel mode) — the download routes
    # then 404 and the page hides its download buttons. `head_only` (a HEAD request)
    # keeps the headers but drops the body.
    def self.respond(target : String, *, pem : String?, der : Bytes?, spki : String?,
                     ca_path : String?, listen : {String, Int32}, version : String,
                     head_only : Bool) : Bytes
      case route(target)
      when :pem
        if pem
          build(200, "OK", "application/x-pem-file", pem.to_slice, head_only,
            disposition: %(attachment; filename="gori-ca.pem"))
        else
          unavailable(head_only)
        end
      when :der
        if der
          build(200, "OK", "application/x-x509-ca-cert", der, head_only,
            disposition: %(attachment; filename="gori-ca.der"))
        else
          unavailable(head_only)
        end
      when :favicon
        no_content
      when :not_found
        build(404, "Not Found", "text/html; charset=utf-8",
          simple_html("Not found", "That path isn't served here. Try <a href=\"/\">the gori info page</a>.").to_slice,
          head_only)
      else # :index
        build(200, "OK", "text/html; charset=utf-8",
          index_html(ca_available: !pem.nil?, spki: spki, ca_path: ca_path, listen: listen, version: version).to_slice,
          head_only)
      end
    end

    # ── response framing ──────────────────────────────────────────────────────

    private def self.build(status : Int32, reason : String, content_type : String,
                           body : Bytes, head_only : Bool, disposition : String? = nil) : Bytes
      io = IO::Memory.new(body.size + 256)
      io << "HTTP/1.1 " << status << ' ' << reason << "\r\n"
      io << "Content-Type: " << content_type << "\r\n"
      io << "Content-Length: " << body.size << "\r\n"
      io << "Content-Disposition: " << disposition << "\r\n" if disposition
      io << "Cache-Control: no-store\r\n"
      io << "Connection: close\r\n"
      io << "\r\n"
      io.write(body) unless head_only
      io.to_slice
    end

    # 204 carries no body by definition — no Content-Type/Length.
    private def self.no_content : Bytes
      "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".to_slice
    end

    private def self.unavailable(head_only : Bool) : Bytes
      build(404, "Not Found", "text/html; charset=utf-8",
        simple_html("Certificate unavailable",
          "gori isn't intercepting HTTPS right now, so there's no CA certificate to install.").to_slice,
        head_only)
    end

    # ── HTML ──────────────────────────────────────────────────────────────────

    private def self.simple_html(title : String, body : String) : String
      <<-HTML
      <!doctype html><html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>gori - #{HTML.escape(title)}</title>#{STYLE}</head>
      <body><main class="page"><section class="hero">
        <p class="mark">#{WORDMARK}</p>
        <h1>#{HTML.escape(title)}</h1>
        <p class="lead">#{body}</p>
      </section></main></body></html>
      HTML
    end

    private def self.index_html(*, ca_available : Bool, spki : String?, ca_path : String?,
                                listen : {String, Int32}, version : String) : String
      listen_s = HTML.escape("#{listen[0]}:#{listen[1]}")
      ver = HTML.escape(version)
      path = HTML.escape(ca_path || "unknown")
      fp = spki ? HTML.escape(spki) : nil

      cta =
        if ca_available
          <<-HTML
          <div class="cta">
            <a class="btn primary" href="/ca.der" download>Download CA (DER)</a>
            <a class="btn ghost" href="/ca.pem" download>Download PEM</a>
          </div>
          <p class="hint">DER (<code>.der</code>/<code>.crt</code>) installs by double-click on macOS and Windows.
          PEM (<code>.pem</code>) suits Firefox and most Linux tooling.</p>
          HTML
        else
          %(<p class="hint">HTTPS interception is off right now, so there's no CA certificate to download.</p>)
        end

      fingerprint = fp ? %(<div><span class="k">Fingerprint</span><code>#{fp}</code></div>) : ""

      <<-HTML
      <!doctype html><html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>gori proxy</title>#{STYLE}</head>
      <body><main class="page">
        <section class="hero">
          <p class="mark">#{WORDMARK}</p>
          <h1>You've reached the proxy</h1>
          <p class="lead">gori captures and inspects HTTP traffic between your browser and the web.
          Install its CA certificate to read HTTPS.</p>
          #{cta}
        </section>

        <section class="details">
          <h2>Trust the certificate</h2>
          <dl class="steps">
            <div><dt>Firefox</dt><dd>Settings → Certificates → Authorities → Import the <code>.pem</code>, then trust it for websites.</dd></div>
            <div><dt>macOS</dt><dd>Open the <code>.der</code> in Keychain Access, then set it to Always Trust.</dd></div>
            <div><dt>Windows</dt><dd>Open the <code>.der</code>, then install to Trusted Root Certification Authorities.</dd></div>
          </dl>

          <div class="meta">
            <div><span class="k">Listening on</span><code>#{listen_s}</code></div>
            <div><span class="k">CA file</span><code>#{path}</code></div>
            #{fingerprint}
            <div><span class="k">Version</span><code>v#{ver}</code></div>
          </div>

          <p class="warn">Only install this CA on a machine you control, for testing. A trusted root CA can decrypt your HTTPS traffic.</p>
        </section>
      </main></body></html>
      HTML
    end

    # gori's palette + type, self-contained. Dark-first (the indigo night) with a
    # warm-paper light variant under prefers-color-scheme: light. Tokens are lifted
    # from docs/static/css/style.css.
    STYLE = <<-CSS
    <style>
    :root{
      color-scheme:dark;
      --bg:#0b0e16;--text:#c6c8d4;--heading:#f6f5f1;--muted:#8d90a2;--quiet:#6a6d7e;
      --accent:#c8a860;--accent-strong:#e6cf92;
      --accent-rgb:200 168 96;--cloud-rgb:108 126 178;--hair:rgb(250 250 250 /.12);
    }
    @media (prefers-color-scheme:light){
      :root{
        color-scheme:light;
        --bg:#faf9f7;--text:#33322f;--heading:#141210;--muted:#6b6454;--quiet:#8a8272;
        --accent:#a8791f;--accent-strong:#8a5d0a;
        --accent-rgb:168 121 31;--cloud-rgb:150 132 96;--hair:rgb(26 22 14 /.14);
      }
    }
    *{box-sizing:border-box;margin:0;padding:0}
    body{min-height:100dvh;background:var(--bg);color:var(--text);
      font:16px/1.62 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans KR","Apple SD Gothic Neo",Arial,sans-serif;
      -webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
    .sr{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
    .page{max-width:44rem;margin:0 auto;padding:2rem 1.5rem 3.5rem}
    .hero{position:relative;min-height:min(80dvh,660px);display:flex;flex-direction:column;justify-content:center;padding:1.5rem 0}
    .hero::before{content:"";position:absolute;z-index:0;top:-2rem;left:-14%;width:66%;height:66%;pointer-events:none;
      background:radial-gradient(60% 60% at 32% 30%,rgb(var(--accent-rgb)/.12),transparent 70%),
        radial-gradient(52% 60% at 62% 52%,rgb(var(--cloud-rgb)/.11),transparent 72%)}
    .hero>*{position:relative;z-index:1}
    .mark{font-family:"STIX Two Math","Cambria Math","Noto Sans Math",Georgia,"Times New Roman",serif;
      font-size:clamp(3.4rem,13vw,6rem);line-height:1;color:var(--accent-strong);letter-spacing:.02em;margin-bottom:1.05rem}
    h1{color:var(--heading);font-size:clamp(1.55rem,4.5vw,2.15rem);line-height:1.16;font-weight:760;letter-spacing:-.015em;
      max-width:18ch;text-wrap:balance;margin-bottom:.7rem}
    .lead{color:var(--muted);font-size:1.06rem;max-width:44ch;margin-bottom:1.5rem}
    .cta{display:flex;flex-wrap:wrap;gap:.7rem}
    .btn{display:inline-flex;align-items:center;min-height:2.9rem;padding:.72rem 1.25rem;border-radius:10px;
      font-weight:650;font-size:.95rem;text-decoration:none;
      transition:transform .15s,filter .15s,border-color .15s,background .15s,color .15s}
    .btn:active{transform:translateY(1px)}
    .btn:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
    .btn.primary{background:var(--accent);color:#17130a}
    .btn.primary:hover{filter:brightness(1.06)}
    .btn.ghost{border:1px solid var(--hair);color:var(--heading)}
    .btn.ghost:hover{border-color:var(--accent)}
    .hint{margin-top:1.05rem;color:var(--muted);font-size:.86rem;max-width:48ch}
    .details{border-top:1px solid var(--hair);padding-top:2rem}
    h2{color:var(--heading);font-size:1.05rem;font-weight:720;margin-bottom:1rem}
    .steps{display:grid;gap:.9rem;margin-bottom:1.9rem}
    .steps dt{color:var(--heading);font-weight:650;font-size:.92rem;margin-bottom:.15rem}
    .steps dd{color:var(--muted);font-size:.9rem}
    a{color:var(--accent-strong);text-decoration:underline;text-underline-offset:.2em;text-decoration-color:rgb(var(--accent-rgb)/.45)}
    a:hover{color:var(--heading);text-decoration-color:currentColor}
    code{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:.85em;color:var(--accent-strong);word-break:break-all}
    .meta{border-top:1px solid var(--hair);padding-top:1.2rem;display:grid;gap:.42rem;font-size:.85rem}
    .meta .k{color:var(--quiet);display:inline-block;min-width:8.5rem}
    .meta code{color:var(--text)}
    .warn{margin-top:1.35rem;color:var(--quiet);font-size:.82rem;max-width:54ch}
    @media (prefers-reduced-motion:no-preference){
      .hero>.mark,.hero>h1,.hero>.lead,.hero>.cta,.hero>.hint{animation:rise .7s cubic-bezier(.16,1,.3,1) both}
      .hero>h1{animation-delay:.08s}.hero>.lead{animation-delay:.16s}
      .hero>.cta{animation-delay:.24s}.hero>.hint{animation-delay:.32s}
    }
    @keyframes rise{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}
    </style>
    CSS
  end
end
