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
    # the reader stopped early. `consumed` is how far into `data` it got, `stop` names why it
    # stopped — nil when it did not — and `decoded` is false when the whole rendering is one
    # `$partial` marker, i.e. the reader made NOTHING of the body it was handed.
    record Rendering, json : String, complete : Bool, consumed : Int32, stop : String?,
      decoded : Bool do
      # Is this rendering ABOUT the `size`-byte body it came from?
      #
      # THREE failures wear the same `complete: false`, and what the operator should be shown
      # differs:
      #
      #   * a body the capture cap CUT SHORT — the reader made a document out of the bytes in
      #     front of the cut, then consumed every byte it had left and wanted more. What it
      #     decoded is what the operator came for, so it is shown.
      #   * a body that is not this format — the reader hit something it could not read with
      #     bytes still to go, or finished a value early and left the rest lying there. There
      #     is nothing here about the body, and showing it costs the operator the binary
      #     placeholder that would have pointed at the hex view.
      #   * a body whose very FIRST header lied about a length. This one stops for want of
      #     input like the first case and lands on `consumed == size` like the first case — a
      #     short read consumes every byte it was given, by design, so that a cut landing
      #     inside a value still counts — yet the reader decoded nothing at all: the entire
      #     rendering is the marker. `{` is CBOR major 3 with additional info 27, so any JSON
      #     body under an `application/cbor` label (an ordinary mislabel) reads as a text
      #     string of 2.4 × 10^18 bytes and took exactly this path: a 20 KB response was
      #     replaced in the detail panel by `{"$partial": "truncated"}`, with the binary
      #     placeholder suppressed because a document had "decoded".
      #
      # So the test has three parts — where it stopped, how far it got, and whether it made
      # anything of the body at all. `decoded` is the third, and it is not a size heuristic:
      # it is false exactly when the rendering has no content, which is a rendering about
      # nothing whatever the bytes were.
      #
      # The residual, stated rather than papered over. A body of a DOZEN bytes that is not this
      # format can be indistinguishable from a truncated one — a PNG's `0x89` opens a
      # MessagePack map of 9 entries and runs out exactly as a cut-off document would. And
      # `decoded` does not reach a CONTAINER header that lies: msgpack `0xdd` followed by ASCII
      # declares an array of a billion elements and renders the bytes that really are there as
      # its first few, which is a rendering of this body's bytes and passes. Measured against
      # PNG, gzip, zlib, JSON and HTML at 20 KB, all five are refused by both readers.
      def describes?(size : Int32) : Bool
        return true if complete
        decoded && stop == "truncated" && consumed >= size
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
