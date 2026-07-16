require "./screen"
require "./theme"
require "./frame"
require "./chain_pane"
require "../decoder"

module Gori::Tui
  # The ^Y chain editor: a centered modal that edits a §…§ marker's Decoder chain AND
  # previews how the marker's value transforms through it (value → each step → output).
  # Replaces the old bottom CHAIN split — the inline chain is concealed now, so the
  # editing surface became a focused popup that can show the wire result before you send.
  # Stateless: the owning view holds the ChainPane (edit state) + the marker's value and
  # calls `render`; keys still flow through ChainPane via the controller.
  module ChainOverlay
    MAX_STEPS = 8
    HINT      = "↵ save · esc cancel · Tab completes"
    LABEL_W   = 7 # "value"/"chain" gutter

    # Draw the modal over `area`. `header` is the card title ("CHAIN · §N"), `value` the
    # marker's default payload, `pane` the live chain editor.
    def self.render(screen : Screen, area : Rect, header : String, value : String, pane : ChainPane) : Nil
      return if area.w < 24 || area.h < 8
      chain = pane.value.strip
      result = chain.empty? ? nil : Decoder.run(Decoder.shared_registry, value.to_slice, chain)
      nsteps = result ? result.steps.size : 0
      box = overlay_box(area, nsteps)
      return if box.nil?

      Frame.card(screen, box, header, bg: Theme.panel, border: Theme.border_focus)
      ix = box.x + 2
      vx = ix + LABEL_W
      vw = {box.right - 1 - vx, 1}.max
      y = box.y + 1

      screen.text(ix, y, "value", Theme.muted, Theme.panel)
      screen.text(vx, y, oneline(value, vw), Theme.text, Theme.panel, width: vw)
      y += 1

      screen.text(ix, y, "chain", Theme.marker_accent, Theme.panel)
      field = Rect.new(vx, y, vw, 1)
      pane.render_input(screen, field, focused: true)
      y += 1

      Frame.tee_divider(screen, box, y, bg: Theme.panel)
      y += 1
      screen.text(ix, y, "PREVIEW", Theme.accent, Theme.panel, Attribute::Bold)
      y += 1

      hint_y = box.bottom - 2
      render_preview(screen, ix, vx, y, hint_y, box.right - 1, value, result)
      screen.text(ix, hint_y, HINT, Theme.muted, Theme.panel, width: {box.right - 1 - ix, 1}.max)

      # Dropdown LAST so an open completion list overlays the preview cleanly.
      pane.render_dropdown(screen, field, box)
    end

    # Content rows: value + chain, the divider, the PREVIEW header, the preview body
    # (input + one row per step, capped), and the hint — plus the two border rows. Clamped
    # to the available height so a short window still opens (the preview just truncates).
    private def self.overlay_box(area : Rect, nsteps : Int32) : Rect?
      preview_rows = 1 + (nsteps == 0 ? 1 : {nsteps, MAX_STEPS}.min)
      rows = 2 + 1 + 1 + preview_rows + 1
      w = {area.w - 4, 72}.min
      h = {rows + 2, area.h - 2}.min
      return nil if w < 28 || h < 9
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # Draw the transform: an `in` row (the value), then one row per chain step with its
    # output — green while the pipeline is live, red at the first failed/unknown step and
    # dim for steps skipped after it. Stops at `y_end` (exclusive) so it never hits the hint.
    private def self.render_preview(screen : Screen, ix : Int32, vx : Int32, y : Int32, y_end : Int32,
                                    right : Int32, value : String, result : Decoder::ChainResult?) : Nil
      vw = {right - vx, 1}.max
      return if y >= y_end
      screen.text(ix, y, "in", Theme.muted, Theme.panel)
      screen.text(vx, y, oneline(value, vw), Theme.text, Theme.panel, width: vw)
      y += 1

      if result.nil?
        screen.text(ix, y, "(no chain — value is sent unchanged)", Theme.muted, Theme.panel, width: {right - ix, 1}.max) if y < y_end
        return
      end

      nx = ix + 2 # step number gutter
      lx = nx + 3 # converter name
      name_w = 15
      ox = lx + name_w + 1 # step output
      ow = {right - ox, 1}.max
      result.steps.each_with_index do |step, i|
        break if y >= y_end
        num_col, out_col, text = step_row(step)
        screen.text(nx, y, "#{i + 1}", Theme.muted, Theme.panel)
        screen.text(lx, y, oneline(step.name, name_w), num_col, Theme.panel, width: name_w)
        screen.text(ox, y, oneline(text, ow), out_col, Theme.panel, width: ow)
        y += 1
      end
    end

    # {name colour, output colour, output text} for one step's row.
    private def self.step_row(step : Decoder::StepResult) : {Color, Color, String}
      case step.state
      when .ok?
        bytes = step.output
        shown = bytes ? Decoder.display(bytes)[0] : ""
        {Theme.text, Theme.green, shown}
      when .skipped?
        {Theme.muted, Theme.muted, "(skipped)"}
      else # failed / unknown
        {Theme.red, Theme.red, step.error || "error"}
      end
    end

    # Collapse whitespace to single spaces (multi-line values/outputs render on one row)
    # and let screen.text ellipsize to width — keeps the preview to exactly one line/row.
    private def self.oneline(s : String, _w : Int32) : String
      s.gsub(/[\r\n\t]+/, " ")
    end
  end
end
