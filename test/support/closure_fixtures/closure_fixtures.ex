# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ClosureFixtures.Sink do
  @moduledoc """
  Fixture effector wrapper for the closure court: `write/1` stands in for an
  external effect. The court's test classifies this module as an effector.
  """
  def write(term), do: {:written, term}
  def read(term), do: {:read, term}
end

defmodule AshA2A.ClosureFixtures.Kernel do
  @moduledoc "Fixture allowed caller: the only module permitted to reach `Sink`."
  def commit(term), do: AshA2A.ClosureFixtures.Sink.write(term)
end

defmodule AshA2A.ClosureFixtures.Bypass do
  @moduledoc """
  PLANTED bypass: reaches `Sink.write/1` two local hops below a public entry,
  without going through `Kernel`. Removing this module from the analysed set
  is the "plant removed" case.
  """
  def entry(term), do: helper(term)
  defp helper(term), do: AshA2A.ClosureFixtures.Sink.write(term)
end

defmodule AshA2A.ClosureFixtures.FunRefBypass do
  @moduledoc "PLANTED bypass through a remote function reference (`&Sink.write/1`)."
  def writer, do: &AshA2A.ClosureFixtures.Sink.write/1
end

defmodule AshA2A.ClosureFixtures.Dynamic do
  @moduledoc "Fixture with dynamic call sites the court must flag as UNRESOLVED."
  def via_apply(m, f, args), do: apply(m, f, args)
  def via_module_var(m, x), do: m.write(x)
end

defmodule AshA2A.ClosureFixtures.ReadOnly do
  @moduledoc "Fixture calling a NON-effector function of `Sink` (function-level classification)."
  def look(term), do: AshA2A.ClosureFixtures.Sink.read(term)
end
