defmodule AshA2A.Chicago.Court do
  @moduledoc """
  Behaviour for one RFC-SA2A-002 Chicago qualification court.

  A court owns a test-ID family (Appendix B, e.g. `"CHI-BRCE"`), declares its
  falsifiers up front (§11), and executes them against the real SUT inside the
  run's `AshA2A.Chicago.Context`:

      defmodule AshA2A.Chicago.Courts.Brce do
        use AshA2A.Chicago.Court

        @impl true
        def id, do: "CHI-BRCE"
        @impl true
        def title, do: "Sole DO boundary / zero unreceipted actuation"
        @impl true
        def gate, do: 7
        @impl true
        def profile, do: :do
        @impl true
        def rfc_sections, do: ["§38", "§68", "§69"]
        @impl true
        def falsifiers, do: [...]
        @impl true
        def run(ctx), do: [...]
      end

  Courts are discovered, not registered: `use AshA2A.Chicago.Court` marks the
  module (`__chicago_court__/0`) and `AshA2A.Chicago.courts/0` finds every
  compiled `:ash_a2a` module carrying the mark. Adding a court never edits a
  central list. Test-only courts that exercise the court machinery itself use
  `use AshA2A.Chicago.Court, discoverable: false` and are passed to the runner
  explicitly, so they never contaminate a real qualification run.

  ## Rules the runner enforces

    * `run/1` must return exactly one `AshA2A.Chicago.Result` per declared
      falsifier. A declared falsifier with no result, a result for an
      undeclared id, or a raise/throw/exit from `run/1` becomes `:unknown`
      (§129, §130) -- never a pass.
    * Every stimulus must go through `AshA2A.Chicago.Context.stimulus/3` so the
      independent observer can attribute SUT evidence to it.
    * Load-bearing collaborators must be real (§9, §10): no Mock/:meck/Mox.

  ## Optional callbacks

    * `ocel_mappings/0` -- extra `AshA2A.Chicago.Ocel.Mapping`s for SUT
      telemetry events this court relies on (merged into the observer's
      admitted, versioned mapping before the run, §17).
    * `refusal_codes/0` -- `%{code => AshA2A.Semantic.Refusal class}` for any
      new refusal codes this court's modules introduce; picked up by
      `AshA2A.Semantic.Refusal.mapping/0` without editing its table.
  """

  alias AshA2A.Chicago.{Context, Falsifier, Ocel, Profile, Result}

  @callback id() :: String.t()
  @callback title() :: String.t()
  @callback gate() :: 1..12 | nil
  @callback profile() :: Profile.t()
  @callback rfc_sections() :: [String.t()]
  @callback falsifiers() :: [Falsifier.t()]
  @callback run(Context.t()) :: [Result.t()]
  @callback ocel_mappings() :: [Ocel.Mapping.t()]
  @callback refusal_codes() :: %{atom() => atom()}

  @optional_callbacks ocel_mappings: 0, refusal_codes: 0

  defmacro __using__(opts) do
    discoverable = Keyword.get(opts, :discoverable, true)

    quote do
      @behaviour AshA2A.Chicago.Court

      @doc false
      def __chicago_court__, do: unquote(discoverable)

      @doc false
      def __sa2a_refusal_codes__, do: refusal_codes()

      @impl AshA2A.Chicago.Court
      def ocel_mappings, do: []

      @impl AshA2A.Chicago.Court
      def refusal_codes, do: %{}

      defoverridable ocel_mappings: 0, refusal_codes: 0
    end
  end

  @doc "True when `module` is a compiled Chicago court (discoverable or not)."
  @spec court?(module()) :: boolean()
  def court?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__chicago_court__, 0)
  end

  @doc "True when `module` is a court that discovery should pick up."
  @spec discoverable?(module()) :: boolean()
  def discoverable?(module) when is_atom(module),
    do: court?(module) and module.__chicago_court__()
end
