# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2A.Conformance.Check do
  @moduledoc """
  One requirement check of a conformance profile.

  A check is a probe that returns `{status, evidence}` where status is:

    * `:pass` -- an EXECUTED probe (a call into the code, a real court, an
      inspection of compiled BEAM chunks or a loaded mix project) supported the
      requirement. A documentation grep is never a pass.
    * `:fail` -- the probe ran and the requirement is not met, or the module /
      interface the requirement depends on does not exist yet. Evidence names
      the precise reason.
    * `:unverified` -- the requirement needs an operator prerequisite or
      something not executable here (no `--github`, no built release, ...).

  `run/4` is total: a probe that raises or returns a malformed value is a
  `:fail`, never a crash and never a pass.
  """

  @type status :: :pass | :fail | :unverified
  @type t :: %__MODULE__{
          id: String.t(),
          profile: atom(),
          title: String.t(),
          status: status(),
          evidence: String.t()
        }

  @enforce_keys [:id, :profile, :title, :status, :evidence]
  defstruct @enforce_keys

  @statuses [:pass, :fail, :unverified]

  @spec run(String.t(), atom(), String.t(), (-> {status(), term()})) :: t()
  def run(id, profile, title, fun) when is_function(fun, 0) do
    {status, evidence} =
      try do
        case fun.() do
          {status, evidence} when status in @statuses ->
            {status, evidence}

          other ->
            {:fail, "malformed probe result: #{inspect(other, limit: 5)}"}
        end
      rescue
        e -> {:fail, "probe raised #{inspect(e.__struct__)}: #{Exception.message(e)}"}
      catch
        kind, reason -> {:fail, "probe #{kind}: #{inspect(reason, limit: 5)}"}
      end

    %__MODULE__{
      id: id,
      profile: profile,
      title: title,
      status: status,
      evidence: to_string(evidence)
    }
  end
end
