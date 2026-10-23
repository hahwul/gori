# Project description pane — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # project: the description pane (READ mode on the DESCRIPTION card)
  abstract def project_desc_read_mode? : Bool
  # project: the registry's tags for this project (the Edit tags card)
  abstract def project_edit_tags : Nil
end
