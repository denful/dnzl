# Schema-validated messages via bend lenses.
#
# A `bend` schema is a `{ get, set }` lens. Applying a lens to a stream
# (`msgs schema`) makes the stream functor map `lens.get` over every element,
# producing a stream of Either: valid messages become `{ right = ... }`,
# invalid ones `{ left = ... }` carrying blame. `.right` / `.left` then split
# that stream into successes and failures — no manual pattern-matching.
#
# `bend.recordAll` is an attrset lens that collects ALL field errors at once:
# every field is validated and reported, so a single bad message names every
# field that failed via `{ field, got }` blame.
dnzl:
let
  inherit (dnzl) ned bend;
  inherit (ned) st;

  # Each message must have a string `name` and an int `age`.
  schema = bend.recordAll {
    name = bend.str;
    age = bend.int;
  };
in
{
  validation = {
    # Valid message → right-wrapped, rebuilt record. The lens re-emits the
    # validated attrset so downstream actors get a clean, typed payload.
    test-valid-passes = {
      expr =
        let
          validated = st {
            name = "alice";
            age = 30;
          } schema;
        in
        validated.right.toList;
      expected = [
        {
          right = {
            name = "alice";
            age = 30;
          };
        }
      ];
    };

    # Invalid field → left-wrapped blame. recordAll reports every field: the
    # passing `name` stays `{ right = ... }`, the failing `age` becomes
    # `{ left = { field; got; } }` so the failure is fully attributed.
    test-invalid-is-blamed = {
      expr =
        let
          validated =
            st
              {
                name = "alice";
                age = 30;
              }
              {
                name = "bob";
                age = "oops";
              }
              schema;
        in
        {
          ok = validated.right.toList;
          bad = validated.left.toList;
        };
      expected = {
        ok = [
          {
            right = {
              name = "alice";
              age = 30;
            };
          }
        ];
        bad = [
          {
            left = {
              name = {
                right = "bob";
              };
              age = {
                left = {
                  field = "age";
                  got = "oops";
                };
              };
            };
          }
        ];
      };
    };

    # Multiple bad fields in one message → recordAll collects ALL errors, not
    # just the first. Both `name` and `age` come back blamed in one `left`.
    test-collects-all-errors = {
      expr =
        let
          validated = st {
            name = 7;
            age = "oops";
          } schema;
        in
        validated.left.toList;
      expected = [
        {
          left = {
            name = {
              left = {
                field = "name";
                got = 7;
              };
            };
            age = {
              left = {
                field = "age";
                got = "oops";
              };
            };
          };
        }
      ];
    };
  };
}
