# The garden's pipeline - filter, renderer, serving config - as one function
# of the site's settings.
#
# The service and `nix run .#garden-preview` both call this, which is what
# keeps the preview from drifting from the server: both are handed
# the same pieces built from the same settings (lib/site.nix), rather than the
# preview reading them back out of an evaluated host.
# The filter checks import lib/filter.nix directly: it takes no settings, so
# it is the same derivation either way.
{ pkgs, lib }:
{
  mkGarden =
    {
      baseUrl,
      siteTitle,
      siteDescription,
      styleSheet,
      footerLinks,
    }:
    {
      renderer = (import ./hugo.nix { inherit pkgs lib; }).mkRenderer {
        inherit
          baseUrl
          siteTitle
          siteDescription
          styleSheet
          footerLinks
          ;
      };
      # The publish filter: publish-filter.py and the bonsai.py it imports,
      # assembled into one directory. See the header of lib/filter.nix.
      filter = import ./filter.nix { inherit pkgs; };
      serve = import ./serve.nix { inherit lib; };
      # The rendering fixture: every element the theme styles, on as few pages
      # as possible. See the header of lib/preview.nix.
      fixture = ./hugo/fixture;
      # The stylesheet baked into the renderer, for a caller that wants to
      # offer a different one in its place.
      inherit styleSheet;
    };
}
