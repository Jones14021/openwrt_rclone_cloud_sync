{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShellNoCC {
  packages = with pkgs; [
    git
    curl
    gnupg
    coreutils  # sha256sum, mktemp, od, tr, chmod, cp, mv
    unzip
    rclone     # host-native binary for interactive OneDrive setup
  ];
}
