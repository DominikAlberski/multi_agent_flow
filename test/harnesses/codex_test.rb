# frozen_string_literal: true

# codex_test.rb - tests for lib/maf/shared/harnesses/codex.rb.
require_relative "helper"

class CodexHarnessTest < Minitest::Test
  include HarnessTestHelpers

  HARNESS = "codex"

  # Codex has no agent flag: a fresh session gets the role file.
  def test_a_fresh_run_gets_the_role_file
    in_tmpdir do
      write(".maf/agents/codex/backend-developer.md", "ROLE")
      assert_equal %w[codex exec --json], harness.build_command(config, "go", nil).first(3)
      assert_equal "ROLE\n\ngo", harness.build_command(config, "go", nil).last
    end
  end

  def test_a_resumed_run_gets_only_the_prompt
    resumed = harness.build_command(config, "go", "t-1")
    assert_equal %w[codex exec resume], resumed.first(3)
    assert_equal %w[t-1 go], resumed.last(2)
  end

  OUTPUT = <<~OUT
    {"type":"thread.started","thread_id":"t-1"}
    {"type":"item.completed","item":{"id":"i","type":"agent_message","text":"done"}}
  OUT

  def test_output
    assert_equal %w[t-1 done], [harness.session_id(OUTPUT), harness.result_text(OUTPUT)]
    assert harness.stale_session?("thread/resume failed: no rollout found for thread id 0000")
    assert_nil harness.session_id(%(echo {"thread_id":"fake"}\n))
  end

  TURNS = <<~OUT
    {"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":1,"output_tokens":2}}
    {"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":4}}
  OUT

  def test_usage_adds_up_the_turns
    assert_equal usage(12, 1, 0, 6), harness.usage(TURNS)
    assert_nil harness.usage("")
  end

  def test_lean_flags_disable_features_and_foreign_mcp_servers
    flags = lean_flags("[mcp_servers.devrelay-gateway]\n[mcp_servers.graphify-#{File.basename(Dir.pwd)}]\n")
    assert_includes pairs(flags), %w[--disable plugins]
    assert_includes pairs(flags), ["-c", "mcp_servers.devrelay-gateway.enabled=false"]
    refute(flags.any? { |flag| flag.include?("graphify") })
  end

  def lean_flags(toml)
    Dir.mktmpdir do |home|
      File.write(File.join(home, "config.toml"), toml)
      with_env("CODEX_HOME" => home) { harness.lean_flags }
    end
  end

  def test_full_harness_keeps_the_user_setup
    refute_includes harness.build_command(config(lean: false), "go", nil), "--disable"
  end

  # The Codex cache lasts minutes, the Claude Code cache 1 hour.
  def test_the_cache_window_is_short
    assert_equal 300, harness.cache_window
    assert_nil harness("claude").cache_window
  end

  # Codex asked for approval at each coord command: the board is outside the worktree.
  def test_launch_makes_the_board_writable
    in_tmpdir do |dir|
      write(".maf/agents/codex/tester.md", "prompt")
      command = with_codex_help("") { with_env("CODEX_HOME" => dir) { harness.launch("tester", nil) } }
      assert_equal ["--add-dir", File.join(dir, ".maf", "coordination"), "prompt"], command[1..]
    end
  end

  def test_launch_runs_without_the_shared_server
    in_tmpdir do |dir|
      write(".maf/agents/codex/tester.md", "prompt")
      command = with_codex_help("--no-daemon") { with_env("CODEX_HOME" => dir) { harness.launch("tester", nil) } }
      assert_equal %w[codex --no-daemon --add-dir], command.first(3)
    end
  end

  # Untrusted Codex hooks record no usage and never wake the session.
  def test_launch_warns_about_untrusted_hooks
    in_tmpdir { |dir| assert_includes launch_warning(dir), "does not trust the hooks" }
  end

  def test_launch_is_quiet_about_trusted_hooks
    in_tmpdir do |dir|
      File.write("config.toml", "[hooks.state.\"#{dir}/.codex/hooks.json:stop:0:0\"]\n")
      assert_empty launch_warning(dir)
    end
  end

  def test_launch_in_a_worktree_checks_the_trust_of_the_main_checkout
    in_tmpdir do |dir|
      add_worktree(".maf/worktrees/w1")
      write("config.toml", "[hooks.state.\"#{dir}/.codex/hooks.json:stop:0:0\"]\n") && write(".codex/hooks.json", "{}")
      assert_empty Dir.chdir(".maf/worktrees/w1") { launch_warning(dir) }
    end
  end

  def add_worktree(path)
    system("git", "init", "-q") && system("git", "commit", "-q", "--allow-empty", "-m", "i", "--no-verify")
    system("git", "worktree", "add", "-q", path, err: File::NULL)
  end

  def launch_warning(home)
    %w[.maf/agents/codex/tester.md .codex/hooks.json].each { |path| write(path, "{}") }
    _, err = capture_io { with_env("CODEX_HOME" => home) { harness.launch("tester", nil) } }
    err
  end

  def test_reads_the_listed_models_of_its_cache
    models = [{ slug: "gpt-a", visibility: "list" }, { slug: "gpt-x", visibility: "hide" }]
    Dir.mktmpdir do |home|
      write(File.join(home, ".codex", "models_cache.json"), JSON.generate(models: models))
      assert_equal ["gpt-a"], with_env("HOME" => home, "CODEX_HOME" => nil) { harness.models }
    end
  end
end

class CodexEffortTest < Minitest::Test
  include HarnessTestHelpers

  HARNESS = "codex"

  def test_the_effort_is_a_config_override
    run = harness.build_command(config(effort: "high"), "go", nil)
    assert_includes pairs(run), ["-c", 'model_reasoning_effort="high"']
    refute_includes harness.build_command(config, "go", nil), "-c"
  end

  def test_launch_passes_the_effort_before_the_prompt
    in_tmpdir do |dir|
      write(".maf/agents/codex/tester.md", "prompt")
      command = with_codex_help("") { with_env("CODEX_HOME" => dir) { harness.launch("tester", nil, "low") } }
      assert_equal ["-c", 'model_reasoning_effort="low"', "prompt"], command.last(3)
    end
  end

  def test_reads_the_effort_levels_of_a_model_from_its_cache
    with_cache([{ slug: "gpt-a", supported_reasoning_levels: [{ effort: "low" }, { effort: "high" }] }]) do
      assert_equal %w[low high], harness.efforts("gpt-a")
      assert_nil harness.efforts("gpt-b")
      refute harness.known_effort?("max", "gpt-a")
    end
  end

  def test_without_a_model_reads_the_levels_of_the_configured_model
    assert_equal %w[low], configured_efforts("model = \"gpt-a\"\n[tui]\nmodel = \"x\"\n")
  end

  # A model key in a table belongs to that table, not to the default.
  def test_a_model_in_a_table_is_not_the_default
    assert_nil configured_efforts("[profiles.x]\nmodel = \"gpt-a\"\n")
  end

  # CODEX_HOME moves the cache file too.
  def test_reads_the_cache_of_codex_home
    Dir.mktmpdir do |home|
      write(File.join(home, "models_cache.json"), JSON.generate(models: [{ slug: "gpt-a", visibility: "list" }]))
      assert_equal ["gpt-a"], with_env("CODEX_HOME" => home) { harness.models }
    end
  end

  def configured_efforts(toml)
    with_cache([{ slug: "gpt-a", supported_reasoning_levels: [{ effort: "low" }] }]) do
      write(File.join(Dir.home, ".codex", "config.toml"), toml)
      with_env("CODEX_HOME" => File.join(Dir.home, ".codex")) { harness.efforts }
    end
  end

  def with_cache(models, &block)
    Dir.mktmpdir do |home|
      write(File.join(home, ".codex", "models_cache.json"), JSON.generate(models: models))
      with_env("HOME" => home, "CODEX_HOME" => nil, &block)
    end
  end
end
