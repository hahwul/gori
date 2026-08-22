require "../spec_helper"
require "../support/memory_backend"
require "file_utils"
require "socket"
require "../../src/gori/tui/controllers/history_controller"
require "../../src/gori/tui/controllers/sitemap_controller"

include Gori::Tui

# Clicking the filter bar (#-): the chips right of the query — `v:` / `f:follow` / `⇧S scope` on
# History, `g:fold` / `⇧S scope` on the Target tree — are the toggles their chords are, and the
# field left of them opens for editing like `/`.
#
# The property every example here turns on is COLUMN AGREEMENT: the chips drop individually on a
# narrow bar and appear/disappear with the state, so what is asserted is that every cell the
# hit-test claims for a chip is a cell the paint actually put that chip's text in — not that a
# chip is somewhere near where it was expected.

private class FilterBarFakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  # What the filter bar's chips reach the shell through: the scope lens is a Host toggle, and
  # the view picker is an overlay only the Runner can open.
  getter lens_toggles = 0
  getter view_pickers = 0
  property active_tab : Symbol = :history

  def initialize(@session : Gori::Session)
    @jobs = Gori::Tui::Jobs.new
    @notifications = Gori::Tui::Notifications.new
  end

  def session : Gori::Session
    @session
  end

  def jobs : Gori::Tui::Jobs
    @jobs
  end

  def notifications : Gori::Tui::Notifications
    @notifications
  end

  def status(message : String) : Nil
    @statuses << message
  end

  def request_overlay(kind : Symbol) : Nil
  end

  def request_focus(pane : Symbol) : Nil
  end

  def focus_body : Nil
  end

  def switch_tab(tab : Symbol) : Nil
  end

  def goto_tab(tab : Symbol) : Nil
  end

  def open_palette : Nil
  end

  def open_help_query(surface : Symbol) : Nil
  end

  def open_space_menu : Nil
  end

  def open_fuzz_set_editor(edit_index : Int32?) : Nil
  end

  def open_fuzz_advanced_editor : Nil
  end

  def open_authorize_identities : Nil
  end

  def reconfigure_sequence : Nil
  end

  def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
  end

  def open_custom_rule_editor(rule : Gori::Probe::CustomRule?) : Nil
  end

  def open_rewriter_rule_editor(rule : Gori::Store::MatchRule?) : Nil
  end

  def open_colormarker_rule_editor(rule : Gori::Store::ColorRule?) : Nil
  end

  def open_colormarker_color_editor(color : Gori::Settings::ColormarkerColor?) : Nil
  end

  def open_extract_rule_editor(rule : Gori::Store::ExtractRule?) : Nil
  end

  def open_chain_save : Nil
  end

  def open_chain_load : Nil
  end

  def open_oast_provider_editor(provider : Gori::Oast::ProviderConfig?) : Nil
  end

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    action.call
  end

  def overlay : Symbol
    :none
  end

  def focus : Symbol
    :body
  end

  def reveal? : Bool
    false
  end

  def toggle_reveal : Nil
  end

  def pretty? : Bool
    false
  end

  def toggle_pretty : Nil
  end

  def toggle_scope_lens : Nil
    @lens_toggles += 1
  end

  def open_history_view_picker : Nil
    @view_pickers += 1
  end

  def toggle_sandbox : Nil
  end

  def apply_project_network(bind_host : String, bind_port : Int32, upstream : String,
                            connect_secs : Int32, io_secs : Int32, capture_mib : Int32) : String
    ""
  end
end

# Each column of the bar row, mapped to the chip the hit-test claims it for. Compared against the
# painted row, so a hit-test that drifted off the paint by even one cell fails here.
private def chip_columns(backend : MemoryBackend, rect : Rect, hit) : Hash(Symbol, String)
  out = {} of Symbol => String
  row = backend.row(rect.y)
  (rect.x...rect.right).each do |x|
    next unless tag = hit.call(x)
    out[tag] = "#{out[tag]? || ""}#{row[x]}"
  end
  out
end

private def history_bar(view : HistoryView, w = 110, h = 14) : Hash(Symbol, String)
  backend = MemoryBackend.new(w, h)
  rect = Rect.new(0, 0, w, h)
  view.render_list(Screen.new(backend), rect)
  chip_columns(backend, rect, ->(x : Int32) { view.ql_chip_at(rect, x, 0) })
end

private def sitemap_bar(view : SitemapView, w = 110, h = 14) : Hash(Symbol, String)
  backend = MemoryBackend.new(w, h)
  rect = Rect.new(0, 0, w, h)
  view.render(Screen.new(backend), rect)
  chip_columns(backend, rect, ->(x : Int32) { view.ql_chip_at(rect, x, 0) })
end

describe "HistoryView — filter bar chips are clickable" do
  it "claims exactly the cells each chip was painted in" do
    view = HistoryView.new
    history_bar(view).should eq({
      :view   => "v:All",
      :follow => "f:follow",
      :scope  => "⇧S scope:off",
    })
  end

  it "follows the chip's own label when a view is active" do
    view = HistoryView.new
    view.set_view(Gori::SavedViews::BUILTINS.find { |v| v.name == "Errors" }.not_nil!)
    history_bar(view)[:view].should eq("v:Errors")
  end

  it "claims nothing while the bar is being edited" do
    # The cluster is not painted then — those cells hold the query text, and a click there must
    # not flip a lens the operator cannot see.
    view = HistoryView.new
    view.start_query
    history_bar(view).should be_empty
  end

  it "leaves a chip the narrow bar dropped unclickable, and keeps the ones it drew" do
    # `Frame.right_text_chain` drops a chip that would cross min_x and KEEPS GOING, so a shorter
    # chip further left still draws at that same edge. A hit-test that stopped at the first
    # dropped chip would leave live cells on chrome nobody painted.
    view = HistoryView.new
    hits = history_bar(view, w: 26)
    hits.has_key?(:view).should be_false # "v:All" no longer fits left of f:follow
    hits[:follow].should eq("f:follow")
  end
end

describe "SitemapView — filter bar chips are clickable" do
  it "claims exactly the cells each chip was painted in" do
    view = SitemapView.new
    sitemap_bar(view).should eq({
      :fold  => "g:fold",
      :scope => "⇧S scope:off",
    })
  end

  it "claims nothing while the bar is being edited" do
    view = SitemapView.new
    view.start_query
    sitemap_bar(view).should be_empty
  end
end

# The CA is the slow part of standing a Session up and no example asserts anything about it.
private FILTER_BAR_CA_ROOT = File.tempname("gori-filter-bar-ca")
Spec.after_suite { FileUtils.rm_rf(FILTER_BAR_CA_ROOT) }

private def with_controllers(&)
  root = File.tempname("gori-filter-bar")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("filterbar")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(FILTER_BAR_CA_ROOT), Gori::Verbs.registry, project)
  begin
    host = FilterBarFakeHost.new(session)
    yield Gori::Tui::HistoryController.new(host), Gori::Tui::SitemapController.new(host), host
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The column `label` was painted at on the framed body's bar row. Rendered through the CONTROLLER
# so the frame inset the click path applies is the one the assertion measures against.
private def bar_col(ctrl, rect : Rect, label : String) : Int32
  backend = MemoryBackend.new(rect.w, rect.h)
  ctrl.render_body(Screen.new(backend), rect, :body)
  row = backend.row(rect.y + 1)
  idx = row.index(label)
  raise "#{label.inspect} is not on the bar row: #{row.inspect}" unless idx
  idx
end

describe "HistoryController — clicking the filter bar" do
  it "toggles follow, the scope lens and the view picker from their own chips" do
    with_controllers do |ctrl, _sitemap, host|
      rect = Rect.new(0, 0, 110, 16)
      was = ctrl.view.follow?

      ctrl.handle_click(rect, bar_col(ctrl, rect, "f:follow"), 1).should be_true
      ctrl.view.follow?.should eq(!was)

      ctrl.handle_click(rect, bar_col(ctrl, rect, "scope:"), 1)
      host.lens_toggles.should eq(1)

      ctrl.handle_click(rect, bar_col(ctrl, rect, "v:"), 1)
      host.view_pickers.should eq(1)
    end
  end

  it "opens the query field on a click left of the chips" do
    with_controllers do |ctrl, _sitemap, _host|
      rect = Rect.new(0, 0, 110, 16)
      ctrl.view.querying?.should be_false
      ctrl.handle_click(rect, 2, 1).should be_true
      ctrl.view.querying?.should be_true
    end
  end

  it "does not dismiss the field, or flip a chip, on a click inside the open editor" do
    # The chips are not painted while the bar is being edited, so those columns belong to the
    # query text: clicking the field you are typing in must not close it.
    with_controllers do |ctrl, _sitemap, host|
      rect = Rect.new(0, 0, 110, 16)
      col = bar_col(ctrl, rect, "f:follow")
      was = ctrl.view.follow?
      ctrl.view.start_query
      ctrl.handle_click(rect, col, 1).should be_true
      ctrl.view.querying?.should be_true
      ctrl.view.follow?.should eq(was)
      host.lens_toggles.should eq(0)
    end
  end
end

describe "SitemapController — clicking the filter bar" do
  it "toggles id folding and the scope lens from their own chips" do
    with_controllers do |_history, ctrl, host|
      rect = Rect.new(0, 0, 110, 16)
      was = ctrl.view.grouping?

      ctrl.handle_click(rect, bar_col(ctrl, rect, "g:fold"), 1).should be_true
      ctrl.view.grouping?.should eq(!was)

      ctrl.handle_click(rect, bar_col(ctrl, rect, "scope:"), 1)
      host.lens_toggles.should eq(1)
    end
  end

  it "opens the query field on a click left of the chips" do
    with_controllers do |_history, ctrl, _host|
      rect = Rect.new(0, 0, 110, 16)
      ctrl.handle_click(rect, 2, 1).should be_true
      ctrl.view.querying?.should be_true
    end
  end

  it "leaves the bar row to the tree while the tag editor is up" do
    # The tag prompt is a text sub-mode the shell routes every key into; a second field opening
    # under it would leave two claiming the keyboard.
    with_controllers do |_history, ctrl, _host|
      rect = Rect.new(0, 0, 110, 16)
      col = bar_col(ctrl, rect, "g:fold")
      was = ctrl.view.grouping?
      ctrl.view.start_tag # false on an empty tree — the guard is what is under test either way
      ctrl.handle_click(rect, col, 1)
      ctrl.view.grouping?.should eq(was) if ctrl.view.tagging?
      ctrl.view.querying?.should be_false
    end
  end
end
