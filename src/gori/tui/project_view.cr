require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "../project"
require "../store"

module Gori::Tui
  # The Project tab (new default home on entry after create/select). Shows static
  # project metadata (name, created, sizes, counts) + an editable DESCRIPTION
  # (multi-line, persisted in store settings like Notes). Editing is live when
  # the tab body has focus (cursor visible); Esc / ^P / ^C save + exit like NotesView.
  # Description can also be provided optionally when creating via the picker.
  class ProjectView
    DESC_KEY = "description"

    @project : Project?
    @flow_count : Int64
    @findings_count : Int32
    @db_size : Int64
    @total_captured : Int64
    @created : Time?
    @desc_area : TextArea
    @desc_dirty : Bool

    def initialize
      @project = nil
      @flow_count = 0
      @findings_count = 0
      @db_size = 0
      @total_captured = 0
      @created = nil
      @desc_area = TextArea.new
      @desc_dirty = false
    end


    # Snapshot stats from the live session (called on tab enter and initial run).
    # Re-loading is cheap and keeps numbers fresh when user switches away and back
    # after more capture.
    def reload(project : Project, store : Store) : Nil
      @project = project
      @flow_count = store.count
      @findings_count = store.count_findings
      @db_size = project.db_size
      @total_captured = store.total_size
      earliest = store.earliest_created_at
      @created = earliest ? Time.unix(earliest) : project.created

      @desc_area.set_text(store.setting(DESC_KEY) || "")
      @desc_dirty = false
    end

    # Persist description iff edited (called on tab exit paths, like NotesView).
    def save(store : Store) : Nil
      return unless @desc_dirty
      store.set_setting(DESC_KEY, @desc_area.text)
      @desc_dirty = false
    end

    # --- live description editing (delegated when Project tab body is focused) ---
    def insert(ch : Char) : Nil
      @desc_area.insert(ch)
      @desc_dirty = true
    end

    def newline : Nil
      @desc_area.insert_newline
      @desc_dirty = true
    end

    def backspace : Nil
      @desc_area.backspace
      @desc_dirty = true
    end

    def move(dr : Int32, dc : Int32) : Nil
      @desc_area.move(dr, dc)
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      screen.text(rect.x + 1, rect.y, "PROJECT", Theme::ACCENT, attr: Attribute::Bold)
      hint = "project overview"
      screen.text(rect.x + 9, rect.y, hint, Theme::MUTED)
      Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))

      p = @project
      return unless p

      y = rect.y + 2
      max_y = rect.bottom - 1
      return if y > max_y

      # Static metadata (always visible at top of the tab).
      lines = [
        {"Name", p.name},
        {"Created", format_time(@created)},
        {"DB Path", p.dir},
        {"DB Size (용량)", human_size(@db_size)},
        {"Flows", @flow_count.to_s},
        {"Captured", human_size(@total_captured)},
        {"Findings", @findings_count.to_s},
      ]

      lines.each do |(label, value)|
        break if y > max_y
        screen.text(rect.x + 2, y, label + ":", Theme::TEXT_BRIGHT)
        vx = rect.x + 2 + 18
        w = {rect.right - vx, 0}.max
        screen.text(vx, y, value, Theme::TEXT, width: w) if w > 0
        y += 1
      end

      # Editable DESCRIPTION section (takes remaining vertical space).
      # When the Project tab body is focused, the TextArea shows an active cursor
      # and accepts input (delegated from Runner#handle_project_key).
      y += 1
      return if y > max_y
      screen.text(rect.x + 2, y, "DESCRIPTION", Theme::ACCENT, attr: Attribute::Bold)
      edit_hint = focused ? "type to edit · esc tabs" : "↵/→ to edit"
      screen.text(rect.x + 14, y, edit_hint, Theme::MUTED)
      y += 1
      return if y > max_y
      Frame.inner_divider(screen, rect, y, border: Frame.pane_border(focused))
      y += 1
      return if y > max_y

      desc_h = {max_y - y, 1}.max
      desc_rect = Rect.new(rect.x + 2, y, {rect.w - 4, 0}.max, desc_h)
      @desc_area.render(screen, desc_rect, cursor: focused)
    end



    private def format_time(t : Time?) : String
      return "—" if t.nil?
      # Absolute local-ish time for creation date (no tz noise in TUI).
      t.to_s("%Y-%m-%d %H:%M")
    end

    private def human_size(bytes : Int64) : String
      return "0 B" if bytes <= 0
      units = ["B", "KB", "MB", "GB", "TB"]
      i = 0
      b = bytes.to_f64
      while b >= 1024.0 && i < units.size - 1
        b /= 1024.0
        i += 1
      end
      if i == 0
        "#{b.to_i64} #{units[i]}"
      else
        "%.1f #{units[i]}" % b
      end
    end
  end
end
