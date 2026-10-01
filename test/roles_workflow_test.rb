#!/usr/bin/env ruby
# frozen_string_literal: true

# test/roles_workflow_test.rb - tests for project roles (.maf/roles.yml) and
# the workflow fragment (.maf/workflow.md).
#
# Run: ruby test/roles_workflow_test.rb
#
# The tests run bin/maf as a subprocess in a disposable project directory.
require "minitest/autorun"
require_relative "board_guard"
require "tmpdir"
require "fileutils"
require "yaml"
require "rbconfig"

MAF = File.expand_path("../bin/maf", __dir__)

class RolesWorkflowTestCase < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("maf-roles-test"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def maf(*args)
    env = { "VAULT_SKIP" => "1", "TASKRC" => nil, "COORD_DIR" => nil, "COORD_ROLE" => nil, "COORD_WORKER" => nil }
    output = IO.popen(env, [RbConfig.ruby, MAF, *args], chdir: @dir, err: [:child, :out], &:read)
    [output, $?.exitstatus]
  end

  def path(*parts) = File.join(@dir, *parts)

  def write(rel, content)
    FileUtils.mkdir_p(File.dirname(path(rel)))
    File.write(path(rel), content)
  end

  def role_file(role) = File.read(path(".maf", "agents", "opencode", "#{role}.md"))
end

class ProjectRolesTest < RolesWorkflowTestCase
  def test_role_add_writes_a_stub_with_the_four_duty_parts
    out, status = maf("role", "add", "data-engineer")

    assert_equal 0, status, out
    role = YAML.load_file(path(".maf", "roles.yml")).fetch("roles").fetch("data-engineer")
    %w[Focus: Checks: Done\ when: Avoid:].each { |part| assert_includes role.fetch("duties"), part }
  end

  def test_role_add_is_idempotent
    maf("role", "add", "data-engineer")
    before = File.read(path(".maf", "roles.yml"))

    out, status = maf("role", "add", "data-engineer")

    assert_equal 0, status, out
    assert_includes out, "exists"
    assert_equal before, File.read(path(".maf", "roles.yml"))
  end

  def test_role_add_keeps_the_other_project_roles
    maf("role", "add", "data-engineer")
    maf("role", "add", "designer")

    roles = YAML.load_file(path(".maf", "roles.yml")).fetch("roles")

    assert_equal %w[data-engineer designer], roles.keys
  end

  def test_role_add_refuses_a_bad_name
    _, status = maf("role", "add", "Bad Name")

    refute_equal 0, status
    refute File.exist?(path(".maf", "roles.yml"))
  end

  def test_roles_marks_the_source_of_each_role
    maf("role", "add", "data-engineer")

    out, status = maf("roles")

    assert_equal 0, status, out
    assert_includes out, "architect (built-in)"
    assert_includes out, "data-engineer (project)"
  end

  def test_a_project_role_replaces_a_built_in_role
    write(".maf/roles.yml", <<~YML)
      roles:
        tester:
          title: Strict Tester
          description: Runs the strict suite.
          duties: "Focus: strict."
    YML

    out, status = maf("add", "opencode:tester", "--no-bootstrap")

    assert_equal 0, status, out
    assert_includes role_file("tester"), "Strict Tester"
    assert_includes maf("roles").first, "tester (project)"
  end

  def test_add_accepts_a_project_role
    maf("role", "add", "data-engineer")

    out, status = maf("add", "opencode:data-engineer", "--no-bootstrap")

    assert_equal 0, status, out
    assert_includes role_file("data-engineer"), "You are the Data Engineer"
  end

  def test_add_refuses_an_unknown_role
    _, status = maf("add", "opencode:nobody", "--no-bootstrap")

    refute_equal 0, status
  end
end

class WorkflowTest < RolesWorkflowTestCase
  STAGES = "Stage 1. Write the plan.\nStage 2. Create one spec task for the tester.\n"

  def add_team
    out, status = maf("add", "opencode:architect", "opencode:tester", "--no-bootstrap")
    assert_equal 0, status, out
  end

  def test_the_workflow_goes_into_the_architect_prompt_only
    write(".maf/workflow.md", STAGES)

    add_team

    assert_includes role_file("architect"), "Workflow:\n  Stage 1. Write the plan."
    refute_includes role_file("tester"), "Stage 1."
  end

  def test_without_a_workflow_the_architect_prompt_has_no_workflow_heading
    add_team

    refute_includes role_file("architect"), "Workflow:"
  end

  def test_an_empty_workflow_changes_nothing
    write(".maf/workflow.md", "\n")

    add_team

    refute_includes role_file("architect"), "Workflow:"
  end

  def test_update_applies_a_changed_workflow
    add_team
    write(".maf/workflow.md", STAGES)

    out, status = maf("update", "--no-bootstrap")

    assert_equal 0, status, out
    assert_includes role_file("architect"), "Stage 2."
  end
end

class HandoffRulesTest < RolesWorkflowTestCase
  def test_the_architect_prompt_holds_the_artifact_and_sequencing_rules
    maf("add", "opencode:architect", "--no-bootstrap")

    assert_includes role_file("architect"), "$COORD_DIR/artifacts/<goal>/<name>.md"
    assert_includes role_file("architect"), "Do not create the task of the next stage"
  end

  def test_the_contract_holds_the_artifact_rules
    contract = File.read(File.expand_path("../assets/agents-contract.md", __dir__))

    assert_includes contract, "### Handoff artifacts"
    assert_includes contract, "Never write an artifact inside a worktree."
  end
end

class DefaultWorkflowTest < RolesWorkflowTestCase
  NAMES = %w[simple plan-review tdd].freeze

  def source(name) = File.expand_path("../templates/workflows/#{name}.md", __dir__)

  def test_each_default_workflow_starts_with_stage_1_and_has_short_sentences
    NAMES.each do |name|
      text = File.read(source(name))

      assert text.start_with?("Stage 1."), name
      text.split(/(?<=[.?!])\s+/).each { |sentence| assert_operator sentence.split.size, :<=, 20, sentence }
    end
  end

  def test_each_default_workflow_reaches_the_architect_prompt
    NAMES.each do |name|
      write(".maf/workflow.md", File.read(source(name)))
      out, status = maf("add", "opencode:architect", "--no-bootstrap")

      assert_equal 0, status, out
      assert_includes role_file("architect"), "Workflow:\n  Stage 1."
    end
  end
end

class UninstallKeepsUserFilesTest < RolesWorkflowTestCase
  def test_uninstall_keeps_the_roles_and_the_workflow_files
    maf("role", "add", "data-engineer")
    write(".maf/workflow.md", "Stage 1. Work.\n")
    maf("add", "opencode:architect", "--no-bootstrap")

    out, status = maf("uninstall", "--yes")

    assert_equal 0, status, out
    assert File.exist?(path(".maf", "roles.yml"))
    assert File.exist?(path(".maf", "workflow.md"))
  end
end

class DomainDocsPromptTest < RolesWorkflowTestCase
  def setup
    super
    out, status = maf("add", "opencode:project-manager", "opencode:architect", "opencode:reviewer", "opencode:tester", "--no-bootstrap")
    assert_equal 0, status, out
  end

  def test_the_project_manager_runs_a_round_based_interview
    text = role_file("project-manager")

    assert_includes text, "Interview the user in rounds"
    assert_includes text, "Ask the whole frontier in one round"
    assert_includes text, "The interview ends when the frontier is empty."
    refute_includes text, "If two readings of the request lead to different work, ask the user first."
  end

  def test_the_project_manager_writes_terms_to_the_draft_and_never_commits
    text = role_file("project-manager")

    assert_includes text, "$COORD_DIR/artifacts/<goal>/glossary-draft.md"
    assert_includes text, "Never commit: the architect owns the committed `GLOSSARY.md`"
  end

  def test_the_architect_owns_the_glossary_and_the_adr_gates
    text = role_file("architect")

    assert_includes text, "Own the committed `GLOSSARY.md`"
    assert_includes text, "hard to reverse, it is surprising without context"
    refute_includes text, "ADRs for small choices"
  end

  def test_the_reviewer_checks_the_vocabulary
    assert_includes role_file("reviewer"), "one meaning per term, no implementation detail"
  end

  def test_other_roles_do_not_get_the_glossary_rules
    refute_includes role_file("tester"), "glossary-draft"
  end

  def test_the_contract_holds_the_domain_documentation_rules
    contract = File.read(File.expand_path("../assets/agents-contract.md", __dir__))

    assert_includes contract, "### Domain documentation"
    assert_includes contract, "The file does not exist until the first term resolves."
    assert_includes contract, "Two goals that add terms conflict at merge time."
  end

  def test_no_skill_text_or_dependency_is_shipped
    files = Dir.glob(File.expand_path("../{assets,templates,lib}/**/*", __dir__)).select { |f| File.file?(f) }

    assert_empty files.select { |f| File.read(f).match?(/grill-with-docs|domain-modeling/) }
  end
end
