require "../project_registry"

module Gori
  module Tui
    # The tags field shared by the picker's new-project form and the Project tab's Edit tags
    # prompt: committed tags drawn as `#tag` chips, a buffer being typed, and a row of the
    # host's existing tags suggested beneath it. Keys only — the caller owns the IME preedit and
    # the field focus, and stores the result through `ProjectRegistry` (whose `normalize_tags`
    # is the one rule a tag is checked against, here and on every other surface).
    class TagInput
      enum Outcome
        Handled   # the key edited the field
        Unhandled # not this field's key: the caller's (field navigation, esc)
        Submit    # ↵ with nothing left to commit: the caller saves
        Refused   # a tag `normalize_tags` refused; the reason is in `#refusal`
      end

      getter tags : Array(String)
      getter buffer = ""
      getter refusal : String? = nil
      @picked = 0

      # `known` is `ProjectRegistry.tag_counts` over the host: what to suggest, most-used first.
      def initialize(@tags : Array(String), @known : Array({String, Int32}))
      end

      # The tags still worth suggesting: none already on the field, and with a buffer, the ones
      # it is a prefix of before the ones that merely contain it.
      def suggestions : Array({String, Int32})
        taken = @tags.map(&.downcase).to_set
        open = @known.reject { |(t, _)| taken.includes?(t.downcase) }
        q = @buffer.strip.lchop('#').downcase
        return open if q.empty?
        prefixed, rest = open.partition { |(t, _)| t.downcase.starts_with?(q) }
        prefixed + rest.select { |(t, _)| t.downcase.includes?(q) }
      end

      def handle(ev : Termisu::Event::Key) : Outcome
        @refusal = nil
        key = ev.key
        sugg = suggestions
        @picked = @picked.clamp(0, {sugg.size - 1, 0}.max)
        if key.enter?
          @buffer.strip.empty? ? Outcome::Submit : commit(@buffer)
        elsif !sugg.empty? && (key.tab? || key.left? || key.right?)
          pick(key, sugg)
        else
          edit(ev)
        end
      end

      # tab takes the picked suggestion; ←/→ move the pick.
      private def pick(key : Termisu::Input::Key, sugg : Array({String, Int32})) : Outcome
        return commit(sugg[@picked][0]) if key.tab?
        @picked = (@picked + (key.left? ? -1 : 1)) % sugg.size
        Outcome::Handled
      end

      private def edit(ev : Termisu::Event::Key) : Outcome
        key = ev.key
        if key.backspace?
          if @buffer.empty?
            @tags.pop?
          else
            @buffer = @buffer[0, @buffer.size - 1]
          end
          @picked = 0
          Outcome::Handled
        elsif (c = ev.char || key.to_char) && !c.control? && !ev.ctrl? && !ev.alt?
          return commit(@buffer) if c == ','
          @buffer += c
          @picked = 0
          Outcome::Handled
        else
          Outcome::Unhandled
        end
      end

      # Every tag the field holds, a buffer not yet committed included — what a save stores, so
      # `↵` on another field does not drop the word still being typed. Raises like
      # `normalize_tags`.
      def final_tags : Array(String)
        ProjectRegistry.normalize_tags(@tags + [@buffer])
      end

      private def commit(raw : String) : Outcome
        @tags = ProjectRegistry.normalize_tags(@tags + [raw])
        @buffer = ""
        @picked = 0
        Outcome::Handled
      rescue ex : Gori::Error
        @refusal = ex.message
        Outcome::Refused
      end

      # The field row from `x`: the chips, then the buffer (a live caret only while `active`).
      def render_field(screen : Screen, x : Int32, y : Int32, width : Int32, fg : Color, bg : Color,
                       active : Bool, preedit : String) : Nil
        right = x + width
        px = x
        @tags.each do |t|
          chip = "##{t}"
          break if px + Screen.display_width(chip) >= right
          px = screen.text(px, y, chip, Theme.syn_header, bg) + 1
        end
        rest = {right - px, 1}.max
        if active
          screen.input_line(px, y, @buffer, @buffer.size, preedit, fg, bg, width: rest)
        else
          screen.text(px, y, @buffer, fg, bg, width: rest)
        end
      end

      # The suggestion row: `tag count` cells, the picked one on the selection band, and how
      # many more did not fit. Nothing when there is nothing to suggest.
      def render_suggestions(screen : Screen, x : Int32, y : Int32, width : Int32, bg : Color) : Nil
        sugg = suggestions
        return if sugg.empty?
        right = x + width
        px = x
        sugg.each_with_index do |(t, n), i|
          cell = "#{t} #{n}"
          more = "+#{sugg.size - i}"
          if px + Screen.display_width(cell) + (i < sugg.size - 1 ? Screen.display_width(more) + 3 : 0) > right
            screen.text(px, y, more, Theme.muted, bg) if px + Screen.display_width(more) <= right
            break
          end
          picked = i == @picked
          px = screen.text(px, y, cell, picked ? Theme.text_bright : Theme.muted, picked ? Theme.accent_bg : bg)
          px += 3
        end
      end
    end
  end
end
