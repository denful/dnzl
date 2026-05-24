# Dnzl actor system — comprehensive examples and feature showcase.
#
# Each section demonstrates one core concept. Tests ARE user-code: copy any
# section as a starting point for your own actors.
#
# Reading order: stateless → reply → stateful → fan-out → fan-in → either →
#                delegation → routing → pipeline → extra-outputs →
#                world-edge → composition
dnzl:
let
  # ── imports ────────────────────────────────────────────────────────────────
  inherit (dnzl)
    ned
    actor
    reply
    become
    send
    merge
    ;
  inherit (ned)
    st
    map-c
    when-c
    run
    static-d
    ;

  # ── behaviours ─────────────────────────────────────────────────────────────
  # A behaviour is a plain Nix function: msg → result-attrset.
  # It knows nothing about dnzl internals.

  # Counter — canonical stateful actor.
  # Returns right + become on every message so callers always get typed output.
  counter =
    count: msg:
    if msg == "inc" then
      reply.right (count + 1) // become (counter (count + 1))
    else if msg == "get" then
      reply.right count
    else if msg == "reset" then
      reply.right 0 // become (counter 0)
    else
      { }; # unknown message → no reply, behaviour unchanged

  # Toggle — simple two-state machine.
  toggle =
    state: msg:
    if msg == "flip" then
      reply.right (!state) // become (toggle (!state))
    else if msg == "query" then
      reply.right state
    else
      { };

  # Safe division — pure function, Either output, no state.
  safe-div =
    msg:
    if msg.divisor == 0 then reply.left "div-by-zero" else reply.right (msg.dividend / msg.divisor);

  # Validator — filters a stream into right (positive) and left (non-positive).
  validator = n: if n > 0 then reply.right n else reply.left "non-positive: ${toString n}";

  # Expander — fan-out: one message emits multiple items.
  # reply = ST, not a plain value — fields "reply" flattens it.
  expander = msg: { reply = st.fromList msg.items; };

  # Tagger — wraps each message in metadata; no state needed.
  tagger =
    msg:
    reply {
      tagged = true;
      value = msg;
    };

  # Audit-logged division — emits a side-channel "log" field alongside reply.
  # Demonstrates extra output extraction via states.fields.
  logged-div =
    msg:
    if msg.divisor == 0 then
      reply.left "div-by-zero" // { log = "WARN: div-by-zero dividend=${toString msg.dividend}"; }
    else
      reply.right (msg.dividend / msg.divisor)
      // {
        log = "OK: ${toString msg.dividend}/${toString msg.divisor}=${
          toString (msg.dividend / msg.divisor)
        }";
      };

  # ── actors ─────────────────────────────────────────────────────────────────
  # actor wraps a behaviour into a cycle: { inbox } → { outbox, states }
  counter-c = actor (counter 0);
  toggle-c = actor (toggle false);
  div-c = actor safe-div;
  validator-c = actor validator;
  expander-c = actor expander;
  tagger-c = actor tagger;
  logged-div-c = actor logged-div;

  # Stateless actors need no state — use map-c directly (no actor wrapper).
  echo-c = map-c (x: x);
  double-c = map-c (n: n * 2);

in
{
  # ── 1. Stateless actors ────────────────────────────────────────────────────
  # map-c is sufficient for behaviours with no state.
  # These are the simplest possible actors: pure stream transformers.
  stateless = {
    # Identity pass-through — useful as a base case or for testing.
    test-echo = {
      expr = (echo-c (st "a" "b" "c")).toList;
      expected = [
        "a"
        "b"
        "c"
      ];
    };

    # Pure transformation — map-c replaces actor when there is no state.
    test-transform = {
      expr = (double-c (st 1 2 3)).toList;
      expected = [
        2
        4
        6
      ];
    };
  };

  # ── 2. reply variants ──────────────────────────────────────────────────────
  # reply data        → { reply = data }           (untyped, any shape)
  # reply.right data  → { reply = { right = data } }  (Either success)
  # reply.left  data  → { reply = { left  = data } }  (Either failure)
  reply-types = {
    # Plain reply — use when callers don't need to distinguish success/failure.
    test-plain = {
      expr = (tagger-c { inbox = st "x" "y"; }).outbox.toList;
      expected = [
        {
          tagged = true;
          value = "x";
        }
        {
          tagged = true;
          value = "y";
        }
      ];
    };

    # Typed reply — right/left let callers split the stream without pattern-matching.
    test-right-and-left = {
      expr =
        let
          a = div-c {
            inbox =
              st
                {
                  dividend = 10;
                  divisor = 2;
                }
                {
                  dividend = 6;
                  divisor = 0;
                }
                {
                  dividend = 9;
                  divisor = 3;
                };
          };
        in
        {
          ok = a.outbox.right.toList;
          err = a.outbox.left.toList;
        };
      expected = {
        ok = [
          5
          3
        ];
        err = [ "div-by-zero" ];
      };
    };
  };

  # ── 3. Stateful actors ─────────────────────────────────────────────────────
  # become swaps the behaviour for the next message.
  # State lives entirely in the closure — no mutable variables needed.
  stateful = {
    # Basic increment and read.
    test-counter = {
      expr = (counter-c { inbox = st "inc" "inc" "get"; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
      ];
    };

    # become replaces the behaviour; every message after "reset" sees count = 0.
    test-reset = {
      expr = (counter-c { inbox = st "inc" "inc" "reset" "get"; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 0; }
        { right = 0; }
      ];
    };

    # Unknown messages are silently dropped — no reply, no become.
    test-unknown-drops = {
      expr = (counter-c { inbox = st "inc" "???" "get"; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 1; } # "???" produced no side-effect
      ];
    };

    # Two-state machine: toggle alternates on every "flip".
    test-toggle = {
      expr = (toggle-c { inbox = st "flip" "query" "flip" "query"; }).outbox.toList;
      expected = [
        { right = true; }
        { right = true; }
        { right = false; }
        { right = false; }
      ];
    };
  };

  # ── 4. Fan-out ─────────────────────────────────────────────────────────────
  # A behaviour can set reply = ST to emit multiple items per message.
  # fields "reply" flattens the nested stream automatically.
  fan-out = {
    # One envelope message expands into its items individually.
    test-expander = {
      expr =
        (expander-c {
          inbox = st {
            items = [
              10
              20
              30
            ];
          };
        }).outbox.toList;
      expected = [
        10
        20
        30
      ];
    };

    # Different envelopes each expand independently; items concatenate in order.
    test-multiple-envelopes = {
      expr =
        (expander-c {
          inbox =
            st
              {
                items = [
                  "a"
                  "b"
                ];
              }
              { items = [ "c" ]; }
              {
                items = [
                  "d"
                  "e"
                ];
              };
        }).outbox.toList;
      expected = [
        "a"
        "b"
        "c"
        "d"
        "e"
      ];
    };
  };

  # ── 5. Fan-in / merge ──────────────────────────────────────────────────────
  # merge [s1 s2 ...] concatenates streams in list order.
  # Use this to feed a single actor from multiple upstream sources.
  fan-in = {
    # Two streams → one inbox, items arrive in source order.
    test-merge-two = {
      expr =
        (echo-c (merge [
          (st "a" "b")
          (st "c" "d")
        ])).toList;
      expected = [
        "a"
        "b"
        "c"
        "d"
      ];
    };

    # Three streams — handy for fanout routing into a shared collector.
    test-merge-three = {
      expr =
        (echo-c (merge [
          (st 1)
          (st 2 3)
          (st 4)
        ])).toList;
      expected = [
        1
        2
        3
        4
      ];
    };

    # merge with actor: two command streams feed one shared counter.
    test-shared-counter = {
      expr =
        let
          cmds-a = st "inc" "inc"; # two increments
          cmds-b = st "inc" "get"; # one increment then read
          shared = counter-c {
            inbox = merge [
              cmds-a
              cmds-b
            ];
          };
        in
        shared.outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 3; }
        { right = 3; }
      ];
    };
  };

  # ── 6. Either stream splitting ─────────────────────────────────────────────
  # outbox.right and outbox.left are sub-streams, not lists.
  # Chain further actors onto them — no explicit filtering needed.
  either = {
    # Separate successes from errors without touching the full outbox.
    test-split-stream = {
      expr =
        let
          a = validator-c { inbox = st 5 (-3) 8 0 2; };
        in
        {
          valid = a.outbox.right.toList;
          invalid = a.outbox.left.toList;
        };
      expected = {
        valid = [
          5
          8
          2
        ];
        invalid = [
          "non-positive: -3"
          "non-positive: 0"
        ];
      };
    };

    # Chain a second actor onto the success stream only.
    # Errors are discarded by only consuming outbox.right.
    test-chain-on-right = {
      expr =
        let
          validated = validator-c { inbox = st 3 (-1) 4 (-2) 7; };
          doubled = double-c validated.outbox.right;
        in
        doubled.toList;
      expected = [
        6
        8
        14
      ];
    };
  };

  # ── 7. Delegation via send ─────────────────────────────────────────────────
  # send ref msgs = { reply = (ref { inbox = msgs }).outbox }
  # Returns { reply = ST } so a behaviour can return `send ...` directly.
  # Each send call creates a fresh actor instance — no shared state.
  delegation = {
    # Proxy: route each message to a freshly constructed sub-actor.
    # "inc" → fresh counter → right 1.  "get" → fresh counter → right 0.
    test-fresh-per-message = {
      expr =
        let
          proxy = msg: send counter-c (st msg);
          proxy-c = actor proxy;
          a = proxy-c { inbox = st "inc" "inc" "get"; };
        in
        a.outbox.toList;
      expected = [
        { right = 1; } # fresh counter, "inc" → 1
        { right = 1; } # fresh counter, "inc" → 1
        { right = 0; } # fresh counter, "get" → 0
      ];
    };

    # Batch send: one message triggers a multi-step sub-session.
    # reply = ST from the sub-actor → fields "reply" flattens into parent outbox.
    test-batch-send = {
      expr =
        let
          batch = msg: send counter-c (st.fromList msg.cmds);
          batch-c = actor batch;
          a = batch-c {
            inbox = st {
              cmds = [
                "inc"
                "inc"
                "get"
              ];
            };
          };
        in
        a.outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
      ];
    };

    # Combine send + become: proxy selects a sub-actor based on message type.
    test-dispatch = {
      expr =
        let
          dispatch =
            msg:
            if msg.via == "div" then
              send div-c (st {
                dividend = msg.a;
                divisor = msg.b;
              })
            else
              send counter-c (st msg.cmd);
          dispatch-c = actor dispatch;
          a = dispatch-c {
            inbox =
              st
                {
                  via = "div";
                  a = 10;
                  b = 2;
                }
                {
                  via = "ctr";
                  cmd = "inc";
                }
                {
                  via = "div";
                  a = 15;
                  b = 3;
                };
          };
        in
        a.outbox.toList;
      expected = [
        { right = 5; }
        { right = 1; }
        { right = 5; }
      ];
    };
  };

  # ── 8. Message routing ─────────────────────────────────────────────────────
  # when-c pred inbox f → filtered + mapped sub-stream.
  # Route different message types to specialised actors before the inbox split.
  routing = {
    # Type-tagged envelope: split by "type" field, extract payload per branch.
    test-type-routing = {
      expr =
        let
          inbox =
            st
              {
                type = "count";
                cmd = "inc";
              }
              {
                type = "div";
                dividend = 10;
                divisor = 2;
              }
              {
                type = "count";
                cmd = "inc";
              }
              {
                type = "div";
                dividend = 9;
                divisor = 3;
              }
              {
                type = "count";
                cmd = "get";
              };

          counts = counter-c { inbox = when-c (m: m.type == "count") inbox (m: m.cmd); };
          divides = div-c { inbox = when-c (m: m.type == "div") inbox (m: m); };
        in
        # concat counts first, then divides — sequential fan-in
        (counts.outbox (divides.outbox)).toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
        { right = 5; }
        { right = 3; }
      ];
    };
  };

  # ── 9. Pipeline / actor chaining ───────────────────────────────────────────
  # Actors compose by wiring one outbox to the next inbox.
  # Lazy Nix let handles the dependency graph — no explicit ordering needed.
  pipeline = {
    # Validate then double: only valid (right) numbers reach the doubler.
    test-validate-then-double = {
      expr =
        let
          validated = validator-c { inbox = st 3 (-1) 4 0 7; };
          doubled = double-c validated.outbox.right;
        in
        doubled.toList;
      expected = [
        6
        8
        14
      ];
    };

    # Two counters in series: A counts raw commands, B counts A's replies.
    test-counter-chain = {
      expr =
        let
          a = counter-c { inbox = st "inc" "inc" "inc"; };
          # Each reply from a triggers one "inc" in b.
          b = counter-c { inbox = a.outbox.right (st.map (_: "inc")); };
        in
        b.outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 3; }
      ];
    };
  };

  # ── 10. Extra output channels via states ────────────────────────────────────
  # A behaviour can emit arbitrary extra fields alongside reply.
  # states.fields "name" extracts those fields as an independent stream.
  # This is how audit logs, metrics, and side-channel data work.
  extra-outputs = {
    # Logged division: "log" field appears on every state alongside reply.
    test-audit-log = {
      expr =
        let
          a = logged-div-c {
            inbox =
              st
                {
                  dividend = 10;
                  divisor = 2;
                }
                {
                  dividend = 6;
                  divisor = 0;
                };
          };
        in
        {
          results = a.outbox.toList;
          log = (a.states.fields "log").toList;
        };
      expected = {
        results = [
          { right = 5; }
          { left = "div-by-zero"; }
        ];
        log = [
          "OK: 10/2=5"
          "WARN: div-by-zero dividend=6"
        ];
      };
    };

    # states exposes the full accumulated state — useful for inspecting
    # intermediate values or building derived streams beyond the main outbox.
    test-states-accessible = {
      expr =
        let
          a = counter-c { inbox = st "inc" "inc"; };
        in
        builtins.length a.states.toList; # initial + 2 msgs = 3 states
      expected = 3;
    };
  };

  # ── 11. World edge — ned.run ────────────────────────────────────────────────
  # ned.run connects drivers to a cycle, forcing evaluation.
  # static-d turns a plain list into a driver (ignores the sink, emits the list).
  # This is the canonical way to run actors against static test data.
  world-edge = {
    test-run-counter = {
      expr =
        (run {
          inbox = static-d [
            "inc"
            "inc"
            "get"
          ];
        } counter-c).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
      ];
    };

    test-run-validator = {
      expr =
        let
          a = run {
            inbox = static-d [
              5
              (-2)
              8
            ];
          } validator-c;
        in
        {
          ok = a.outbox.right.toList;
          err = a.outbox.left.toList;
        };
      expected = {
        ok = [
          5
          8
        ];
        err = [ "non-positive: -2" ];
      };
    };
  };

  # ── 12. Composition patterns ───────────────────────────────────────────────
  # Actors compose structurally — no runtime coordination required.
  # Lazy Nix let is sufficient for both simple pipelines and feedback wiring.
  composition = {
    # Inline actor construction: a cycle that builds sub-actors internally.
    # The outer cycle hides the routing detail from its caller.
    test-composite-cycle = {
      expr =
        let
          # This cycle routes by type internally; caller just sends envelopes.
          typed-c =
            { inbox }:
            let
              counts = counter-c { inbox = when-c (m: m ? cmd) inbox (m: m.cmd); };
              divides = div-c { inbox = when-c (m: m ? dividend) inbox (m: m); };
            in
            {
              outbox = counts.outbox (divides.outbox);
            };

          a = typed-c {
            inbox = st { cmd = "inc"; } {
              dividend = 10;
              divisor = 2;
            } { cmd = "get"; };
          };
        in
        a.outbox.toList;
      expected = [
        { right = 1; }
        { right = 1; }
        { right = 5; }
      ];
    };

    # One-way seeded feedback: pong reads inbox, ping reads pong's output.
    # Lazy let resolves the dependency — pong evaluates before ping needs it.
    test-seeded-pipeline = {
      expr =
        let
          pong = counter-c { inbox = st "inc" "inc" "inc"; };
          # ping gets one "get" per reply from pong — each sees a fresh counter
          ping = actor (msg: send counter-c (st msg)) { inbox = pong.outbox.right (st.map (_: "get")); };
        in
        ping.outbox.toList;
      # 3 pong replies → 3 "get" to fresh counters → each returns right 0
      expected = [
        { right = 0; }
        { right = 0; }
        { right = 0; }
      ];
    };

    # Behaviour spawns a sub-actor inline to compute its reply.
    # Each outer message creates a fresh inner actor session.
    test-inline-spawn = {
      expr =
        let
          # For each batch, spin up a counter and run all commands through it.
          batcher = msg: send counter-c (st.fromList msg.cmds);
          batcher-c = actor batcher;
          a = batcher-c {
            inbox =
              st
                {
                  cmds = [
                    "inc"
                    "inc"
                    "get"
                  ];
                }
                {
                  cmds = [
                    "inc"
                    "get"
                  ];
                };
          };
        in
        a.outbox.toList;
      # each batch is a fresh counter session — state does not bleed across batches
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
        { right = 1; } # second batch: fresh counter
        { right = 1; }
      ];
    };
  };
}
