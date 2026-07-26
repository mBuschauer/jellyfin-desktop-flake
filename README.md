# jellyfin-desktop-flake
A flake for the new [jellium-desktop](https://github.com/andrewrabert/jellium-desktop)

The flake.lock gets checked for updates once a week on Sundays or whenever I remember. 

To use, add the following as an input to `flake.nix`
```nix
    jellyfin-desktop.url = "github:mBuschauer/jellyfin-desktop-flake";
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

> [!NOTE]
> The upstream repo seems to change heavily and frequently, there was a recent massive rewrite into using xcargo which took me a while to figure out.
> I'll try to keep this updated in the meantime.
