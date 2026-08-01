#!/usr/bin/env python3
# Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
"""Compare a MEDS-V RTL execution trace against Spike's golden trace.

This is the backbone of the project's verification (Book Ch 13).  Spike is the
official RISC-V reference model; if the RTL's committed-instruction stream
diverges from Spike's, the RTL is wrong.

The value of a trace diff over an end-of-test memory comparison is that it names
the FIRST instruction that went wrong, with its PC.  "The answer is wrong" costs
a day; "instruction 4127, PC 0x800001a4, vadd.vv wrote v3 = 0x... expected
0x..." costs five minutes.

Golden trace:
    spike --isa=rv64gcv_zvl128b -l --log-commits prog.elf 2> spike.log

RTL trace: emit one line per committed instruction in the normalised format
below (see `--emit-format`).

Usage:
    python3 scripts/cosim_diff.py spike.log rtl.log
    python3 scripts/cosim_diff.py spike.log rtl.log --context 5
    python3 scripts/cosim_diff.py --emit-format
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass

# Spike emits TWO interleaved line formats, and the distinction matters.
#
#   -l  disassembly line:
#       core   0: 0x000000008000000a (0x0d02f357) vsetvli t1, t0, e32, m1, ta, ma
#
#   --log-commits commit line (note the privilege level before the PC):
#       core   0: 3 0x000000008000000a (0x0d02f357) x6 0x0000000000000004
#
# The COMMIT line is the authoritative record: it is emitted once per retired
# instruction and carries the architectural state change.  The disassembly line
# is not a reliable one-per-instruction record -- in a tight loop Spike emits
# far fewer of them (a hello-world trace here had 5000 commits but only 341
# disassembly lines).  So commit lines are parsed by preference, and the
# disassembly form is accepted only as a fallback for `-l`-only logs.
SPIKE_COMMIT_RE = re.compile(
    r"^core\s+\d+:\s+\d+\s+0x(?P<pc>[0-9a-f]+)\s+\((?P<insn>0x[0-9a-f]+)\)\s*(?P<dis>.*)$"
)
SPIKE_DISASM_RE = re.compile(
    r"^core\s+\d+:\s+0x(?P<pc>[0-9a-f]+)\s+\((?P<insn>0x[0-9a-f]+)\)\s*(?P<dis>.*)$"
)

# Normalised RTL format -- one line per committed instruction:
#   <pc_hex> <insn_hex> [optional disassembly]
RTL_RE = re.compile(
    r"^\s*(?:0x)?(?P<pc>[0-9a-fA-F]+)\s+(?:0x)?(?P<insn>[0-9a-fA-F]+)\s*(?P<dis>.*)$"
)

EMIT_FORMAT = """
RTL trace format expected by cosim_diff.py
------------------------------------------
One line per COMMITTED instruction, in commit order:

    <pc_hex> <insn_hex> [disassembly ignored]

for example:

    8000000a 0d02f357 vsetvli t1, t0, e32, m1, ta, ma
    80000016 0203e087 vle32.v v1, (t2)
    8000001a 02108157 vadd.vv v2, v1, v1

Rules:
  * Emit ONLY on commit, never on issue -- a flushed instruction must not appear.
  * Emit in program order, one line each, even for multi-pass vector
    instructions.  A vadd.vv spanning eight passes is ONE line.
  * Hex, lower case, no leading zeros required, 0x prefix optional.
  * Write it to a file, not to the same stream as $display debug output.

In SystemVerilog:

    integer trace_fd;
    initial trace_fd = $fopen("rtl.log", "w");
    always_ff @(posedge clk_i)
      if (instr_retire)
        $fwrite(trace_fd, "%08x %08x\\n", retire_pc, retire_insn);
"""


@dataclass
class Entry:
    pc: int
    insn: int
    dis: str
    lineno: int


def _scan(path: str, regex: re.Pattern, name: str) -> list[Entry]:
    out: list[Entry] = []
    try:
        with open(path, "r", errors="replace") as f:
            for lineno, line in enumerate(f, 1):
                m = regex.match(line.rstrip("\n"))
                if not m:
                    continue
                try:
                    pc = int(m.group("pc"), 16)
                    insn = int(m.group("insn"), 16)
                except ValueError:
                    continue
                out.append(Entry(pc, insn, m.group("dis").strip(), lineno))
    except FileNotFoundError:
        sys.exit(f"error: cannot open {name} trace '{path}'")
    return out


def parse_spike(path: str) -> list[Entry]:
    """Prefer --log-commits lines; fall back to -l disassembly lines."""
    out = _scan(path, SPIKE_COMMIT_RE, "Spike")
    if out:
        return out
    out = _scan(path, SPIKE_DISASM_RE, "Spike")
    if not out:
        sys.exit(f"error: no instructions parsed from Spike trace '{path}'.\n"
                 f"       Generate it with:  spike --isa=rv64gcv_zvl128b -l "
                 f"--log-commits prog.elf > spike.log 2>&1")
    print("  note: no --log-commits lines found; using -l disassembly lines,\n"
          "        which are NOT a reliable one-per-instruction record.")
    return out


def parse_rtl(path: str) -> list[Entry]:
    out = _scan(path, RTL_RE, "RTL")
    if not out:
        sys.exit(f"error: no instructions parsed from RTL trace '{path}' "
                 f"-- check the format (--emit-format)")
    return out


def trim_spin(entries: list[Entry]) -> tuple[list[Entry], int]:
    """Drop a trailing run of the same PC.

    Bare-metal programs park in `1: j 1b` after writing tohost, and Spike keeps
    committing that branch until it next polls HTIF -- thousands of times.  Those
    commits are an artefact of the host handshake, not of the program, and the
    RTL will not reproduce their count.  Trimming them is what makes the
    end-of-trace length comparison meaningful.
    """
    if not entries:
        return entries, 0
    last_pc = entries[-1].pc
    i = len(entries)
    while i > 1 and entries[i - 1].pc == last_pc:
        i -= 1
    return entries[:i + 1], len(entries) - (i + 1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spike", nargs="?", help="Spike log (spike -l --log-commits)")
    ap.add_argument("rtl", nargs="?", help="RTL trace in the normalised format")
    ap.add_argument("--context", type=int, default=3,
                    help="instructions of context to show around a mismatch")
    ap.add_argument("--skip", type=int, default=0,
                    help="skip this many leading instructions (boot code)")
    ap.add_argument("--keep-spin", action="store_true",
                    help="do not trim the trailing halt-loop commits")
    ap.add_argument("--emit-format", action="store_true",
                    help="print the expected RTL trace format and exit")
    a = ap.parse_args()

    if a.emit_format:
        print(EMIT_FORMAT)
        return 0
    if not a.spike or not a.rtl:
        ap.error("both spike and rtl trace paths are required")

    gold = parse_spike(a.spike)[a.skip:]
    dut = parse_rtl(a.rtl)[a.skip:]

    trimmed_g = trimmed_d = 0
    if not a.keep_spin:
        gold, trimmed_g = trim_spin(gold)
        dut, trimmed_d = trim_spin(dut)

    print(f"\n  Spike : {len(gold)} instructions  ({a.spike})")
    print(f"  RTL   : {len(dut)} instructions  ({a.rtl})")
    if trimmed_g or trimmed_d:
        print(f"  (trimmed {trimmed_g} / {trimmed_d} trailing spin-loop commits; "
              f"--keep-spin to disable)")
    print()

    for i, (g, d) in enumerate(zip(gold, dut)):
        if g.pc == d.pc and g.insn == d.insn:
            continue

        print(f"  MISMATCH at committed instruction {i}\n")
        lo = max(0, i - a.context)
        for j in range(lo, min(len(gold), i + a.context + 1)):
            mark = ">>" if j == i else "  "
            gj = gold[j]
            dj = dut[j] if j < len(dut) else None
            print(f"  {mark} [{j}] spike: pc={gj.pc:#010x} insn={gj.insn:#010x}  {gj.dis}")
            if dj is not None:
                print(f"  {mark}       rtl: pc={dj.pc:#010x} insn={dj.insn:#010x}  {dj.dis}")
            else:
                print(f"  {mark}       rtl: <trace ended>")
            print()

        if gold[i].pc != dut[i].pc:
            print("  Diagnosis: PCs differ -- control flow diverged.  Look for a\n"
                  "             mispredicted branch, a wrong vsetvli result feeding a\n"
                  "             loop bound, or a trap the RTL took and Spike did not.\n")
        else:
            print("  Diagnosis: same PC, different instruction word -- the RTL fetched\n"
                  "             or decoded something else.  Check instruction memory\n"
                  "             initialisation first.\n")
        return 1

    if len(gold) != len(dut):
        shorter, longer = ("RTL", "Spike") if len(dut) < len(gold) else ("Spike", "RTL")
        n = min(len(gold), len(dut))
        print(f"  MISMATCH in length: first {n} instructions agree, but the {shorter}\n"
              f"  trace ends early ({len(dut)} vs {len(gold)}).\n")
        print("  Diagnosis: the RTL usually stops early because it hung (a vl=0 that\n"
              "             should not be, or a handshake that never completes) or\n"
              "             because the testbench timeout fired.\n")
        return 1

    print(f"  MATCH : {len(gold)} instructions identical.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
