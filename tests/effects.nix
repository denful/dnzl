# Effects / dependency-injection — the reader pattern for actors.
#
# A behaviour can REQUEST an effect instead of hard-coding a value: it names
# the effect as a function argument and returns it inside an ST. `st` over a
# function-with-named-args becomes an effect *request* (ctx-s); the value is
# left unresolved until the world edge supplies it.
#
# The edge resolves requests with a `ctx-d` handler: `ctx-d { name = val; }`
# binds each requested name to a constant. Swap the handler → swap the value,
# with the SAME behaviour unchanged. This is dependency-injection: the
# behaviour stays pure and testable; the deployment (prod vs mock) is chosen
# at the edge by picking a handler.
#
# Mechanics:
#   reply (st (fn-with-named-args))   →  emits an effect request per message
#   ctx-d { greeting = "Hi"; } outbox →  resolves "greeting" in every request
dnzl:
let
  inherit (dnzl) actor reply;
  inherit (dnzl.ned) st ctx-d;

  # greeter REQUESTS the effect `greeting` — it never decides what the greeting
  # word is. The message (the name to greet) is captured; `greeting` stays open.
  greeter = msg: reply (st ({ greeting }: "${greeting}, ${msg}!"));
  greeter-c = actor greeter;

  # connect REQUESTS two effects, `host` and `port`, and combines them with the
  # message (the user). One behaviour, environment supplied from outside.
  connect = user: reply (st ({ host, port }: "${user}@${host}:${toString port}"));
  connect-c = actor connect;
in
{
  effects = {
    # The handler `ctx-d { greeting = "Hello"; }` provides the requested value.
    # Each message in the inbox produces one resolved reply.
    test-resolve = {
      expr = (ctx-d { greeting = "Hello"; } (greeter-c { inbox = st "world" "tux"; }).outbox).toList;
      expected = [
        "Hello, world!"
        "Hello, tux!"
      ];
    };

    # Same behaviour, different handler. Only the edge changes — `greeter` is
    # untouched — yet every reply now says "Hi". This is the swap.
    test-swap-handler = {
      expr = (ctx-d { greeting = "Hi"; } (greeter-c { inbox = st "world" "tux"; }).outbox).toList;
      expected = [
        "Hi, world!"
        "Hi, tux!"
      ];
    };

    # Multiple effects at once. The prod handler binds real host/port; the
    # message still flows through, so each user gets its own line.
    test-multi-effect = {
      expr =
        (ctx-d {
          host = "igloo";
          port = 22;
        } (connect-c { inbox = st "tux" "root"; }).outbox).toList;
      expected = [
        "tux@igloo:22"
        "root@igloo:22"
      ];
    };

    # The mock handler swaps the whole environment for tests. `connect` is the
    # exact same behaviour as above — only the supplied bindings differ.
    test-mock-deployment = {
      expr =
        (ctx-d {
          host = "mock";
          port = 0;
        } (connect-c { inbox = st "tux" "root"; }).outbox).toList;
      expected = [
        "tux@mock:0"
        "root@mock:0"
      ];
    };
  };
}
