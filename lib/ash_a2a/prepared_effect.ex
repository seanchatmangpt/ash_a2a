defmodule AshA2A.PreparedEffect do
  @enforce_keys [:instance, :effect, :consequence_class, :prepared_digest]
  defstruct [
    :instance,
    :effect,
    :consequence_class,
    :prepared_digest,
    :authority_epoch,
    :prepared_at
  ]

  def new(instance, effect, class, opts \\ []) do
    body = %{
      "effect_id" => instance.effect_id,
      "subject_digest" => instance.subject_digest,
      "effect" => effect,
      "consequence_class" => to_string(class),
      "authority_epoch" => Keyword.get(opts, :authority_epoch, 0)
    }

    with {:ok, digest} <- AshA2A.Identity.Canonical.digest(body) do
      {:ok,
       struct!(__MODULE__,
         instance: instance,
         effect: effect,
         consequence_class: class,
         prepared_digest: digest,
         authority_epoch: Keyword.get(opts, :authority_epoch, 0),
         prepared_at: Keyword.get(opts, :prepared_at)
       )}
    end
  end
end
