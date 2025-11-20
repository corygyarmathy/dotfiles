{
  lib,
  config,
  pkgs,
  ...
}:
let
  zellij-switch-version = "0.2.1";

  zellij-sessioniser = pkgs.writeShellScriptBin "zellij-sessioniser" ''
    #!/usr/bin/env bash

    # Configuration - adjust these to your preferences
    SEARCH_PATHS=(${
      pkgs.lib.concatStringsSep " " [
        "$HOME/git"
        "$HOME/projects"
      ]
    })
    SPECIFIC_PATHS=(${
      pkgs.lib.concatStringsSep " " [
        "$HOME/.dotfiles"
        # "$HOME/.config/nvim"
      ]
    })

    # Path to the locally installed plugin
    ZELLIJ_SWITCH_PLUGIN="file:$HOME/.config/zellij/plugins/zellij-switch.wasm"

    # OS detection for stat command differences
    OS_TYPE="$(uname)"

    get_atime() {
      local dir="$1"
      if [[ "$OS_TYPE" == "Linux" ]]; then
        stat -c "%X" "$dir" 2>/dev/null || echo "0"
      else
        stat -f "%a" "$dir" 2>/dev/null || echo "0"
      fi
    }

    # Function to extract session name from display line
    extract_session_name() {
      local display_line="$1"
      local clean_path=$(echo "$display_line" | sed 's/ \x1b\[[0-9;]*m([^)]*)\x1b\[[0-9;]*m$//' | sed 's/ ([^)]*)$//')
      local full_path
      if [[ "$clean_path" == ~* ]]; then
        full_path="$HOME''${clean_path:1}"
      else
        full_path="$clean_path"
      fi
      basename "$full_path"
    }

    # Function to generate the display list
    generate_display_list() {
      local all_dirs=()
      
      # Add directories from SEARCH_PATHS
      for search_path in "''${SEARCH_PATHS[@]}"; do
        if [[ -d "$search_path" ]]; then
          for dir in "$search_path"/*; do
            if [[ -d "$dir" ]]; then
              all_dirs+=("$dir")
            fi
          done
        fi
      done
      
      # Add SPECIFIC_PATHS
      for specific_path in "''${SPECIFIC_PATHS[@]}"; do
        if [[ -d "$specific_path" ]]; then
          all_dirs+=("$specific_path")
        fi
      done
      
      # Sort directories by last access time
      local temp_file=$(mktemp)
      for dir in "''${all_dirs[@]}"; do
        local atime=$(get_atime "$dir")
        echo "$atime $dir" >> "$temp_file"
      done
      
      # Sort and extract directory names
      local sorted_dirs=()
      while IFS= read -r line; do
        local dir_name="''${line#* }"
        sorted_dirs+=("$dir_name")
      done < <(sort -nr "$temp_file")
      
      rm "$temp_file"
      
      # Get zellij session information
      declare -A session_status
      if command -v zellij >/dev/null 2>&1; then
        while IFS= read -r line; do
          if [[ -n "$line" ]]; then
            local session_name=$(echo "$line" | awk '{print $1}')
            
            if [[ "$line" == *"(current)"* ]]; then
              session_status["$session_name"]=" $(tput setaf 2)(current)$(tput sgr0)"
            elif [[ "$line" == *"(EXITED"* ]]; then
              session_status["$session_name"]=" $(tput setaf 1)(exited)$(tput sgr0)"
            else
              session_status["$session_name"]=" $(tput setaf 3)(active)$(tput sgr0)"
            fi
          fi
        done < <(zellij ls -n 2>/dev/null)
      fi
      
      # Create display names with session status
      for dir in "''${sorted_dirs[@]}"; do
        local display_name=$(echo "$dir" | sed "s|^$HOME|~|")
        local session_name=$(basename "$dir")
        
        if [[ -n "''${session_status[$session_name]}" ]]; then
          display_name="''${display_name}''${session_status[$session_name]}"
        fi
        
        echo "$display_name"
      done
    }

    # Handle --generate-list argument for reload functionality
    if [[ "$1" == "--generate-list" ]]; then
      generate_display_list
      exit 0
    fi

    # Create temporary script for session operations
    temp_script=$(mktemp)
    cat > "$temp_script" << 'INNEREOF'
    #!/usr/bin/env bash

    extract_session_name() {
      local display_line="$1"
      local clean_path=$(echo "$display_line" | sed 's/ \x1b\[[0-9;]*m([^)]*)\x1b\[[0-9;]*m$//' | sed 's/ ([^)]*)$//')
      local full_path
      if [[ "$clean_path" == ~* ]]; then
        full_path="$HOME''${clean_path:1}"
      else
        full_path="$clean_path"
      fi
      basename "$full_path"
    }

    if [[ "$1" == "delete" ]]; then
      session_name=$(extract_session_name "$2")
      if [[ -n "$session_name" ]]; then
        zellij delete-session "$session_name" --force 2>/dev/null
      fi
    fi

    if [[ "$1" == "kill" ]]; then
      session_name=$(extract_session_name "$2")
      if [[ -n "$session_name" ]]; then
        zellij kill-session "$session_name" 2>/dev/null
      fi
    fi
    INNEREOF

    chmod +x "$temp_script"

    # Use fzf with key bindings
    selected_display=$(generate_display_list | fzf --ansi \
      --height=~100% \
      --layout=reverse \
      --border=rounded \
      --prompt="Select project: " \
      --header="Enter: Select | Ctrl+D: Delete | Ctrl+K: Kill" \
      --bind="ctrl-d:execute($temp_script delete {})+reload($0 --generate-list)" \
      --bind="ctrl-k:execute($temp_script kill {})+reload($0 --generate-list)")

    rm -f "$temp_script"

    # Exit if nothing selected
    [[ -z "$selected_display" ]] && exit 0

    # Convert display name back to full path
    clean_display=$(echo "$selected_display" | sed 's/ \x1b\[[0-9;]*m([^)]*)\x1b\[[0-9;]*m$//' | sed 's/ ([^)]*)$//')

    if [[ "$clean_display" == ~* ]]; then
      selected_dir="$HOME''${clean_display:1}"
    else
      selected_dir="$clean_display"
    fi

    session_name=$(basename "$selected_dir")

    # Change to session
    if [[ -n "$ZELLIJ" ]]; then
      # Inside zellij - use the switch plugin
      zellij pipe --plugin "$ZELLIJ_SWITCH_PLUGIN" -- "--session $session_name --cwd $selected_dir"
    else
      # Outside zellij - attach or create
      cd "$selected_dir" 2>/dev/null
      zellij attach "$session_name" --create
    fi
  '';
in
{
  options = {
    cg.home.zellij.enable = lib.mkEnableOption "setting zellij hm settings";
  };

  config = lib.mkIf config.cg.home.zellij.enable {
    # Configure zellij
    xdg = {
      enable = true;
      configFile = {
        "zellij/config.kdl".text =
          builtins.replaceStrings [ "$XDG_CONFIG_HOME" ] [ config.xdg.configHome ]
            (builtins.readFile ./config.kdl);
        "zellij/layouts/default.kdl" = {
          source = ./default.kdl;
        };
        "zellij/plugins/zellij-switch.wasm" = {
          source = pkgs.fetchurl {
            url = "https://github.com/mostafaqanbaryan/zellij-switch/releases/download/${zellij-switch-version}/zellij-switch.wasm";
            hash = "sha256-7yV+Qf/rczN+0d6tMJlC0UZj0S2PWBcPDNq1BFsKIq4=";
          };
        };
      };
    };

    programs.bash = {
      enable = true;
      initExtra = ''
        # Ensure proper terminal state on shell startup
        if [[ -n "$ZELLIJ" ]]; then
          stty sane 2>/dev/null
        fi

        # Bind Ctrl-f to the sessionizer
        bind -x '"\C-f": "exec < /dev/tty; zellij-sessioniser"'
      '';
    };
    home.packages = with pkgs; [
      zellij
      zellij-sessioniser
    ];
  };
}
