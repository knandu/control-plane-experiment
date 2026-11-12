# Day 4.2

## The question Day 4.1 left open

> When fresh discovery finds more realizations than intent permits, can one
> authority remove the right incarnation without remembering a victim list,
> and reject a removal whose authority has become stale?

Day 4.1 made three different situations visible: an absent domain, a domain
occupied by a Starting realization, and invalid occupancy. It could fill the
first, wait for the second, and only fail on the third.

That failure was evidence, not an unfinished cleanup loop to erase from history.
Three children in two domains did not satisfy three-domain intent, even when
the total count happened to be right.

## Prior learning

I expected removal to need at least as much care as creation. A stale Start
can create an extra realization. A stale Stop can destroy a useful one.
I also expected a PID alone to be too weak an address for a destructive action.

Those are priors. Day 3 had demonstrated the local creation fence, not a
termination fence. Day 4.1 had detected collisions, not earned a keeper policy.
The new experiment is deliberately narrower than a general lifecycle manager.

## Before the change

The tree was clean on `main` at
`c11d024ef6bb2f3e79546ae3a93bfd48261c1f7c`.

Intent already held `WorkloadId`, `Desired`, and an optional `Replicas`.
Realizations exposed their logical domain and incarnation identity. Fresh set
discovery already separated Starting occupancy from ready occupancy.

What was missing was a legitimate way to lower the count, a deterministic
choice when occupancy conflicted with intent, and a checked termination effect.
None of those required storing the observed set or the chosen victim.

## The smallest change tried

### Change only explicit cardinality intent

Default `intent <file>` still refuses to overwrite an existing file, with
the same error and original two-property JSON when creating default intent.

Only `intent <file> --replicas <count>` may update an existing intent.
It preserves the logical workload ID and desired state, validates the new
positive count, and uses the existing flushed temporary-file replacement.
No domain map, victim list, last observation, or operation history enters
`PlatformState`. Test logs and result files are diagnostic evidence, not
state loaded by management.

Managers still load intent once. In these experiments I relinquish the old
manager, update the count, then launch management against the revised intent.
This does not introduce live intent reload or a concurrent-writer protocol.

### Classify before acting

For multi-replica intent, target domains remain `domain-1` through `domain-N`.
A canonical positive 32-bit domain number outside that range is now removable
surplus, rather than an unrecognized label. For example, `domain-99` is valid
numbered surplus when the desired count is three.

Missing labels, arbitrary names, zero, and noncanonical forms such as
`domain-01` still cause explicit isolation failure before any Start or Stop.
A malformed member blocks remediation for that observation; I do not quietly
ignore it while acting on the others.

Every observation selects at most one effect:

```text
malformed or missing domain -> explicit failure; no effect
numbered surplus           -> Stop one surplus incarnation
target-domain collision    -> Stop one non-keeper
clean occupancy deficit    -> Start in the first missing domain
full occupancy, not ready  -> wait
all target domains ready   -> count a matching observation
```

Surplus is removed before target-domain collisions. The highest numbered
surplus domain goes first, numerically rather than lexically. Within it,
Starting precedes Running, then newest native start ticks, highest PID, and
descending run ID break ties.

Otherwise I choose the first colliding target domain in numeric order. Its
keeper prefers Running over Starting, then earliest native start ticks,
lowest PID, and ascending run ID. Among non-keepers, the victim prefers
Starting, then newest ticks, highest PID, and descending run ID.

This is an explicit experimental policy, not proof that the oldest ready
application instance always has the best data or should survive every workload.
Fresh discovery chooses again after each effect. Nothing persists that choice.
Convergence still needs two consecutive all-ready observations of the desired
distinct domains, and multi-replica logs now include lifetime Start and Stop
counts for that manager.

### Verify the incarnation at the termination boundary

A Stop decision gets the existing manager pre-check and can pause before its
effect. Inside `Workload.Stop`, the authority source's same-session mutex checks
the offered epoch at `process termination` and remains held through the effect.
An independent test gate can pause inside that lock before `Process.Kill`.

The effect opens the selected PID, verifies that the process is still alive
and its native UTC start ticks equal the discovered incarnation, then calls
`Kill(entireProcessTree: true)` and waits up to 5000 ms for the root to exit.
Successful termination is logged before the authority lock is released.

An already-absent target or mismatched incarnation produces an explicit
`Termination skipped` diagnostic and does not increase the successful Stop
count. Access errors and termination timeouts remain errors, not success.
The test exercises the actual Stop method with a real live PID and wrong
expected ticks; it does not wait for accidental PID reuse.

Without an authority file, the operation retains the existing cooperative,
unfenced mode. With the file, the grant protocol and mutex are unchanged.
No creator epoch was added to children or workload intent.

## The executable experiments

The first experiment converges three domains, exits management, updates the
same intent to two, and launches management again. Only `domain-3` may be
removed. Domains 1 and 2 must retain their exact PIDs, native ticks, and run IDs.
The new manager must converge with zero Starts and one Stop.

The second begins with an older Starting child and a newer Running child in
`domain-1`, a Running child in `domain-2`, and no `domain-3`. The Running
incarnation must survive even though it is newer. Management must first stop
the pending duplicate, then create in domain 3. A separate readiness gate holds
that replacement so returned Start cannot be mistaken for convergence.

The third pauses A after a valid Stop decision and manager pre-check under
epoch 1, but before termination. The source commits epoch 2. Releasing A must
fail at `process termination` with zero successful Stops, leaving all three
incarnations independently alive. Only then does B under epoch 2 perform the
valid removal and converge.

The fourth reverses the order. A pauses after the termination authority check,
inside the mutex. A concurrent `grant 2` must report `Authority lock waiting`,
and the file must still contain 1 while the victim remains alive. After release,
native root exit and successful termination must precede the new grant's commit.
B then observes the two survivors and converges without a Start or Stop.

Additional probes make the selection policy distinguishable: numeric domain
10 before 9, surplus before collisions, pending before ready, newest pending
first, and collisions in domain 1 before domain 2 even when domain 2 was
discovered earlier. Four malformed-domain probes refuse all effects. The
incarnation test offers the real PID with expected ticks off by one and checks
that the actual child survives; an absent-target probe checks the explicit no-op.

The process tests independently inspect live command lines, current session,
native start ticks against WMI microsecond creation time, and each run's
readiness event. They check survivor identities and durable intent bytes.
An opened native process handle supplies the exit timestamp in the locked
termination experiment; manager log ordering alone is not that evidence.

## What actually happened

These are measurements from the second complete `tests\all.ps1` run, not the
earlier focused passes. Its Day 4.2 evidence directory was
`.state\day-04.2-665f4dc3d5544df8843fe400aa468e50`. All times below are UTC on
**November 12, 2026**. Native ticks and run IDs are reproduced without rounding.

### Three domains become two

Workload `f2c26166-7fb0-48f8-8c8e-dcb0c05276fd` retained its identity when the
explicit intent update changed only `Replicas` from 3 to 2.

| Domain | PID | Native start ticks | Run ID | Result |
|---|---:|---:|---|---|
| domain-1 | 29820 | 639301184354557385 | 8ae19555-4a96-4bb7-b3dc-a8f74d867846 | Preserved |
| domain-2 | 13796 | 639301184356601192 | 50cdbe27-a4c1-40b2-907d-50d2775a7555 | Preserved |
| domain-3 | 27592 | 639301184358501465 | 64776fe6-71b8-4924-8892-2993c18f8ef3 | Stopped |

Manager **20292**, epoch 1, selected domain 3 on observation 1 at
`22:13:57.9792857`; termination completed at `22:13:58.0134722`.
Observations 2 and 3 at `22:13:58.1948147` and `22:13:58.3793252` saw the same
two ready survivors. Convergence reported **0 Starts, 1 Stop**.

### Resolve the collision before filling the hole

Workload `378b34a7-d70b-4d0f-bbcc-e93e8c4c3357` began with three children but
only two occupied domains.

| Domain | PID | Native start ticks | Run ID | Result |
|---|---:|---:|---|---|
| domain-1 | 12928 | 639301184389912479 | b0d9e06f-47d9-42e8-942d-262410d1ced3 | Older Starting duplicate stopped |
| domain-1 | 4568 | 639301184391946357 | a93fc83c-83da-4d5a-b5ef-b50bc43c7a76 | Newer Running keeper preserved |
| domain-2 | 10272 | 639301184393252023 | 86c09640-9a61-4fe0-9816-b0f41181bea0 | Preserved |
| domain-3 | 5936 | 639301184401194251 | b53999ed-9b41-49e8-8889-57ce120fcfb2 | Created after removal |

Manager **10312**, epoch 1, chose Stop on observation 1 at `22:13:59.9098511`.
The duplicate exited before the successful termination log at
`22:13:59.9419670`. Only observation 2 selected Start in domain 3, at
`22:14:00.1138357`. Its readiness gate was released at `22:14:00.3931212`.
Observations 7 and 8 at `22:14:01.0182662` and `22:14:01.1943880` were both
all-ready with the original keepers. Convergence reported **1 Start, 1 Stop**.

That is not a count-only repair: the initial live count already equaled three.
The first decision removed a conflicting occupant rather than accepting the
count or creating a fourth child in the missing domain.

### A newer grant rejects the old Stop

For workload `446a2048-f94e-4b0b-bfd5-b5b932f1b604`, A was manager **9396**,
native start ticks `639301184438106280`, epoch 1. Its selected domain-3 victim
was **10392**, ticks `639301184424342657`, run ID
`f1791b5f-10f0-4c2a-88d4-c6b41a2b6d28`.

A passed its manager pre-check and paused before termination at
`22:14:04.1640721`. Grant 2 committed at `22:14:04.3826714`.
After release, A failed explicitly at `22:14:04.3914616`:

```text
Authority rejected: boundary=process termination; offeredEpoch=1; currentEpoch=2
```

Independent native, command-line, and readiness inspection still found all
three original children alive after that rejection. A had **0 Starts, 0 Stops**.

B was manager **5156**, ticks `639301184462514205`, epoch 2. It terminated the
same domain-3 incarnation at `22:14:06.6492918` and converged with
**0 Starts, 1 Stop** after observations at `22:14:06.8352587` and
`22:14:07.0059152`. Domain 1 remained **1124**, ticks `639301184420219407`,
run ID `17db2db4-c45b-4027-9e80-b9ccd3765d29`; domain 2 remained **33388**,
ticks `639301184422217035`, run ID `951370ad-46e5-4f51-83d8-855c8a50ba20`.

### An accepted Stop delays the next grant

For workload `c2c764b6-fe14-483e-821d-6693a88a7fd3`, A was manager **26704**,
ticks `639301184496228821`, epoch 1. Its domain-3 victim was **10504**,
ticks `639301184481878485`, run ID `e19c3f03-5138-4272-9f58-2a933bad7374`.

A paused inside the checked termination lock at `22:14:09.9908593`.
The concurrent grant reported `Authority lock waiting` at `22:14:10.2242268`;
the authority file still contained 1 and the victim was independently ready.

| Evidence | UTC time |
|---|---|
| Test released the checked Stop | 22:14:10.2261740 |
| Native root process exit | 22:14:10.2432484 |
| Successful termination logged under the lock | 22:14:10.2575214 |
| Grant 2 committed | 22:14:10.2620239 |

The ordering was not inferred solely from two manager messages: the native
exit timestamp came from the retained OS process handle.

A completed **0 Starts, 1 Stop**. B, manager **11080**, ticks
`639301184503841671`, epoch 2, converged with **0 Starts, 0 Stops** after
observations at `22:14:10.7556220` and `22:14:10.9326302`. Its survivors were
the originals: domain 1 **33332**, ticks `639301184477862984`, run ID
`f4eb679f-4e65-44a9-83eb-832068f5e4e6`; domain 2 **18236**, ticks
`639301184479885817`, run ID `bc4871e1-f431-47a3-b54f-ad559e8a6db5`.

### Distinguishing the policy from an accidental pass

The nine-member priority probe produced this exact seven-Stop sequence:

```text
domain-10 Starting 32484
domain-10 Running  14148
domain-9  Running  32112
domain-1  Starting 28880  (newer pending)
domain-1  Starting 20252  (older pending)
domain-1  Running   3524  (newer ready)
domain-2  Running   6680  (newer ready)
```

It retained domain-1 **32728** and domain-2 **28876**, with no Starts.
Domain 2 had been discovered before domain 1; numeric collision-domain order,
not discovery order, determined which collision was repaired first.

Missing domain **15176**, `worker-x` **27436**, `domain-0` **24792**, and
`domain-01` **13680** each caused explicit isolation failure with no Start
or Stop. These are not numbered scale-down surplus.

The actual Stop method refused ready PID **31284**, run ID
`754b3b2f-34a3-4b6d-ac32-d16622c5ebda`, when offered expected ticks
`639301184661769920` instead of its native `639301184661769919`.
It logged the mismatch at `22:14:26.3909646`; the independently inspected child
survived. Calling Stop after external cleanup also returned an explicit
absent-target no-op rather than a successful termination.

## Keeping the uncomfortable history

`tests\all.ps1` now exports Day 4.1 at `c11d024` and runs that checkpoint's
own test and implementation. Its collision, unknown-domain, and surplus
failures remain executable before-remediation evidence.

The existing pins for Day 1, Day 2.1/2.2, and Day 3.2 remain. Current Day 2.3,
Day 3.1, and Day 3.3 still exercise single-replica compatibility before current
Day 4.2. No earlier notebook or historical test was rewritten to make the new
behavior appear to have existed earlier.

## Validation and cleanup

The final runtime and test sources passed these commands. Each script invocation
used `pwsh -NoLogo -NoProfile -File` in a fresh shell.

| Validation | Result |
|---|---|
| `dotnet build .\ControlPlaneExperiment.slnx` | 0 warnings, 0 errors |
| `tests\day-04.2.ps1`, first final-code pass | Passed; evidence suffix `10e0faf7cf904facb058cdae1c2a45e0` |
| `tests\day-04.2.ps1`, repeat | Passed; evidence suffix `666a564842634f7ba54dfa1db07f4cb8` |
| `tests\all.ps1`, first | Passed; Day 4.2 evidence suffix `5de2fd4570ea4a4daed9f5c92d4e8255` |
| `tests\all.ps1`, repeat | Passed; Day 4.2 evidence suffix `665f4dc3d5544df8843fe400aa468e50` |

All five builds in each complete run reported zero warnings and zero errors.
The complete runs exercised current single-replica intent bytes, discovery,
handoffs, and creation fencing as well as the pinned historical failures.

The tests cleaned up their owned processes. A final native process inventory
found no remaining experiment processes. I archived the final Day 4.2 evidence
outside the repository and verified all 59 copied files byte-for-byte before
removing the 11 task-created state directories. Only the four pre-existing
Day 2 state directories remained. Nothing was pushed.

## What surprised me

The destructive operation did not require a more elaborate durable record.
It required a more precise operational address and a clear side-effect boundary.
The chosen victim remained a temporary consequence of one observation.

The keeper policy also exposed a distinction that count alone cannot show.
An older pending child is not automatically more valuable than a newer ready
one. Readiness preference and age preference are different choices; the test
needed them to disagree to demonstrate which choice the implementation made.

## What remains uncomfortable

These are logical labels on one Windows machine, not independent fault domains.
The policy does not prove application-level replication safety, data freshness,
quorum preservation, graceful draining, or remote-node placement.

The termination fence remains cooperative, same-session ordering. A stalled
termination inside the mutex delays the next grant, just as a stalled creation
did. Requesting the next epoch does not make it current. This is not consensus,
hostile-caller isolation, or an OS-enforced right to kill.

Discovery and effect are not one transaction. Two managers mistakenly given
the same current epoch can still act from overlapping observations. A running
child can change readiness or disappear after selection. Incarnation checking
protects the addressed process identity, not the freshness of every selection
assumption or the application's right choice of keeper.

The Stop uses a process-tree kill, but these children do not spawn descendants.
The experiment checks the root incarnation and root exit, not independently
verified descendant ownership or termination on a remote worker.

Effective count one deliberately keeps `Workload.Discover` and its original
multiple-realization ambiguity. This is not a scale-down-from-many-to-one
protocol. Updating the count to one does not authorize the multi-domain removal
policy to bypass that compatibility boundary.

The successful-operation counters are diagnostics, not durable truth. A crash
after a kill but before a returned action could lose that log without restoring
the process. This checkpoint does not demonstrate crash recovery at every
termination instruction or a general durability contract for authority.

## What I currently believe

**Prior:** removal needs a trustworthy incarnation address and current authority
at the effect boundary, not just a remembered decision.

**Observed:** fresh discovery supported scale-down and collision repair while
preserving the chosen survivors. The actual Stop refused the wrong native
incarnation. Grant-first rejected a stale termination; termination-first held
grant advancement until native exit and the accepted effect completed.

**Interpretation:** a deterministic keeper policy and fresh rediscovery can
support this bounded local subtractive reconciliation without a durable victim
list. Neither the policy nor the local fence should be mistaken for a general
distributed removal protocol.

## Questions earned

What would make a keeper choice legitimate for application data, rather than
merely deterministic for process identities?

What must change when removal means draining and stopping a realization on a
remote worker instead of killing a local process?

Which crash windows and independently failing domains would force stronger
evidence or a different boundary than this same-session authority protocol?
