require "../spec_helper"

private alias F = Gori::Fuzz

describe "Fuzz::Matcher#spec_error" do
  it "is nil for every valid spelling of a numeric and a status spec" do
    m = F::Matcher.new
    m.match_status = "200, 2xx, >=400, <500, 301-302, =404"
    m.filter_status = "5xx"
    m.match_size = ">100, 1-5, =7, <=9, 42"
    m.match_time = ">=5000"
    m.filter_grpc = "7, 1-16, >0"
    m.match_words = ""       # blank = unconstrained, not an error
    m.filter_lines = "  ,  " # only empty terms = unconstrained
    m.spec_error.should be_nil
  end

  it "names the first term that can never fire, and which dimension it is on" do
    m = F::Matcher.new
    m.match_size = "1500,1O00"
    m.spec_error.not_nil!.should contain("match size spec")
    m.spec_error.not_nil!.should contain("\"1O00\"")

    m = F::Matcher.new
    m.filter_status = "2OO"
    m.spec_error.not_nil!.should contain("filter status spec")
    m.spec_error.not_nil!.should contain("2xx") # the remedy names the class form

    m = F::Matcher.new
    m.match_time = ">= fast"
    m.spec_error.not_nil!.should contain("match time spec")

    m = F::Matcher.new
    m.match_status = ">=abc"
    m.spec_error.should_not be_nil
  end

  it "validates exactly what the compiled predicate would refuse to match" do
    F::Predicate.invalid_num_term("1O00").should eq("1O00")
    F::Predicate.invalid_num_term(">=x").should eq(">=x")
    F::Predicate.invalid_num_term("100-200,>5").should be_nil
    F::Predicate.invalid_status_term("2OO").should eq("2OO")
    F::Predicate.invalid_status_term("2xx,>=4xx,404,200-299").should be_nil
    F::Predicate.invalid_status_term("6xx").should eq("6xx") # no such class
  end
end
