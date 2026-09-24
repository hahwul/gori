# Params (the per-endpoint parameter inventory, #1231) — verbs, reopens
# Gori::Verb::ExecContext (see verb/context.cr for the full facade and the class-reopening
# convention).
abstract class Gori::Verb::ExecContext
  abstract def params_move(delta : Int32) : Nil # move the parameter-row cursor
  abstract def params_run : Nil                 # (re-)scan the captured requests
  abstract def params_toggle_headers : Nil      # include / leave out the standard browser headers
  abstract def params_clear_target : Nil        # drop the Sitemap-node narrowing (every endpoint)
  abstract def params_open_flow : Nil           # open the row's newest flow in the History detail
  abstract def params_copy_names : Nil          # every visible name, one per line, to the clipboard
  abstract def params_export : Nil              # the visible names as a wordlist file
  # Mine the row's endpoint, the names seen on the host's OTHER endpoints seeded first.
  abstract def params_mine : Nil
  # The Sitemap's `p`: open Params narrowed to the cursor row (host or subtree).
  abstract def sitemap_params : Nil
  abstract def params_rows_shown? : Bool # a scan is on screen with a row under the cursor
  abstract def params_targeted? : Bool   # narrowed to a Sitemap node (the clear verb's gate)
end
