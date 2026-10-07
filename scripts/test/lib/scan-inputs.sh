#!/usr/bin/env bash
# Draw every random input before a checker can consume RANDOM. Bash 3.2
# consumes it when making the temporary file for a here-string or heredoc.
# A shard skips some checkers, so interleaving draws and checks changes the
# next input even when the seed is fixed. These arrays are read-only inputs.
alphabet=(\' \" \\ ' ' a b n p m i s t l 1 . @ - / \; \& \| $'\n' '=' '(' ')' '$' '한')
heredoc_alphabet=(\' \" \\ ' ' '<' '<' '>' '-' '#' '`' '$' '(' '(' ')' ')' '{' '}' '[' ']' E O F p i $'\n' $'\n' $'\t' ';' '|' '&' '=' '1')
record_alphabet=('sh -c ' 'eval ' 'env -S ' 'bash -c ' '$(' ')' '`' "'" '"' '\' "\$'" '\x1d' '\n' ' ' ';' '<(' '#' 'pip install x' '--split-string=')
for code in $(seq 1 127); do
  # shellcheck disable=SC2059 # an octal escape
  printf -v b "\\$(printf '%03o' "${code}")"
  record_alphabet+=("${b}")
done
grammar_words=('{' '}' '(' ')' '()' ';' '|' '&&' $'\n' '!' if then else fi do done for i in foreach end '(1)' \
  repeat 1 time -p '[[' ']]' '((i=0;i<1;i++))' '$((1;2))' '$(a; b)' coproc case x 'x)' ';;' ';|' ';;&' esac function f g \
  always '>' 'out' '2>&1' '<(a)' 'X=1' while true pip install)
scan_random=() heredoc_random=() record_random=() grammar_random=()
paired_random=() paired_grammar=()
record_cases="${SAFEDEPS_SCAN_RECORD_CASES:-200}"
for pool in scan heredoc record grammar paired; do
  RANDOM="${fuzz_seed}"
  count="${fuzz_cases}"
  [[ "${pool}" != record ]] || count="${record_cases}"
  for ((draw = 0; draw < count; draw++)); do
    input=""
    case "${pool}" in
      scan|heredoc|paired)
        len=$((RANDOM % 40))
        for ((k = 0; k < len; k++)); do
          if [[ "${pool}" == scan ]]; then input+="${alphabet[RANDOM % ${#alphabet[@]}]}"
          else input+="${heredoc_alphabet[RANDOM % ${#heredoc_alphabet[@]}]}"; fi
        done
        case "${pool}" in
          scan) scan_random+=("${input}") ;;
          heredoc) heredoc_random+=("${input}") ;;
          paired) paired_random+=("${input}") ;;
        esac ;;
      record)
        len=$((RANDOM % 24))
        for ((k = 0; k < len; k++)); do
          if (( RANDOM % 2 )); then input+="${record_alphabet[RANDOM % 19]}"
          else input+="${record_alphabet[RANDOM % ${#record_alphabet[@]}]}"; fi
        done
        record_random+=("${input}") ;;
    esac
    if [[ "${pool}" == grammar || "${pool}" == paired ]]; then
      len=$((RANDOM % 12 + 1))
      input=""
      for ((k = 0; k < len; k++)); do
        input+="${grammar_words[RANDOM % ${#grammar_words[@]}]}"
        (( RANDOM % 4 )) && input+=" "
      done
      if [[ "${pool}" == grammar ]]; then grammar_random+=("${input}")
      else paired_grammar+=("${input}"); fi
    fi
  done
done
