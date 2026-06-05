# Dnzl actor system — `st.withPeers`: neighbour-aware grouping.
#
# `st.withPeers key-fn f source` groups the source stream by `key-fn`, then for
# every item calls `f peers item` where `peers` is the WHOLE group that item
# belongs to. This is RELATIONAL grouping: each item gets to see its siblings —
# unlike per-item `when-c` routing, where a message only ever sees itself.
#
# Leader election is the canonical use. Votes are grouped by election id; within
# each group every node can inspect the full slate of peers and decide the
# winner (highest vote). To emit exactly ONE row per election, the behaviour
# emits only for the winning item (`st {...}`) and the empty stream (`st`)
# otherwise — so the per-item fan-out collapses to one leader per group.
dnzl:
let
  inherit (dnzl) ned;
  inherit (ned) st;

  # leader :: [vote] -> vote -> ST leader-row
  # Given the peer group and the current vote, find the highest-vote node.
  # Only the winning vote emits a row; every other vote emits nothing. The net
  # effect across the group is a single leader announcement per election.
  leader =
    peers: m:
    let
      winner = builtins.head (builtins.sort (p: q: p.v > q.v) peers);
    in
    if m.node == winner.node then
      st {
        inherit (m) election;
        leader = winner.node;
        votes = winner.v;
      }
    else
      st; # losers stay silent → exactly one row per election
in
{
  leader-election = {
    # One election, three candidates: the relational view lets every vote see
    # the whole slate, so the group agrees on a single winner (highest vote).
    test-single-election = {
      expr =
        let
          votes =
            st
              {
                election = "alpha";
                node = "n1";
                v = 2;
              }
              {
                election = "alpha";
                node = "n2";
                v = 7;
              }
              {
                election = "alpha";
                node = "n3";
                v = 4;
              };
        in
        (st.withPeers (m: m.election) leader votes).toList;
      expected = [
        {
          election = "alpha";
          leader = "n2";
          votes = 7;
        }
      ];
    };

    # Two interleaved elections: withPeers partitions by election id first, so
    # x-votes never see y-votes. Each group elects its own leader independently —
    # one row per election, in group order (x before y).
    test-multiple-elections = {
      expr =
        let
          votes =
            st
              {
                election = "x";
                node = "a";
                v = 3;
              }
              {
                election = "x";
                node = "b";
                v = 5;
              }
              {
                election = "y";
                node = "c";
                v = 1;
              }
              {
                election = "x";
                node = "c";
                v = 2;
              };
        in
        (st.withPeers (m: m.election) leader votes).toList;
      expected = [
        {
          election = "x";
          leader = "b";
          votes = 5;
        }
        {
          election = "y";
          leader = "c";
          votes = 1;
        }
      ];
    };

    # Quorum: a leader is only declared if the group has enough voters. Here the
    # winner emits only when its peer group reaches 3 — so election "x" (3 voters)
    # elects "b", while election "y" (a single lone vote) is dropped entirely.
    # This is exactly what per-item routing cannot do: the decision depends on
    # how many siblings the item has.
    test-quorum = {
      expr =
        let
          quorum =
            peers: m:
            let
              winner = builtins.head (builtins.sort (p: q: p.v > q.v) peers);
            in
            if m.node == winner.node && builtins.length peers >= 3 then
              st {
                inherit (m) election;
                leader = winner.node;
                quorum = builtins.length peers;
              }
            else
              st;
          votes =
            st
              {
                election = "x";
                node = "a";
                v = 3;
              }
              {
                election = "x";
                node = "b";
                v = 5;
              }
              {
                election = "y";
                node = "c";
                v = 1;
              }
              {
                election = "x";
                node = "c";
                v = 2;
              };
        in
        (st.withPeers (m: m.election) quorum votes).toList;
      expected = [
        {
          election = "x";
          leader = "b";
          quorum = 3;
        }
      ];
    };

    # Peer-count: instead of collapsing to a winner, every item can keep its own
    # row AND read its group size. This shows `peers` really is the full group —
    # each x-vote reports peers = 3, the lone y-vote reports peers = 1. Items stay
    # in group order, members in source order within each group.
    test-peer-count = {
      expr =
        let
          tag =
            peers: m:
            st {
              v = m.v;
              peers = builtins.length peers;
            };
          votes =
            st
              {
                election = "x";
                node = "a";
                v = 3;
              }
              {
                election = "x";
                node = "b";
                v = 5;
              }
              {
                election = "y";
                node = "c";
                v = 1;
              }
              {
                election = "x";
                node = "c";
                v = 2;
              };
        in
        (st.withPeers (m: m.election) tag votes).toList;
      expected = [
        {
          peers = 3;
          v = 3;
        }
        {
          peers = 3;
          v = 5;
        }
        {
          peers = 3;
          v = 2;
        }
        {
          peers = 1;
          v = 1;
        }
      ];
    };
  };
}
