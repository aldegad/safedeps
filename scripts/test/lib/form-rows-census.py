#!/usr/bin/env python3
"""Hold the suite's list of skippable forms to the rows that showed them.

observed   forms.rows: one `form<TAB>row` per counted line; row is empty for a
           row that cannot be skipped, and the skippable row's name otherwise.
declared   what the suite names with form_rows: `form<TAB>row`, one per row.
rows       the skippable rows entered (`name<TAB>ran|skipped`).
required   the forms the oracle requires at least once.

A form that only skippable rows show may be absent from a log whose rows were
skipped, so the suite names it with those rows. That list is written by hand.
Where every skippable row ran, the rows' own records say which forms they show,
so the list must equal them: a form left out hides the loss of a row that was
not skipped, and a row left out of a form's entry does the same. Where a row was
skipped the records are partial, and this says it did not judge.
"""
import argparse
import sys
from pathlib import Path


def tsv(path):
    return [line.split('\t') for line in Path(path).read_text().splitlines() if line]


def main():
    a = argparse.ArgumentParser()
    a.add_argument('--observed', required=True)
    a.add_argument('--declared', required=True)
    a.add_argument('--rows', required=True)
    a.add_argument('--required', required=True)
    a = a.parse_args()
    required = set(a.required.split())
    entered = {}
    for name, state in tsv(a.rows):
        entered.setdefault(name, set()).add(state)
    skipped = sorted(name for name, states in entered.items() if 'skipped' in states)
    if skipped:
        print('# form_rows census: not judged, %d skippable row(s) were skipped in this log: %s' % (len(skipped), ', '.join(skipped)))
        return 0
    producers = {}
    for form, row in tsv(a.observed):
        if form in required:
            producers.setdefault(form, set()).add(row)
    only = {form: rows for form, rows in producers.items() if '' not in rows}
    declared = {}
    for form, row in tsv(a.declared):
        declared.setdefault(form, set()).add(row)
    problems = []
    for form in sorted(set(only) | set(declared)):
        if form not in declared:
            problems.append('%s is shown only by skippable rows (%s) and form_rows does not name it' % (form, ', '.join(sorted(only[form]))))
        elif form not in only:
            why = ('is shown by a row that cannot be skipped' if form in producers else
                   'is not a required form' if form not in required else 'was shown by no row')
            problems.append('form_rows names %s (%s) and it %s' % (form, ', '.join(sorted(declared[form])), why))
        elif declared[form] != only[form]:
            problems.append('%s is shown by %s and form_rows names %s' % (
                form, ', '.join(sorted(only[form])), ', '.join(sorted(declared[form]))))
    ran = sorted(entered)
    if problems:
        for text in problems:
            print('not ok - form_rows census: ' + text, file=sys.stderr)
        print('# the entries these rows give (skippable rows that ran: %s):' % ', '.join(ran), file=sys.stderr)
        for form in sorted(only):
            print('form_rows %s %s' % (form, ' '.join("'%s'" % row for row in sorted(only[form]))), file=sys.stderr)
        return 1
    print('# form_rows census: %d skippable rows ran; %d forms are shown only by them, each named with its rows' % (len(ran), len(only)))
    for form in sorted(only):
        print('#   %-28s %s' % (form, ', '.join(sorted(only[form]))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
