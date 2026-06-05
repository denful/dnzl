{
  outputs = _: { };

  inputs = {
    ned.url = "github:denful/ned";

    bend.url = "github:denful/bend";
    bend.flake = false;

    nix-effects.url = "github:denful/nix-effects";
    nix-effects.flake = false;

    with-inputs.url = "github:denful/with-inputs";
    with-inputs.flake = false;
  };
}
