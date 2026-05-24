# Advanced actor patterns — 1:1 private channels, dynamic dispatch, capabilities.
#
# These patterns compose the primitives from examples.nix into coordination
# schemes. Each section builds one concept that real programs use.
#
# Patterns covered:
#   dynamic-dispatch   — cycle ref lives in the message; caller chooses actor
#   isolated-sessions  — shared bus, per-client state via when-c routing
#   capability-refs    — server vends refs; holding a ref IS the permission
#   scatter-gather     — N actors in parallel, results merged
#   private-channels   — tagged bus + per-client filter (1:1 reply routing)
#   continuation       — request carries its own reply-to ref
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
  inherit (ned) st map-c when-c;

  # ── shared behaviours ──────────────────────────────────────────────────────

  counter =
    count: msg:
    if msg == "inc" then
      reply.right (count + 1) // become (counter (count + 1))
    else if msg == "get" then
      reply.right count
    else
      { };

  safe-div =
    msg:
    if msg.divisor == 0 then reply.left "div-by-zero" else reply.right (msg.dividend / msg.divisor);

  validator = n: if n > 0 then reply.right n else reply.left "non-positive: ${toString n}";

  # ── shared actors ──────────────────────────────────────────────────────────
  counter-c = actor (counter 0);
  div-c = actor safe-div;
  validator-c = actor validator;

in
{
  # ── 1. Dynamic dispatch ────────────────────────────────────────────────────
  # The cycle ref lives inside the message envelope.
  # A dispatcher unpacks the ref and installs the inbox at runtime.
  # Each dispatch creates a fresh, independent actor session.
  dynamic-dispatch = {
    # Inline dispatcher: flatMap over envelopes, call each ref once.
    # Ref identity is irrelevant — any cycle function is valid.
    test-ref-in-envelope = {
      expr =
        let
          # dispatcher is not an actor — it's a plain cycle-c that uses flatMap
          dispatcher =
            { inbox }:
            {
              outbox = inbox.flatMap (env: (env.ref { inbox = st env.msg; }).outbox);
            };

          a = dispatcher {
            inbox =
              st
                {
                  ref = counter-c;
                  msg = "inc";
                } # fresh counter → 1
                {
                  ref = div-c;
                  msg = {
                    dividend = 10;
                    divisor = 2;
                  };
                } # div → 5
                {
                  ref = counter-c;
                  msg = "inc";
                }; # new fresh counter → 1
          };
        in
        a.outbox.toList;
      # Each envelope is independent — counter state does not persist across dispatches.
      expected = [
        { right = 1; }
        { right = 5; }
        { right = 1; }
      ];
    };

    # Heterogeneous dispatch: pick the right specialist per message type.
    # The ref field is set by the caller — no central routing table needed.
    test-heterogeneous-refs = {
      expr =
        let
          dispatcher =
            { inbox }:
            {
              outbox = inbox.flatMap (env: (env.ref { inbox = st.fromList env.msgs; }).outbox);
            };

          a = dispatcher {
            inbox =
              st
                {
                  ref = counter-c;
                  msgs = [
                    "inc"
                    "inc"
                    "get"
                  ];
                }
                {
                  ref = div-c;
                  msgs = [
                    {
                      dividend = 9;
                      divisor = 3;
                    }
                  ];
                }
                {
                  ref = counter-c;
                  msgs = [
                    "inc"
                    "get"
                  ];
                }; # fresh counter
          };
        in
        a.outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; } # first counter session: inc inc get
        { right = 3; } # div
        { right = 1; }
        { right = 1; } # second counter session: inc get (fresh)
      ];
    };
  };

  # ── 2. Isolated sessions ───────────────────────────────────────────────────
  # Multiple clients share one incoming stream.
  # when-c routes to per-client actors — each actor has its own scanl state.
  # Messages for client A never influence client B's counter.
  isolated-sessions = {
    # Two clients on a shared bus; each gets their own counter state.
    test-two-clients-independent-state = {
      expr =
        let
          # Single shared stream — all clients read the same bus
          shared =
            st
              {
                to = "alice";
                cmd = "inc";
              }
              {
                to = "bob";
                cmd = "inc";
              }
              {
                to = "alice";
                cmd = "inc";
              }
              {
                to = "alice";
                cmd = "get";
              }
              {
                to = "bob";
                cmd = "get";
              };

          alice = counter-c { inbox = when-c (m: m.to == "alice") shared (m: m.cmd); };
          bob = counter-c { inbox = when-c (m: m.to == "bob") shared (m: m.cmd); };
        in
        {
          alice = alice.outbox.toList;
          bob = bob.outbox.toList;
        };
      # alice incremented twice; bob only once — states never mix
      expected = {
        alice = [
          { right = 1; }
          { right = 2; }
          { right = 2; }
        ];
        bob = [
          { right = 1; }
          { right = 1; }
        ];
      };
    };

    # Three clients on the same bus — scales linearly with more when-c wires.
    test-three-clients = {
      expr =
        let
          bus =
            st
              {
                to = "x";
                cmd = "inc";
              }
              {
                to = "y";
                cmd = "inc";
              }
              {
                to = "z";
                cmd = "inc";
              }
              {
                to = "x";
                cmd = "inc";
              }
              {
                to = "y";
                cmd = "get";
              }
              {
                to = "x";
                cmd = "get";
              };

          x = counter-c { inbox = when-c (m: m.to == "x") bus (m: m.cmd); };
          y = counter-c { inbox = when-c (m: m.to == "y") bus (m: m.cmd); };
          z = counter-c { inbox = when-c (m: m.to == "z") bus (m: m.cmd); };
        in
        {
          x = x.outbox.toList;
          y = y.outbox.toList;
          z = z.outbox.toList;
        };
      expected = {
        x = [
          { right = 1; }
          { right = 2; }
          { right = 2; }
        ];
        y = [
          { right = 1; }
          { right = 1; }
        ];
        z = [ { right = 1; } ];
      };
    };
  };

  # ── 3. Capability refs ─────────────────────────────────────────────────────
  # A server returns a cycle ref as its reply — the ref IS the capability.
  # Callers who receive the ref can communicate with that actor directly.
  # Callers who do not receive the ref have no access.
  capability-refs = {
    # Server vends fresh counter sessions on connect.
    # Each caller gets an independent ref; sessions are isolated by construction.
    test-server-vends-sessions = {
      expr =
        let
          # Server: every "connect" request yields a fresh counter-c ref
          session-server-c = actor (_: reply counter-c);

          # Two clients connect — each receives their own counter ref
          session-refs = (session-server-c { inbox = st "connect" "connect"; }).outbox;

          # Use each ref with the same commands — proves sessions are isolated
          sessions = session-refs.flatMap (ref: (ref { inbox = st "inc" "inc" "get"; }).outbox);
        in
        sessions.toList;
      # Both sessions start fresh — same commands, same output, no state bleed.
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; } # session 1
        { right = 1; }
        { right = 2; }
        { right = 2; } # session 2 — fully independent
      ];
    };

    # Capability delegation: a ref can be passed to a third party.
    # The third party can use it exactly like the original holder.
    test-delegated-ref = {
      expr =
        let
          # Mediator receives a ref and a message, forwards the message to the ref
          mediator = msg: send msg.ref (st msg.payload);
          mediator-c = actor mediator;

          a = mediator-c {
            inbox =
              st
                {
                  ref = counter-c;
                  payload = "inc";
                }
                {
                  ref = counter-c;
                  payload = "inc";
                }
                {
                  ref = counter-c;
                  payload = "get";
                };
          };
        in
        a.outbox.toList;
      # Each delegation creates a fresh session — same as direct dispatch
      expected = [
        { right = 1; }
        { right = 1; }
        { right = 0; }
      ];
    };
  };

  # ── 4. Scatter-gather ──────────────────────────────────────────────────────
  # Fan-out: spawn N independent actors (one per input).
  # Fan-in: collect all results with merge.
  # Nix laziness evaluates all actors; order is deterministic (list order).
  scatter-gather = {
    # Validate N inputs in parallel, collect all results in input order.
    test-validate-many = {
      expr =
        let
          inputs = [
            5
            (-1)
            8
            0
            2
          ];
          actors = builtins.map (n: validator-c { inbox = st n; }) inputs;
          results = merge (builtins.map (a: a.outbox) actors);
        in
        results.toList;
      expected = [
        { right = 5; }
        { left = "non-positive: -1"; }
        { right = 8; }
        { left = "non-positive: 0"; }
        { right = 2; }
      ];
    };

    # Scatter to specialists, gather successes only.
    test-gather-successes = {
      expr =
        let
          inputs = [
            5
            (-1)
            8
            0
            2
          ];
          actors = builtins.map (n: validator-c { inbox = st n; }) inputs;
          # merge all outboxes, then filter to right side
          all = merge (builtins.map (a: a.outbox) actors);
        in
        all.right.toList;
      expected = [
        5
        8
        2
      ];
    };
  };

  # ── 5. Private channels ────────────────────────────────────────────────────
  # A server handles requests from multiple clients on a shared bus.
  # Each response is tagged with the originating client id.
  # Clients read from the shared outbox, filtering by their own id.
  # This gives each client a private 1:1 view of the server's output.
  private-channels = {
    test-tagged-bus = {
      expr =
        let
          # Server: doubles the value, tags reply with client id
          server-beh =
            msg:
            reply {
              id = msg.id;
              result = msg.value * 2;
            };
          server-c = actor server-beh;

          shared-bus =
            st
              {
                id = "a";
                value = 5;
              }
              {
                id = "b";
                value = 3;
              }
              {
                id = "a";
                value = 10;
              };

          server = server-c { inbox = shared-bus; };

          # Each client reads only their own replies — no other changes needed
          client-a = server.outbox.filter (r: r.id == "a");
          client-b = server.outbox.filter (r: r.id == "b");
        in
        {
          a = client-a.toList;
          b = client-b.toList;
        };
      expected = {
        a = [
          {
            id = "a";
            result = 10;
          }
          {
            id = "a";
            result = 20;
          }
        ];
        b = [
          {
            id = "b";
            result = 6;
          }
        ];
      };
    };

    # Combine tagged bus + either: separate success/error per client.
    test-tagged-bus-with-errors = {
      expr =
        let
          # compute-div returns the Either value directly (not wrapped in reply)
          compute-div =
            msg:
            if msg.divisor == 0 then { left = "div-by-zero"; } else { right = msg.dividend / msg.divisor; };
          server-c = actor (
            msg:
            reply {
              id = msg.id;
              result = compute-div msg;
            }
          );

          shared-bus =
            st
              {
                id = "a";
                dividend = 10;
                divisor = 2;
              }
              {
                id = "b";
                dividend = 6;
                divisor = 0;
              }
              {
                id = "a";
                dividend = 9;
                divisor = 3;
              };

          server = server-c { inbox = shared-bus; };

          # Each reply has shape { id, result: { right | left } }
          # Client filters by id, then inspects result
          a-replies = server.outbox.filter (r: r.id == "a");
          b-replies = server.outbox.filter (r: r.id == "b");
        in
        {
          a = a-replies.toList;
          b = b-replies.toList;
        };
      expected = {
        a = [
          {
            id = "a";
            result = {
              right = 5;
            };
          }
          {
            id = "a";
            result = {
              right = 3;
            };
          }
        ];
        b = [
          {
            id = "b";
            result = {
              left = "div-by-zero";
            };
          }
        ];
      };
    };
  };

  # ── 6. Continuation-passing (reply-to ref) ─────────────────────────────────
  # Each request carries a reply-to cycle ref.
  # The handler writes its result to that ref — caller-chosen destination.
  # This decouples handler from consumer; any cycle can receive the reply.
  continuation = {
    # Handler doubles value, sends result to the caller-supplied reply-to actor.
    # reply-to ref is a one-shot channel — each request gets its own.
    test-reply-to-ref = {
      expr =
        let
          # Simple store-and-forward: echo anything back as a plain reply
          echo-a = actor (x: reply x);

          # Handler: reads value, sends result to reply-to ref in request
          handler = msg: send msg.reply-to (st (msg.value * 2));
          handler-c = actor handler;

          a = handler-c {
            inbox =
              st
                {
                  value = 5;
                  reply-to = echo-a;
                }
                {
                  value = 3;
                  reply-to = echo-a;
                };
          };
        in
        a.outbox.toList;
      # handler doubles and forwards; echo-a stores and returns
      expected = [
        10
        6
      ];
    };

    # Different reply-to refs per request — each goes to a different actor.
    # Shows that the reply destination is truly dynamic, chosen per message.
    test-per-request-reply-to = {
      expr =
        let
          echo-a = actor (x: reply x);

          # Two different "accumulator" actors as reply-to targets
          acc-double = actor (x: reply (x * 2));
          acc-negate = actor (x: reply (x * (-1)));

          handler = msg: send msg.reply-to (st msg.value);
          handler-c = actor handler;

          a = handler-c {
            inbox =
              st
                {
                  value = 7;
                  reply-to = acc-double;
                } # 7 → double → 14
                {
                  value = 4;
                  reply-to = acc-negate;
                } # 4 → negate → -4
                {
                  value = 3;
                  reply-to = echo-a;
                }; # 3 → echo → 3
          };
        in
        a.outbox.toList;
      expected = [
        14
        (-4)
        3
      ];
    };
  };
}
