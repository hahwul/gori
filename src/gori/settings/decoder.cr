require "json"

# DECODER section: Decoder tab scratch state (global, not project data). See
# settings.cr for the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # Decoder tab scratch state (a global scratch tool, not project data). Each open
  # sub-tab (an independent conversion session) is restored on restart as a
  # {input, chain, name} tuple; decoder_chains are named, saved chain specs
  # (name -> spec) the user can re-load. Written only on commit (Esc/quit),
  # dirty-guarded, so an untouched Decoder tab never rewrites the file.
  # decoder_input/decoder_chain are the LEGACY single-session fields — read for
  # back-compat migration (see DecoderController), no longer written once
  # decoder_sessions exists.
  class_property decoder_input : String = ""
  class_property decoder_chain : String = ""
  class_property decoder_sessions : Array({String, String, String}) = [] of {String, String, String}
  class_property decoder_chains : Array({String, String}) = [] of {String, String}

  # Tolerant sub-tab session parse: a non-array (or absent) node keeps the current
  # value (older configs without a "sessions" array fall back to the legacy
  # input/chain scalars in DecoderController). Missing fields default to "" (a blank
  # session is valid — an empty sub-tab). Mirrors parse_decoder_chains.
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
  # value (older configs are safe); entries missing/blank "name" or "spec" are
  # dropped. Mirrors parse_tab_prefs.
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

  # Omit the whole block when there's nothing worth persisting — no saved chains,
  # no legacy scalars, and every open session blank+unnamed — so an untouched OR
  # cleared Decoder workbench never writes a "decoder" section. Once any session
  # has content we write the "sessions" array (the source of truth); until then we
  # preserve the legacy input/chain scalars so an un-opened Decoder tab never loses
  # them. (`all?` is vacuously true for an empty array.)
  private def self.serialize_decoder(j : JSON::Builder) : Nil
    sessions_blank = decoder_sessions.all? { |(i, c, n)| i.empty? && c.empty? && n.empty? }
    unless sessions_blank && decoder_chains.empty? && decoder_input.empty? && decoder_chain.empty?
      j.field "decoder" do
        j.object do
          if decoder_sessions.empty?
            j.field "input", decoder_input
            j.field "chain", decoder_chain
          else
            j.field "sessions" do
              j.array do
                decoder_sessions.each do |(input, chain, name)|
                  j.object do
                    j.field "input", input
                    j.field "chain", chain
                    j.field "name", name unless name.empty?
                  end
                end
              end
            end
          end
          unless decoder_chains.empty?
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
end
