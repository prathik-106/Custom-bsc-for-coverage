#!/usr/bin/env python3
"""
coverage_report.py
Compares branch-coverage probes inserted by ICoverage.hs (found in
generated Verilog) against probes that actually fired (found in one or
more simulation log files containing $display("PROBE_...") output).

Probe numbering is PER SOURCE FILE (resets to 0 in each .bsv compilation
unit), so probes are keyed on (source_file, full_label) -- NEVER on the
bare numeric id alone, since the same number means different things in
different files.

For each source file, this prints THREE separate sections, in order:
  1. Branches   (_then/_else/_tern_true/_tern_false)
  2. Rules      (_RULE_FIRED)
  3. Methods    (_METHOD_FIRED)
followed by a per-file summary line for each of those three buckets.
"other" (anything not matching a known suffix) is reported separately
too, if present, so nothing silently vanishes.

These are different KINDS of coverage questions ("did this branch get
taken" vs "did this rule ever commit" vs "did this method ever commit")
and are never averaged together into one percentage.

In addition to printing to stdout, this also writes a Markdown copy of
the same report to disk (default: ~/Downloads/coverage_report.md) via
--md-out / --no-md.

Usage:
    python3 coverage_report.py --verilog-dir build/hw/verilog \
        --sim-log /tmp/sim_output.log [--sim-log /tmp/other_test.log ...] \
        [--file stage3.bsv] [--show-missing] [--csv out.csv] \
        [--md-out ~/Downloads/coverage_report.md]

Multiple --sim-log args are unioned together, so you can run this once
against an entire regression suite's logs to get aggregate coverage
across all tests, not just one.
"""

import argparse
import csv
import glob
import os
import re
import sys
from collections import defaultdict
from datetime import datetime

# Matches: <anything>PROBE_<digits>_<label chars>[ <condition text>]
# The label itself is word-chars only (rule/method name + _Lnnn + suffix
# like _then/_else/_tern_true/etc). mkProbeWithCond in ICoverage.hs
# appends a SPACE then the rendered condition text (e.g. "(s03 == 0)")
# after the label for _then/_else/_tern_* probes -- that condition text
# contains spaces, parens, and operator characters, so it must be
# captured as a separate group rather than left outside the word-char
# label match (which silently dropped it entirely before this fix).
# The condition group runs up to the closing quote of the $display
# string, stopping at a literal '"' so it doesn't run past the actual
# display string into trailing Verilog syntax (`);` etc), and also
# stops at '%%' escape sequences cleanly since those are just text.
#
# NOTE: '\.bsv?' (not '\.bsv') -- BSC stdlib source files use the
# extension '.bs' (no trailing 'v'), e.g. GetPut.bs, Connectable.bs,
# DReg.bs. The old '\.bsv' literal silently dropped every probe from
# those files on BOTH sides (inserted-scan of .v files and fired-scan
# of the sim log), so they never appeared as a report section at all --
# not a filtering policy, an accidental exclusion. Confirmed via:
#   grep -l "GetPut.bs:PROBE" build/hw/verilog/*.v
# which matched real instrumented modules (mkccore_axi4.v, mkdmem.v,
# mkimem.v, mkSoc.v).
PROBE_RE = re.compile(
    r'([A-Za-z0-9_./-]+\.bsv?):PROBE_(\d+)_([A-Za-z0-9_]+)')

_CATEGORY_SUFFIXES = [
    ('_RULE_FIRED',   'rule_fired'),
    ('_METHOD_FIRED', 'method_fired'),
    ('_tern_true',    'tern_true'),
    ('_tern_false',   'tern_false'),
    ('_then',         'then'),
    ('_else',         'else'),
]


def categorize(label):
    """Classify a probe label by its known suffix. Falls back to 'other'
    for anything that doesn't match a known suffix, rather than
    mis-bucketing or crashing."""
    for suffix, cat in _CATEGORY_SUFFIXES:
        if label.endswith(suffix):
            return cat
    return 'other'


BRANCH_CATEGORIES = {'then', 'else', 'tern_true', 'tern_false'}

# Order matters here -- this IS the print order: branches, then rules,
# then methods, then anything uncategorized.
BUCKETS = [
    ('Branches', BRANCH_CATEGORIES),
    ('Rules',    {'rule_fired'}),
    ('Methods',  {'method_fired'}),
    ('Other',    {'other'}),
]


def extract_probes(text):
    """Returns a dict: { source_file: set of (probe_num, label) }
    Condition text (if any) is collected separately via extract_conditions
    since the dedup/matching key must stay (num, label) -- the condition
    text is for display only and should never affect whether an inserted
    probe is considered to have fired."""
    result = defaultdict(set)
    for src_file, num, label in PROBE_RE.findall(text):
        result[src_file].add((num, label))
    return result


def merge(into, frm):
    for k, v in frm.items():
        into[k] |= v


def load_text(path):
    with open(path, 'r', errors='replace') as f:
        return f.read()


def bucket_sets(probe_set, categories):
    return {x for x in probe_set if categorize(x[1]) in categories}


def pct(fired, inserted):
    return (100.0 * fired / inserted) if inserted else 0.0


class Reporter:
    """Tees every line of output to both stdout (plain text, unchanged
    from before) and an in-memory Markdown buffer, so the two never
    drift apart -- one code path produces both, instead of duplicating
    the report logic twice (which is what `--csv` accidentally did,
    keeping that one separate since it's structured/tabular already)."""

    def __init__(self):
        self.md_lines = []

    def line(self, text=''):
        print(text)

    def md(self, text=''):
        self.md_lines.append(text)

    def both(self, text=''):
        self.line(text)
        self.md(text)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--verilog-dir', required=True,
                     help='Directory containing generated .v files '
                          '(e.g. build/hw/verilog)')
    ap.add_argument('--sim-log', action='append', required=True,
                     help='Path to a simulation log file. Repeatable for '
                          'multiple test runs (results are unioned).')
    ap.add_argument('--file', default=None,
                     help='Only report on source files matching this '
                          'substring (e.g. "stage3.bsv"). Default: all.')
    ap.add_argument('--show-missing', action='store_true',
                     help='Within each section (Branches/Rules/Methods), '
                          'list only the probes that never fired.')
    ap.add_argument('--show-all', action='store_true',
                     help='Within each section, list EVERY probe with its '
                          'FIRED/MISSED status (not just the missing ones).')
    ap.add_argument('--csv', default=None,
                     help='Write a per-file, per-bucket CSV summary to '
                          'this path.')
    ap.add_argument('--md-out', default='~/Downloads/coverage_report.md',
                     help='Write a Markdown copy of this report to this '
                          'path (default: ~/Downloads/coverage_report.md). '
                          'Use --no-md to skip writing it.')
    ap.add_argument('--no-md', action='store_true',
                     help='Do not write a Markdown report.')
    args = ap.parse_args()

    r = Reporter()

    v_files = glob.glob(f'{args.verilog_dir}/*.v')
    if not v_files:
        print(f'ERROR: no .v files found in {args.verilog_dir}', file=sys.stderr)
        sys.exit(1)

    inserted = defaultdict(set)
    for vf in v_files:
        text = load_text(vf)
        merge(inserted, extract_probes(text))

    if not inserted:
        print('ERROR: no PROBE_ strings found in any generated Verilog. '
              'Was this build actually instrumented?', file=sys.stderr)
        sys.exit(1)

    fired = defaultdict(set)
    for logpath in args.sim_log:
        merge(fired, extract_probes(load_text(logpath)))

    src_files = sorted(inserted.keys())
    if args.file:
        src_files = [f for f in src_files if args.file in f]
        if not src_files:
            print(f'No source files matched "{args.file}". '
                  f'Known files include e.g.: {sorted(inserted.keys())[:5]}',
                  file=sys.stderr)
            sys.exit(1)

    grand_ins = {name: 0 for name, _ in BUCKETS}
    grand_fir = {name: 0 for name, _ in BUCKETS}
    grand_total_ins = 0
    grand_total_fir = 0

    csv_rows = []

    r.md(f'# Coverage Report')
    r.md('')
    r.md(f'_Generated {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}_')
    r.md('')
    r.md(f'- Verilog dir: `{args.verilog_dir}`')
    for logpath in args.sim_log:
        r.md(f'- Sim log: `{logpath}`')
    if args.file:
        r.md(f'- File filter: `{args.file}`')
    r.md('')

    for src in src_files:
        ins_set = inserted[src]
        fir_set = fired.get(src, set()) & ins_set

        n_ins = len(ins_set)
        n_fir = len(fir_set)
        grand_total_ins += n_ins
        grand_total_fir += n_fir

        r.line('=' * 84)
        r.line(f'{src}   ({n_fir}/{n_ins} = {pct(n_fir, n_ins):.1f}% overall)')
        r.line('=' * 84)

        r.md(f'## `{src}`')
        r.md('')
        r.md(f'**Overall: {n_fir} / {n_ins} ({pct(n_fir, n_ins):.1f}%)**')
        r.md('')

        row = [src, n_ins, n_fir, f'{pct(n_fir, n_ins):.1f}']

        for name, categories in BUCKETS:
            b_ins = bucket_sets(ins_set, categories)
            b_fir = bucket_sets(fir_set, categories)
            grand_ins[name] += len(b_ins)
            grand_fir[name] += len(b_fir)
            row += [len(b_ins), len(b_fir), f'{pct(len(b_fir), len(b_ins)):.1f}']

            if not b_ins:
                continue  # nothing in this bucket for this file

            b_pct = pct(len(b_fir), len(b_ins))
            r.line(f'\n-- {name}: {len(b_fir)} / {len(b_ins)} ({b_pct:.1f}%) --')

            r.md(f'### {name}: {len(b_fir)} / {len(b_ins)} ({b_pct:.1f}%)')
            r.md('')

            ordered = sorted(b_ins, key=lambda x: int(x[0]))

            rows_to_emit = None
            if args.show_all:
                rows_to_emit = ordered
            elif args.show_missing:
                rows_to_emit = [x for x in ordered if x not in b_fir]

            if rows_to_emit is not None:
                if rows_to_emit:
                    r.md('| Probe | Status | Label |')
                    r.md('|---|---|---|')
                    for num, label in rows_to_emit:
                        status = 'FIRED' if (num, label) in b_fir else 'MISSED'
                        if args.show_missing and status == 'FIRED':
                            continue
                        tag = 'FIRED ' if status == 'FIRED' else 'MISSED'
                        if args.show_all:
                            r.line(f'    PROBE_{num:<6} {tag}  {label}')
                        else:
                            r.line(f'    MISSING  PROBE_{num}_{label}')
                        r.md(f'| `PROBE_{num}` | {status} | `{label}` |')
                    r.md('')
                else:
                    r.line('    (all fired)')
                    r.md('_(all fired)_')
                    r.md('')

        r.line()
        csv_rows.append(row)

    r.line('=' * 84)
    overall_pct = pct(grand_total_fir, grand_total_ins)
    r.line(f'TOTAL   {grand_total_fir} / {grand_total_ins} ({overall_pct:.1f}%)')

    r.md('## TOTAL')
    r.md('')
    r.md(f'**{grand_total_fir} / {grand_total_ins} ({overall_pct:.1f}%)**')
    r.md('')
    r.md('| Bucket | Fired | Inserted | Coverage |')
    r.md('|---|---|---|')

    for name, _ in BUCKETS:
        ins_n = grand_ins[name]
        if not ins_n:
            continue
        fir_n = grand_fir[name]
        r.line(f'  {name:<10} {fir_n:>6} / {ins_n:<6} ({pct(fir_n, ins_n):.1f}%)')
        r.md(f'| {name} | {fir_n} | {ins_n} | {pct(fir_n, ins_n):.1f}% |')

    if args.csv:
        header = ['source_file', 'inserted', 'fired', 'coverage_pct']
        for name, _ in BUCKETS:
            header += [f'{name.lower()}_inserted', f'{name.lower()}_fired',
                       f'{name.lower()}_coverage_pct']
        with open(args.csv, 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(csv_rows)
            total_row = ['TOTAL', grand_total_ins, grand_total_fir, f'{overall_pct:.1f}']
            for name, _ in BUCKETS:
                total_row += [grand_ins[name], grand_fir[name],
                               f'{pct(grand_fir[name], grand_ins[name]):.1f}']
            w.writerow(total_row)
        print(f'\nCSV written to {args.csv}')

    if not args.no_md:
        md_path = os.path.expanduser(args.md_out)
        os.makedirs(os.path.dirname(md_path), exist_ok=True)
        with open(md_path, 'w') as f:
            f.write('\n'.join(r.md_lines) + '\n')
        print(f'\nMarkdown report written to {md_path}')


if __name__ == '__main__':
    main()
