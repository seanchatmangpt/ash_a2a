defmodule A2aDemo.Auth do
  @moduledoc """
  The demo credential table and the boot-time grant issuance.

  Bearer tokens map to fixed identities; `issue_demo_grants/0` files the
  standing `"create_note"` grant for the demo principal so the `:change`
  skill is admissible, while `other-user` is deliberately left ungranted so
  the fail-closed authority gate has a real negative case.
  """

  @tokens %{
    "demo-token" => %{id: "demo-user", tenant: "demo"},
    "other-token" => %{id: "other-user", tenant: "demo"}
  }

  def verify("bearer_auth", token, _conn) when is_map_key(@tokens, token) do
    {:ok, Map.fetch!(@tokens, token)}
  end

  def verify(_scheme, _credential, _conn), do: {:error, "unknown token"}

  @doc """
  Files the standing grant for the demo principal. The capability id is the
  CANONICAL, resource-qualified id from the compiled capability index
  (`"A2aDemo.Note.create_note"`) -- the same id `Grant.authorize/3` is asked
  for at dispatch (SA2A-AUTH-017). Idempotent for one boot (re-granting the
  same (subject, capability) refuses with `:token_id_taken`).
  """
  def issue_demo_grants do
    subject = AshA2A.Identity.principal(@tokens["demo-token"])
    {:ok, skill} = AshA2A.Info.skill(A2aDemo.Note, :create_note)
    {:ok, _authority} = AshA2A.Authority.Grant.grant(subject, skill.id)
    :ok
  end
end
