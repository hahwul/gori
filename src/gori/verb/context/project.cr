# Project description pane — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # project: the description pane (READ mode on the DESCRIPTION card)
  abstract def project_desc_read_mode? : Bool
end
