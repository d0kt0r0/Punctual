{ reflex-commit ? "9e306f72ed0dbcdccce30a4ba0eb37aa03cf91e3" }:

let reflex-platform = builtins.fetchTarball "https://github.com/reflex-frp/reflex-platform/archive/${reflex-commit}.tar.gz"; in

(import reflex-platform {}).project ({ pkgs, ... }:

with pkgs.haskell.lib;

{

  name = "Punctual";

  packages = {
    punctual = ./.;
  };

  shells = {
    ghc = ["punctual"];
    ghcjs = ["punctual"];
  };

  android = {};

  overrides = self: super: {
    #       lens = self.callHackage "lens" "4.15.4" {}; # saving this example in case we need it later

    base-compat-batteries = dontCheck super.base-compat-batteries;

    text-show = dontCheck super.text-show;

    musicw = dontHaddock (self.callCabal2nix "musicw" (pkgs.fetchFromGitHub {
      owner = "dktr0";
      repo = "musicw";
<<<<<<< HEAD
      rev = "9b0dd9d6b3374f2635916ec9c5d748f2ebdeec57";
      sha256 = "1r4dyf2lhk8rprvlb4nm7vigkfdqkcjpiifgqlks2qrqb8jdwf8h";
=======
      sha256 = "0vl6kamccf11pk7fd2jb8pdh88rynppgym40z55bafafyihk09na";
      rev = "05c9bdd016a7777510aef8b3c05626f6e2223b7d";
>>>>>>> async
      }) {});

    reflex-dom-contrib = dontHaddock (self.callCabal2nix "reflex-dom-contrib" (pkgs.fetchFromGitHub {
      owner = "reflex-frp";
      repo = "reflex-dom-contrib";
      rev = "b9e2965dff062a4e13140f66d487362a34fe58b3";
      sha256 = "1aa045mr82hdzzd8qlqhfrycgyhd29lad8rf7vsqykly9axpl52a";
      }) {});

    haskellish = dontHaddock (self.callCabal2nix "haskellish" (pkgs.fetchFromGitHub {
      owner = "dktr0";
      repo = "Haskellish";
      sha256 = "0n2926g62j6cjy1fmb6s2zx4lwc24mrica03cplh9ahh9gfwgfwx";
      rev = "41caf3c9eeb4847643dce307bdcdab3bf1accf17";
      }) {});

  };

})
