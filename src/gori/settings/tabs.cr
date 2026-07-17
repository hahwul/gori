require "json"

# TAB BAR section: top tab-bar order/visibility. See settings.cr for the
# module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # Top tab-bar layout: ordered {tab-id, visible?}. Empty = never customized → Chrome
  # reconciles to catalog defaults. Opaque String ids (Crystal has no runtime String→Symbol);
  # Chrome maps ids→catalog symbols. Only an EXPLICIT false hides a tab.
  class_property tab_prefs : Array({String, Bool}) = [] of {String, Bool}

  # Tolerant tab-bar parse: a non-array (or absent) node keeps the current value;
  # entries missing/blank "id" are dropped; "visible" absent or non-bool ⇒ visible
  # (never hide a tab from a malformed flag). Unknown/duplicate ids are left for
  # Chrome.reconcile to normalize against the canonical catalog.
  private def self.parse_tab_prefs(node : JSON::Any?) : Array({String, Bool})
    arr = node.try(&.as_a?)
    return tab_prefs unless arr
    out = [] of {String, Bool}
    arr.each do |e|
      next unless o = e.as_h?
      id = o["id"]?.try(&.as_s?)
      next if id.nil? || id.empty?
      out << {remap_legacy_id(id), o["visible"]?.try(&.as_bool?) != false} # only explicit false hides
    end
    out
  end

  # Rewrite a pre-rename tab id or verb id to its current name, so a settings.json
  # written before the Repeater/Probe/Issues/Decoder rename keeps its saved tab
  # order/visibility and custom keybindings instead of Chrome.reconcile /
  # Hotkeys.rebindable_overrides silently dropping the now-unknown id. Whole-string
  # (not prefix) substitution so compound ids like "finding.replay-flow" become
  # "issue.repeater-flow". Idempotent on already-new ids (they contain no old token).
  # Order matters: "findings" before "finding".
  private def self.remap_legacy_id(id : String) : String
    id.gsub("findings", "issues")
      .gsub("finding", "issue")
      .gsub("replay", "repeater")
      .gsub("prism", "probe")
      .gsub("convert", "decoder")
  end

  # Omit when empty so an untouched install never writes an ambiguous "tabs": []
  # (a human reader might misread it as "all hidden").
  private def self.serialize_tabs(j : JSON::Builder) : Nil
    unless tab_prefs.empty?
      j.field "tabs" do
        j.array do
          tab_prefs.each { |(id, vis)| j.object { j.field "id", id; j.field "visible", vis } }
        end
      end
    end
  end
end
