dnzl:
let
  inherit (dnzl)
    ned
    actor
    reply
    become
    send
    merge
    ;
  inherit (ned) st map-c;

  counter =
    count: msg:
    if msg == "inc" then
      reply.right (count + 1) // become (counter (count + 1))
    else if msg == "get" then
      reply.right count
    else if msg == "reset" then
      reply.right 0 // become (counter 0)
    else
      { };

  counter-c = actor (counter 0);

  safe-div =
    msg:
    if msg.divisor == 0 then reply.left "div-by-zero" else reply.right (msg.dividend / msg.divisor);

  div-c = actor safe-div;

  expander = msg: { reply = st.fromList msg.items; };
  expander-c = actor expander;

  echo-c = map-c (x: x);

in
{
  actor = {
    test-counter = {
      expr = (counter-c { inbox = st "inc" "inc" "get"; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 2; }
      ];
    };

    test-become = {
      expr = (counter-c { inbox = st "inc" "inc" "inc" "get"; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 3; }
        { right = 3; }
      ];
    };

    test-reset = {
      expr = (counter-c { inbox = st "inc" "inc" "reset" "get"; }).outbox.toList;
      expected = [
        { right = 1; }
        { right = 2; }
        { right = 0; }
        { right = 0; }
      ];
    };

    test-unknown-msg-no-reply = {
      expr = (counter-c { inbox = st "unknown"; }).outbox.toList;
      expected = [ ];
    };

    test-typed-replies = {
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
                  dividend = 5;
                  divisor = 0;
                };
          };
        in
        {
          ok = a.outbox.right.toList;
          err = a.outbox.left.toList;
        };
      expected = {
        ok = [ 5 ];
        err = [ "div-by-zero" ];
      };
    };

    test-fan-out = {
      expr =
        (expander-c {
          inbox = st {
            items = [
              1
              2
              3
            ];
          };
        }).outbox.toList;
      expected = [
        1
        2
        3
      ];
    };

    test-merge = {
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

    test-send = {
      expr =
        let
          proxy = msg: send counter-c (st msg);
          proxy-c = actor proxy;
          a = proxy-c { inbox = st "inc" "inc" "get"; };
        in
        a.outbox.toList;
      expected = [
        { right = 1; }
        { right = 1; }
        { right = 0; }
      ];
    };
  };
}
