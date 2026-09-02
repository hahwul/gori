require "./spec_helper"

private alias I18n = Gori::I18n

# SEAM spec (like layering_spec.cr): the shipped Korean catalog held against the source that
# keys it.
#
# The catalog is msgid-keyed — the English literal in code IS the key — and nothing type-checks
# that a key still names a live string. Left alone, rewording an English literal would orphan
# its translation in silence (the TUI falls back to English and nobody is told), and a newly
# wrapped literal would ship untranslated until someone noticed. Both directions gate here:
# every ko entry must be a msgid something in `src/` wraps, and every wrapped msgid must have
# a ko entry — an EMPTY value is allowed as "not yet translated" and is reported, not failed.
#
# Wrapped msgids come from two places. Literal calls — `I18n.ui("…")`, `I18n.sys("…", x: …)`,
# `I18n.ui_n(n, "…", "…", …)` — are found by regex, one line at a time (a msgid is a single
# plain literal on the line of its call; that is the contract, and anything else fails below).
# TABLES whose entries are translated where they are DRAWN (`Companion::GREETING`, and the
# verb / help / settings tables as their sweeps land) are enumerated in `wrapped_in_tables`.
# A call whose first argument is not a literal is a dynamic msgid: reported, never failed —
# `I18n.collect_missing` is the runtime net for those.
private SRC_ROOT = File.expand_path("../src", __DIR__)

# `"…"` with the escapes a msgid may carry (checked in `unescape_msgid`).
private STR          = %q{"((?:[^"\\\n]|\\.)*)"}
private CALL_RE      = /\bI18n\.(ui|help|sys|ring)\(\s*#{STR}\s*[,)]/
private CALL_N_RE    = /\bI18n\.(ui|help|sys|ring)_n\(\s*[^,()]+,\s*#{STR}\s*,\s*#{STR}\s*[,)]/
private DYNAMIC_RE   = /\bI18n\.(ui|help|sys|ring)\(\s*(?!")/
private DYNAMIC_N_RE = /\bI18n\.(ui|help|sys|ring)_n\(\s*[^,()]+,\s*(?!")/
private DOMAIN_OF    = {"ui" => "ui", "help" => "help", "sys" => "system", "ring" => "companion"}

private record Wrapped, domain : String, msgid : String, site : String

# The Crystal literal's text as the catalog key. Only `\"`, `\\` and `\n` are allowed: a
# msgid with any other escape, or with interpolation, would never equal its catalog key.
private def unescape_msgid(raw : String, site : String, bad : Array(String)) : String?
  if raw.includes?("\#{")
    bad << "#{site}: a msgid interpolates — use a %{name} placeholder"
    return nil
  end
  raw.gsub(/\\(.)/) do |whole|
    case $1
    when "\"" then "\""
    when "\\" then "\\"
    when "n"  then "\n"
    else
      bad << "#{site}: escape #{whole} is not allowed in a msgid"
      whole
    end
  end
end

private def wrapped_in_source(bad : Array(String), dynamic : Array(String)) : Array(Wrapped)
  found = [] of Wrapped
  Dir.glob(File.join(SRC_ROOT, "**", "*.cr")).sort.each do |path|
    rel = path[(SRC_ROOT.size + 1)..]
    File.read(path).each_line.with_index(1) do |line, no|
      next if line.lstrip.starts_with?('#')
      site = "#{rel}:#{no}"
      line.scan(CALL_RE) do |m|
        unescape_msgid(m[2], site, bad).try { |s| found << Wrapped.new(DOMAIN_OF[m[1]], s, site) }
      end
      line.scan(CALL_N_RE) do |m|
        {m[2], m[3]}.each do |raw|
          unescape_msgid(raw, site, bad).try { |s| found << Wrapped.new(DOMAIN_OF[m[1]], s, site) }
        end
      end
      dynamic << site if line.matches?(DYNAMIC_RE) || line.matches?(DYNAMIC_N_RE)
    end
  end
  found
end

# Tables translated at their draw site. One line per table; a sweep that starts translating a
# table at render time adds it here in the same change.
private def wrapped_in_tables : Array(Wrapped)
  found = [] of Wrapped
  found << Wrapped.new("companion", Gori::Tui::Companion::GREETING, "Companion::GREETING")
  Gori::Tui::Tutorial::COMPANION_LINES.each do |(_, line)|
    found << Wrapped.new("companion", line, "Tutorial::COMPANION_LINES")
  end
  # Verb titles are drawn through I18n.ui by the palette, the space menu and the hotkeys
  # editor; descriptions through I18n.help by the hotkeys editor's footer.
  Gori::Verbs.registry.each do |v|
    found << Wrapped.new("ui", v.title, "Verb #{v.id}")
    found << Wrapped.new("help", v.description, "Verb #{v.id}")
  end
  # Help: section heads and item descriptions (HelpView.draw_row / shortcut_rows), and the
  # Query page's tables read from QL and InterceptFilter (HelpView.query_rows).
  Gori::Tui::HelpView::SECTIONS.each do |(title, items)|
    found << Wrapped.new("help", title, "HelpView::SECTIONS")
    items.each { |it| found << Wrapped.new("help", it.desc, "HelpView::SECTIONS #{title}") }
  end
  Gori::QL::SYNTAX_HELP.each { |(_, meaning)| found << Wrapped.new("help", meaning, "QL::SYNTAX_HELP") }
  Gori::QL::FIELD_HELP.each_value { |text| found << Wrapped.new("help", text, "QL::FIELD_HELP") }
  Gori::InterceptFilter::FIELD_HELP.each_value { |text| found << Wrapped.new("help", text, "InterceptFilter::FIELD_HELP") }
  Gori::QL::CAVEATS.each do |(what, why)|
    found << Wrapped.new("help", what, "QL::CAVEATS")
    found << Wrapped.new("help", why, "QL::CAVEATS")
  end
  # Settings: field labels (ui) and hints (help), catalog section titles (ui) and
  # descriptions (help), the group strip (ui).
  Gori::Tui::SettingsView::SECTIONS.each_value do |fields|
    fields.each do |field|
      found << Wrapped.new("ui", field.label, "SettingsView::Field")
      found << Wrapped.new("help", field.hint, "SettingsView::Field")
    end
  end
  Gori::Tui::SettingsCatalog.all.each do |sec|
    found << Wrapped.new("ui", sec.title, "SettingsCatalog #{sec.id}")
    found << Wrapped.new("help", sec.desc, "SettingsCatalog #{sec.id}")
  end
  Gori::Tui::SettingsCatalog::GROUPS.each { |(_, label)| found << Wrapped.new("ui", label, "SettingsCatalog::GROUPS") }
  # Menus and chips whose labels are tables.
  Gori::Tui::SpaceMenu::SECTION_LABELS.each_value { |l| found << Wrapped.new("ui", l, "SpaceMenu::SECTION_LABELS") }
  Gori::Tui::SpaceMenu::GROUP_LABELS.each_value { |l| found << Wrapped.new("ui", l, "SpaceMenu::GROUP_LABELS") }
  Gori::Tui::HotkeysOverlay::SCOPE_LABEL.each_value { |l| found << Wrapped.new("ui", l, "HotkeysOverlay::SCOPE_LABEL") }
  Gori::Tui::Jobs::KIND_LABELS.each_value { |l| found << Wrapped.new("ui", l, "Jobs::KIND_LABELS") }
  found << Wrapped.new("ui", "jobs", "Jobs::KIND_LABELS fallback") # `KIND_LABELS.fetch(kind, "jobs")`
  # The Query page's own heads ("SYNTAX", …) are built as English keys and translated by draw_row.
  Gori::Tui::HelpView.query_rows.each { |r| found << Wrapped.new("help", r.a, "HelpView.query_rows") if r.kind == :head }
  # A settings choice draws `choice_labels[code]` through I18n.ui — except a language's own
  # name, which SettingsView#choice_label leaves alone.
  Gori::Tui::SettingsView::SECTIONS.each_value do |fields|
    fields.each do |field|
      field.choice_labels.try &.each_value do |label|
        next if I18n::LANGUAGES.any? { |l| l.endonym == label }
        found << Wrapped.new("ui", label, "SettingsView choice_labels")
      end
    end
  end
  found
end

private def all_wrapped : Array(Wrapped)
  bad = [] of String
  dynamic = [] of String
  wrapped_in_source(bad, dynamic) + wrapped_in_tables
end

private def placeholders(s : String) : Array(String)
  s.scan(/%\{(\w+)\}/).map(&.[1]).sort
end

# The `^X` tokens `Hotkeys.retag` rewrites: a translation that drops one stops advertising a
# key, and one that gains one advertises a key that does not exist.
private def carets(s : String) : Array(String)
  s.scan(/\^[A-Za-z,1-9]/).map(&.[0]).sort
end

private def report(line : String) : Nil
  STDERR.puts "  i18n: #{line}" if ENV["GORI_I18N_REPORT"]?.presence
end

describe "the Korean catalog" do
  it "ships one file per non-English language, keyed by domain" do
    I18n::CATALOG_RAW.keys.sort.should eq((I18n.codes - ["en"]).sort)
    cat = I18n.catalog("ko").should_not be_nil
    (cat.keys - I18n::Domain.values.map(&.key)).should be_empty
  end

  it "keeps every placeholder and key token the English carries" do
    cat = I18n.catalog("ko").not_nil!
    offenders = [] of String
    cat.each do |domain, entries|
      entries.each do |msgid, text|
        next if text.empty?
        offenders << "#{domain}: #{msgid.inspect} — placeholders differ" unless placeholders(text) == placeholders(msgid)
        offenders << "#{domain}: #{msgid.inspect} — key tokens differ" unless carets(text) == carets(msgid)
        if !placeholders(msgid).empty? && text.matches?(/%(?![{%])/)
          offenders << "#{domain}: #{msgid.inspect} — a stray % would break interpolation"
        end
      end
    end
    offenders.should be_empty
  end

  it "only ever wraps a plain single-line literal" do
    bad = [] of String
    dynamic = [] of String
    wrapped_in_source(bad, dynamic)
    bad.should be_empty
    report("#{dynamic.size} dynamic msgid site(s): #{dynamic.first(5).join(", ")}") unless dynamic.empty?
  end

  it "has no entry for a msgid nothing wraps — a reworded English literal cannot orphan a translation" do
    expected = {} of String => Set(String)
    all_wrapped.each { |w| (expected[w.domain] ||= Set(String).new) << w.msgid }
    cat = I18n.catalog("ko").not_nil!
    orphans = [] of String
    cat.each do |domain, entries|
      entries.each_key do |msgid|
        orphans << "#{domain}: #{msgid.inspect}" unless expected[domain]?.try(&.includes?(msgid))
      end
    end
    orphans.should be_empty
  end

  it "has an entry for every wrapped msgid (the failure lists the pairs to paste into ko.json)" do
    cat = I18n.catalog("ko").not_nil!
    missing = [] of String
    untranslated = 0
    all_wrapped.each do |w|
      text = cat[w.domain]?.try(&.[w.msgid]?)
      if text.nil?
        missing << %(  "#{w.domain}": #{w.msgid.to_json}: ""   ← #{w.site})
      elsif text.empty? || text == w.msgid
        untranslated += 1
      end
    end
    report("#{untranslated} untranslated entr#{untranslated == 1 ? "y" : "ies"}") if untranslated > 0
    missing.should be_empty
  end
end
