# The watch state, declared once: its document, the names of its states, and
# every transition a writer makes. lib/watch/scan.sh, `safedeps watch claim`,
# `ack` and `status` all read and write the document through these definitions,
# and nothing else names a state.
#
# Included with `jq -L <lib/watch> 'include "state"; ...'`.

def watch_schema: "safedeps-watch/1";

# Finding states. A detection state says what the last measurement saw;
# closed_* say what evidence closed it. There is no "clean": a scope nobody
# measured keeps what it had, marked stale.
def st_open: "open";
def st_no_fix: "no_fix_available";
def st_triage: "triage_needed";
def st_closed: "closed";
def closed_seen_fixed: "seen_fixed";
def closed_withdrawn: "advisory_withdrawn";
def closed_retired: "root_retired";
# Runtime finding states (lib/watch/runtime.sh writes them).
def rt_update_available: "update_available";
def rt_current_as_of: "current_as_of";
def rt_pre_announced: "pre_announced";
def rt_vendor_feed_missing: "vendor_feed_missing";
def rt_feed_unavailable: "feed_unavailable";
def runtime_states: [rt_update_available, rt_current_as_of, rt_pre_announced, rt_vendor_feed_missing, rt_feed_unavailable];

# Event delivery states. pending -> claimed -> dispatched | unknown.
# Nothing returns a claim to pending; time does not either.
def ev_pending: "pending";
def ev_claimed: "claimed";
def ev_dispatched: "dispatched";
def ev_unknown: "unknown";

# Remediation states a consumer records on a finding. report_acknowledged is
# the owner's judgment of a finding that only reports (see set_remediation); it
# records a decision, not a repair. A deployment judgment is separate from
# the scan's local closure and replaces the existing deployment record.
def rm_awaiting_deploy: "awaiting_deploy";
def rm_deploy_resolved: "deploy_resolved";
def remediation_states: ["dispatched", "blocked", "fix_failed", rm_awaiting_deploy, "fixed_pending_rescan", "report_acknowledged", rm_deploy_resolved];
# A worker is on it: the finding does not wait for the owner.
def remediation_in_progress: ["dispatched", "fixed_pending_rescan"];
# Finding states that report and that nobody can fix by a repair here: no fixed
# version, or a runtime whose next step is an install decision.
def report_only_states: [st_no_fix, rt_update_available, rt_pre_announced];

def is_closed: .state == st_closed;

def empty_state:
  {schema: watch_schema, generation: 0, scan_generation: 0, last_scan: null,
   last_full_scan: null, last_success_at: null, population: null, roots: {}, findings: {}, unmeasured: [],
   runtime: null, ledger: null, diff: {new: [], closed: [], changed: []}, errors: [],
   events: [], error_streaks: {}, summary: null};

# Is this a document a reader may consume?
def is_watch_state:
  type == "object" and .schema == watch_schema and (.generation | type) == "number"
  and (.findings | type) == "object" and (.events | type) == "array";

# The scope a finding belongs to: one lockfile of one root, or one runtime
# location. A measured scope that no longer shows a finding closes it.
def scope_of: (.root + "|" + .scope);

def day_of($ts): ($ts // "" | .[0:10]);

# What a finding reports, without when it was seen: the facts an owner's
# report_acknowledged judgment is made on. Each is a field the producer already
# writes (lib/watch/lockfiles.sh, lib/watch/scan.sh): the state, the fixed
# versions as a set, the advisory and its record ids, its URL and date, the
# reason, the vendor's latest and the KEV answer. first_seen, last_seen and
# the other times a scan stamps are not in it, so a scan that only saw the
# finding again leaves it as it was. KEV preserves the producer's three answers:
# listed (true), not listed (false), and unknown (null). An outage or recovery
# changes the report just as a listing does; the scan's errors remain separate.
def report_fact:
  {state, fixed: ((.fixed // []) | unique), advisory: (.advisory // null), ids: ((.ids // []) | unique),
   advisory_url: (.advisory_url // null), advisory_date: (.advisory_date // null),
   reason: (.reason // null), latest: (.latest // null), kev: .kev};

# The shape of a report_fact handed back by the owner (--expect): every key and
# no other, each of the type the producers write.
def report_fact_keys: ["advisory", "advisory_date", "advisory_url", "fixed", "ids", "kev", "latest", "reason", "state"];
def is_report_fact:
  type == "object" and keys == report_fact_keys
  and (.state | type) == "string"
  and (.fixed | type) == "array" and all(.fixed[]; type == "string")
  and (.ids | type) == "array" and all(.ids[]; type == "string")
  and all(.advisory, .advisory_url, .advisory_date, .reason, .latest; type == "string" or type == "null")
  and (.kev == null or (.kev | type) == "boolean");

# ---- scan merge --------------------------------------------------------------
# $prior: the last complete document (or empty_state). $m: what this run
# measured (lib/watch/scan.sh builds it). Returns the next document, without
# generation bump (publish does that).
def merge_scan($prior; $m):
  ($m.now) as $now
  | (($prior.scan_generation // 0) + 1) as $scan_generation
  | ($m.scope.kind) as $kind
  | ($m.scope.root // null) as $only
  # A finding is in this run's reach when the run is full, or when it is a root
  # run for its root.
  | def in_reach: ($kind == "full") or (.root == $only);
  ($m.measured_scopes | map({key: ., value: true}) | from_entries) as $measured
  | ($m.unmeasured_scopes | map({key: .scope, value: .reason}) | from_entries) as $why
  | ($m.retired | map({key: .root, value: .evidence}) | from_entries) as $retired
  | ($m.roots | map({key: .path, value: .class}) | from_entries) as $root_class
  | (($m.population.roots // []) | map({key: .path, value: true}) | from_entries) as $in_population
  # Why a scope this run did not measure was not measured. A root that was
  # measured and no longer has the lockfile where the walk looked: lockfile_missing. A root a full
  # run's population no longer lists: removed_from_population. Neither closes
  # anything.
  # A lockfile under a part of the root the walk left out (a network mount
  # inside it, an excluded prefix) was not looked for, so it is not missing.
  # Nor is one under a root whose walk did not finish: scan.sh names that root's
  # scope root|* with root_walk_incomplete.
  | def stale_reason:
      . as $f
      | ([($m.unmeasured_prefixes // [])[] | . as $p | select($p.root == $f.root and ($f.scope | startswith($p.prefix))) | $p.reason] | first) as $hidden
      | $why[scope_of] // $hidden // $why[.root + "|*"]
      // (if $root_class[.root] == "ok" then "lockfile_missing"
          elif $kind == "full" and ($m.population.state // "") == "missing" then "population_missing"
          elif $kind == "full" and $in_population[.root] == null and .root != "@host" then "removed_from_population"
          else "not_measured" end);
  ($m.findings | map({key: .key, value: .}) | from_entries) as $current
  | ($prior.findings // {}) as $old
  # Prior findings, carried forward.
  | (reduce ($old | to_entries[]) as $e ({};
      ($e.value) as $f
      | ($e.key) as $k
      | if ($f | in_reach | not) then .[$k] = $f
        elif ($f | is_closed) and ($current[$k] == null) then .[$k] = $f
        elif $retired[$f.root] != null and ($f | is_closed | not) then
          .[$k] = ($f + {state: st_closed, closed_reason: closed_retired, retired_evidence: $retired[$f.root],
                         closed_at: $now, previous_state: $f.state, stale_measurement: false})
        elif $current[$k] != null then
          ($current[$k] + {last_seen_scan_generation: $scan_generation}) as $c
          | if $c.state == st_closed then
              (if ($f | is_closed) then .[$k] = $f
               else .[$k] = ($f + $c + {first_seen: $f.first_seen, last_seen: $now, closed_at: $now,
                                         previous_state: $f.state, stale_measurement: false}) end)
            elif ($f | is_closed) then
              .[$k] = ($c + {first_seen: $now, last_seen: $now, reopened_from: $f.closed_reason,
                             stale_measurement: false, remediation: null})
            else
              .[$k] = ($f + $c + {first_seen: $f.first_seen, last_seen: $now, stale_measurement: false,
                                  remediation: ($f.remediation // null),
                                  previous_state: (if $f.state != $c.state then $f.state else ($f.previous_state // null) end)})
            end
        elif $measured[($f | scope_of)] == true then
          .[$k] = ($f + {state: st_closed, closed_reason: closed_seen_fixed, closed_at: $now,
                         previous_state: $f.state, stale_measurement: false})
        else
          .[$k] = ($f + {stale_measurement: true, unmeasured_reason: ($f | stale_reason)})
        end))
    as $carried
  # New findings.
  | (reduce ($current | to_entries[]) as $e ($carried;
      if .[$e.key] != null then .
      elif $e.value.state == st_closed then .
      else .[$e.key] = ($e.value + {first_seen: $now, last_seen: $now, last_seen_scan_generation: $scan_generation,
                                   stale_measurement: false, remediation: null})
      end))
    as $findings
  # What changed between the two documents.
  | ([$findings | to_entries[] | select(($old[.key] == null) or (($old[.key] | is_closed) and (.value | is_closed | not))) | select(.value | is_closed | not) | .key]) as $new
  | ([$findings | to_entries[] | select(.value | is_closed) | select($old[.key] != null and ($old[.key] | is_closed | not)) | .key]) as $closed
  | ([$findings | to_entries[] | select($old[.key] != null and ($old[.key] | is_closed | not) and (.value | is_closed | not) and $old[.key].state != .value.state) | .key]) as $changed
  | ([$new[] | {k: ., from: (if $old[.] == null then null else $old[.].state end), to: $findings[.].state}]
     + [$closed[] | {k: ., from: $old[.].state, to: (st_closed + ":" + $findings[.].closed_reason)}]
     + [$changed[] | {k: ., from: $old[.].state, to: $findings[.].state}]) as $transitions
  | ([$transitions[] | {id: (.k + "#" + ((.from // "none") | tostring) + ">" + .to + "#" + $now),
                        kind: "finding", finding: .k, from: .from, to: .to, created_at: $now,
                        status: ev_pending, claim: null, task: null}]) as $new_events
  # Events nobody delivered stay; delivered ones are kept 30 days.
  | (($prior.events // []) | map(select(.status == ev_pending or .status == ev_claimed or .status == ev_unknown
                                         or ((.created_at // "") > ($m.retention_floor // "")))))
    as $kept_events
  # Unmeasured rows: replaced for this run's reach, kept outside it. Scopes
  # whose findings were kept stale for a reason the measurement did not list
  # (a lockfile gone, a root no longer in the population) get a row too.
  | ([$findings[] | select((is_closed | not) and .stale_measurement == true and in_reach)
      | {kind: .unmeasured_reason, root: .root, path: .scope}]
     | map(select(.kind == "lockfile_missing" or .kind == "removed_from_population"))
     | map(if .kind == "removed_from_population" then .path = null else . end)
     | unique_by([.kind, .root, .path])
     | map(. + {reason: .kind, followup: ($m.followups[.kind] // null)})) as $derived
  | ((($prior.unmeasured // []) | map(select(in_reach | not))) + $m.unmeasured + $derived) as $unmeasured
  # Roots: replaced for this run's reach.
  | ((($prior.roots // {}) | with_entries(select(($kind == "root") and (.key != $only))))
     + ($m.roots | map({key: .path, value: .}) | from_entries)) as $roots
  # A failure kind that repeats is counted once a day, not alerted again.
  | (reduce ($m.errors[] | (.kind + "|" + (.root // "-"))) as $ek (($prior.error_streaks // {});
      if .[$ek] == null then .[$ek] = {count: 1, first_at: $now, last_at: $now}
      elif day_of(.[$ek].last_at) == day_of($now) then .
      else .[$ek] = (.[$ek] + {count: (.[$ek].count + 1), last_at: $now}) end)
     | with_entries(select(day_of(.value.last_at) >= ($m.streak_floor // ""))))
    as $streaks
  | ($prior // empty_state)
  + {schema: watch_schema,
     scan_generation: $scan_generation,
     last_scan: $m.scan,
     # The last full scan, which a root scan does not replace: its times, its
     # errors and the runtime that ran it. Null until the first full scan.
     last_full_scan: (if $kind == "full" then ($m.scan + {errors: $m.errors}) else ($prior.last_full_scan // null) end),
     last_success_at: (if ($m.errors | length) == 0 and $kind == "full" then $now else ($prior.last_success_at // null) end),
     population: (if $kind == "full" then ($m.population | del(.roots) + {count: ($m.population.roots | length), excluded: $m.excluded_count, roots: $m.population.roots}) else $prior.population end),
     roots: $roots,
     findings: $findings,
     unmeasured: $unmeasured,
     runtime: (if $kind == "full" then $m.runtime else $prior.runtime end),
     ledger: (if $kind == "full" then $m.ledger else $prior.ledger end),
     diff: {new: $new, closed: $closed, changed: $changed},
     errors: $m.errors,
     events: ($kept_events + $new_events),
     error_streaks: $streaks};

# ---- summary -----------------------------------------------------------------
# The one line every report and the routine print. A sentence that says every
# project was measured is only true when population is fresh and nothing is
# unmeasured or blocked; the line says the numbers, and the caller says the
# sentence only then. The roots a walk was made of come before what was
# measured in them: a root walked partway is counted as incomplete, so a small
# "osv measured" never stands alone for roots that were not read.
# agent_runtime_stale is the runtime of the last scan: true or false for a
# runtime the installer built, by the digest of its checkout; false for a
# checkout, which runs its own files; null when a built runtime's checkout
# could not be read, and then the line says unknown, with the read's words.
def summary:
  ([.findings[] | select(is_closed | not)]) as $live
  | ([.roots[] | .lockfiles[]? ]) as $lf
  | ([.roots[] | select(.class == "ok")]) as $walked
  | (.last_scan.runtime // {}) as $rt
  | {population: (.population.state // "missing"),
     population_count: (.population.count // 0),
     excluded: (.population.excluded // 0),
     roots_walked: ([$walked[] | select(.partial == false)] | length),
     roots_walk_incomplete: ([$walked[] | select(.partial != false)] | length),
     osv_measured: ([$lf[] | select(.kind == "npm" and .status == "measured")] | length),
     native_audit: ([$lf[] | select(.kind == "native" and .status == "measured")] | length),
     unmeasured: (.unmeasured | length),
     unmeasured_by_kind: (.unmeasured | group_by(.kind) | map({key: .[0].kind, value: length}) | from_entries),
     unmeasured_without_followup: ([.unmeasured[] | select((.followup // "") == "")] | length),
     blocked: ([$live[] | select(.remediation.state? == "blocked")] | length),
     open: ($live | length),
     fixable: ([$live[] | select(.state == st_open)] | length),
     triage: ([$live[] | select(.state == st_triage)] | length),
     no_fix: ([$live[] | select(.state == st_no_fix)] | length),
     runtime: ([$live[] | select(.ecosystem == "runtime") | .state] | group_by(.) | map({key: .[0], value: length}) | from_entries),
     stale_findings: ([$live[] | select(.stale_measurement == true)] | length),
     pending_events: ([.events[] | select(.status == ev_pending)] | length),
     claimed_events: ([.events[] | select(.status == ev_claimed)] | length),
     unknown_events: ([.events[] | select(.status == ev_unknown)] | length),
     agent_runtime_stale: (if $rt.built == true then $rt.stale else false end)}
  | . + {complete: (.population == "fresh" and .unmeasured == 0 and .blocked == 0),
         line: ("population \(.population) \(.population_count); roots walked \(.roots_walked)/\(.roots_walked + .roots_walk_incomplete) (\(.roots_walk_incomplete) incomplete); osv measured \(.osv_measured); native audit \(.native_audit); unmeasured \(.unmeasured)"
                + (if .unmeasured > 0 then " (" + (.unmeasured_by_kind | to_entries | map("\(.key) \(.value)") | join(", ")) + ")" else "" end)
                + "; blocked \(.blocked); open \(.open) (fixable \(.fixable), triage \(.triage), no fix \(.no_fix))"
                + (if .agent_runtime_stale == null then
                     "; agent runtime stale unknown" + (if ($rt.error // "") == "" then "" else " (\($rt.error))" end)
                   else "" end))};

# ---- delivery ----------------------------------------------------------------
# Claims up to $limit pending events for $consumer. The caller holds the lock
# and publishes the result before it dispatches anything. $token names this
# call, so its answer is the events it claimed and no earlier claim's.
def claim_events($consumer; $limit; $now; $token):
  ([.events | to_entries[] | select(.value.status == ev_pending) | .key] | .[0:$limit]) as $idx
  | reduce $idx[] as $i (.;
      .events[$i] = (.events[$i] + {status: ev_claimed, claim: {consumer: $consumer, at: $now, token: $token}}));

def claimed_by($consumer):
  [.events[] | select(.status == ev_claimed and .claim.consumer == $consumer)];

# Records what happened to a claimed event: dispatched with the broker's task,
# or unknown when it cannot be told whether anything was submitted. Only the
# consumer that claimed it answers for it.
def ack_event($id; $consumer; $outcome; $task; $now):
  if ([.events[] | select(.id == $id)] | length) != 1 then error("no such event: " + $id)
  elif ([.events[] | select(.id == $id and .status == ev_claimed)] | length) != 1 then
    error("event is not claimed: " + $id)
  elif ([.events[] | select(.id == $id and .claim.consumer == $consumer)] | length) != 1 then
    error("event is claimed by another consumer: " + $id)
  else .events |= map(if .id == $id then . + {status: $outcome, task: $task, acked_at: $now} else . end)
  end;

# report_acknowledged is taken only for a live finding that only reports, only
# with the owner's judgment in words, and only for the report the owner judged:
# $expect is that report_fact, as awaiting_owner printed it. It must equal the
# finding's report_fact now, or nothing is written and the error names the
# report as it is now, for the owner to judge. A scan that changes the report
# later puts the finding back in awaiting_owner. The check and the record are
# one reading of the document the caller holds under the lock. $expect is the
# empty string when it was not given. deploy_resolved also binds a judgment
# to these facts, and to the task of the deployment record it replaces.
def deploy_refusal($key; $reason; $f):
  error("deploy remediation refused, nothing written: " + $reason + ": " + $key
        + "; current: " + (if $f == null then null else
          ($f | {state, closed_reason: (.closed_reason // null),
                 remediation: (.remediation | {state, task, at}), report_fact: report_fact}) end | tojson));

def set_remediation($key; $state; $detail; $task; $expect; $now):
  .findings[$key] as $f
  | if $f == null then
      (if $state == rm_deploy_resolved then deploy_refusal($key; "no such finding"; $f)
       else error("no such finding: " + $key) end)
    elif (remediation_states | index($state)) == null then error("not a remediation state: " + $state)
    elif $state == rm_deploy_resolved then
      ($f | report_fact) as $fact
      | ($expect | try fromjson catch null) as $e
      | if ($f | is_closed | not) then deploy_refusal($key; "deploy_resolved needs a closed finding"; $f)
        elif $f.remediation.state != rm_awaiting_deploy then
          deploy_refusal($key; "deploy_resolved needs the current awaiting_deploy record"; $f)
        elif $f.remediation.task == null or $f.remediation.task != $task then
          deploy_refusal($key; "--task must match the record; link the task/plan first: re-record awaiting_deploy --task"; $f)
        elif (($detail // "") | test("\\S") | not) then
          deploy_refusal($key; "deploy_resolved needs --detail: deployed or not needed, with the linked evidence"; $f)
        elif ($e | is_report_fact | not) then
          deploy_refusal($key; "deploy_resolved needs --expect: the complete report_fact you judged"; $f)
        elif ($e | report_fact) != $fact then
          deploy_refusal($key; "the report is not the one you judged; judge the current report and linked evidence again"; $f)
        else .findings[$key].remediation =
          {state: $state, detail: $detail, task: $task, at: $now, seen: $fact, resolves: $f.remediation}
        end
    elif ($f | is_closed) and $f.remediation.state == rm_awaiting_deploy and $state != rm_awaiting_deploy then
      deploy_refusal($key; "a closed awaiting_deploy record can only be linked again or ended with deploy_resolved"; $f)
    elif $state != "report_acknowledged" then
      (if $expect != "" then error("--expect goes with --state report_acknowledged or deploy_resolved only")
       else (.scan_generation // 0) as $sg
         | .findings[$key].remediation = ({state: $state, detail: $detail, task: $task, at: $now}
             + (if $state == "fixed_pending_rescan" then {scan_generation: $sg} else {} end)) end)
    elif ($f | is_closed) then error("report_acknowledged needs a live finding; this one is closed: " + $key)
    elif (report_only_states | index($f.state)) == null then
      error("report_acknowledged is for a finding that only reports (" + (report_only_states | join(", ")) + "), not " + ($f.state | tostring) + ": " + $key)
    elif (($detail // "") | test("\\S") | not) then error("report_acknowledged needs --detail: the owner's judgment, in words")
    elif $expect == "" then
      error("report_acknowledged needs --expect: the report_fact of the awaiting_owner row you judged, as watch status printed it")
    else
      ($expect | try fromjson catch null) as $e
      | ($f | report_fact) as $fact
      | if ($e | is_report_fact | not) then
          error("--expect is not a report_fact (exactly the keys " + (report_fact_keys | join(", ")) + "): " + $expect)
        elif ($e | report_fact) != $fact then
          error("report_acknowledged refused, nothing written: the report is not the one you judged. Judge this one: " + ($fact | tojson))
        else .findings[$key].remediation = {state: $state, detail: $detail, task: $task, at: $now, seen: $fact}
        end
    end;

# Findings that wait for the owner's judgment, with why: unassigned
# (no remediation), blocked or fix_failed (work that stopped),
# acknowledged_other_state (a report_acknowledged made on another report),
# rescan_still_live (a measurement after fixed_pending_rescan still saw it),
# rescan_order_unknown (an old record without a scan boundary), awaiting_deploy
# (a nonfailure needing deployment ownership, including locally closed
# findings), or unrecognized_remediation. Only deploy_resolved ends a closed
# deployment wait; event delivery and the scan's local closure do not.
# The same lock orders scans and remediation writes. A record captures the
# document's scan_generation; only seeing this finding advances its own
# last_seen_scan_generation. Neither wall time nor an unrelated scan proves
# that the finding was measured after the record. Legacy records cannot prove
# this order: the owner records the boundary again before a new scan.
# Each row carries the finding's report_fact, which the owner hands back with
# report_acknowledged or deploy_resolved.
def awaiting_owner:
  [.findings | to_entries[]
   | .value as $f
   | select(($f | is_closed | not) or $f.remediation.state == rm_awaiting_deploy)
   | ($f.remediation.state? // null) as $r
   | (if $r == null then "unassigned"
      elif $r == "blocked" or $r == "fix_failed" then $r
      elif $r == "report_acknowledged" then
        (if $f.remediation.seen == ($f | report_fact) then null else "acknowledged_other_state" end)
      elif $r == rm_awaiting_deploy then rm_awaiting_deploy
      elif $r == "fixed_pending_rescan" then
        (if ($f.remediation.scan_generation | type) != "number" then "rescan_order_unknown"
         elif ($f.last_seen_scan_generation // 0) > $f.remediation.scan_generation then "rescan_still_live"
         else null end)
      elif (remediation_in_progress | index($r)) != null then null
      else "unrecognized_remediation" end) as $why
   | select($why != null)
   | {key, state: $f.state, closed_reason: ($f.closed_reason // null), root: $f.root, ecosystem: $f.ecosystem, package: $f.package, version: $f.version,
      fixed: $f.fixed, report_fact: ($f | report_fact), remediation: $f.remediation, why: $why}]
  | sort_by(.key);
