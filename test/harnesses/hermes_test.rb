# frozen_string_literal: true

# hermes_test.rb - tests for lib/maf/shared/harnesses/hermes.rb.
require_relative "helper"

class HermesHarnessTest < Minitest::Test
  include HarnessTestHelpers

  HARNESS = "hermes"

  def full_command = in_tmpdir { harness.build_command(config(skill: "p-dev", model: "m", max_turns: 50), "go", "s-1") }

  def test_a_run_starts_hermes_in_one_shot_mode
    assert_equal %w[hermes chat --oneshot --yolo --format stream-json -Q], full_command.first(7)
    assert_equal %w[-q go], full_command.last(2)
  end

  def test_a_run_preloads_the_skill_and_resumes_the_session
    cmd = full_command
    expected = [%w[--skills p-dev], %w[--model m], %w[--resume s-1]]
    assert_equal expected, pairs(cmd) & expected
  end

  # Regression: the stream-json gateway of Hermes 0.22 refuses --run-budget, so each run failed.
  def test_the_command_has_no_run_budget
    refute_includes full_command, "--run-budget"
  end

  def test_build_command_without_skill_or_session
    cmd = in_tmpdir { harness.build_command(config(max_turns: 50), "go", nil) }
    refute_includes cmd, "--skills"
    refute_includes cmd, "--resume"
  end

  # The Hermes defaults live here, not in the dispatcher.
  def test_prepare_sets_the_max_turns_and_drops_a_skill_on_no_skill
    prepared = in_tmpdir { harness.prepare(config(skill: "s", no_skill: true)) }
    assert_equal 50, prepared.max_turns
    assert_nil prepared.skill
  end

  # Shapes taken from hermes_cli/stream_json.py and a real `--resume bogus` run.
  OUTPUT = <<~OUT
    {"type": "system", "subtype": "init", "session_id": ""}
    {"type": "text", "text": "partial"}
    {"type": "result", "session_id": "s-42", "exit_code": 0, "text": "all done"}
  OUT

  def test_parses_session_id_and_text_from_the_result_event
    assert_equal ["s-42", "all done"], [harness.session_id(OUTPUT), harness.result_text(OUTPUT)]
  end

  # Regression: an agent that echoed a prompt or a note could supply a false session ID.
  ECHOED = <<~OUT
    tool output: {"session_id": "fake"}
    {"type": "result", "session_id": "real", "text": "done"}
    stderr: "session_id": "fake2"
  OUT

  def test_echoed_text_cannot_supply_a_session_id
    assert_equal "real", harness.session_id(ECHOED)
    assert_nil harness.session_id(%({"type": "result", "session_id": ""}\n))
  end

  def test_parse_tolerates_garbage
    assert_nil harness.session_id("not json\n{broken")
    assert_nil harness.result_text("")
  end

  def test_detects_a_stale_session
    assert harness.stale_session?("Session not found: bogus\nUse a session ID from a previous CLI run")
    refute harness.stale_session?("rate limited")
  end

  def test_usage_comes_from_the_result_event
    output = %({"type":"result","session_id":"s","usage":{"prompt_tokens":8,"completion_tokens":2}}\n)
    assert_equal usage(8, 0, 0, 2), harness.usage(output)
  end

  MANIFEST = { "agents" => [{ "harness" => "hermes", "role" => "reviewer", "can_edit" => false },
                            { "harness" => "hermes", "role" => "tester", "can_edit" => true }] }.freeze

  def command_of(role) = in_project(MANIFEST) { harness.build_command(config(role: role, max_turns: 5), "go", nil) }

  def toolsets(role) = pairs(command_of(role)).find { |flag, _| flag == "-t" }.last.split(",")

  # Regression: with -t, a read-only role lost the graph server. coord is the board, and maf starts the workers.
  def test_each_role_gets_its_toolsets_the_graph_server_and_no_kanban
    reviewer, tester = %w[reviewer tester].map { |role| toolsets(role) }
    assert_equal([false, true], [reviewer, tester].map { |list| list.include?("file") })
    [reviewer, tester].each { |list| assert_equal 1, list.grep(/\Amcp-graphify-./).size }
    assert_empty (reviewer + tester) & %w[kanban delegation cronjob computer_use]
  end

  # A lead role owns no task. Its launch prompt must not tell it to claim one.
  def test_launch_prompt_of_a_lead_role_forbids_a_claim
    prompt = in_tmpdir { harness.launch("project-manager", nil).last }
    assert_includes prompt, "Never claim a task"
    assert_includes prompt, "coord inbox --wait"
    assert_includes in_tmpdir { harness.launch("tester", nil).last }, "Claim a task"
  end

  # The skill name uses the main checkout's name, from the root and from a worktree alike.
  def test_skill_name_is_the_same_in_root_and_worktree
    in_project({}) do |root|
      system("git", "worktree", "add", "-q", "-b", "w", ".maf/worktrees/t-1", exception: true, err: File::NULL)
      assert_equal "#{File.basename(root)}-tester", harness.skill_name("tester")
      Dir.chdir(".maf/worktrees/t-1") { assert_equal "#{File.basename(root)}-tester", harness.skill_name("tester") }
    end
  end

  # maf add records a custom --hermes-dir in the manifest. The launcher looks for the skill there.
  def test_skill_dir_comes_from_the_manifest
    in_project({}) do |root|
      File.write(".maf/config.json", JSON.generate("hermes_dir" => File.join(root, "skills")))
      write(File.join("skills", "#{File.basename(root)}-tester", "SKILL.md"), "x")
      assert_equal "#{File.basename(root)}-tester", harness.skill("tester")
    end
  end

  def test_role_files_live_outside_the_project
    assert_nil harness.role_path("tester")
    assert_equal "/s/proj-tester/SKILL.md", harness.role_destination("/x/proj", "tester", "hermes_dir" => "/s")
  end

  def in_project(manifest)
    in_tmpdir do |root|
      git_init
      write(".maf/config.json", JSON.generate(manifest))
      yield root
    end
  end

  def git_init
    system("git", "init", "-q", exception: true)
    system("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "i",
           exception: true)
  end
end

class HermesEffortTest < Minitest::Test
  include HarnessTestHelpers

  HARNESS = "hermes"

  def test_the_effort_is_the_reasoning_level
    run = harness.build_command(harness.prepare(config(effort: "ultra")), "go", nil)
    assert_includes pairs(run), ["--reasoning", "ultra"]
    assert_includes pairs(in_tmpdir { harness.launch("tester", nil, "low") }), ["--reasoning", "low"]
    assert harness.known_effort?("none")
  end
end
