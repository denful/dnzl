<table>
<tr>
<td>

# dnzl

Dnzl is an Actor System for Nix based on [Ned](https://github.com/denful/ned) stream-cycles. Write behaviours as plain functions, automatic behaviour replacement, state keeping and error handling. Compose them into pipelines, fan-outs, and feedback loops using lazy `let` and stream wiring.


**Full documentation, patterns, and reference at [https://dnzl.denful.dev](https://dnzl.denful.dev)**

</td>

<td>

<img src="https://raw.githubusercontent.com/denful/dnzl/refs/heads/main/docs/public/dnzl.png">
  
</td>
</tr>
</table>


## What it enables

**Stateful stream processing.** Each actor maintains state across messages via function closures. State threads through `scanl` — no mutable variables, no global state.

**Behaviour switching.** An actor can replace itself with a new behaviour after each message. State machines are just functions calling functions.

**Either routing.** Tag replies as `right` (success) or `left` (failure). `outbox.right` and `outbox.left` are sub-streams of bare values — no unwrapping needed.

**Lazy pipelines.** Wire one actor's outbox as another's inbox. Nix laziness resolves evaluation order — no explicit sequencing.

**Capability refs.** A cycle-c is a Nix value. Return it as a reply; the receiver gains the ability to invoke that actor. Holding the ref is the permission.

**Fan-out and scatter-gather.** Spawn N independent actors with `builtins.map`, collect results with `merge`. Order is deterministic.

**Content-based routing.** `when-c` filters a shared stream to per-actor slices. Multiple actors share one inbox without coupling.

