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
# records a decision, not a repair.
def remediation_states: ["dispatched", "blocked", "fix_failed", "awaiting_deploy", "fixed_pending_rescan", "report_acknowledged"];
# A worker is on it: the finding does not wait for the owner.
def remediation_in_progress: ["dispatched", "awaiting_deploy", "fixed_pending_rescan"];
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
# finding again leaves it as it was.
def report_fact:
  {state, fixed: ((.fixed // []) | unique), advisory: (.advisory // null), ids: ((.ids // []) | unique),
   advisory_url: (.advisory_url // null), advisory_date: (.advisory_date // null),
   reason: (.reason // null), latest: (.latest // null), kev: (.kev // null)};

# ---- scan merge --------------------------------------------------------------
# $prior: the last complete document (or empty_state). $m: what this run
# measured (lib/watch/scan.sh builds it). Returns the next document, without
# generation bump (publish does that).
def merge_scan($prior; $m):
  ($m.now) as $now
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
          ($current[$k]) as $c
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
      else .[$e.key] = ($e.value + {first_seen: $now, last_seen: $now, stale_measurement: false, remediation: null})
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
     scan_generation: (($prior.scan_generation // 0) + 1),
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
# sentence only then.
def summary:
  ([.findings[] | select(is_closed | not)]) as $live
  | ([.roots[] | .lockfiles[]? ]) as $lf
  | {population: (.population.state // "missing"),
     population_count: (.population.count // 0),
     excluded: (.population.excluded // 0),
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
     unknown_events: ([.events[] | select(.status == ev_unknown)] | length)}
  | . + {complete: (.population == "fresh" and .unmeasured == 0 and .blocked == 0),
         line: ("population \(.population) \(.population_count); osv measured \(.osv_measured); native audit \(.native_audit); unmeasured \(.unmeasured)"
                + (if .unmeasured > 0 then " (" + (.unmeasured_by_kind | to_entries | map("\(.key) \(.value)") | join(", ")) + ")" else "" end)
                + "; blocked \(.blocked); open \(.open) (fixable \(.fixable), triage \(.triage), no fix \(.no_fix))")};

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

# report_acknowledged is taken only for a live finding that only reports, and
# only with the owner's judgment in words. It keeps the report it was made on
# (seen), so a scan that changes the report puts the finding back in
# awaiting_owner. The check and the snapshot are one reading of the document
# the caller holds under the lock.
def set_remediation($key; $state; $detail; $task; $now):
  .findings[$key] as $f
  | if $f == null then error("no such finding: " + $key)
    elif (remediation_states | index($state)) == null then error("not a remediation state: " + $state)
    elif $state != "report_acknowledged" then .findings[$key].remediation = {state: $state, detail: $detail, task: $task, at: $now}
    elif ($f | is_closed) then error("report_acknowledged needs a live finding; this one is closed: " + $key)
    elif (report_only_states | index($f.state)) == null then
      error("report_acknowledged is for a finding that only reports (" + (report_only_states | join(", ")) + "), not " + ($f.state | tostring) + ": " + $key)
    elif (($detail // "") | test("\\S") | not) then error("report_acknowledged needs --detail: the owner's judgment, in words")
    else .findings[$key].remediation = {state: $state, detail: $detail, task: $task, at: $now, seen: ($f | report_fact)}
    end;

# The live findings that wait for the owner's judgment, with why: unassigned
# (no remediation), blocked or fix_failed (work that stopped),
# acknowledged_other_state (a report_acknowledged made on another report), or
# unrecognized_remediation (a value this definition does not know). A finding a
# worker is on and a report_acknowledged that still holds do not wait.
def awaiting_owner:
  [.findings | to_entries[]
   | .value as $f
   | select($f | is_closed | not)
   | ($f.remediation.state? // null) as $r
   | (if $r == null then "unassigned"
      elif $r == "blocked" or $r == "fix_failed" then $r
      elif $r == "report_acknowledged" then
        (if $f.remediation.seen == ($f | report_fact) then null else "acknowledged_other_state" end)
      elif (remediation_in_progress | index($r)) != null then null
      else "unrecognized_remediation" end) as $why
   | select($why != null)
   | {key, state: $f.state, root: $f.root, ecosystem: $f.ecosystem, package: $f.package, version: $f.version,
      fixed: $f.fixed, remediation: $f.remediation, why: $why}]
  | sort_by(.key);
