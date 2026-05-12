# Operator Acceptance Test (OAT)

A sit-down checklist a real operator runs **once**, against real hardware and
real services, before trusting `loadout-pipeline` in production. The
automated suites under `test/run_tests.sh` and `test/integration/` cover
correctness at the code level; this document covers the things only a human
in front of real infrastructure can confirm — that the SD card you just
plugged in is actually written to, that your real FTP credentials work end
to end, that the precheck skips a re-run against your real S3 bucket.

Every section is self-contained: do them in any order, skip the adapters
you don't care about, and come back later for the rest. Cross-cutting
behaviours at the end (recovery, space pressure, strip list, profile
directories, debug output) apply to every adapter and only need to be run
once with whichever adapter you have the cheapest setup for — most
operators run them against `lvol`.

## Conventions used in this document

- `$REPO` — wherever you cloned the repo (`/path/to/loadout-pipeline`).
- `$ISOS` — directory of `.7z` archives you control. The instructions below
  generate test fixtures into `test/fixtures/isos/` so you don't need
  real game ISOs for any of the validations.
- Lines starting with `#` are explanatory; lines starting with `$` are
  commands. Output examples are quoted from a real run with timestamps and
  PIDs replaced by placeholders.
- Every command is intended to be run from `$REPO`. Use absolute paths in
  jobs files; the pipeline resolves them relative to the working directory.
- Where a value is **operator-supplied** (your FTP host, your S3 bucket,
  your SSH user), the doc uses an `OPERATOR_*` placeholder you replace.
- The hash codes in checklist items (`OAT-LVOL-1`, …) are stable. Cite them
  in bug reports and release notes; they don't change between versions.

## Prerequisites — done once for the whole document

```bash
$ cd $REPO
$ cp .env.example .env && chmod 600 .env
# Edit .env if you want — every value can also be set inline at call time.

$ bash test/fixtures/create_fixtures.sh
# [fixtures] Packing game1 → test/fixtures/isos/game1.7z
# [fixtures] Packing game2 → test/fixtures/isos/game2.7z
# [fixtures] Packing game3 → test/fixtures/isos/game3.7z
# [fixtures] Packing game4 → test/fixtures/isos/game4.7z

$ ls test/fixtures/isos/
# game1.7z  game2.7z  game3.7z  game4.7z
```

If `bash bin/loadout-pipeline.sh` exits 2 with `prerequisite check failed`
on a fresh machine, install the **Core (always required)** packages from
the `Required packages` section of `README.md` first and re-run.

---

## OAT-LVOL — local volume adapter

The cheapest adapter to validate. Works against any writable local
directory: an SD card, a USB drive, an external SSD, a NAS mount, or even
just `/tmp/some-folder`. If you have any operator-supplied destination, run
this section against it; if you have nothing, run it against
`/tmp/oat_lvol`.

### OAT-LVOL-1 — happy path

```bash
$ OPERATOR_LVOL=/tmp/oat_lvol     # ← replace with your real mount, e.g. /media/user/SD32GB
$ mkdir -p "$OPERATOR_LVOL"
$ cat > /tmp/oat_lvol.jobs <<EOF
~$REPO/test/fixtures/isos/game1.7z|lvol|oat/game1~
~$REPO/test/fixtures/isos/game3.7z|lvol|oat/game3~
EOF

$ LVOL_MOUNT_POINT="$OPERATOR_LVOL" bash bin/loadout-pipeline.sh /tmp/oat_lvol.jobs
```

**Look for, in order:**

```
[pipeline] Checking prerequisites...
[pipeline] Initializing environment...
[pipeline] Loading jobs from /tmp/oat_lvol.jobs...
[pipeline] Starting pipeline...
[pipeline] resume planner: 0 of 2 already satisfied in 0s (2 to process)
[pipeline] Starting 2 extract worker(s) and 2 dispatch worker(s)...
[extract] Copying .../game1.7z → /tmp/iso_pipeline_copies/<pid>/game1.7z.<nnn>
[extract] Extracting .../game1.7z.<nnn> → /tmp/iso_pipeline/game1
[extract] Copying .../game3.7z → /tmp/iso_pipeline_copies/<pid>/game3.7z.<nnn>
[extract] Extracting .../game3.7z.<nnn> → /tmp/iso_pipeline/game3
[lvol] Copying /tmp/iso_pipeline/game1 → <OPERATOR_LVOL>/oat/game1
[lvol] Copying /tmp/iso_pipeline/game3 → <OPERATOR_LVOL>/oat/game3
[pipeline] All jobs completed!
```

Process exit code must be **0**.

**Verify at the destination:**

```bash
$ ls -1 "$OPERATOR_LVOL/oat/game1" "$OPERATOR_LVOL/oat/game3"
# Should list the same files that game1.7z and game3.7z contain — at least
# one file each. Compare against:
$ 7z l -slt "$REPO/test/fixtures/isos/game1.7z" | awk '/^Path = / { sub(/^Path = /,""); print }' | tail -n +2
```

The two listings should match (the 7z output may include directory
entries the `ls` doesn't, which is expected).

### OAT-LVOL-2 — idempotent re-run

Re-run the **exact same command** without changing anything:

```bash
$ LVOL_MOUNT_POINT="$OPERATOR_LVOL" bash bin/loadout-pipeline.sh /tmp/oat_lvol.jobs
```

**Look for:**

- The `resume planner` line now reports `2 of 2 already satisfied`, OR
- Two `[skip] ... (reason: already exists at destination)` lines appear in
  place of `[extract] Copying`.
- No `[lvol] Copying` lines.
- Exit code 0.

If you see `[extract] Copying` again, the precheck is misidentifying the
destination — usually a path-mismatch between `LVOL_MOUNT_POINT` and where
the files actually landed in OAT-LVOL-1. Re-check OAT-LVOL-1's verification
output before continuing.

### OAT-LVOL-3 — destination escape rejected (security)

Confirm the path-containment check works. The job-line parser rejects `..`
at parse time, but the lvol adapter also re-validates — exercise the
defense-in-depth path:

```bash
$ cat > /tmp/oat_lvol_evil.jobs <<EOF
~$REPO/test/fixtures/isos/game1.7z|lvol|../../etc/oat_should_not_exist~
EOF

$ LVOL_MOUNT_POINT="$OPERATOR_LVOL" bash bin/loadout-pipeline.sh /tmp/oat_lvol_evil.jobs
# Expect a non-zero exit and an error message about ".." being rejected at
# the parse stage. Nothing should be written outside $OPERATOR_LVOL.

$ ls /etc/oat_should_not_exist 2>/dev/null && echo "FAIL — escape succeeded" || echo "PASS — destination contained"
```

### OAT-LVOL-4 — cleanup

```bash
$ rm -rf "$OPERATOR_LVOL/oat" /tmp/oat_lvol.jobs /tmp/oat_lvol_evil.jobs
```

If `$OPERATOR_LVOL` is a real device, also unmount it cleanly before
removing the test directory.

---

## OAT-FTP — FTP adapter

Requires a reachable FTP server you can write to. If you don't have one,
spin up a transient one for the duration of this section:

```bash
# pure-ftpd is the same daemon used by the integration suite.
# This recipe mirrors test/integration/Dockerfile and is for the OAT only.
$ docker run --rm -d --name oat_ftp \
    -e PUBLICHOST=127.0.0.1 -e FTP_USER_NAME=oat -e FTP_USER_PASS=oat \
    -e FTP_USER_HOME=/home/ftpuser -p 21:21 -p 30000-30009:30000-30009 \
    stilliard/pure-ftpd
```

### OAT-FTP-1 — happy path

```bash
$ OPERATOR_FTP_HOST=127.0.0.1
$ OPERATOR_FTP_USER=oat
$ OPERATOR_FTP_PASS=oat
$ OPERATOR_FTP_PORT=21
$ cat > /tmp/oat_ftp.jobs <<EOF
~$REPO/test/fixtures/isos/game1.7z|ftp|/oat/game1~
~$REPO/test/fixtures/isos/game3.7z|ftp|/oat/game3~
EOF

$ env -u ALLOW_STUB_ADAPTERS \
    FTP_HOST="$OPERATOR_FTP_HOST" \
    FTP_USER="$OPERATOR_FTP_USER" \
    FTP_PASS="$OPERATOR_FTP_PASS" \
    FTP_PORT="$OPERATOR_FTP_PORT" \
    bash bin/loadout-pipeline.sh /tmp/oat_ftp.jobs
```

**Look for:**

- `[ftp] Transferring .../game1 → ftp://<HOST>:<PORT>/oat/game1`
- `[ftp] Transferring .../game3 → ftp://<HOST>:<PORT>/oat/game3`
- `lftp` per-file progress lines (varies by `lftp` build).
- **No** `[ftp] STUB —` lines. If you see those, `ALLOW_STUB_ADAPTERS=1`
  has leaked into the environment from `.env` or a parent shell — unset
  it and re-run.
- Exit code 0.

**Verify at the destination** — listing the FTP directory must show every
member of every archive:

```bash
$ curl -s --list-only "ftp://${OPERATOR_FTP_USER}:${OPERATOR_FTP_PASS}@${OPERATOR_FTP_HOST}:${OPERATOR_FTP_PORT}/oat/game1/"
# Expected: the same filenames as `7z l -slt game1.7z` (minus directories).

$ curl -s --list-only "ftp://${OPERATOR_FTP_USER}:${OPERATOR_FTP_PASS}@${OPERATOR_FTP_HOST}:${OPERATOR_FTP_PORT}/oat/game3/"
```

### OAT-FTP-2 — idempotent re-run

```bash
$ env -u ALLOW_STUB_ADAPTERS \
    FTP_HOST="$OPERATOR_FTP_HOST" FTP_USER="$OPERATOR_FTP_USER" \
    FTP_PASS="$OPERATOR_FTP_PASS" FTP_PORT="$OPERATOR_FTP_PORT" \
    bash bin/loadout-pipeline.sh /tmp/oat_ftp.jobs
```

Expect `[skip]` lines and zero `[ftp] Transferring`. If transfers fire
again, the precheck listing failed — most often because of passive-mode
firewall issues that prevent the data channel. Re-check that
`OPERATOR_FTP_PORT`'s data range (e.g. 30000-30009 above) is also reachable.

### OAT-FTP-3 — credentials never on argv (security)

While a transfer is in flight (or right after if it's quick), confirm the
password is not visible on any process command line:

```bash
$ ps -eo pid,args | grep -E 'ftp|lftp' | grep -v grep
# The output may show `lftp` with no arguments, with a heredoc fd, or with
# shell-builtin glue — but it must NOT show your password as a literal
# token. The adapter feeds creds via a heredoc, never via -e or argv.
```

### OAT-FTP-4 — cleanup

```bash
$ rm -f /tmp/oat_ftp.jobs
$ docker rm -f oat_ftp 2>/dev/null   # only if you used the docker recipe above
```

---

## OAT-HDL — HDL dump adapter (PS2 HDLoader injector)

Requires real PS2 HDD hardware (typically a 2.5" or 3.5" drive in an SATA-
or USB-to-IDE enclosure) and a working `~/.hdl_dump.conf`. If you don't
have the hardware on hand, jump to OAT-HDL-DRY at the end — it validates
everything except the actual write.

**Before starting:** install `ps2homebrew/hdl-dump` (build from source —
not packaged on most distros) and confirm you can list the HDD by hand:

```bash
$ hdl_dump toc hdd0:        # or sri:, depending on your config
# Expect a table of installed PS2 games. If this fails by hand, the
# pipeline cannot use it either — fix the local hdl_dump install first.
```

### OAT-HDL-1 — happy path

You'll need a small, real PS2 ISO archive. A homebrew demo (e.g. the
official PS2 SDK demos at `https://github.com/ps2dev/ps2sdk/tree/main/demo`,
re-packaged into a `.7z`) works fine and is freely redistributable.

```bash
$ OPERATOR_HDL_TARGET=hdd0:        # ← your hdl_dump install target
$ OPERATOR_HDL_PROBE=sri:          # ← your hdl_dump host device id; leave empty to skip the probe
$ OPERATOR_HDL_TITLE="OAT Test Title"
$ OPERATOR_HDL_ARCHIVE=/path/to/your/homebrew_demo.7z

$ cat > /tmp/oat_hdl.jobs <<EOF
~$OPERATOR_HDL_ARCHIVE|hdl|dvd|$OPERATOR_HDL_TITLE~
EOF

$ env -u ALLOW_STUB_ADAPTERS \
    HDL_INSTALL_TARGET="$OPERATOR_HDL_TARGET" \
    HDL_HOST_DEVICE="$OPERATOR_HDL_PROBE" \
    bash bin/loadout-pipeline.sh /tmp/oat_hdl.jobs
```

**Look for:**

- `[pipeline] Probing hdl host device <DEVICE> ...` (only if `HDL_HOST_DEVICE`
  is set; this is a one-shot startup writability check).
- `[hdl] Injecting .../<title>.iso → hdd0: as "OAT Test Title" (dvd)`
- Exit code 0.

**Verify on the HDD:**

```bash
$ hdl_dump toc "$OPERATOR_HDL_TARGET" | grep -F "$OPERATOR_HDL_TITLE"
# Should print the row for the freshly-injected title.
```

### OAT-HDL-2 — idempotent re-run

```bash
$ env -u ALLOW_STUB_ADAPTERS \
    HDL_INSTALL_TARGET="$OPERATOR_HDL_TARGET" \
    HDL_HOST_DEVICE="$OPERATOR_HDL_PROBE" \
    bash bin/loadout-pipeline.sh /tmp/oat_hdl.jobs
```

Expect `[skip] ...|hdl|...` and **no** `[hdl] Injecting`. The precheck
runs `hdl_dump toc` and matches the title at end-of-line, so a partition
named exactly `OAT Test Title` triggers the skip; a partition named
`OAT Test Title 2` does not. (This is a deliberate guard against
substring collisions like `Zelda` vs `Zelda II`.)

### OAT-HDL-3 — `HDL_INSTALL_TARGET` unset is a hard error

Confirms the adapter refuses to silently no-op when configuration is
missing — only `ALLOW_STUB_ADAPTERS=1` enables stub fallback:

```bash
$ env -u ALLOW_STUB_ADAPTERS -u HDL_INSTALL_TARGET \
    bash bin/loadout-pipeline.sh /tmp/oat_hdl.jobs
# Expect non-zero exit and:
#   [ERROR] hdl: HDL_INSTALL_TARGET is not set
```

### OAT-HDL-DRY — dry-run validation without hardware

If you don't have PS2 hardware on hand, you can still validate the
adapter's argument unpacking, the 4-field job grammar (`<iso>|hdl|<format>|<title>`),
and the precheck title-match rules using an `hdl_dump` shim. Suite
`test/suites/20_unit_adapters_resume.sh` already does this — re-running
the unit suite with `bash test/run_tests.sh` exercises the H1–H7 scenarios
(image selection: dvd/cd, single iso, multiple iso, cue+bin, ambiguous
mixes) without touching any hardware. Confirming `bash test/run_tests.sh`
returns 0 with the documented assertion count covers OAT-HDL-DRY.

### OAT-HDL-4 — cleanup

```bash
$ rm -f /tmp/oat_hdl.jobs
# To remove the test partition from the HDD:
$ hdl_dump delete "$OPERATOR_HDL_TARGET" "$OPERATOR_HDL_TITLE"
```

---

## OAT-RCLONE — rclone adapter

Requires a configured rclone remote (`rclone config` once, then your
remote is referenced by name). The simplest free option is a local
`alias:` remote pointing at a directory; the most realistic is an S3
bucket or a Google Drive OAuth remote.

### Remote-setup-helpers (skip if you already have one)

```bash
# Local alias remote — no network, no credentials, but exercises the same
# rclone code paths as a real cloud remote.
$ rclone config create oat_local alias remote=/tmp/oat_rclone_root
$ mkdir -p /tmp/oat_rclone_root
```

### OAT-RCLONE-1 — happy path

```bash
$ OPERATOR_RCLONE_REMOTE=oat_local        # or your real remote name like "mys3"
$ OPERATOR_RCLONE_BASE=/oat               # base path on the remote
$ cat > /tmp/oat_rclone.jobs <<EOF
~$REPO/test/fixtures/isos/game1.7z|rclone|game1~
~$REPO/test/fixtures/isos/game3.7z|rclone|game3~
EOF

$ env -u ALLOW_STUB_ADAPTERS \
    RCLONE_REMOTE="$OPERATOR_RCLONE_REMOTE" \
    RCLONE_DEST_BASE="$OPERATOR_RCLONE_BASE" \
    bash bin/loadout-pipeline.sh /tmp/oat_rclone.jobs
```

**Look for:**

- `[rclone] Transferring .../game1 → oat_local:/oat/game1`
- `[rclone] Transferring .../game3 → oat_local:/oat/game3`
- rclone progress output (one block per file by default).
- Exit code 0.

**Verify at the destination:**

```bash
$ rclone lsf "${OPERATOR_RCLONE_REMOTE}:${OPERATOR_RCLONE_BASE}/game1"
$ rclone lsf "${OPERATOR_RCLONE_REMOTE}:${OPERATOR_RCLONE_BASE}/game3"
# Each listing should match the archive's contents.
```

### OAT-RCLONE-2 — idempotent re-run

```bash
$ env -u ALLOW_STUB_ADAPTERS \
    RCLONE_REMOTE="$OPERATOR_RCLONE_REMOTE" \
    RCLONE_DEST_BASE="$OPERATOR_RCLONE_BASE" \
    bash bin/loadout-pipeline.sh /tmp/oat_rclone.jobs
```

Expect `[skip]` lines and no `[rclone] Transferring`. If transfers fire
again, the most common cause is a `RCLONE_DEST_BASE` mismatch between the
runs — the precheck builds `${REMOTE}:${BASE}/${dest}` and any leading or
trailing slash difference produces a different probe target.

### OAT-RCLONE-3 — explicit config path

If your operators run with a non-default `rclone.conf` location, confirm
`RCLONE_CONFIG` is forwarded:

```bash
$ env -u ALLOW_STUB_ADAPTERS \
    RCLONE_REMOTE="$OPERATOR_RCLONE_REMOTE" \
    RCLONE_DEST_BASE="$OPERATOR_RCLONE_BASE" \
    RCLONE_CONFIG=/path/to/your/rclone.conf \
    bash bin/loadout-pipeline.sh /tmp/oat_rclone.jobs
# Same expectations as OAT-RCLONE-1; the only difference is that rclone
# now reads `--config /path/to/your/rclone.conf` instead of the default.
```

### OAT-RCLONE-4 — cleanup

```bash
$ rm -f /tmp/oat_rclone.jobs
$ rclone purge "${OPERATOR_RCLONE_REMOTE}:${OPERATOR_RCLONE_BASE}"
$ rm -rf /tmp/oat_rclone_root         # only if you used the local alias remote
$ rclone config delete oat_local      # only if you created it for this OAT
```

---

## OAT-RSYNC — rsync adapter

Two sub-modes: local-target (no `RSYNC_HOST`) and remote-target
(`RSYNC_HOST` set, transfer over SSH). Run both — they exercise different
code paths in the adapter and the precheck.

### OAT-RSYNC-LOCAL-1 — local target, happy path

```bash
$ OPERATOR_RSYNC_BASE=/tmp/oat_rsync_local
$ mkdir -p "$OPERATOR_RSYNC_BASE"
$ cat > /tmp/oat_rsync.jobs <<EOF
~$REPO/test/fixtures/isos/game1.7z|rsync|games/game1~
~$REPO/test/fixtures/isos/game3.7z|rsync|games/game3~
EOF

$ RSYNC_DEST_BASE="$OPERATOR_RSYNC_BASE" \
    bash bin/loadout-pipeline.sh /tmp/oat_rsync.jobs
```

**Look for:**

- `[rsync] Transferring .../game1 → /tmp/oat_rsync_local/games/game1`
- `[rsync] Transferring .../game3 → /tmp/oat_rsync_local/games/game3`
- `info=progress2` summary lines (file count, bytes, speed).
- Exit code 0.

**Verify:**

```bash
$ ls -1 "$OPERATOR_RSYNC_BASE/games/game1" "$OPERATOR_RSYNC_BASE/games/game3"
```

### OAT-RSYNC-LOCAL-2 — idempotent re-run

```bash
$ RSYNC_DEST_BASE="$OPERATOR_RSYNC_BASE" \
    bash bin/loadout-pipeline.sh /tmp/oat_rsync.jobs
```

Expect `[skip]` lines and no `[rsync] Transferring`.

### OAT-RSYNC-REMOTE-1 — remote target over SSH, happy path

Requires a host you can ssh to non-interactively (key in
`~/.ssh/authorized_keys` on the remote, or `ssh-agent` already loaded):

```bash
$ OPERATOR_RSYNC_HOST=user@your-server.example.com   # ← replace
$ OPERATOR_RSYNC_USER=user                           # used to build user@host if RSYNC_HOST is bare
$ OPERATOR_RSYNC_BASE_REMOTE=/srv/oat                # absolute path on the remote
$ OPERATOR_RSYNC_PORT=22

# Pre-create the destination root on the remote.
$ ssh -p "$OPERATOR_RSYNC_PORT" "$OPERATOR_RSYNC_HOST" "mkdir -p $OPERATOR_RSYNC_BASE_REMOTE"

$ RSYNC_HOST="$OPERATOR_RSYNC_HOST" \
  RSYNC_USER="$OPERATOR_RSYNC_USER" \
  RSYNC_SSH_PORT="$OPERATOR_RSYNC_PORT" \
  RSYNC_DEST_BASE="$OPERATOR_RSYNC_BASE_REMOTE" \
    bash bin/loadout-pipeline.sh /tmp/oat_rsync.jobs
```

**Look for:**

- `[rsync] Transferring .../game1 → user@host:/srv/oat/games/game1/`
- `--mkpath` in the rsync invocation (creates missing intermediate dirs on
  the remote). Visible at `DEBUG_IND=2`.
- Exit code 0.

**Verify:**

```bash
$ ssh -p "$OPERATOR_RSYNC_PORT" "$OPERATOR_RSYNC_HOST" \
    "ls -1 $OPERATOR_RSYNC_BASE_REMOTE/games/game1 $OPERATOR_RSYNC_BASE_REMOTE/games/game3"
```

### OAT-RSYNC-REMOTE-2 — remote idempotent re-run (precheck over SSH)

```bash
$ RSYNC_HOST="$OPERATOR_RSYNC_HOST" \
  RSYNC_USER="$OPERATOR_RSYNC_USER" \
  RSYNC_SSH_PORT="$OPERATOR_RSYNC_PORT" \
  RSYNC_DEST_BASE="$OPERATOR_RSYNC_BASE_REMOTE" \
    bash bin/loadout-pipeline.sh /tmp/oat_rsync.jobs
```

This is the hottest path for the new rsync precheck (`lib/precheck.sh`
rsync arm) — it issues `rsync --list-only` over the same SSH transport
the adapter uses for transfers. Expect `[skip]` lines and no `[rsync]
Transferring`. If you see transfers, run with `DEBUG_IND=1` and look for
the precheck's `← precheck.sh rsync: already present` trace line — its
absence pinpoints whether the listing or the matching is failing.

### OAT-RSYNC-3 — cleanup

```bash
$ rm -rf "$OPERATOR_RSYNC_BASE" /tmp/oat_rsync.jobs
$ ssh -p "$OPERATOR_RSYNC_PORT" "$OPERATOR_RSYNC_HOST" \
    "rm -rf $OPERATOR_RSYNC_BASE_REMOTE"
```

---

## OAT-CROSS — cross-cutting behaviours

Run these once with whichever adapter you have the cheapest setup for —
typically `lvol`. They exercise the orchestration layer (workers, queues,
ledger, registry, strip-list, profiles, debug output) that all five
adapters share.

### OAT-CROSS-1 — strip list

Prove that files listed in `strip.list` are deleted post-extract and
never reach the destination, AND that the precheck is strip-list aware
(re-runs still skip even though the stripped file is missing at the
destination):

```bash
$ OPERATOR_LVOL=/tmp/oat_strip
$ mkdir -p "$OPERATOR_LVOL"
# Add a marker file to game1.7z that we want stripped:
$ STRIPPED="Strip Me.txt"
$ STAGE=$(mktemp -d)
$ ( cd "$STAGE" && 7z x -y "$REPO/test/fixtures/isos/game1.7z" >/dev/null \
    && echo 'should be stripped' > "$STRIPPED" \
    && 7z a -bso0 -bsp0 "$STAGE/game1_strip.7z" * "$STRIPPED" )
$ cat > /tmp/oat_strip.jobs <<EOF
~$STAGE/game1_strip.7z|lvol|stripped/game1~
EOF

# Tell the pipeline what to strip.
$ STRIP_LIST=$(mktemp)
$ printf '%s\n' "$STRIPPED" > "$STRIP_LIST"

$ EXTRACT_STRIP_LIST="$STRIP_LIST" LVOL_MOUNT_POINT="$OPERATOR_LVOL" \
    bash bin/loadout-pipeline.sh /tmp/oat_strip.jobs
```

**Look for:**

- `[extract] Stripping 'Strip Me.txt'` in the run output.
- `ls "$OPERATOR_LVOL/stripped/game1"` does **not** contain `Strip Me.txt`.
- All other game1 members are present.

**Re-run** and confirm `[skip]` fires even though `Strip Me.txt` is
missing at the destination (the precheck must ignore stripped files):

```bash
$ EXTRACT_STRIP_LIST="$STRIP_LIST" LVOL_MOUNT_POINT="$OPERATOR_LVOL" \
    bash bin/loadout-pipeline.sh /tmp/oat_strip.jobs
# Expect [skip] line for the stripped/game1 job. If a re-extract fires,
# the precheck is missing the strip-list check.
```

Cleanup:

```bash
$ rm -rf "$OPERATOR_LVOL" "$STAGE" "$STRIP_LIST" /tmp/oat_strip.jobs
```

### OAT-CROSS-2 — SIGKILL recovery

Kill an extract worker mid-run and confirm intra-run recovery completes
the job. Use the cheapest adapter and an artificial slow-down via a
larger-than-default fixture or a `sleep` injection. The simplest path:

```bash
$ OPERATOR_LVOL=/tmp/oat_recover
$ mkdir -p "$OPERATOR_LVOL"
# Use the multi-archive default jobs file so there's something to recover:
$ cat > /tmp/oat_recover.jobs <<EOF
~$REPO/test/fixtures/isos/game1.7z|lvol|r/g1~
~$REPO/test/fixtures/isos/game2.7z|lvol|r/g2~
~$REPO/test/fixtures/isos/game3.7z|lvol|r/g3~
~$REPO/test/fixtures/isos/game4.7z|lvol|r/g4~
EOF

# In one terminal, start the pipeline at debug level 1:
$ DEBUG_IND=1 LVOL_MOUNT_POINT="$OPERATOR_LVOL" \
    bash bin/loadout-pipeline.sh /tmp/oat_recover.jobs 2> /tmp/oat_recover.log &
$ PIPELINE_PID=$!

# In a second terminal (or quickly in the same one), kill an extract worker:
$ pgrep -f 'extract.sh' | head -n1 | xargs -r kill -9
$ wait "$PIPELINE_PID"; echo "exit=$?"
```

**Look for, in `/tmp/oat_recover.log` and stdout:**

- An `[ERROR]` reporting the killed worker.
- `[pipeline] Recovery pass 1: restarting workers for orphaned job(s)...`
- The recovered job eventually completes (`[lvol] Copying ...`) on the
  recovery pass.
- Final exit code 0 (recovery succeeded within `MAX_RECOVERY_ATTEMPTS`).

If exit is non-zero, the recovery loop was exhausted — increase
`MAX_RECOVERY_ATTEMPTS` or investigate why the second pass also failed.

Cleanup:

```bash
$ rm -rf "$OPERATOR_LVOL" /tmp/oat_recover.jobs /tmp/oat_recover.log
```

### OAT-CROSS-3 — space-pressure backoff

Run the pipeline against a deliberately small scratch directory and
confirm extract workers back off and retry rather than failing outright:

```bash
$ SMALL=$(mktemp -d)
# Mount a 5 MB tmpfs at $SMALL — adjust size below the largest fixture.
$ sudo mount -t tmpfs -o size=5m tmpfs "$SMALL"

$ DEBUG_IND=1 \
  SCRATCH_DISK_DIR="$SMALL" \
  LVOL_MOUNT_POINT=/tmp/oat_space \
  SPACE_RETRY_BACKOFF_INITIAL_SEC=1 \
  SPACE_RETRY_BACKOFF_MAX_SEC=4 \
    bash bin/loadout-pipeline.sh "$REPO/examples/lvol.jobs" 2> /tmp/oat_space.log
```

**Look for in `/tmp/oat_space.log`:**

- One or more `space reservation miss` messages from `lib/workers.sh`.
- The job is re-queued and eventually completes.
- Final exit 0 (scratch space frees up between attempts as other workers
  finish).

If you see ENOSPC errors and a non-zero exit, the tmpfs is so small even
one job can't fit — increase `size=` until at least one extract slot fits.

Cleanup:

```bash
$ sudo umount "$SMALL" && rmdir "$SMALL"
$ rm -rf /tmp/oat_space /tmp/oat_space.log
```

### OAT-CROSS-4 — profile directory (multi-jobs-file)

Confirm a directory of `*.jobs` files is loaded and concatenated:

```bash
$ PROF=/tmp/oat_profile
$ mkdir -p "$PROF" /tmp/oat_prof_dest

$ cat > "$PROF/01_a.jobs" <<EOF
~$REPO/test/fixtures/isos/game1.7z|lvol|p/g1~
EOF
$ cat > "$PROF/02_b.jobs" <<EOF
~$REPO/test/fixtures/isos/game3.7z|lvol|p/g3~
EOF

$ LVOL_MOUNT_POINT=/tmp/oat_prof_dest bash bin/loadout-pipeline.sh "$PROF"
```

**Look for:**

- `[pipeline] Loading jobs from directory <PROF> (all *.jobs files)...`
- Both jobs run.
- `ls /tmp/oat_prof_dest/p/g1 /tmp/oat_prof_dest/p/g3` shows extracted
  contents from both archives.

Cleanup:

```bash
$ rm -rf "$PROF" /tmp/oat_prof_dest
```

### OAT-CROSS-5 — debug output levels

Confirm `DEBUG_IND=0/1/2` produce monotonically increasing output and
that `DEBUG_IND` validation rejects nonsense values:

```bash
$ DEBUG_IND=0 LVOL_MOUNT_POINT=/tmp/oat_dbg \
    bash bin/loadout-pipeline.sh examples/lvol.jobs 2>/tmp/oat_dbg0.log
$ DEBUG_IND=1 LVOL_MOUNT_POINT=/tmp/oat_dbg \
    bash bin/loadout-pipeline.sh examples/lvol.jobs 2>/tmp/oat_dbg1.log
$ DEBUG_IND=2 LVOL_MOUNT_POINT=/tmp/oat_dbg \
    bash bin/loadout-pipeline.sh examples/lvol.jobs 2>/tmp/oat_dbg2.log
$ wc -l /tmp/oat_dbg0.log /tmp/oat_dbg1.log /tmp/oat_dbg2.log
# Expect monotonic growth: dbg2 > dbg1 > dbg0.
```

```bash
$ DEBUG_IND=true bash bin/loadout-pipeline.sh examples/lvol.jobs 2>&1 | head -3
# Expect exit 2 and a clear error message naming DEBUG_IND.
```

Cleanup:

```bash
$ rm -rf /tmp/oat_dbg /tmp/oat_dbg{0,1,2}.log
```

### OAT-CROSS-6 — bundle parity (single-file deployment)

Confirm `dist/loadout-pipeline.sh` is bit-equivalent in behaviour to the
git-checkout. The unit suite supports running against the bundle directly:

```bash
$ bash build/bundle.sh
$ ls -l dist/loadout-pipeline.sh

# Run a real lvol job through the bundle.
$ LVOL_MOUNT_POINT=/tmp/oat_bundle \
    bash dist/loadout-pipeline.sh examples/lvol.jobs

# Run the unit suite against the bundle.
$ PIPELINE="$PWD/dist/loadout-pipeline.sh" bash test/run_tests.sh
```

**Look for:**

- The bundle invocation produces the same `[extract]` / `[lvol]` lines as
  a git-checkout invocation.
- The unit suite's final assertion count matches the source-tree run
  (today's documented baseline ≥ 458 assertions, 0 failures).

Cleanup:

```bash
$ rm -rf /tmp/oat_bundle dist/loadout-pipeline.sh
```

### OAT-CROSS-7 — Docker parity

Confirm the Docker image behaves identically:

```bash
$ docker build -t loadout-pipeline .

$ mkdir -p /tmp/oat_docker_dest
$ docker run --rm \
    -v "$REPO/test/fixtures/isos:/isos:ro" \
    -v "$REPO/examples:/jobs:ro" \
    -v /tmp/oat_docker_dest:/mnt/lvol \
    -e LVOL_MOUNT_POINT=/mnt/lvol \
    loadout-pipeline /jobs/lvol.jobs

$ ls /tmp/oat_docker_dest        # confirm extracted contents landed
```

**Note:** `examples/lvol.jobs` references archives at
`test/fixtures/isos/...`. When running inside Docker that path is
mounted at `/isos`, so for an actual Docker OAT you'll want to write a
small Docker-specific jobs file pointing at `/isos/...` paths and bind-
mount it at `/jobs/`. The integration suite's `12_docker_pipeline.sh` is
the canonical reference for the conventions.

Cleanup:

```bash
$ rm -rf /tmp/oat_docker_dest
$ docker rmi loadout-pipeline
```

---

## Sign-off checklist

A 1.0 release should have every applicable row green before the tag is
cut. Mark N/A for adapters you don't ship to.

| ID                  | Pass | Notes / operator initials |
| ------------------- | :--: | ------------------------- |
| OAT-LVOL-1          |      |                           |
| OAT-LVOL-2          |      |                           |
| OAT-LVOL-3          |      |                           |
| OAT-LVOL-4          |      |                           |
| OAT-FTP-1           |      |                           |
| OAT-FTP-2           |      |                           |
| OAT-FTP-3           |      |                           |
| OAT-FTP-4           |      |                           |
| OAT-HDL-1           |      |                           |
| OAT-HDL-2           |      |                           |
| OAT-HDL-3           |      |                           |
| OAT-HDL-DRY         |      |                           |
| OAT-HDL-4           |      |                           |
| OAT-RCLONE-1        |      |                           |
| OAT-RCLONE-2        |      |                           |
| OAT-RCLONE-3        |      |                           |
| OAT-RCLONE-4        |      |                           |
| OAT-RSYNC-LOCAL-1   |      |                           |
| OAT-RSYNC-LOCAL-2   |      |                           |
| OAT-RSYNC-REMOTE-1  |      |                           |
| OAT-RSYNC-REMOTE-2  |      |                           |
| OAT-RSYNC-3         |      |                           |
| OAT-CROSS-1         |      |                           |
| OAT-CROSS-2         |      |                           |
| OAT-CROSS-3         |      |                           |
| OAT-CROSS-4         |      |                           |
| OAT-CROSS-5         |      |                           |
| OAT-CROSS-6         |      |                           |
| OAT-CROSS-7         |      |                           |

When every applicable row is green, paste the signed-off table into the
release-cut PR description and proceed to tag `v1.0.0`.
