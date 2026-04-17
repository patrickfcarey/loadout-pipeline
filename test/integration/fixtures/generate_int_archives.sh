#!/usr/bin/env bash
# test/integration/fixtures/generate_int_archives.sh
#
# Produces the synthetic 7z archives the integration suite consumes.
# All archives are built from urandom bytes so there are no licensing,
# size, or network concerns. Output lands in ./isos/ next to this script.
#
# Cached by presence: the generator skips any archive that already
# exists with non-zero size. Delete the target file to force regen.

set -euo pipefail

FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISOS_DIR="$FIXTURES_DIR/isos"
SOURCES_DIR="$FIXTURES_DIR/sources"
mkdir -p "$ISOS_DIR" "$SOURCES_DIR"

# ─── helpers ─────────────────────────────────────────────────────────────────

_int_need_archive() {
    local out="$1"
    [[ -s "$out" ]] && return 1
    return 0
}

_int_pack() {
    # $1 archive out path, $2 source dir containing the members
    local out="$1" src="$2"
    echo "[int-fix] packing $(basename "$out") …"
    rm -f "$out"
    ( cd "$src" && 7z a "$out" ./* >/dev/null )
}

_int_random_iso() {
    # $1 dest file, $2 size-in-bytes
    local dest="$1" bytes="$2"
    dd if=/dev/urandom of="$dest" bs=1 count=0 seek="$bytes" 2>/dev/null
    # dd seek=N creates a sparse file; the pipeline reads real bytes, so
    # force-populate with a smaller burst of real random data first.
    dd if=/dev/urandom of="$dest" bs=4096 count=$(( bytes / 4096 + 1 )) 2>/dev/null
    # truncate to exact requested size.
    truncate -s "$bytes" "$dest"
}

# ─── small.7z — ~512 KB single iso ───────────────────────────────────────────

if _int_need_archive "$ISOS_DIR/small.7z"; then
    d="$SOURCES_DIR/small"
    mkdir -p "$d"; rm -rf "$d"/*
    _int_random_iso "$d/small.iso" $(( 512 * 1024 ))
    _int_pack "$ISOS_DIR/small.7z" "$d"
fi

# ─── medium.7z — ~2 MB single iso ────────────────────────────────────────────

if _int_need_archive "$ISOS_DIR/medium.7z"; then
    d="$SOURCES_DIR/medium"
    mkdir -p "$d"; rm -rf "$d"/*
    _int_random_iso "$d/medium.iso" $(( 2 * 1024 * 1024 ))
    _int_pack "$ISOS_DIR/medium.7z" "$d"
fi

# ─── large.7z — ~10 MB single iso ────────────────────────────────────────────

if _int_need_archive "$ISOS_DIR/large.7z"; then
    d="$SOURCES_DIR/large"
    mkdir -p "$d"; rm -rf "$d"/*
    _int_random_iso "$d/large.iso" $(( 10 * 1024 * 1024 ))
    _int_pack "$ISOS_DIR/large.7z" "$d"
fi

# ─── multi.7z — .bin + .cue (~2 MB total) ────────────────────────────────────

if _int_need_archive "$ISOS_DIR/multi.7z"; then
    d="$SOURCES_DIR/multi"
    mkdir -p "$d"; rm -rf "$d"/*
    _int_random_iso "$d/multi.bin" $(( 2 * 1024 * 1024 ))
    cat > "$d/multi.cue" <<'CUE'
FILE "multi.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
CUE
    _int_pack "$ISOS_DIR/multi.7z" "$d"
fi

# ─── parens (USA) [!].7z — pathological iso_path characters ─────────────────
# The iso_path regex in lib/jobs.sh allows letters, digits, _ . / space and
# parentheses — but NOT brackets. Use "parens (USA).7z" without brackets
# so the archive is valid for a load_jobs run.

PATHOLOGICAL_NAME="parens (USA).7z"
if _int_need_archive "$ISOS_DIR/$PATHOLOGICAL_NAME"; then
    d="$SOURCES_DIR/parens"
    mkdir -p "$d"; rm -rf "$d"/*
    _int_random_iso "$d/parens (USA).iso" $(( 512 * 1024 ))
    _int_pack "$ISOS_DIR/$PATHOLOGICAL_NAME" "$d"
fi

# ─── strip_target.7z — .bin + .cue + Vimm's Lair.txt ────────────────────────

if _int_need_archive "$ISOS_DIR/strip_target.7z"; then
    d="$SOURCES_DIR/strip_target"
    mkdir -p "$d"; rm -rf "$d"/*
    _int_random_iso "$d/strip_target.bin" $(( 512 * 1024 ))
    cat > "$d/strip_target.cue" <<'CUE'
FILE "strip_target.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
CUE
    # File name must match strip.list exactly so the dispatch guard
    # actually removes it. strip.list in the repo root carries the
    # canonical name.
    printf 'Ripped by Vimms Lair\n' > "$d/Vimm's Lair.txt"
    _int_pack "$ISOS_DIR/strip_target.7z" "$d"
fi

# ─── wrapper_ok.7z — single-directory wrapper around one iso ───────────────
# Exercises the extract-stage flatten path: archive stores its payload under
# "MyGame/game.iso", extract.sh must lift the contents up one level before
# dispatch. Keeps one .iso so suite assertions can pattern-match by name.
if _int_need_archive "$ISOS_DIR/wrapper_ok.7z"; then
    d="$SOURCES_DIR/wrapper_ok"
    mkdir -p "$d"; rm -rf "$d"/*
    mkdir -p "$d/MyGame"
    _int_random_iso "$d/MyGame/wrapper_ok.iso" $(( 512 * 1024 ))
    _int_pack "$ISOS_DIR/wrapper_ok.7z" "$d"
fi

# ─── wrapper_strip.7z — wrapper dir + Vimm's Lair.txt at top level ─────────
# Pre-flatten strip pass must remove the top-level Vimm's Lair.txt so the
# remaining single wrapper directory can be flattened unambiguously.
if _int_need_archive "$ISOS_DIR/wrapper_strip.7z"; then
    d="$SOURCES_DIR/wrapper_strip"
    mkdir -p "$d"; rm -rf "$d"/*
    mkdir -p "$d/MyGame"
    _int_random_iso "$d/MyGame/wrapper_strip.iso" $(( 512 * 1024 ))
    printf 'Ripped by Vimms Lair\n' > "$d/Vimm's Lair.txt"
    _int_pack "$ISOS_DIR/wrapper_strip.7z" "$d"
fi

# ─── wrapper_ambig.7z — wrapper dir + unrelated loose file ─────────────────
# Ambiguity case: after the strip pass the top level still has both a
# wrapper dir AND a loose file, so extract.sh must refuse to flatten and
# fail this job. Unit tests cover the same logic; the integration suite
# verifies the behaviour holds end-to-end against real substrates.
if _int_need_archive "$ISOS_DIR/wrapper_ambig.7z"; then
    d="$SOURCES_DIR/wrapper_ambig"
    mkdir -p "$d"; rm -rf "$d"/*
    mkdir -p "$d/MyGame"
    _int_random_iso "$d/MyGame/wrapper_ambig.iso" $(( 512 * 1024 ))
    printf 'unrelated sibling\n' > "$d/unrelated.dat"
    _int_pack "$ISOS_DIR/wrapper_ambig.7z" "$d"
fi

# ─── wrapper_inner_strip.7z — strip-list file inside the wrapper dir ──────
# The strip target ("Vimm's Lair.txt") lives inside the wrapper directory,
# not at the top level. The strip pass must find and remove it even after
# flatten lifts the wrapper contents up one level.
if _int_need_archive "$ISOS_DIR/wrapper_inner_strip.7z"; then
    d="$SOURCES_DIR/wrapper_inner_strip"
    mkdir -p "$d"; rm -rf "$d"/*
    mkdir -p "$d/MyGame"
    _int_random_iso "$d/MyGame/wrapper_inner_strip.iso" $(( 512 * 1024 ))
    printf 'Ripped by Vimms Lair\n' > "$d/MyGame/Vimm's Lair.txt"
    _int_pack "$ISOS_DIR/wrapper_inner_strip.7z" "$d"
fi

# ─── wrapper_two_dirs.7z — two top-level directories (ambiguous) ─────────
# Two directories at the top level: extract.sh must refuse to flatten
# because there is no single unambiguous wrapper to lift.
if _int_need_archive "$ISOS_DIR/wrapper_two_dirs.7z"; then
    d="$SOURCES_DIR/wrapper_two_dirs"
    mkdir -p "$d"; rm -rf "$d"/*
    mkdir -p "$d/DirA" "$d/DirB"
    _int_random_iso "$d/DirA/a.iso" $(( 512 * 1024 ))
    _int_random_iso "$d/DirB/b.iso" $(( 512 * 1024 ))
    _int_pack "$ISOS_DIR/wrapper_two_dirs.7z" "$d"
fi

# ─── ps2_synth.7z — synthetic PS2 ISO with valid SYSTEM.CNF ────────────────
# hdl_dump sniffs the ISO's SYSTEM.CNF for a BOOT2 line to extract the
# title-id (SLUS_999.99 here). A real PS2 game ships a hundred-plus files;
# for the integration test we only need hdl_dump to accept the inject and
# later round-trip via `hdl_dump toc`. The synthetic image is ≤10 MB so it
# exercises the `cd` path (DVD threshold in hdl_dump is ~675 MB).
if _int_need_archive "$ISOS_DIR/ps2_synth.7z"; then
    d="$SOURCES_DIR/ps2_synth"
    mkdir -p "$d"; rm -rf "$d"/*
    iso_staging="$SOURCES_DIR/ps2_iso_staging"
    mkdir -p "$iso_staging"; rm -rf "$iso_staging"/*

    # Valid-enough SYSTEM.CNF. CRLF line endings match the PS2 console
    # convention and some hdl_dump forks require them. The BOOT2 line
    # encodes the PS2 title id the pipeline tests look up later.
    printf 'BOOT2 = cdrom0:\\SLUS_999.99;1\r\nVER = 1.00\r\nVMODE = NTSC\r\n' \
        > "$iso_staging/SYSTEM.CNF"

    # Pad out to ~8 MB so there's something for hdl_dump to chew on.
    dd if=/dev/urandom of="$iso_staging/DATA.DAT" \
        bs=1024 count=7168 >/dev/null 2>&1

    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -quiet \
            -V "LOADOUT_PS2_SYNTH" \
            -o "$d/ps2_synth.iso" \
            "$iso_staging" >/dev/null 2>&1 \
            || { echo "[int-fix] xorriso failed" >&2; exit 1; }
    elif command -v genisoimage >/dev/null 2>&1; then
        genisoimage -quiet \
            -V "LOADOUT_PS2_SYNTH" \
            -o "$d/ps2_synth.iso" \
            "$iso_staging" >/dev/null 2>&1 \
            || { echo "[int-fix] genisoimage failed" >&2; exit 1; }
    else
        echo "[int-fix] neither xorriso nor genisoimage installed — cannot build ps2_synth" >&2
        exit 1
    fi

    _int_pack "$ISOS_DIR/ps2_synth.7z" "$d"
fi

echo "[int-fix] archives ready in $ISOS_DIR/"
ls -lh "$ISOS_DIR" | sed 's/^/[int-fix]   /'
