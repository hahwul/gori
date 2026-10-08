require "../../spec_helper"

# Runner owns a live terminal and is not constructed by specs, so the wiring is pinned by source.
private def params_mine_source : String
  File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "tui", "runner", "params.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
    .split("def params_mine", 2)[1].split("\n  end", 2)[0]
end

describe "Runner#params_mine" do
  # The on-screen report holds only a narrowed target's subtree (and a prefix `/orders` also
  # matches `/orders-archive`), so seeding from it missed the origin's other endpoints. The seed
  # is the History mine's origin-wide read (`ParamInventory.seed_names`), off the UI loop.
  it "seeds through the origin-wide read History's mine uses, not the narrowed report" do
    body = params_mine_source
    body.should contain("seed_mine_names(open_mine_config(seed))")
  end
end
