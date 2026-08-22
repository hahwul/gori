require "base64"
require "uri"
require "html"
require "json"
require "digest/md5"
require "digest/sha1"
require "digest/sha256"
require "digest/sha512"
require "digest/crc32"
require "openssl"

module Gori::Decoder
  # Builds the default registry — every v1 converter, in autocomplete display
  # order. Each implementation uses a stdlib API verified against Crystal 1.20
  # (e.g. Base64.strict_encode, NOT Base64.encode which MIME-wraps with newlines;
  # URI.encode_www_form, NOT the deprecated URI.encode; String#hexbytes?, not the
  # raising #hexbytes). The catalog is pure data — the engine lives in registry/chain.
  # Why the brotli/zstd converters cannot run, or nil when they can. Both come from the same
  # build flag — the two `@[Link]` blocks sit under one `{% unless %}`, so a half-linked build
  # cannot exist — and the answer is prefixed with the converter's own name because that is
  # what the two readers of `unusable` expect: `Fuzz::Plan` and the Repeater's pre-send check
  # both collect these into one list, and an unprefixed sentence leaves an operator with
  # several marked positions unable to tell which token is the one that cannot run.
  private def self.native_codec_reason(name : String) : String?
    return nil if Gori::Proxy::Codec::Brotli::AVAILABLE
    "#{name}: this gori was built with -Dwithout_native_codecs, so libbrotlidec/libzstd are not linked in"
  end

  def self.default_registry : Registry
    r = Registry.new

    # ---------------- ENCODING: base64 ----------------
    r.register encode("base64-encode", "base64", "b64", "b64encode",
      category: Category::Encoding,
      description: "Base64 encode (standard alphabet, padded)") { |b| Base64.strict_encode(b) }
    r.register decode("base64-decode", "base64url-decode", "b64decode", "unbase64",
      category: Category::Encoding,
      description: "Base64 decode (auto std/url-safe, tolerant padding)") { |s| Codecs.base64_decode(s) }
    r.register encode("base64url-encode", "base64url", "b64url", "urlsafe-base64",
      category: Category::Encoding,
      description: "Base64 URL-safe encode (-_ alphabet, padded)") { |b| Base64.urlsafe_encode(b, padding: true) }

    # ---------------- ENCODING: url ----------------
    r.register text("url-encode", "url", "urlencode", "percent-encode",
      category: Category::Encoding, direction: Direction::Encode,
      description: "URL/percent encode (form style: space -> '+')") { |s| URI.encode_www_form(s) }
    r.register text("url-decode", "urldecode", "percent-decode",
      category: Category::Encoding, direction: Direction::Decode,
      description: "URL/percent decode ('+' -> space, %XX)") { |s| URI.decode_www_form(s) }
    r.register encode("url-encode-all", "url-encode-full", "percent-encode-all",
      category: Category::Encoding,
      description: "Percent-encode every byte (%XX, uppercase) — WAF-bypass style") { |b| Codecs.url_encode_all(b) }

    # ---------------- ENCODING: hex ----------------
    r.register encode("hex-encode", "hex", "tohex",
      category: Category::Encoding,
      description: "Hex encode (lowercase, no separators)") { |b| b.hexstring }
    r.register decode("hex-decode", "unhex", "fromhex",
      category: Category::Encoding,
      description: "Hex decode (ignores spaces, ':' and 0x)") { |s| Codecs.hex_decode(s) }

    # ---------------- ENCODING: more ----------------
    r.register encode("base32-encode", "base32", "b32",
      category: Category::Encoding, description: "Base32 encode (RFC 4648, padded)") { |b| Codecs.base32_encode(b) }
    r.register decode("base32-decode", "unbase32",
      category: Category::Encoding, description: "Base32 decode (RFC 4648)") { |s| Codecs.base32_decode(s) }

    r.register encode("ascii85-encode", "ascii85", "a85", "base85",
      category: Category::Encoding, description: "Ascii85 encode (Adobe, no <~ ~> wrap)") { |b| Codecs.ascii85_encode(b) }
    r.register decode("ascii85-decode", "unascii85",
      category: Category::Encoding, description: "Ascii85 decode") { |s| Codecs.ascii85_decode(s) }

    r.register encode("base58-encode", "base58", "b58",
      category: Category::Encoding, description: "Base58 encode (Bitcoin alphabet)") { |b| Codecs.base58_encode(b) }
    r.register decode("base58-decode", "unbase58",
      category: Category::Encoding, description: "Base58 decode (Bitcoin alphabet)") { |s| Codecs.base58_decode(s) }

    r.register encode("base36-encode", "base36", "b36",
      category: Category::Encoding, description: "Base36 encode (0-9a-z, leading NULs kept as '0')") { |b| Codecs.base36_encode(b) }
    r.register decode("base36-decode", "unbase36",
      category: Category::Encoding, description: "Base36 decode (case-insensitive)") { |s| Codecs.base36_decode(s) }

    r.register encode("base62-encode", "base62", "b62",
      category: Category::Encoding, description: "Base62 encode (0-9A-Za-z, leading NULs kept as '0')") { |b| Codecs.base62_encode(b) }
    r.register decode("base62-decode", "unbase62",
      category: Category::Encoding, description: "Base62 decode (case-sensitive)") { |s| Codecs.base62_decode(s) }

    r.register encode("quoted-printable-encode", "quoted-printable", "qp", "qp-encode",
      category: Category::Encoding,
      description: "Quoted-printable encode (RFC 2045, 76-col soft breaks)") { |b| Codecs.quoted_printable_encode(b) }
    r.register decode("quoted-printable-decode", "qp-decode", "unqp",
      category: Category::Encoding,
      description: "Quoted-printable decode (=XX plus soft line breaks)") { |s| Codecs.quoted_printable_decode(s) }

    r.register text("punycode-encode", "punycode", "idn-encode",
      category: Category::Encoding, direction: Direction::Encode,
      description: "Punycode/IDN encode per dot-label (RFC 3492, adds xn--)") { |s| Codecs.punycode_encode(s) }
    r.register text("punycode-decode", "idn-decode", "unpunycode",
      category: Category::Encoding, direction: Direction::Decode,
      description: "Punycode/IDN decode per dot-label (xn-- labels only)") { |s| Codecs.punycode_decode(s) }

    # ---------------- ENCODING: number bases (byte-oriented, space-separated) ----------------
    r.register encode("decimal-encode", "decimal", "to-decimal", "dec",
      category: Category::Encoding, description: "Bytes to space-separated decimal (0-255)") { |b| Codecs.decimal_encode(b) }
    r.register decode("decimal-decode", "from-decimal", "undecimal",
      category: Category::Encoding, description: "Space/comma-separated decimal to bytes") { |s| Codecs.decimal_decode(s) }

    r.register encode("binary-encode", "binary", "to-binary", "bin",
      category: Category::Encoding, description: "Bytes to space-separated 8-bit binary") { |b| Codecs.binary_encode(b) }
    r.register decode("binary-decode", "from-binary", "unbinary",
      category: Category::Encoding, description: "Space/comma-separated binary to bytes") { |s| Codecs.binary_decode(s) }

    r.register encode("octal-encode", "octal", "to-octal", "oct",
      category: Category::Encoding, description: "Bytes to space-separated octal") { |b| Codecs.octal_encode(b) }
    r.register decode("octal-decode", "from-octal", "unoctal",
      category: Category::Encoding, description: "Space/comma-separated octal to bytes") { |s| Codecs.octal_decode(s) }

    # ---------------- COMPRESSION ----------------
    r.register bytes("gzip-compress", "gzip", "gz",
      category: Category::Compression, direction: Direction::Encode,
      description: "Gzip compress") { |b| Codecs.gzip_compress(b) }
    r.register bytes("gzip-decompress", "gunzip", "ungzip",
      category: Category::Compression, direction: Direction::Decode,
      description: "Gzip decompress (tolerant, 32 MiB cap)") { |b| Codecs.gzip_decompress(b) }
    r.register bytes("zlib-compress", "zlib", "deflate",
      category: Category::Compression, direction: Direction::Encode,
      description: "Zlib/deflate compress (RFC 1950)") { |b| Codecs.zlib_compress(b) }
    r.register bytes("zlib-decompress", "inflate",
      category: Category::Compression, direction: Direction::Decode,
      description: "Zlib/deflate decompress (32 MiB cap)") { |b| Codecs.zlib_decompress(b) }
    r.register bytes("raw-deflate", "deflate-raw",
      category: Category::Compression, direction: Direction::Encode,
      description: "Raw DEFLATE compress (RFC 1951, no zlib/gzip header)") { |b| Codecs.deflate_raw(b) }
    r.register bytes("raw-inflate", "inflate-raw",
      category: Category::Compression, direction: Direction::Decode,
      description: "Raw DEFLATE decompress (RFC 1951, 32 MiB cap)") { |b| Codecs.inflate_raw(b) }
    # DECOMPRESS only: gori links the brotli DECODER library and wraps libzstd's decompressor,
    # because what a proxy needs is to read what an origin sent. Registered even when the build
    # dropped them, carrying the reason — a `-Dwithout_native_codecs` build should say which
    # build it is, not make `br` look like a typo.
    r.register bytes("brotli-decompress", "brotli", "br", "unbrotli",
      category: Category::Compression, direction: Direction::Decode,
      description: "Brotli decompress (Content-Encoding: br — tolerant, 32 MiB cap)",
      unusable: native_codec_reason("brotli-decompress")) { |b| Codecs.brotli_decompress(b) }
    r.register bytes("zstd-decompress", "zstd", "unzstd",
      category: Category::Compression, direction: Direction::Decode,
      description: "Zstandard decompress (Content-Encoding: zstd — tolerant, 32 MiB cap)",
      unusable: native_codec_reason("zstd-decompress")) { |b| Codecs.zstd_decompress(b) }

    # ---------------- SERIALIZATION ----------------
    # One direction only, and the direction that matters: these read a body somebody else
    # wrote. The JSON is a PROJECTION — types JSON cannot hold come back named rather than
    # folded away — so it is for reading, not for re-encoding into the original document.
    r.register bytes("msgpack-decode", "msgpack", "mpack", "unmsgpack",
      category: Category::Serialization, direction: Direction::Decode,
      description: "MessagePack → JSON (schema-less; $bin / $ext / $timestamp are named)") { |b| Codecs.msgpack_to_json(b) }
    r.register bytes("cbor-decode", "cbor", "uncbor",
      category: Category::Serialization, direction: Direction::Decode,
      description: "CBOR → JSON (RFC 8949, schema-less; $bin / $tag / $bignum are named)") { |b| Codecs.cbor_to_json(b) }

    # ---------------- TOKEN ----------------
    r.register encode("jwt-decode", "jwt",
      category: Category::Token, direction: Direction::Decode,
      description: "Decode JWT header+payload (no signature verify)") { |b| Codecs.jwt_decode(b) }

    # Framework signed session cookies — parse into payload / timestamp / signature, no
    # verify (that + crack/forge live in `gori run cookie` and the MCP cookie_* tools).
    r.register encode("cookie-decode", "cookie", "session-cookie",
      category: Category::Token, direction: Direction::Decode,
      description: "Decode a Flask/Rack/Django signed session cookie (auto-detect)") { |b| Codecs.cookie_decode(b) }
    r.register encode("flask-decode", "flask", "flask-cookie", "itsdangerous",
      category: Category::Token, direction: Direction::Decode,
      description: "Decode a Flask (itsdangerous) session cookie") { |b| Codecs.flask_cookie_decode(b) }
    r.register encode("rack-decode", "rack", "rack-cookie",
      category: Category::Token, direction: Direction::Decode,
      description: "Decode a Rack (Ruby) session cookie") { |b| Codecs.rack_cookie_decode(b) }
    r.register encode("django-decode", "django", "django-cookie",
      category: Category::Token, direction: Direction::Decode,
      description: "Decode a Django (django.core.signing) session cookie") { |b| Codecs.django_cookie_decode(b) }

    # ---------------- HASH ----------------
    r.register encode("md5", category: Category::Hash, direction: Direction::Hash, description: "MD5 digest (hex)") { |b| Digest::MD5.hexdigest(b) }
    r.register encode("sha1", category: Category::Hash, direction: Direction::Hash, description: "SHA-1 digest (hex)") { |b| Digest::SHA1.hexdigest(b) }
    r.register encode("sha224", category: Category::Hash, direction: Direction::Hash, description: "SHA-224 digest (hex)") { |b| OpenSSL::Digest.new("SHA224").update(b).final.hexstring }
    r.register encode("sha256", category: Category::Hash, direction: Direction::Hash, description: "SHA-256 digest (hex)") { |b| Digest::SHA256.hexdigest(b) }
    r.register encode("sha384", category: Category::Hash, direction: Direction::Hash, description: "SHA-384 digest (hex)") { |b| OpenSSL::Digest.new("SHA384").update(b).final.hexstring }
    r.register encode("sha512", category: Category::Hash, direction: Direction::Hash, description: "SHA-512 digest (hex)") { |b| Digest::SHA512.hexdigest(b) }
    r.register encode("crc32", category: Category::Hash, direction: Direction::Hash, description: "CRC-32 checksum (hex)") { |b| Digest::CRC32.checksum(b).to_s(16).rjust(8, '0') }

    # ---------------- ESCAPE ----------------
    r.register text("html-escape", "html-encode", "htmlentities", "html",
      category: Category::Escape, direction: Direction::Encode,
      description: "HTML-escape & < > \" ' (only)") { |s| HTML.escape(s) }
    r.register text("html-unescape", "html-decode", "unhtml",
      category: Category::Escape, direction: Direction::Decode,
      description: "HTML-unescape named + numeric entities") { |s| HTML.unescape(s) }

    r.register text("json-escape", "json-encode", "jsonstring",
      category: Category::Escape, direction: Direction::Encode,
      description: "JSON string-escape (yields a quoted literal)") { |s| s.to_json }
    r.register text("json-unescape", "json-decode",
      category: Category::Escape, direction: Direction::Decode,
      description: "JSON string-unescape (quoted or bare)") { |s| Codecs.json_unescape(s) }

    r.register text("unicode-escape", "u-escape", "unicodeescape",
      category: Category::Escape, direction: Direction::Encode,
      description: "Escape non-ASCII as \\uXXXX (lowercase)") { |s| Codecs.unicode_escape(s) }
    r.register text("unicode-unescape", "u-unescape",
      category: Category::Escape, direction: Direction::Decode,
      description: "Decode \\uXXXX (incl. surrogate pairs)") { |s| Codecs.unicode_unescape(s) }

    r.register text("xml-escape", "xml-encode", "xml",
      category: Category::Escape, direction: Direction::Encode,
      description: "XML-escape & < > \" ' (the five predefined entities)") { |s| Codecs.xml_escape(s) }
    r.register text("xml-unescape", "xml-decode", "unxml",
      category: Category::Escape, direction: Direction::Decode,
      description: "XML-unescape the five entities + &#NN; / &#xNN;") { |s| Codecs.xml_unescape(s) }

    r.register text("shell-escape", "sh-escape", "bash-escape", "shell-quote",
      category: Category::Escape, direction: Direction::Encode,
      description: "POSIX shell single-quote (wraps; one-way)") { |s| Codecs.shell_escape(s) }
    r.register text("powershell-escape", "ps-escape", "pwsh-escape", "powershell-quote",
      category: Category::Escape, direction: Direction::Encode,
      description: "PowerShell single-quote (doubles ', wraps; one-way)") { |s| Codecs.powershell_escape(s) }

    r.register encode("c-string-escape", "c-escape", "cstring-escape",
      category: Category::Escape,
      description: "C string-literal escape (\\n, \\xNN; body only, no quotes)") { |b| Codecs.c_string_escape(b) }
    r.register decode("c-string-unescape", "c-unescape", "cstring-unescape",
      category: Category::Escape,
      description: "C string-literal unescape (\\xNN, \\NNN, \\uXXXX, \\n …)") { |s| Codecs.c_string_unescape(s) }

    # ---------------- TEXT ----------------
    r.register text("rot13", category: Category::Text, direction: Direction::Transform,
      description: "ROT13 letters") { |s| Codecs.rot13(s) }
    r.register text("upper", "uppercase", "upcase", category: Category::Text, direction: Direction::Transform,
      description: "Uppercase") { |s| s.upcase }
    r.register text("lower", "lowercase", "downcase", category: Category::Text, direction: Direction::Transform,
      description: "Lowercase") { |s| s.downcase }
    r.register text("reverse", category: Category::Text, direction: Direction::Transform,
      description: "Reverse characters") { |s| s.reverse }
    r.register text("rot47", category: Category::Text, direction: Direction::Transform,
      description: "ROT47 (printable ASCII 33-126, self-inverse)") { |s| Codecs.rot47(s) }

    r.register text("homoglyph", "homoglyphs", "confusable",
      category: Category::Text, direction: Direction::Transform,
      description: "ASCII letters to Unicode lookalikes (lossy, one-way)") { |s| Codecs.homoglyph(s) }
    r.register text("typo", "typos", "typosquat",
      category: Category::Text, direction: Direction::Transform,
      description: "Near-miss variants, one per line (omit/swap/adjacent-key)") { |s| Codecs.typo(s) }

    r
  end
end
