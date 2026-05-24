# Design patterns lifted verbatim from design.md — fills coverage gaps.
#
# Each section corresponds to a named pattern or idiom from the design notes.
# Read alongside examples.nix and advanced.nix for full picture.
#
# Patterns:
#   st-combinators      — stream (st.map f), stream (st.filter p) combinator form
#   proxy               — send msg.ref (st msg.data) — ref + datum in same envelope
#   multi-output-cycle  — cycle that returns named { values, errors } outputs
#   multi-sender        — merge external inbox with static appended messages
#   ping-pong           — lazy let: pong feeds ping via st.map on outbox
#   inbox-concat        — inbox (actor.outbox) — extend inbox with upstream replies
#   run-inline          — ned.run with anonymous inline cycle body
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

  # ── shared behaviours ──────────────────────────────────────────────────────
  counter =
    count: msg:
    if msg == "inc" then
      reply.right (count + 1) // become (counter (count + 1))
    else if msg == "get" then
      reply.right count
    else
      { };

  validator = n: if n > 0 then reply.right n else reply.left "non-positive: ${toString n}";

  safe-div =
    msg:
    if msg.divisor == 0 then reply.left "div-by-zero" else reply.right (msg.dividend / msg.divisor);

  counter-c = actor (counter 0);
  validator-c = actor validator;
  div-c = actor safe-div;

in
{
  # ── 1. ST combinator form ──────────────────────────────────────────────────
  # Streams are functors: stream (combinator) applies the combinator in-place.
  # st.map f and st.filter p return no-arg functions — the functor dispatch
  # treats them as combinators and applies them to self.
  # This is the low-level form; map-c and when-c are convenience wrappers.
  st-combinators = {
    # stream (st.map f) ≡ map-c f stream
    test-map-combinator = {
      expr = ((st 1 2 3) (st.map (x: x * 10))).toList;
      expected = [
        10
        20
        30
      ];
    };

    # stream (st.filter p) ≡ when-c p stream (x: x) but keeps original value
    test-filter-combinator = {
      expr = ((st 1 2 3 4 5) (st.filter (x: x > 3))).toList;
      expected = [
        4
        5
      ];
    };

    # Chain map then filter via successive functor calls
    test-map-then-filter = {
      expr = ((st 1 2 3 4) (st.map (x: x * 2)) (st.filter (x: x > 4))).toList;
      expected = [
        6
        8
      ];
    };

    # st.flatMap as combinator — fan-out per element
    test-flatmap-combinator = {
      expr = ((st 1 2 3) (st.flatMap (x: st x x))).toList;
      expected = [
        1
        1
        2
        2
        3
        3
      ];
    };

    # st.scanl as combinator — running fold without actor wrapper
    # Useful for accumulation that doesn't need become or reply
    test-scanl-combinator = {
      expr = ((st 1 2 3 4) (st.scanl (acc: x: acc + x) 0)).toList;
      # scanl emits the accumulator BEFORE each step (including initial value)
      expected = [
        0
        1
        3
        6
        10
      ];
    };
  };

  # ── 2. Proxy — send msg.ref (st msg.data) ─────────────────────────────────
  # Each message carries its own destination ref and a single datum.
  # The proxy actor forwards datum → ref and returns whatever the ref replies.
  # This is the minimal forwarding pattern: ref + data bundled per message.
  proxy = {
    test-proxy-forwards = {
      expr =
        let
          proxy = msg: send msg.ref (st msg.data);
          proxy-c = actor proxy;
          a = proxy-c {
            inbox =
              st
                {
                  ref = counter-c;
                  data = "inc";
                }
                {
                  ref = counter-c;
                  data = "inc";
                }
                {
                  ref = counter-c;
                  data = "get";
                };
          };
        in
        a.outbox.toList;
      # Each dispatch is a fresh counter session — no shared state.
      expected = [
        { right = 1; } # fresh counter, inc → 1
        { right = 1; } # fresh counter, inc → 1
        { right = 0; } # fresh counter, get → 0
      ];
    };

    # Proxy to heterogeneous refs — each message routes to a different specialist.
    test-proxy-heterogeneous = {
      expr =
        let
          proxy = msg: send msg.ref (st msg.data);
          proxy-c = actor proxy;
          a = proxy-c {
            inbox =
              st
                {
                  ref = counter-c;
                  data = "inc";
                }
                {
                  ref = div-c;
                  data = {
                    dividend = 12;
                    divisor = 4;
                  };
                }
                {
                  ref = validator-c;
                  data = (-5);
                };
          };
        in
        a.outbox.toList;
      expected = [
        { right = 1; }
        { right = 3; }
        { left = "non-positive: -5"; }
      ];
    };
  };

  # ── 3. Multi-output cycle ──────────────────────────────────────────────────
  # A cycle may return multiple named output streams.
  # Callers access them by name — no need to filter the shared outbox.
  # outbox.right / outbox.left are the split point; the cycle hides that detail.
  multi-output-cycle = {
    # Cycle returns { values, errors } — two independent output channels.
    test-named-outputs = {
      expr =
        let
          validate-c =
            { inbox }:
            let
              a = validator-c { inherit inbox; };
            in
            {
              values = a.outbox.right; # ST int
              errors = a.outbox.left; # ST string
            };

          result = validate-c { inbox = st 5 (-1) 3 0 7; };
        in
        {
          values = result.values.toList;
          errors = result.errors.toList;
        };
      expected = {
        values = [
          5
          3
          7
        ];
        errors = [
          "non-positive: -1"
          "non-positive: 0"
        ];
      };
    };

    # Multi-output cycle wrapping a stateful actor — same split pattern.
    test-stateful-multi-output = {
      expr =
        let
          # Counter that emits all inc replies on one channel, get replies on another.
          # Uses states.fields to route by message type rather than Either.
          logged-counter =
            count: msg:
            if msg == "inc" then
              reply.right (count + 1) // { kind = "mutation"; } // become (logged-counter (count + 1))
            else if msg == "get" then
              reply.right count // { kind = "query"; }
            else
              { };

          lc = actor (logged-counter 0);

          lc-c =
            { inbox }:
            let
              a = lc { inherit inbox; };
            in
            {
              mutations = a.states.fields "kind" (st.filter (k: k == "mutation"));
              queries = a.states.fields "kind" (st.filter (k: k == "query"));
              outbox = a.outbox;
            };

          result = lc-c { inbox = st "inc" "get" "inc" "get"; };
        in
        {
          mutations = result.mutations.toList;
          queries = result.queries.toList;
          outbox = result.outbox.toList;
        };
      expected = {
        mutations = [
          "mutation"
          "mutation"
        ];
        queries = [
          "query"
          "query"
        ];
        outbox = [
          { right = 1; }
          { right = 1; }
          { right = 2; }
          { right = 2; }
        ];
      };
    };
  };

  # ── 4. Multi-sender — extend inbox with static messages ───────────────────
  # merge can combine a dynamic external inbox with static additional messages.
  # The actor sees all messages in order: external first, then static appended.
  multi-sender = {
    # External inbox augmented with static bootstrap commands.
    test-extend-with-static = {
      expr =
        let
          # Append two extra "inc" commands after whatever the caller sends.
          bootstrapped-c =
            { inbox }:
            counter-c {
              inbox = merge [
                inbox
                (st "inc" "inc")
              ];
            };

          result = bootstrapped-c { inbox = st "inc"; };
        in
        result.outbox.toList;
      # caller sends "inc" (→1), then two bootstrapped "inc" (→2, →3)
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 3; }
      ];
    };

    # Two independent actors feed a shared downstream actor.
    # design.md's multi-sender-c: sender-a and sender-b both produce messages.
    test-two-senders-shared-actor = {
      expr =
        let
          # Two counters produce plain-number outputs; third counter counts those.
          sender-a = actor (n: reply (n + 1)) { inbox = st 0 1 2; }; # emits 1 2 3
          sender-b = actor (n: reply (n * 10)) { inbox = st 1 2; }; # emits 10 20

          # Downstream sees all values; filters those above threshold
          downstream = actor (n: if n > 5 then reply.right n else reply.left n) {
            inbox = merge [
              sender-a.outbox
              sender-b.outbox
            ];
          };
        in
        {
          above = downstream.outbox.right.toList;
          below = downstream.outbox.left.toList;
        };
      # sender-a emits: 1 2 3 — sender-b emits: 10 20 — merged in list order
      expected = {
        above = [
          10
          20
        ];
        below = [
          1
          2
          3
        ];
      };
    };
  };

  # ── 5. Ping-pong — lazy let, pong feeds ping ──────────────────────────────
  # design.md's ping-pong-c: two actors wired via lazy let.
  # pong reads the external inbox; ping reads pong's output transformed.
  # No circularity — pong does not depend on ping.
  # Nix laziness resolves the dependency order automatically.
  ping-pong = {
    # Canonical ping-pong: pong counts, ping reads counts as "get" queries.
    test-pong-feeds-ping = {
      expr =
        let
          ping-pong-c =
            { inbox }:
            let
              # pong processes the external seed
              pong = counter-c { inherit inbox; };
              # ping gets one "get" per reply from pong — queries a fresh counter
              ping = counter-c { inbox = pong.outbox (st.map (_: "get")); };
            in
            {
              outbox = ping.outbox;
            };

          result = ping-pong-c { inbox = st "inc" "inc" "inc"; };
        in
        result.outbox.toList;
      # pong: 3 replies → ping gets 3 "get" queries → fresh counter always returns 0
      expected = [
        { right = 0; }
        { right = 0; }
        { right = 0; }
      ];
    };

    # Three-stage pipeline: each actor transforms and feeds the next.
    test-three-stage-lazy = {
      expr =
        let
          stage-a = counter-c { inbox = st "inc" "inc" "inc"; };
          # stage-b gets one "inc" per reply from stage-a
          stage-b = counter-c { inbox = stage-a.outbox (st.map (_: "inc")); };
          # stage-c gets one "get" per reply from stage-b
          stage-c = counter-c { inbox = stage-b.outbox (st.map (_: "get")); };
        in
        stage-c.outbox.toList;
      # stage-a: 3 replies → stage-b: 3 "inc" → 3 replies → stage-c: 3 "get"
      # stage-c is always fresh per-message dispatch → always returns 0
      expected = [
        { right = 0; }
        { right = 0; }
        { right = 0; }
      ];
    };
  };

  # ── 6. Inbox concat — extend inbox with upstream replies ──────────────────
  # inbox (actor.outbox) uses the stream functor to concatenate.
  # The actor sees: all external messages first, then the upstream replies.
  # This is the mechanism behind run-feedback in design.md.
  inbox-concat = {
    # External "inc" commands followed by the sub-actor's own replies as "get" queries.
    test-concat-inbox-with-output = {
      expr =
        let
          sub = counter-c { inbox = st "inc" "inc"; };
          # feed same "inc" commands, then query once per sub reply
          extended = counter-c {
            # sub.outbox has 2 replies → mapped to 2 "get" commands
            inbox = (st "inc" "inc") (sub.outbox (st.map (_: "get")));
          };
        in
        extended.outbox.toList;
      # "inc" "inc" → 1, 2; then "get" "get" → both see count=2
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
        { right = 2; }
      ];
    };

    # design.md's run-feedback: b's inbox = seed + a's output (which is empty)
    # Counter ignores { right = n } messages → a produces no output → terminates.
    test-run-feedback-terminates = {
      expr =
        let
          a = counter-c { inbox = st { right = 1; }; }; # unknown msg → no reply
          b = counter-c { inbox = (st "inc") (a.outbox); }; # seed + a's (empty) output
        in
        {
          a-out = a.outbox.toList;
          b-out = b.outbox.toList;
        };
      expected = {
        a-out = [ ]; # counter ignores { right = 1 }
        b-out = [ { right = 1; } ]; # b only processes the "inc" seed
      };
    };
  };

  # ── 7. run with inline cycle body ─────────────────────────────────────────
  # ned.run accepts any cycle-c — including an anonymous lambda.
  # Useful for one-off wiring without naming the cycle.
  run-inline = {
    # Anonymous cycle wrapping counter — same result as named counter-c.
    test-anonymous-cycle = {
      expr =
        let
          result = run {
            inbox = static-d [
              "inc"
              "inc"
              "get"
            ];
          } ({ inbox }: counter-c { inherit inbox; });
        in
        result.outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
      ];
    };

    # Inline cycle that composes two actors — router exposed via run.
    test-inline-composite = {
      expr =
        let
          result =
            run
              {
                inbox = static-d [
                  {
                    type = "count";
                    cmd = "inc";
                  }
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
                    cmd = "get";
                  }
                ];
              }
              (
                { inbox }:
                let
                  counts = counter-c { inbox = when-c (m: m.type == "count") inbox (m: m.cmd); };
                  divides = div-c { inbox = when-c (m: m.type == "div") inbox (m: m); };
                in
                {
                  outbox = counts.outbox (divides.outbox);
                }
              );
        in
        result.outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
        { right = 5; }
      ];
    };
  };
}
