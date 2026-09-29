defmodule AshA2A.SA2A.Conformance.Claim do
  @moduledoc """
  The RFC-SA2A-007 section 4 conformance statement, computed and never
  hand-written:

      SA2A <version> conforms to profile <Cn> at independence tier <Ti>,
      hosting scope <S>, on subject SHA <H>

  It is emitted only when every required check passed; otherwise
  `refusal/2` renders `NOT CONFORMANT to <Cn>` with the failing and unverified
  check ids (or the forced reason, for `:dev_bypass` / `:legacy_compat`).
  """

  @spec statement(atom(), %{version: String.t(), tier: String.t(), scope: String.t()}, String.t()) ::
          String.t()
  def statement(profile, %{version: version, tier: tier, scope: scope}, sha) do
    "SA2A #{version} conforms to profile #{label(profile)} at independence tier #{tier}, " <>
      "hosting scope #{scope}, on subject SHA #{sha}"
  end

  @spec refusal(atom(), [String.t()]) :: String.t()
  def refusal(profile, reasons),
    do: "NOT CONFORMANT to #{label(profile)}: " <> Enum.join(reasons, "; ")

  @spec label(atom()) :: String.t()
  def label(profile), do: profile |> Atom.to_string() |> String.upcase()
end
