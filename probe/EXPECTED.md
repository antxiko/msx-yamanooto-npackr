# K4 PROBE — tabla de esperados

Imagen: `k4probe_image.rom` (sonda A en OFFR=4, sonda B en OFFR=8 — verificado en la
salida del builder). Valores con **ECHO apagado** (arranque normal); con Echo Mode
activo suma 2 a los hex de CFGR y los tags marcados (†) suben 2 (P08→P0A).

Leyenda tags: `Pnn` = banco nn de la sonda A (flash 128-256KB) · `Qnn` = banco nn de
la sonda B (flash 256-384KB) · `FFFF` = flash sin firma (zona launcher/padding).

| Línea | openMSX (firmware viejo) | Ziggy previsto (si el modelo es correcto) |
|-------|--------------------------|-------------------------------------------|
| E0    | `80 04 01`               | `?? ?? 01` (readback real del core)        |
| E1    | `P00 P01 P02 P03`        | `P00 P01 P02 P03`                          |
| SW    | `0123456789ABCDEF`       | `0123456789ABCDEF`                         |
| 11A   | `P00 P01 P02 P03`        | **`Q00 Q01 Q02 Q03`** ← master en decode   |
| 11B   | `P00 P01 P02 P03`        | `P00 P01 P02 P03`                          |
| E2    | `P00 P08† P02 P03`       | `P00 P01 P02 P03` si CFGR es registro puro |
| E3    | `P00 P05 P06 P07`        | `P00 FFFF FFFF FFFF` si canónicas=raw (master=0 aquí) |
| E3B   | `P00 Q01 Q02 Q03`        | `P00 P01 P02 P03` si raw (0x11-13 = bancos abs 17-19) |
| E4    | `P00 P08 P09 P0A`        | ? (¿regs K5 vivos en K4?)                  |
| E5    | `P01 >P00 >P01`          | `P01 >P01 >P01` si ENAR no toca ventanas   |
| E6    | `P00 P01`                | ? (¿ventana 0 conmutable en K4?)           |
| E7    | `FFFF P04 P01`           | ? (¿OFFR de mapper hace algo en K4?)       |
| E7B   | `P00 Q08 P02 P03`        | sin movimiento si latch / todo Q si decode |
| E8    | `88 04 01`               | readback real                              |
| SX    | `P04 P05 P06 P07`        | `P04 P05 P06 P07`                          |
| S1B   | `P04 P05 P06 P07`        | **`Q04 Q05 Q06 Q07`** ← master en decode   |
| S2    | `P00 P01 P02 P03`        | `P00 P01 P02 P03`                          |
| S3    | `P00 P08† P02 P03`       | `P00 P01 P02 P03` si registro puro         |
| S4    | `P00 P00 P02 P03`        | `P00 P01 P02 P03` si registro puro         |
| S4B   | `P00 P01 P02 P03`        | **`P00 P01 P02 P03`** ← veredicto del fix  |

- **Gate en openMSX**: la columna openMSX debe clavarse línea a línea ANTES de
  flashear. Cualquier desviación = bug de la sonda, no del emulador.
- **En hardware**: S4B = `P00 P01 P02 P03` significa que el trampolín nuevo deja las
  4 ventanas exactamente como el juego las necesita → el fix es correcto.
- **Test de reset (E9)**: la sonda se queda en HALT con CFGR=K4, master/OFFR=4 y ENAR
  bloqueado (estado idéntico a un juego K4 recién lanzado). Pulsa RESET:
  - vuelve el **MENÚ** → el master se limpia en el reset (o FIX B lo limpia) ✓
  - vuelve la **SONDA** → el master sobrevive al reset (comportamiento "remember
    last game" del vendor; se vuelve al menú con power-cycle)
  - **NO DIRECTORY** → FIX B insuficiente, anotar E0/E8 reales.
