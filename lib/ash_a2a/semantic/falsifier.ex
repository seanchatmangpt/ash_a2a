defmodule AshA2A.Semantic.Falsifier do
  @moduledoc """
  One RFC-SA2A-001 S61 falsifier definition.

  Fields:

    * `:id` -- stable atom identifier.
    * `:rfc` -- the RFC S61 subsection this falsifier discharges.
    * `:title` -- the RFC's own wording of the condition.
    * `:ask` -- the **normative** SPARQL 1.1 `ASK` text. Per RFC S18.2 a
      graph-global falsifier *is* an ASK query; this field is the
      specification, not a comment on it.
    * `:mandatory` -- whether a `true` result MUST block admission in a
      Strict deployment. All fourteen S61 falsifiers are mandatory.
    * `:evaluation` -- how this build actually evaluates the falsifier at
      runtime. `:structural` means a real Elixir structural check over the
      same graph, held to agreement with a real SPARQL engine's answer to
      `:ask`. See `AshA2A.Semantic.FalsifierSuite`'s moduledoc for the
      measured reason SPARQL evaluation is not reachable here yet.
    * `:backing` -- the real `AshA2A` module whose invariant this falsifier
      guards, or `:none` when that machinery does not exist in this repo
      yet. `:none` is reported as DEFERRED: the graph check discriminates,
      but there is nothing here it is yet guarding.

  This lives in its own module rather than nested inside
  `AshA2A.Semantic.FalsifierSuite` because that module builds its fourteen
  definitions in a module attribute, and a struct cannot be constructed in
  the same compilation context that defines it.
  """

  @enforce_keys [:id, :rfc, :title, :ask, :mandatory, :evaluation, :backing]
  defstruct [:id, :rfc, :title, :ask, :mandatory, :evaluation, :backing]

  @type t :: %__MODULE__{
          id: atom(),
          rfc: binary(),
          title: binary(),
          ask: binary(),
          mandatory: boolean(),
          evaluation: :structural | :sparql,
          backing: module() | :none
        }
end
