require "./screen"
require "./geometry"
require "./theme"
require "./fmt"
require "./url"
require "./traffic_empty_state"
require "../authorize/engine"
require "../repeater/message_lines"
require "../store/models"

module Gori::Tui
  # The Authorize tab body. A LIST of captured requests, each replayed under the same set of
  # identities, plus — for the selected request — the per-identity result table and a preview
  # of one identity's response. Session-only (no project DB, see AuthorizeController).
  #
  # Two-level like Burp Autorize / Caido: the top pane is one row per REQUEST with an aggregate
  # verdict; the bottom pane drills into the selected request's identities. `Tab` moves the
  # identity sub-cursor so each identity's response can be read.
  #
  # MVP ships two built-in identities — the request as-captured (baseline) and an anonymous one
  # that strips Cookie/Authorization — which already answers "is this endpoint protected at
  # all?". Custom identities are a follow-up.
  class AuthorizeView
    # One request under test, plus its run outcome. A class (not a record): `target`/`state`
    # mutate in place as the background run completes.
    class Entry
      getter id : Int32
      getter detail : Store::FlowDetail
      property target : Authorize::Target?
      property state : Symbol # :pending | :running | :done | :error
      property error : String?
      # The identity revision `target` was produced under. A result from an older set is not
      # wrong — it is what those identities saw — but it no longer describes the current ones,
      # so it counts as pending again.
      property result_rev : Int32

      def initialize(@id : Int32, @detail : Store::FlowDetail)
        @target = nil
        @state = :pending
        @error = nil
        @result_rev = -1
      end

      # Does this entry hold a result for the identity set `rev` names?
      def current?(rev : Int32) : Bool
        !@target.nil? && @result_rev == rev
      end

      def method : String
        @detail.row.method
      end

      def host_path : String
        "#{@detail.row.host}#{Url.origin_path(@detail.row.target)}"
      end

      # The one-word verdict for the master row: the state while it is not done, else the
      # aggregate across non-baseline identities — :bypass if ANY matched the baseline (the
      # row worth a look), :enforced if every one clearly differed, :review otherwise.
      def verdict : Symbol
        return @state unless @state == :done
        t = @target
        return :error unless t
        non = t.trials.reject(&.baseline?)
        return :review if non.empty?
        return :bypass if non.any?(&.verdict.same?)
        return :enforced if non.all?(&.verdict.different?)
        :review
      end
    end

    def self.default_identities : Array(Authorize::Identity)
      [
        Authorize::Identity.as_captured("as-captured"),
        Authorize::Identity.new("anonymous", remove_headers: ["Cookie", "Authorization"]),
      ]
    end

    getter identities : Array(Authorize::Identity)
    getter entries : Array(Entry)
    # Bumped whenever the identity set changes. An entry's result records the revision it was
    # produced under, so a result from an older set counts as PENDING again — see
    # `pending_entries`.
    getter identity_rev : Int32
    # Replaces the empty state's headline while passive replay is on. The status line that
    # announces the mode is transient and the operator is usually in a browser when it
    # matters, so the tab itself has to be able to answer "why is nothing happening".
    property passive_note : String?

    # Replace the identity set. Bumps `identity_rev`, which is what makes every result already
    # on screen count as pending again: those verdicts were produced under the OLD set, and
    # without this an operator who fixes a session cookie and presses ^R is told "every request
    # already has a result" and nothing goes out.
    def identities=(list : Array(Authorize::Identity)) : Nil
      return if list == @identities
      @identities = list
      @identity_rev += 1
    end

    def initialize
      @entries = [] of Entry
      @identities = AuthorizeView.default_identities
      @identity_rev = 0
      @passive_note = nil.as(String?)
      @next_id = 0
      @sel = 0  # master (request) cursor
      @tsel = 0 # identity sub-cursor within the selected request
      @detail_scroll = 0
      @stop_requested = false
    end

    def any_requests? : Bool
      !@entries.empty?
    end

    def size : Int32
      @entries.size
    end

    # Append a request to test. Returns its entry id. Selects it, so a fresh seed is what the
    # operator lands on.
    #
    # `@next_id` is MONOTONIC and is never reset — not by `clear`, not by `remove`. It is the
    # only thing keeping a late outcome from a still-draining batch off a freshly added entry:
    # outcomes carry an entry id, and a recycled id would let one land on somebody else's row.
    def add(detail : Store::FlowDetail) : Int32
      id = (@next_id += 1)
      @entries << Entry.new(id, detail)
      @sel = @entries.size - 1
      @tsel = 0
      @detail_scroll = 0
      id
    end

    def entry_by_id(id : Int32) : Entry?
      @entries.find { |e| e.id == id }
    end

    # The flow ids already queued — the dedup key for seeding. A flow id, not a URL: two
    # DIFFERENT captures of the same endpoint are different evidence (different params, body,
    # moment) and both belong in the queue; the same capture twice is a re-marking accident.
    def queued_flow_ids : Set(Int64)
      @entries.map(&.detail.row.id).to_set
    end

    # Every entry not currently mid-run — what "Run all" re-sends.
    def runnable : Array(Entry)
      @entries.reject { |e| e.state == :running }
    end

    # Entries with no CURRENT result — what "Run pending" sends. Three ways in: never run, a
    # previous send errored (no verdict either way), or the result predates the identity set
    # now configured.
    def pending_entries : Array(Entry)
      @entries.select { |e| pending?(e) }
    end

    def pending_count : Int32
      @entries.count { |e| pending?(e) }
    end

    private def pending?(e : Entry) : Bool
      e.state != :running && !e.current?(@identity_rev)
    end

    # What PASSIVE's unattended re-run may pick up: pending work that has not already blown up
    # under this identity set.
    #
    # The split matters because the two callers mean different things by "unfinished". A manual
    # ^R is the operator asking again, and a request that raised is exactly what they might
    # want retried. Passive asks on every drain tick with nobody watching, so an entry that
    # raises — a stored h2 pseudo-header head, say, which raises every time by construction —
    # would be re-dispatched forever, one fiber and one Jobs row per tick.
    def auto_pending_entries : Array(Entry)
      @entries.select { |e| pending?(e) && !errored_this_rev?(e) }
    end

    private def errored_this_rev?(e : Entry) : Bool
      !e.error.nil? && e.result_rev == @identity_rev
    end

    # Remove the cursor entry. Returns false (and changes nothing) while that row is mid-run —
    # its outcome is still coming. Clamps the cursor: the new selection has a different trial
    # count, so the sub-cursor and the detail scroll cannot carry over.
    def remove_selected : Bool
      e = selected_entry
      return false unless e
      return false if e.state == :running
      @entries.delete(e)
      @sel = @sel.clamp(0, {@entries.size - 1, 0}.max)
      @tsel = 0
      @detail_scroll = 0
      true
    end

    # --- stop flag (read cross-fiber by the run loop, written on the main fiber) ------------
    # Safe without a lock on the single-threaded scheduler (no -Dpreview_mt): the write is
    # visible to the run fiber at its next scheduling point. It would need an Atomic under MT.

    def stop_requested? : Bool
      @stop_requested
    end

    def request_stop : Nil
      @stop_requested = true
    end

    # Cleared at the START of a run, on the main fiber — never in the run fiber's teardown,
    # where a stop issued while it was winding down would be swallowed and the NEXT run would
    # inherit a `true` flag and refuse to send anything.
    def reset_stop : Nil
      @stop_requested = false
    end

    # Settle every entry a stopped batch left marked `:running`. TARGET-AWARE on purpose: "Run
    # all" re-runs entries that already hold a result, and `mark_running` leaves that result in
    # place — so reverting them all to `:pending` would print "pending" on the master row while
    # the detail pane still rendered the previous trials table.
    def settle_running(ids : Set(Int32)) : Nil
      @entries.each do |e|
        next unless e.state == :running && ids.includes?(e.id)
        e.state = e.target ? :done : (e.error ? :error : :pending)
      end
    end

    # How many entries hold a result — the honest denominator for a run summary. After a stop,
    # "no identity matched across N requests" would be a claim about requests that never ran.
    def completed_count : Int32
      @entries.count { |e| !e.target.nil? }
    end

    # The same two counts restricted to ONE batch. A run summary says what THIS run did, so it
    # cannot use the queue-wide totals: after a partial run, "ran 6" over a queue of six when
    # the batch was three describes work done by earlier runs.
    def completed_in(ids : Set(Int32)) : Int32
      @entries.count { |e| ids.includes?(e.id) && !e.target.nil? }
    end

    def bypasses_in(ids : Set(Int32)) : Int32
      @entries.sum { |e| ids.includes?(e.id) ? ((t = e.target) ? t.same_count : 0) : 0 }
    end

    def mark_running(ids : Set(Int32)) : Nil
      @entries.each { |e| e.state = :running if ids.includes?(e.id) }
    end

    def apply_result(id : Int32, target : Authorize::Target) : Nil
      return unless e = entry_by_id(id)
      e.target = target
      e.state = :done
      e.error = nil
      e.result_rev = @identity_rev
    end

    # A run that RAISED for this entry (as opposed to a send that failed and produced error
    # trials). `result_rev` is stamped so `pending?` counts it as answered under the current
    # identity set: without it a raising entry stayed pending forever, and passive's autorun
    # re-dispatched it — a fresh fiber and a fresh Jobs row — on every drain tick.
    #
    # Re-running it is still one keystroke: ⇧R takes every row, and changing the identity set
    # bumps the revision, which is when a retry could plausibly go differently.
    def apply_error(id : Int32, message : String) : Nil
      return unless e = entry_by_id(id)
      e.state = :error
      e.error = message
      e.result_rev = @identity_rev
    end

    # Total non-baseline identities that matched their baseline across every request — the
    # headline count the run summary states.
    # Requests in `ids` whose every send the outbound gate refused. A run made entirely of
    # these has to say so — silence there reads as "tested, nothing found".
    def blocked_in(ids : Set(Int32)) : Int32
      @entries.count { |e| ids.includes?(e.id) && (t = e.target) && t.fully_blocked? }
    end

    # The first refusal any batch entry recorded, for the summary line.
    def blocked_reason_in(ids : Set(Int32)) : String?
      @entries.each do |e|
        next unless ids.includes?(e.id)
        t = e.target
        next unless t && t.fully_blocked?
        if r = t.blocked_reason
          return r
        end
      end
      nil
    end

    def bypass_total : Int32
      @entries.sum { |e| (t = e.target) ? t.same_count : 0 }
    end

    # Empty the queue. Deliberately does NOT reset `@next_id` — see `add`.
    def clear : Nil
      @entries.clear
      @sel = 0
      @tsel = 0
      @detail_scroll = 0
    end

    def move_row(delta : Int32) : Nil
      return if @entries.empty?
      @sel = (@sel + delta).clamp(0, @entries.size - 1)
      @tsel = 0
      @detail_scroll = 0
    end

    # Move the identity sub-cursor within the selected request (Tab). Wraps.
    def move_trial(delta : Int32) : Nil
      trials = selected_entry.try(&.target).try(&.trials)
      return unless trials && !trials.empty?
      @tsel = (@tsel + delta) % trials.size
      @detail_scroll = 0
    end

    def scroll_detail(delta : Int32) : Nil
      @detail_scroll = (@detail_scroll + delta).clamp(0, 100_000)
    end

    def selected_entry : Entry?
      @entries[@sel]?
    end

    def selected_trial : Authorize::Trial?
      selected_entry.try(&.target).try(&.trials[@tsel]?)
    end

    def label : String
      any_requests? ? "#{@entries.size} req · #{@identities.size} id" : "Authorize"
    end

    # ── render ────────────────────────────────────────────────────────────────

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return render_empty(screen, rect) if @entries.empty?
      y = render_header(screen, rect, rect.y)
      # Split: the request list up top (bounded to half the body), the selected request's
      # identities + response below.
      # Bounded by the ROWS THIS PANE HAS, not just by a share of them: the old floor of 3
      # applied at any height, so a 3-row body drew a request row (and its selection fill) at
      # `rect.bottom` — outside the framed body, over the hint line. `rect.bottom - y` is what
      # is actually left below the header.
      avail = {rect.bottom - y, 0}.max
      list_h = (@entries.size + 1).clamp(1, {rect.h // 2, 3}.max)
      list_h = {list_h, avail}.min
      list_bottom = y + list_h
      render_list(screen, rect, y, list_bottom, focused)
      divider_y = list_bottom
      render_divider(screen, rect, divider_y)
      render_detail(screen, rect.x, divider_y + 1, rect.right, rect.bottom, focused)
    end

    # The shared onboarding card (figure + card, degrading to lines on a short pane), the same
    # surface every other empty tab shows — rather than three hand-centred sentences, which is
    # what this drew before and what every other tab stopped drawing.
    private def render_empty(screen : Screen, rect : Rect) : Nil
      TrafficEmptyState.render(screen, rect, variant: :authorize, title: @passive_note)
    end

    # "5 requests (2 pending) · identities: as-captured, anonymous" — the pending count is what
    # tells an operator building the queue incrementally whether ^R has anything left to send.
    private def render_header(screen : Screen, rect : Rect, y : Int32) : Int32
      ids = @identities.map(&.name).join(", ")
      pending = pending_count
      count = "#{@entries.size} request#{@entries.size == 1 ? "" : "s"}"
      count += " (#{pending} pending)" if pending > 0
      screen.text(rect.x, y, "#{count} · identities: #{ids}", Theme.muted, Theme.bg, width: rect.w)
      y + 1
    end

    # One row per request: cursor · # · METHOD · host/path · aggregate verdict.
    private def render_list(screen : Screen, rect : Rect, y : Int32, bottom : Int32, focused : Bool) : Nil
      hdr = sprintf("  %-3s %-6s %-38s %s", "#", "METHOD", "HOST / PATH", "VERDICT")
      screen.text(rect.x, y, hdr, Theme.muted, Theme.bg, Attribute::Bold, width: rect.w)
      y += 1
      @entries.each_with_index do |e, i|
        break if y >= bottom
        selected = i == @sel
        bg = (selected && focused) ? Theme.accent_bg : Theme.bg
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg) if selected && focused
        screen.text(rect.x, y, selected ? "▎" : " ", Theme.focus_gold, bg)
        cols = sprintf(" %-3d %-6s %-38s ", i + 1, e.method, truncate(e.host_path, 38))
        screen.text(rect.x + 1, y, cols, Theme.text, bg)
        vx = rect.x + 1 + cols.size
        v = e.verdict
        screen.text(vx, y, master_verdict_label(e), master_verdict_color(v), bg,
          Attribute::Bold, width: rect.right - vx)
        y += 1
      end
    end

    private def render_divider(screen : Screen, rect : Rect, y : Int32) : Nil
      screen.hline(rect.x, y, rect.w, '┈', Theme.border, Theme.bg) if y < rect.bottom
    end

    # The selected request's per-identity table, then the sub-cursor identity's response.
    private def render_detail(screen : Screen, x : Int32, y : Int32, right : Int32, bottom : Int32, focused : Bool) : Nil
      return if y >= bottom
      e = selected_entry
      return unless e
      # Request line for the selected entry.
      screen.text(x, y, "#{e.method} #{e.detail.row.url}", Theme.text_bright, Theme.bg, Attribute::Bold, width: right - x)
      y += 1
      # Every row below re-checks: `bottom` is the pane's edge, and a short body can run out
      # between any two of these writes. Nothing downstream clips for us — `Screen` bounds-checks
      # against the TERMINAL, so an overrun lands on the hint line rather than being dropped.
      return if y >= bottom
      t = e.target
      unless t
        note = e.state == :running ? "running…" : (e.error || "not run yet — press r")
        screen.text(x, y, note, Theme.muted, Theme.bg)
        return
      end
      y = render_trials(screen, x, y, right, bottom, t, focused)
      return if y >= bottom
      render_response(screen, x, y, right, bottom)
    end

    private def render_trials(screen : Screen, x : Int32, y : Int32, right : Int32, bottom : Int32,
                              t : Authorize::Target, focused : Bool) : Int32
      return y if y >= bottom
      hdr = sprintf("  %-14s %-7s %-9s %-22s %s", "IDENTITY", "STATUS", "SIZE", "Δ VS BASELINE", "VERDICT")
      screen.text(x, y, hdr, Theme.muted, Theme.bg, Attribute::Bold, width: right - x)
      y += 1
      t.trials.each_with_index do |trial, i|
        break if y >= bottom
        sub = i == @tsel
        bg = (sub && focused) ? Theme.accent_bg : Theme.bg
        screen.fill(Rect.new(x, y, right - x, 1), bg) if sub && focused
        screen.text(x, y, sub ? "▎" : " ", Theme.focus_gold, bg)
        size = trial.meta.size.try { |s| Repeater::ExchangeMeta::Format.bytes(s) } || "—"
        cols = sprintf(" %-14s %-7s %-9s %-22s ",
          truncate(trial.identity, 14), trial.meta.status_text, size, truncate(trial.delta || "—", 22))
        screen.text(x + 1, y, cols, Theme.text, bg)
        vx = x + 1 + cols.size
        screen.text(vx, y, trial_verdict_label(trial.verdict), trial_verdict_color(trial.verdict), bg,
          Attribute::Bold, width: right - vx)
        y += 1
      end
      y
    end

    private def render_response(screen : Screen, x : Int32, y : Int32, right : Int32, bottom : Int32) : Nil
      trial = selected_trial
      return unless trial
      return if y >= bottom
      screen.hline(x, y, right - x, '┈', Theme.border, Theme.bg)
      y += 1
      return if y >= bottom
      summary = trial.summary
      head = "#{trial.identity} · #{trial.meta.line}"
      head += " · #{summary.error}" if summary.error
      screen.text(x, y, head, Theme.text_bright, Theme.bg, Attribute::Bold, width: right - x)
      y += 1
      lines = Repeater::MessageLines.of(trial.response_head, trial.response_body,
        decode: true, error: summary.error)
      shown = lines[@detail_scroll..]? || [] of String
      shown.each do |ln|
        break if y >= bottom
        screen.text(x, y, ln, Theme.text, Theme.bg, width: right - x)
        y += 1
      end
    end

    # ── labels / colours ────────────────────────────────────────────────────────

    private def master_verdict_label(e : Entry) : String
      case e.verdict
      when :bypass   then "⚠ #{same_count(e)} same"
      when :enforced then "enforced"
      when :review   then "review"
      when :running  then "running…"
      when :pending  then "pending"
      when :error    then "error"
      else                "—"
      end
    end

    private def same_count(e : Entry) : Int32
      (t = e.target) ? t.same_count : 0
    end

    private def master_verdict_color(v : Symbol) : Color
      case v
      when :bypass   then Theme.red
      when :enforced then Theme.green
      when :review   then Theme.yellow
      when :running  then Theme.yellow
      else                Theme.muted
      end
    end

    private def trial_verdict_label(v : Authorize::Verdict) : String
      case v
      in .same?      then "⚠ same"
      in .different? then "different"
      in .review?    then "review"
      in .error?     then "error"
      in .baseline?  then "baseline"
      end
    end

    private def trial_verdict_color(v : Authorize::Verdict) : Color
      case v
      in .same?      then Theme.red
      in .different? then Theme.green
      in .review?    then Theme.yellow
      in .error?     then Theme.muted
      in .baseline?  then Theme.focus_gold
      end
    end

    private def truncate(s : String, w : Int32) : String
      s.size <= w ? s : s[0, w - 1] + "…"
    end
  end
end
