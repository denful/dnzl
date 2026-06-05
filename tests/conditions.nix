# Conditions / restart — Common-Lisp-style resumable errors.
#
# A bad input does NOT crash the actor. Instead the behaviour SIGNALS a named
# condition that offers one or more named restarts. A handler policy installed
# at the world edge (via scope-d) decides which restart to invoke, and the
# behaviour RESUMES with the recovery value the restart carries.
#
# The key property: the recovery policy lives entirely outside the behaviour.
# `safe` never mentions a fallback number — it only signals "div-zero" and
# resumes with whatever value comes back. Swap the withRestart policy and the
# same behaviour recovers differently, untouched. This is the algebraic-effects
# encoding of CL conditions: the handler IS the algebra choosing among restarts.
dnzl:
let
  inherit (dnzl)
    ned
    fx
    actor
    reply
    ;
  inherit (ned) st scope-d;
  inherit (fx) bind pure;

  signal = fx.effects.conditions.signal;
  withRestart = fx.effects.conditions.withRestart;

  # Safe division as a behaviour. On a zero divisor it signals "div-zero",
  # offering the "use-zero" restart, then resumes with the restart's value.
  # The non-zero path is a plain pure division. The behaviour knows nothing
  # about which value recovery will supply.
  safe =
    msg:
    reply (
      st (
        if msg.divisor == 0 then
          bind (signal "div-zero" { inherit (msg) dividend; } [ "use-zero" ]) (r: pure r.value)
        else
          pure (msg.dividend / msg.divisor)
      )
    );

  safe-c = actor safe;

  # Run safe-c over an inbox under a given recovery policy.
  run-under = policy: inbox: (scope-d policy (safe-c { inherit inbox; }).outbox).toList;
in
{
  conditions = {
    # Recover with 0: the second message (7/0) resumes as 0.
    # This is the proven oracle.
    test-recover-zero = {
      expr = run-under (withRestart "div-zero" "use-zero" 0) (
        st
          {
            dividend = 10;
            divisor = 2;
          }
          {
            dividend = 7;
            divisor = 0;
          }
      );
      expected = [
        5
        0
      ];
    };

    # Same behaviour, different policy: recover with 999 instead.
    # `safe` is byte-for-byte identical — only the world-edge handler changed.
    test-swap-policy = {
      expr = run-under (withRestart "div-zero" "use-zero" 999) (
        st
          {
            dividend = 10;
            divisor = 2;
          }
          {
            dividend = 7;
            divisor = 0;
          }
      );
      expected = [
        5
        999
      ];
    };

    # No zero divisor anywhere → the condition never fires; the handler is
    # present but idle. Both divisions take the pure path.
    test-no-signal = {
      expr = run-under (withRestart "div-zero" "use-zero" 0) (
        st
          {
            dividend = 10;
            divisor = 2;
          }
          {
            dividend = 20;
            divisor = 4;
          }
      );
      expected = [
        5
        5
      ];
    };

    # The policy applies to every signal in the stream: two separate zero
    # divisors both resume with -1, the good division in between is untouched.
    test-recovery-applies-per-signal = {
      expr = run-under (withRestart "div-zero" "use-zero" (-1)) (
        st
          {
            dividend = 8;
            divisor = 0;
          }
          {
            dividend = 9;
            divisor = 3;
          }
          {
            dividend = 1;
            divisor = 0;
          }
      );
      expected = [
        (-1)
        3
        (-1)
      ];
    };
  };
}
