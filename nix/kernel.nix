dnzl:
let
  inherit (dnzl) ned;
  inherit (ned) st;

  reply = {
    __functor = _: data: { reply = data; };
    left = data: {
      reply = {
        left = data;
      };
    };
    right = data: {
      reply = {
        right = data;
      };
    };
  };

  become = next-behaviour: { inherit next-behaviour; };

  eitherST =
    s:
    s
    // {
      right = (s.filter (x: x ? right)) (st.map (x: x.right));
      left = (s.filter (x: x ? left)) (st.map (x: x.left));
    };

  actor =
    initial-behaviour:
    { inbox }:
    let
      step =
        state: msg:
        let
          result = state.behaviour msg;
        in
        {
          behaviour = result.next-behaviour or state.behaviour;
        }
        // (builtins.removeAttrs result [ "next-behaviour" ]);
      states = inbox.scanl step { behaviour = initial-behaviour; };
    in
    {
      outbox = eitherST (states.fields "reply");
      inherit states;
    };

  send = ref: msgs: { reply = (ref { inbox = msgs; }).outbox; };

  merge = streams: eitherST (st.flatten (st.fromList streams));

in
{
  inherit
    actor
    reply
    become
    send
    merge
    ;
}
