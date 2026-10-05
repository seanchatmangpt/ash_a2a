# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/test/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Passport.Merkle do
  @moduledoc """
  RFC 6962-style SHA-256 Merkle tree over the passport's pinned entries.

  Domain separation follows RFC 6962 section 2.1: a leaf hash is
  `H(0x00 || data)` and an interior node is `H(0x01 || left || right)`,
  so a raw leaf can never be replayed as an interior node (or vice versa).

  Odd-length levels duplicate their last node (Bitcoin convention), which
  keeps `root/1`, `proof/2` and `valid_proof?/3` consistent by construction
  — the audit path generator replays the exact `level_up/1` the root used.

  Every entry of a passport is pinned by this tree: capability attestations
  first, then evidence entries, in document order. When verification finds a
  leaf whose current hash no longer matches the SIGNED leaf list, it returns
  the audit path (from `proof/2`) computed over the signed leaves — the proof
  that the SIGNED tree contained the old value at that index, i.e. the
  Merkle proof pinning the mutation to a specific entry.
  """

  @type leaf_hash :: <<_::256>>

  @spec leaf(binary()) :: leaf_hash()
  def leaf(data) when is_binary(data), do: :crypto.hash(:sha256, <<0, data::binary>>)

  @doc """
  Root of the tree over `leaves` (already-hashed 32-byte leaf hashes, in
  document order). Refuses the empty tree — a passport with no pinned
  entries has nothing to authenticate and is rejected upstream.
  """
  @spec root([leaf_hash()]) :: {:ok, leaf_hash()} | {:error, :empty | :not_a_list}
  def root([]), do: {:error, :empty}

  def root(leaves) when is_list(leaves), do: {:ok, build(leaves)}
  def root(_), do: {:error, :not_a_list}

  @doc """
  Audit path for `index` over `leaves`, replaying the exact same
  `level_up/1` sequence `root/1` used. Each step carries the sibling hash
  and whether the sibling sits on the `:left` or `:right`.
  """
  @spec proof([leaf_hash()], non_neg_integer()) ::
          {:ok, [%{required(:side) => :left | :right, required(:hash) => leaf_hash()}]} | {:error, term()}
  def proof(leaves, index) when is_list(leaves) and is_integer(index) do
    cond do
      leaves == [] -> {:error, :empty}
      index < 0 or index >= length(leaves) -> {:error, {:out_of_range, length(leaves)}}
      true -> do_proof(leaves, index, [])
    end
  end

  def proof(_, _), do: {:error, :not_a_list}

  @doc """
  Recomputes the root implied by `leaf_hash` plus `proof` and compares it
  to `root` in constant time. Pure, fail-closed: any malformed step is
  `false`.
  """
  @spec valid_proof?(term(), term(), term()) :: boolean()
  def valid_proof?(leaf_hash, proof, root)

  def valid_proof?(<<_::256>> = leaf_hash, proof, <<_::256>> = root) when is_list(proof) do
    Enum.reduce_while(proof, {:ok, leaf_hash}, fn
      %{side: :left, hash: sib}, {:ok, cur}
      when is_binary(sib) and byte_size(sib) == 32 ->
        {:cont, {:ok, node(sib, cur)}}

      %{side: :right, hash: sib}, {:ok, cur}
      when is_binary(sib) and byte_size(sib) == 32 ->
        {:cont, {:ok, node(cur, sib)}}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, computed} -> :crypto.hash_equals(computed, root)
      :error -> false
    end
  end

  def valid_proof?(_, _, _), do: false

  # ------------------------------------------------------------------
  # Tree construction
  # ------------------------------------------------------------------

  defp build([root]), do: root

  defp build(level) do
    level
    |> level_up()
    |> build()
  end

  defp level_up([a, b | rest]), do: [node(a, b) | level_up(rest)]
  # Odd-length level (including a lone node): duplicate the last node.
  defp level_up([a]), do: [node(a, a)]
  defp level_up([]), do: []

  defp node(a, b), do: :crypto.hash(:sha256, <<1, a::binary, b::binary>>)

  # ------------------------------------------------------------------
  # Audit path generation
  # ------------------------------------------------------------------

  defp do_proof([_], 0, acc), do: {:ok, Enum.reverse(acc)}

  defp do_proof(level, index, acc) do
    n = length(level)
    last = n - 1

    {sibling_index, side} =
      cond do
        # Odd-duplicate convention: the last node of an odd level is paired
        # with ITSELF in level_up/1, so its audit-path sibling is itself on
        # the right — pairing it with its left neighbour would replay to a
        # node that does not exist in the tree.
        rem(n, 2) == 1 and index == last -> {index, :right}
        rem(index, 2) == 0 -> {index + 1, :right}
        true -> {index - 1, :left}
      end

    step = %{side: side, hash: Enum.at(level, sibling_index)}
    do_proof(level_up(level), div(index, 2), [step | acc])
  end
end
