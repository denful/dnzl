{
  outputs = _: { };

  inputs = {
    ned.url = "github:denful/ned";

    with-inputs.url = "github:denful/with-inputs";
    with-inputs.flake = false;
  };
}
