{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShellNoCC {
  packages = with pkgs; [
    git
    curl
    gnupg
    coreutils  # sha256sum, mktemp, od, tr, chmod, cp, mv
    unzip
    rclone     # host-native binary for interactive OneDrive setup
    busybox    # exercise scripts with the router's BusyBox-style utilities
    curl       # dashboard HTTP smoke tests
    jq         # inspect CGI JSON responses in host tests
    nodejs     # JavaScript syntax checks
    openssl    # generate a local certificate for HTTPS smoke tests
    shellcheck # shell linting
    uhttpd     # run the dashboard locally
  ];
}
