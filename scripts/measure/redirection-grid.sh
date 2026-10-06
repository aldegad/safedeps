#!/usr/bin/env bash
# safedeps: the shell's redirection grammar as a grid of forms, measured.
#
# Three review rounds each found a redirection the lexer read unlike the shell
# (a target that is a process substitution, a `{varname}` descriptor word, a
# redirection between a manager and its verb), and each time the form was one
# no corpus held. So the forms are not picked one by one here: every operator
# the manuals list is put in every place a redirection can stand, and the
# shells say which of them run the install.
#
# The tables:
#
#   operators  bash REDIRECTION: [n]< [n]> [n]>| [n]>> &> &>> [n]>& [n]<&
#              [n]<> << <<- <<< [n]>&- [n]<&- [n]<&digit-, each with a
#              number and with bash's {varname} in front where the manual
#              allows one. zsh: >! >>! >>| &>| &>! >&| >&! >>& >>&| >>&!
#              &>>| &>>!. dash: the POSIX subset, where &> is & then >.
#   places     before the command, between the command word and its
#              arguments, among the arguments, after them; after a
#              separator, &&, a pipe, an assignment, env, command, exec, !,
#              time and another redirection; inside a function body, a
#              group, a subshell and an if; and two data places, where the
#              install words are arguments to echo.
#   targets    the target word as the lexer must cut it: plain, after a
#              blank, quoted, glued quoting, escaped, a substitution, a
#              backquote, a parameter expansion, a process substitution
#              (with a blank inside, a quoted parenthesis, a redirection of
#              its own), the empty word. Crossed with four operators and
#              three places.
#   words      what the manuals say a word may be made of, one row per
#              production, each with the manual section it comes from. The
#              targets above were picked by hand, and the next review found
#              the words nobody had picked: an array value, a case pattern
#              inside a substitution, zsh `=(...)`, a glob group. So this
#              table is read off the manuals instead: bash Quoting, Brace
#              Expansion, Tilde Expansion, Shell Parameter Expansion, Command
#              Substitution, Arithmetic Expansion, Process Substitution,
#              Pattern Matching, Arrays and Shell Parameters; zsh Array
#              Parameters, Process Substitution, Filename Generation, Glob
#              Qualifiers and Precommand Modifiers. A row is a value (v: a
#              word that stands for a file name), an assignment (a: a word
#              that is one whole assignment) or a precommand (p: words that
#              stand before a command and are none).
#   word places  where such a word stands. A value: as the value of an
#              assignment prefix, as a redirection target (glued, after a
#              blank, between the command word and its arguments, after a
#              separator, in a function body), and as data (an argument of
#              echo, and a target of echo). An assignment or a precommand:
#              before the command, before a redirection, between the command
#              word and its arguments, after a separator, in a function
#              body, and as an argument of echo.
#   subshells  where a subshell stands when it stands where a command does.
#              A statement start is written before a word, and a subshell
#              is none, so each word the grammar lets a subshell follow is a
#              place of its own: after `{`, a function head, `do`, `then`,
#              `else`, `!`, `time`, `coproc`, a case arm, `if`, `while` and
#              `until`, and after a separator. Each with a blank before the
#              `(` and glued to what is before it. And what may follow its
#              `)`: `then`, `do`, `fi`, `done`, `}`, `esac`, `else`, with a
#              blank or glued, where the close has to end the command for the
#              reserved word to be read. Three data forms: a `(` among the
#              arguments, a bash extglob argument, and an array value.
#   precommands  the words a command may stand behind and their options, as
#              the manuals list them: bash `command [-pVv]`, `exec [-cl] [-a
#              name]` and the reserved word `time [-p]`; zsh `command
#              [-pvV]`, `exec [-cl] [-a argv0]` and the precommand modifiers
#              `-`, `builtin`, `noglob`, `nocorrect`; dash `command [-p]
#              [-vV]` and `exec`. Each option set, with `--` after it, and
#              two of the words in a row; at the start, in a function body,
#              and as data (arguments of echo).
#   productions  every place a command list stands in the compound commands
#              of the manuals -- bash Compound Commands (grouping,
#              conditional and looping constructs, the arithmetic for), Shell
#              Functions, Coprocesses and Pipelines (`!`, `time`); the zsh
#              Complex Commands and their Alternate Forms (`for NAME (WORDS)`,
#              `foreach`, `repeat`, the `{ }` bodies of `if` and `while`,
#              `always`, anonymous and multi-name functions); Command and
#              Process Substitution and zsh `=(...)` -- one row per production
#              with %L where the list goes, crossed with what may stand first
#              in that list (the command, a subshell, a group, `!`) and with
#              a blank or nothing (%_) before it. The subshell table above
#              was picked by hand and the next review found the places it
#              left out (a `{` glued to `for ((...))`, a subshell glued to a
#              case pattern close or to `for i (1)`, a subshell first inside
#              a process substitution); this one is read off the grammars.
#
# Each form names its command word @@HEAD@@ and its arguments
# `install evil==6.6.6` (see scripts/measure/shell-reading-measure.sh): the
# measurement runs a stub that marks only those exact arguments, and the gate
# battery reads `pip`.
#
# Usage:
#   scripts/measure/redirection-grid.sh generate   the grid, unmeasured
#   scripts/measure/redirection-grid.sh record     regenerate, keep the other
#       platform's measured values for forms whose text did not change,
#       measure this platform, and write scripts/measure/redirection-grid.json
#   scripts/measure/redirection-grid.sh check      the committed grid is the
#       generated one, this platform measures what it records, and the gate
#       judges every form a shell runs and leaves the data forms alone
#
# On macOS, SAFEDEPS_MEASURE_BASH5=<path to a bash 5> adds the bash5 column
# (bash 4.1 and later read {fd} as a descriptor; /bin/bash 3.2 does not).
# Both platforms record into one file: run `record` on macOS and on Linux.
set -uo pipefail
# bash 5.2 reads `&` in the replacement of ${var//pattern/replacement} as the
# matched text, and the operators below are full of `&`: on Linux the grid
# came out with other forms under the same ids than on macOS (bash 3.2).
shopt -u patsub_replacement 2>/dev/null || true

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GRID="${ROOT_DIR}/scripts/measure/redirection-grid.json"
ARGS='install evil==6.6.6'

# id <TAB> spelling, with T where the target goes and B where a heredoc
# delimiter goes <TAB> default target
OPERATORS='in	<T	/dev/null
out	>T	/dev/null
clobber	>|T	/dev/null
append	>>T	/dev/null
rw	<>T	/dev/null
dupin	<&T	0
dupout	>&T	2
dupword	>&T	/dev/null
closein	<&-
closeout	>&-
herestring	<<<T	x
heredoc	<<B
heredocstrip	<<-B
both	&>T	/dev/null
bothappend	&>>T	/dev/null
n-out	2>T	/dev/null
n-in	0<T	/dev/null
n-clobber	2>|T	/dev/null
n-append	2>>T	/dev/null
n-rw	3<>T	/dev/null
n-dup	2>&T	1
n-dupin	3<&T	0
n-close	2>&-
n-move	4<&0-
n-herestring	0<<<T	x
n-heredoc	0<<B
n-wide	10>T	/dev/null
v-out	{fd}>T	/dev/null
v-in	{fd}<T	/dev/null
v-clobber	{fd}>|T	/dev/null
v-append	{fd}>>T	/dev/null
v-rw	{fd}<>T	/dev/null
v-dup	{fd}>&T	2
v-dupin	{fd}<&T	0
v-herestring	{fd}<<<T	x
v-heredoc	{fd}<<B
z-bang	>!T	/dev/null
z-appendbang	>>!T	/dev/null
z-appendbar	>>|T	/dev/null
z-bothbar	&>|T	/dev/null
z-bothbang	&>!T	/dev/null
z-dupbar	>&|T	/dev/null
z-dupbang	>&!T	/dev/null
z-appendboth	>>&T	/dev/null
z-appendbothbar	>>&|T	/dev/null
z-appendbothbang	>>&!T	/dev/null
z-bothappendbar	&>>|T	/dev/null
z-bothappendbang	&>>!T	/dev/null
z-bang-blank	>! T	/dev/null'

# id <TAB> template: %R is the redirection, %H the command word and its
# arguments, %C the command word alone and %A its arguments
PLACES='pre	%R %H
mid	%C %R %A
post	%C install %R evil==6.6.6
end	%H %R
sep	true; %R %H
and	true && %R %H
pipe	true | %R %H
assign	FOO=1 %R %H
assignafter	%R FOO=1 %H
env	env %R %H
command	command %R %H
exec	exec %R %H
bang	! %R %H
time	time %R %H
two	%R %R %H
func	f() { %R %H; }; f
group	{ %R %H; }
subshell	( %R %H )
if	if %R %H; then :; fi
data-echo	echo %R %H
data-lead	%R echo %H'

# id <TAB> target word (an operator reads it in place of T)
TARGETS='plain	/dev/null
blank	 /dev/null
dq	"/dev/null"
sq	'"'"'/dev/null'"'"'
glued	/dev/nu'"''"'ll
escaped	\/dev/null
subst	$(echo /dev/null)
substq	"$(echo /dev/null)"
substblank	$(echo  /dev/null )
backquote	`echo /dev/null`
param	${HOME:+/dev/null}
psin	<(true)
psinblank	 <(true)
psout	>(cat)
psoutblank	 >(cat)
psblanks	>(true; true)
psparen	>(echo ")" >/dev/null)
psredir	>(cat >/dev/null)
semi	'"'"'a;b'"'"'
empty	""'
TARGET_OPS='out in n-out v-out'
TARGET_PLACES='pre mid sep'

# id <TAB> kind <TAB> manual section <TAB> setup line or - <TAB> the word
# (@NL@ is a newline inside it). A value word names a file the form can
# create or open where it runs: `f` in the throwaway directory, or /dev/null.
#
# Not in the table: a word the shell removes when it runs the command. zsh
# `a=(x)(N)` is a glob that matches nothing and goes, so between the command
# word and its arguments it leaves the install behind (measured: zsh ran it).
# That is not where a word ends but which word is the command, the boundary
# consumer-forms pins with `pip $x install ...`, and the plan that owns it is
# safedeps/command-words-read-as-the-shell-dequotes. The row was taken out
# because the grid holds every form a shell runs to a verdict, and this one
# has none yet.
read -r -d '' WORDS <<'EOT' || true
q-ansi	v	bash: ANSI-C Quoting	-	$'f'
q-ansi-blank	v	bash: ANSI-C Quoting	-	$'f g'
q-locale	v	bash: Locale-Specific Translation	-	$"f"
q-esc-blank	v	bash: Escape Character	-	f\ g
q-esc-paren	v	bash: Escape Character	-	f\(g\)
q-dq-paren	v	bash: Double Quotes	-	"(f)"
q-mixed	v	bash: Quoting	-	f"g h"'i j'
brace	v	bash: Brace Expansion	-	f{1,2}
brace-seq	v	bash: Brace Expansion	-	f{1..2}
brace-one	v	bash: Brace Expansion	-	f{1}
tilde	v	bash: Tilde Expansion	-	~+/f
param	v	bash: Shell Parameter Expansion	-	${nope:-f}
param-blank	v	bash: Shell Parameter Expansion	-	${nope:-f g}
param-paren	v	bash: Shell Parameter Expansion	-	${nope:-(f)}
param-subst	v	bash: Shell Parameter Expansion	-	${nope:-$(echo f)}
param-case	v	bash: Shell Parameter Expansion	-	${nope:-$(case a in a) echo f;; esac)}
cs-list	v	bash: Command Substitution	-	$(true; echo f)
cs-nested	v	bash: Command Substitution	-	$(echo $(echo f))
cs-subshell	v	bash: Command Substitution	-	$( (echo f) )
cs-comment	v	bash: Command Substitution	-	$(echo f # )@NL@)
cs-case	v	bash: Command Substitution	-	$(case a in a) echo f;; esac)
cs-case-paren	v	bash: Command Substitution	-	$(case a in (a) echo f;; esac)
cs-case-dq	v	bash: Command Substitution	-	"$(case a in a) echo f;; esac)"
cs-case-two	v	bash: Command Substitution	-	$(case a in a) echo f;; esac)$(case b in b) echo g;; esac)
cs-case-bq	v	bash: Command Substitution	-	`case a in a) echo f;; esac`
arith	v	bash: Arithmetic Expansion	-	$((1+1))
arith-paren	v	bash: Arithmetic Expansion	-	$(( (1+1) ))
arith-old	v	bash: Arithmetic Expansion	-	$[1+1]
ps-case	v	bash: Process Substitution	-	<(case a in a) true;; esac)
ps-nested	v	bash: Process Substitution	-	<(cat <(true))
glob-one	v	bash: Pattern Matching	-	/dev/nul?
glob-any	v	bash: Pattern Matching	-	/dev/nul*
glob-class	v	bash: Pattern Matching	-	/dev/[n]ull
ext-at	v	bash: Pattern Matching (extglob)	shopt -s extglob	/dev/@(null)
ext-alt	v	bash: Pattern Matching (extglob)	shopt -s extglob	/dev/@(null|nope)
ext-not	v	bash: Pattern Matching (extglob)	shopt -s extglob	f!(x)
ext-star	v	bash: Pattern Matching (extglob)	shopt -s extglob	f*(x)
ext-plus	v	bash: Pattern Matching (extglob)	shopt -s extglob	f+(x)
ext-opt	v	bash: Pattern Matching (extglob)	shopt -s extglob	f?(x)
z-eq	v	zsh: Process Substitution	-	=(true)
z-eq-list	v	zsh: Process Substitution	-	=(true; true)
z-eq-case	v	zsh: Process Substitution	-	=(case a in a) true;; esac)
z-group	v	zsh: Filename Generation	-	/dev/(null)
z-group-tail	v	zsh: Filename Generation	-	/dev/nul(l)
z-alt	v	zsh: Filename Generation	-	/dev/(null|nope)
z-numeric	v	zsh: Filename Generation	-	/dev/fd/<1-1>
z-numeric-open	v	zsh: Filename Generation	-	/dev/fd/<1->
z-exclude	v	zsh: Filename Generation	-	f~x
z-repeat	v	zsh: Filename Generation	-	/dev/nul#l
z-flag	v	zsh: Globbing Flags	-	/dev/(#i)null
z-qual	v	zsh: Glob Qualifiers	-	/dev/null(N)
z-qual-any	v	zsh: Glob Qualifiers	-	/dev/nul*(N)
z-qual-type	v	zsh: Glob Qualifiers	-	/dev/null(N%c)
z-qual-q	v	zsh: Glob Qualifiers	-	/dev/null(#qN)
arr	a	bash: Arrays	-	a=(x)
arr-blank	a	bash: Arrays	-	a=( x y )
arr-empty	a	bash: Arrays	-	a=()
arr-append	a	bash: Arrays	-	a+=(x)
arr-keys	a	bash: Arrays	-	a=([0]=x [1]=y)
arr-subst	a	bash: Arrays	-	a=($(echo x))
arr-case	a	bash: Arrays	-	a=($(case a in a) echo x;; esac))
arr-quoted	a	bash: Arrays	-	a=("x y" 'z')
arr-comment	a	bash: Arrays	-	a=(x # c@NL@y)
arr-newline	a	bash: Arrays	-	a=(@NL@x@NL@)
elem	a	bash: Arrays	-	a[1]=x
elem-append	a	bash: Arrays	-	a[1]+=x
elem-blank	a	bash: Arrays	-	a[1 + 1]=x
elem-subst	a	bash: Arrays	-	a[$(echo 1)]=x
elem-nested	a	bash: Arrays	-	a[b[1]]=x
elem-dq	a	bash: Arrays	-	a["1"]=x
append	a	bash: Shell Parameters	-	a+=x
three	a	bash: Shell Parameters	-	a=(x) b+=(y) c[2]=z
z-slice	a	zsh: Array Parameters	-	a[1,2]=(x y)
pre-dash	p	zsh: Precommand Modifiers	-	-
pre-builtin	p	zsh: Precommand Modifiers	-	builtin
pre-command	p	zsh: Precommand Modifiers	-	command
pre-exec	p	zsh: Precommand Modifiers	-	exec
pre-nocorrect	p	zsh: Precommand Modifiers	-	nocorrect
pre-noglob	p	zsh: Precommand Modifiers	-	noglob
pre-two	p	zsh: Precommand Modifiers	-	noglob nocorrect
pre-dash-noglob	p	zsh: Precommand Modifiers	-	- noglob
pre-three	p	zsh: Precommand Modifiers	-	nocorrect noglob -
pre-exec-dash	p	zsh: Precommand Modifiers	-	exec -
pre-exec-name	p	zsh: Precommand Modifiers	-	exec -a x
pre-command-p	p	zsh: Precommand Modifiers	-	command -p
pre-builtin-noglob	p	zsh: Precommand Modifiers	-	builtin noglob
pre-command-noglob	p	zsh: Precommand Modifiers	-	command noglob
EOT

# id <TAB> the kinds it holds <TAB> template (%W is the word) <TAB> data?
WORD_PLACES='assign	v	X=%W %H	false
target	v	>%W %H	false
targetblank	v	> %W %H	false
mid	v	%C >%W %A	false
sep	v	true; >%W %H	false
func	v	f() { >%W %H; }; f	false
data	v	echo %W %H	true
datatarget	v	echo >%W %H	true
prefix	ap	%W %H	false
redir	ap	%W 2>/dev/null %H	false
mid	ap	%C %W %A	false
sep	ap	true; %W %H	false
func	ap	f() { %W %H; }; f	false
data	ap	echo %W %H	true'

# id <TAB> glue: both (a form with a blank before the subshell and one
# without), or one <TAB> template. %S is the subshell that runs the install,
# %_ the blank that the glued form leaves out. <TAB> data?
SUBSHELLS='start	one	%S	false
sep	both	true;%_%S	false
and	both	true &&%_%S	false
pipe	both	true |%_%S	false
brace	both	{%_%S; }	false
fn	both	f() {%_%S; }; f	false
fn-keyword	both	function f {%_%S; }; f	false
fn-body	both	f()%_%S; f	false
do	both	for i in 1; do%_%S; done	false
do-args	both	set -- a; for i do%_%S; done	false
while-do	both	while true; do%_%S; break; done	false
then	both	if true; then%_%S; fi	false
else	both	if false; then :; else%_%S; fi	false
elif-then	both	if false; then :; elif true; then%_%S; fi	false
bang	both	!%_%S	false
time	both	time%_%S	false
coproc	both	coproc%_%S; wait	false
case-arm	both	case x in x)%_%S;; esac	false
if	both	if%_%S; then :; fi	false
while	both	while%_%S; do break; done	false
until	both	until%_%S; do :; done	false
close-then	both	if %S%_then :; fi	false
close-do	both	while %S%_do break; done	false
close-fi	both	if true; then %S%_fi	false
close-done	both	for i in 1; do %S%_done	false
close-brace	both	{ %S%_}	false
close-esac	both	case x in x) %S%_esac	false
close-else	both	if false; then (:)%_else %S; fi	false
close-both	both	if (true)%_then %S%_fi	false
close-cmd	one	(true); %H	false
data-stray	one	echo a (b) %H	true
data-extglob	one	shopt -s extglob@NL@ls !(zz) %H	true
data-array	one	a=(%H)	true'

# id <TAB> the prefix. A prefix runs the command after it or does not; the
# shells say which.
PRECOMMANDS='cmd	command
cmd-p	command -p
cmd-pp	command -pp
cmd-p-p	command -p -p
cmd-dd	command --
cmd-p-dd	command -p --
cmd-v	command -v
cmd-V	command -V
cmd-pv	command -pv
exec	exec
exec-c	exec -c
exec-l	exec -l
exec-cl	exec -cl
exec-lc	exec -lc
exec-a	exec -a x
exec-ax	exec -ax
exec-aa	exec -aa
exec-ca	exec -ca x
exec-cax	exec -cax
exec-a-c	exec -a x -c
exec-la	exec -la x
exec-dd	exec --
exec-c-dd	exec -c --
exec-a-dd	exec -a x --
exec-a-ddname	exec -a -- --
time	time
time-p	time -p
time-p-dd	time -p --
time-dd	time --
z-dash	-
z-builtin	builtin
z-noglob	noglob
z-nocorrect	nocorrect
env	env
env-i	env -i
env-u	env -u X
env-uglued	env -uX
env-assign	env X=1
env-dd	env --
env-i-dd	env -i --
env-C	env -C /
env-P	env -P /usr/bin
env-v	env -v
env-unset	env --unset=X
env-chdir	env --chdir=/
env-path	/usr/bin/env
env-path-i	/usr/bin/env -i
env-path-dd	/usr/bin/env --'
# env -S STRING (GNU --split-string) runs the words of STRING and those after
# it: id <TAB> template, %H the install, %C its command word, %A its arguments.
ENV_SPLITS='S	env -S '"'"'%H'"'"'
S-glued	env -S'"'"'%H'"'"'
iS	env -iS '"'"'%H'"'"'
S-rest	env -S '"'"'%C install'"'"' evil==6.6.6
split-string	env --split-string='"'"'%H'"'"'
path-S	/usr/bin/env -S '"'"'%H'"'"''
# What stands first in a command list, before the command word: generated
# from the simple-command grammar, not picked. The four first places picked by
# hand before (a command, a subshell, a group, `!`) missed every start a
# prefix glued to a reserved word, `!`, a head's close or zsh's `{` puts there
# (verdict howl-20261004-084050), and those are what this grammar puts before
# a command word:
#
#   POSIX Shell Command Language 2.10.2 (Shell Grammar):
#     pipeline       : pipe_sequence | Bang pipe_sequence
#     cmd_prefix     : io_redirect | cmd_prefix io_redirect
#                    | ASSIGNMENT_WORD | cmd_prefix ASSIGNMENT_WORD
#     io_redirect    : io_file | IO_NUMBER io_file | io_here | IO_NUMBER io_here
#     io_file        : '<' | LESSAND | '>' | GREATAND | DGREAT | LESSGREAT | CLOBBER
#     io_here        : DLESS here_end | DLESSDASH here_end
#   bash 3.6 Redirections (&>, &>>, <<<, {varname}), 3.4 Parameters (+=,
#   NAME[i]=, NAME=(...)), 3.2.3 Pipelines (time, time -p), 4.1 (command, exec);
#   zsh 6.2 Precommand Modifiers (-, nocorrect, noglob), 7 Redirection (>!);
#   env(1).
#
# id <TAB> prefix text (the install follows it after one blank). This is the
# one list: scripts/measure/first-place-grid.sh reads it from here.
FIRSTS='lt	</dev/null
lessand	<&0
gt	>/dev/null
greatand	>&2
dgreat	>>/dev/null
lessgreat	<>/dev/null
clobber	>|/dev/null
ionum-gt	2>/dev/null
ionum-dup	2>&1
dless	<<E
dlessdash	<<-E
and-gt	&>/dev/null
and-dgreat	&>>/dev/null
tless	<<<x
varfd	{fd}>/dev/null
z-bang-gt	>!/dev/null
assign	X=1
assign-plus	X+=1
assign-sub	a[1]=x
assign-arr	a=(x)
bang	!
time	time
time-p	time -p
command	command
command-p	command -p
exec	exec
noglob	noglob
nocorrect	nocorrect
z-dash	-
env	env
env-assign	env X=1
env-u	env -u X
gt+assign	>/dev/null X=1
assign+gt	X=1 >/dev/null
ionum+command	2>/dev/null command
assign+command	X=1 command
gt+dup	>/dev/null 2>&1
bang+gt	! >/dev/null
time+gt	time >/dev/null
noglob+gt	noglob >/dev/null'

# The words two prefixes in a row are drawn from (the first, then the second).
PRECOMMAND_FIRSTS='command|command -p|command --|exec|exec -c|exec --|noglob|-|nocorrect|time -p'
PRECOMMAND_SECONDS='command|command -p|command --|exec|exec -a x|exec --|noglob|-|env|time'
# id <TAB> template (%P the prefix, %H the install) <TAB> data?
PRECOMMAND_PLACES='start	%P %H	false
func	f() { %P %H; }; f	false
data	echo %P %H	true'

# id <TAB> manual section <TAB> template: %L is the list slot, %_ a blank or
# nothing, @NL@ a newline. Every loop ends after one round whatever the
# install does, and nothing reads standard input.
PRODUCTIONS='group	bash: Command Grouping	{%_%L; }
subshell	bash: Command Grouping	(%_%L)
if-cond	bash: Conditional Constructs	if%_%L; then :; fi
if-then	bash: Conditional Constructs	if true; then%_%L; fi
elif-cond	bash: Conditional Constructs	if false; then :; elif%_%L; then :; fi
elif-then	bash: Conditional Constructs	if false; then :; elif true; then%_%L; fi
else	bash: Conditional Constructs	if false; then :; else%_%L; fi
while-cond	bash: Looping Constructs	while%_%L; do break; done
while-do	bash: Looping Constructs	while true; do%_%L; break; done
until-cond	bash: Looping Constructs	until%_%L; do break; done
until-do	bash: Looping Constructs	until false; do%_%L; break; done
for-in-do	bash: Looping Constructs	for i in 1; do%_%L; done
for-args-do	bash: Looping Constructs	set -- a; for i do%_%L; done
for-in-brace	bash: Looping Constructs	for i in 1; {%_%L; }
arith-for-do	bash: Looping Constructs	for ((i=0;i<1;i++)); do%_%L; done
arith-for-close-do	bash: Looping Constructs	for ((i=0;i<1;i++))%_do %L; done
arith-for-close-brace	bash: Looping Constructs	for ((i=0;i<1;i++))%_{ %L; }
arith-for-brace	bash: Looping Constructs	for ((i=0;i<1;i++)) {%_%L; }
arith-for-spaced	bash: Looping Constructs	for (( i = 0 ; i < 1 ; i++ ))%_{ %L; }
arith-for-down	bash: Looping Constructs	for ((x=1;x;x--))%_do %L; done
arith-for-close-semi	bash: Looping Constructs	for ((i=0;i<1;i++))%_; do %L; done
case-arm	bash: Conditional Constructs	case x in x)%_%L;; esac
case-arm-paren	bash: Conditional Constructs	case x in (x)%_%L;; esac
case-second	bash: Conditional Constructs	case a in b) :;; *)%_%L;; esac
case-fall	bash: Conditional Constructs	case a in a) :;&%_b)%_%L;; esac
case-test	bash: Conditional Constructs	case a in a) :;;&%_*)%_%L;; esac
arith-and	bash: Conditional Constructs	((1))%_&& %L
arith-semi	bash: Conditional Constructs	((1))%_; %L
dbr-and	bash: Conditional Constructs	[[ -n x ]]%_&& %L
sub-then	bash: Conditional Constructs	if (true)%_then %L; fi
fn	bash: Shell Functions	f()%_{ %L; }; f
fn-first	bash: Shell Functions	f() {%_%L; }; f
fn-sub	bash: Shell Functions	f()%_(%L); f
fn-keyword	bash: Shell Functions	function f%_{ %L; }; f
fn-keyword-paren	bash: Shell Functions	function f()%_{ %L; }; f
fn-keyword-if	bash: Shell Functions	function f if%_%L; then :; fi; f
coproc	bash: Coprocesses	coproc%_%L; wait
coproc-named	bash: Coprocesses	coproc c {%_%L; }; wait
bang	bash: Pipelines	!%_%L
time	bash: Pipelines	time%_%L
time-p	bash: Pipelines	time -p%_%L
and	bash: Lists of Commands	true &&%_%L
or	bash: Lists of Commands	false ||%_%L
pipe	bash: Pipelines	true |%_%L
seq	bash: Lists of Commands	true;%_%L
bg	bash: Lists of Commands	true &%_%L; wait
newline	bash: Lists of Commands	true@NL@%L
z-for-list	zsh: Alternate Forms	for i (1)%_%L
z-for-list-two	zsh: Alternate Forms	for i j (1 2)%_%L
z-foreach	zsh: Alternate Forms	foreach i (1)%_%L@NL@end
z-for-in-short	zsh: Alternate Forms	for i in 1;%_%L
z-arith-for-short	zsh: Alternate Forms	for ((i=0;i<1;i++))%_%L
z-repeat	zsh: Alternate Forms	repeat 1%_%L
z-repeat-brace	zsh: Alternate Forms	repeat 1 {%_%L; }
z-if-brace	zsh: Alternate Forms	if [[ -n x ]] {%_%L; }
z-if-dbr	zsh: Alternate Forms	if [[ -n x ]]%_%L
z-if-arith	zsh: Alternate Forms	if ((1))%_%L
z-if-sub	zsh: Alternate Forms	if (true)%_%L
z-while-brace	zsh: Alternate Forms	i=; while [[ -z $i ]] {%_%L; i=1; }
z-always	zsh: Complex Commands	{ : } always {%_%L; }
z-try	zsh: Complex Commands	{%_%L; } always { : }
z-anon	zsh: Functions	() {%_%L; }
z-fn-two	zsh: Functions	f g () {%_%L; }; f
cs	bash: Command Substitution	echo $(%_%L)
cs-dq	bash: Command Substitution	echo "$(%_%L)"
bq	bash: Command Substitution	echo `%_%L`
ps-in	bash: Process Substitution	cat <(%_%L)
ps-in-redir	bash: Process Substitution	cat < <(%_%L)
ps-out	bash: Process Substitution	tee >(%_%L) </dev/null
ps-assign	bash: Process Substitution	x=<(%_%L) true
z-eq	zsh: Process Substitution	cat =(%_%L)
data-sq	bash: Single Quotes	echo '"'"'if true; then%_%L; fi'"'"'
data-dq	bash: Double Quotes	echo "{%_%L; }"'
# id <TAB> what stands first in the list, %H the install: a command, a
# subshell and a group, and each first place in FIRSTS before the command.
FILLERS='cmd	%H
sub	(%H)
group	{ %H; }'

# The heredoc bodies a form needs: one per delimiter B, in order.
bodies() { # count
  local k out=""
  for ((k = 0; k < $1; k++)); do out+=$'\nx\nE'; done
  printf '%s' "${out}"
}

# One form: <id> <label> <redirection> <place template> <data?>
form() {
  local id="$1" label="$2" redir="$3" place="$4" data="$5" text n
  text="${place//%H/%C %A}"
  text="${text//%A/${ARGS}}"
  text="${text//%C/@@HEAD@@}"
  text="${text//%R/${redir}}"
  n=$(grep -o '<<-\{0,1\}E' <<< "${text}" | grep -c . || true)
  text="${text}$(bodies "${n}")"$'\n'
  jq -nc --arg id "${id}" --arg label "${label}" --arg text "${text}" --argjson data "${data}" \
    '{id: $id, cls: "R", label: $label, text: $text} + (if $data then {data: true} else {} end)'
}

# One word form: <id> <label> <manual section> <setup> <word> <place template> <data?>
word_form() {
  local id="$1" label="$2" manual="$3" setup="$4" word="$5" place="$6" data="$7" text
  text="${place//%H/%C %A}"
  text="${text//%A/${ARGS}}"
  text="${text//%C/@@HEAD@@}"
  text="${text//%W/${word}}"
  text="${text//@NL@/$'\n'}"
  [[ "${setup}" == "-" ]] || text="${setup}"$'\n'"${text}"
  text="${text}"$'\n'
  jq -nc --arg id "${id}" --arg label "${label}" --arg manual "${manual}" --arg text "${text}" --argjson data "${data}" \
    '{id: $id, cls: "W", label: $label, manual: $manual, text: $text} + (if $data then {data: true} else {} end)'
}

# One subshell form: <id> <label> <template> <the glue blank or nothing> <data?>
subshell_form() {
  local id="$1" label="$2" text="$3" glue="$4" data="$5"
  text="${text//%S/(%H)}"
  text="${text//%H/@@HEAD@@ ${ARGS}}"
  text="${text//%_/${glue}}"
  text="${text//@NL@/$'\n'}"$'\n'
  jq -nc --arg id "${id}" --arg label "${label}" --arg text "${text}" --argjson data "${data}" \
    '{id: $id, cls: "S", label: $label, text: $text} + (if $data then {data: true} else {} end)'
}

# One form of the later tables: <id> <label> <template> <glue> <data?>, where
# %S is a subshell running the install, %H the install and %_ the glue. A
# first place that opens a heredoc gets its body after the form.
place_form() {
  local id="$1" label="$2" text="$3" glue="$4" data="$5" n
  text="${text//%S/(%H)}"
  text="${text//%H/@@HEAD@@ ${ARGS}}"
  text="${text//%_/${glue}}"
  text="${text//@NL@/$'\n'}"
  n=$(grep -o '<<-\{0,1\}E' <<< "${text}" | grep -c . || true)
  text="${text}$(bodies "${n}")"$'\n'
  jq -nc --arg id "${id}" --arg label "${label}" --arg text "${text}" --argjson data "${data}" \
    '{id: $id, cls: "P", label: $label, text: $text} + (if $data then {data: true} else {} end)'
}

generate() {
  local op spell target place tpl redir pid tid ttext wid kind manual setup word kinds data sid glue pre a b cid ctpl xid xtext tbl
  {
    while IFS=$'\t' read -r op spell target; do
      redir="${spell//T/${target}}"
      redir="${redir//B/E}"
      while IFS=$'\t' read -r pid tpl; do
        # An operator that starts with `&>` is no data place in dash, which
        # ends the command at the `&` and reads the install as the next one:
        # held to a pass, `echo &>!/dev/null pip install x` would demand that
        # the gate not read a command dash runs whenever the target lets it.
        form "RG-${op}-${pid}" "operator ${spell} (${op}) at ${pid}" "${redir}" "${tpl}" \
          "$([[ "${pid}" == data-* && "${spell}" != '&>'* ]] && echo true || echo false)"
      done <<< "${PLACES}"
    done <<< "${OPERATORS}"
    while IFS=$'\t' read -r tid ttext; do
      for op in ${TARGET_OPS}; do
        spell=$(awk -F'\t' -v o="${op}" '$1 == o { print $2 }' <<< "${OPERATORS}")
        redir="${spell//T/${ttext}}"
        for pid in ${TARGET_PLACES}; do
          tpl=$(awk -F'\t' -v p="${pid}" '$1 == p { print $2 }' <<< "${PLACES}")
          form "RT-${tid}-${op}-${pid}" "target ${tid} after ${spell} at ${pid}" "${redir}" "${tpl}" false
        done
      done
    done <<< "${TARGETS}"
    while IFS=$'\t' read -r wid kind manual setup word; do
      while IFS=$'\t' read -r pid kinds tpl data; do
        [[ "${kinds}" == *"${kind}"* ]] || continue
        word_form "RW-${wid}-${pid}" "word ${wid} at ${pid}" "${manual}" "${setup}" "${word}" "${tpl}" "${data}"
      done <<< "${WORD_PLACES}"
    done <<< "${WORDS}"
    while IFS=$'\t' read -r sid glue tpl data; do
      if [[ "${glue}" == both ]]; then
        subshell_form "RS-${sid}-blank" "subshell at ${sid}, after a blank" "${tpl}" " " "${data}"
        subshell_form "RS-${sid}-glued" "subshell at ${sid}, glued" "${tpl}" "" "${data}"
      else
        subshell_form "RS-${sid}" "subshell at ${sid}" "${tpl}" " " "${data}"
      fi
    done <<< "${SUBSHELLS}"
    while IFS=$'\t' read -r pid pre; do
      while IFS=$'\t' read -r sid tpl data; do
        place_form "RP-${pid}-${sid}" "prefix ${pre} at ${sid}" "${tpl//%P/${pre}}" " " "${data}"
      done <<< "${PRECOMMAND_PLACES}"
    done <<< "${PRECOMMANDS}"
    while IFS= read -r a; do
      while IFS= read -r b; do
        [[ "${a}" != "${b}" ]] || continue
        pid="${a// /_}+${b// /_}"
        place_form "RP2-${pid}" "prefixes ${a} then ${b}" "${a} ${b} %H" " " false
      done < <(tr '|' '\n' <<< "${PRECOMMAND_SECONDS}")
    done < <(tr '|' '\n' <<< "${PRECOMMAND_FIRSTS}")
    while IFS=$'\t' read -r pid tpl; do
      place_form "RE-${pid}" "env ${pid}" "${tpl//%C/@@HEAD@@}" " " false
    done <<< "${ENV_SPLITS}"
    while IFS=$'\t' read -r pid manual tpl; do
      data=false
      [[ "${pid}" != data-* ]] || data=true
      while IFS=$'\t' read -r xid xtext; do
        if [[ "${tpl}" == *%_* ]]; then
          place_form "RL-${pid}-${xid}-blank" "${xid} in ${pid} (${manual}), after a blank" "${tpl//%L/${xtext}}" " " "${data}"
          place_form "RL-${pid}-${xid}-glued" "${xid} in ${pid} (${manual}), glued" "${tpl//%L/${xtext}}" "" "${data}"
        else
          place_form "RL-${pid}-${xid}" "${xid} in ${pid} (${manual})" "${tpl//%L/${xtext}}" " " "${data}"
        fi
      done < <(printf '%s\n' "${FILLERS}"; while IFS=$'\t' read -r xid xtext; do printf '%s\t%s %%H\n' "${xid}" "${xtext}"; done <<< "${FIRSTS}")
    done <<< "${PRODUCTIONS}"
  } | jq -s '.'
}

# A data form the shells all leave alone has to stay data: the gate passes
# it. Set from the measured values, so a data form some shell does run (dash
# runs `echo a &>f pip install x`) is held to a verdict instead.
with_gate() {
  jq '[.[] | if .data and ([.measured | .. | strings | select(startswith("R"))] | length) == 0
             then . + {gate: "pass"} else del(.gate) end]'
}

case "${1:-check}" in
  generate)
    generate
    ;;
  record)
    work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-grid.XXXXXX")
    trap 'rm -rf "${work}"' EXIT
    generate > "${work}/new.json"
    # The other platform's values carry over to a form whose text is the same.
    if [[ -f "${GRID}" ]]; then
      jq --slurpfile old "${GRID}" '
        ($old[0] | map({key: .id, value: .}) | from_entries) as $o
        | map(if ($o[.id] != null and $o[.id].text == .text and $o[.id].measured != null)
              then . + {measured: $o[.id].measured} else . end)' "${work}/new.json" > "${work}/merged.json"
    else
      cp "${work}/new.json" "${work}/merged.json"
    fi
    SAFEDEPS_SHELL_FORMS="${work}/merged.json" "${ROOT_DIR}/scripts/measure/shell-reading-measure.sh" --record \
      | with_gate > "${work}/out.json" || exit 1
    mv "${work}/out.json" "${GRID}"
    printf 'recorded %s forms in %s\n' "$(jq length "${GRID}")" "${GRID}"
    ;;
  check)
    rc=0
    work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-grid.XXXXXX")
    trap 'rm -rf "${work}"' EXIT
    generate > "${work}/new.json"
    if [[ "$(jq -c 'map({id, text})' "${work}/new.json")" != "$(jq -c 'map({id, text})' "${GRID}")" ]]; then
      printf 'not ok - the committed grid is not the generated one: run record on each platform\n'
      rc=1
    else
      printf 'ok - the committed grid is the generated one (%s forms)\n' "$(jq length "${GRID}")"
    fi
    SAFEDEPS_SHELL_FORMS="${GRID}" "${ROOT_DIR}/scripts/measure/shell-reading-measure.sh" | tail -1 || rc=1
    SAFEDEPS_SHELL_FORMS="${GRID}" bash "${ROOT_DIR}/scripts/test/shell-reading.sh" "${@:2}" || rc=1
    exit "${rc}"
    ;;
  *)
    printf 'usage: %s generate|record|check [--count]\n' "$0" >&2
    exit 2
    ;;
esac
