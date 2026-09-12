require "./src/gori/tui/color"
require "./src/gori/tui/attribute"
require "./src/gori/tui/ansi"
cases = [
  "\e[31m\e[38:2::300:0:0mx",
  "\e[31m\e[58:2::1:2:3mx",
  "\e[31m\e[:5mx",
  "\e[1;31m\e[38;5;abcmx",
  "\e[1;31m\e[38:2:1:2:3:4:5mx",
  "\e[31m\e[38:2::1:2mx",
  "\e[1m\e[38:5:196;31mx",
  "\e[38:5:196;;1mx",
  "\e[31m\e[4:3;mx",
  "\e[31m\e[1;;38:5:21mx",
]
cases.each do |c|
  s = Gori::Tui::Ansi.parse(c)
  puts "#{c.inspect} => fg=#{s[0].fg.inspect} bg=#{s[0].bg.inspect} attr=#{s[0].attr}"
end
