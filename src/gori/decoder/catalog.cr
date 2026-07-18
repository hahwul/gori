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

    # ---------------- TOKEN ----------------
    r.register encode("jwt-decode", "jwt",
      category: Category::Token, direction: Direction::Decode,
      description: "Decode JWT header+payload (no signature verify)") { |b| Codecs.jwt_decode(b) }

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

    r
  end
end
