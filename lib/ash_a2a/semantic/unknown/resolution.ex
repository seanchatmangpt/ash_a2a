defmodule AshA2A.Semantic.Unknown.Resolution do
  @moduledoc """
  The result of resolving an UNKNOWN: **a candidate, never canonical
  truth** (RFC S37/S40).

  Every field that could carry standing is fixed at construction:
  `standing: :candidate`, `authority: :none`. `new/3` reads neither from
  the payload, so a payload asserting otherwise changes nothing (and is
  separately refused by `AshA2A.Semantic.LlmBoundary.candidate/3`'s
  claim scan before ever reaching here).

  The same struct carries resolutions from all six RFC S37 routes --
  LLM, human, prover, search, synthesis, experiment. A human-sourced or
  prover-sourced resolution is candidate-standing for exactly the same
  reason an LLM-sourced one is: standing comes from deterministic
  admission over the resolved content, not from the trustworthiness of
  whatever produced it.
  """

  alias AshA2A.Semantic.Unknown

  @enforce_keys [:unknown_fingerprint, :class, :resolver, :payload, :fingerprint]
  defstruct [
    :unknown_fingerprint,
    :class,
    :resolver,
    :payload,
    :fingerprint,
    standing: :candidate,
    authority: :none
  ]

  @type t :: %__MODULE__{
          unknown_fingerprint: String.t(),
          class: String.t(),
          resolver: Unknown.resolver_kind(),
          payload: map(),
          fingerprint: String.t(),
          standing: :candidate,
          authority: :none
        }

  @doc """
  Builds a candidate resolution. Called only by
  `AshA2A.Semantic.LlmBoundary.candidate/3` in ordinary use -- that
  function is the boundary, this is its product.
  """
  @spec new(Unknown.t(), Unknown.resolver_kind(), map()) :: {:ok, t()} | {:error, map()}
  def new(%Unknown{} = unknown, resolver, payload) when is_map(payload) do
    if resolver in Unknown.resolver_kinds() do
      resolution = %__MODULE__{
        unknown_fingerprint: unknown.fingerprint,
        class: unknown.class,
        resolver: resolver,
        payload: payload,
        fingerprint: ""
      }

      {:ok,
       %{
         resolution
         | fingerprint: Unknown.fingerprint({unknown.fingerprint, resolver, payload})
       }}
    else
      {:error, %{code: :unknown_resolver_kind, resolver: resolver}}
    end
  end
end
