#!/usr/bin/env python3
"""Every expansion a bash script makes outside double quotes, and what bash
does to its value there.

    unquoted.py <script>

Prints one line per expansion, `LINE CONTEXT TEXT`, in the order of the
script. A script it cannot read to its end (a quote, a substitution, a
${...}, an arithmetic expansion or a heredoc left open) is an error: it says
why on stderr and exits 2, and prints no shorter list.

It reads the shapes the queue runner scripts/ci/slot.sh and the scripts
around it use, not every shape bash accepts. A trap's body and the script of
bash -c or sh -c are commands too, and are read as such when written as one
word in single quotes. Commands it cannot read from the text alone are an
error as well: eval, source and ., and such a body or script written in
double quotes, where its expansions are made once before it is read again.

Where bash splits the value into words and expands the globs in each word:
  arg        a word of a simple command
  for-list   a word after `for NAME in`
  array      an element of an array literal NAME=( ... )
  redirect   the target of a redirection (a split there is an error)
Where bash 3.2 splits the value and joins the words with one blank, and
bash 4.4 and later do not, and neither expands globs:
  here-str   the word after <<<
Where the value is a pattern, so a glob character in it matches:
  pattern    the right side of == != = in [[ ]], or a case pattern
  regex      the right side of =~ in [[ ]]
Where bash neither splits nor globs the value:
  assign     the value of NAME=, NAME+=, or of local, declare, export,
             readonly and typeset
  test       an operand of [[ ]] other than those above
  case-word  the word after `case`
An arithmetic expansion $(( )) is listed in the context it stands in, as $$
is. What is inside it, or inside (( )) and for (( )), is read as
arithmetic, which bash neither splits nor globs, so it is not listed. In
double quotes and in a heredoc, a $ before a quote is a plain character.
"""
import re
import sys

ASSIGN = re.compile(r'[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=')
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
REDIRECT = re.compile(r'[0-9]*(<<<|<<-|<<|&>>|&>|>>|>&|<&|<>|>\||>|<)')
DECLARE = {'local', 'declare', 'export', 'readonly', 'typeset'}
STARTS = {'if', 'then', 'else', 'elif', 'do', 'while', 'until', '{', '!',
          'time', 'fi', 'done', '}', 'esac', 'function'}
SPECIAL = set('@*#?$!-0123456789')
SHELLS = {'bash', 'sh', 'dash', 'zsh', 'ksh'}
UNFOLLOWED = {'eval', 'source', '.'}
SCRIPT_FLAG = re.compile(r'-[A-Za-z]*c[A-Za-z]*')
TEST_SIDES = {'==': 'pattern', '!=': 'pattern', '=': 'pattern', '=~': 'regex'}


class Unreadable(Exception):
    pass


class Lexer:
    def __init__(self, text, line0=0):
        self.s, self.n, self.line0 = text, len(text), line0
        self.out = []
        self.heredocs = []  # (delimiter, quoted, strip tabs)

    def line(self, i):
        return self.line0 + self.s.count('\n', 0, i) + 1

    def open_at(self, i, what):
        raise Unreadable(f'line {self.line(i)}: {what} is not closed')

    def report(self, i, j, context):
        self.out.append((self.line(i), context, self.s[i:j].replace('\n', '\\n')))

    # --- expansions ---------------------------------------------------------
    def dollar(self, i, context):
        """i at '$'. Reports the expansion in context (None when quoted) and
        returns the index after it."""
        s = self.s
        if i + 1 >= self.n:
            return i + 1
        c = s[i + 1]
        if c == '(':
            if s.startswith('((', i + 1):
                j = self.arith(i + 3)
                if context:
                    self.report(i, j, context)
                return j
            j = self.commands(i + 2, ')')
        elif c == '{':
            j = self.braced(i + 2)
        elif c == "'":
            return self.ansi(i + 2)
        elif c == '"':
            return self.dquote(i + 2)
        elif c in SPECIAL:
            j = i + 2
        else:
            m = NAME.match(s, i + 1)
            if not m:
                return i + 1
            j = m.end()
        if context:
            self.report(i, j, context)
        return j

    def braced(self, k):
        """k after '${'; returns the index after the matching '}'."""
        start, depth = k - 2, 1
        while k < self.n:
            c = self.s[k]
            if c == '\\':
                k += 2
            elif c == "'":
                end = self.s.find("'", k + 1)
                if end < 0:
                    self.open_at(k, 'a single quote')
                k = end + 1
            elif c == '"':
                k = self.dquote(k + 1)
            elif c == '$' and self.s.startswith(('$(', '${'), k):
                k = self.dollar(k, None)
            else:
                if c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth == 0:
                        return k + 1
                k += 1
        self.open_at(start, '${')

    def arith(self, k):
        """k after '$((' or '(('; returns the index after the closing '))'."""
        start, depth = k - 2, 0
        while k < self.n:
            c = self.s[k]
            if c == '(':
                depth += 1
            elif c == ')':
                if depth == 0 and self.s.startswith('))', k):
                    return k + 2
                depth -= 1
            elif c == '$' and self.s.startswith('$(', k) and not self.s.startswith('$((', k):
                k = self.commands(k + 2, ')')
                continue
            k += 1
        self.open_at(start, 'an arithmetic expansion')

    def ansi(self, k):
        start = k - 2
        while k < self.n:
            if self.s[k] == '\\':
                k += 2
            elif self.s[k] == "'":
                return k + 1
            else:
                k += 1
        self.open_at(start, "a $'...' quote")

    def dquote(self, k):
        """k after an opening double quote. Its expansions are quoted, and a
        command substitution inside it is a command list of its own."""
        start = k - 1
        while k < self.n:
            c = self.s[k]
            if c == '\\':
                k += 2
            elif c == '"':
                return k + 1
            elif c == '$' and self.s[k + 1:k + 2] in ('"', "'"):
                k += 1
            elif c == '$':
                k = self.dollar(k, None)
            elif c == '`':
                k = self.backtick(k + 1)
            else:
                k += 1
        self.open_at(start, 'a double quote')

    def backtick(self, k):
        start = k
        while k < self.n and self.s[k] != '`':
            k += 2 if self.s[k] == '\\' else 1
        if k >= self.n:
            self.open_at(start - 1, 'a backquote')
        inner = self.s[start:k].replace('\\`', '`').replace('\\$', '$').replace('\\\\', '\\')
        sub = Lexer(inner, self.line(start) - 1)
        sub.commands(0, None)
        self.out.extend(sub.out)
        return k + 1

    def payload(self, at, w, words):
        """w, read at at, is a word of the simple command whose words so far
        are words. A trap's first word and the word after bash -c are
        commands, read here when they are one single-quoted word."""
        body = words == ['trap']
        script = (len(words) >= 2 and SCRIPT_FLAG.fullmatch(words[-1])
                  and words[-2].rsplit('/', 1)[-1] in SHELLS)
        if not (body or script):
            return
        what = "a trap's body" if body else f'the script of {words[-2]} {words[-1]}'
        if len(w) >= 2 and w[0] == "'" and w[-1] == "'" and "'" not in w[1:-1]:
            sub = Lexer(w[1:-1], self.line(at) - 1)
            sub.commands(0, None)
            self.out.extend(sub.out)
        elif any(q in w for q in '"$`\\'):
            raise Unreadable(f'line {self.line(at)}: {what} is not one single-quoted word, '
                             'so what it runs is not in the text')

    # --- words --------------------------------------------------------------
    def word(self, k, context):
        """Reads one word from k and reports its expansions outside double
        quotes in context. Returns (end, text)."""
        start = k
        while k < self.n:
            c = self.s[k]
            if c in ' \t\n;&|()<>':
                break
            if c == '\\':
                k += 2
            elif c == "'":
                end = self.s.find("'", k + 1)
                if end < 0:
                    self.open_at(k, 'a single quote')
                k = end + 1
            elif c == '"':
                k = self.dquote(k + 1)
            elif c == '`':
                k = self.backtick(k + 1)
            elif c == '$':
                k = self.dollar(k, context)
            else:
                k += 1
        return k, self.s[start:k]

    def blank(self, k, newline=False):
        """Skips blanks, line continuations and comments from k."""
        while k < self.n:
            c = self.s[k]
            if c in ' \t' or (newline and c == '\n'):
                k += 1
            elif self.s.startswith('\\\n', k):
                k += 2
            elif c == '#' and (k == 0 or self.s[k - 1] in ' \t\n;&|()'):
                while k < self.n and self.s[k] != '\n':
                    k += 1
            else:
                break
        return k

    def heredoc_bodies(self, k):
        """k after the newline that ends a line with heredocs on it."""
        for delimiter, quoted, strip in self.heredocs:
            start = k
            while True:
                if k >= self.n:
                    self.open_at(start, f'a heredoc ({delimiter})')
                e = self.s.find('\n', k)
                e = self.n if e < 0 else e
                text = self.s[k:e]
                if (text.lstrip('\t') if strip else text) == delimiter:
                    k = e + 1
                    break
                j = k
                while not quoted and j < e:
                    if self.s[j] == '\\':
                        j += 2
                    elif self.s[j] == '$' and self.s[j + 1:j + 2] in ('"', "'"):
                        j += 1
                    elif self.s[j] == '$':
                        j = self.dollar(j, None)
                    elif self.s[j] == '`':
                        j = self.backtick(j + 1)
                    else:
                        j += 1
                k = e + 1
        self.heredocs = []
        return k

    def assignment(self, k):
        """k at NAME= or NAME+=; returns the index after its value."""
        j = ASSIGN.match(self.s, k).end()
        if self.s.startswith('(', j):
            return self.array(j + 1)
        return self.word(j, 'assign')[0]

    def array(self, k):
        start = k - 1
        while k < self.n:
            k = self.blank(k, newline=True)
            if k < self.n and self.s[k] == ')':
                return k + 1
            j, _ = self.word(k, 'array')
            k = j if j > k else k + 1
        self.open_at(start, 'an array literal')

    def commands(self, k, close):
        """Reads a command list until close (')') or the end (None). Returns
        the index after close."""
        start = k
        state = 'start'
        side = ''
        words = []
        while True:
            k = self.blank(k)
            if k >= self.n:
                if close:
                    self.open_at(start - 1, 'a command substitution or subshell')
                if self.heredocs:
                    self.open_at(k, f'a heredoc ({self.heredocs[0][0]})')
                return k
            c = self.s[k]
            if c == '\n':
                k = self.heredoc_bodies(k + 1) if self.heredocs else k + 1
                if state in ('args', 'for-list', 'declare'):
                    state = 'start'
                elif state == 'for-name':
                    state = 'for-in'
                continue
            if close and c == close and state != 'case-pattern':
                return k + 1
            if state == 'case-pattern':
                if c == ')':
                    state = 'start'
                    k += 1
                elif c in '|(':
                    k += 1
                else:
                    k, w = self.word(k, 'pattern')
                    if w == 'esac':
                        state = 'args'
                continue
            if self.s.startswith(';;', k):
                k += 3 if self.s.startswith(';;&', k) else 2
                state = 'case-pattern'
                continue
            if self.s.startswith(';&', k):
                k += 2
                state = 'case-pattern'
                continue
            if c in ';&|':
                k += 1
                if state != 'case-in':
                    state = 'start'
                continue
            if c == '(':
                if state in ('start', 'for-name') and self.s.startswith('((', k):
                    k = self.arith(k + 2)
                    state = 'args'
                else:
                    k = self.commands(k + 1, ')')
                continue
            if c == ')':
                k += 1
                continue
            m = REDIRECT.match(self.s, k)
            if m and state != 'test':
                op = m.group(1)
                k = self.blank(m.end())
                if op in ('<<', '<<-'):
                    k, w = self.word(k, None)
                    quoted = any(q in w for q in '\'"\\')
                    for q in '\'"\\':
                        w = w.replace(q, '')
                    self.heredocs.append((w, quoted, op == '<<-'))
                else:
                    k, _ = self.word(k, 'here-str' if op == '<<<' else 'redirect')
                if state == 'start':
                    state = 'args'
                continue
            if state == 'start':
                if ASSIGN.match(self.s, k):
                    k = self.assignment(k)
                    continue
                at = k
                k, w = self.word(k, 'arg')
                if w in UNFOLLOWED:
                    raise Unreadable(f'line {self.line(at)}: {w} runs commands that are not in the text')
                words = [w]
                if w == '[[':
                    state, side = 'test', ''
                elif w in STARTS:
                    state = 'start'
                elif w in ('for', 'select'):
                    state = 'for-name'
                elif w == 'case':
                    state = 'case-word'
                elif w in DECLARE:
                    state = 'declare'
                else:
                    state = 'args'
            elif state == 'declare':
                if ASSIGN.match(self.s, k):
                    k = self.assignment(k)
                else:
                    k, _ = self.word(k, 'arg')
            elif state == 'for-name':
                k, _ = self.word(k, None)
                state = 'for-in'
            elif state == 'for-in':
                k, w = self.word(k, None)
                state = 'for-list' if w == 'in' else 'start'
            elif state == 'for-list':
                k, w = self.word(k, 'for-list')
                if w == 'do':
                    state = 'start'
            elif state == 'case-word':
                k, _ = self.word(k, 'case-word')
                state = 'case-in'
            elif state == 'case-in':
                k, w = self.word(k, None)
                if w == 'in':
                    state = 'case-pattern'
            elif state == 'test':
                if self.s.startswith(']]', k):
                    k += 2
                    state = 'args'
                    continue
                j, w = self.word(k, TEST_SIDES.get(side, 'test'))
                if j == k:
                    j = k + (2 if self.s.startswith(('&&', '||'), k) else 1)
                    w = self.s[k:j]
                side, k = w, j
            else:
                j, w = self.word(k, 'arg')
                if j > k:
                    self.payload(k, w, words)
                    words.append(w)
                k = j if j > k else k + 1


def main(argv):
    if len(argv) != 2:
        print('usage: unquoted.py <script>', file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding='utf-8', errors='surrogateescape') as f:
            text = f.read()
    except OSError as e:
        print(f'unquoted.py: {argv[1]}: {e.strerror}', file=sys.stderr)
        return 2
    lexer = Lexer(text)
    try:
        lexer.commands(0, None)
    except Unreadable as e:
        print(f'unquoted.py: {argv[1]}: {e}', file=sys.stderr)
        return 2
    for line, context, expansion in sorted(lexer.out, key=lambda r: r[0]):
        print(line, context, expansion)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
