module Gori::Tui
  # READ = navigable (space cmds, select/copy); INS = literal text entry.
  enum InputMode
    Read
    Insert
  end
end
