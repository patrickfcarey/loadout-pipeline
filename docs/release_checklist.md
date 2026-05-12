# Release checklist

The end-to-end procedure for cutting a tagged release of `loadout-pipeline`.
Walk through every section in order. Skip nothing — even items that look
trivial today have caught a real regression at least once.

The **scope** of a single pass through this document is one tag. A patch
release (`v1.0.1`) and a minor release (`v1.1.0`) both run the full list;
the only thing that changes is which CHANGELOG section you write.

> **Cutting v1.0.0?** This is the first time the document is being used in
> anger. Pay extra attention to anything labelled "first release only" —
> the steps that establish baselines (assertion count, frozen-interface
> diff fixtures, OAT table) only happen once.

## 0. Authorisation and scope

- [ ] You are the named release manager for this tag (or have explicit
      written authorisation from one).
- [ ] You have decided the version number and which branch is being
      promoted. The default flow is `origin/dev` → `origin/main` → tag.
- [ ] You have checked there is no in-flight work on `dev` you would be
      unwilling to ship as part of this tag — everything currently on the
      branch goes out together.

## 1. Pre-flight: clean working tree

- [ ] `git status` reports a clean tree on the branch you intend to
      release from. No untracked files. No staged but uncommitted
      changes. If anything is dirty, stash or land it first.
- [ ] `git fetch --all --tags` and confirm your local `dev` and `main`
      track their remotes one-to-one.
- [ ] No outstanding pre-commit hook failures from the most recent
      commit.

## 2. Tests — source tree

Run from the repo root.

- [ ] `bash test/fixtures/create_fixtures.sh` — regenerates the synthetic
      `.7z` fixtures the unit suite needs. Idempotent.
- [ ] `bash test/run_tests.sh` — full unit suite.
  - [ ] Exit code 0 (or, if the `Ultimate Board Game Collection (USA).7z`
        real archive is not on disk, exit code 1 with **only** Test 21
        failing — that fixture is documented as a hard-fail-when-absent
        guard against silently skipping the real-archive path).
  - [ ] Total assertion count **≥ 508**. The number is allowed to grow;
        a drop is a regression that means a pinned behaviour was
        silently removed. Investigate before continuing.
- [ ] `bash test/validate_tests.sh` — mutation validation suite. All
      ≥61 V-checks pass (the baseline grows as suites grow; treat any
      drop as a regression).
- [ ] `bash test/integration/launch.sh` — Docker integration suite.
      Requires Docker. Stub-adapter scenarios are expected to land their
      payloads now that `ftp` and `rclone` are real implementations; if
      any suite fails, fix it before the tag.

## 3. Tests — bundle parity

The single-file bundle must behave identically to the source tree.

- [ ] `bash build/bundle.sh` — builds `dist/loadout-pipeline.sh`.
- [ ] `PIPELINE="$PWD/dist/loadout-pipeline.sh" bash test/run_tests.sh`
      — re-runs the unit suite against the bundle. Same exit-code and
      assertion-count expectations as section 2.
- [ ] Diff the operator-visible log lines between a source-tree run and
      a bundle run for the canonical lvol jobs file:
      ```bash
      LVOL_MOUNT_POINT=/tmp/rel_src bash bin/loadout-pipeline.sh examples/lvol.jobs > /tmp/rel_src.log 2>&1
      LVOL_MOUNT_POINT=/tmp/rel_bun bash dist/loadout-pipeline.sh examples/lvol.jobs > /tmp/rel_bun.log 2>&1
      diff <(grep -oE '^\[(pipeline|extract|lvol|skip)\]' /tmp/rel_src.log) \
           <(grep -oE '^\[(pipeline|extract|lvol|skip)\]' /tmp/rel_bun.log)
      ```
      Output must be empty (identical log-line skeletons).

## 4. Tests — Docker parity

- [ ] `docker build -t loadout-pipeline:rc .` succeeds.
- [ ] `docker run --rm loadout-pipeline:rc /isos/example.jobs` (with the
      conventional bind-mounts from `README.md` Docker section) produces
      the same `[pipeline]` / `[extract]` skeleton as section 3.

## 5. Operator acceptance test (OAT)

- [ ] Run the per-adapter walkthrough in
      [`docs/operator_acceptance.md`](operator_acceptance.md) for every
      adapter this tag ships an implementation of. Cross-cutting
      sections (`OAT-CROSS-1` through `OAT-CROSS-7`) must all pass.
- [ ] Paste the completed sign-off table (every applicable row green)
      into the release-cut PR description. Use the sign-off table at the
      bottom of the OAT doc verbatim — do not paraphrase IDs.
- [ ] If any row is "N/A," write **why** in the Notes column. Empty
      Notes for an N/A row is a blocker.

## 6. Backwards-compatibility audit

The frozen-interface policy in
[`ai_agent_entry_point.md`](../ai_agent_entry_point.md) lists what may
not be renamed, removed, or have its meaning silently altered. For the
tag being cut:

- [ ] Diff the env-var defaults declared in `lib/config.sh` against the
      previous tag (`git diff <prev_tag>..HEAD -- lib/config.sh`). Any
      removed name or changed default is a major-version-only change.
- [ ] Diff `bin/loadout-pipeline.sh`'s positional-argument handling
      against the previous tag — the dual file/profile-directory
      semantic is frozen.
- [ ] Diff `lib/jobs.sh` regex (the job-line grammar) against the
      previous tag. Field 1–3 grammar is frozen; only `(\|field)*`
      *appended* fields are allowed.
- [ ] Diff the adapter-script signatures (`adapters/*.sh` argv
      handling) — every adapter must still take exactly `<src> <dest>`.
- [ ] If any of the above diffs are non-empty, classify each diff:
      addition (allowed), removal/rename (block until major-version
      decision is made), or behaviour change (must be called out in
      CHANGELOG and matched by an updated test pin).

**First release only:** capture today's frozen-interface state as the
baseline by appending the `git diff` outputs to the PR description for
v1.0.0. Future releases compare against that baseline.

## 7. Version bump

`loadout-pipeline` does not yet carry a runtime `VERSION` constant or a
`VERSION` file. For this tag:

- [ ] Decide the canonical place to record the version. The two real
      options are:
  1. A top-level `VERSION` text file containing the bare version
     string (`1.0.0\n`). `build/bundle.sh` `cat`s it into the dist
     header. `bin/loadout-pipeline.sh` reads it to populate
     `LOADOUT_PIPELINE_VERSION`.
  2. A `LOADOUT_PIPELINE_VERSION` constant in `lib/config.sh` exported
     alongside the other defaults. The bundle picks it up for free
     because it inlines `lib/`.
- [ ] Pick one and apply. Whichever path you take is now permanent —
      moving the version constant after v1.0.0 is itself a breaking
      change for anyone parsing it.
- [ ] Make `bin/loadout-pipeline.sh --version` (or equivalent
      env-dump) print the version string. Add a regression assertion in
      `test/suites/01_prerequisites.sh` that the output equals
      `cat VERSION` (or the constant).

**First release only:** the v1.0.0 PR is where this gets set up. Later
releases just bump the value.

## 8. CHANGELOG

- [ ] If `CHANGELOG.md` does not exist yet (it does not as of v1.0.0),
      create it at the repo root using the
      [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
- [ ] Add an entry for the tag being cut. Sections:
      `### Added`, `### Changed`, `### Fixed`, `### Removed`,
      `### Security`, `### Deprecated`. Drop empty sections.
- [ ] For v1.0.0 specifically: note the public-interface freeze in the
      `### Added` section ("All env vars in `lib/config.sh`, the
      `~src|adapter|dest~` job grammar, the `<jobs_or_profile>` CLI
      shape, the strip-list format, and the `<src> <dest>` adapter
      contract are now stable across future minor releases").
- [ ] Cross-link to PR numbers, CVE IDs, or issue numbers where
      applicable.
- [ ] Spell-check the entry. The CHANGELOG is the highest-readership
      doc in the repo on release day.

## 9. Documentation pass

- [ ] `README.md` — version references (Quickstart screenshots,
      adapter table) match the tag.
- [ ] `ai_agent_entry_point.md` — frozen-interface section's assertion
      baseline matches today's count from section 2.
- [ ] `docs/architecture.md` — diagrams reflect any new subsystem
      added in this tag.
- [ ] `docs/operator_acceptance.md` — sign-off table covers every
      adapter and cross-cutting behaviour the tag ships.
- [ ] No `TODO` markers in production code (`lib/`, `adapters/`,
      `bin/`, `build/`) without a linked issue or commit hash. Search:
      ```bash
      grep -rn "TODO\|FIXME\|XXX" lib/ adapters/ bin/ build/ \
          | grep -v "_test\|test/"
      ```

## 10. Merge dev → main

- [ ] Open a PR from `origin/dev` to `origin/main` titled
      `Release v<X.Y.Z>` with the OAT sign-off table, the CHANGELOG
      entry, and the section-6 backwards-compat diff in the body.
- [ ] PR is reviewed and approved by at least one other collaborator
      (or by the named release manager if you are the only maintainer).
- [ ] Merge **with a merge commit**, not a squash — the dev branch's
      individual commits are the audit trail for what landed in this
      tag, and squashing collapses them into one opaque entry.
- [ ] Confirm `main` HEAD is now the commit you intend to tag.

## 11. Tag

- [ ] Create an **annotated** tag (not a lightweight tag) with a
      message that includes the CHANGELOG entry verbatim:
      ```bash
      git tag -a v<X.Y.Z> -m "$(cat <<EOF
      v<X.Y.Z>
      <paste CHANGELOG entry here>
      EOF
      )"
      ```
- [ ] If you sign tags, sign this one (`-s` instead of `-a`).
- [ ] `git push origin v<X.Y.Z>` — push the tag.
- [ ] `git push origin main` — push the merge commit.
- [ ] Confirm the tag points at the merge commit (`git rev-parse
      v<X.Y.Z>` matches `git rev-parse origin/main`).

## 12. Artefacts

If your distribution model includes published artefacts, build them
**from a fresh clone of the tag** to prove the tag is self-contained:

- [ ] `git clone --branch v<X.Y.Z> --depth 1 <repo_url> /tmp/rel_clone &&
      cd /tmp/rel_clone && bash build/bundle.sh` — produces
      `dist/loadout-pipeline.sh` byte-for-byte from the tagged source.
- [ ] Optional: publish `dist/loadout-pipeline.sh` to the GitHub
      Releases page for the tag. Include the SHA-256 in the release
      notes so downstream installers can verify.
- [ ] Optional: `docker build -t <registry>/loadout-pipeline:<X.Y.Z> .
      && docker push <registry>/loadout-pipeline:<X.Y.Z>`. Also tag
      `:latest` if this is the newest stable release.

## 13. Post-release smoke

Run the cheapest end-to-end smoke against the freshly tagged commit, on
a machine that has not seen the source before — this catches "works on
my machine" issues before any user does:

- [ ] Fresh clone in a scratch directory:
      `git clone --branch v<X.Y.Z> --depth 1 <repo_url> /tmp/smoke && cd /tmp/smoke`
- [ ] `bash test/fixtures/create_fixtures.sh && bash test/run_tests.sh`
      — same exit-code and assertion-count expectations as section 2.
- [ ] `LVOL_MOUNT_POINT=/tmp/smoke_dest bash bin/loadout-pipeline.sh examples/lvol.jobs`
      and confirm files land at `/tmp/smoke_dest`.
- [ ] If you published a Docker image, also smoke it from a registry
      pull (`docker pull <registry>/loadout-pipeline:<X.Y.Z>`) followed
      by the canonical bind-mounted `/jobs/lvol.jobs` invocation.

## 14. Announce

- [ ] Update the GitHub Releases page (or the equivalent on whichever
      forge hosts the repo) with the CHANGELOG entry, the dist artefact
      link, the Docker image tag, and the OAT table from section 5.
- [ ] If your project has a public channel (Slack, Discord, mailing
      list, blog), post a one-line announcement linking to the release
      page.
- [ ] If this release closes any open GitHub issues, comment on each
      one with the tag and close it.

## 15. Post-release housekeeping

- [ ] Open a follow-up PR on `origin/dev` titled
      `Post-release housekeeping for v<X.Y.Z>`:
  - [ ] Bump the version constant (section 7) to the next planned
        version with a `-dev` or `-pre` suffix.
  - [ ] Add an empty `## [Unreleased]` heading at the top of
        `CHANGELOG.md`.
  - [ ] Cross out resolved items from this checklist's "things we
        decided to defer" notes (see below).
- [ ] If any blocker was deferred to the next release rather than fixed
      for this tag, file a tracking issue **now**, while it is fresh.
      "We'll remember" is how regressions ship.

## Things commonly deferred (and the answer)

- **`tools/perf/` exemption.** The framework is documented as exempt
  from the freeze until a real-hardware sweep has been captured in
  git. **Decision for v1.0.0:** keep the exemption as written; revisit
  once a sweep lands. Do NOT freeze `tools/perf/` flags this tag.
- **`ai/ai_worker.sh`.** A 6-line placeholder. **Decision for v1.0.0:**
  delete or implement before the tag. Shipping placeholder code in a
  stable release is worse than the inconvenience of removing it.
- **HDL adapter without real PS2 hardware on hand.** The OAT-HDL-DRY
  fallback (suite 20 H1–H7 shim coverage) is the documented substitute
  for OAT-HDL-1 through OAT-HDL-4 when a maintainer has no hardware to
  test against. Mark the OAT row "DRY only" in Notes.
