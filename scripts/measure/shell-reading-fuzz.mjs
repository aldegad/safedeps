#!/usr/bin/env node
// safedeps: random commands built from the places where shells lex differently.
//
// Usage: node scripts/measure/shell-reading-fuzz.mjs <seed> <count>
//
// Prints a JSON array of forms, {id, text}, in the shape of
// scripts/measure/shell-reading-forms.json: each text holds @@TAIL@@ once,
// with a few gadgets before it and after it. A gadget is a line a shell reads
// one way and another shell another way -- `((` decided per site, a quote in
// arithmetic, an apostrophe in "${...}", `$'...'` and `$[` that dash does not
// know, a zsh case arm -- or a line that closes what one of them opened.
// Stacking them is how the verdict that made the readings shells found the
// forms no fixed reading caught (bogeuli-20261001-234308, F47 F81 F144 F342).
//
// scripts/measure/shell-reading-fuzz.sh runs the forms under real shells and
// compares what they ran with what each reading of the lexer shows. The
// generator is seeded so a count can be re-derived: seed 20261001, count 400
// is the run the plan cites.

const GADGETS = [
  "((cat <<EOF\nit's\nEOF\n) )", // a subshell to zsh and dash, an open quote to bash
  "((1<<2))", // arithmetic to bash and zsh, a heredoc to dash
  "echo \"${x:-'}\"", // a quote to bash, a character to zsh and dash
  "((1' ))", // a character in zsh arithmetic, an open quote to bash
  "# '",
  "echo \"'}\"",
  "# ' ))",
  "2",
  "((echo \"a))b\") )", // a subshell to bash (its look-ahead honors quotes)
  "x=$((cat <<EOF\nit's\nEOF\n) )",
  "echo \"${x#'}\"",
  "# it's",
  "EOF",
  "echo \"$((1' ))\"",
  "case x in x) :;| *) :;; esac", // a zsh arm terminator
  "((x=1 ' ) ' ))",
  "echo $'x\\'", // dash has no $'...': the escaped quote closes it
  "'",
  "x=$[1' ]'", // dash has no $[
  "# ' ]",
  "x=$[1<<2]",
  "2]",
  "((echo $(echo \")\") <<2) )", // the look-ahead steps over $(...) whole
  "(( x = $(echo \")\" | wc -c) <<2 ))",
];

// mulberry32: small, seedable, the same on every node.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const [seedArg, countArg] = process.argv.slice(2);
const seed = Number.parseInt(seedArg ?? "", 10);
const count = Number.parseInt(countArg ?? "", 10);
if (!Number.isInteger(seed) || !Number.isInteger(count) || count < 1) {
  process.stderr.write("usage: shell-reading-fuzz.mjs <seed> <count>\n");
  process.exit(2);
}

const next = rng(seed);
const pick = () => GADGETS[Math.floor(next() * GADGETS.length)];
const between = (lo, hi) => lo + Math.floor(next() * (hi - lo + 1));
const forms = [];
const seen = new Set();
let draws = 0;
while (forms.length < count) {
  if (++draws > count * 50) {
    process.stderr.write(`only ${forms.length} distinct forms after ${draws} draws\n`);
    process.exit(1);
  }
  const before = Array.from({ length: between(1, 4) }, pick);
  const after = Array.from({ length: between(0, 3) }, pick);
  const text = [...before, "@@TAIL@@", ...after].join("\n") + "\n";
  if (seen.has(text)) continue;
  seen.add(text);
  forms.push({ id: `F${forms.length}`, text });
}
process.stdout.write(JSON.stringify(forms, null, 1) + "\n");
