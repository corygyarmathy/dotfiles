# The fleet, as an ordinary NixOS option.
#
# ../../fleet is the data; this is how a module reads it. A module that needs
# the domain or another host's address reads `config.cg.fleet` like it reads
# anything else and stays a normal NixOS module - no extra function argument,
# no dependency on how it was instantiated.
#
# TWO THINGS HERE ARE LOAD-BEARING.
#
# The data is the option's *default*, not a definition set by `mkHost`. Those
# look equivalent and are not: the behaviour tests in ../../checks instantiate
# service modules directly and never go near `mkHost`, so as a definition the
# first module to read `cg.fleet` would break every check containing it, and
# the repair would be to teach checks/lib.nix to inject a fleet into every
# test - a harness change caused entirely by where the value was put. As a
# default, every evaluation of the module system gets the fleet, tests
# included, and `mkHost` sets nothing.
#
# It is not `readOnly`, which is the obvious thing to reach for and silently
# costs the property this exists for. `readOnly` counts the option's own
# default among its definitions, so `readOnly` plus a `default` rejects *any*
# override - "The option `cg.fleet' is read-only, but it's set multiple
# times." - and every check would be permanently stuck with the production
# fleet, unable to exercise a module against a different one. checks/
# reverse-proxy.nix does exactly that. Single-sourcing is kept here by
# convention; what the mechanism still buys is below.
#
# `types.raw` rather than an attrset type, so the option does not merge: two
# modules both defining `cg.fleet` is a conflict error rather than a silent
# union of two fleets. That is most of what `readOnly` was wanted for, at no
# cost to the override.
#
# The shape is documented in ../../fleet/default.nix rather than in a
# submodule type: the file is the schema, and a type here would be a second
# copy of it to keep in step.
#
# Modules that read the fleet import this file themselves, so that a check
# instantiating one module gets the declaration with it. Importing the same
# path from several modules is free - the module system keys on the path.
{ lib, ... }:
{
  options.cg.fleet = lib.mkOption {
    type = lib.types.raw;
    default = import ../../fleet;
    defaultText = lib.literalExpression "import ./fleet";
    description = ''
      Facts about this fleet that more than one host has to agree on: the
      domain, the LAN, every host's address and which host owns which
      fleet-wide duty. See `fleet/default.nix` for the shape and for what
      belongs in it.
    '';
  };
}
