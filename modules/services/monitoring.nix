# Minimal monitoring
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.monitoring;
in
{
  options.cg.service.monitoring = {
    enable = lib.mkEnableOption "Monitoring with prometheus+grafana";
  };

  config = lib.mkIf cfg.enable {

    services.prometheus = {
      enable = true;
      exporters = {
        node = {
          enable = true;
          enabledCollectors = [
            "systemd"
            "processes"
          ];
        };
      };
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [ { targets = [ "localhost:9100" ]; } ];
        }
      ];
    };

    services.grafana = {
      enable = true;
      settings.server = {
        http_port = 3000;
        domain = "grafana.gyarmathy.co";
      };
    };
  };
}
