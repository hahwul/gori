require "../decoder"
require "../proxy/ws/frame"
require "./template"
require "./types"

module Gori::Fuzz
  # One part of a WebSocket script: an outbound frame's marked payload template, plus the
  # framing the operator declared for it.
  #
  # The shape is carried here rather than re-derived at render time because it is the
  # operator's test case, not a property of the payload — a FIN=0 fragment, an RSV1 bit on a
  # socket that negotiated no extension, a `len=` that disagrees with the bytes. `Fuzz::Plan`
  # takes it off `WsMessageSource` and hands it straight to `Repeater::WsEngine::OutMsg`;
  # nothing between the two may fold it, which is the defect `WsEngine::OutMsg`'s own comment
  # records for the repeater ("twelve distinct shapes replayed as seven identical ones").
  struct FrameTemplate
    getter template : Template
    getter opcode : Int32
    getter shape : Proxy::WS::Shape
    # PROVENANCE, per frame: true when these bytes were CAPTURED, false when the operator typed
    # them here and now (`--message`, MCP `messages`). Per-frame and not per-run because the two
    # populations mix in one list — the same reason `WsEngine::OutMsg#evidence` is.
    getter? evidence : Bool

    def initialize(@template : Template, @opcode : Int32, @shape : Proxy::WS::Shape,
                   @evidence : Bool)
    end
  end

  # One variation of a script, rendered: the handshake bytes with their payload spans, and the
  # outbound frames with theirs.
  #
  # The handshake's spans are separate from the frames' because the buffers are. A caller that
  # flattened them would hand `Env.expand_bindings` offsets computed against a different slice
  # — see `WsFrame#payload_spans`.
  record Rendered,
    handshake : Bytes,
    handshake_spans : Array({Int32, Int32}),
    frames : Array(WsFrame)

  # A marked WebSocket SCRIPT under ONE global position index space.
  #
  # ## Why one index space, and why the handshake is part 0
  #
  # Every attack mode, `--mark`, each position's `¦chain`, `PayloadSet` and `AutoEncode` are
  # defined over the payload-VALUE vector, not over a buffer — the only buffer-level operation
  # in `Generator#emit` is the splice itself. So a composite that concatenates its parts'
  # position lists into one vector, and fans a rendered value vector back out to the parts,
  # leaves `Mode`, `Generator#sniper/battering/pitchfork/cluster`, `Plan.refuse_unusable_chains`
  # and the payload layer working unchanged. That is the whole trick: Sniper over a two-frame
  # script means what it has always meant, and a Pitchfork can lock a handshake header to a
  # frame field.
  #
  # The HANDSHAKE is part 0 rather than an un-fuzzable prefix. A WS upgrade head IS an ordinary
  # HTTP request head, so `Template` already fits it exactly, and marking `Sec-WebSocket-Protocol`
  # or a cookie in the upgrade is a real test that would otherwise need a refusal. It also keeps
  # the four passes that read a request as a request — `urlencoded_positions`, `AutoEncode`,
  # `ContentLength.sync_at`, `Outbound.request_target` — aimed at the one part that is one.
  #
  # ## Why a sibling of `Template` and not a subclass of it
  #
  # Every part IS a `Template`, so `parse`'s `§§` escape rule, the byte-oriented render that
  # keeps a non-UTF-8 frame intact, and the marking helpers are reused verbatim instead of
  # re-derived. What differs is only the RETURN of a render — several buffers, not one — which
  # is a different method signature and not an override.
  struct WsScript
    getter handshake : Template
    getter frames : Array(FrameTemplate)
    # The global index of each part's FIRST position: `offsets[0]` is the handshake (always 0)
    # and `offsets[k + 1]` is `frames[k]`. Size is `frames.size + 1`.
    getter offsets : Array(Int32)
    # Every part's positions concatenated in part order, re-indexed to the global space.
    getter positions : Array(Template::Position)

    def initialize(@handshake : Template, @frames : Array(FrameTemplate),
                   @offsets : Array(Int32), @positions : Array(Template::Position))
    end

    def self.build(handshake : Template, frames : Array(FrameTemplate)) : WsScript
      offsets = Array(Int32).new(frames.size + 1)
      positions = [] of Template::Position
      cursor = 0
      offsets << cursor
      # `Position#index` is written at parse time and read NOWHERE in `src/` — every consumer
      # indexes the array instead — so re-stamping it with the global index here is free and
      # keeps the record honest for anything that later does read it.
      handshake.positions.each do |p|
        positions << Template::Position.new(cursor, p.default, p.chain)
        cursor += 1
      end
      frames.each do |f|
        offsets << cursor
        f.template.positions.each do |p|
          positions << Template::Position.new(cursor, p.default, p.chain)
          cursor += 1
        end
      end
      new(handshake, frames, offsets, positions)
    end

    def position_count : Int32
      @positions.size
    end

    def default_payloads : Array(String)
      @positions.map(&.default)
    end

    def apply_chains(payloads : Array(String), registry : Decoder::Registry) : Array(String)
      apply_chains_reported(payloads, registry).map(&.[0])
    end

    # Through `Template`'s class-method form, so a `¦chain` behaves identically on a WebSocket
    # sweep and an HTTP one and the failure sentence has one author.
    def apply_chains_reported(payloads : Array(String),
                              registry : Decoder::Registry) : Array({String, String?})
      Template.apply_chains_reported(@positions, payloads, registry)
    end

    # HANDSHAKE positions only — the global indices of the ones inside its query string or
    # urlencoded body.
    #
    # A frame payload is not a URL. Percent-encoding a payload spliced into a JSON TEXT frame
    # would send `%3Cscript%3E` where the operator marked `<script>`, i.e. a different test, and
    # `AutoEncode`'s whole justification is that a query/form position REQUIRES the escape to
    # reach the app intact. The handshake's own query string keeps it: `GET /ws?room=§X§` is an
    # ordinary request target and behaves like one.
    def urlencoded_positions : Array(Int32)
      @handshake.urlencoded_positions
    end

    # Splice one variation's payload vector across every part.
    #
    # `payloads` is the GLOBAL vector; each part takes the slice `offsets` assigns it. A short
    # vector (a spec or a non-generator caller) simply renders the parts it reaches — the same
    # tolerance `Template#render_spans` has for a payload list that is not `position_count` long.
    def render_spans(payloads : Array(String)) : Rendered
      hs_bytes, hs_spans = @handshake.render_spans(slice_for(payloads, 0, @handshake.position_count))
      rendered = Array(WsFrame).new(@frames.size)
      @frames.each_with_index do |f, k|
        bytes, spans = f.template.render_spans(
          slice_for(payloads, @offsets[k + 1], f.template.position_count))
        rendered << WsFrame.new(f.opcode, bytes, f.shape, f.evidence?, spans)
      end
      Rendered.new(hs_bytes, hs_spans, rendered)
    end

    # `payloads[from, count]`, clamped. Not `payloads[from, count]` alone: Crystal raises when
    # `from` is past the end, which a short vector reaches on the last part.
    private def slice_for(payloads : Array(String), from : Int32, count : Int32) : Array(String)
      return [] of String if count <= 0 || from >= payloads.size
      payloads[from, Math.min(count, payloads.size - from)]
    end
  end
end
