require "../store"
require "../fuzz/template"
require "./flow_request"

module Gori::Repeater
  # The one predicate the headless send seams ask before replaying a saved session:
  # "would the Repeater TAB send different bytes than these?".
  #
  # PROVENANCE (the long form is `tui/repeater_view/markers.cr#markers_live?`): `§…§` and its
  # `¦chain` are the operator's DRAFT language, not a value the wire can carry. A `§` that
  # arrived as CAPTURED evidence is DATA — U+00A7 is ordinary text, ubiquitous in German and
  # legal bodies — so `gori run repeater <id>`, MCP `send_request` and a retest step replay
  # those bytes EXACTLY, and must keep doing so. That half is right and is not what this is for.
  #
  # The other half is a session whose `§` can only be the operator's, where the tab renders
  # each `§v¦chain§` through its Decoder chain before the socket sees it and the headless
  # paths rendered nothing — so the SAME session sent from two surfaces put two different
  # bodies on the wire, under two different Content-Lengths, with neither surface saying so
  # (#1068). There are TWO such sessions, and the TUI already draws the line for both:
  #
  #   * NO source flow (`flow_id` NULL) — authored with `^N`, or created by `gori run repeater
  #     create` / MCP `create_repeater`. `markers_live?` is `!@evidence || @markers_declared`,
  #     so these are live unconditionally.
  #   * A flow-seeded session the operator MARKED BY HAND. `RepeaterView#adopt_capture_markers`
  #     re-derives that on every reopen, from the one piece of evidence the row does not carry:
  #     a `§` that is in the buffer and was NOT in the origin's bytes can only have been typed
  #     here. The same two reads answer it here, so the send seams draw the line the tab draws
  #     rather than a weaker one — this is the commonest way a marker gets into a session at
  #     all (`^R` off History, then `^T`), and keying only on `flow_id` would have left it
  #     shipping `user=§admin¦base64-encode§` with `isError:false`.
  #
  # Where the CAPTURE carried a `§` too, gori genuinely cannot tell one from the other: the
  # tab leaves its markers INERT and says so on the REQUEST border, and the headless bytes
  # then match it exactly. Nothing to refuse. Same for a flow that is gone — the tab is inert
  # there too.
  #
  # Rendering headlessly is the fix that cannot be made: this predicate is asked of stored
  # bytes, and on an inert row the answer would be "delete two bytes the origin really sent".
  # So the divergence is REFUSED at the seam instead, the way `minimize` already refuses the
  # same shape (`Repeater::Minimize` has no marker language either). A refusal is recoverable
  # — the operator removes the markers, sweeps the marked request as a Fuzzer TEMPLATE (the
  # one seed that reads `§…§` as positions; see `.refusal`), or says the bytes are the message
  # with the surface's own `verbatim`.
  module DraftMarkers
    # True when the session holds at least one CLOSED `§…§` region that the Repeater tab would
    # RENDER — i.e. when replaying these bytes is a divergence and not a faithful replay.
    #
    # The byte prefilter is not just speed: `marked_spans` walks CHARS, and a stored request is
    # routinely not valid UTF-8. `marker_bytes_in?` is a byte scan over the two-byte UTF-8
    # encoding of `§` and is exactly as precise (UTF-8 is self-synchronizing), so the char walk
    # — and the flow read below it — only ever run on a buffer that really does carry one.
    # `request` is the bytes the send will carry — the row's own by default, or a per-send copy
    # (`repeater send --path`) that may no longer hold the stored marker at all.
    def self.live?(store : Store, rec : Store::RepeaterRecord, request : Bytes = rec.request) : Bool
      return false unless Fuzz::Template.marker_bytes_in?(request)
      return false if Fuzz::Template.marked_spans(String.new(request)).empty?
      fid = rec.flow_id
      return true unless fid
      operator_marked?(store, fid)
    end

    # Whether the session is still EVIDENCE: seeded from a flow (`flow_id`) and still holding exactly
    # the bytes that seed produced (`FlowRequest.build`, in either request-line form, since
    # `--keep-request-line` / MCP `keep_request_line` stores the absolute one), so a `$ENV`/`$GEN`
    # token in it is one the capture brought and goes out literally (#1670), as in the Repeater
    # tab. Asked of the STORED row: a send's own `--path`/`-H` leaves it evidence and expands only
    # what the operator added, as a flow replay does. An edited row is the operator's draft again,
    # and so is one whose seed is gone: nothing is left to tell the capture's tokens from typed ones.
    def self.evidence?(store : Store, rec : Store::RepeaterRecord) : Bool
      return false unless (fid = rec.flow_id) && (detail = store.get_flow(fid))
      FlowRequest.build(detail).bytes == rec.request ||
        FlowRequest.build(detail, rewrite_absolute_form: false).bytes == rec.request
    rescue FlowRequest::PseudoHeaderHead
      false
    end

    # Why a race/timing group whose members' `evidence?` answers are `captured` cannot ride one
    # plan, or nil. The group is one Sender, so an untouched seed beside a draft would have its
    # captured tokens expanded as the draft's (#1670); the TUI race refuses the same group. A
    # verbatim group expands no member, so it has nothing to mix.
    # `what` names the group the caller sends ("a race", "a timing run").
    def self.mixed_group_refusal(captured : Array(Bool), verbatim : Bool, what : String = "a race") : String?
      return nil if verbatim || captured.all? || captured.none?
      "the sessions mix captured requests (untouched flow seeds) and drafts — #{what} needs one " \
      "provenance (all captured or all drafts), so the seeds' own tokens are not expanded as a " \
      "draft's. Send them separately, or edit the seeds into drafts"
    end

    # `RepeaterView#adopt_capture_markers`' test, asked of the store instead of the tab: did
    # the flow this session was seeded from carry a `§` of its own? Head AND body, because a
    # `§` in either is one gori cannot attribute — and the seed read these same stored bytes,
    # truncation included, so the two sides are comparable even for a capture whose body was
    # cut at the cap.
    private def self.operator_marked?(store : Store, flow_id : Int64) : Bool
      detail = store.get_flow(flow_id)
      return false unless detail # seed lost → the tab is inert too
      return false if Fuzz::Template.marker_bytes_in?(detail.request_head)
      return false if (body = detail.request_body) && Fuzz::Template.marker_bytes_in?(body)
      true
    end

    # The refusal: what this path would have sent, and why that is not what the operator wrote.
    #
    # `remedy` is the caller's own sentence, and it is NOT "use the Fuzzer on this session".
    # Both headless fuzz seeds (`fuzz_start{repeater_id}`, `gori run fuzz --repeater`) run the
    # stored bytes through `Template.escape_literal_markers` on purpose — a repeater row's `§`
    # is literal text there and `--auto`/`--mark` define the positions — so prescribing that
    # route would answer a divergence with a second one. The route that DOES read `§…§` as
    # positions is the template source (`--request=FILE`, `fuzz_start{template}`), which is
    # what each surface names, beside its own `verbatim`.
    def self.refusal(id : Int64, remedy : String) : String
      "repeater ##{id} holds §…§ markers — the Repeater tab renders each one through its " \
      "¦chain before sending, and this path cannot, so the send would put the literal § bytes " \
      "on the wire under a Content-Length framed around them. #{remedy}"
    end
  end
end
