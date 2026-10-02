module Gori
  # `"1 flow"`, `"3 flows"`: a count and an English noun that takes a plain `s`.
  def self.plural(n : Int, word : String) : String
    "#{n} #{word}#{n == 1 ? "" : "s"}"
  end
end
