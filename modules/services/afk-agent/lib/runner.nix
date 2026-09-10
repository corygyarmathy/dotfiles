# Assembles the AFK runner script from the stage fragments in ./stages/.
#
# Each fragment is plain shell with @TOKEN@ placeholders where a Nix value
# belongs (plain files, so shellcheck and editors see real shell instead of a
# Nix string). This file substitutes the values and concatenates the stages
# in pipeline order. The fragments are the inline script this replaced:
# the logic is unchanged, whitespace and comment wording drifted in the
# move, and the generated values below match the old inline expressions
# byte for byte. Behaviour is pinned by checks/afk-agent-runner.nix.
{
  lib,
  stateDir,
  repository,
  ntfyUrl,
  ntfyTopic,
  deniedPaths,
  sessionListDepth,
  botLogin,
  handoffLabel,
  credentialNames,
  toolNames,
  appId,
  commitName,
  commitEmail,
  implementPrompt,
  gateTimeout,
  attemptTimeout,
  gateTailLines,
  maxAttempts,
  model,
  variant,
  permissionOverlay,
  reviewModel,
  prIntro,
  prHandoff,
  ciPollInterval,
  ciFirstCheckPolls,
  ciSettlePolls,
  maxCiRounds,
  reviewPrompt,
  reviewOverlay,
  reviewTimeout,
  reviewAxes,
  revisePrompt,
  reviseLabel,
  maxRevisionRounds,
  label,
  baseBranch,
  branchPrefix,
  prLabel,
  workingLabel,
  stuckLabel,
}:
let
  stageDir = ./stages;

  # Pipeline order: claim -> isolate -> implement -> push gate -> push ->
  # pull request -> watch CI -> review -> hand off, with the stuck path
  # available throughout (see ADR 0007). 150-revise.sh is the second entry
  # point (#196): the issue poll hands the run over to it when its
  # queue is empty, and the stages in between read `$flow` and step aside.
  stageFiles = [
    "00-env.sh"
    "10-util.sh"
    "20-notify.sh"
    "30-stuck.sh"
    "40-preflight.sh"
    "50-poll-claim.sh"
    "60-isolate.sh"
    "70-implement.sh"
    "80-push-gate.sh"
    "90-push.sh"
    "100-pr.sh"
    "110-ci.sh"
    "120-review.sh"
    "130-verify-review.sh"
    "140-handoff.sh"
    "150-revise.sh"
  ];

  # Fragments carry a `# shellcheck shell=bash` directive so they lint
  # standalone; it is not part of the runner and is stripped here.
  readStage =
    name:
    let
      content = builtins.readFile (stageDir + "/${name}");
      prefix = "# shellcheck shell=bash\n";
    in
    assert lib.hasPrefix prefix content;
    lib.removePrefix prefix content;

  template = lib.concatStringsSep "" (map readStage stageFiles);

  values = {
    "@STATE_DIR@" = stateDir;
    "@REPOSITORY@" = repository;
    "@NTFY_URL@" = ntfyUrl;
    "@NTFY_TOPIC@" = ntfyTopic;
    # The three generated line groups reproduce the inline expressions
    # exactly. builtins.readFile does no indentation handling, so the
    # placeholder's own indent lives here in the separator values: the
    # "  " prefix and the "\n        " separators below are the same bytes
    # the inline script produced, not anything the substitution mechanism
    # supplies. checks/afk-agent-runner.nix pins this behaviour.
    "@DENIED_LINES@" = "  " + lib.concatMapStringsSep "\n        " (p: "\"${p}\"") deniedPaths;
    "@SESSION_LIST_DEPTH@" = toString sessionListDepth;
    "@HANDOFF_LABEL@" = handoffLabel;
    "@REQUIRE_CREDENTIAL_LINES@" = lib.concatMapStringsSep "\n      " (
      name: "require_credential ${name}"
    ) credentialNames;
    "@REQUIRE_TOOL_LINES@" = lib.concatMapStringsSep "\n      " (
      name: "require_tool ${name}"
    ) toolNames;
    "@APP_ID@" = appId;
    "@COMMIT_NAME@" = lib.escapeShellArg commitName;
    "@COMMIT_EMAIL@" = lib.escapeShellArg commitEmail;
    "@IMPLEMENT_PROMPT@" = toString implementPrompt;
    "@GATE_TIMEOUT@" = toString gateTimeout;
    "@ATTEMPT_TIMEOUT@" = toString attemptTimeout;
    "@GATE_TAIL_LINES@" = toString gateTailLines;
    "@MAX_ATTEMPTS@" = toString maxAttempts;
    "@MODEL@" = model;
    "@VARIANT@" = variant;
    "@PERMISSION_OVERLAY@" = lib.escapeShellArg permissionOverlay;
    "@REVIEW_MODEL@" = reviewModel;
    "@PR_INTRO@" = toString prIntro;
    "@PR_HANDOFF@" = toString prHandoff;
    "@CI_POLL_INTERVAL@" = toString ciPollInterval;
    "@CI_FIRST_CHECK_POLLS@" = toString ciFirstCheckPolls;
    "@CI_SETTLE_POLLS@" = toString ciSettlePolls;
    "@MAX_CI_ROUNDS@" = toString maxCiRounds;
    "@REVIEW_PROMPT@" = toString reviewPrompt;
    "@REVIEW_OVERLAY@" = lib.escapeShellArg reviewOverlay;
    "@REVIEW_TIMEOUT@" = toString reviewTimeout;
    "@REVIEW_AXES@" = toString reviewAxes;
    "@REVISE_PROMPT@" = toString revisePrompt;
    "@REVISE_LABEL@" = reviseLabel;
    "@MAX_REVISION_ROUNDS@" = toString maxRevisionRounds;
    "@BOT_LOGIN@" = botLogin;
    "@LABEL@" = label;
    "@BASE_BRANCH@" = baseBranch;
    "@BRANCH_PREFIX@" = branchPrefix;
    "@PR_LABEL@" = prLabel;
    "@WORKING_LABEL@" = workingLabel;
    "@STUCK_LABEL@" = stuckLabel;
  };
in
lib.replaceStrings (lib.attrNames values) (lib.attrValues values) template
