require "base64"
require "./process_hook"
require "./decoder/converter"
require "./decoder/registry"
require "./decoder/codecs"
require "./decoder/catalog"
require "./decoder/chain"
require "./decoder/library"

module Gori::Decoder
  # Output ceiling for any single step / decompression drain — lifted from
  # Proxy::Codec::ContentDecode::MAX_OUT (32 MiB) so a chained decompress can't bomb.
  MAX_OUT = 32 * 1024 * 1024

  # The marker that turns a chain step into an EXTERNAL COMMAND (#818):
  # `base64-decode > exec:./mytool --flag > json-pretty`. Everything after the colon is the
  # argv, tokenized by `ProcessHook.parse_argv` and exec'd with NO SHELL.
  #
  # Why `exec:` and not the `| argv` the issue drew. `|` is already one of this grammar's three
  # interchangeable SEPARATORS (`SEPARATORS`, documented in the CLI reference), so `a > | ./tool`
  # splits into a bare `./tool` token with the marker gone before anything can read it — and
  # repurposing `|` would silently change what every existing `a | b` chain means, from "then run
  # converter b" to "then exec the program b". A colon-prefixed kind marker is the idiom already
  # in the tree (`DisplayColumns`: `header:x`, `regex:…`, `position:…`), collides with no
  # separator, and survives a shell's own quoting rules unremarkably.
  #
  # LIMIT, and it comes from the same place: the spec is split on `>`, `|` and `,` BEFORE a step
  # is looked at, so those three characters cannot appear anywhere in an exec step's argv. There
  # is no shell here, so redirection and pipelines were never meanings they could carry; an
  # argument that genuinely needs a comma has to be passed some other way (a file, an env var).
  EXEC_PREFIX = "exec:"

  # The argv text of an exec step, or nil when this token is an ordinary converter name. The one
  # place the marker is recognised — the chain executor, the autocomplete panes, the Fuzzer and
  # Repeater pre-send gates and the saved-chain flattener all ask HERE rather than each spelling
  # the prefix out (P1).
  # A bare `exec:` (or `exec:` with only whitespace after it) IS an exec step — an empty one.
  # Requiring a non-empty remainder sent it to the registry instead, which reported `unknown
  # converter "exec:"` and pointed the operator at a converter name that was never the problem;
  # it also re-opened the completion popup over a marker they had just typed. The step now fails
  # with `no command`, which is what is actually wrong with it.
  def self.exec_spec(token : String) : String?
    t = token.strip
    return nil unless t.size >= EXEC_PREFIX.size && t[0, EXEC_PREFIX.size].compare(EXEC_PREFIX, case_insensitive: true) == 0
    t[EXEC_PREFIX.size..].strip
  end

  # Whether this token names an exec step at all (however broken its argv is). Separated from
  # `exec_spec` because the callers that REFUSE a bad chain need "this was meant to be an exec
  # step" to be true even when the argv does not tokenize — otherwise a typo'd command falls
  # through to the registry and is reported as an unknown converter, which sends the operator
  # looking for a converter name.
  def self.exec_step?(token : String) : Bool
    !exec_spec(token).nil?
  end

  # Why this exec step cannot run, or nil when it can. The shared validator behind every
  # pre-send refusal — see `Fuzz::Plan.refuse_unusable_chains`.
  def self.exec_step_error(token : String) : String?
    spec = exec_spec(token)
    return nil if spec.nil?
    out = ProcessHook.parse_argv(spec)
    out.is_a?(String) ? "#{token}: #{out}" : nil
  end

  # Whether running `spec` would run an external command — directly (`exec:…`) or through a
  # saved chain that contains one (`Converter#runs_commands?`). The predicate a caller uses when
  # command execution is not something it may do at all.
  #
  # A saved chain is why this cannot be a scan for the marker: the library registers each saved
  # spec as a converter callable BY NAME, so `myenc` runs whatever `myenc` was defined as, and
  # the token says nothing. Asking the registry is the only way to see through the name.
  def self.chain_runs_commands?(registry : Registry, spec : String) : Bool
    parse_spec(spec).any? do |tok|
      exec_step?(tok) || !!registry[tok]?.try(&.runs_commands?)
    end
  end

  # How a (possibly binary) value is rendered in the Output/pipeline panes.
  enum RenderAs
    Text
    Base64
    Hex
  end

  # Default display choice for a value: valid UTF-8 -> text, else base64 (the exact
  # decision mcp/serialize.cr makes). `prefer` overrides it (the ^X hex/base64
  # toggle). Returns the rendered string + the mode actually used.
  def self.display(data : Bytes, prefer : RenderAs? = nil) : {String, RenderAs}
    case prefer
    when RenderAs::Hex
      {data.hexstring, RenderAs::Hex}
    when RenderAs::Base64
      {Base64.strict_encode(data), RenderAs::Base64}
    when RenderAs::Text
      {String.new(data), RenderAs::Text}
    else
      s = String.new(data)
      s.valid_encoding? ? {s, RenderAs::Text} : {Base64.strict_encode(data), RenderAs::Base64}
    end
  end

  def self.binary?(data : Bytes) : Bool
    !String.new(data).valid_encoding?
  end

  # A process-wide registry built once and reused. The catalog is pure, read-only
  # data after construction, so concurrent reads (fuzz worker fibers all splice
  # through it) are safe. Callers that would otherwise rebuild `default_registry`
  # per request/run — the Fuzzer/Repeater send paths, `gori run fuzz`, MCP fuzz —
  # share this instance instead.
  @@shared : Registry?

  def self.shared_registry : Registry
    @@shared ||= build_registry
  end

  # The named-chain library (settings.json `decoder.chains`) as the engine sees it. Settings
  # PUSHES it here on every write (Settings.decoder_chains=), so the engine stays free of the
  # config layer — it is handed the entries, it never reads them.
  @@library = [] of {String, String}

  def self.library : Array({String, String})
    @@library
  end

  # Rebuilds `shared_registry` as a FRESH Registry rather than registering into the live one:
  # the shared instance is documented read-only-after-construction because fuzz worker fibers
  # splice through it concurrently, and a reference swap keeps that true — a fiber holding the
  # old registry keeps reading immutable data instead of a half-updated hash.
  def self.library=(entries : Array({String, String})) : Array({String, String})
    @@library = entries
    @@shared = build_registry(entries)
    entries
  end

  # The catalog plus one converter per saved chain, so `myenc > url-encode` resolves through
  # the same `Registry#[]?` every surface already uses. See decoder/library.cr.
  def self.build_registry(entries : Array({String, String}) = @@library) : Registry
    r = default_registry
    Library.register_all(r, entries)
    r
  end
end
