# Day 4.1

## The question Day 3 left open

> Can a single management authority reconcile an active-active workload of N
> replicas, one per logical execution domain, using desired cardinality and
> fresh occupancy discovery without persisting a placement table, replica
> slots, member locators, or operation history?

Day 2 made a surviving realization rediscoverable. Day 3 separated moving
management authority from moving that realization, then enforced stale Start
rejection at the local creation boundary.

Neither result answered what should happen when more than one realization is
actually desired across distinct execution domains. Until now, two matching
children meant explicit ambiguity.

## Prior learning

I expected active-active replicas to occupy separate execution or fault domains,
without necessarily needing a durable table of member assignments. That is
prior architectural learning, not a result of this experiment.

Day 1 had already made another distinction concrete: a returned Start is not
readiness. Increasing the desired count must not turn every not-yet-ready
child into a reason to create another one.

The experiment is whether those two ideas can coexist with rediscovery and
the authority boundary already earned. It is not permission to introduce a
remote placement framework, a worker service, or remembered replica operations.

## Before the change

The tree was clean on `main` at
`4cfd31d5315373ca8e3d53ef75a64b6f066b6bd1`.

The first uncommitted attempt reconciled an undifferentiated pool of three
processes. Its count and recovery tests passed, but that was too weak a
question: it did not distinguish three children in separate domains from three
children in the same one. I redirected the checkpoint before committing it.
Those flat-pool runs are not validation evidence for the domain-aware result.

Intent contained only `WorkloadId` and `Desired`. A child exposed the logical
workload GUID and its own incarnation run GUID. Native process identity and
the readiness event supplied independent evidence about that incarnation.

The missing intent was the desired count. The missing operational relationship
was which domain each live incarnation occupied. The count belongs in intent;
occupancy must be exposed by the realization and rediscovered.

## The smallest change tried

`intent <state-file> [--replicas <count>]` accepts a positive integer.
Explicit multi-replica intent has this shape:

```json
{
  "WorkloadId": "<logical workload id>",
  "Desired": "Running",
  "Replicas": 3
}
```

`Replicas` is nullable and omitted when unspecified. The ignored
`EffectiveReplicas` helper supplies one and validates the count. Default
intent remains byte-for-byte the original two-property JSON; neither a null
property nor the helper leaks into serialization. Invalid counts fail before
intent is saved, and invalid stored counts fail when management loads them.

`DiscoverAll` reuses the existing Windows/session/assembly-path discovery,
logical-ID correlation, native start-time validation, and readiness checks.
It returns live `Starting` and `Running` members ordered by UTC start ticks,
then PID, then run ID. That order is diagnostic, not a slot assignment.

For multi-replica intent the available logical domain pool is deterministically
`domain-1` through `domain-N`. A multi-replica child adds its target domain as
one final launch argument. Discovery recovers it from the live command line.
No domain list, assignment, or map is written into `PlatformState`.

For effective count one, `Discover` retains its explicit multiple-match
failure, the original child launch arguments, and the existing observation
and convergence logs. Domain-less children remain valid in that mode.

For larger counts, each pass observes the set:

```text
liveCount = runningCount + startingCount
invalid domain occupancy  -> explicit isolation error; no Start
liveCount < desired       -> create in the first unoccupied domain
liveCount == desired      -> wait if any member is Starting
all desired domains ready -> count a matching observation
```

Before deciding any Start, the manager rejects duplicate occupancy in any
domain, an unrecognized or missing domain, or a total above the desired count.
The exception names domain occupancy and PIDs, distinguishes collisions from
unrecognized domains, and says `No Start issued.` A collision is invalid even
when the total is no greater than the desired count and another domain is empty.

Convergence requires two consecutive observations with one ready realization
in every desired domain. Observation and convergence logs include each
`domain`, state, PID, native UTC start ticks, and run ID. A successful
multi-replica creation resets the pending counter, so filling a larger fleet
does not itself consume the existing 100-pending-observation limit. An
occupied but never-ready fleet still has
that bounded failure, not a remediation policy.

The creation path is shared with the single-replica path. With an authority
file, every Start uses both the existing manager pre-check and the checked
`Workload.Start` boundary. The separate scalar grant and mutex are unchanged.
Without that file, the earlier unenforced mode remains.

## The executable experiment

`tests\day-04.1.ps1` uses 600 ms startup delays and an opt-in named-event
readiness gate. The child waits before signaling its own readiness event;
releasing the gate does not assert readiness on the child's behalf.
The helper clears the inherited fault flag unless a test explicitly sets it.

The test holds a cold fleet at three `Starting` members in three distinct
domains across repeated observations, checks that no fourth Start or
convergence occurs, then releases readiness. It kills the verified `domain-2`
incarnation after convergence and
checks one replacement specifically in `domain-2`, retaining both survivors
in `domain-1` and `domain-3`.

For the partial-fleet handoff, A pauses after creating `domain-1` at
the existing former-pre-locator-save fault point. The test verifies its one
child is alive and not ready, then kills A by its known PID. This is a
fault-paused exit, not a claim of cooperative relinquishment. The source
advances the grant, and B must rediscover `domain-1` while still `Starting`,
create only `domain-2` and `domain-3`, and converge after readiness is released.

The isolation experiment first injects two children into `domain-1` and one
into `domain-2`, leaving `domain-3` empty. One colliding child is `Starting` and
the other `Running`. Management must fail despite `liveCount == 3`, not fill
the empty domain or mistake total count for valid placement.

Separate probes inject a child in `domain-99` and a domain-less legacy child
under multi-replica intent. Finally, after the original manager relinquishes,
a fourth child held `Starting` is injected into occupied `domain-1` beside
the three ready fleet members. Each new observing manager must fail explicitly
with zero Starts and leave the inspected children untouched. That zero is a
lifetime Start count, not a subtraction from an earlier manager's operations.

At each key boundary the test independently checks native process-start
ticks, WMI creation time and command-line workload/run IDs, current session,
and per-incarnation readiness. It compares intent bytes throughout, validates
the default serialization, and rejects non-positive new and stored counts.
Logs, result JSON, and timestamped external inspections are diagnostic evidence,
not operational state loaded by management.

## What the final complete run showed

These are measurements from the second domain-aware `tests\all.ps1` run,
not the earlier flat-pool runs. Its evidence directory was
`.state\day-04.1-94f9e2c0538f44c5af23c3343058d752`.
All times below are UTC on November 12, 2026.

### Three occupied domains before readiness

Manager **18264**, native start ticks `639301164233500744`, ran under epoch
**1** for workload `9de42870-4a55-498f-95ca-aa0b88b9d0d9`.
It created these three incarnations:

| Domain | PID | Native UTC start ticks | Run ID |
| --- | --- | --- | --- |
| domain-1 | 7360 | 639301164236968529 | b54457ef-c92d-4408-bde2-1ebe98cbb656 |
| domain-2 | 27552 | 639301164238973173 | ec93a677-83c7-47a5-8951-61674100bc9f |
| domain-3 | 4828 | 639301164240830876 | c913949c-721d-412b-9ac9-6c23323038ea |

Observation 4 at **21:40:24.2792300** reported `runningCount=0`,
`startingCount=3`, and `liveCount=3`. All three domains were occupied while
readiness was held. Repeated pending observations issued no fourth Start.

External inspection of **7360** at **21:40:24.4772045** independently found
native ticks `639301164236968529`, WMI creation time
`21:40:23.696852`, and readiness **false**. Its live application arguments
ended with:

```text
--workload 9de42870-4a55-498f-95ca-aa0b88b9d0d9 b54457ef-c92d-4408-bde2-1ebe98cbb656 600 domain-1
```

The same native/command-line/readiness checks covered the other members.
After readiness was released at **21:40:24.4970046**, observations 7 and 8
at **21:40:24.8373651** and **21:40:25.0084881** independently reported all
three `Running`. Convergence recorded `starts this manager=3`.

### Replace domain-2, not the fleet

I killed **27552** in `domain-2` at **21:40:25.2145670**. Observation 10
at **21:40:25.3968335** found exactly two `Running` members: **7360** in
`domain-1` and **4828** in `domain-3`.

The only new incarnation was **7736**, in `domain-2`, with native ticks
`639301164253990404` and run ID
`6144bd9e-5e04-4ef2-a065-74618d818a8b`. Both survivors retained the exact
PIDs, ticks, and run IDs in the first table.

Observations 14 and 15 at **21:40:26.1688308** and **21:40:26.3508136**
again found three ready distinct domains. The cumulative Start count was
**4**, not six. Discovery order now placed the newer `domain-2` incarnation
after `domain-3`; domain occupancy did not depend on array position.

### Move authority while domain-1 is still Starting

For workload `4c60ab2c-40fa-417d-aea8-b63450743d1c`, A was manager
**14508**, native ticks `639301164269361961`, under epoch **1**.
It paused after creating only **29336** in `domain-1`, still `Starting`.
After A's fault-paused exit, grant 2 committed at **21:40:27.5558563**.

B was manager **23808**, native ticks `639301164275657248`, under epoch
**2**. Its first observation at **21:40:27.9124040** rediscovered **29336**
as `Starting` in `domain-1`. B's two Starts filled only the missing domains:

| Domain | PID | Native UTC start ticks | Run ID | Created by |
| --- | --- | --- | --- | --- |
| domain-1 | 29336 | 639301164272814161 | 188aa1eb-efc2-4fa2-81ab-bd876cf674a3 | A |
| domain-2 | 28072 | 639301164279193467 | 071744ff-97b2-4c52-9028-f6f0e1f96f30 | B |
| domain-3 | 26548 | 639301164281080510 | 2c748e69-c41c-4d30-aaec-1f3bdfb3935d | B |

At **21:40:28.2873270**, B observed all three `Starting`, with no domain
available for another Start. Readiness was released at **21:40:28.3796124**.
Observations 7 and 8 at **21:40:29.0039269** and **21:40:29.1872805**
found all three ready and converged. The lifetime Start counts were **1 / 2**.
No persisted assignment told B that `domain-1` was occupied.

### A count of three is not enough

The separate isolation workload was
`4378b9a9-6a0a-491a-a626-e97ad4c107d5`. Its first probe had ready **23324**
and pending **17476** in `domain-1`, plus ready **17680** in `domain-2`.
`domain-3` was empty. Despite `liveCount=3`, management failed with:

```text
occupancy=[domain=domain-1,pids=23324,17476; domain=domain-2,pids=17680];
collisions=[domain-1]; unrecognized=[]; desiredReplicas=3; liveCount=3.
No Start issued.
```

The next probes rejected pending **27696** in `domain-99` and pending
domain-less **21220**, reporting `unrecognized=[domain-99]` and
`unrecognized=[<none>]` respectively.

Finally, pending **22600** was injected into `domain-1` beside the repaired
ready fleet. The error named `domain-1` PIDs **7360,22600**, `domain-3`
PID **4828**, and `domain-2` PID **7736**, with `liveCount=4`.
All four observing managers exited with `InvalidOperationException`
(`-532462766`) and **0** lifetime Starts. None selected a cleanup victim.

Every scenario retained the original intent bytes: only `WorkloadId`,
`Desired: Running`, and `Replicas: 3`. The separate default-intent probe
retained the original two-property bytes. Domain occupancy never entered
either intent representation.

## How this differs from the earlier days

Day 2 recovered the relationship between intent and one surviving realization.
Day 3 tested continuity and permission to create across authority movement.

Day 4.1 changes what matching intent means. Three matching children are valid
only when they occupy the three recognized distinct domains. Three children
in two domains are not converged. The logical workload identity and incarnation
identity retain their meanings; a multi-replica child now also exposes its
logical execution domain, not a creator epoch or persisted replica slot.

Nor did authority acquire a new meaning. The partial-fleet test uses the same
source and creation fence, not a new coordination mechanism for each member.

`tests\all.ps1` still exports Day 1 at `0ab3e5c`, Day 2.1/2.2 at `ab24103`,
and Day 3.2 at `a7665e7`. It runs current Day 2.3, Day 3.1, and Day 3.3 before
Day 4.1. A passing historical failure test means the old failure was reproduced,
not repaired retroactively. No earlier notebook was rewritten.

## What surprised me

The first surprise was methodological. A passing count-based test could still
ask too little of an active-active model. The same-domain collision with an
empty domain made the missing requirement executable.

The more useful adjustment was to the meaning of waiting.

With one desired child, observing `Starting` meant not issuing another Start.
With three desired domains, one `Starting` member means its domain is occupied,
but two other domains are still missing realizations. Waiting merely because
anything is starting would serialize startup unnecessarily. Ignoring pending
members would overshoot.

The distinction that survived was not "Starting means wait." It was:

> Count pending realizations as domain occupancy, and create only in a missing domain.

Recovery then replaced the missing `domain-2` member without reading a saved
assignment. The two survivors did not need to be renamed, renumbered, or restarted.

## What became uncomfortable

These domains are logical labels on one Windows machine. They do not isolate
CPU, memory, process trees, machine failures, or power. This tests a placement
invariant over fresh metadata, not physical fault independence, application
data consistency, load balancing, or real placement across worker nodes.

The domain pool is derived from the count rather than discovered from a node
inventory. It is an explicit simulation boundary. Domain labels distinguish
execution locations; a replacement has a new incarnation in the same domain.
There is no persisted per-domain member locator or assignment.

Discovery is still a sequence of inspections, not an atomic fleet snapshot.
The authority mutex orders grant advancement with creation; it does not make
discovery and creation one transaction. Two managers incorrectly launched with
the same current epoch can still act from overlapping deficit observations.
An out-of-protocol creator can still inject a collision or surplus, as this
test does.
Cardinality convergence is observed evidence, not a permanent global invariant.

Authority enforcement remains cooperative and limited to the same Windows
session and authority-file protocol. The existing stalled-creation liveness
cost and source-recovery questions remain. This is not distributed consensus
or remote-node fencing.

Invalid occupancy is explicit but unresolved. The manager fails without
selecting or stopping a victim. The test's process kills and teardown are external
administration, not an implementation of fenced Stop or scale-down. Killing
one member for the recovery experiment does not settle victim selection.

Intent is still loaded once per manager. This checkpoint does not add a live
scaling command or intent-update protocol. A full but never-ready fleet still
eventually throws after the pending-observation limit. Readiness is still
initial startup evidence, not ongoing application health. Three replicas
exercise the cardinality rules; they do not establish large-fleet performance.

## What I currently believe

**Prior:** active-active realizations should occupy distinct execution domains,
and fresh occupancy may avoid a durable placement table.

**Observed:** one authority created one child per domain while counting pending
occupancy, replaced only `domain-2` while preserving `domain-1` and `domain-3`,
and recovered partial placement across epochs 1 and 2 with Start counts
`1 / 2`. A same-domain collision at total three, unknown and missing domains,
and excess occupancy all caused explicit rejection with zero Starts. Intent
bytes did not change.

**Interpretation:** desired cardinality plus the deterministic logical domain
pool was sufficient configuration for these local cases. Realizations exposed
their domains, and fresh discovery reconstructed occupancy without persisted
placement state. This does not show that assignments can never earn a durable
role or that logical labels provide physical fault isolation.

## Validation and checkpoint

I built the domain-aware code with:

```powershell
dotnet build .\ControlPlaneExperiment.slnx
```

The result was **0 warnings and 0 errors**. I then ran each of these twice,
in fresh shells, after the domain-aware changes:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\day-04.1.ps1
pwsh -NoLogo -NoProfile -File .\tests\all.ps1
```

| Run | Result | Cold domain-1 / domain-2 / domain-3 PIDs | Replacement in domain-2 |
| --- | --- | --- | --- |
| Focused first | PASS | 10340 / 14052 / 26536 | 18652 |
| Focused repeat | PASS | 33380 / 27424 / 16140 | 24432 |
| Complete first | PASS | 5024 / 24396 / 12144 | 30196 |
| Complete repeat | PASS | 7360 / 27552 / 4828 | 7736 |

Each run checked the partial-domain handoff, all four isolation failures,
native identities and readiness, and unchanged intent bytes. Both complete
runs also passed the historical and current Day 1 through Day 3 checks,
including the single-replica byte and behavior assertions. The earlier
flat-pool runs and the cancelled superseded repeat do not count toward
these four passes.

Before checkpointing, I copied the final evidence out of the repository,
verified no experiment-owned processes remained, and removed **23** exact
task-created `.state` directories, including the cancelled historical export.
The four pre-existing directories were preserved. No earlier notebook,
historical test, or authority-grant implementation changed. I did not push.

## Questions earned by this checkpoint

When four live realizations exist but only three are desired, which one should
be removed, and what evidence makes that selection legitimate?

Where must Stop be fenced so a stale removal cannot damage a surviving
incarnation after authority moves?

What would real worker-node placement and independently failing domains require
that these local labels and local discovery cannot expose?

These are questions left by Day 4.1, not mechanisms added to make its surplus
failure disappear. I stop here without starting Day 4.2.
