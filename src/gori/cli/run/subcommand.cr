module Gori
  module CLI
    module Run
      # Declares a `cmd_*` entry point as one `gori run` subcommand:
      #
      #     @[Subcommand("history", "ls", help: [
      #       {"history (ls)", "List / QL-query captured flows"},
      #       {"history clear", "Delete ALL captured flows in the project (needs --yes)"},
      #     ])]
      #     private def self.cmd_history(args : Array(String)) : Nil
      #
      # `Run` harvests every annotated method in its `macro finished` block (the "Subcommand
      # registry" section of cli/run.cr) into the name → handler dispatch and the `gori run
      # -h` table, so a subcommand is declared exactly once, next to its body, and adding one
      # touches only its own `run/*.cr` file.
      #
      # Positional arguments: the subcommand name, then any aliases (`"sequence", "seq"`).
      # `help:` is the list of `{name column, description}` rows the subcommand contributes
      # to `gori run -h`, in the order they should print — a subcommand with verbs lists
      # each verb worth a line of its own. The handler receives argv AFTER the subcommand
      # token.
      annotation Subcommand
      end
    end
  end
end
