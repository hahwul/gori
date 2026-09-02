require "json"
require "../i18n"

# LANGUAGE section: which language each area of the TUI speaks. See settings.cr for the
# load/save orchestration and i18n.cr for the catalogs these codes select. Settings only STORES
# the choice — `Tui.apply_language` is the one place it becomes the live languages, which is
# what keeps `gori run` / `gori mcp` English.
module Gori::Settings
  # "en", not "auto": an upgrade must not flip an existing install's screen because its shell
  # happens to export a Korean locale, and a fresh install is asked on the wizard's first step.
  # `auto` is an explicit choice (GORI_LANG → LC_ALL → LC_MESSAGES → LANG, see I18n.resolve_auto).
  DEFAULT_LANGUAGE = I18n::DEFAULT_CODE # a code, or I18n::AUTO
  # Each area follows the default until told otherwise. Codes, never enums, like every section.
  DEFAULT_LANGUAGE_OVERRIDE = I18n::INHERIT

  class_property language_default : String = DEFAULT_LANGUAGE
  class_property language_ui : String = DEFAULT_LANGUAGE_OVERRIDE
  class_property language_help : String = DEFAULT_LANGUAGE_OVERRIDE
  class_property language_system : String = DEFAULT_LANGUAGE_OVERRIDE
  class_property language_companion : String = DEFAULT_LANGUAGE_OVERRIDE

  # Derived from I18n so a new language reaches this section by existing.
  def self.language_defaults : Array(String)
    I18n.codes + [I18n::AUTO]
  end

  def self.language_overrides_allowed : Array(String)
    [I18n::INHERIT] + I18n.codes
  end

  def self.normalize_language_default(s : String) : String
    language_defaults.includes?(s) ? s : DEFAULT_LANGUAGE
  end

  def self.normalize_language_override(s : String) : String
    language_overrides_allowed.includes?(s) ? s : DEFAULT_LANGUAGE_OVERRIDE
  end

  # The per-area picks that differ from "follow the default", keyed the way I18n.apply takes
  # them.
  def self.language_overrides : Hash(I18n::Domain, String)
    picks = {} of I18n::Domain => String
    {
      I18n::Domain::Ui        => language_ui,
      I18n::Domain::Help      => language_help,
      I18n::Domain::System    => language_system,
      I18n::Domain::Companion => language_companion,
    }.each { |domain, code| picks[domain] = code unless code == I18n::INHERIT }
    picks
  end

  # Tolerant language section: absent/non-object keeps current; an unknown code → default.
  private def self.parse_language(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    o["default"]?.try(&.as_s?).try { |v| self.language_default = normalize_language_default(v) }
    o["ui"]?.try(&.as_s?).try { |v| self.language_ui = normalize_language_override(v) }
    o["help"]?.try(&.as_s?).try { |v| self.language_help = normalize_language_override(v) }
    o["system"]?.try(&.as_s?).try { |v| self.language_system = normalize_language_override(v) }
    o["companion"]?.try(&.as_s?).try { |v| self.language_companion = normalize_language_override(v) }
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). One assignment
  # per field serialize_language writes — the two lists are kept in step by hand, as everywhere.
  private def self.reset_language : Nil
    self.language_default = DEFAULT_LANGUAGE
    self.language_ui = DEFAULT_LANGUAGE_OVERRIDE
    self.language_help = DEFAULT_LANGUAGE_OVERRIDE
    self.language_system = DEFAULT_LANGUAGE_OVERRIDE
    self.language_companion = DEFAULT_LANGUAGE_OVERRIDE
  end

  # Omitted entirely while every field is at its factory default, so an English install's
  # settings.json stays quiet and the 3-way merge has nothing to reconcile.
  private def self.serialize_language(j : JSON::Builder) : Nil
    unless language_default == DEFAULT_LANGUAGE &&
           language_ui == DEFAULT_LANGUAGE_OVERRIDE &&
           language_help == DEFAULT_LANGUAGE_OVERRIDE &&
           language_system == DEFAULT_LANGUAGE_OVERRIDE &&
           language_companion == DEFAULT_LANGUAGE_OVERRIDE
      j.field "language" do
        j.object do
          j.field "default", language_default
          j.field "ui", language_ui
          j.field "help", language_help
          j.field "system", language_system
          j.field "companion", language_companion
        end
      end
    end
  end
end
