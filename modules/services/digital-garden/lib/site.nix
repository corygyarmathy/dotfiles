# What this garden is called, where it lives and what it links to: the
# settings that make lib/pipeline.nix produce THIS site rather than a site.
#
# Plain data, read in two places. The module takes its option defaults from
# here, and `nix run .#garden-preview` hands it to the pipeline directly, so
# the preview renders the same masthead and footer as the server without
# evaluating a host to find out what they are. That only holds while no host
# overrides these options: change the site here, not in hosts/.
{ domain }:
{
  baseUrl = "garden.${domain}";
  siteTitle = "Cory Gyarmathy";
  siteDescription = "Notes and essays, published from a private vault.";
  # An empty URL renders as muted text rather than as a link, so these two
  # hold their place in the header's link list until they have somewhere to
  # point - rather than shipping two 404s or two stub pages to stand in for
  # them. Fill in a URL and it becomes an ordinary link.
  footerLinks = {
    GitHub = "https://github.com/corygyarmathy";
    Projects = "";
    Resume = "";
  };
  styleSheet = ./hugo/assets/main.css;
}
