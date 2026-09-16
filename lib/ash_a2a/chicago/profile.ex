defmodule AshA2A.Chicago.Profile do
  @moduledoc """
  RFC-SA2A-002 §25-§30 conformance profiles and the gate set each one requires.

  Profiles are cumulative: `SA2A-LOGIC` carries every `SA2A-CORE` court,
  `SA2A-PLAN` every LOGIC court, and so on up to `SA2A-STRICT`. A court declares
  the lowest profile it belongs to (`AshA2A.Chicago.Court.profile/0`); it is
  applicable to every profile at or above that rank.

  ## Required crown gates per profile

  §31 defines twelve Strict crown gates. The lower profiles are mapped onto the
  gates whose subject matter §26-§29 require:

  | profile  | required gates                          |
  |----------|-----------------------------------------|
  | `:core`  | 1 identity, 2 admission, 3 real collaborators |
  | `:logic` | core                                   |
  | `:plan`  | logic + 4 planning candidate-only, 5 preflight |
  | `:do`    | plan + 6 autonomy, 7 BRCE, 8 postcondition, 9 receipt binding, 10 replay, 11 fresh consumer |
  | `:strict`| all twelve (adds 12 zero inference on KNOWN) |

  A required gate with no applicable court is an open evidence gap (§145) and
  blocks `CONFORMANT`.
  """

  @type t :: :core | :logic | :plan | :do | :strict

  @profiles [:core, :logic, :plan, :do, :strict]

  @required_gates %{
    core: [1, 2, 3],
    logic: [1, 2, 3],
    plan: [1, 2, 3, 4, 5],
    do: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    strict: Enum.to_list(1..12)
  }

  @spec profiles() :: [t()]
  def profiles, do: @profiles

  @spec profile?(term()) :: boolean()
  def profile?(value), do: value in @profiles

  @spec rank(t()) :: non_neg_integer()
  def rank(profile) when profile in @profiles,
    do: Enum.find_index(@profiles, &(&1 == profile))

  @doc "True when a court declared at `court_profile` applies to a `claimed` profile run."
  @spec applicable?(t(), t()) :: boolean()
  def applicable?(court_profile, claimed), do: rank(court_profile) <= rank(claimed)

  @spec required_gates(t()) :: [1..12]
  def required_gates(profile) when profile in @profiles, do: Map.fetch!(@required_gates, profile)

  @doc "RFC name, e.g. `\"SA2A-STRICT\"`."
  @spec name(t()) :: String.t()
  def name(profile) when profile in @profiles,
    do: "SA2A-" <> String.upcase(Atom.to_string(profile))

  @doc "Parses `\"strict\"`, `\"SA2A-STRICT\"`, or `:strict`."
  @spec parse(String.t() | atom()) :: {:ok, t()} | {:error, :unknown_profile}
  def parse(value) when is_atom(value),
    do: if(value in @profiles, do: {:ok, value}, else: {:error, :unknown_profile})

  def parse(value) when is_binary(value) do
    normalized = value |> String.downcase() |> String.replace_prefix("sa2a-", "")

    Enum.find_value(
      @profiles,
      {:error, :unknown_profile},
      &(Atom.to_string(&1) == normalized && {:ok, &1})
    )
  end
end
