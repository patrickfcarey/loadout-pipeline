#!/usr/bin/env bash
# test/integration/suites/11_negative.sh
#
# Negative-result validation suite. Every scenario here confirms that the
# integration assertion helpers (verify.sh) are sensitive enough to detect
# a specific category of injected error.
#
# Structure of each scenario:
#   1. Establish real filesystem state — either reused from an earlier suite
#      that already ran (particularly suite 02, which deposited files on
#      $INT_SD_VFAT and decoded expected trees under $INT_STATE/t2_expected)
#      or freshly created for mutation cases.
#   2. Call an assertion against a DELIBERATELY WRONG expected value: a
#      one-character typo in a path, a mismatched file, a wrong return code,
#      an impossible mtime, etc.
#   3. neg_check (verify.sh) runs the assertion in a subshell, captures its
#      stdout, and looks for the [FAIL] marker. If found → the assertion
#      caught the injected error → this scenario PASSes. If [FAIL] is absent
#      → the assertion has a blind spot → this scenario FAILs.
#
# None of these scenarios invoke the pipeline. They rely on real files already
# present on the integration substrates from earlier suites. All scratch dirs
# created here are cleaned up before the scenario exits.

# ─── N1: wrong filename extension ────────────────────────────────────────────
#
# Suite 02 wrote small.iso to $INT_SD_VFAT/t2/small/. Asserting for .bin
# (which does not exist there) must be detected as absent.

header "Int Negative N1: wrong file extension (.iso → .bin)"

neg_check "assert_file_present: .iso renamed to .bin in path" \
    assert_file_present "$INT_SD_VFAT/t2/small/small.bin" "N1"

# ─── N2: one-character typo in subdirectory ───────────────────────────────────
#
# The real directory is t2/small/. Dropping the final 'l' produces a path
# that does not exist; the assertion must catch it.

header "Int Negative N2: one-character typo in subdirectory (small → smal)"

neg_check "assert_file_present: 'smal' vs 'small' in subdir" \
    assert_file_present "$INT_SD_VFAT/t2/smal/small.iso" "N2"

# ─── N3: completely wrong game directory name ─────────────────────────────────
#
# No 'large' entry was written to t2/ by suite 02. The assertion must
# not silently succeed on a nonexistent directory tree.

header "Int Negative N3: entirely wrong game directory name"

neg_check "assert_file_present: 'large' dir never created under t2/" \
    assert_file_present "$INT_SD_VFAT/t2/large/large.iso" "N3"

# ─── N4: assert_file_absent on a file that really exists ─────────────────────
#
# small.iso IS there from suite 02. Claiming it is absent must be detected.

header "Int Negative N4: assert_file_absent on a file that is present"

neg_check "assert_file_absent: small.iso actually exists" \
    assert_file_absent "$INT_SD_VFAT/t2/small/small.iso" "N4"

# ─── N5: assert_dir_present on a nonexistent directory ───────────────────────
#
# 'smal' (missing trailing 'l') was never created. The assertion must catch it.

header "Int Negative N5: assert_dir_present on nonexistent directory"

neg_check "assert_dir_present: 'smal' does not exist" \
    assert_dir_present "$INT_SD_VFAT/t2/smal" "N5"

# ─── N6: assert_tree_eq between two archives with different content ───────────
#
# T2_EXP/small and T2_EXP/medium were decoded by suite 02 from two different
# archives. Their trees are byte-different; the hash comparison must fail.

header "Int Negative N6: assert_tree_eq between two different archive trees"

neg_check "assert_tree_eq: small vs medium decoded trees differ" \
    assert_tree_eq "$T2_EXP/small" "$T2_EXP/medium" "N6 tree"

# ─── N7: assert_tree_eq after a single byte is appended to one file ───────────
#
# Copy the small tree, append one byte to small.iso, then compare against
# the original. A single extra byte changes the sha256; the assertion must
# detect the divergence.

header "Int Negative N7: assert_tree_eq with one byte appended to a file"

N7_DIR="$INT_STATE/n7_tampered"
rm -rf "$N7_DIR"
cp -r "$T2_EXP/small/." "$N7_DIR/"
printf 'x' >> "$N7_DIR/small.iso"

neg_check "assert_tree_eq: original vs byte-appended copy" \
    assert_tree_eq "$T2_EXP/small" "$N7_DIR" "N7 tree"

rm -rf "$N7_DIR"

# ─── N8: assert_file_eq on two files with different content ───────────────────
#
# small.iso and medium.iso have different byte sequences. The sha256 check
# must detect the mismatch.

header "Int Negative N8: assert_file_eq on files with different content"

neg_check "assert_file_eq: small.iso vs medium.iso" \
    assert_file_eq \
        "$INT_SD_VFAT/t2/small/small.iso" \
        "$INT_SD_VFAT/t2/medium/medium.iso" \
        "N8 file-eq"

# ─── N9: assert_rc with a mismatched expected value ──────────────────────────
#
# assert_rc "0" "1" checks whether actual==expected. 0 ≠ 1, so it must emit
# [FAIL]. This confirms the rc assertion is not comparing in the wrong order
# or coercing both sides to the same value.

header "Int Negative N9: assert_rc with wrong expected return code"

neg_check "assert_rc: actual=0 but expected=1" \
    assert_rc "0" "1" "N9 rc"

# ─── N10: assert_mtime_unchanged with epoch 0 as the expected value ───────────
#
# No real file has mtime 0 (1970-01-01). Passing epoch 0 as the expected value
# must be detected as a mismatch against the file's real mtime.

header "Int Negative N10: assert_mtime_unchanged with epoch 0"

neg_check "assert_mtime_unchanged: real mtime does not equal epoch 0" \
    assert_mtime_unchanged "$INT_SD_VFAT/t2/small/small.iso" "0" "N10 mtime"

# ─── N11: assert_fs_bytes_below with a limit of 1 byte ───────────────────────
#
# The extract tmpfs has real archive data written to it from earlier suites.
# Asserting that it holds ≤ 1 byte of used data must fail.

header "Int Negative N11: assert_fs_bytes_below with impossibly low limit"

neg_check "assert_fs_bytes_below: used bytes far exceed limit of 1" \
    assert_fs_bytes_below "$INT_EXTRACT" "1" "N11 fs"

# ─── N12: assert_queue_empty with a leftover .job file ───────────────────────
#
# Place a single .job file in a scratch queue dir and assert the queue is
# empty. The assertion must count the leftover and report failure.

header "Int Negative N12: assert_queue_empty with a leftover .job file"

N12_QUEUE="$INT_QUEUE/n12"
mkdir -p "$N12_QUEUE"
printf '~%s/small.7z|sd|n12/small~\n' "$INT_FIXTURES" > "$N12_QUEUE/leftover.job"

neg_check "assert_queue_empty: .job file is present" \
    assert_queue_empty "$N12_QUEUE"

rm -rf "$N12_QUEUE"

# ─── N13: assert_tree_eq with an extra unexpected file in the actual tree ─────
#
# Copy the small expected tree, then add a file the original does not have.
# tree_hash includes every regular file found by `find`, so the extra file
# changes the composite hash; the assertion must detect it.

header "Int Negative N13: assert_tree_eq with extra file in actual tree"

N13_DIR="$INT_STATE/n13_extra"
rm -rf "$N13_DIR"
cp -r "$T2_EXP/small/." "$N13_DIR/"
printf 'intruder\n' > "$N13_DIR/unexpected_file.txt"

neg_check "assert_tree_eq: actual has one extra file not in expected" \
    assert_tree_eq "$T2_EXP/small" "$N13_DIR" "N13 tree"

rm -rf "$N13_DIR"

# ─── N14: assert_file_present on an absolute path that does not exist ─────────
#
# A fully nonexistent path with no relation to any fixture or substrate. The
# assertion must not pass vacuously when handed a path that never existed.

header "Int Negative N14: assert_file_present on a fully nonexistent path"

neg_check "assert_file_present: /nonexistent/path/game.iso" \
    assert_file_present "/nonexistent/path/game.iso" "N14"

# ─── N15: assert_tree_eq when the expected directory does not exist ───────────
#
# Passing a nonexistent expected dir to assert_tree_eq must fail, not silently
# treat a missing reference as "matches everything". tree_hash returns non-zero
# for a missing dir; assert_tree_eq must propagate that as [FAIL].

header "Int Negative N15: assert_tree_eq with missing expected directory"

neg_check "assert_tree_eq: expected dir does not exist" \
    assert_tree_eq "/nonexistent/expected_dir" "$T2_EXP/small" "N15 tree"
