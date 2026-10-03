require "json"
require "../decoder"

# DECODER section: the Decoder tab's named chain specs. See settings.cr for the
# module-level overview and the load/save/serialize orchestration.
module Gori::Settings
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
  # callable as a step after the library it came from was dropped would be a ghost.
  private def self.reset_decoder : Nil
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
