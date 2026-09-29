defmodule AshA2A.PreparedEffect do
  @enforce_keys [:instance, :effect, :consequence_class, :prepared_digest]
  defstruct [:instance, :effect, :consequence_class, :prepared_digest, :authority_epoch, :prepared_at]
  @type t :: %__MODULE__{instance: AshA2A.EffectInstance.t(), effect: term(), consequence_class: atom(),
    prepared_digest: binary(), authority_epoch: non_neg_integer(), prepared_at: term()}
  def new(instance, effect, class, opts \\ []) do
    body = %{"schema" => "sa2a.prepared-effect.v1", "effect_id" => instance.effect_id,
      "request_id" => instance.request_id, "subject_digest" => instance.subject_digest,
      "effect" => effect, "consequence_class" => to_string(class),
      "authority_epoch" => Keyword.get(opts, :authority_epoch, 0)}
    with {:ok, digest} <- AshA2A.Identity.Canonical.digest(body) do
      {:ok, struct!(__MODULE__, instance: instance, effect: effect, consequence_class: class,
        prepared_digest: digest, authority_epoch: Keyword.get(opts, :authority_epoch, 0),
        prepared_at: Keyword.get(opts, :prepared_at))}
    end
  end
end
