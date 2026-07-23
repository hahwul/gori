require "json"
require "./paths"
require "./settings/network"
require "./settings/env"
require "./settings/scan_rules"
require "./settings/oast_providers"
require "./settings/display"
require "./settings/tabs"
require "./settings/keymap"
require "./settings/decoder"
require "./settings/miner"
require "./settings/probe"
require "./settings/discover"
require "./settings/update"
require "./settings/fuzzer"

module Gori
  # Global, persisted user settings — the editable runtime CONFIG for one gori
  # process (the `settings:*` command-palette entries control this). Currently the
  # NETWORK section (proxy bind + upstream proxy), the EDITOR (external ^E editor),
  # and the TUI THEME. Hotkeys are TODO. Persisted as JSON at <config_dir>/settings.json.
  #
  # Loaded once at startup (CLI flags then override the bind in memory); the
  # Settings UI edits these class properties and calls `save`. `upstream_proxy` is
  # read live by Upstream.dial, so changing it applies immediately; `bind_host`/
  # `bind_port` are applied by App on the next project open (the live proxy keeps
  # its current bind).
  #
  # The module body is split across src/gori/settings/*.cr, each reopening
  # `module Gori::Settings` with one section's class_property declarations plus its
  # parse_*/serialize_*/save_* helpers (see each file's header comment for its
  # section). This file keeps only the orchestration shared by every section: path
  # resolution, load, save, the 3-way merge-with-disk, the top-level serialize
  # dispatcher, and the couple of generic JSON-parsing helpers (load_bool/
  # load_bool_h/normalize_os) reused across sections.
  module Settings
    # The exact JSON this process last read from disk (nil = never loaded). It's the
    # 3-way-merge BASE at save time: a top-level section this process didn't change
    # (in-memory == base) yields to whatever is on disk now, so a concurrent writer's
    # unrelated edit isn't clobbered by this process persisting one unrelated field.
    @@loaded_raw : String? = nil

    def self.path : String
      File.join(Paths.home_dir, "settings.json")
    end

    # Load persisted values into the class properties. Tolerant: a missing or
    # malformed file leaves the defaults (or CLI-provided values) in place.
    def self.load : Nil
      @@loaded_raw = nil
      raw = load_raw
      return unless raw # no file yet / unreadable — first run, keep defaults
      root = load_root(raw)
      return unless root # present but unparseable — kept a .corrupt copy, keep defaults
      @@loaded_raw = raw
      apply_sections(root)
    rescue
      # a malformed individual section — keep whatever loaded so far
    end

    # Read each top-level section of a parsed settings document into the class properties.
    # Split out of load so load stays a small read → parse → apply flow.
    private def self.apply_sections(root : JSON::Any) : Nil
      if net = root["network"]?
        self.bind_host = net["bind_host"]?.try(&.as_s?) || bind_host
        self.bind_port = net["bind_port"]?.try(&.as_i?) || bind_port
        self.upstream_proxy = net["upstream_proxy"]?.try(&.as_s?) || upstream_proxy
        self.verify_upstream = load_bool(net, "verify_upstream", verify_upstream?)
        self.serve_landing = load_bool(net, "serve_landing", serve_landing?)
        net["connect_timeout_secs"]?.try(&.as_i?).try { |v| self.connect_timeout_secs = {v, 1}.max }
        net["io_timeout_secs"]?.try(&.as_i?).try { |v| self.io_timeout_secs = {v, 1}.max }
        net["capture_max_mib"]?.try(&.as_i?).try { |v| self.capture_max_mib = v.clamp(1, MAX_CAPTURE_MAX_MIB) }
      end
      self.theme = root["theme"]?.try(&.as_s?) || theme # validated against the known themes by Theme.apply
      self.mouse = load_bool(root, "mouse", mouse)
      self.pretty_bodies_default = load_bool(root, "pretty_bodies", pretty_bodies_default)
      if ed = root["editor"]?
        self.editor = ed["command"]?.try(&.as_s?) || editor
        self.editor_markdown = load_bool(ed, "markdown", editor_markdown)
      end
      self.tab_prefs = parse_tab_prefs(root["tabs"]?)
      self.hostname_overrides = parse_hostname_overrides(root["hostname_overrides"]?)
      parse_env(root["env"]?)
      self.scan_rules = parse_scan_rules(root["scan_rules"]?)
      self.oast_providers = parse_oast_providers(root["oast_providers"]?)
      parse_hotkeys(root["hotkeys"]?)
      if cv = root["decoder"]?
        self.decoder_sessions = parse_decoder_sessions(cv["sessions"]?)
        self.decoder_chains = parse_decoder_chains(cv["chains"]?)
      end
      parse_mine_prefs(root["mine"]?)
      parse_fuzzer_prefs(root["fuzzer"]?)
      if pr = root["probe"]?.try(&.as_h?)
        pr["active_notify"]?.try(&.as_s?).try { |s| self.probe_active_notify = s }
      end
      parse_discover_prefs(root["discover"]?)
      parse_layout(root["layout"]?)
      parse_statusline(root["statusline"]?)
      parse_display(root["display"]?)
      parse_notifications(root["notifications"]?)
      parse_general(root["general"]?)
      parse_update(root["update"]?)
      Env.bump_highlight_rev
    end

    # Read the settings file; nil on missing/unreadable (a first run keeps defaults).
    private def self.load_raw : String?
      File.read(path)
    rescue
      nil
    end

    # Parse the settings JSON. On a PRESENT-but-unparseable file, preserve a recoverable
    # copy at "<path>.corrupt" FIRST — otherwise the next save() overwrites the file with
    # an all-defaults document (merge_with_disk gives up on an unparseable base), silently
    # and permanently losing the user's real settings — then return nil so load keeps the
    # in-memory defaults and leaves @@loaded_raw nil (the next save is a clean write, not a
    # merge against corrupt bytes).
    private def self.load_root(raw : String) : JSON::Any?
      JSON.parse(raw)
    rescue
      (File.write("#{path}.corrupt", raw) rescue nil) if raw.presence
      nil
    end

    # load_bool over a Hash (the layout object), same false-preserving semantics as load_bool.
    private def self.load_bool_h(h : Hash(String, JSON::Any), key : String, current : Bool) : Bool
      (v = h[key]?) && !(b = v.as_bool?).nil? ? b : current
    end

    private def self.normalize_os(raw : String?) : String
      down = raw.try(&.downcase)
      %w(darwin linux windows).includes?(down) ? down.not_nil! : "auto"
    end

    # Read a boolean field, keeping `current` when it's absent or non-bool. A plain
    # `|| current` would wrongly resurrect a stored `false` (false is falsy), so we
    # assign only when a real bool is present.
    private def self.load_bool(node : JSON::Any, key : String, current : Bool) : Bool
      (v = node[key]?) && !(b = v.as_bool?).nil? ? b : current
    end

    # Persist the current values. Never raises into the caller (a failed write must
    # not crash the TUI); returns whether it succeeded.
    def self.save : Bool
      Paths.ensure_dirs
      # Atomic write: a torn File.write (crash / two instances / disk-full) would leave a
      # half-written settings.json that load()'s blanket rescue silently resets to factory
      # defaults — losing theme, hotkeys, hostname overrides, tab prefs, decoder sessions.
      # Stage to a sibling temp then rename (atomic on POSIX), mirroring cert_authority.
      tmp = "#{path}.tmp"
      # `mine` = THIS process's serialization of its OWN in-memory state. Base the next
      # merge on it, NOT on a re-read of the file we just wrote: that file also carries a
      # concurrent peer's values for sections WE didn't change (we merged them through). If
      # the base held a peer's value for an unchanged section, our next save would see
      # current != base for it and wrongly "win", silently clobbering the peer's edit back.
      # Basing on `mine` keeps "did I change this section?" honest, so an unchanged section
      # always yields to disk on every subsequent save.
      mine = serialize
      File.write(tmp, merge_with_disk(mine))
      File.rename(tmp, path)
      @@loaded_raw = mine
      true
    rescue
      File.delete?("#{path}.tmp") rescue nil
      false
    end

    # 3-way merge (base = what we loaded, mine = `current` serialization, theirs = the
    # file on disk now) over the top-level sections, so persisting one field doesn't
    # discard a concurrent writer's edit to an unrelated one: a section this process
    # left unchanged (mine == base) yields to disk; a section it changed wins.
    private def self.merge_with_disk(current : String) : String
      base = @@loaded_raw
      return current unless base && File.exists?(path)
      disk = File.read(path)
      return current if disk == base # nobody else wrote since we loaded — nothing to merge
      cur_h = (JSON.parse(current).as_h? rescue nil)
      base_h = (JSON.parse(base).as_h? rescue nil)
      disk_h = (JSON.parse(disk).as_h? rescue nil)
      return current unless cur_h && base_h && disk_h
      keys = (cur_h.keys + disk_h.keys).uniq!
      JSON.build do |j|
        j.object do
          keys.each do |k|
            cur_v = cur_h[k]?
            # I changed this section (mine != base) → mine wins; else take disk's (a
            # concurrent writer's value, or unchanged). Drop a section absent from both.
            chosen = cur_v != base_h[k]? ? cur_v : (disk_h[k]? || cur_v)
            j.field k, chosen if chosen
          end
        end
      end
    rescue
      current # any merge hiccup falls back to the plain write (never worse than before)
    end

    # Builds the full settings.json document by dispatching to each section's
    # serialize_* helper (defined alongside that section's class_property/parse_*
    # in src/gori/settings/*.cr), in the SAME ORDER the monolithic serialize used to
    # write these keys. JSON object key order is not semantically significant (load
    # reads by key), so this ordering is cosmetic/historical, kept only to make a
    # settings.json diff before/after this split a no-op.
    private def self.serialize : String
      JSON.build do |j|
        j.object do
          serialize_appearance(j)
          serialize_layout(j)
          serialize_statusline(j)
          serialize_display(j)
          serialize_notifications(j)
          serialize_general(j)
          serialize_update(j)
          serialize_network(j)
          serialize_editor(j)
          serialize_tabs(j)
          serialize_hostname_overrides(j)
          serialize_env(j)
          serialize_scan_rules(j)
          serialize_oast_providers(j)
          serialize_hotkeys(j)
          serialize_mine(j)
          serialize_fuzzer(j)
          serialize_probe(j)
          serialize_discover(j)
          serialize_decoder(j)
        end
      end
    end
  end
end

require "./env"
