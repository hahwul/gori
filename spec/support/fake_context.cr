require "../../src/gori"

# A RECORDING ExecContext for exercising registry/palette logic and the verb bodies
# themselves. Every command method (the Nil-returning "do something" half of the
# interface) appends a Call instead of doing work, so a spec can assert exactly which
# intent a verb dispatched — and in what order, which matters for the verbs that chain
# two calls (detail.repeater closes the detail BEFORE opening the Repeater). The query
# half (selected_flow_id, *_read_mode?, *_count …) stays settable state, since verbs
# read it through `available?` gates rather than driving it.
class FakeExecContext < Gori::Verb::ExecContext
  # One recorded dispatch: the ExecContext method plus its stringified arguments
  # (Symbol/Int32 both render usefully, and a String comparison keeps assertions terse).
  record Call, name : Symbol, args : Array(String)

  getter calls = [] of Call

  property selected : Int64? = nil
  property current_tab : Symbol = :history # settable so tab-gated verbs (Decoder, …) can be exercised

  # The recorded method names in dispatch order — the usual assertion target.
  def call_names : Array(Symbol)
    @calls.map(&.name)
  end

  # Arguments of the one recorded call named `name`, or nil when it never fired. RAISES
  # when the intent fired more than once: returning the first match would let a handler
  # that dispatched the same intent twice with different arguments (focus_pane(:menu)
  # then focus_pane(:subtabs)) hide behind the one the spec happened to expect.
  def args_for(name : Symbol) : Array(String)?
    found = @calls.select { |c| c.name == name }
    if found.size > 1
      raise "#{name} was dispatched #{found.size} times (#{found.map(&.args).inspect}); assert on #calls instead"
    end
    found.first?.try(&.args)
  end

  private def rec(name : Symbol) : Nil
    @calls << Call.new(name, [] of String)
  end

  private def rec(name : Symbol, *args) : Nil
    @calls << Call.new(name, args.map(&.to_s).to_a)
  end

  def open_help_query(surface : Symbol) : Nil
    rec(:open_help_query)
  end

  def selected_flow_id : Int64?
    @selected
  end

  # Multi-select marks (#442). `marks` is settable state (the query half); the effective
  # target set derives from it exactly as the Runner's does — marks if any, else the cursor
  # — so a spec can exercise the marks-vs-cursor rule without a live view. Defaults to
  # empty so every `available?` lambda is safe on a bare FakeExecContext
  # (spec/verbs/registry_sweep_spec.cr).
  property marks = [] of Int64

  def selected_flow_ids : Array(Int64)
    return marks unless marks.empty?
    [@selected].compact
  end

  def marked_flow_count : Int32
    marks.size
  end

  property repeater_tab_count : Int32 = 0

  def repeater_subtab_count : Int32
    @repeater_tab_count
  end

  property subtab_marks : Int32 = 0

  def subtab_marked_count : Int32
    @subtab_marks
  end

  property subtab_search_tab_count : Int32 = 0

  def subtab_search_count : Int32
    @subtab_search_tab_count
  end

  def repeater_toggle_http2 : Nil
    rec(:repeater_toggle_http2)
  end

  def fuzz_toggle_http2 : Nil
    rec(:fuzz_toggle_http2)
  end

  property repeater_read_mode : Bool = false # settable so grouped-menu specs can exercise the read-mode verbs

  def repeater_read_mode? : Bool
    @repeater_read_mode
  end

  property fuzzer_results_saveable : Bool = false

  def fuzzer_results_saveable? : Bool
    @fuzzer_results_saveable
  end

  # Settable so the read-mode-gated Fuzzer verbs can be exercised.
  property? fuzzer_read_mode : Bool = false

  def sequence_export(format : Symbol) : Nil
    rec(:sequence_export)
    @sequence_export_format = format
  end

  getter sequence_export_format : Symbol? = nil

  property? sequence_report_ready = false

  def sequence_report_ready? : Bool
    @sequence_report_ready
  end

  property? miner_has_issue = false

  def miner_finding_selected? : Bool
    @miner_has_issue
  end

  property? fuzzer_has_result = false

  def fuzzer_result_selected? : Bool
    @fuzzer_has_result
  end

  # Settable so the availability sweep can exercise the marked-only entries (sitemap.mark-clear
  # renders only while a mark is set), the way `current_tab` is settable for the tab gates.
  property sitemap_marked_count : Int32 = 0

  # Settable so the selection-gated "promote this callback to an Issue" verb can be exercised.
  property? oast_callback_selected : Bool = false

  # Settable so the listener-gated OAST insert verbs can be exercised.
  property? oast_payload_available : Bool = false

  property scope_has_rule : Bool = false

  def scope_rule_selected? : Bool
    @scope_has_rule
  end

  property probe_has_custom_rule : Bool = false

  def probe_custom_rule_selected? : Bool
    @probe_has_custom_rule
  end

  property hostov_has_entry : Bool = false

  def hostov_entry_selected? : Bool
    @hostov_has_entry
  end

  property env_has_var : Bool = false

  def env_var_selected? : Bool
    @env_has_var
  end

  property activity_has_row : Bool = false

  def activity_row_selected? : Bool
    @activity_has_row
  end

  # Issues multi-select, mirroring the History pair above: `issue_marks` is settable state
  # (the query half) and `selected_issue` the cursor row, with the effective target set
  # derived exactly as the Runner's is — marks if any, else the cursor. Both default to empty
  # so every `available?` lambda is safe on a bare FakeExecContext.
  property issue_marks = [] of Int64
  property selected_issue = nil.as(Int64?)

  def selected_issue_ids : Array(Int64)
    return issue_marks unless issue_marks.empty?
    [@selected_issue].compact
  end

  def selected_issue_id : Int64?
    @selected_issue
  end

  def marked_issue_count : Int32
    issue_marks.size
  end

  property intercept_selected : Int64? = nil # settable so the held-message-gated verbs can be exercised

  def selected_intercept_id : Int64?
    @intercept_selected
  end

  property marked_intercept : Int32 = 0 # settable so the mark-gated verbs can be exercised

  def marked_intercept_count : Int32
    @marked_intercept
  end

  def authorize_passive? : Bool
    false
  end

  def authorize_has_target? : Bool
    false
  end

  def authorize_running? : Bool
    false
  end

  # --- retest diff (two PROJECTS at endpoint scale) ---

  property diff_rows_shown : Bool = false

  def diff_rows_shown? : Bool
    @diff_rows_shown
  end

  property decoder_read_mode : Bool = false # settable so grouped-menu specs can exercise COMMON's Copy

  def decoder_read_mode? : Bool
    @decoder_read_mode
  end

  property jwt_read_mode : Bool = false # settable so grouped-menu specs can exercise COMMON's Copy

  def jwt_read_mode? : Bool
    @jwt_read_mode
  end

  property cookie_read_mode : Bool = false # settable so grouped-menu specs can exercise COMMON's Copy

  def cookie_read_mode? : Bool
    @cookie_read_mode
  end

  property rewriter_rule_selected : Bool = false # settable so the has-rule gate can be exercised
  property rewriter_rules_sub : Bool = true      # settable so the RULES-sub-tab gate can be exercised
  property rewriter_global_rule : Bool = false   # settable so the global-rule gate (toggle-default) can be exercised
  property rewriter_preview_out : Bool = false   # settable so the PREVIEW OUTPUT read-pane gate can be exercised
  property comparer_diff : Bool = false          # settable so the Comparer row-cursor gate can be exercised
  property intercept_preview : Bool = false      # settable so the Intercept preview read-pane gate can be exercised
  property miner_detail_read : Bool = false      # settable so the Miner FINDING read-pane gate can be exercised
  property sequencer_analysis : Bool = false     # settable so the Sequencer ANALYSIS read-pane gate can be exercised
  property probe_detail_read : Bool = false      # settable so the Probe AFFECTED-URLS read-pane gate can be exercised
  property oast_detail : Bool = false            # settable so the OAST callback-detail read-pane gate can be exercised

  def rewriter_rule_selected? : Bool
    @rewriter_rule_selected
  end

  def rewriter_rules_sub? : Bool
    @rewriter_rules_sub
  end

  # Defaults to "the list has focus" so every existing rule-verb expectation keeps its
  # meaning; a test that wants a preview pane focused sets it false.
  property rewriter_rule_list_focused = true

  def rewriter_rule_list_focused? : Bool
    @rewriter_rules_sub && @rewriter_rule_list_focused
  end

  def rewriter_preview_out? : Bool
    @rewriter_preview_out
  end

  # --- colormarker (History row-colour rules) ---
  property colormarker_rule_selected : Bool = false # settable so the has-rule gate can be exercised
  property colormarker_global_rule : Bool = false   # settable so the global-rule gate (toggle-default) can be exercised

  def colormarker_rule_selected? : Bool
    @colormarker_rule_selected
  end

  # Focus gate: settable so the focus-aware `on_rule`/`in_cm` predicates can be exercised. Both
  # default true so the existing policy-verb tests read as "policy pane focused".
  property colormarker_rule_list_focused : Bool = true
  property colormarker_colors_focused : Bool = false
  property colormarker_color_selected : Bool = false

  def colormarker_rule_list_focused? : Bool
    @colormarker_rule_list_focused
  end

  def colormarker_global_rule_selected? : Bool
    @colormarker_global_rule
  end

  def colormarker_colors_focused? : Bool
    @colormarker_colors_focused
  end

  def colormarker_color_selected? : Bool
    @colormarker_color_selected
  end

  def comparer_diff_shown? : Bool
    @comparer_diff
  end

  def intercept_preview_readable? : Bool
    @intercept_preview
  end

  # Copy's wider gate — settable independently so a spec can hold the held-bytes editor open
  # (preview NOT readable) and still assert `^Y` reaches Copy.
  property intercept_copyable : Bool = false

  def intercept_copyable? : Bool
    intercept_copyable
  end

  def oast_detail_readable? : Bool
    @oast_detail
  end

  def probe_detail_readable? : Bool
    @probe_detail_read
  end

  def sequencer_analysis_readable? : Bool
    @sequencer_analysis
  end

  def miner_detail_readable? : Bool
    @miner_detail_read
  end

  def rewriter_global_rule_selected? : Bool
    @rewriter_global_rule
  end

  # Settable; defaults ON — the Notes body opens in read mode.
  property? notes_read_mode : Bool = true

  # Settable so project.copy / project.select-line can be exercised.
  property? project_desc_read_mode : Bool = false

  property selection_active : Bool = false # settable so selection-gated verbs (send-to, clear-selection) can be exercised

  def read_selection_active? : Bool
    selection_active
  end

  # Settable so the INS half of the `*.copy` verbs' availability can be exercised: those verbs
  # are available in READ mode OR while an editor is focused, which is what gives `^Y` a copy
  # to reach when a bare `y` would be a literal character.
  property editor_focused : Bool = false

  def editor_focused? : Bool
    editor_focused
  end

  getter send_to_opened : Bool = false

  def send_to_open : Nil
    @send_to_opened = true
    rec(:send_to_open)
  end

  property detail_navigable : Bool = false # settable so grouped-menu specs can exercise detail.select-line

  def detail_navigable? : Bool
    @detail_navigable
  end

  def space_menu_title(verb_id : String) : String?
    nil
  end

  # Settable so the issue-notes read verbs can be exercised.
  property? issues_notes_read_mode : Bool = false

  # The four linkable-entity ids, settable so both sides of the link.* gates can be
  # exercised (a verb is offered only once the entity has a persisted row to point at).
  property link_flow : Int64? = nil
  property link_repeater : Int64? = nil
  property link_fuzz : Int64? = nil
  property link_miner : Int64? = nil

  def link_flow_id : Int64?
    @link_flow
  end

  def link_repeater_id : Int64?
    @link_repeater
  end

  def link_fuzz_id : Int64?
    @link_fuzz
  end

  def link_miner_id : Int64?
    @link_miner
  end

  # Every remaining intent, generated from the catalogue itself. `ExecContext` declares
  # 400-odd abstract methods (verb/context.cr and verb/context/*.cr); all but a handful of
  # the Nil-returning ones are pure "record that this fired" here, so this block harvests
  # the catalogue once the whole program is parsed and emits a recorder for each one the
  # class does not define by hand above. Adding an intent to the catalogue therefore no
  # longer touches this file — only a recorder that must ALSO mutate state (a counter the
  # verb's `available?` gate reads) or a query with a settable default is written out.
  # Queries (Bool/Int/Array returns) are deliberately NOT generated: a missing one is a
  # compile error here, which is the right prompt to decide its default.
  macro finished
    {% for m in Gori::Verb::ExecContext.methods %}
      {% if m.abstract? && m.return_type && m.return_type.stringify == "Nil" && !@type.methods.any? { |d| d.name == m.name && d.args.size == m.args.size } %}
        def {{ m.name }}({{ m.args.map { |a| "#{a.name} : #{a.restriction}".id }.splat }}) : Nil
          rec({{ m.name.symbolize }}{% unless m.args.empty? %}, {{ m.args.map(&.name).splat }}{% end %})
        end
      {% end %}
    {% end %}
  end
end

# Fire one verb on a fresh recording context and return the intents it dispatched, IN
# ORDER — the shape every spec/verbs/*_spec.cr asserts on. Lives here rather than being
# re-declared per file so a change to it (say, also asserting arguments) is one edit.
def verb_intents(registry : Gori::Verb::Registry, id : String,
                 ctx = FakeExecContext.new) : Array(Symbol)
  registry[id].call(ctx)
  ctx.call_names
end
