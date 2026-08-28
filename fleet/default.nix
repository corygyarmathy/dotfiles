# What this fleet is.
#
# Host names, addresses, the domain and which machine owns which fleet-wide
# duty were each written down in several files that had no way to notice when
# they disagreed. This is the one place they are written down now; everything
# else reads them.
#
# Plain data, deliberately. No `mkIf`, no options, no `config`, no `lib` - so
# the flake can read it before the module system exists (it is what
# `nixosConfigurations` is generated from) and a module can read it through
# `config.cg.fleet`, which is declared with this file as its default in
# ../modules/nixos/fleet.nix.
#
# WHAT BELONGS HERE. Fleet facts, not host choices. `homelab02`'s address is a
# fleet fact: homelab01 mounts its export and cannot be configured without it.
# That homelab02 runs qBittorrent is a host choice and belongs in
# hosts/homelab02/. Moving the second kind in here rebuilds the monolith one
# level up, which is the thing this file exists to undo.
{
  domain = "gyarmathy.co";

  lan = {
    # The trusted network. Caddy's LAN-only allowlist and gluetun's outbound
    # firewall are both written against it.
    cidr = "10.20.2.0/24";
    # Router. Also the PTR resolver for the reverse zone, since it is the only
    # thing that knows what DHCP handed out.
    gateway = "10.20.2.1";
  };

  # Every machine this flake builds. `nixosConfigurations` is generated from
  # this attrset, so adding a host here and a hosts/<name>/ directory is the
  # whole change.
  #
  # `kind` is what the rest of the fleet may assume, not what the host runs: a
  # `server` has a reserved address, is expected to be up, and is scraped,
  # peered and backed up by the others. `xps15` is a laptop on DHCP and is
  # none of those, which is why it has no address to give.
  hosts = {
    homelab01 = {
      kind = "server";
      system = "x86_64-linux";
      address = "10.20.2.85";
    };
    homelab02 = {
      kind = "server";
      system = "x86_64-linux";
      address = "10.20.2.130";
    };
    xps15 = {
      kind = "workstation";
      system = "x86_64-linux";
    };
  };

  # The duties that are fleet-wide rather than host-local - the ones another
  # host has to know the answer to before it can configure itself.
  #
  # This is a short list on purpose. A duty earns a name here when a *second*
  # host needs to point at it; until then it is a host choice and stays in
  # hosts/<name>/.
  roles = {
    # Owns the Cloudflare tunnel, the primary AdGuard instance, and the
    # wildcard that every unlisted subdomain resolves to.
    gateway = "homelab01";
    # Owns the ZFS pool and the NFS export homelab01 mounts.
    storage = "homelab02";
  };
}
