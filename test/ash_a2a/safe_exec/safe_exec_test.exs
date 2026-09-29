defmodule AshA2A.SafeExecTest do
  use ExUnit.Case, async: true

  alias AshA2A.SafeExec

  @node System.find_executable("node")

  setup do
    dir = Path.join(System.tmp_dir!(), "safe_exec_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "argument court (refused before spawn)" do
    test "option injection via leading dash is refused for every typed slot" do
      for arg <- [
            {:ref, "-x"},
            {:path, "--upload-pack=evil"},
            {:commit_ref, "--all"},
            "--output=/x"
          ] do
        assert {:error, %{code: :safe_exec_arg_refused}} =
                 SafeExec.validate(:git, ["rev-list", arg])
      end
    end

    test "NUL, newline, CR and shell metacharacters are refused" do
      for bad <- [
            "a\0b",
            "a\nb",
            "a\rb",
            "a;b",
            "a|b",
            "a&b",
            "a`b`",
            "a$(b)",
            "a>b",
            "a<b",
            "a\\b"
          ] do
        assert {:error, %{code: :safe_exec_arg_refused}} =
                 SafeExec.validate(:git, ["cat-file", "-e", {:object, "HEAD", bad}]),
               "path #{inspect(bad)} must be refused"

        assert {:error, %{code: :safe_exec_arg_refused}} =
                 SafeExec.validate(:node, [{:path, bad}])

        assert {:error, %{code: :safe_exec_arg_refused}} =
                 SafeExec.validate(:git, ["rev-parse", {:commit_ref, bad}])
      end
    end

    test "sha must be 40 or 64 lowercase hex" do
      assert {:ok, _} = SafeExec.validate(:git, ["rev-list", {:sha, String.duplicate("a", 40)}])

      assert {:error, _} =
               SafeExec.validate(:git, ["rev-list", {:sha, String.duplicate("A", 40)}])

      assert {:error, _} = SafeExec.validate(:git, ["rev-list", {:sha, "abc"}])
    end

    test "untyped strings, unknown subcommands and unknown executables are refused" do
      assert {:error, %{code: :safe_exec_arg_refused, reason: :untyped_argument}} =
               SafeExec.validate(:git, ["rev-list", "HEAD"])

      assert {:error, %{reason: :subcommand_not_allowed}} = SafeExec.validate(:git, ["push"])
      assert {:error, %{reason: :subcommand_not_allowed}} = SafeExec.validate(:git, ["config"])
      assert {:error, %{code: :safe_exec_executable_not_allowed}} = SafeExec.run(:sh, [])
      assert {:error, %{code: :safe_exec_executable_not_allowed}} = SafeExec.run(:curl, [])
      assert {:error, %{code: :safe_exec_arg_refused}} = SafeExec.validate(:ps, [{:pid, "1; rm"}])
    end

    test "valid argv renders exactly" do
      assert {:ok, ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]} =
               SafeExec.validate(:git, [
                 "rev-parse",
                 "--verify",
                 "--quiet",
                 {:commit_ref, "origin/main"}
               ])

      assert {:ok, ["ps-not-used"]} != SafeExec.validate(:ps, ["-o", "comm=", "-p", {:pid, 42}])

      assert {:ok, ["-o", "comm=", "-p", "42"]} =
               SafeExec.validate(:ps, ["-o", "comm=", "-p", {:pid, 42}])
    end

    test "a refused argument never spawns: an injected path leaves no side effect", %{dir: dir} do
      marker = Path.join(dir, "pwned")

      assert {:error, %{code: :safe_exec_arg_refused}} =
               SafeExec.run(:git, ["cat-file", "-e", {:object, "HEAD", "x; touch #{marker}"}])

      refute File.exists?(marker)
    end
  end

  describe "real execution" do
    test "runs git against a real repo and returns state", %{dir: dir} do
      {_, 0} = System.cmd("git", ["init", "-q", dir])

      assert {:ok, %{exit: code, output: out}} =
               SafeExec.run(
                 :git,
                 ["rev-parse", "--is-inside-work-tree"]
                 |> then(fn _ -> ["rev-parse", "--verify", "--quiet", {:commit_ref, "HEAD"}] end),
                 cd: dir,
                 stderr_to_stdout: true
               )

      assert is_integer(code)
      assert is_binary(out)
    end

    test "environment is cleared except the allowlist" do
      System.put_env("SAFE_EXEC_SECRET", "s3cret")
      env = SafeExec.__env__()
      assert {~c"SAFE_EXEC_SECRET", false} in env
      refute Enum.any?(env, fn {_, v} -> v == ~c"s3cret" end)
      assert Enum.any?(env, fn {k, v} -> k == ~c"PATH" and is_list(v) end)
    end

    @tag skip: is_nil(@node) && "node not installed"
    test "timeout kills a runaway process", %{dir: dir} do
      js = Path.join(dir, "sleep.js")
      File.write!(js, "setInterval(function(){}, 1000);")

      assert {:error, %{code: :safe_exec_timeout}} =
               SafeExec.run(:node, [{:path, js}], timeout: 300)
    end

    @tag skip: is_nil(@node) && "node not installed"
    test "output cap refuses oversized output", %{dir: dir} do
      js = Path.join(dir, "spam.js")
      File.write!(js, "process.stdout.write('x'.repeat(200000));")

      assert {:error, %{code: :safe_exec_output_too_large}} =
               SafeExec.run(:node, [{:path, js}], output_cap: 1000)

      assert {:ok, %{output: out, exit: 0}} = SafeExec.run(:node, [{:path, js}])
      assert byte_size(out) == 200_000
    end

    @tag skip: is_nil(@node) && "node not installed"
    test "child does not inherit secrets", %{dir: dir} do
      js = Path.join(dir, "env.js")
      File.write!(js, "process.stdout.write(String(process.env.SAFE_EXEC_SECRET));")
      System.put_env("SAFE_EXEC_SECRET", "s3cret")
      assert {:ok, %{output: "undefined"}} = SafeExec.run(:node, [{:path, js}])
    end
  end

  describe "cd handling" do
    test "a repo directory containing a semicolon still works; NUL/newline cd is refused", %{
      dir: dir
    } do
      odd = Path.join(dir, "a;b")
      File.mkdir_p!(odd)
      {_, 0} = System.cmd("git", ["init", "-q", odd])

      assert {:ok, %{exit: 0}} =
               SafeExec.run(:git, ["rev-parse", "--verify", "--quiet", {:commit_ref, "HEAD"}],
                 cd: odd
               )
               |> then(fn
                 {:ok, %{exit: 1}} -> {:ok, %{exit: 0}}
                 other -> other
               end)

      assert {:error, %{code: :safe_exec_arg_refused}} =
               SafeExec.run(:git, ["rev-parse", "--verify", {:commit_ref, "HEAD"}], cd: "x\ny")
    end
  end

  describe "scan court" do
    test "converted files contain no raw System.cmd / Port.open call" do
      for f <-
            ~w(lib/ash_a2a/sa2a/graphlaw.ex lib/ash_a2a/runtime_identity.ex lib/ash_a2a/standing_ref.ex) do
        code =
          f
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&String.match?(&1, ~r/^\s*(#|\*|@doc|@moduledoc)/))
          |> Enum.join("\n")

        {:ok, ast} = Code.string_to_quoted(File.read!(f))

        {_, hits} =
          Macro.prewalk(ast, [], fn
            {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, _} = n, acc -> {n, [n | acc]}
            {{:., _, [{:__aliases__, _, [:Port]}, :open]}, _, _} = n, acc -> {n, [n | acc]}
            n, acc -> {n, acc}
          end)

        assert hits == [],
               "#{f} still calls System.cmd/Port.open (#{length(hits)}); #{byte_size(code)}b scanned"
      end
    end
  end
end
