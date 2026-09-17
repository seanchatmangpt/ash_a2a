defmodule AshA2A.Chicago.Courts.SA2AV269_17Topology do
  @moduledoc """
  Orient-release / close-critical-repo-boundaries court for the v26.9.17 SA2A
  self-improvement release qualification
  (`test/support/hddl/sa2a_v26_9_17_dogfood/{domain,problem}.hddl`).

  ## Scope -- existence/identity only, never capability depth

  This court's falsifier is deliberately narrow and structural: *does the
  claimed repo exist and have a real HEAD* -- exactly `AshA2A.Chicago.Subject`'s
  exact-identity gate applied to cross-repo topology instead of one subject.
  It is real, re-runnable machinery (a real `git rev-parse` / `git status`
  subprocess per repo, real telemetry, real independent OCEL corroboration),
  never a static claim.

  It does NOT re-audit any repo's source, dependency graph, or the depth to
  which a `(repo, capability)` pair's implementation is real -- that was
  already done, once, by direct investigation on 2026-09-17 and is recorded
  below as disclosed, NOT-re-verified-by-this-court documentation:

  | repo         | capability               | established verdict (2026-09-17) |
  |--------------|--------------------------|-----------------------------------|
  | autofde-lab  | cap-crown                | ALIVE                              |
  | ash-a2a      | cap-orchestration        | ALIVE (self)                       |
  | ash-r2rml    | cap-semantic-feedback    | ALIVE                              |
  | bcinr        | cap-bounded-select       | ALIVE                              |
  | ggen         | cap-manufacture          | ALIVE                              |
  | ggen-igniter | cap-framework-projection | ALIVE                              |
  | xaas         | cap-system-authority     | ALIVE                              |
  | affidavit    | cap-standing             | ALIVE                              |
  | beam4pm      | cap-process-court        | PARTIAL                            |

  `unrdf`/cap-runtime and `wasm4pm`/cap-portable-runtime are declared HDDL
  `:objects` and `owns` facts in `problem.hddl` but are not marked `critical`
  there -- this court still checks their real existence/identity (they are
  real repos on disk), it just does not include them in the "critical pair"
  positive control below. Re-deriving the ALIVE/PARTIAL verdicts above, or
  auditing what each repo's capability implementation actually does, is
  explicitly OUT of this court's falsifiers -- that would silently overclaim
  more than a `git rev-parse` subprocess can ever verify. Anyone who needs
  those verdicts re-verified must re-run the original direct investigation,
  not trust this court's PASSED/green as proof of it.

  ## Real falsifiers (RFC-SA2A-002 Chicago style, zero mocks)

    * `SA2A-TOPO-001` (`:measurement`) -- checks all 11 HDDL repo objects this
      domain's `:init` declares and records, per repo, whether it is real
      (`git rev-parse --verify HEAD^{commit}` succeeds with a real hex object
      id) plus its observed HEAD and dirty flag.
    * `SA2A-TOPO-002` (`:positive_control`) -- the 9 critical
      `(repo, capability)` pairs `problem.hddl` marks `critical` are each
      backed by a really-present repo with a real git HEAD: the release
      chain has no phantom dependency. Proves the existence check
      discriminates rather than reporting everyone alive (RFC-SA2A-002 §100
      applied to this ad hoc topology check).
    * `SA2A-TOPO-003` (`:negative`) -- attacks the boundary itself: a
      synthetic scratch directory that is never a git repository is
      presented as a repo path. Killed only when `check_repo/1` reports it
      `real?: false`, never `true` -- proof this is a real existence check,
      not a check that always answers yes.

  Reuses `AshA2A.Chicago.Subject.capture/1`'s real git-subprocess pattern
  (`System.cmd("git", ..., cd: repo, stderr_to_stdout: true)`, rescued to
  `nil`/`false` rather than raising) rather than reimplementing it from
  scratch; `Subject`'s own `commit/2`/`dirty?/1` are module-private so this
  court mirrors their exact shape instead of calling them directly.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Ocel.Mapping

  @court "SA2A-TOPO"

  @checked_event [:ash_a2a, :chicago, :topology, :repo_checked]
  @checked_activity "chicago.topology.repo_checked"

  @object_id ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  # {hddl repo object (problem.hddl :objects, dash-case), real sibling
  # directory name under root/0, hddl capability object it owns, critical?}
  @repos [
    {"autofde-lab", "autofde-lab", "cap-crown", true},
    {"ash-a2a", "ash_a2a", "cap-orchestration", true},
    {"ash-r2rml", "ash_r2rml", "cap-semantic-feedback", true},
    {"bcinr", "bcinr", "cap-bounded-select", true},
    {"ggen", "ggen", "cap-manufacture", true},
    {"ggen-igniter", "ggen_igniter", "cap-framework-projection", true},
    {"xaas", "xaas", "cap-system-authority", true},
    {"affidavit", "affidavit", "cap-standing", true},
    {"beam4pm", "beam4pm", "cap-process-court", true},
    {"unrdf", "unrdf", "cap-runtime", false},
    {"wasm4pm", "wasm4pm", "cap-portable-runtime", false}
  ]

  @default_root "/Users/sac"

  @impl true
  def id, do: @court

  @impl true
  def title,
    do: "SA2A v26.9.17 cross-repo topology -- existence/identity of the 11 HDDL repo objects"

  @impl true
  def gate, do: nil

  @impl true
  def profile, do: :core

  @impl true
  def rfc_sections, do: ["§5", "§32"]

  @doc """
  The 11 `{hddl_object, sibling_dir, hddl_capability, critical?}` tuples this
  court checks, exactly as `problem.hddl`'s `:objects`/`owns`/`critical`
  facts declare them.
  """
  @spec repos() :: [{String.t(), String.t(), String.t(), boolean()}]
  def repos, do: @repos

  @doc """
  Root directory the 11 sibling repos live under on this machine. Overridable
  via `config :ash_a2a, :chicago_topology_root, path` for a machine with a
  different layout; defaults to this session's real, confirmed-present
  `/Users/sac`.
  """
  @spec root() :: Path.t()
  def root, do: Application.get_env(:ash_a2a, :chicago_topology_root, @default_root)

  @doc "Real absolute path for one sibling directory name under `root/0`."
  @spec repo_path(String.t()) :: Path.t()
  def repo_path(dir), do: Path.join(root(), dir)

  @doc """
  Real, structural existence/identity check for one repo path: a real
  `git rev-parse --verify --quiet HEAD^{commit}` subprocess `cd`'d into
  `path` (mirroring `AshA2A.Chicago.Subject`'s exact-identity subprocess
  style), gated by a real hex object-id shape check so a garbled or
  malicious stdout is never accepted as a HEAD. Never raises: a path that
  does not exist, is not a directory, or is not a git repository resolves to
  `real?: false`, `head: nil`, `dirty?: nil` -- the same "record, never
  invent" discipline as `Subject.capture/1`.
  """
  @spec check_repo(Path.t()) :: %{
          real?: boolean(),
          head: String.t() | nil,
          dirty?: boolean() | nil
        }
  def check_repo(path) do
    case git(path, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) do
      nil ->
        %{real?: false, head: nil, dirty?: nil}

      head ->
        if Regex.match?(@object_id, head) do
          %{real?: true, head: head, dirty?: dirty?(path)}
        else
          %{real?: false, head: nil, dirty?: nil}
        end
    end
  end

  # --- declarations (§11) ------------------------------------------------------

  @impl true
  def falsifiers do
    [
      Falsifier.new!(
        id: "SA2A-TOPO-001",
        court_id: @court,
        kind: :measurement,
        invariant:
          "Every repo the v26.9.17 problem.hddl declares as an :objects fact is a real, " <>
            "checkable local repository -- the release topology has no phantom node",
        stimulus:
          "check_repo/1 (real git rev-parse + git status subprocess) over all 11 real " <>
            "sibling paths named in problem.hddl's :objects list",
        boundary: "AshA2A.Chicago.Courts.SA2AV269_17Topology.check_repo/1",
        attempt_evidence:
          "#{@checked_activity} observed 11x, one per HDDL repo object, during this " <>
            "falsifier's stimulus window",
        rfc_sections: ["§5"],
        attempt_predicate: {:count, @checked_activity, :gte, 11}
      ),
      Falsifier.new!(
        id: "SA2A-TOPO-002",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "Every one of the 9 (repo, capability) pairs problem.hddl marks `critical` is " <>
            "backed by a really-present repo with a real git HEAD: the release chain has no " <>
            "phantom dependency, and this discriminates -- it is not a check that reports " <>
            "everyone alive regardless of reality (§100)",
        stimulus:
          "check_repo/1 over the 9 real sibling paths owning a `critical` capability in " <>
            "problem.hddl",
        boundary: "AshA2A.Chicago.Courts.SA2AV269_17Topology.check_repo/1",
        attempt_evidence:
          "#{@checked_activity} observed 9x, one per critical (repo, capability) pair, " <>
            "during this falsifier's stimulus window",
        survival_evidence:
          "no #{@checked_activity} in this window reports real=false for a critical repo",
        rfc_sections: ["§5", "§100"],
        attempt_predicate: {:count, @checked_activity, :gte, 9},
        outcome_predicate: {:not_observed, @checked_activity, %{"real" => "false"}}
      ),
      Falsifier.new!(
        id: "SA2A-TOPO-003",
        court_id: @court,
        kind: :negative,
        invariant:
          "A path that is never a real git repository must not be reported as having a real " <>
            "HEAD -- the existence check discriminates rather than answering \"real\" for " <>
            "every path it is handed",
        stimulus:
          "check_repo/1 over a synthetic scratch directory (created fresh, never `git init`'d) " <>
            "presented as a claimed critical-pair repo path",
        boundary: "AshA2A.Chicago.Courts.SA2AV269_17Topology.check_repo/1",
        forbidden_outcome: "the synthetic non-repo path is reported real?: true",
        attempt_evidence: "#{@checked_activity} observed for the synthetic path",
        survival_evidence: "#{@checked_activity} for the synthetic path reports real=false",
        guard:
          "check_repo/1's git rev-parse --verify --quiet exit-code check plus the hex " <>
            "object-id regex gate on stdout",
        failure_class: :identity_failure,
        rfc_sections: ["§5"],
        attempt_predicate: {:observed, @checked_activity, %{"repo" => "sa2a-topo-003-synthetic"}},
        outcome_predicate:
          {:observed, @checked_activity, %{"repo" => "sa2a-topo-003-synthetic", "real" => "true"}}
      )
    ]
  end

  # --- OCEL mappings (§17) -----------------------------------------------------

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: @checked_event,
        activity: @checked_activity,
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"repo", meta[:repo], "checked_repo"},
            {"capability", meta[:capability], "owned_capability"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [:repo, :path, :capability, :critical, :real, :head, :dirty])
        end
      )
    ]
  end

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})

    [
      guarded(f["SA2A-TOPO-001"], fn -> run_all_repos(ctx, f["SA2A-TOPO-001"]) end),
      guarded(f["SA2A-TOPO-002"], fn -> run_critical_repos(ctx, f["SA2A-TOPO-002"]) end),
      guarded(f["SA2A-TOPO-003"], fn -> run_synthetic_attack(ctx, f["SA2A-TOPO-003"]) end)
    ]
  end

  # SA2A-TOPO-001
  defp run_all_repos(ctx, f) do
    statuses =
      Context.stimulus(ctx, f, fn ->
        Enum.map(@repos, fn {obj, dir, cap, critical?} ->
          {obj, check_and_emit(obj, repo_path(dir), cap, critical?)}
        end)
      end)

    checked = Enum.count(Context.observed(ctx, f), &(&1.activity == @checked_activity))

    Result.measured(f,
      attempt_observed?: checked == length(@repos),
      measurements:
        Map.new(statuses, fn {obj, s} ->
          {obj, %{"real" => s.real?, "head" => s.head, "dirty" => s.dirty?}}
        end),
      evidence: %{"repos_checked" => checked}
    )
  end

  # SA2A-TOPO-002
  defp run_critical_repos(ctx, f) do
    critical = Enum.filter(@repos, fn {_obj, _dir, _cap, critical?} -> critical? end)

    statuses =
      Context.stimulus(ctx, f, fn ->
        Enum.map(critical, fn {obj, dir, cap, critical?} ->
          {obj, check_and_emit(obj, repo_path(dir), cap, critical?)}
        end)
      end)

    checked = Enum.count(Context.observed(ctx, f), &(&1.activity == @checked_activity))
    all_real? = Enum.all?(statuses, fn {_obj, s} -> s.real? end)

    Result.positive(f,
      attempt_observed?: checked == length(critical),
      expected_outcome_observed?: checked == length(critical) and all_real?,
      evidence: %{
        "critical_pairs" =>
          Map.new(statuses, fn {obj, s} -> {obj, %{"real" => s.real?, "head" => s.head}} end)
      }
    )
  end

  # SA2A-TOPO-003
  #
  # The synthetic directory must NOT be created under `ctx.evidence_dir`:
  # that directory (an ExUnit `tmp_dir`, or any evidence root a caller
  # chooses) commonly lives *inside* a real git working tree (e.g. this very
  # repo checkout), and `git rev-parse` walks up to the nearest enclosing
  # `.git` -- a nested scratch dir would then resolve to the ENCLOSING repo's
  # real HEAD, silently defeating the attack. `System.tmp_dir!/0` (the real
  # OS temp root) is real, confirmed, and outside every git working tree.
  defp run_synthetic_attack(ctx, f) do
    synthetic =
      Path.join(
        System.tmp_dir!(),
        "sa2a-topo-003-synthetic-non-repo-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(synthetic)
    File.mkdir_p!(synthetic)

    status =
      Context.stimulus(ctx, f, fn ->
        check_and_emit("sa2a-topo-003-synthetic", synthetic, nil, false)
      end)

    File.rm_rf!(synthetic)

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, @checked_activity),
      forbidden_outcome_observed?: status.real? == true,
      evidence: %{"path" => synthetic, "real" => status.real?, "head" => status.head}
    )
  end

  defp check_and_emit(repo_obj, path, capability, critical?) do
    status = check_repo(path)

    :telemetry.execute(@checked_event, %{system_time: System.system_time()}, %{
      repo: repo_obj,
      path: path,
      capability: capability,
      critical: critical?,
      real: status.real?,
      head: status.head,
      dirty: status.dirty?
    })

    status
  end

  # One broken edge must not take the other falsifiers with it (§129-§130): a
  # raise becomes UNKNOWN for that falsifier only, never a pass.
  defp guarded(%Falsifier{} = f, fun) do
    fun.()
  rescue
    exception ->
      Result.unknown(f, "raised: " <> Exception.format(:error, exception, __STACKTRACE__))
  catch
    kind, reason ->
      Result.unknown(f, "stimulus #{kind}: #{inspect(reason, limit: 20)}")
  end

  # --- real git subprocess helpers (mirrors AshA2A.Chicago.Subject's private
  # commit/2 and dirty?/1 exactly -- Subject's are module-private, so this
  # court cannot call them and instead reproduces their real-subprocess
  # shape: System.cmd against a real `git`, cd'd into the repo, output
  # captured, non-zero exit or an unreadable path recorded as nil/false
  # rather than raising) -----------------------------------------------------

  defp git(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp dirty?(path) do
    case System.cmd("git", ["status", "--porcelain", "--untracked-files=no"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) != ""
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
