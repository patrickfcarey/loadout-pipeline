#!/usr/bin/env bash
# sourced by bin/loadout-pipeline.sh — do not execute directly

# ─── _assert_pipeline_dir_safe ────────────────────────────────────────────────
# Asserts that a pipeline working directory is safe to use before the pipeline
# touches the filesystem. Checks three conditions in order:
#   1. Must not be a symlink — a symlink-to-dir can redirect all writes to an
#      attacker-controlled location outside the expected path.
#   2. If it already exists, must be owned by the current user — prevents a
#      local attacker from pre-creating the directory and planting hostile
#      symlinks or world-writable files inside it.
#   3. If it does not exist yet, creates it with mode 0700 — prevents other
#      local users from reading or writing the directory before the pipeline
#      populates it.
#
# Deliberately calls exit rather than returning non-zero: a bad working
# directory is not recoverable, and letting the pipeline continue would
# silently corrupt data or expose credentials stored in scratch files.
#
# Parameters
#   $1  directory_path — absolute path of the working directory to validate
#                        (e.g. $QUEUE_DIR, $EXTRACT_DIR, $COPY_DIR)
#
# Returns     : 0 — directory is safe (exits with code 1 on any failure)
# Modifies    : filesystem — may create directory_path with mode 0700 if absent
#
# Locals
#   directory_path  — $1 captured as a named local
#   directory_owner — numeric UID of the existing directory (from stat -c %u)
#   current_uid     — UID of the running process (from id -u); compared to
#                     directory_owner to enforce ownership
# ──────────────────────────────────────────────────────────────────────────────
_assert_pipeline_dir_safe() {
    local directory_path="$1"

    if [[ -L "$directory_path" ]]; then
        log_error "pipeline directory must not be a symlink: $directory_path"
        log_error "remove it and let the pipeline create a real directory"
        exit 1
    fi

    if [[ -e "$directory_path" ]]; then
        local directory_owner
        directory_owner="$(stat -c %u "$directory_path" 2>/dev/null || echo -1)"
        local current_uid
        current_uid="$(id -u)"
        if [[ "$directory_owner" != "$current_uid" ]]; then
            log_error "pipeline directory is not owned by the current user (uid=$current_uid): $directory_path"
            log_error "delete it or change ownership before running"
            exit 1
        fi
    else
        # Directory does not exist yet — create it with restricted permissions
        # so other local users cannot plant files or symlinks inside it.
        install -d -m 700 "$directory_path"
    fi
}

# ─── init_environment ─────────────────────────────────────────────────────────
# Validates all pipeline working directories for safety and then ensures they
# exist. Called once at pipeline startup, before any queue, ledger, or scratch
# file is created. Delegates the safety checks to _assert_pipeline_dir_safe,
# which exits the process on any violation — so if init_environment returns,
# all directories are guaranteed to be safe and writable.
#
# Parameters  : none
# Returns     : 0 always (exits the process on any safety violation)
# Modifies    : filesystem — creates $QUEUE_DIR, $EXTRACT_DIR, and $COPY_DIR
#               if they do not already exist (via mkdir -p inside
#               _assert_pipeline_dir_safe or the subsequent mkdir -p calls)
# Locals      : none
# ──────────────────────────────────────────────────────────────────────────────
init_environment() {
    log_enter
    # Validate every working directory the pipeline will write to before touching
    # the filesystem. A world-writable /tmp means an attacker can pre-create these
    # as symlinks and redirect our writes. _assert_pipeline_dir_safe rejects symlinks
    # and directories owned by other users.
    _assert_pipeline_dir_safe "$QUEUE_DIR"
    _assert_pipeline_dir_safe "$EXTRACT_DIR"
    _assert_pipeline_dir_safe "$COPY_DIR"

    # mkdir -p is idempotent: safe to call on every run. The directories are
    # guaranteed to already exist (either pre-existing and validated above, or
    # created by _assert_pipeline_dir_safe itself).
    mkdir -p "$EXTRACT_DIR"
    mkdir -p "$COPY_DIR"
    mkdir -p "$QUEUE_DIR"
}
