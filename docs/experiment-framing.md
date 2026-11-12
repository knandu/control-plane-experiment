# Experiment Framing

I didn't start this project with a methodology for architectural experimentation.

I started with a question.

By Day 2, I ran into a problem I hadn't really anticipated: I have strong opinions about this architecture because I've built something like it before.

That creates a risk.

Instead of discovering which parts of the earlier architecture are actually necessary, I can very easily reconstruct them and call the result an experiment.

So I'm adding a few rules.

## Prior beliefs are allowed

I'm not pretending to approach this problem without experience.

I already have architectural instincts from the system that led to this experiment.

For example, I believe there is value in having a single management authority, with the underlying HA mechanism responsible for deciding where that authority runs.

I also expect some state may eventually need to survive the lifetime or movement of that authority.

Those are priors.

They can influence which questions I choose to investigate.

They are not findings from this repository, and they don't automatically earn an implementation here.

## Make the problem appear before adding the solution

If I think durable state is necessary, first restart the manager without it.

If I think fencing is necessary, first produce the stale-authority failure.

If I think a worker abstraction is necessary, first encounter the boundary that requires it.

An idea from the original system can be a hypothesis. It doesn't become part of this system merely because I already know how I would implement it.

## When ambiguity appears, record it before resolving it

The uncomfortable state is evidence.

If a restart makes ownership ambiguous, or an observation doesn't fit cleanly into the current model, record that before introducing another abstraction to make the problem disappear.

The ambiguity may be more useful than the first solution.

## Prefer rediscovery over memory

Where operational reality can be observed again, don't assume the control plane needs to remember what it previously did.

A manager may not need to remember that it issued an operation if it can recover from durable intent and freshly observed reality.

Persist only what an experiment demonstrates must survive.

## Don't confuse a prior with a conclusion

"I expected this" and "the experiment demonstrated this" are different statements.

Keep them different.

The repository should make it possible to distinguish:

- what I believed going in,
- what I tried,
- what I actually observed,
- and what I changed my mind about.

## Keep the experiment bounded

This is still a seven-logical-day project.

The goal is not to exhaustively compare orchestration architectures or rediscover distributed systems from first principles.

Experience is allowed to give me good hypotheses.

The experiment should subject the important ones to small tests capable of making them uncomfortable.

That means I don't need to implement peer-to-peer management, multiple storage systems, consensus algorithms, or alternative orchestrators merely to prove that I considered them.

## One rule for introducing architecture

No abstraction, boundary, interface, or durable state enters the implementation merely because it existed in the original system.

It must either solve a problem observed in this experiment or remain a documented prior belief awaiting validation.

## Why this document exists

This rule wasn't part of the project when I started.

I discovered the need for it while beginning Day 2.

I found myself introducing concepts from the original architecture because I already believed they would be necessary. The criticism was fair: if I added the solution before reproducing the problem, I wasn't really learning whether the solution was necessary.

So this document is itself part of the experiment.

The project started by asking whether an architecture would survive simplification.

It has now exposed a second question:

How do you experiment honestly with an architecture you already believe in?

I don't know yet whether that becomes one of the eventual articles.

For now, it is something I want the remaining experiments to remember.
