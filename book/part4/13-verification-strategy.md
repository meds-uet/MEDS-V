# Chapter 13 — Verification Strategy

> **Purpose of this chapter.** Establish how the team knows the design is correct. This is
> the chapter that decides whether the project produces a *result* or a demo that works on
> one input.
>
> The central claim: **build the checker before the thing it checks.** Chapter 11 puts
> co-simulation at milestone M2, before any datapath exists, and this chapter explains what
> to build there.

---

## 13.1 Why verification comes first

A vector processor has an unusually large state space. For a single instruction:

```
   ~58 operations
 ×  4 SEW values (8, 16, 32, 64)
 ×  7 LMUL values (1/8 … 8)
 ×  VLMAX+1 values of vl
 ×  2 masked / unmasked
 ×  2 tail policies × 2 mask policies
 ─────────────────────────────────────
   tens of thousands of distinct behaviours, per instruction
```

No team hand-writes that many directed tests. The only tractable approach is to compare
against a reference model that already implements all of it — and that model is **Spike**,
the official RISC-V ISA simulator.

The economics are stark. A directed test costs perhaps twenty minutes to write and covers
one case. A co-simulation harness costs perhaps three days to write and covers every case
any test program exercises, forever. Teams that skip the harness spend the three days
anyway, in the form of one-off debugging, and get no reusable asset for it.

> **⚠️ The failure mode this prevents.** Without a reference comparison, the only signal is
> "the final answer is wrong". That says nothing about *which* of the several thousand
> executed instructions caused it. With a trace diff, the output is "instruction 4127,
> PC 0x800001a4, `vadd.vv` wrote `v3 = 0x...`, expected `0x...`". One costs a day; the
> other costs five minutes.

---

## 13.2 The four layers

Verification runs at four levels, each catching a different class of bug.

| Layer | What it checks | When | Catches |
|---|---|---|---|
| **1. Unit tests** | One module against hand-computed expectations | M1 onward | Logic errors inside a block |
| **2. Co-simulation** | Whole design against Spike, instruction by instruction | **M2 onward** | Integration and semantic errors |
| **3. Architectural tests** | Compliance with the ratified spec | M4 onward | Spec misreadings, corner cases |
| **4. Random stress** | Randomly generated instruction sequences | M5 onward | Hazards, timing, the unimagined |

All four are needed. Layer 2 is the backbone; the others cover its blind spots.

---

## 13.3 Layer 1 — Unit tests

Each block gets a testbench whose exit criteria are the "Done when" lists of Chapter 9.
`verif/tb_vec_csr.sv` is the reference template — 73 checks against the CSR unit — and it
demonstrates three habits worth copying.

**Derive expectations from parameters, never from constants.**

```systemverilog
    do_vsetvli(mk_zimm(3'b000, 3'b000, 1'b1, 1'b1), 64'hFFFF); // e8, m1
    check("e8,m1   VLMAX", int'(vl), VLEN / 8);
```

`VLEN / 8`, not `16`. This is what allows the same testbench to run unmodified at every
configuration:

```
=== tb_vec_csr, same testbench, three VLENs ===
  VLEN=128  === PASS : 73 checks ===
  VLEN=256  === PASS : 77 checks ===
  VLEN=512  === PASS : 85 checks ===
```

The check count rises because the AVL sweep runs to VLMAX+4. A suite written against
constants would have to be rewritten for the M6 configuration sweep — which in practice
means it does not get rewritten, and the sweep does not happen.

**Test the properties that cause hangs, not just wrong answers.**

```systemverilog
    // vl > 0 whenever AVL > 0.  If this ever fails, every stripmine loop hangs.
    for (int unsigned avl = 1; avl <= 40; avl++) begin
      do_vsetvli(mk_zimm(3'b000, 3'b010, 1'b1, 1'b1), XLEN'(avl));
      if (vl == 0) $display("  FAIL  vl == 0 for AVL = %0d", avl);
    end
```

Forty iterations asserting one trivial property. It is the difference between a bug found
in five seconds and a bug found by watching a simulation spin for an hour.

**Test the reporting path, not only the computation.**

```systemverilog
    #1 check("vsetvli returns new vl in rd", int'(set_vl), vlmax32);
```

A unit that computes `vl` correctly but returns the *previous* value in `rd` yields a
machine that is off by one iteration on every loop. `vec_csr.sv` guards this by assigning
`set_vl_o = vl_d` rather than `vl_q` (Chapter 12 §12.3), and this check is what would catch
a regression.

### The per-block unit-test checklist

| Block | Must test |
|---|---|
| Decoder | All ~120 encodings; all six legality checks; 10 000 random words vs. Spike's legality verdict |
| CSR unit | All 2048 `vsetvli` immediates; four AVL cases; `vill` semantics |
| VRF | Every register; sparse byte-enable patterns; the `v0` port; read-during-write |
| Lane | Every op × every SEW; **`vsub` operand order**; shift amounts ≥ SEW; signed/unsigned compares |
| Sequencer | Pass counts for all SEW/LMUL/`vl`; RAW/WAR/WAW; **the `v0` mask hazard**; `vstart` ≠ 0 |
| VLSU | Alignment; masked access generates no bus traffic; `vl` = 0 generates none; backpressure |
| Mask unit | Random masks, all SEW; `vcpop`/`vfirst` including the empty-mask case |

---

## 13.4 Layer 2 — Co-simulation against Spike

The backbone. Run the same program on Spike and on the RTL, and compare the committed
instruction streams.

### Generating the golden trace

```bash
spike --isa=rv64gcv_zvl128b -l --log-commits prog.elf > spike.log 2>&1
```

> **⚠️ Spike emits two different line formats, and the difference matters.**
>
> The `-l` **disassembly** line:
> ```
> core   0: 0x000000008000000a (0x0d02f357) vsetvli t1, t0, e32, m1, ta, ma
> ```
> The `--log-commits` **commit** line — note the privilege level before the PC:
> ```
> core   0: 3 0x000000008000000a (0x0d02f357) x6 0x0000000000000004
> ```
>
> **Use the commit lines.** They are emitted once per retired instruction and carry the
> architectural state change. The disassembly lines are *not* a reliable one-per-instruction
> record: in a measured hello-world trace here, Spike produced **5000 commit lines but only
> 341 disassembly lines**. A checker built on disassembly lines silently compares a fraction
> of the program.

### What the commit line actually contains — and why it is so valuable

For vector instructions, Spike reports far more than the PC. Real captured output:

```
core   0: 3 0x80000052 (0x5208a0d7) e32 m1 l4 v1  0x00000003000000020000000100000000 c8_vstart 0x0
core   0: 3 0x80000056 (0x5e0741d7) e32 m1 l4 v3  0x00000064000000640000006400000064 c8_vstart 0x0
core   0: 3 0x8000006c (0x9611a157) e32 m1 l4 v2  0x0000012c000000c80000006400000000 c8_vstart 0x0
core   0: 3 0x80000070 (0x0207e0a7) e32 m1 l4 c8_vstart 0x0 mem 0x80002210 0x00000000 mem 0x80002214 0x00000001 ...
```

Read that carefully, because it changes what the checker can do:

- **`e32 m1 l4`** — the SEW, LMUL and `vl` in force for that instruction.
- **`v1 0x00000003000000020000000100000000`** — the *entire written vector register*, all
  VLEN bits. (This is `vid.v`, writing `[0,1,2,3]` — the elements are visible, little-endian,
  element 0 in the low bits, exactly as Chapter 4 §4.6 describes.)
- **`mem 0x80002210 0x00000000 …`** — every memory location a store touched.
- **`c8_vstart`** — the `vstart` CSR write at retire.

So the comparison is not limited to control flow. **The checker can verify the full vector
register value and every memory write, per instruction.** That means a wrong tail policy, a
wrong mask, a wrong element position, or a stray memory access is caught *at the
instruction that caused it* — which is the difference between a five-minute fix and a day
of bisection.

> **🎯 Build the checker in two stages.** Stage 1 (M2): compare PC and instruction word —
> enough to catch control-flow divergence and prove the harness works. Stage 2 (M3, when
> the VRF is writable): extend it to compare the written register value. The shipped
> `scripts/cosim_diff.py` implements stage 1 and is structured for stage 2.

### The RTL side

The RTL emits one line per committed instruction:

```systemverilog
    integer trace_fd;
    initial trace_fd = $fopen("rtl.log", "w");
    always_ff @(posedge clk_i)
      if (instr_retire)
        $fwrite(trace_fd, "%08x %08x\n", retire_pc, retire_insn);
```

Three rules, all of which have bitten someone:

1. **Emit on commit, never on issue.** A flushed instruction must not appear.
2. **One line per instruction, not per pass.** A `vadd.vv` spanning eight passes at LMUL=8
   is *one* committed instruction.
3. **Write to a file, not to the same stream as `$display` debug output.**

`python3 scripts/cosim_diff.py --emit-format` prints this contract.

### Running the comparison

```bash
python3 scripts/cosim_diff.py spike.log rtl.log
```

On agreement:

```
  Spike : 341 instructions  (spike.log)
  RTL   : 341 instructions  (rtl.log)
  (trimmed 4659 / 4659 trailing spin-loop commits; --keep-spin to disable)

  MATCH : 341 instructions identical.
```

> **⚠️ Note the trimming, and why it is necessary.** A bare-metal program parks in
> `1: j 1b` after writing `tohost`, and Spike keeps committing that branch until it next
> polls HTIF — **4659 times** in this trace. Those commits are an artefact of the host
> handshake, not of the program, and the RTL will not reproduce their count. Without
> trimming, every end-of-trace length comparison fails for a reason that has nothing to do
> with the design.

On a mismatch, with a single corrupted instruction word injected at index 60:

```
  MISMATCH at committed instruction 60

     [58] spike: pc=0x8000006c insn=0x9611a157  e32 m1 l4 v2 0x0000012c000000c80000006400000000
           rtl: pc=0x8000006c insn=0x9611a157

     [59] spike: pc=0x80000070 insn=0x0207e0a7  e32 m1 l4 mem 0x80002240 0x0000000c ...
           rtl: pc=0x80000070 insn=0x0207e0a7

  >> [60] spike: pc=0x80000074 insn=0x000007c1  x15 0x0000000080002250
  >>       rtl: pc=0x80000074 insn=0x000006c1

     [61] spike: pc=0x80000076 insn=0x021230d7  e32 m1 l4 v1 0x00000013000000120000001100000010
           rtl: pc=0x80000076 insn=0x021230d7

  Diagnosis: same PC, different instruction word -- the RTL fetched
             or decoded something else.  Check instruction memory
             initialisation first.
```

And on a truncated RTL trace — the signature of a hang:

```
  MISMATCH in length: first 200 instructions agree, but the RTL
  trace ends early (200 vs 341).

  Diagnosis: the RTL usually stops early because it hung (a vl=0 that
             should not be, or a handshake that never completes) or
             because the testbench timeout fired.
```

> **🔧 The M2 exit criterion is exactly this.** Take a known-good trace, corrupt one
> instruction, and confirm the comparator reports it at the right index with useful
> context. Then truncate a trace and confirm the length diagnosis fires. **Do not proceed
> to M3 until both work.** A comparator that has never caught a bug is not known to work.

---

## 13.5 Layer 3 — Architectural tests

The RISC-V architectural test suite (`riscv-arch-test`, maintained by RISC-V International)
contains vector tests generated from the specification. Running them provides an external,
citable statement of compliance rather than a self-assessment.

The tests work by signature comparison: each test writes results to a memory region, and
the signature is compared against a reference generated by Spike.

**What they will find**, in rough order of likelihood:

1. Illegal-encoding handling — reserved `vsew`/`vlmul`, misaligned register groups, EMUL
   out of range. Every one of Chapter 9 §9.1's six legality checks is probed.
2. `vill` semantics — that an illegal `vtype` sets `vill` and zeroes the other fields
   rather than trapping.
3. `vstart` ≠ 0 behaviour.
4. Tail and mask policy edge cases.
5. `vl` = 0 — that the instruction becomes a genuine no-op.

> **🎯 Realistic scoping.** MEDS-V v1 implements a subset, so most of the suite will not
> apply. **This is fine, and reporting it honestly is a strength.** The correct claim is:
> "of the N architectural tests covering the `Zve32x` instructions in the documented
> subset, MEDS-V passes M." That is a real compliance statement. "The team pass the RISC-V
> architectural tests" without qualification is not, and a reviewer will ask.
>
> Record which tests are excluded and why, in the same document as the scope contract
> (Appendix E).

---

## 13.6 Layer 4 — Random stress

Directed tests check what the team thought of. Random tests find what nobody thought of —
particularly hazards, which arise from *sequences* rather than individual instructions.

The approach: generate random-but-legal instruction sequences, run on Spike and the RTL,
diff.

```python
# sketch -- scripts/gen_random.py
def random_vector_instruction(rng, sew, lmul):
    op   = rng.choice(SUPPORTED_OPS)
    emul = lmul_regs(lmul)
    vd   = rng.randrange(0, 32, emul)     # respect group alignment
    vs1  = rng.randrange(0, 32, emul)
    vs2  = rng.randrange(0, 32, emul)
    vm   = rng.choice([0, 1])
    if vm == 0 and vd == 0:               # masked ops must not write v0
        vd = emul
    return encode(op, vd, vs1, vs2, vm)
```

**Bias the generator toward the interesting cases**, or it will spend its time on
uninteresting ones:

- back-to-back dependent instructions (hazard coverage),
- `vl` at 0, 1, VLMAX−1, VLMAX,
- masked instructions immediately after a mask-writing comparison (**the `v0` hazard**),
- `vsetvli` changing SEW or LMUL mid-sequence,
- LMUL=8 groups, where a single instruction touches eight registers.

A cheap and high-value variant needs no generator at all: **compile ordinary C at
`-O3 -march=rv64gcv` and let GCC's autovectoriser produce the sequences.** It generates
instruction mixes no human would write, and it is free.

---

## 13.7 Continuous integration

From week 4, every pull request runs:

```yaml
  - make -C verif lint                      # RTL lint, full -Wall
  - make -C verif all                       # all unit testbenches
  - python3 scripts/param_sweep.py          # all VLEN x lane configurations
  - ./scripts/run_cosim_suite.sh            # co-simulation regression
```

The parameter sweep deserves its place in CI even though it looks like a formality.
Chapter 12 §12.4 describes a real bug it caught: a per-byte non-blocking assignment in the
VRF that elaborated fine at VLEN=128 and 512 and **failed at VLEN=1024**. Nothing in a
single-configuration flow would have found it, and it would have surfaced during M6 while
generating the final results — the worst possible time.

**The Friday rule from Chapter 11 §11.5:** the integration build must be green before
anyone goes home. A red build on Friday means Monday starts with debugging instead of
progress.

---

## 13.8 A bug-hunting checklist

When co-simulation reports a mismatch, work down this list. It is ordered by frequency,
based on where these bugs actually cluster.

| Symptom | Look at first |
|---|---|
| Wrong result, right element count | ALU operation select; **`vsub` operand order** (`vs2 − vs1`) |
| Right for SEW=32, wrong for SEW=8/16 | Segmented ALU carry breaks; the subtract carry re-injection |
| Last element(s) wrong | Tail handling — write enables from `vl` |
| Intermittently wrong masked results | **The `v0` RAW hazard in the scoreboard** |
| Wrong after a `vsetvli` that changes LMUL | Register-group addressing; scoreboard group masks |
| Wrong only at LMUL > 1 | Pass count; register offset within the group |
| Hang at the first `vsetvli` | `mstatus.VS` not enabled |
| Hang in a loop | `vl` = 0 returned for non-zero AVL |
| Memory image wrong, registers right | VLSU byte enables; element-to-byte-lane mapping |
| Faults on a valid program | VLSU fetching VLEN bits instead of `vl` elements |
| Off by one iteration everywhere | `vsetvli` returning `vl_q` instead of `vl_d` |

---

## 13.9 What "verified" is allowed to mean

At M7, the honest claim has this shape:

> MEDS-V implements *N* instructions of the `Zve32x` subset documented in Appendix E.
> It passes:
> - *A* unit-test checks across seven blocks;
> - co-simulation against Spike on *B* test programs, comprising *C* committed
>   instructions, at VLEN ∈ {128, 256, 512} and NR_LANES ∈ {1, 2, 4};
> - *D* of the *E* architectural tests applicable to the implemented subset;
> - *F* randomly generated instruction sequences.
>
> Not verified: [the deferred list from Appendix E], and floating point, which is not
> implemented.

Numbers and boundaries. That is a defensible result, and it is far stronger than an
unqualified claim that invites a reviewer to go looking for the gap.

---

## 🔧 Exercises

**13.1** Generate a Spike trace for `examples/01-hello-vector`. Count the commit lines and
the disassembly lines separately. Explain the difference.

**13.2** Reproduce the three `cosim_diff.py` scenarios in §13.4: identical, injected fault,
truncated. This is the M2 exit criterion.

**13.3** From the vector commit lines in §13.4, decode
`e32 m1 l4 v1 0x00000003000000020000000100000000` by hand: which instruction produced it,
and what is in each element?

**13.4** Extend `cosim_diff.py` to parse the written vector register value from Spike's
commit line and compare it against a field in the RTL trace. This is stage 2 from §13.4 and
is a genuine M3 deliverable.

**13.5** Write the directed test for the `v0` mask hazard: `vmseq.vv v0, v1, v2` followed
immediately by `vadd.vv v3, v4, v5, v0.t`. Verify against Spike.

**13.6 (mentors)** Set up CI with the four checks in §13.7 before M2 completes. Verify it
fails when it should by pushing a deliberately broken branch.

---

## Key takeaways

- The state space is too large for directed tests alone. **Compare against Spike.**
- **Build the checker before the thing it checks** — M2, before any datapath exists.
- Four layers: unit tests, co-simulation, architectural tests, random stress. All four are
  needed.
- Unit tests must derive expectations **from parameters, not constants**, or the M6
  configuration sweep becomes a rewrite.
- Use Spike's **`--log-commits` lines, not the `-l` disassembly lines** — in a measured
  trace there were 5000 of the former and only 341 of the latter.
- Spike's vector commit lines carry **SEW, LMUL, `vl`, the full written register value, and
  every memory write** — so the checker can verify data, not just control flow.
- **Trim the trailing spin-loop commits** (4659 in a hello-world trace) or every length
  comparison fails spuriously.
- The M2 exit criterion is that the comparator **catches an injected fault and a
  truncation**. A comparator that has never caught a bug is not known to work.
- Run the parameter sweep in CI — it caught a real VLEN=1024 elaboration bug that no
  single-configuration flow would reveal.
- State compliance with numbers and boundaries, not unqualified claims.

---

*Part IV complete. Next: [Chapter 14 — Workloads](../part5/14-workloads.md)*
