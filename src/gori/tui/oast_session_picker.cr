require "./screen"
require "./theme"
require "./fmt"
require "./frame"
require "./oast_provider_picker"
require "../plural"

module Gori::Tui
  # RESUME LISTENER: pick one of this project's persisted OAST sessions and start polling it
  # again.
  #
  # Registration state is the only part of an OAST listener that is NOT reconstructible: the
  # correlation id, the poll secret and the interactsh RSA private key are minted once, by the
  # server, and the payloads planted out in the world resolve against THAT triple and no other.
  # gori has always written them to `oast_sessions` — and never read them back, so `^R` could
  # only ever mint a fresh registration. Every payload planted before a restart was dead, which
  # is precisely backwards for the one workbench whose findings arrive late.
  #
  # Two actions, because a session has two ends: `↵` resumes it (the reason this card exists)
  # and `x` releases it — deregisters the server-side state for an engagement that is over,
  # without touching the callbacks already collected. Neither deletes anything local; the rows
  # in `oast_callbacks` are evidence.
  class OastSessionPicker < OastPicker
    # One persisted session as the card shows it. `hits` is the controller's own per-session
    # counter (the TOTAL folded, not the windowed view's size) and `live` marks the sessions
    # already polling — those rows stay listed rather than being filtered out, because a card
    # that silently omitted the running listener would read as "that session is gone".
    record Row,
      session_id : Int64,
      provider : String,
      payload_host : String,
      started_at : Time,
      hits : Int32,
      live : Bool

    # Set by the open-site; runs for the `x` action instead of the ↵ commit.
    property on_release : Proc(Int64, Nil)?

    def initialize(@rows : Array(Row))
    end

    def entry_count : Int32
      @rows.size
    end

    def selected_row : Row?
      @rows[@selected]?
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::OastSession
    end

    def title : String
      "RESUME LISTENER"
    end

    def hint : String
      "↑/↓ select · ↵ resume · x release (deregister) · esc cancel"
    end

    # ↵ resumes, `x` releases, esc cancels; j/k are the vim nav every other picker gives.
    #
    # `x` is a plain letter and that is safe HERE in a way it would not be in a
    # FilterPickerOverlay, where every printable belongs to the query. This card has no filter
    # — a project's session list is a handful of rows — so letters are free to be actions.
    #
    # A release does NOT commit: the card stays up. Releasing is a housekeeping pass over a
    # finished engagement ("drop these three"), and closing after each one would make the
    # operator reopen the card between them.
    private def letter_key(c : Char) : Nil
      release_selected if c == 'x'
    end

    # Hand the selected session to the open-site's release closure and mark the row released
    # in place, so the card reflects what just happened without a reopen. The row keeps its
    # place in the list: it is still resumable (interactsh rebuilds a deregistered session
    # from the same key), so removing it would overstate what a release does.
    private def release_selected : Nil
      row = @rows[@selected]?
      return unless row
      if cb = @on_release
        cb.call(row.session_id)
      end
      @rows[@selected] = row.copy_with(live: false)
    end

    # A session IS its payload host to the operator — "which of these is the oast.pro one" is
    # the question this card gets asked.
    private def row_parts(idx : Int32) : {String, String, String, Bool}
      row = @rows[idx]
      {row.provider, row.payload_host, meta_text(row), row.live}
    end

    private def meta_text(row : Row) : String
      base = "#{Gori.plural(row.hits, "hit")} · #{Fmt.ago(row.started_at)}"
      row.live ? "#{base} · ● live" : base
    end
  end
end
