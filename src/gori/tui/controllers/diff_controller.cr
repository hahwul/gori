require "../tab_controller"
require "../comparer_slot"
require "../diff_view"
require "../../diff"
require "../../paths"
require "../../project_registry"

module Gori::Tui
  # The Diff sub-tab (under Target): the retest report, two PROJECTS in the slots.
  #
  # Owns the read. Side B is the open project — its store is the session's and is never
  # closed here; side A is another project, opened READ-ONLY for the length of one
  # comparison and closed again, so the tab never holds a second project open while the
  # operator reads the result (P8).
  #
  # The comparison runs on demand (`r`, and on picking a side), never on the poll: it is a
  # second database open, and a report that silently re-ran under the cursor would move
  # rows out from under a click.
  class DiffController < TabController
    # Endpoint groups read per side. Deliberately below `Store::ENDPOINT_OBSERVATION_MAX`
    # (40k) and in line with the Sitemap tab's own `SITEMAP_MAX` (10k): this read runs
    # SYNCHRONOUSLY on the event loop — the two grouped queries, the union fold tree and the
    # issue walk all happen inside one keystroke — and the union tree is the quadratic-memory
    # shape `Sitemap.add` warns about. A cut is REPORTED (`Coverage#truncated`, plus a caveat
    # on the header), so a bounded read is honest where a frozen terminal is not.
    READ_MAX = 10_000

    def initialize(host : Host)
      super(host)
      @diff = DiffView.new
    end

    def view : DiffView
      @diff
    end

    def tab : Symbol
      :diff
    end

    def command_scope : Verb::Scope
      Verb::Scope::Diff
    end

    # Side B defaults to the project that is open — the common retest is "this engagement
    # against the last one", and making the operator pick the project they are already in
    # would be a step with one possible answer.
    def on_enter : Nil
      @diff.set_slot(:b, @host.session.project) unless @diff.slot(:b)
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      BodyChrome.framed(screen, rect, focus == :body) { |inner| render_content(screen, inner, focus) }
    end

    def render_content(screen : Screen, content : Rect, focus : Symbol) : Nil
      @diff.render(screen, content, focused: focus == :body)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      handle_click_content(BodyChrome.frame_inner(rect), mx, my)
    end

    def handle_click_content(content : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      if idx = @diff.row_at(content, mx, my)
        @diff.select_index(idx)
      end
      true
    end

    def body_scroll(delta : Int32) : Bool
      @diff.move(delta)
      true
    end

    def handle_wheel(step : Int32) : Bool
      @diff.move(step)
      true
    end

    def focus_first : Nil
      @diff.focus_first
    end

    def focus_last : Nil
      @diff.focus_last
    end

    def body_hint(focus : Symbol) : String
      return "" unless focus == :body
      return "a pick the baseline project" unless @diff.ready?
      base = "a/b pick · s swap · r run · v lens"
      # The three ROW verbs are gated on a row under the cursor (`diff_rows_shown?`), and a
      # lens can empty the list. Naming a key that would do nothing is the hint lying about
      # what the tab can do — which it already did for `↵` before these two joined it.
      @diff.selected_row ? "#{base} · ↵ Comparer · ⇧F issue · n note" : base
    end

    # --- verbs ---------------------------------------------------------------

    # Every project the registry knows, minus the one already in the OTHER slot: a
    # project does not differ from itself, and offering it would only produce a refusal.
    def pickable(for_slot : Symbol) : Array(Project)
      other = @diff.slot(for_slot == :a ? :b : :a)
      ProjectRegistry.new(Paths.projects_dir).list.reject { |p| other && p.db_path == other.db_path }
    end

    def set_slot(which : Symbol, project : Project) : Nil
      @diff.set_slot(which, project)
      run
    end

    def swap : Nil
      @diff.swap
      run
    end

    def cycle_lens(dir : Int32) : Nil
      lens = @diff.cycle_lens(dir)
      @host.status("diff lens: #{lens.try(&.label) || "findings (everything but unchanged)"}")
    end

    # Run the comparison. Both slots must be set; a store this tab opened is closed here.
    def run : Nil
      a = @diff.slot(:a)
      b = @diff.slot(:b)
      return @host.status("pick both sides first (a / b)") unless a && b
      if a.db_path == b.db_path
        @diff.error = "both slots name the same project — pick two different ones"
        return
      end
      # The read blocks the event loop for its duration, so say what is running BEFORE it
      # starts rather than only reporting the result once it is over.
      @host.status("diff: reading #{a.name} → #{b.name}…")
      # Either slot may name the OPEN project — B does by default, and `s` moves it to A —
      # and then its store is the session's. A second connection to the database this TUI is
      # capturing into buys nothing and would sit beside the writer's lock, so it is borrowed
      # rather than reopened (and never closed here).
      store_a, owned_a = side_store(a)
      return unless store_a
      store_b, owned_b = side_store(b)
      unless store_b
        store_a.close if owned_a
        return
      end
      begin
        @diff.report = Gori::Diff.run(store_a, store_b,
          label_a: a.name, label_b: b.name,
          path_a: a.db_path, path_b: b.db_path,
          limit: READ_MAX, raise_on_error: true)
        @host.status("diff: #{a.name} → #{b.name}")
      rescue ex
        @diff.error = "diff failed: #{ex.message}"
      ensure
        store_a.close if owned_a
        store_b.close if owned_b
      end
    end

    # {store, ours-to-close}. The session's own store for the open project; a fresh
    # read-only handle for anything else.
    private def side_store(p : Project) : {Store?, Bool}
      session = @host.session
      return {session.store, false} if p.db_path == session.project.db_path
      {open_side(p), true}
    end

    # The selected endpoint's capture from EACH side, as Comparer slots — the byte-level
    # answer to a row this tab can only summarize. nil on a side that never captured the
    # endpoint (an `added` row has no A, a `removed` row has no B), which the caller reports
    # rather than silently comparing one side against a blank.
    #
    # A slot holds BYTES, so nothing it hands back outlives the connection it was read from
    # — and a store this tab opened is closed again here (the session's is borrowed).
    def comparer_slots : {ComparerSlot?, ComparerSlot?}
      row = @diff.selected_row
      return {nil, nil} unless row
      {slot_for(@diff.slot(:a), row.a), slot_for(@diff.slot(:b), row.b)}
    end

    private def slot_for(project : Project?, facts : Gori::Diff::Facts?) : ComparerSlot?
      return nil unless project && facts
      store, owned = side_store(project)
      return nil unless store
      begin
        detail = store.get_flow(facts.sample_flow_id)
        detail ? ComparerSlot.from_flow(detail, source: project.name) : nil
      ensure
        store.close if owned
      end
    end

    # --- record: a row leaves the tab as an Issue or a Note --------------------

    # {the flow id a record from this row may link to, a builder for the record itself}.
    #
    # A record is written to the project that is OPEN — the only store this TUI holds a
    # writer on — and `entity_links.ref_id` is a bare rowid with no project column. So the
    # linkable side is whichever slot names the open project (B by default, A after `s`),
    # and the other side's capture is NAMED in the body rather than linked to a rowid that
    # means a different flow here. nil when there is no row under the cursor, or a slot is
    # empty (both of which the caller reports rather than filing an unanchored record).
    #
    # A BUILDER rather than a finished draft, because the body prints "linked to this
    # record" and that is an evidence claim: only the caller knows whether the link write
    # actually landed, and it cannot know until after it has run (a note has to exist before
    # anything can be linked to it). One nil check, one gate, and the text is built from what
    # happened rather than from what was intended.
    def selected_record : {Int64?, Proc(Bool, Gori::Diff::Record::Draft)}?
      row = @diff.selected_row || return nil
      a = @diff.slot(:a) || return nil
      b = @diff.slot(:b) || return nil
      home, flow_id = home_side(row, a, b)
      build = ->(linked : Bool) {
        Gori::Diff::Record.draft(row, Gori::Diff::Record::Context.new(a.name, b.name, home,
          linked: linked, a_path: a.db_path, b_path: b.db_path))
      }
      {flow_id, build}
    end

    # {the side that names the OPEN project, the flow id a record may link to}. The side is
    # reported even when the flow is not linkable, because "the capture was pruned" and "the
    # capture is in the other engagement's database" are two different things to tell the
    # reader of the record (see `Diff::Record::Context`).
    #
    # The flow is re-checked against the store rather than trusted: the report is a SNAPSHOT
    # taken at `r`, and a capture deleted since (a retention prune, a `history delete`, a
    # peer session) must not become a link row pointing at a rowid SQLite will later hand to
    # an unrelated flow. Same guard `create_issue_from_form` puts on its extra flow ids.
    private def home_side(row : Gori::Diff::Row, a : Project,
                          b : Project) : {Gori::Diff::Record::Side?, Int64?}
      session_path = @host.session.project.db_path
      # B first: it is the open project by default, and after `s` moves it to A the check
      # below catches that. Both slots naming it is impossible — `run` refuses that pair.
      if b.db_path == session_path
        return {Gori::Diff::Record::Side::B, linkable_flow(row.b)}
      elsif a.db_path == session_path
        return {Gori::Diff::Record::Side::A, linkable_flow(row.a)}
      end
      {nil, nil}
    end

    private def linkable_flow(facts : Gori::Diff::Facts?) : Int64?
      return nil unless facts
      id = facts.sample_flow_id
      @host.session.store.flow_row(id) ? id : nil
    end

    # A read-only, non-indexing open of a project this TUI is not capturing into. Retention
    # is unlimited because nothing here writes and a prune is the last thing reading another
    # engagement's database should be able to do. nil (with the reason on the view) when the
    # database will not open.
    private def open_side(p : Project) : Store?
      Store.open(p.db_path, retention_flows: Store::RETENTION_UNLIMITED,
        read_only: true, background_index: false)
    rescue ex
      @diff.error = p.open_failure_reason(ex)
      nil
    end
  end
end
