defmodule AshA2A.SecurityProfile.Template do
  @moduledoc """
  Compile-time generator behind `AshA2A.SecurityProfile` (RFC-SA2A-007).

  `use AshA2A.SecurityProfile.Template, env: env, requested: profile` defines
  the profile API for one build. `env` is the Mix environment the module is
  compiled under and `requested` the build-config profile. They are explicit
  arguments so a court can compile a `:prod` fixture from a `:test` run.

  ## What is decided at compile time

    * `requested` must be `:strict`, `:legacy_compat` or `:dev_bypass`;
      anything else is a `CompileError`.
    * `requested == :dev_bypass` with `env == :prod` is a `CompileError`.
    * `announce_dev_bypass/0`, `dev_bypass_banner/0` and every reference to
      the `:dev_bypass` atom are defined only when `env != :prod`; in a prod
      build they are absent from the BEAM (proved by the BEAM-scan court in
      `test/ash_a2a/security_profile/security_profile_test.exs`).

  The profile is a constant of the build. There is no runtime, per-call or
  request-data input.
  """

  defmacro __using__(opts) do
    env = Keyword.fetch!(opts, :env)
    requested = Keyword.fetch!(opts, :requested)

    quote bind_quoted: [env: env, requested: requested] do
      @sp_env env
      @sp_requested requested
      @sp_dev_bypass_compiled env != :prod
      @sp_profiles [:strict, :legacy_compat] ++ if(env != :prod, do: [:dev_bypass], else: [])

      if @sp_requested not in @sp_profiles do
        raise CompileError,
          file: __ENV__.file,
          line: __ENV__.line,
          description:
            "unknown security profile #{inspect(@sp_requested)} for env #{inspect(@sp_env)}; " <>
              "allowed: #{inspect(@sp_profiles)}" <>
              if(@sp_env == :prod and @sp_requested == :dev_bypass,
                do: " (the dev_bypass profile is compiled out of prod builds)",
                else: ""
              )
      end

      @doc "The build's security profile (a compile-time constant)."
      @spec current() :: :strict | :legacy_compat | :dev_bypass
      def current, do: unquote(@sp_requested)

      @doc "True under the `:strict` profile."
      @spec strict?() :: boolean()
      def strict?, do: unquote(@sp_requested == :strict)

      @doc "True under the explicit `:legacy_compat` profile."
      @spec legacy_compat?() :: boolean()
      def legacy_compat?, do: unquote(@sp_requested == :legacy_compat)

      @doc "Whether this build contains the dev_bypass code at all (false in prod)."
      @spec dev_bypass_compiled?() :: boolean()
      def dev_bypass_compiled?, do: unquote(@sp_dev_bypass_compiled)

      if @sp_dev_bypass_compiled do
        @doc "True under the opt-in `:dev_bypass` profile (never true in prod)."
        @spec dev_bypass?() :: boolean()
        def dev_bypass?, do: unquote(@sp_requested == :dev_bypass)

        @doc "The loud boot banner printed under `:dev_bypass`."
        @spec dev_bypass_banner() :: String.t()
        def dev_bypass_banner do
          """
          ==========================================================================
          !! ash_a2a security profile DEV_BYPASS ACTIVE                            !!
          !! Boot-time security refusals are DISABLED. Every receipt is stamped     !!
          !! security_profile: :dev_bypass. NEVER run this profile in production.   !!
          ==========================================================================
          """
        end

        @doc "Prints the banner and emits `[:ash_a2a, :security_profile, :dev_bypass]`."
        @spec announce_dev_bypass() :: :ok
        def announce_dev_bypass do
          IO.puts(:stderr, dev_bypass_banner())

          :telemetry.execute(
            [:ash_a2a, :security_profile, :dev_bypass],
            %{system_time: System.system_time()},
            %{profile: unquote(@sp_requested)}
          )

          :ok
        end
      else
        @doc "Always false in a prod build."
        @spec dev_bypass?() :: false
        def dev_bypass?, do: false
      end

      @doc """
      Stamps `map` (a receipt or evidence map) with the build's profile.
      Any caller-supplied `:security_profile` / `\"security_profile\"` is
      discarded, so request data cannot forge or switch it.
      """
      @spec stamp(map()) :: map()
      def stamp(map) when is_map(map) do
        map
        |> Map.delete("security_profile")
        |> Map.put(:security_profile, unquote(@sp_requested))
      end
    end
  end
end
