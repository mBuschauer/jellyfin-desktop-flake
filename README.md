# jellyfin-desktop-flake
A flake for the new [jellium-desktop](https://github.com/andrewrabert/jellium-desktop)

The flake.lock gets checked for updates once a week on Sundays or whenever I remember. 

To use, add the following as an input to `flake.nix`
```nix
    jellium-desktop.url = "github:mBuschauer/jellyfin-desktop-flake";
```
Install jellyfin-desktop with
```nix
{ inputs, ... }:
{
    environment.systemPackages = [
        inputs.jellium-desktop.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
}
```
