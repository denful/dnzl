{
  inputs = {
    ned.url = "github:denful/ned";
  };

  outputs = inputs: {
    lib = import ./. { inherit inputs; };
  };
}
