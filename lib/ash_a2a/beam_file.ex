# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.BeamFile do
  @moduledoc """
  Resolves the on-disk `.beam` object file of a loaded module.

  `:code.which/1` answers `:cover_compiled` for a module that `mix test --cover`
  has re-compiled in memory, so every static proof that reads a module's own
  BEAM chunks (imports, abstract code, atoms, running-code digest) or derives an
  `ebin` directory from it would fail under coverage. The object code that the
  cover tool instrumented still exists on the code path, so
  `:code.get_object_code/1` locates the original, uninstrumented file. Reading
  that file is what these proofs mean to read: the compiled subject, not the
  coverage-instrumented copy.
  """

  @doc "Path (charlist) of `module`'s `.beam` file on disk, or `{:error, reason}`."
  @spec path(module()) :: {:ok, charlist()} | {:error, term()}
  def path(module) when is_atom(module) do
    case :code.which(module) do
      path when is_list(path) and path != [] ->
        {:ok, path}

      :cover_compiled ->
        case :code.get_object_code(module) do
          {^module, _binary, filename} when is_list(filename) -> {:ok, filename}
          other -> {:error, {:no_beam_file, other}}
        end

      other ->
        {:error, {:no_beam_file, other}}
    end
  end

  @doc """
  Raw 16-byte md5 identifying `module`'s compiled code.

  A loaded module answers `module_info(:md5)`. Under `mix test --cover` the
  loaded module is the cover tool's instrumented recompilation, whose md5
  differs from the on-disk BEAM by construction and from the md5 any other OS
  process (a fresh consumer, an offline replay) computes for the same source.
  Identities that must reproduce across processes -- the court revision, the
  OCEL mapping digest, the validator identity -- therefore use the on-disk
  object code's md5 while the cover instrumentation is what is loaded. A module
  loaded from anywhere else (including a mutant) is identified by its loaded md5.
  """
  @spec md5(module()) :: binary()
  def md5(module) when is_atom(module) do
    with :cover_compiled <- :code.which(module),
         {^module, binary, _file} <- :code.get_object_code(module),
         {:ok, {^module, md5}} <- :beam_lib.md5(binary) do
      md5
    else
      _ -> module.module_info(:md5)
    end
  end

  @doc """
  Interns every atom `module`'s compiled BEAM names -- its atom table and its
  literal table -- WITHOUT loading or running the module.

  A fresh process that must `binary_to_term(bytes, [:safe])` a term naming atoms
  only a not-to-be-loaded module contains (e.g. a consequence-boundary module)
  calls this first: the atoms are exactly those compiled into the application,
  none attacker-controlled. Compile-time literal maps keep their atoms in the
  `LitT` chunk rather than the atom table, so both are read.
  """
  @spec intern_atoms(module()) :: :ok | {:error, term()}
  def intern_atoms(module) when is_atom(module) do
    with {:ok, path} <- path(module),
         {:ok, {_, [atoms: _]}} <- :beam_lib.chunks(path, [:atoms]),
         {:ok, {_, [{~c"LitT", lit}]}} <- :beam_lib.chunks(path, [~c"LitT"]) do
      intern_literals(lit)
    else
      {:ok, {_, [{~c"LitT", :missing_chunk}]}} -> :ok
      other -> {:error, other}
    end
  end

  # The chunk is `<<uncompressed_size::32, table::binary>>`; a zero size means
  # the table is stored uncompressed, otherwise it is zlib-compressed.
  defp intern_literals(<<0::32, table::binary>>), do: intern_table(table)

  defp intern_literals(<<_uncompressed::32, compressed::binary>>) do
    compressed |> :zlib.uncompress() |> intern_table()
  rescue
    error -> {:error, error}
  end

  defp intern_literals(_), do: :ok

  defp intern_table(<<count::32, rest::binary>>) do
    intern_literal_terms(count, rest)
  rescue
    error -> {:error, error}
  end

  defp intern_literal_terms(0, _), do: :ok

  defp intern_literal_terms(n, <<size::32, term::binary-size(size), rest::binary>>) do
    _ = :erlang.binary_to_term(term)
    intern_literal_terms(n - 1, rest)
  end
end
