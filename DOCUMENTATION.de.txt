AUDSVC.R4X
==========

AUDSVC.R4X ist der Audio- und Mixer-Service.

Projektstruktur seit 0.51.19:
- `build.zig` baut den Service als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports, Startdaten und Contract.

Build:

    cd Code\System\Services\AudioService
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Services\AudioService\zig-out\AUDSVC.R4X

Contract:
- R4XStart-Entry: `audsvc_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS`, `R4AUDIO`
- Service-Name: `AUDSVC`
- Standardargumente: `/RUN`
- Zielpfad im Image: `C:\R4OS\SERVICES\AUDSVC.R4X`

