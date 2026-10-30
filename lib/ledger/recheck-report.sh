#!/usr/bin/env bash
# The report `safedeps re-check --json` prints, declared once. bin/safedeps
# builds it with recheck_report, and the daily wrapper
# (scripts/safedeps-recheck-alert.sh) reads it with the recheck_* readers, so
# a field is named in this file and nowhere else. Each reader keeps the default
# the wrapper has always read an absent field as. smoke.sh builds a report here
# and reads every field back.
#
# A declaration only: sourcing it sets one variable and runs nothing.

# shellcheck disable=SC2034,SC2016  # jq text, read by the files that source this one
SAFEDEPS_RECHECK_REPORT_JQ='
def recheck_command: "re-check";
def recheck_report($checked; $still_clean; $newly_vulnerable; $kev_hit; $revoked; $suspected_forgery):
  {command: recheck_command, checked: $checked, still_clean: $still_clean, newly_vulnerable: $newly_vulnerable,
   kev_hit: $kev_hit, revoked: $revoked, suspected_forgery: $suspected_forgery};
def recheck_is_report: .command == recheck_command;
def recheck_checked: .checked // 0;
def recheck_still_clean: .still_clean // 0;
def recheck_newly_vulnerable: .newly_vulnerable // [];
def recheck_kev_hit: .kev_hit // [];
def recheck_revoked: .revoked // [];
def recheck_suspected_forgery: .suspected_forgery // [];
'
