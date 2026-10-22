require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "../discover"

module Gori::Tui
  # The custom-headers editor for a Discover run: a plain multi-line text editor,
  # one "Name: Value" per line. Opened from the Discover config popup's headers row;
  # esc saves the parsed headers and returns to the popup.
  # Host/Connection are always emitted by the engine, so entering them here is a
  # no-op (dropped on parse).
  #
  # A SUB-EDITOR on the Overlay seam (see overlay.cr): it has no cancel path at all, so
  # both esc and click-away commit, and the injected closure writes the parsed headers
  # back onto the Discover popup and re-opens it.
  #
  # A line gori will NOT send is a refusal, not a drop. `Headers.parse_lines` used to be
  # called here with its `rejected` out-collector omitted, so a value carrying CR/LF — a
  # request-splitting primitive, correctly refused — vanished with no word: the overlay
  # said `custom headers: 1 set`, 284 probes went out with ZERO carrying `Authorization`,
  # and the run reported `1 endpoint`. An authenticated sweep that runs unauthenticated
  # and reports "found nothing" over the whole authenticated surface is the worst way this
  # can fail, so esc now REFUSES to close while a line is unusable and names it. Deleting
  # or fixing the line always resolves it, and a blank line is not a header anyone asked
  # for (parse_lines skips those without reporting them).
  #
  # The refusal holds ONLY while the card that explains it is on screen. It used to hold
  # unconditionally, and that was a trap with no keyboard exit: `overlay_box` bails below
  # a 34x8 card while `Layout.usable?` admits 40x8, so a band of short bodies is
  # live-but-unrenderable — the refusal was drawn on a branch that never ran, esc and
  # click-away both answered :stay, and the one line that DID draw advertised a dead key.
  # Only ^C/^D (quitting gori) or a resize got out. A refusal nobody can read is a lock,
  # not a guard: where the editor cannot show the line, esc saves and the degraded line
  # says how many lines that drops, so the save is still never silent.
  class DiscoverHeadersOverlay < Overlay
    include SavingEditorCard

    def initialize(headers : Array({String, String}))
      text = headers.map { |name, value| "#{name}: #{value}" }.join("\n")
      @editor = TextArea.new(text)
      @refused = nil.as(String?)
      # Did the LAST frame have room for the card? `handle_key` gets no `area`, so this is
      # the only channel by which the key path can know whether a refusal is readable.
      # Defaults true so the guard keeps its teeth before the first frame — the shell draws
      # before it reads a key, so production always answers from a real frame.
      @card_drawn = true
    end

    # Current headers parsed from the editor buffer.
    def headers : Array({String, String})
      Discover::Headers.parse_lines(@editor.text.split('\n'))
    end

    # The lines `parse_lines` will not turn into headers, in buffer order.
    def rejected_lines : Array(String)
      # NB: not `out` — that is a Crystal keyword and a bare `out` argument is parsed as
      # an out-parameter declaration, not as this local.
      rejected = [] of String
      Discover::Headers.parse_lines(@editor.text.split('\n'), rejected)
      rejected
    end

    # The refusal to render, or nil when every non-blank line is a usable header.
    # Recomputed on every commit attempt, so fixing the line clears it.
    def refusal : String?
      first = rejected_lines.first?
      return nil unless first
      name = first.partition(':')[0].strip
      name = first.strip if name.empty?
      name = "#{name[0, 39]}…" if name.size > 40
      "#{name.inspect} will not be sent — a header value may not contain CR or LF, " \
      "and a name must be an RFC 7230 token. Fix or delete the line."
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::DiscoverHeaders
    end

    def title : String
      "CUSTOM HEADERS"
    end

    def hint : String
      # Keys only. The two format rules this editor enforces are stated on the card's own
      # band, where the operator is already looking to type them — repeating them down here
      # was the same sentence in two places, which is how the two spellings drifted.
      "type headers · esc saves & closes"
    end

    def overlay_box(area : Rect) : Rect?
      area.card?(64, 16, 34, 8)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      @card_drawn = !box.nil? # what try_commit reads on the next key (see there)
      unless box
        render_degraded(screen, area) unless area.empty?
        return
      end
      # bg: Theme.bg (not the card default panel) so the embedded editor, which paints
      # on Theme.bg, doesn't two-tone against the card interior.
      Frame.card(screen, box, "CUSTOM HEADERS", bg: Theme.bg, border: Theme.border_focus)
      hintline = box.bottom - 2
      editor = editor_rect(box)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(editor.x, editor.y, "one header per line — e.g. Authorization: Bearer …", Theme.muted, Theme.bg, width: editor.w)
        screen.cursor(editor.x, editor.y)
      else
        @editor.render(screen, editor, cursor: true)
      end
      if refused = @refused
        screen.text(box.x + 2, hintline, refused, Theme.red, Theme.bg, width: box.w - 4)
      else
        # The two rules this editor enforces, which nothing else states. The `esc saves &
        # closes` tail came off — the shell draws `hint` in the status strip for the open
        # modal, so spelling the key here was the same advice twice.
        screen.text(box.x + 2, hintline, "one per line · Host/Connection ignored", Theme.muted, Theme.bg, width: box.w - 4)
      end
    end

    # The one line the card collapses to when there is no room for it. esc LEADS the
    # sentence on purpose: at 40 columns this clips, and the fact the operator needs is
    # which key gets them out. When lines will be dropped it says how many, so the save is
    # reported even here — a silent drop of an Authorization header is the failure this
    # whole overlay exists to prevent.
    private def render_degraded(screen : Screen, area : Rect) : Nil
      n = rejected_lines.size
      if n.zero?
        screen.text(area.x + 1, area.y, "headers editor needs a larger window · esc saves & closes", Theme.muted, Theme.bg)
      else
        plural = n == 1 ? "" : "s"
        screen.text(area.x + 1, area.y,
          "esc saves & closes · #{n} line#{plural} dropped · widen the window to fix",
          Theme.red, Theme.bg)
      end
    end
  end
end
