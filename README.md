# BSC Branch / Rule / Method Coverage Instrumentation

## Overview

This repository extends the **Bluespec Compiler (BSC)** with
compile-time instrumentation for **Branch**, **Rule**, and **Method**
coverage. It also includes utilities to process simulation logs and
generate detailed coverage reports.

The workflow consists of the following steps:

1.  Install the instrumentation files.
2.  Rebuild the Bluespec compiler.
3.  Verify the instrumented compiler.
4.  Generate instrumented Verilog.
5.  Verify that probes were inserted.
6.  Build and run the simulator.
7.  Generate the coverage report.
8.  Review the coverage results.

------------------------------------------------------------------------

# Prerequisites

Before using the instrumentation, ensure that you have:

-   A working checkout of the Bluespec Compiler (BSC).
-   Successfully built the original BSC at least once.
-   Python 3 installed.
-   [Verilator](https://verilator.org/) installed (or another supported
    simulator, e.g. VCS).

------------------------------------------------------------------------

# Repository Contents

  ------------------------------------------------------------------------------------
  File                     Destination                    Description
  ------------------------ ------------------------------ ----------------------------
  **ICoverage.hs**         `bsc/src/comp/ICoverage.hs`    Compiler pass that inserts
                                                          Branch, Rule, and Method
                                                          coverage probes.

  **VProbeOnce.hs**        `bsc/src/comp/VProbeOnce.hs`   Post-processes generated
                                                          Verilog so that each probe
                                                          is printed only once per
                                                          simulation.

  **bsc.hs**               `bsc/src/comp/bsc.hs`          Modified compiler driver
                                                          that integrates the
                                                          instrumentation passes.

  **coverage_report.py**   Anywhere                       Generates coverage reports
                                                          by comparing inserted probes
                                                          with simulation logs.

  **examples/**            Anywhere                       A small worked example
                                                          (`ExampleDesign.bsv` +
                                                          testbench) to sanity-check
                                                          your setup end-to-end.
  ------------------------------------------------------------------------------------

------------------------------------------------------------------------

# Instrumentation Overview

The instrumentation inserts three categories of probes.

## Branch Probes

Inserted for:

-   Every `if` / `else`
-   Every `case` arm
-   Every ternary operator (`?:`)

Example:

``` verilog
$display("src/stage3.bsv:PROBE_30_RL_foo_L142_then");
```

## Rule-Fired Probes

Inserted into every rule body and fire only when the rule successfully
commits.

## Method-Fired Probes

Inserted into every fireable Action and ActionValue interface method and
fire only when the method executes.

Each probe is unique within its source file.

------------------------------------------------------------------------

# Installing the Instrumentation

Copy the instrumentation files into your BSC source tree.

``` bash
cp ICoverage.hs  <BSC_ROOT>/src/comp/
cp VProbeOnce.hs <BSC_ROOT>/src/comp/
cp bsc.hs        <BSC_ROOT>/src/comp/
```

The modified `bsc.hs` integrates the instrumentation pipeline:

-   `iInstrumentCoverage` executes after `iSplitIf` and before `iLift`.
-   `instrumentProbeOnce` executes immediately before the generated
    Verilog is written.

Whenever any instrumentation source file is modified, copy the updated
file into the BSC source tree before rebuilding.

------------------------------------------------------------------------

# Building the Instrumented Compiler

From the BSC source directory:

``` bash
cd <BSC_ROOT>/src/comp
make bsc
```

Ensure the compiler completes successfully before proceeding.

------------------------------------------------------------------------

# Verifying the Compiler

Confirm that the newly built compiler is the one you intend to use
before compiling your design.

``` bash
which bsc
bsc -verilog -v      # sanity-check it runs
```

If you have both a stock BSC and an instrumented build on your machine,
make sure your `PATH` points at the instrumented one before continuing.

------------------------------------------------------------------------

## Worked Example: Generating Verilog, Building, and Running

This section walks through the full pipeline end-to-end on the small
example design in `examples/` (`ExampleDesign.bsv` + `tb_example.v`),
so you can confirm your setup works before pointing it at a real
design.

All commands below assume you're in the directory containing
`ExampleDesign.bsv` and `tb_example.v`. The build/run steps use
Verilator as the simulator, since it's free and simple to set up — any
other supported simulator (VCS, Questa, etc.) works the same way, just
swap out that one step.

### Step 1 — Generate instrumented Verilog from the BSV source

``` bash
bsc -verilog ExampleDesign.bsv
```

This produces `mkExample.v` in the current directory. The instrumented
compiler behaves identically to the stock compiler except that it also
inserts probe `$display` statements into the generated Verilog.

> `-g <module>` can be used to pick a specific `(*synthesize*)` module
> if a file defines more than one. It's not needed here since
> `mkExample` is the only synthesize boundary in `ExampleDesign.bsv`.

### Step 2 — Verify probes were inserted

``` bash
grep "PROBE_" mkExample.v
```

You should see lines like:

``` text
$display("ExampleDesign.bsv:PROBE_0_mkExample_RL_process_data_L18_tern_true (data <= 50)");
```

If nothing shows up, the compiler you invoked isn't the instrumented
build — recheck the "Verifying the Compiler" step above.

### Step 3 — Build the simulator

``` bash
verilator --binary -j 0 \
  --top-module tb_example \
  tb_example.v mkExample.v \
  -o sim_example \
  --trace
```

-   `--trace` is only needed if your testbench calls `$dumpvars` and
    you want a VCD for waveform viewing.

**If Verilator fails with an error like:**

``` text
%Error: Cannot find file containing module: 'RegN'
```

it means `mkExample.v` instantiates a BSC Verilog primitive
(`RegN`, `FIFO2`, etc.) that wasn't inlined into the file and instead
needs to be linked in from BSC's own Verilog library. Find that
library on your machine first:

``` bash
echo $BLUESPECDIR                     # check if it's already set
find / -iname "RegN.v" 2>/dev/null    # otherwise locate it manually
```

Then re-run the same Verilator command, but also point `-I` at that
directory and add all of its `.v` files to the file list:

``` bash
verilator --binary -j 0 \
  -I$BLUESPECDIR/Verilog \
  --top-module tb_example \
  tb_example.v mkExample.v $BLUESPECDIR/Verilog/*.v \
  -o sim_example \
  --trace
```

For the small example design in this repo you likely won't hit this —
`mkExample.v` compiles standalone. It tends to become relevant on
larger, real-world designs that use more BSC library modules.

### Step 4 — Run the simulation and capture the log

``` bash
./obj_dir/sim_example > coverage.log
```

If probes execute successfully, `coverage.log` will contain entries
like:

``` text
ExampleDesign.bsv:PROBE_15_mkExample_RL_process_data_L18_RULE_FIRED
ExampleDesign.bsv:PROBE_17_mkExample_put_METHOD_FIRED
```

### Step 5 — Generate the coverage report

``` bash
python3 coverage_report.py \
    --verilog-dir mkExample.v \
    --sim-log coverage.log \
    --show-missing
```

`--verilog-dir` accepts either a single `.v` file (as above, for
quick single-module checks) or a directory to glob `*.v` across (for
multi-file designs — see the next section).

#### Sample output

Running the example through the full pipeline (bsc → Verilator →
`coverage.log` → `coverage_report.py --show-all`) produces a report
like this:

``` text
====================================================================================
ExampleDesign.bsv   (14/19 = 73.7% overall)
====================================================================================
-- Branches: 11 / 15 (73.3%) --
    PROBE_0      FIRED   mkExample_RL_process_data_L18_tern_true
    PROBE_1      MISSED  mkExample_RL_process_data_L18_tern_false
    PROBE_2      MISSED  mkExample_RL_process_data_L18_tern_true
    PROBE_3      FIRED   mkExample_RL_process_data_L18_tern_false
    PROBE_4      MISSED  mkExample_RL_process_data_L18_tern_true
    PROBE_5      FIRED   mkExample_RL_process_data_L18_tern_false
    PROBE_6      MISSED  mkExample_RL_process_data_L18_tern_true
    PROBE_7      FIRED   mkExample_RL_process_data_L18_tern_false
    PROBE_8      FIRED   mkExample_RL_process_data_L18_then
    PROBE_9      FIRED   mkExample_RL_process_data_L18_then
    PROBE_10     FIRED   mkExample_RL_process_data_L18_else
    PROBE_11     FIRED   mkExample_RL_process_data_L18_then
    PROBE_12     FIRED   mkExample_RL_process_data_L18_else
    PROBE_13     FIRED   mkExample_RL_process_data_L18_then
    PROBE_14     FIRED   mkExample_RL_process_data_L18_else
-- Rules: 1 / 2 (50.0%) --
    PROBE_15     FIRED   mkExample_RL_process_data_L18_RULE_FIRED
    PROBE_16     MISSED  mkExample_RL_reset_on_max_L40_RULE_FIRED
-- Methods: 2 / 2 (100.0%) --
    PROBE_17     FIRED   mkExample_put_METHOD_FIRED
    PROBE_18     FIRED   mkExample_get_METHOD_FIRED
====================================================================================
TOTAL   14 / 19 (73.7%)
  Branches       11 / 15     (73.3%)
  Rules           1 / 2      (50.0%)
  Methods         2 / 2      (100.0%)
```

Reading this: the testbench never held `valid`/`counter` long enough
for `counter` to reach 100, so `reset_on_max` never fires (`isEmpty`
isn't instrumented as a method here since it has no side effects —
only `Action`/`ActionValue` methods get `METHOD_FIRED` probes). Several
`tern_true` branches in `process_data` are also missed, because each
`put`/`get` pair is spaced far enough apart that the rule re-fires
multiple times per test step, cycling the ternary condition through
values beyond the one branch the test intended to isolate. This is
exactly the kind of gap the report is meant to surface — see the
[Notes and Limitations](#notes-and-limitations) section for tightening
the testbench to get 1:1 branch isolation.

> The exact probe numbers/labels above will differ slightly depending
> on your bsc version and source line numbers, but the shape of the
> report — Branches / Rules / Methods, each with counts and a
> percentage — is the same for any design.

That's it — you now have a full Branch / Rule / Method coverage report
for the example design. Apply the same five steps to your own `.bsv`
sources to get coverage for a real project.

------------------------------------------------------------------------

# Using the Pipeline on Larger, Multi-File Designs

The same five steps apply; the only differences are scale-related.

### Generating Verilog for a full build

Compile your design exactly as you normally would (e.g. via your
project's existing Makefile/build scripts) — no special flags are
needed for instrumentation, since it's built into the compiler.

### Verifying probe insertion across a build directory

``` bash
grep -R "PROBE_" build/hw/verilog
```

### Running the simulation

Build your simulator exactly as you normally would (Verilator, VCS,
Questa, etc. — whichever your project uses), and save the output to a
log file:

``` bash
./your_sim_binary > simulation.log
```

### Generating the report against a whole directory

``` bash
python3 coverage_report.py \
    --verilog-dir build/hw/verilog \
    --sim-log simulation.log
```

Useful options:

### Multiple simulation logs

``` bash
python3 coverage_report.py \
    --verilog-dir build/hw/verilog \
    --sim-log test1.log \
    --sim-log test2.log \
    --sim-log test3.log
```

### Report a single source file (within a multi-file build dir)

``` bash
python3 coverage_report.py \
    --verilog-dir build/hw/verilog \
    --sim-log simulation.log \
    --file stage3.bsv
```

### Show uncovered probes

``` bash
python3 coverage_report.py \
    --verilog-dir build/hw/verilog \
    --sim-log simulation.log \
    --show-missing
```

### Show all probes

``` bash
python3 coverage_report.py \
    --verilog-dir build/hw/verilog \
    --sim-log simulation.log \
    --show-all
```

### Export CSV

``` bash
python3 coverage_report.py \
    --verilog-dir build/hw/verilog \
    --sim-log simulation.log \
    --csv coverage.csv
```

------------------------------------------------------------------------

# Coverage Report

For each source file, the report contains:

-   Branch Coverage
-   Rule Coverage
-   Method Coverage

Each section reports:

-   Number of inserted probes
-   Number of fired probes
-   Coverage percentage

A grand summary across all source files is also produced.

By default, a Markdown version of the report is written to:

``` text
~/Downloads/coverage_report.md
```

The destination can be changed using:

``` bash
--md-out <path>
```

or disabled with:

``` bash
--no-md
```

------------------------------------------------------------------------

# Notes and Limitations

-   Probe numbering is unique only within each source file.
-   Standard library `.bs` files are also instrumented when applicable.
-   Coverage for rules or methods involving `noinline` functions is
    currently not fully reliable.

------------------------------------------------------------------------

# Troubleshooting

  -----------------------------------------------------------------------
  Problem                   Possible Cause
  ------------------------- ---------------------------------------------
  No `PROBE_` strings in    Instrumentation was not installed correctly
  generated Verilog         or BSC was not rebuilt, or `bsc` on `PATH`
                            is the stock (non-instrumented) build.

  No probe messages during  Simulator was built using stale Verilog or
  simulation                the wrong compiler output.

  Empty coverage report     The simulation log does not correspond to the
                            generated Verilog directory/file.

  Verilator: "Cannot find    Design references BSC Verilog primitives
  file containing module"   that weren't inlined. Add
                            `-I$BLUESPECDIR/Verilog $BLUESPECDIR/Verilog/*.v`
                            to the Verilator command.
  -----------------------------------------------------------------------

------------------------------------------------------------------------

# Complete Workflow

1.  Install the instrumentation files.
2.  Rebuild BSC.
3.  Verify the compiler.
4.  Generate instrumented Verilog. `bsc -verilog ExampleDesign.bsv`
5.  Verify probe insertion. `grep "PROBE_" mkExample.v`
6.  Build the simulator. `verilator --binary -j 0 --top-module tb_example tb_example.v mkExample.v -o sim_example --trace`
7.  Run the simulation. `./obj_dir/sim_example > coverage.log`
8.  Generate the coverage report. `python3 coverage_report.py --verilog-dir mkExample.v --sim-log coverage.log --show-missing`
9.  Review the Branch, Rule, and Method coverage results.
