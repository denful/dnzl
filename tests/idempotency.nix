# Idempotent / at-most-once message handling with st.dedup.
#
# In a distributed system, commands get retried: a client resends because it
# never saw the ack, or the transport delivers the same message twice. If each
# retry were applied, a stateful actor would over-count.
#
# st.dedup key-fn stream drops every item whose key was already seen, keeping
# only the FIRST occurrence. Tag each command with a stable message id and use
# that id as the dedup key: retries collapse, so each command is applied
# at-most-once. Feed the deduped commands into a stateful counter and the count
# reflects only the unique commands — duplicates leave no trace.
#
# The kernel's dedup (ned/kernel.nix) uses scanl to track seen keys and emits
# each key's first occurrence only.
dnzl:
let
  inherit (dnzl)
    ned
    actor
    reply
    become
    ;
  inherit (ned) st;

  # Canonical stateful counter: "inc" bumps and remembers, "get" reads.
  counter =
    count: msg:
    if msg == "inc" then
      reply.right (count + 1) // become (counter (count + 1))
    else if msg == "get" then
      reply.right count
    else
      { };
  counter-c = actor (counter 0);

  # Retried command log: id 1 twice, id 2 twice, id 3 once — 5 deliveries,
  # but only 3 distinct commands. Every command is the same operation ("inc").
  cmds =
    st
      {
        id = 1;
        op = "inc";
      }
      {
        id = 1;
        op = "inc";
      }
      {
        id = 2;
        op = "inc";
      }
      {
        id = 2;
        op = "inc";
      }
      {
        id = 3;
        op = "inc";
      };
in
{
  idempotency = {
    # dedup by message id collapses the retries: 5 deliveries → 3 unique
    # commands, so the counter only ever advances to 3.
    test-dedup-collapses-retries = {
      expr =
        let
          unique = ned.st.dedup (m: m.id) cmds;
          ops = unique (st.map (m: m.op));
        in
        (counter-c { inbox = ops; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 3; }
      ];
    };

    # Contrast: feed the SAME commands without dedup and every retry is
    # applied — the counter over-counts to 5. This is the bug dedup prevents.
    test-without-dedup-applies-all = {
      expr =
        let
          ops = cmds (st.map (m: m.op));
        in
        (counter-c { inbox = ops; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 3; }
        { right = 4; }
        { right = 5; }
      ];
    };

    # The deduped count is the source of truth: after applying the unique
    # incs, a final "get" reads 3 — not 5 — confirming retries left no trace.
    test-count-reflects-unique = {
      expr =
        let
          unique = ned.st.dedup (m: m.id) cmds;
          ops = unique (st.map (m: m.op));
          # concat a trailing "get" op after the deduped incs
          ops-with-get = ops (st "get");
        in
        (counter-c { inbox = ops-with-get; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 3; }
        { right = 3; } # get → final count is 3 unique commands, not 5
      ];
    };

    # dedup keeps the FIRST occurrence in arrival order. Here later deliveries
    # of an id carry a different payload (a stale retry); dedup discards them
    # and preserves the first-seen value, in order.
    test-dedup-keeps-first = {
      expr =
        let
          retries =
            st
              {
                id = 1;
                v = "a";
              }
              {
                id = 2;
                v = "b";
              }
              {
                id = 1;
                v = "a-RETRY";
              }
              {
                id = 3;
                v = "c";
              }
              {
                id = 2;
                v = "b-RETRY";
              };
          unique = ned.st.dedup (m: m.id) retries;
        in
        {
          ids = (unique (st.map (m: m.id))).toList;
          vals = (unique (st.map (m: m.v))).toList;
        };
      expected = {
        ids = [
          1
          2
          3
        ];
        vals = [
          "a"
          "b"
          "c"
        ];
      };
    };
  };
}
