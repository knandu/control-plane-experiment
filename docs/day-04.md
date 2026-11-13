# Day 4

Day 3 ended with a boundary: a decision can remain remembered after the authority
to perform it has moved. Creation needed to reject stale authority at the
side-effect boundary, not merely when management made its decision.

Day 4 asked a different question:

> How can one movable management authority reconcile an active-active workload
> across distinct execution domains?

The domains in this experiment are logical labels on one Windows machine.
That qualification matters to both the result and the decision about what
should come next.

Within that model, the strongest result is not simply that I added replicas,
Stop, or health. It is that a movable authority could repair the workload from
durable intent and rediscoverable realization evidence, even when authority
moved between removal and replacement.

**Reconciliation itself became the recovery mechanism.**

## What I brought into the day

I expected replicas to occupy separate execution or fault domains. I expected
one management authority to be sufficient for an active-active workload.
I also expected fresh discovery to remain preferable to a saved operational
workflow.

Those were architectural priors. Day 3 had not demonstrated multi-domain
placement, legitimate removal, or health-aware replacement. It had earned a
local creation fence, not permission to assume those other results.

The useful question was how much additional machinery these cases would
actually require.

## Day 4.1: placement is not just cardinality

The first uncommitted attempt treated three replicas as three undifferentiated
processes in a flat pool. Its count tests passed, but that was the wrong test.
Three live processes in one domain are not the same topology as one in each
of three domains.

I redirected the checkpoint before committing it.

[Day 4.1](day-04.1.md), committed as `c11d024`, made domains explicit:
`domain-1` through `domain-N`, derived deterministically from the desired count.
Each multi-replica child exposed its domain in its live launch arguments.
Management reconstructed occupancy instead of saving assignments.

A Starting realization already occupied its domain. It did not become a reason
to create another child there merely because readiness had not arrived.
Convergence required the desired distinct domains to be Running across two
consecutive observations.

That supported targeted recovery: losing domain-2 did not require replacing
domain-1 or domain-3. It also supported authority movement during partial
placement. The next manager discovered the first Starting occupant and created
only in the remaining domains.

Collisions and surplus deliberately failed at this checkpoint. The manager
could identify contradictory occupancy, but had not yet earned the right
policy or effect for removing it.

The distinction was useful: desired replicas were not just a count.
They described a topology whose occupancy had to be rediscovered.

## Day 4.2: reconciliation sometimes has to subtract

[Day 4.2](day-04.2.md), committed as `9352cd5`, asked what should happen when
reality contained too much or contradictory state.

An explicit count update expressed scale-down without changing logical workload
identity. Numbered surplus and intra-domain collisions became remediable.
Missing or malformed domain labels still failed explicitly rather than being
silently ignored.

Management selected one deterministic victim from the current observation.
It removed surplus before resolving collisions, and resolved those conflicts
before filling a missing domain. Each pass permitted at most one Stop or
one Start.

The destructive effect required more than a PID or an earlier valid decision.
Stop verified the native process incarnation and used the authority boundary
already introduced for creation. A stale termination was rejected; an accepted
termination held the ordering boundary until its effect completed.

Scale-down from three domains to two removed domain-3 while preserving the
original domain-1 and domain-2 incarnations. Collision recovery preserved a
chosen keeper rather than rebuilding the whole fleet.

No persisted victim list was necessary. The next observation selected again
from the world that remained.

Day 4.1's original failures remain replayable at its historical commit.
Adding remediation did not erase the evidence for why it was needed.

## Day 4.3: correct topology can still be unhealthy

The right count in the right domains was not enough.
A child could remain alive in its assigned domain while losing readiness.

But an unset readiness signal alone could not distinguish a child that had
never finished startup from one that had become unhealthy afterward.
Killing every unready occupant would destroy legitimate startups.

[Day 4.3](day-04.3.md), committed as `ba174e8`, put one more piece of evidence
in the realization: a volatile startup-completed witness held for that
incarnation's lifetime.

The two signals answer slightly different questions:

| Evidence | Meaning |
|---|---|
| Readiness | What the child currently exposes as ready |
| Started witness | Whether startup completed in this incarnation's lifetime |

Starting and Degraded are interpretations of that rediscovered evidence,
not states a manager must remember having observed.

This is not a claim that the system contains no memory. The Started witness
remembers something, but it belongs to the live incarnation. It is not a
manager-owned persisted health history. A cold manager could distinguish a
Running peer, a genuine Starting peer, and a Degraded peer on its first pass.

Replacement then used two ordinary decisions. One pass stopped the degraded
occupant. The next found a missing domain and started a new incarnation there.
Subsequent passes respected its Starting occupancy until it became Running.
Healthy peers retained their exact PIDs, native start ticks, and RunIds.

Health also informed collisions: Running was preferred over Starting, and
Starting over Degraded. A younger Starting child survived an older Degraded
occupant, showing that health preference, not the age tie-breaker, made
the choice.

### Interrupting the repair made the stronger result visible

The recorded handoff had three managers:

| Manager | Epoch | Actual Starts / Stops | Result |
|---|---:|---:|---|
| A | 1 | 0 / 0 | Its stale Stop was rejected after epoch 2 became current |
| B | 2 | 0 / 1 | Stopped the degraded child, then exited before replacement creation |
| C | 3 | 1 / 0 | Discovered the empty domain and created its replacement |

B had selected a Start and paused before its effect. That decision did not
become a durable instruction for C. C needed neither B's log nor a saved
replacement phase.

There was no durable record resembling
`ReplacementOperation(domain, old, new, phase = StoppedOld)`.
The world after Stop was sufficient evidence for the next reconciliation
decision.

That is stronger than saying a manager can restart a workload:

> In this experiment, interruption did not require every recovery operation
> to become transactional. It left behind reality that the next reconciliation
> pass could understand.

## What did not need to be added

The absence of extra machinery is part of the result, not an omission from
a feature checklist.

| Not introduced | What supplied the needed information instead |
|---|---|
| Placement table or persisted replica slots | Desired count and rediscovered domain occupancy |
| Manager-owned persisted health | Live readiness and the per-incarnation Started witness |
| Durable victim list | A deterministic choice from each fresh observation |
| Repair journal, replacement transaction, or persisted workflow phases | Ordinary removal followed by rediscovered absence |
| Active-active management | Movement of one current authority, with stale effects rejected |
| DNS or service-publication logic | Not required to test the local reconciliation question |

Workload intent still contains only `WorkloadId`, `Desired`, and optional
`Replicas`. Default single-replica intent retains its original representation.
Managers do retain ephemeral counters and convergence observations; diagnostic
logs record history for investigation. None of those becomes a repair plan
loaded by the next manager.

The separate current-epoch grant remains durable authority-protocol state.
"No durable repair workflow" does not mean that authority needs no durable
representation, or that workload intent alone authorizes effects.

The distinction continues the rule from [Day 2](day-02.md):

> Persist what the management plane knows because it owns it. Rediscover what
> it knows only because it observed it.

Realizations had to expose enough evidence to make that rule workable.
Rediscovery was not a substitute for having that evidence.

## The loops this closes

| Day | Question | Distinction made concrete |
|---|---|---|
| [Day 1](day-01.md) | What is state? | A returned action is not an observation of readiness |
| [Day 2](day-02.md) | What should management remember? | Durable intent is different from rediscoverable operational reality |
| [Day 3](day-03.md) | Who may change reality? | Declared authority needs enforcement at the effect boundary |
| Day 4 | How does one authority reconcile a multi-domain workload? | Placement, subtraction, and repair can converge without a durable operational workflow |

Creation could leave a surviving realization for the next manager to discover.
Termination gained an incarnation check and an authority fence.
Replacement combined those capabilities without adding a durable transaction.
Authority could move between the two effects without disturbing healthy peers.

These are connected results, not four unrelated features.

The individual notebooks retain their exact measurements, limitations, and
validation evidence. This reflection introduces no new runtime mechanism or
new experiment. The full runner preserves historical failures alongside the
current Day 4.2 and Day 4.3 tests.

## The boundary of the claim

The experiment demonstrates local reconciliation and cooperative authority
semantics using logical domains on one Windows machine. It does **not**
demonstrate independent machine failure, network partitions, remote execution,
durable distributed consensus, or production service publication.

The epochs are advanced externally. No election or HA framework was built.
The same-session fence does not establish one manager per current epoch;
two managers incorrectly given the same epoch could still race from overlapping
observations. Singleton authority remains a deployment/protocol assumption,
not a consensus result.

Health loss is event-injected, not diagnosed by a real application probe.
Discovery and the two event reads are not an atomic health snapshot. Checked
termination verifies authority and native incarnation, not application-level
replication safety, graceful draining, or a transactional health precondition.

Even the multi-domain policy is deliberately bounded: effective count one
retains historical duplicate ambiguity. This is not a general scale-down-to-one
or arbitrary scheduling protocol.

The publication discussion in Day 4.3 identifies an attachment point:
derive eligible endpoints from Running, in-scope domain keepers and withhold
Starting or Degraded incarnations before replacement. It does not implement
external withdrawal, endpoint addresses, TTLs, or publication fencing.

Most importantly, local rediscoverable absence must not quietly become a claim
that an unreachable remote realization is absent.

## Closing Day 4, without choosing Day 5

Placement, removal, and health-aware repair form a complete intellectual unit.
I am closing Day 4 here, not adding another mechanism as Day 4.4.

The next question should not be "What feature should the orchestrator have?"
It should be:

> What claim does the architecture now appear to make that I have not yet
> tried hard enough to falsify?

One defensible decision is to stop with the bounded local claim above.
Distillation includes recognizing what the experiment has not earned.

If I continue, the strongest candidate is crossing the physical-domain
boundary, not adding scheduling sophistication. Genuinely independent domains
would challenge assumptions that local process enumeration has made easy:

- When a domain is unreachable, what can discovery legitimately conclude?
- Is absence of observation evidence of absence, or does it require an Unknown state?
- Can an authority that reaches only some domains safely change the workload?
- Where is incarnation identity exposed when the process is not locally enumerable?
- Can a replacement be created safely without proving the old realization is gone?

Those are candidate falsification questions, not a scheduled Day 5 design.
No remote worker, new durable field, or distributed protocol is justified
merely by listing them.

For now, the result worth preserving is that recovery did not require a more
elaborate durable replacement operation. It required intent, sufficient
realization evidence, checked effects, and another reconciliation pass.
