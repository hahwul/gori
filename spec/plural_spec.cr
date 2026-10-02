require "./spec_helper"

describe "Gori.plural" do
  it "adds the s for every count but one, whatever the integer width" do
    Gori.plural(1, "flow").should eq("1 flow")
    Gori.plural(0, "flow").should eq("0 flows")
    Gori.plural(2, "sub-tab").should eq("2 sub-tabs")
    Gori.plural(-1, "flow").should eq("-1 flows")
    Gori.plural(1_u64, "held message").should eq("1 held message")
    Gori.plural(3_i64, "URL").should eq("3 URLs")
  end
end
