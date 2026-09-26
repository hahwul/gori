# Differential timing analysis (#1246): send two request variants many times and decide which is
# consistently slower by response ORDER and quartiles, not eyeballed latency. The measurement layer
# on top of the #1236 synchronized-release race. See `timing/stats.cr` for the reasoning.
require "./timing/stats"
require "./timing/runner"
require "./timing/present"
