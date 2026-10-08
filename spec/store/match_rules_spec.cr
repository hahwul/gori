require "../spec_helper"

describe "Store global rule overrides" do
  # A torn row used to parse as "no overrides", so one toggle rewrote it as a one-entry map
  # and silently re-enabled every other global rule this project had switched off.
  it "refuses a toggle over an unparsable row and leaves the row alone" do
    with_store do |store|
      key = Gori::Store::REWRITER_OVERRIDES_KEY
      store.set_setting(key, %({"1":false,"2":fal))
      store.set_rewriter_override(3_i64, false).should be_false
      store.clear_rewriter_override(1_i64).should be_false
      store.setting(key).should eq(%({"1":false,"2":fal))
      store.rewriter_overrides.should be_empty # the read side stays tolerant
    end
  end

  it "still writes over an absent or well-formed row" do
    with_store do |store|
      store.set_rewriter_override(1_i64, false).should be_true
      store.set_rewriter_override(2_i64, false).should be_true
      store.rewriter_overrides.should eq({1_i64 => false, 2_i64 => false})
    end
  end
end
