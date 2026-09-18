require "../spec_helper"

include Gori::Tui

# The publish gate for the operator's selection (#1091). `Runner#ui_state_identity` compares
# this on every 50 ms tick and only rewrites the `ui_state` row when it MOVED, so the value
# type's equality IS the feature: get it wrong and marking four rows in History publishes
# nothing at all, while every payload spec stays green.
describe Gori::Tui::SelectionIdent do
  it "is a value type — `record`, not a class" do
    # The load-bearing assertion in this file. As a class, `==` would be reference equality:
    # two identical idents would compare unequal and the row would be rewritten every tick,
    # or (with an `==` someone added later) the reverse. Neither shows up in a payload spec.
    {{ Gori::Tui::SelectionIdent < Struct }}.should be_true
    SelectionIdent.new.should eq(SelectionIdent.new)
  end

  it "compares field-wise, so any one field moving republishes" do
    base = SelectionIdent.new(marks: 2, cursor: 5, cursor_id: 41_i64, rows: 100,
      query: "status:500", view: "p_3", scoped: true, subtabs: 1)
    base.should eq(base.copy_with)
    base.should_not eq(base.copy_with(marks: 3))
    base.should_not eq(base.copy_with(cursor: 6))
    base.should_not eq(base.copy_with(cursor_id: 42_i64))
    base.should_not eq(base.copy_with(cursor_key: "/v1/users"))
    base.should_not eq(base.copy_with(rows: 99))
    base.should_not eq(base.copy_with(query: "status:501"))
    base.should_not eq(base.copy_with(view: "p_4"))
    base.should_not eq(base.copy_with(scoped: false))
    base.should_not eq(base.copy_with(subtabs: 2))
  end

  it "defaults to the all-zero value every non-participating tab answers with" do
    # Help, Settings, Decoder and the rest never override `list_selection_ident`, so the gate
    # has to behave for them exactly as it did before the field existed.
    d = SelectionIdent.new
    {d.marks, d.cursor, d.rows, d.subtabs}.should eq({0, 0, 0, 0})
    d.cursor_id.should eq(0_i64)
    d.cursor_key.should eq("")
    d.query.should eq("")
    d.view.should eq("")
    d.scoped.should be_false
  end
end
