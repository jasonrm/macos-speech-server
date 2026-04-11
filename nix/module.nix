{ config, lib, pkgs, ... }:

let
  cfg = config.services.speech-server;

  # speech-server reads YAML via Yams. YAML 1.2 is a superset of JSON, so the
  # JSON document produced by `pkgs.formats.json` is a valid YAML document and
  # is consumed unchanged.
  format = pkgs.formats.json { };

  configFile = format.generate "speech-server.json" cfg.settings;
in
{
  options.services.speech-server = {
    enable = lib.mkEnableOption "macos-speech-server (OpenAI-compatible speech API + Wyoming protocol)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.speech-server;
      defaultText = lib.literalExpression "pkgs.speech-server";
      description = "speech-server package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "_speech-server";
      description = "User account under which speech-server runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "_speech-server";
      description = "Primary group of the speech-server service user.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 401;
      description = ''
        UID for the service user. Must be unique on the host. nix-darwin
        cannot allocate UIDs dynamically, so pick something free in the system
        range (typically 200–500).
      '';
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 401;
      description = "GID for the service group. Same caveats as `uid`.";
    };

    homeDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/speech-server";
      description = ''
        Home directory for the service user. FluidAudio caches downloaded
        ASR/TTS models under `$HOME/Library/Application Support/FluidAudio`,
        so this directory must be writable by the service user and have
        enough space for the model bundles (several GB on first run).
      '';
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log/speech-server";
      description = "Directory for `output.log` and `error.log`.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        HTTP bind address. Convenience for
        `services.speech-server.settings.servers.http.host`; explicit values
        in `settings` win.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        HTTP listening port. Convenience for
        `services.speech-server.settings.servers.http.port`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = format.type;
      };
      default = { };
      example = lib.literalExpression ''
        {
          log_level = "notice";
          servers.wyoming.port = 10300;
          stt = {
            engine = "parakeet";
            parakeet.model_version = "v3";
          };
          tts = {
            engine = "avspeech";
            avspeech.default_voice = "Samantha";
          };
        }
      '';
      description = ''
        Free-form speech-server configuration. Rendered to JSON (a valid YAML
        subset, parsed by Yams) and exposed to the daemon via the
        `SPEECH_SERVER_CONFIG` environment variable. See `speech-server.yaml.example`
        in the upstream repo for the full schema.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Top-level convenience options bleed into `settings` with mkDefault so any
    # explicit value the user puts in `settings` overrides them.
    services.speech-server.settings = {
      servers.http.host = lib.mkDefault cfg.host;
      servers.http.port = lib.mkDefault cfg.port;
    };

    users.knownUsers = [ cfg.user ];
    users.knownGroups = [ cfg.group ];

    users.users.${cfg.user} = {
      description = "speech-server service account";
      uid = cfg.uid;
      gid = cfg.gid;
      home = cfg.homeDir;
      shell = "/usr/bin/false";
    };

    users.groups.${cfg.group} = {
      gid = cfg.gid;
      description = "speech-server service group";
    };

    # The launchd daemon runs as `cfg.user`, so it cannot create root-owned
    # state directories itself. Provision them at system activation time.
    system.activationScripts.speech-server-dirs.text = ''
      echo "setting up speech-server state directories" >&2
      install -d -m 0755 ${lib.escapeShellArg cfg.homeDir} ${lib.escapeShellArg cfg.logDir}
      chown ${cfg.user}:${cfg.group} ${lib.escapeShellArg cfg.homeDir} ${lib.escapeShellArg cfg.logDir}
    '';

    launchd.daemons.speech-server = {
      serviceConfig = {
        Label = "org.nixos.speech-server";
        ProgramArguments = [ (lib.getExe cfg.package) "serve" ];
        RunAtLoad = true;
        KeepAlive = true;
        UserName = cfg.user;
        GroupName = cfg.group;
        WorkingDirectory = cfg.homeDir;
        EnvironmentVariables = {
          SPEECH_SERVER_CONFIG = "${configFile}";
          HOME = cfg.homeDir;
        };
        StandardOutPath = "${cfg.logDir}/output.log";
        StandardErrorPath = "${cfg.logDir}/error.log";
      };
    };
  };
}
