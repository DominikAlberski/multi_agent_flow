# ADR 0007: The design of the agent sandbox

Status: accepted. Date: 2026-10-14.

## Context

A dispatched agent runs without approval prompts. The user does not watch it.
Prompt injection or a mistake can make the agent change files that run later on the host.
A later process outside the sandbox then runs the change: maf, coord, git, Taskwarrior,
the shell of the user, or a session of a harness.
So the sandbox must stop writes to each file that a process on the host runs or loads.
`docs/sandbox.md` tells the user what the sandbox does. This ADR records why the code does it.

## Decision

### Modes and the policy

- `lib/maf/shared/sandbox.rb` reads the mode from `MAF_SANDBOX` or `.maf/sandbox.json`.
  `auto` gives Seatbelt on macOS and bwrap on Linux.
- A broken policy file stops maf. Else a typo turns the sandbox off.
- maf creates the policy file before the first run. Else the agent could create it.
- The agent cannot change `.maf/sandbox.json`. So a run cannot turn off the sandbox of the next run.
- A relative path in the `write` list starts at the project root, not at the current folder.
- A worker that a lead starts runs inside the sandbox of the lead.
  So the sandbox opens the state paths of each harness of the project, not only of the lead.

### Protected paths (`Paths`)

The agent can read each protected path. It cannot change it.

| Path | Process on the host that runs or reads it |
|---|---|
| `.maf/sandbox.json` | maf reads the policy |
| `.maf/bin`, `.maf/lib` | the dispatcher, coord, and each maf script |
| `.maf/env.sh`, also in each worktree | the shell of the user puts `.maf/bin` on `PATH` |
| `.maf/coordination/harness-hooks` | the harness config runs these hooks. They load `session-guard.rb` with `require_relative`, so the reference scan cannot find it |
| `.maf/claude`, `.maf/mcp` | `maf start` and the dispatcher give these files to the harness (`--settings`, `--mcp-config`) |
| `message-hooks`, `taskrc`, `worktree-env.rb` of the board | coord runs the hooks. Taskwarrior reads the taskrc |
| `taskdata/hooks` of the board | Taskwarrior runs each script in it, also for a `task` command on the host |
| `.git/hooks`, `.git/config` | git runs the hooks. A config option (`core.fsmonitor`, `core.hooksPath`) runs a command |
| `.git/commondir`, `.maf/worktrees/*/.git`, `.git/worktrees/*/{commondir,gitdir}` | git follows these files to another git folder. In a git folder that the agent wrote, the config runs a command |
| `.git/config.worktree`, also of each worktree | git reads it when `extensions.worktreeConfig` is on |
| `config` and `hooks` of each submodule in `.git/modules` | git reads the config of a submodule, and a commit runs its hooks |
| the harness config of the project and of each worktree | a session of any harness on the host loads it |
| each file that a protected config names | the harness runs or loads it |

- The parent folders of each protected path stay in place. A rename of a parent would move the protected path away.
- A protected symlink stays in place too. Else the agent could put its own file in place of the link.
- The sandboxes compare real paths. On macOS, `/tmp` is `/private/tmp`.
- A protected file that the agent must not change also must not be written by maf in the sandbox.
  So `coord` writes `.maf/env.sh` and `maf start` writes `.codex/hooks.json` only on a change.
  The taskrc is created only when a line is missing.
  In an existing worktree, coord does not add a flow file in the sandbox.

### Harness folders: an allowlist (`HarnessFiles`)

- In the folder of a harness, the agent can write only the state paths: sessions, logs, logins, and caches.
  Each other path is config, hooks, or code that a later run outside the sandbox loads.
- On macOS, a new name in an update of the harness is protected too.
- bwrap can protect only an existing path. So on Linux, a new name stays writable, except the config names of the harness.
- maf creates a missing config path before a bwrap run (a placeholder). An empty JSON file gets `{}`.
  A Markdown or YAML file stays missing: an empty file changes what the harness loads.
- Placeholders that break a harness are not created:
  Codex `packages` (an empty folder looks like an installed app server),
  Cursor `cli-config.json` (Cursor needs a version and permissions in it),
  and Hermes `hermes-agent` (an empty folder looks like a broken install).
- Folders with programs stay protected: Codex `cache` (remote plugins), Hermes `tools`, `node`, `lsp`,
  and opencode `bin` (language servers) and `node_modules` (plugins).
- A prefix (for example `~/.claude.json`) lets Claude Code write the file and its backup files.
  bwrap binds the file, so Claude Code writes it in place.
- A harness with its own OS sandbox turns it off. Codex runs `sandbox-exec`, and it fails inside the maf sandbox.

### The reference scan (`References`)

- A config file can name a script: a hook, a status line, or an MCP command. The harness runs the script on the host.
  So each named file in an allowed path is protected.
- maf follows a chain of names up to a fixed depth, as Claude Code does for imports.
  It also follows a file that is not protected, because a protected file can name a writable one.
- In a Markdown file, maf follows only the imports (`@path`). The text of a skill often names project files,
  and the agent must still change them.
- The permission rules of Claude Code name the files that the agent can edit. They are not commands, so maf skips them.
- `$CLAUDE_PROJECT_DIR` becomes `.`, so a hook path in the project resolves.
- maf reads a named file only up to a size limit. A larger file is protected, but not read.

### Seatbelt (macOS)

- The profile denies each file write outside the allowed paths. A later rule wins, so the denials come last.
- maf runs `/usr/bin/sandbox-exec`. A `sandbox-exec` on `PATH` could be a file that the agent wrote.
- A sandbox can start inside a sandbox. The inner run gets both profiles.
- Host services (tmux, Docker, an SSH agent) listen on Unix sockets. The agent can connect only to sockets in its own folders.
  The DNS resolver socket (mDNSResponder) stays open.
- LaunchServices (`open`) and Apple Events start an app outside the sandbox, so the profile blocks them.
- The runs of one project get their own temporary folder: host services keep sockets in the shared one.
  A `TMPDIR` of another project is not used. maf checks the owner of the folder, because another user could create it first.
- Tools of the host load code from `~/.cache` and `~/Library/Caches`. So the agent gets its own `XDG_CACHE_HOME`.

### bwrap (Linux)

- bwrap mounts the file system read-only and binds each allowed path read-write.
- The home folder gets a temporary overlay (bubblewrap 0.10 or later). Claude Code writes a temporary file there.
  Other writes there succeed, but they are lost after the run.
- In a harness folder, each existing path that is not state is bound read-only.
- `/tmp` and `/dev/shm` are private: host services keep sockets and shared memory there.
- The sockets of systemd, D-Bus, and Docker are masked. A service could start a process outside the sandbox.
  A bind in or above a masked path (for example a `TMPDIR` in `/run/user`) is skipped.
- A parent of a protected path is bound onto itself only inside a writable bind.
  A parent bind in the private `/tmp` would open the host `/tmp` again.
- maf does not take `bwrap` from a folder that the agent can write.
- bubblewrap cannot start inside bubblewrap. The sandbox sets `MAF_BWRAP=1`, and a nested run keeps the sandbox of the lead.
  A host can have its own overlay on the home folder, so the overlay alone is not a marker.
- A bind follows a symlink to its target. So `Links` records each protected link before a run and puts it back after the run.

### Terminal and session

- A process can push input into its terminal (TIOCSTI). The sandbox cannot stop that.
  The shell of the user would run the input after the harness stops.
- A dispatched run, the verify command, and the analyst command start in a new session without a terminal.
  maf waits until the child leads its session, so a stop reaches the whole process group.
- An interactive `maf start` in the sandbox runs the harness on its own pseudo terminal (`PtyRelay`).
  The relay passes TERM, HUP, and INT to the harness and waits for it.
  At the end of the input, the relay sends ^D, else `echo task | maf start` waits.

### Commands from agent-writable files

- The dispatcher runs `coord` of the main checkout. The agent can change the copy in its worktree.
- The `verify` and `analyst` commands come from `.maf/config.json`. The agent can change that file, so the commands run in the sandbox.

### Records of an older maf

- A presence record of an older maf has no start time. Without it, maf cannot tell an old pid from a new process with the same pid.
- Such a record counts as live while its heartbeat is recent. So `maf start` does not start a second dispatcher.
- maf signals a pid only when the start time matches, or when `ps` shows `.maf/bin/dispatcher` with its cwd in the worktree.
  A run can take longer than the heartbeat window.
- Else `maf retire` and `maf worker restart` stop and show the `kill` command. A retired dispatcher could claim the released tasks.

### The VM (`maf vm`)

- The VM mounts only the project folder, at the same path as on the host. The worktrees and the taskrc hold absolute paths.
- The VM installs the maf version of the host. A newer maf could need a newer flow than the project has.
  A local gem file goes into `.maf/vm/`, because the VM sees only the project.
- The VM installs Taskwarrior 3, the same major version as the host: Taskwarrior 2 and 3 store the board in different files.
  Taskwarrior 3.5 needs Rust 1.91.1, so the VM uses Ubuntu 26.04 (Lima 2.2.0 or later).
- Lima runs each provision script on each boot, so a script skips an installed CLI.
- maf copies a login into the VM only after the user agrees. Uninstall keeps the VM, because it holds a copy of the logins.
- Two projects with the same folder name get different VMs: the name ends with a hash of the path.

## Consequences

- Code comments do not repeat these reasons. A change to a mechanism updates this ADR.
- The sandbox stops writes, not reads or network access. `docs/sandbox.md` lists the limits.
- On Linux, the sandbox stops mistakes, not a deliberate break-out. For a strict wall, use `maf vm`.
