dnzl:
let
  inherit (dnzl) fx ned;
in
{
  smoke = {
    test-works = {
      expr = 20;
      expected = 20;
    };
  };
}
