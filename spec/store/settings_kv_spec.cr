require "../spec_helper"

describe "Store#setting_is?" do
  it "answers whether the key holds exactly the value, with nil meaning no row" do
    with_store do |store|
      store.setting_is?("k", nil).should be_true
      store.setting_is?("k", "").should be_false

      store.set_setting("k", "abc")
      store.setting_is?("k", "abc").should be_true
      store.setting_is?("k", nil).should be_false
      store.setting_is?("k", "abd").should be_false
      store.setting_is?("k", "abc ").should be_false
      store.setting_is?("k", "ABC").should be_false # byte equality, not a collation

      store.set_setting("k", "")
      store.setting_is?("k", "").should be_true
      store.setting_is?("k", nil).should be_false
    end
  end

  it "compares a large value byte for byte" do
    with_store do |store|
      big = "x" * 1_000_000 + "é\r\n"
      store.set_setting("big", big)
      store.setting_is?("big", big).should be_true
      store.setting_is?("big", big.rchop).should be_false
      store.setting_is?("big", "#{big[0, big.size - 1]}\r").should be_false
    end
  end
end
