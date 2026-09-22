require "json"
require "../store"
require "../config_log"

# PER-PROJECT NETWORK KEYS, edited ONE AT A TIME (#1115): the headless counterpart of the
# Project settings card, which writes the same `net.*` rows through `save_project_network`.
#
# WHY a second writer rather than calling `save_project_network`. That method takes the WHOLE
# card — eight fields — and folds every value equal to the current global back to "inherit". Both
# halves are right for a pane that is always saved whole from what it displayed, and both are
# wrong for a command that names one key:
#
#   * a whole-card write from a headless process is a read-modify-write of eight rows, so a
#     `set upstream_proxy` would re-write the capture cap it read a moment earlier, over a TUI
#     edit that landed in between;
#   * the pane cannot tell "I typed the global value" from "I left the inherited value alone",
#     so it has to fold. A command can: `set` says pin, `unset` says inherit. Folding here would
#     make `set upstream_proxy=` (dial DIRECT) silently become "inherit" whenever the global
#     scalar is also blank — and inheriting means `upstream_rules` and `HTTPS_PROXY` still
#     route the project through a proxy, the opposite of what was asked.
#
# So `set` writes exactly the row it names (normalized, validated), and every edit that touches
# more than one row — credentials and the upstream they are pinned to — is ONE `set_settings`
# task, for the reason `save_project_network` gives: a busy store must not commit a password
# beside an address it was never validated against.
#
# The planning half is PURE over a snapshot of the current rows, so the rules are testable
# without a store; `apply_project_network_edit` is the one write and the one audit line.
module Gori::Settings
  # One per-project network key as an operator names it: the short `name` (`upstream_proxy`,
  # also accepted as the row's own spelling `net.upstream_proxy`), the project-DB `key`, and the
  # one-line `summary` a listing prints beside it.
  record ProjectNetworkKey, name : String, key : String, summary : String do
    def auth? : Bool
      key == PROJECT_UPSTREAM_AUTH_KEY
    end

    # The two LISTEN keys. They only mean something where gori binds a socket — the TUI and
    # `gori run capture` — which `load_project_network(bind:)` already encodes.
    def bind? : Bool
      key == PROJECT_BIND_HOST_KEY || key == PROJECT_BIND_PORT_KEY
    end
  end

  # Every `net.*` row a project may carry, in the order the Project settings card shows them.
  # The ONE list: the headless listing, the key lookup and the spec that pins it against the
  # `PROJECT_*_KEY` constants all read it, so a ninth key added to `load_project_network`
  # without an entry here is a spec failure rather than a key no command can reach.
  PROJECT_NETWORK_KEYS = [
    ProjectNetworkKey.new("bind_host", PROJECT_BIND_HOST_KEY,
      "proxy listen address (applies where gori listens: the TUI and `gori run capture`)"),
    ProjectNetworkKey.new("bind_port", PROJECT_BIND_PORT_KEY,
      "proxy listen port (applies where gori listens: the TUI and `gori run capture`)"),
    ProjectNetworkKey.new("upstream_proxy", PROJECT_UPSTREAM_KEY,
      "upstream proxy URI (http://, http+tls://, socks5://, socks5h://); empty = dial direct"),
    ProjectNetworkKey.new("upstream_destination_host", PROJECT_UPSTREAM_DESTINATION_KEY,
      "host pattern the project's proxy routing applies to; anything else goes direct (* = all)"),
    ProjectNetworkKey.new("upstream_auth", PROJECT_UPSTREAM_AUTH_KEY,
      "proxy credentials (HTTP Basic, or SOCKS5 username/password); pins the upstream they were set for"),
    ProjectNetworkKey.new("connect_timeout_secs", PROJECT_CONNECT_TIMEOUT_KEY,
      "outbound connect timeout, seconds (min 1)"),
    ProjectNetworkKey.new("io_timeout_secs", PROJECT_IO_TIMEOUT_KEY,
      "outbound idle read/write timeout, seconds (min 1)"),
    ProjectNetworkKey.new("capture_max_mib", PROJECT_CAPTURE_MAX_KEY,
      "body bytes captured and stored per message, MiB (1-#{MAX_CAPTURE_MAX_MIB})"),
  ]

  # The key an operator typed, or nil. Case-insensitive, and the `net.` prefix is optional: the
  # row's own name is what `strings` on the binary, the config reference and #1115's reporter
  # all spell, so refusing it would teach nothing but a second vocabulary.
  def self.project_network_key(spelling : String) : ProjectNetworkKey?
    s = spelling.strip.downcase.lchop("net.")
    PROJECT_NETWORK_KEYS.find { |k| k.name == s }
  end

  # What a project with no row for `k` uses instead — the global value from settings.json, or
  # the built-in default for the one key that has no global counterpart. nil for credentials,
  # which have no fallback at all. The CLI `-l`/`-p` layer is deliberately NOT consulted: it is
  # this process's argv, not something a project inherits (`configured_bind_*` argues the same).
  #
  # For `upstream_proxy` this is only the global SCALAR. Inheriting also means `upstream_rules`
  # and the proxy environment variables take part (`upstream_route`); a listing says so beside
  # the value rather than pretending one string is the whole route.
  def self.project_network_inherited(k : ProjectNetworkKey) : String?
    case k.key
    when PROJECT_BIND_HOST_KEY            then bind_host
    when PROJECT_BIND_PORT_KEY            then bind_port.to_s
    when PROJECT_UPSTREAM_KEY             then upstream_proxy
    when PROJECT_UPSTREAM_DESTINATION_KEY then DEFAULT_PROJECT_UPSTREAM_DESTINATION
    when PROJECT_CONNECT_TIMEOUT_KEY      then connect_timeout_secs.to_s
    when PROJECT_IO_TIMEOUT_KEY           then io_timeout_secs.to_s
    when PROJECT_CAPTURE_MAX_KEY          then capture_max_mib.to_s
    end
  end

  # The project's stored `net.*` rows, keyed by row name — the snapshot every plan below is
  # computed over. Read straight from the store rather than from the runtime layer
  # `load_project_network` installed: that layer drops the bind pair on every headless surface
  # (`bind: false`), and a listing that reported "not set" for a pinned port would be wrong.
  def self.project_network_rows(store : Store) : Hash(String, String)
    rows = {} of String => String
    PROJECT_NETWORK_KEYS.each do |k|
      if v = store.setting(k.key)
        rows[k.key] = v
      end
    end
    rows
  end

  # One planned edit: the rows to write in ONE task (a nil value deletes its key), the facts an
  # operator should be told about what the write means, and the secret-free audit line.
  record ProjectNetworkEdit, rows : Array({String, String?}), notes : Array(String), audit : String

  # Plan `set KEY VALUE` against `current` (`project_network_rows`). Returns the edit, or the
  # refusal. `password` is read only for `upstream_auth`, whose VALUE is the username — a
  # password on an argument vector would sit in the process listing and the shell history, so
  # the surface fetches it some other way and hands it in here.
  def self.plan_project_network_set(current : Hash(String, String), k : ProjectNetworkKey,
                                    value : String, password : String? = nil) : {ProjectNetworkEdit?, String?}
    case k.key
    when PROJECT_BIND_HOST_KEY            then plan_bind_host(k, value)
    when PROJECT_BIND_PORT_KEY            then plan_whole_number(k, value, 0, 65_535)
    when PROJECT_UPSTREAM_KEY             then plan_upstream(current, k, value)
    when PROJECT_UPSTREAM_DESTINATION_KEY then plan_destination(current, k, value)
    when PROJECT_UPSTREAM_AUTH_KEY        then plan_auth(current, value, password)
    when PROJECT_CAPTURE_MAX_KEY          then plan_whole_number(k, value, 1, MAX_CAPTURE_MAX_MIB)
    else                                       plan_whole_number(k, value, 1, Int32::MAX)
    end
  end

  # Plan `unset KEY`: drop the row so the project inherits again. A key that is not set is not
  # an error — `unset` is how a script says "make sure this project inherits", and that is
  # already true — so it comes back as an edit with no rows and a note saying so.
  def self.plan_project_network_unset(current : Hash(String, String),
                                      k : ProjectNetworkKey) : {ProjectNetworkEdit?, String?}
    unless current.has_key?(k.key)
      return {ProjectNetworkEdit.new([] of {String, String?},
        ["#{k.key} is not set on this project — it already inherits"], ""), nil}
    end
    # Credentials pin the upstream they were validated against (`save_project_network`: "Auth
    # pins the upstream unconditionally"). Dropping the pin under them would hand the password
    # to whatever route the project inherits next — a rule, a global edit, `HTTPS_PROXY`.
    if k.key == PROJECT_UPSTREAM_KEY && current.has_key?(PROJECT_UPSTREAM_AUTH_KEY)
      return {nil, "the project's proxy credentials are pinned to this upstream — unset upstream_auth first"}
    end
    notes = [] of String
    if k.auth? && (up = current[PROJECT_UPSTREAM_KEY]?)
      notes << "the upstream pin #{upstream_display(up)} stays — unset upstream_proxy to inherit the global route again"
    end
    audit = if k.auth?
              "project proxy credentials cleared"
            elsif k.key == PROJECT_UPSTREAM_DESTINATION_KEY
              "project upstream destination cleared — back to *"
            else
              "project #{k.key} cleared — inherits the global value"
            end
    {ProjectNetworkEdit.new([{k.key, nil.as(String?)}], notes, audit), nil}
  end

  # Write `edit` in one task and, only once it COMMITTED, record it in the project's config
  # feed (see `ConfigLog.record`: an attempt is not a change). An empty edit writes nothing and
  # reports success — there was nothing to land.
  def self.apply_project_network_edit(store : Store, edit : ProjectNetworkEdit) : Bool
    return true if edit.rows.empty?
    ok = store.set_settings(edit.rows)
    ConfigLog.record(store, "network", edit.audit) if ok && !edit.audit.empty?
    ok
  end

  # How an upstream value reads in a message: the scrubbed URI, or "direct" for the blank pin.
  def self.upstream_display(value : String) : String
    value.strip.empty? ? "direct" : ConfigLog.scrub_url(value.strip)
  end

  private def self.plan_bind_host(k : ProjectNetworkKey, value : String) : {ProjectNetworkEdit?, String?}
    v = value.strip
    return {nil, "#{k.key} must not be empty — unset it to inherit the global bind address"} if v.empty?
    if err = bind_host_error(v)
      return {nil, err}
    end
    {single_row(k, v), nil}
  end

  # The four numeric keys. `to_i?` is strict (no `12abc`, no `1.5`), and the value is stored
  # NORMALIZED (`007` → `7`), because `load_project_network` reads it back with the same `to_i?`
  # and a row that parses differently from how it prints is a row two readers disagree about.
  private def self.plan_whole_number(k : ProjectNetworkKey, value : String,
                                     min : Int32, max : Int32) : {ProjectNetworkEdit?, String?}
    n = value.strip.to_i?
    unless n && min <= n <= max
      range = max == Int32::MAX ? "at least #{min}" : "#{min}-#{max}"
      return {nil, "invalid #{k.key} #{value.inspect} (a whole number, #{range})"}
    end
    {single_row(k, n.to_s), nil}
  end

  # A plain pinned row, noting when the pin equals what the project would inherit anyway —
  # the one outcome the Project settings card would have folded to "inherit" instead.
  private def self.single_row(k : ProjectNetworkKey, v : String) : ProjectNetworkEdit
    notes = [] of String
    if v == project_network_inherited(k)
      notes << "#{v} is also the global value; it is pinned anyway, so a later global edit will " \
               "not reach this project — unset #{k.name} to inherit instead"
    end
    ProjectNetworkEdit.new([{k.key, v.as(String?)}], notes, "project #{k.key} set to #{v}")
  end

  private def self.plan_destination(current : Hash(String, String), k : ProjectNetworkKey,
                                    value : String) : {ProjectNetworkEdit?, String?}
    v = value.strip
    if err = upstream_destination_error(v)
      return {nil, err}
    end
    # An absent row IS `*` (`effective_project_upstream_destination`), so storing the default
    # would only be a second spelling of the state every pre-feature project is in — and with
    # no row there is nothing to clear, so nothing is written or audited.
    if v == DEFAULT_PROJECT_UPSTREAM_DESTINATION && !current.has_key?(k.key)
      return {ProjectNetworkEdit.new([] of {String, String?}, ["* is already the default — nothing to change"], ""), nil}
    end
    if v == DEFAULT_PROJECT_UPSTREAM_DESTINATION
      return {ProjectNetworkEdit.new([{k.key, nil.as(String?)}],
        ["* is the default — the row was cleared, so every destination is eligible"],
        "project upstream destination reset to *"), nil}
    end
    {ProjectNetworkEdit.new([{k.key, v.as(String?)}], [] of String,
      "project upstream destination set to #{v}"), nil}
  end

  # `set upstream_proxy`. A blank value is a PIN to direct, not an unset (see the header). When
  # the project carries credentials they follow the new address in the same task — re-derived
  # for it, since the proxy KIND decides the method (Basic for an HTTP proxy, RFC 1929 for
  # SOCKS5), exactly as the Project settings card re-derives them on save.
  private def self.plan_upstream(current : Hash(String, String), k : ProjectNetworkKey,
                                 value : String) : {ProjectNetworkEdit?, String?}
    v = value.strip
    if err = upstream_proxy_error(v)
      return {nil, err}
    end
    rows = [{k.key, v.as(String?)}]
    notes = [] of String
    if raw_auth = current[PROJECT_UPSTREAM_AUTH_KEY]?
      old = ProjectProxyAuth.parse?(raw_auth)
      return {nil, "the project's stored proxy credentials are malformed — unset upstream_auth first"} unless old
      if v.empty?
        return {nil, "the project's proxy credentials are pinned to its upstream proxy — unset upstream_auth " \
                     "before pinning a direct route"}
      end
      auth, err = build_project_proxy_auth(v, true, old.username, old.password)
      if err || auth.nil?
        return {nil, "the project's stored proxy credentials do not fit #{upstream_display(v)}: #{err} — " \
                     "unset upstream_auth first, or set it again after this"}
      end
      rows << {PROJECT_UPSTREAM_AUTH_KEY, auth.to_json.as(String?)}
      notes << "the project's proxy credentials moved to #{upstream_display(v)}" \
               "#{auth.method == old.method ? "" : " (now #{auth.method})"}"
    end
    if v.empty?
      notes << "direct: this project dials every destination without a proxy — the global " \
               "upstream_proxy, upstream_rules and HTTP(S)_PROXY/ALL_PROXY no longer apply to it"
    elsif v == upstream_proxy
      notes << "#{upstream_display(v)} is also the global value; it is pinned anyway, so " \
               "upstream_rules and a later global edit will not reach this project — unset " \
               "upstream_proxy to inherit instead"
    end
    {ProjectNetworkEdit.new(rows, notes, "project upstream proxy set to #{upstream_display(v)}"), nil}
  end

  # `set upstream_auth USERNAME` with the password handed in. Validated against the upstream the
  # project would dial through — its own pin, else the global scalar the Project settings card
  # displays — and that upstream is PINNED in the same task, so the credentials can never follow
  # a later global edit or a destination rule to a proxy they were not entered for.
  private def self.plan_auth(current : Hash(String, String), username : String,
                             password : String?) : {ProjectNetworkEdit?, String?}
    return {nil, "upstream_auth needs a password as well as the username"} if password.nil?
    upstream = current[PROJECT_UPSTREAM_KEY]? || upstream_proxy
    auth, err = build_project_proxy_auth(upstream, true, username, password)
    return {nil, err || "invalid proxy credentials"} if err || auth.nil?
    notes = [] of String
    unless current.has_key?(PROJECT_UPSTREAM_KEY)
      notes << "the inherited upstream #{upstream_display(upstream)} is now pinned to this project, so " \
               "the credentials cannot follow a later global edit to a different proxy"
    end
    rows = [{PROJECT_UPSTREAM_KEY, upstream.as(String?)}, {PROJECT_UPSTREAM_AUTH_KEY, auth.to_json.as(String?)}]
    # The method and the address, never the username or the password: the audit trail must not
    # leak the credential it records (`log_project_network` holds the same line).
    {ProjectNetworkEdit.new(rows, notes,
      "project proxy credentials set for #{upstream_display(upstream)} (#{auth.method}, #{ConfigLog::REDACTED})"), nil}
  end
end
