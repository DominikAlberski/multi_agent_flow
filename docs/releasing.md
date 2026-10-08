# Releasing the maf gem

The gem is `maf` on rubygems.org: https://rubygems.org/gems/maf

A version tag `vX.Y.Z` on `main` publishes the gem. The workflow
`.github/workflows/release.yml` does the work. No API key is stored:
RubyGems trusted publishing accepts a short-lived token from GitHub.

## Release a new version

1. Make a branch from `main`.
2. Change the version in `lib/maf/version.rb`:

   ```ruby
   VERSION = "0.2.0"
   ```

3. Add an entry to `CHANGELOG.md`. Move the lines under `## [Unreleased]` into
   the new entry:

   ```markdown
   ## [0.2.0] - 2026-11-01

   - What changed for the user.
   ```

4. Run the checks and the tests: `bundle exec rake`.
5. Commit, push, open a PR, and merge it into `main`.
6. Tag the merge commit on `main` and push the tag:

   ```sh
   git checkout main && git pull
   git tag -a v0.2.0 -m "maf 0.2.0"
   git push origin v0.2.0
   ```

7. Watch the release run: `gh run list --workflow release.yml`, or the
   Actions tab on GitHub. If the `release` environment needs an approval,
   approve the run on GitHub.
8. Check the result: `gem search -e maf -r` shows the new version.

The tag must be `v` plus the value of `Maf::VERSION`. If the tag and the
version differ, the workflow stops before it publishes.

## Choose the version number

- Patch (`0.1.0` → `0.1.1`): a bug fix only.
- Minor (`0.1.0` → `0.2.0`): a new command, option, or role. Also a change
  that needs `maf update` in each project.
- Major (`0.x` → `1.0.0`): a change that breaks existing projects or commands.

## Upgrade a project after a release

```sh
gem update maf
cd ~/Projects/my-app && maf update
```

`maf update` replaces the flow files in `.maf/` with the files of the new version.

## One-time setup

Do these steps once. Version 0.1.0 needed none of them: it was published by hand.

1. On rubygems.org, open maf, then Trusted publishers. Add a GitHub Actions
   publisher:
   - owner: `DominikAlberski`
   - repository: `multi_agent_flow`
   - workflow file: `release.yml`
   - environment: `release`
2. Optional: on GitHub, open Settings, then Environments, then `release`. Add
   yourself as a required reviewer. Then a tag does not publish without your
   approval.

## If the release workflow fails

- If the tag check fails, the tag does not match `Maf::VERSION`. Delete the
  tag, fix the version or the tag, and push the tag again:

  ```sh
  git tag -d v0.2.0 && git push origin :refs/tags/v0.2.0
  ```

- If the publish step fails with an authentication error, check the trusted
  publisher on rubygems.org. The workflow file and the environment name must
  match exactly.
- If the tests fail, fix the code on a new branch, merge it, delete the tag,
  and tag the new merge commit.
- rubygems.org never accepts the same version twice. If a broken version is
  published, release a new patch version. `gem yank maf -v X.Y.Z` hides a
  broken version, but the number stays used.

## Publish by hand

Use this only if GitHub Actions is not available.
RubyGems asks for your email, your password, and an MFA code.

```sh
git checkout main && git pull
bundle exec rake               # checks, lint, tests
gem build maf.gemspec
gem push maf-X.Y.Z.gem
git tag -a vX.Y.Z -m "maf X.Y.Z"
git push origin vX.Y.Z
```

The pushed tag starts `release.yml`. The publish step then fails, because the
version exists on rubygems.org. This failure is expected and does no harm.
