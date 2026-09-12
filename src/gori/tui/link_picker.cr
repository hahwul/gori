require "./screen"
require "./theme"
require "./frame"
require "./picker_overlay"
require "../store"

module Gori::Tui
  # ONE picker for "attach this evidence somewhere": every issue and every note in the
  # project on a single filtered list, with `+ New issue…` / `+ New note…` pinned above
  # them.
  #
  # It replaces the IssuePicker/NotePicker pair, which split the same decision across two
  # verbs (`Space k` / `Space u`). That split made the operator commit to an OWNER KIND
  # before seeing what existed, and it buried create twice over: the create row only ever
  # appeared in the list you had already chosen, so "file the issue this session obviously
  # needs" meant guessing the right verb first. Kind is a column here, not a mode — the
  # filter matches the kind word too, so `note auth` narrows to notes and `issue xss` to
  # issues without leaving the card.
  #
  # The kind is `Store::LinkOwnerKind` itself, not a local mirror of it: this type's whole
  # job is to hand the Runner an owner to write an `entity_links` row against, and a second
  # two-member enum next to that one is a silent mis-attach waiting for the third member.
  #
  # A dumb form object on the Overlay seam like its predecessors: which ref gets attached,
  # and what the two create rows do, are both the injected `on_commit` (Runner#link_attach).
  class LinkPicker < FilterPickerOverlay
    # `label` is what the list draws (`#12 [high] SQLi`, `3:Auth notes`); `name` is the
    # owner's own title, for the messages the Runner writes — a toast must not echo `3:`,
    # which is a sub-tab position that changes when an earlier note closes.
    record Row,
      kind : Store::LinkOwnerKind,
      id : Int64,
      label : String,
      name : String,
      detail : String

    # The pinned action rows, in fixed order above the list. Pinned rather than filtered,
    # so create stays two keystrokes away under ANY query — including the query that
    # matches nothing, which is exactly when it is wanted.
    #
    # The labels are DERIVED from the kinds rather than kept in a second tuple beside them:
    # two positionally-correlated lists, one read by the draw and one by the action, drift
    # into a row that says "New issue" and creates a note.
    CREATE_KINDS = {Store::LinkOwnerKind::Issue, Store::LinkOwnerKind::Note}

    # Gutter for the kind badge, so labels line up down both kinds.
    BADGE_W = 6
    # Floor on the label column once a detail is drawn beside it (see draw_row).
    MIN_LABEL_W = 20

    @indexed : Array({Row, String})

    # Does at least one of the refs being attached HAVE an exchange to copy (#1038)? There is
    # no longer a freeze verb beside Link — ↵ freezes by default whenever there are bytes and
    # the destination can own them — so this card's only job here is to SAY so before ↵ is
    # pressed. A Bool, not the snapshots: the picker stays store-free and holds no evidence.
    getter? freezable : Bool

    # …and, when it is false, WHY — the refusal `Evidence.snapshot_for` already wrote ("repeater
    # #3 has never been sent"). Without it the ↵ token silently degraded from `link & freeze` to
    # `link`, the row landed LIVE, and nothing on the card or in the toast said a copy had not
    # been kept: an evidence gap the operator only finds later, in the issue.
    #
    # nil where there is nothing to explain — a note row, or a fuzz/miner ref that was never a
    # freeze candidate at all (`Evidence.freezable?`), which is why those carry no refusal.
    getter freeze_refusal : String?

    def initialize(@rows : Array(Row), *, @freezable : Bool = false, @freeze_refusal : String? = nil,
                   @linked : Bool = true)
      @indexed = @rows.map { |r| {r, haystack(r)} }
      @filtered = @rows
      # Prefer the first existing owner when there is one (create is always at the top), so a
      # reflexive ↵ links rather than opening a form — EXCEPT for a ref nobody has linked yet
      # (`linked: false`), where the common act is the first filing and the cursor opening two
      # rows below `+ New issue…` cost `↑ ↑` every time. A flag, not a store read: this card
      # holds no store.
      @selected = @rows.empty? || !@linked ? 0 : create_rows
    end

    # The pinned create rows. The labels are DERIVED from these rather than kept in a second
    # tuple beside them: two positionally-correlated lists, one read by the draw and one by
    # the action, drift into a row that says "New issue" and creates a note.
    def create_kinds : Tuple(Store::LinkOwnerKind, Store::LinkOwnerKind)
      CREATE_KINDS
    end

    def create_rows : Int32
      create_kinds.size
    end

    private def create_label(idx : Int32) : String
      "+ New #{create_kinds[idx].label}…"
    end

    # Total navigable rows: the create actions + the filtered owners.
    def entry_count : Int32
      create_rows + @filtered.size
    end

    # The create row under the cursor, or nil when the cursor is on an existing owner.
    def selected_create : Store::LinkOwnerKind?
      create_kinds[@selected]?
    end

    def selected_row : Row?
      i = @selected - create_rows
      # Guard the negative: Array#[]? counts backwards from the end, so a cursor parked on
      # a create row would otherwise resolve to the LAST owner and link to the wrong thing.
      return nil if i < 0
      @filtered[i]?
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::LinkPick
    end

    def title : String
      "LINK TO"
    end

    # What ↵ does to the HIGHLIGHTED row, said before it does it. It has to move with the
    # cursor, because the answer is per-row: an issue can own the frozen bytes and a note
    # cannot, and a create row makes the owner first. One hint for the card and for the
    # shell's bottom line — once it names the row under the cursor there is nothing left
    # for a separate "link / create" phrasing to add.
    def hint : String
      "type to filter · ↑/↓ select · ↵ #{enter_action} · esc cancel"
    end

    def enter_action : String
      if kind = selected_create
        freezes_into?(kind) ? "create & freeze" : "create#{freeze_gap(kind)}"
      elsif row = selected_row
        freezes_into?(row.kind) ? "link & freeze" : "link#{freeze_gap(row.kind)}"
      else
        "link"
      end
    end

    private def freezes_into?(kind : Store::LinkOwnerKind) : Bool
      @freezable && kind.issue?
    end

    # Why the row under the cursor is not offering a freeze, when there IS a reason to give.
    # Only on an issue row: a note cannot own frozen bytes at all, so its plain `link` is the
    # design rather than a degradation, and saying "nothing to freeze" there would report a
    # refusal that was never made.
    private def freeze_gap(kind : Store::LinkOwnerKind) : String
      return "" unless kind.issue?
      (why = @freeze_refusal) ? " — nothing to freeze: #{why}" : ""
    end

    protected def refilter : Nil
      terms = query.downcase.split
      @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay)| terms.all? { |t| hay.includes?(t) } }.map(&.first)
      # Keep the create rows at the top; land on the first match when any, else on
      # `+ New issue…` — a query with no hits is the create case.
      @selected = @filtered.empty? ? 0 : create_rows
      @scroll = 0
    end

    private def haystack(r : Row) : String
      "#{r.kind.label} #{r.label} #{r.detail}".downcase
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 80}.min
      h = area.h - 2
      return nil if w < 30 || h < 8
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      list_h = list_height(box)
      i = my - (box.y + LIST_OFFSET)
      return nil if i < 0 || i >= list_h
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < entry_count ? ri : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return render_too_small(screen, area, "the link picker needs a larger window") unless box
      Frame.card(screen, box, title, border: Theme.border_focus)
      list_top = render_filter(screen, box, hint)
      list_h = list_height(box)
      ensure_visible(list_h)
      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= entry_count
        if ri < create_rows
          draw_create(screen, box, list_top + i, ri, ri == @selected)
        else
          draw_row(screen, box, list_top + i, @filtered[ri - create_rows], ri == @selected)
        end
      end
    end

    private def draw_create(screen : Screen, box : Rect, ry : Int32, idx : Int32, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.accent
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      screen.text(box.x + 3, ry, create_label(idx), fg, bg, width: box.w - 5)
    end

    # badge │ label │ detail, in RESERVED columns like SubtabPicker — not label-then-
    # whatever-is-left. The detail carries the host and status the operator scans by, and
    # those are needed most on exactly the long titles that would eat the whole row.
    private def draw_row(screen : Screen, box : Rect, ry : Int32, row : Row, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)

      badge_x = box.x + 3
      label_x = badge_x + BADGE_W
      avail = {box.right - 1 - label_x, 1}.max

      screen.text(badge_x, ry, row.kind.label, Theme.muted, bg, width: BADGE_W)
      if row.detail.empty?
        screen.text(label_x, ry, row.label, fg, bg, width: avail)
        return
      end
      label_w = { {avail // 2, MIN_LABEL_W}.max, avail }.min
      detail_x = label_x + label_w + 1
      detail_w = {box.right - 1 - detail_x, 0}.max
      screen.text(label_x, ry, row.label, fg, bg, width: label_w)
      screen.text(detail_x, ry, row.detail, Theme.muted, bg, width: detail_w) if detail_w > 0
    end
  end
end
