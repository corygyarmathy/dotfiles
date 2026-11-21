# Seeley MagIQtouch, as a Home Assistant custom component.
#
# Controls Seeley evaporative coolers and heaters through Seeley's own cloud
# (AWS Cognito sign-in with the MagIQtouch app's account), so it works only
# while that cloud does.
#
# Needs v5.2 or later: v5.1 predates Home Assistant 2026.4, whose OptionsFlow
# change makes v5.1's options page throw (fixed upstream in #45).
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

buildHomeAssistantComponent rec {
  owner = "andrewleech";
  domain = "magiqtouch";
  version = "5.2";

  src = fetchFromGitHub {
    owner = "andrewleech";
    repo = "ha_magiqtouch";
    tag = "v${version}";
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
      # buildHomeAssistantComponent re-declares `version`, so its position is in
      # nixpkgs, outside this flake, and nix-update refuses it. Name the file.
      "--override-filename"
      "packages/ha-magiqtouch/default.nix"
    ];
  };

  meta = {
    description = "Home Assistant integration for Seeley MagIQtouch controllers";
    homepage = "https://github.com/andrewleech/ha_magiqtouch";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
