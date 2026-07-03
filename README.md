# BSC Branch/Rule/Method Coverage Instrumentation Guide

This guide explains every step required to build an instrumented
Bluespec compiler, generate instrumented Verilog, run a simulation, and
produce a coverage report.

## End-to-end workflow

1.  Install instrumentation files.
2.  Rebuild `bsc`.
3.  Verify the new compiler.
4.  Compile your Bluespec design to Verilog.
5.  Verify probes were inserted.
6.  Build the simulator.
7.  Run the simulator and save the log.
8.  Generate the coverage report.
9.  Review Branch/Rule/Method coverage.

------------------------------------------------------------------------

## Prerequisites

-   A working checkout of the Bluespec Compiler (BSC).
-   A successful normal BSC build before adding instrumentation.
-   Python 3 available.
-   A simulator (Verilator, VCS, or another supported simulator).

------------------------------------------------------------------------

# BSC Branch/Rule/Method Coverage Instrumentation

This adds compile-time coverage instrumentation to `bsc` (the Bluespec
compiler), plus a script to turn simulation logs into a coverage report.

## What's new

Three files:

  ------------------------------------------------------------------------------------
  File                    Where it goes                  What it does
  ----------------------- ------------------------------ -----------------------------
  `ICoverage.hs`          `bsc/src/comp/ICoverage.hs`    New compiler pass. Walks
                                                         every rule body and every
                                                         `Action`/`ActionValue`
                                                         interface method body and
                                                         inserts a
                                                         `$display("PROBE_<n>_...")`
                                                         at each reachable decision
                                                         point.

  `VProbeOnce.hs`         `bsc/src/comp/VProbeOnce.hs`   Post-processes the generated
                                                         Verilog text so every probe
                                                         fires **at most once per
                                                         simulation run** (adds a
                                                         `probe_fired_N` latch around
                                                         each `$display`).

  `bsc.hs`                `bsc/src/comp/bsc.hs`          Replace the already existing
                                                         bsc.hs with this file.

  `coverage_report.py`    anywhere (run from your shell) Diffs "probes inserted into
                                                         the generated Verilog"
                                                         against "probes that actually
                                                         fired in a sim log" and
                                                         prints/writes a coverage
                                                         report.
  ------------------------------------------------------------------------------------

### What gets instrumented

For every rule and every fireable interface method, `ICoverage.hs`
inserts:

-   **Branch probes** --- one per `if`/`else`/`case`-arm and per ternary
    (`_then`, `_else`, `_tern_true`, `_tern_false`).
-   **Rule-fired probes** (`_RULE_FIRED`) --- fires only on cycles the
    rule actually commits (it's joined onto the rule body the same way
    the branch probes are, so it inherits the "only counts if scheduled
    to fire" semantics for free).
-   **Method-fired probes** (`_METHOD_FIRED`) --- same idea, for
    methods.

Each probe is globally unique *within its source file* (numbering resets
per `.bsv`/`.bs` compilation unit), and every probe label is prefixed
with its source file, e.g.:

    $display("src/stage3.bsv:PROBE_30_RL_foo_L142_then");

`VProbeOnce.hs` then rewrites that into a self-latching form so it
prints once instead of flooding your log every cycle the branch is
re-taken:

``` verilog
if (!probe_fired_30) begin
    $display("src/stage3.bsv:PROBE_30_RL_foo_L142_then");
    probe_fired_30 <= 1;
end
```

## Building bsc with the instrumentation

1.  Copy the new files into your `bsc` checkout:

    ``` bash
    cp ICoverage.hs   ~/Downloads/bsc/src/comp/ICoverage.hs
    cp VProbeOnce.hs  ~/Downloads/bsc/src/comp/VProbeOnce.hs
    cp bsc.hs         ~/Downloads/bsc/src/comp/bsc.hs
    ```

    (adjust `~/Downloads/bsc` if your checkout lives elsewhere).

2.  Apply the `bsc.hs` changes (either copy the provided `bsc.hs` over
    the existing one, as above, or apply just the diff --- both the
    import lines and the two pipeline hook-ins are called out in the
    comments at the bottom of `ICoverage.hs` and the top of
    `VProbeOnce.hs` if you'd rather patch by hand):

    -   `iInstrumentCoverage` runs right after `iSplitIf` and before
        `iLift`.
    -   `instrumentProbeOnce` runs on the final Verilog string, right
        before it's written to disk.

3.  Rebuild `bsc` **from `src/comp`, not the repo root**:

    ``` bash
    cd ~/Downloads/bsc/src/comp
    sudo make bsc
    ```

    Every time you change any of `ICoverage.hs` / `VProbeOnce.hs` /
    `bsc.hs`, re-run the `cp` step for that file *before* rebuilding ---
    `make bsc` picks up whatever's already sitting in `src/comp`, it
    won't pull from wherever you keep your working copies:

    ``` bash
    cp ICoverage.hs ~/Downloads/bsc/src/comp/ICoverage.hs && \
    cd ~/Downloads/bsc/src/comp && make bsc
    ```

## Running an instrumented build

Nothing changes about how you invoke `bsc` or your simulator --- the
instrumented compiler just emits extra `$display` lines. Practically:

1.  Build your design's Verilog with the instrumented `bsc`. This is
    what plants the `PROBE_` calls in `build/hw/verilog/*.v`.

2.  Run your simulation(s) as normal (Verilator, VCS, whatever), making
    sure `$display` output is going somewhere you can grab --- redirect
    stdout to a log file, e.g.:

    ``` bash
    ./your_sim_binary > /tmp/sim_output.log
    ```

    Any probes that fire will show up as plain lines in that log.

## Generating a coverage report

Once you have (a) the generated Verilog directory and (b) one or more
simulation log files, run:

``` bash
python3 coverage_report.py \
    --verilog-dir build/hw/verilog \
    --sim-log /tmp/sim_output.log
```

That's the minimal invocation. Useful variations:

-   **Multiple test runs, aggregated together** --- pass `--sim-log`
    multiple times; results are unioned so you get coverage across an
    entire regression suite, not just one run:

    ``` bash
    python3 coverage_report.py \
        --verilog-dir build/hw/verilog \
        --sim-log /tmp/test1.log \
        --sim-log /tmp/test2.log \
        --sim-log /tmp/test3.log
    ```

-   **Just one source file** --- filter by substring:

    ``` bash
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log --file stage3.bsv
    ```

-   **See what's still missing**:

    ``` bash
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log --show-missing
    ```

-   **See every single probe with FIRED/MISSED status**:

    ``` bash
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log --show-all
    ```

-   **Also get a CSV** (per-file, per-bucket summary, handy for
    spreadsheets/CI):

    ``` bash
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log --csv coverage.csv
    ```

### What the report looks like

For each source file, it prints three separate sections in order ---
**Branches**, **Rules**, **Methods** --- each with its own
fired/inserted count and percentage (these are deliberately never
averaged together, since "did this branch get taken" and "did this rule
ever commit" are different questions). Anything that doesn't match a
known probe suffix is bucketed as **Other** rather than silently
dropped. A grand total across all files closes out the report.

By default the script also writes a Markdown copy of the same report to
`~/Downloads/coverage_report.md` (change the destination with
`--md-out <path>`, or skip it with `--no-md`).

## A couple of things worth knowing

-   Probe numbers are **per source file**, not global --- the same
    number means different things in `stage3.bsv` vs. `mkSoC.bsv`. The
    report script always keys on `(source_file, label)`, never on the
    bare number, so this is handled correctly for you; just don't try to
    compare raw `PROBE_N` numbers across files yourself.
-   BSC standard-library files use the `.bs` extension (no trailing `v`)
    --- e.g. `GetPut.bs`, `Connectable.bs`. Both the instrumentation
    pass and the report script handle `.bs` and `.bsv` alike, so probes
    coming from stdlib code you depend on (via inlined rules/methods)
    will show up as their own section too.
-   Coverage for rules/methods that call `noinline` functions is not
    currently reliable --- treat any coverage numbers touching those
    paths as suspect until this is fixed.# BSC Branch/Rule/Method
    Coverage Instrumentation

This adds compile-time coverage instrumentation to `bsc` (the Bluespec
compiler), plus a script to turn simulation logs into a coverage report.

## What's new

Three files:

  ------------------------------------------------------------------------------------
  File                    Where it goes                  What it does
  ----------------------- ------------------------------ -----------------------------
  `ICoverage.hs`          `bsc/src/comp/ICoverage.hs`    New compiler pass. Walks
                                                         every rule body and every
                                                         `Action`/`ActionValue`
                                                         interface method body and
                                                         inserts a
                                                         `$display("PROBE_<n>_...")`
                                                         at each reachable decision
                                                         point.

  `VProbeOnce.hs`         `bsc/src/comp/VProbeOnce.hs`   Post-processes the generated
                                                         Verilog text so every probe
                                                         fires **at most once per
                                                         simulation run** (adds a
                                                         `probe_fired_N` latch around
                                                         each `$display`).

  `bsc.hs`                `bsc/src/comp/bsc.hs`          Replace the already existing
                                                         bsc.hs with this file.

  `coverage_report.py`    anywhere (run from your shell) Diffs "probes inserted into
                                                         the generated Verilog"
                                                         against "probes that actually
                                                         fired in a sim log" and
                                                         prints/writes a coverage
                                                         report.
  ------------------------------------------------------------------------------------

### What gets instrumented

For every rule and every fireable interface method, `ICoverage.hs`
inserts:

-   **Branch probes** --- one per `if`/`else`/`case`-arm and per ternary
    (`_then`, `_else`, `_tern_true`, `_tern_false`).
-   **Rule-fired probes** (`_RULE_FIRED`) --- fires only on cycles the
    rule actually commits (it's joined onto the rule body the same way
    the branch probes are, so it inherits the "only counts if scheduled
    to fire" semantics for free).
-   **Method-fired probes** (`_METHOD_FIRED`) --- same idea, for
    methods.

Each probe is globally unique *within its source file* (numbering resets
per `.bsv`/`.bs` compilation unit), and every probe label is prefixed
with its source file, e.g.:

    $display("src/stage3.bsv:PROBE_30_RL_foo_L142_then");

`VProbeOnce.hs` then rewrites that into a self-latching form so it
prints once instead of flooding your log every cycle the branch is
re-taken:

``` verilog
if (!probe_fired_30) begin
    $display("src/stage3.bsv:PROBE_30_RL_foo_L142_then");
    probe_fired_30 <= 1;
end
```

## Building bsc with the instrumentation

1.  Copy the two new files into your `bsc` checkout:

    ``` bash
    cp ICoverage.hs   bsc/src/comp/ICoverage.hs
    cp VProbeOnce.hs  bsc/src/comp/VProbeOnce.hs
    ```

2.  Apply the `bsc.hs` changes (either copy the provided `bsc.hs` over
    the existing one, or apply just the diff --- both the import lines
    and the two pipeline hook-ins are called out in the comments at the
    bottom of `ICoverage.hs` and the top of `VProbeOnce.hs` if you'd
    rather patch by hand):

    -   `iInstrumentCoverage` runs right after `iSplitIf` and before
        `iLift`.
    -   `instrumentProbeOnce` runs on the final Verilog string, right
        before it's written to disk.

3.  Rebuild `bsc` as usual (`make` from the `bsc` root, or however your
    tree normally builds).

## Running an instrumented build

Nothing changes about how you invoke `bsc` or your simulator --- the
instrumented compiler just emits extra `$display` lines. Practically:

1.  Build your design's Verilog with the instrumented `bsc`. This is
    what plants the `PROBE_` calls in `build/hw/verilog/*.v`.

2.  Run your simulation(s) as normal (Verilator, VCS, whatever), making
    sure `$display` output is going somewhere you can grab --- redirect
    stdout to a log file, e.g.:

    ``` bash
    ./your_sim_binary > /tmp/sim_output.log
    ```

    Any probes that fire will show up as plain lines in that log.

## Generating a coverage report

Once you have (a) the generated Verilog directory and (b) one or more
simulation log files, run:

``` bash
python3 coverage_report.py \
    --verilog-dir build/hw/verilog \
    --sim-log /tmp/sim_output.log
```

That's the minimal invocation. Useful variations:

-   **Multiple test runs, aggregated together** --- pass `--sim-log`
    multiple times; results are unioned so you get coverage across an
    entire regression suite, not just one run:

    ``` bash
    python3 coverage_report.py \
        --verilog-dir build/hw/verilog \
        --sim-log /tmp/test1.log \
        --sim-log /tmp/test2.log \
        --sim-log /tmp/test3.log
    ```

-   **Just one source file** --- filter by substring:

    ``` bash
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log --file stage3.bsv
    ```

-   **See what's still missing**:

    ``` bash
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log --show-missing
    ```

-   **See every single probe with FIRED/MISSED status**:

    ``` bash
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log --show-all
    ```

-   **Also get a CSV** (per-file, per-bucket summary, handy for
    spreadsheets/CI):

    ``` bash
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log --csv coverage.csv
    ```

### What the report looks like

For each source file, it prints three separate sections in order ---
**Branches**, **Rules**, **Methods** --- each with its own
fired/inserted count and percentage (these are deliberately never
averaged together, since "did this branch get taken" and "did this rule
ever commit" are different questions). Anything that doesn't match a
known probe suffix is bucketed as **Other** rather than silently
dropped. A grand total across all files closes out the report.

By default the script also writes a Markdown copy of the same report to
`~/Downloads/coverage_report.md` (change the destination with
`--md-out <path>`, or skip it with `--no-md`).

## A couple of things worth knowing

-   Probe numbers are **per source file**, not global --- the same
    number means different things in `stage3.bsv` vs. `mkSoC.bsv`. The
    report script always keys on `(source_file, label)`, never on the
    bare number, so this is handled correctly for you; just don't try to
    compare raw `PROBE_N` numbers across files yourself.
-   BSC standard-library files use the `.bs` extension (no trailing `v`)
    --- e.g. `GetPut.bs`, `Connectable.bs`. Both the instrumentation
    pass and the report script handle `.bs` and `.bsv` alike, so probes
    coming from stdlib code you depend on (via inlined rules/methods)
    will show up as their own section too.
-   Coverage for rules/methods that call `noinline` functions is not
    currently reliable --- treat any coverage numbers touching those
    paths as suspect until this is fixed.

------------------------------------------------------------------------

# Verifying each stage

## 1. Verify the compiler build

After `make bsc`, ensure the build completed without errors and that the
generated compiler executable is the one you intend to use.

## 2. Verify probes were inserted

After generating Verilog:

``` bash
grep -R "PROBE_" build/hw/verilog
```

If instrumentation worked, the generated Verilog will contain probe
`$display` statements.

## 3. Build the simulator

Build your simulator exactly as you normally would for your project. The
instrumentation does not change the simulator build process.

## 4. Generate a simulation log

Run the simulator while redirecting stdout:

``` bash
./your_sim_binary > simulation.log
```

Verify the log contains entries similar to:

``` text
src/stage3.bsv:PROBE_30_RL_foo_L142_then
src/stage3.bsv:PROBE_44_METHOD_FIRED
```

If no probe messages appear, verify that the instrumented compiler
generated the Verilog and that you rebuilt the simulator using the new
Verilog.

## 5. Generate the coverage report

``` bash
python3 coverage_report.py --verilog-dir build/hw/verilog --sim-log simulation.log
```

The report summarizes: - Branch coverage - Rule coverage - Method
coverage - Overall totals

## Troubleshooting

-   No PROBE strings in Verilog: instrumentation pass was not applied or
    BSC was not rebuilt.
-   No probe messages in simulation: simulator was built from stale
    Verilog or log redirection captured the wrong output.
-   Empty coverage report: ensure the Verilog directory and simulation
    log correspond to the same compiled design.

This completes the full workflow from compiler instrumentation through
coverage report generation.
