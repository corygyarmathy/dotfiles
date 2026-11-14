# Seeley MagIQtouch, as a Home Assistant custom component.
#
# Controls Seeley evaporative coolers and heaters through Seeley's own cloud
# (AWS Cognito sign-in with the MagIQtouch app's account), so it works only
# while that cloud does.
#
# Tracks the `hacs` branch rather than the last release: v5.1 predates Home
# Assistant 2026.4, whose OptionsFlow change makes v5.1's options page throw.
# The fix (#45) is on the branch and in no tag yet.
#
# The component vendors its Python dependencies (boto3, aiobotocore, mandate,
# python-jose, ...) under custom_components/magiqtouch/vendor and appends that
# directory to sys.path, so nothing here supplies them. Appended, not
# prepended: where Home Assistant ships the same module (aiohttp, attrs, yarl)
# its own copy wins, and only the AWS libraries come from the vendor tree.
{
  lib,
  buildHomeAssistantComponent,
  fetchFromGitHub,
  nix-update,
}:

buildHomeAssistantComponent {
  owner = "andrewleech";
  domain = "magiqtouch";
  version = "5.1-unstable-2026-04-15";

  src = fetchFromGitHub {
    owner = "andrewleech";
    repo = "ha_magiqtouch";
    rev = "801fdeb321ffe6c6635f7d7d92ef6e7a4bbac980";
    hash = "sha256-Ny0tmOJ8Ov6TV35sX+K89I6nVl/gYtngglVp7hMHaLE=";
  };

  passthru = {
    # Opt in to .github/workflows/package-update.yml; see packages/comskip for
    # why this is explicit and why nix-update is wrapped.
    autoUpdate = true;
    updateScript = [
      "packages/update-via-nix-update.sh"
      (lib.getExe nix-update)
      "ha-magiqtouch"
      "--version=branch=hacs"
    ];
  };

  meta = {
    description = "Home Assistant integration for Seeley MagIQtouch controllers";
    homepage = "https://github.com/andrewleech/ha_magiqtouch";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
