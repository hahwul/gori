require "json"
require "../decoder"

# DECODER section: the Decoder tab's named chain specs. See settings.cr for the
# module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # LEGACY, READ-ONLY. Open Decoder sub-tabs used to live here, which carried one project's
  # decoded material into the next one on a project switch. They now live in each project's
  # own store (`Store::DECODER_SESSIONS_KEY`); this property only still parses so
  # DecoderController#restore_sessions can adopt a pre-upgrade block once and clear it.
  # Deliberately NOT serialized — writing it again would recreate the global block.
  class_property decoder_sessions : Array({String, String, String}) = [] of {String, String, String}

  # Named, saved chain specs (name -> spec) the user can re-load with ^O — and CALL by name as
  # a single chain step (`myenc > url-encode`) anywhere a spec is accepted. Global on purpose:
  # a chain like "base64-decode > gunzip" is tool config, reusable in every project — only
  # what was run THROUGH it is project data.
  @@decoder_chains = [] of {String, String}

  def self.decoder_chains : Array({String, String})
    @@decoder_chains
  end

  # Publishing to the Decoder engine rides the SETTER, not the load path. Every write goes
  # through here — the startup parse, ^S save, ^X delete, a spec fixture — so "a saved chain
  # is callable as a step" cannot come true in one surface and stay false in another.
  #
  # Published BEFORE the field is assigned: `Decoder.library=` rebuilds the registry, and if
  # that ever raises the two must not be left disagreeing (the ^O picker listing a chain the
  # engine never registered).
  def self.decoder_chains=(entries : Array({String, String})) : Array({String, String})
    Decoder.library = entries
    @@decoder_chains = entries
    entries
  end

  # Drop a named chain from the library and persist. `name` is the key the whole library is
  # addressed by (save_chain already replaces a same-named entry), so there is no id to
  # carry. Returns whether the write reached disk; a name that is not there is a successful
  # no-op, because the caller's intent — "this chain is not in the library" — already holds.
  #
  # Unlike drop_legacy_decoder_sessions this CAN go through `save`: `chains` is still
  # serialized, so the 3-way merge sees the section change and this process wins it.
  #
  # A write that did not reach disk puts the entry BACK. The setter also republishes the
  # engine's library, so without this a refused save left the picker without the row and
  # the name unresolvable in every open conversion — while the toast said "could not delete"
  # and the next start brought it back. Memory follows disk here, not the other way round.
  def self.delete_decoder_chain(name : String) : Bool
    before = decoder_chains
    self.decoder_chains = before.reject { |(n, _)| n == name }
    return true if save
    self.decoder_chains = before
    false
  end

  # Erase a pre-upgrade `decoder.sessions` block from settings.json, keeping every other
  # section (including `decoder.chains`) byte-identical. Returns whether the file is now free
  # of it. Called once, by DecoderController#restore_sessions, after the sessions have been
  # adopted into a project store.
  #
  # `save` CANNOT do this. Its 3-way merge asks "did this process change the section?" by
  # comparing its own serialization against the same serialization at load time — and since
  # sessions are no longer serialized at all, `decoder` reads as unchanged on both sides and
  # therefore YIELDS TO DISK. The block would survive every future save and re-seed the next
  # project opened after every restart. So this rewrites the file it actually finds (never
  # this process's in-memory picture, which would clobber a concurrent peer's sections),
  # dropping exactly one field.
  def self.drop_legacy_decoder_sessions : Bool
    raw = load_raw
    return true unless raw # no file yet — nothing to erase
    root = (JSON.parse(raw).as_h? rescue nil)
    return false unless root
    dec = root["decoder"]?.try(&.as_h?)
    return true unless dec && dec.has_key?("sessions")
    kept = dec.reject("sessions")
    doc = JSON.build(indent: "  ") do |j|
      j.object do
        root.each do |k, v|
          next if k == "decoder"
          j.field k, v
        end
        j.field "decoder", kept unless kept.empty?
      end
    end
    write_private(path, doc)
    true
  rescue
    false
  end

  # Tolerant sub-tab session parse (legacy blocks only — see decoder_sessions): a non-array
  # (or absent) node keeps the current value. Missing fields default to "" (a blank session
  # is valid — an empty sub-tab). Mirrors parse_decoder_chains.
  private def self.parse_decoder_sessions(node : JSON::Any?) : Array({String, String, String})
    arr = node.try(&.as_a?)
    return decoder_sessions unless arr
    out = [] of {String, String, String}
    arr.each do |e|
      next unless o = e.as_h?
      input = o["input"]?.try(&.as_s?) || ""
      chain = o["chain"]?.try(&.as_s?) || ""
      name = o["name"]?.try(&.as_s?) || ""
      out << {input, chain, name}
    end
    out
  end

  # Tolerant named-chain parse: a non-array (or absent) node keeps the current
  # value; entries missing/blank "name" or "spec" are dropped. Mirrors parse_tab_prefs.
  #
  # A name the tab's own ^S would refuse (`Library.name_error`: a separator inside, an
  # `exec:` prefix) is KEPT here, on purpose: dropping it at load would erase the operator's
  # hand-edited or imported entry from disk at the next ^S (the 3-way merge's base is what
  # this parse produced). It stays a picker row, loadable by hand; `Library.register_all`
  # is what refuses to make it a callable step.
  private def self.parse_decoder_chains(node : JSON::Any?) : Array({String, String})
    arr = node.try(&.as_a?)
    return decoder_chains unless arr
    out = [] of {String, String}
    arr.each do |e|
      next unless o = e.as_h?
      name = o["name"]?.try(&.as_s?)
      spec = o["spec"]?.try(&.as_s?)
      next if name.nil? || name.empty? || spec.nil?
      out << {name, spec}
    end
    out
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). `chains` goes
  # through the SETTER so the Decoder engine's library is emptied with it — a chain left
  # callable as a step after the library it came from was dropped would be a ghost. The
  # legacy `sessions` block is cleared too: it is never written back, but an unadopted
  # pre-upgrade block would otherwise survive a factory reset in memory.
  private def self.reset_decoder : Nil
    self.decoder_sessions = [] of {String, String, String}
    self.decoder_chains = [] of {String, String}
  end

  # Omit the whole block when there are no saved chains, so an untouched OR cleared Decoder
  # workbench never writes a "decoder" section. Open sub-tabs are NOT written here any more
  # (they belong to the project store): a save that re-emitted them would put the
  # cross-project carry-over straight back.
  private def self.serialize_decoder(j : JSON::Builder) : Nil
    unless decoder_chains.empty?
      j.field "decoder" do
        j.object do
          j.field "chains" do
            j.array do
              decoder_chains.each { |(name, spec)| j.object { j.field "name", name; j.field "spec", spec } }
            end
          end
        end
      end
    end
  end
end
