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
-   A supported simulator (Verilator, VCS, etc.).

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

------------------------------------------------------------------------

# Generating Instrumented Verilog

Compile your Bluespec design exactly as you normally would.

The instrumented compiler behaves identically to the original compiler
except that it inserts additional probe `$display` statements into the
generated Verilog.

------------------------------------------------------------------------

# Verifying Probe Insertion

After generating Verilog, verify that probes were inserted.

``` bash
grep -R "PROBE_" build/hw/verilog
```

If instrumentation is working correctly, the generated Verilog will
contain probe `$display` statements.

------------------------------------------------------------------------

# Running the Simulation

Build your simulator exactly as you normally would.

Run the simulation while saving the output to a log file.

``` bash
./your_sim_binary > simulation.log
```

If probes execute successfully, the log will contain entries similar to:

``` text
src/stage3.bsv:PROBE_30_RL_foo_L142_then
src/stage3.bsv:PROBE_44_METHOD_FIRED
```

------------------------------------------------------------------------

# Generating the Coverage Report

After simulation, generate the coverage report.

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

### Report a single source file

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
  generated Verilog         or BSC was not rebuilt.

  No probe messages during  Simulator was built using stale Verilog or
  simulation                the wrong compiler output.

  Empty coverage report     The simulation log does not correspond to the
                            generated Verilog directory.
  -----------------------------------------------------------------------

------------------------------------------------------------------------

# Complete Workflow

1.  Install the instrumentation files.
2.  Rebuild BSC.
3.  Verify the compiler.
4.  Generate instrumented Verilog.
5.  Verify probe insertion.
6.  Build the simulator.
7.  Run the simulation.
8.  Generate the coverage report.
9.  Review the Branch, Rule, and Method coverage results.
