require "../../spec_helper"

describe "Runner diff project picker" do
  # ChoicePicker tries a row mnemonic before its vim nav, so a `j`/`k` row ate the scroll keys
  # once the registry reached that far down the list.
  it "hands out no j/k mnemonic" do
    Gori::Tui::Runner::DIFF_PICK_KEYS.should_not contain('j')
    Gori::Tui::Runner::DIFF_PICK_KEYS.should_not contain('k')
  end
end
