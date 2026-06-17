module Gori::Tui
  # Monochrome palette in the spirit of Grok Build: near-black canvas, white/grey
  # text, a white highlight for selection/focus, hairline dividers, minimal
  # chrome. Only HTTP status keeps functional colour (green/amber/red).
  module Theme
    BG            = Color.from_hex("#0a0a0b") # near-black canvas
    PANEL         = Color.from_hex("#141417") # top bar / status / overlays (lifted)
    BORDER        = Color.from_hex("#2a2a30") # hairline dividers
    ACCENT        = Color.from_hex("#fafafa") # the white highlight (Grok signature)
    ACCENT_BG     = Color.from_hex("#26262c") # selection band (focused pane)
    SELECTION_DIM = Color.from_hex("#19191c") # selection band (unfocused pane)
    TEXT          = Color.from_hex("#c8c8cc") # body text
    TEXT_BRIGHT   = Color.from_hex("#fafafa") # emphasis / active
    MUTED         = Color.from_hex("#6e6e76") # secondary
    GREEN         = Color.from_hex("#52c77a") # 2xx
    YELLOW        = Color.from_hex("#d6a13a") # 4xx
    RED           = Color.from_hex("#e5534b") # 5xx / error
    ORANGE        = Color.from_hex("#d9813f")

    def self.method_color(method : String) : Color
      case method.upcase
      when "GET", "HEAD"                    then GREEN
      when "POST", "PUT", "PATCH", "DELETE" then YELLOW
      else                                       MUTED
      end
    end

    def self.status_color(status : Int32?) : Color
      return MUTED if status.nil? || status == 0
      case status
      when 200..299 then GREEN
      when 300..399 then ACCENT
      when 400..499 then YELLOW
      else               RED
      end
    end
  end
end
