module Gori
  # What a schema-less binary reader made of a body, and the one decision every surface that
  # offers such a rendering has to make: **is this rendering about THIS body, or is it what the
  # reader made of bytes that were never the format the header claimed?**
  #
  # `Gori::Msgpack` and `Gori::Cbor` both answer in this shape so the decision has one home.
  # Without it each caller re-derived it from the rendered TEXT — "did it come back `null`" —
  # which cannot tell those two apart at all: a reader with no schema makes *something* of any
  # bytes, and a PNG labelled `application/msgpack` rendered as a plausible-looking map with
  # the hex-view pointer suppressed. A rendering that is wrong is worse than a hex dump that is
  # right, and this is where that is enforced.
  module BinaryDocument
    # `json` is the projection as TEXT (never a parsed tree — it can hold a duplicate member,
    # which is a fact about the body and not a thing to merge away). `complete` is false when
    # the reader stopped early. `consumed` is how far into `data` it got, and `stop` names why
    # it stopped — nil when it did not.
    record Rendering, json : String, complete : Bool, consumed : Int32, stop : String? do
      # Is this rendering ABOUT the `size`-byte body it came from?
      #
      # Two failures wear the same `complete: false` and are opposite in what the operator
      # should be shown:
      #
      #   * a body the capture cap CUT SHORT — the reader consumed every byte it was given and
      #     wanted more. What it decoded is what the operator came for, so it is shown.
      #   * a body that is not this format — the reader hit something it could not read with
      #     bytes still to go, or finished a value early and left the rest lying there. There
      #     is nothing here about the body, and showing it costs the operator the binary
      #     placeholder that would have pointed at the hex view.
      #
      # So the test is where it stopped, not how far it got: running out of input at the very
      # end is truncation; anything else with bytes remaining is the header having lied.
      # The residual, stated rather than papered over: a body of a DOZEN bytes that is not this
      # format can be indistinguishable from a truncated one — a PNG's `0x89` opens a
      # MessagePack map of 9 entries and runs out exactly as a cut-off document would. At any
      # size a real body has, the reader stops with bytes still to go and this holds; measured
      # against PNG, gzip, JSON and HTML at 20 KB, all four are refused by both readers.
      def describes?(size : Int32) : Bool
        return true if complete
        stop == "truncated" && consumed >= size
      end
    end

    # Render `body` as the format its `content_type` claims, or nil when it claims neither —
    # and nil, too, when the rendering turns out not to be about this body (`describes?`).
    #
    # The dispatch is the content type ALONE and never a sniff: `MediaType.binary_document?` is
    # deliberately precise where `MediaType.json?` is permissive, because a failed JSON parse
    # costs one parse while a wrong binary rendering costs the operator the truth about a body.
    # An unlabelled body belongs in the Decoder tab, where the operator is the one deciding.
    def self.render(body : Bytes?, content_type : String?, *, indent : String? = nil) : {String, Rendering}?
      return nil unless body && !body.empty?
      msgpack = MediaType.msgpack?(content_type)
      return nil unless msgpack || MediaType.cbor?(content_type)
      r = msgpack ? Msgpack.render(body, indent: indent) : Cbor.render(body, indent: indent)
      return nil unless r.describes?(body.size)
      {msgpack ? "msgpack" : "cbor", r}
    end
  end
end
