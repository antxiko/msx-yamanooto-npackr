# Compatibilidad Metal Gear 1 / 2 con el guardado a SRAM (nPackR)

_Generado automáticamente desde el triaje de los 90 volcados de Metal Gear de file-hunter (MSX2). Fecha del análisis: 2026-07-11._

Cada volcado se pasó por los parcheadores reales del proyecto (`packager/mg1_to_yamanooto.py` y `mg2_to_yamanooto.py`), que **verifican byte a byte** los puntos de enganche y **rechazan sin escribir** cualquier volcado que no encaje. Por eso esta lista es fiable: "compatible" = el parche se aplica sobre los puntos de guardado exactos que el driver espera.

> **Dos niveles de confianza:**
>
> - **✅ verificado en HW** — imagen flasheada y partida grabada/recargada en hardware real (Yamanooto). Certeza total.
> - **compatible (parche)** — el parche encaja byte a byte en los mismos puntos que los verificados; misma confianza técnica, aún sin probar juego a juego en HW.


## Metal Gear 1 — compatibles (6 volcados únicos)

MG1 solo es compatible con la **estirpe del build inglés** (`E85C5731`) y los hacks montados encima que no reescriben el código de guardado en cinta. El parche redirige los 20 `call` a la BIOS de cassette a un driver que guarda en flash.

| CRC32 | Tam | Versión |
|-------|-----|---------|
| `5F3BB2F1` | 128K | Metal Gear - Konami (1987) [English] [RC-750] [6873] |
| `851FE21A` | 128K | Metal Gear - Konami (1987) [JoySNES] [RC-750] [5309] |
| `E85C5731` | 128K | Metal Gear - Konami (1987) [Official English Translation] [RC-750] [Translated] [1474] |
| `63B1C2C9` | 128K | Metal Gear - Konami (1987) [Translated to Russian] [RC-750] [Translated] [5306] |
| `36386407` | 128K | Metal Gear - Konami (1987) [tr En] [RC-750] [Translated] [1471] |
| `AC4C7FE2` | 128K | Metal Gear - Konami (1987) [tr Sp] [RC-750] [Translated] [1475] **✅ verificado en HW** |

## Metal Gear 2 — compatibles (35 volcados únicos)

MG2 es **ampliamente compatible**: las traducciones y hacks tocan bancos de texto/gráficos y dejan intactos los dos puntos de enganche (`0x5DD4` detección GM2, `0x186D4` helper) y las direcciones de RAM del juego, que es justo lo que el driver de guardado necesita.

| CRC32 | Tam | Versión |
|-------|-----|---------|
| `A2945740` | 512K | Metal Gear 2 - Solid Snake (1990) Konami [Addendum - RC-767] [9696] |
| `8AF9001B` | 512K | Metal Gear 2 - Solid Snake (1990) Konami [English - RC-767] [Translated] [8698] |
| `C412559A` | 512K | Metal Gear 2 - Solid Snake (1990) Konami [English v1.4 + Turbo Fix v1.1 - RC-767] [Translated] [9141] |
| `6F23B91C` | 512K | Metal Gear 2 - Solid Snake (1990) Konami [FRS Turbo Fix v1.1 - Addendum - RC-767] [9694] |
| `9C422B83` | 512K | Metal Gear 2 - Solid Snake (1990) Konami [FRS Turbo Fix v1.1 - Portuguese - RC-767] [Translated] [9695] |
| `91F87685` | 512K | Metal Gear 2 - Solid Snake (1990) Konami [FRS Turbo Fix v1.1 - RC-767] [9693] |
| `52513D60` | 512K | Metal Gear 2 - Solid Snake (1990) Konami [Spanish - RC-767] [Translated] [9692] |
| `18B1F34B` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [(JP)] [RC-767] [GoodMSX] [1489] |
| `F5CABCB3` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Darky Version - No SCC - English] [RC-767] [Translated] [7781] |
| `DD42C9A4` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Darky Version - SCC- English] [RC-767] [Translated] [7782] |
| `5417C895` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Darky Version - SCC- English] [RC-767] [Translated] [7783] |
| `B134D721` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Darky version - No SCC] [RC-767] [7785] |
| `99BCA236` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Darky version - SCC] [RC-767] [7784] |
| `15AA5C3C` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [English - JoySNES] [RC-767] [Translated] [5311] |
| `2E3783AD` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [English v1.4 Slot Patch] [RC-767] [7207] |
| `09A5BBC6` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [English v1.4] [RC-767] [Translated] [3228] **✅ verificado en HW** |
| `0CE62224` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [English] Ulver full crack] [RC-767] [Translated] [1496] |
| `0FFE4568` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [English] [RC-767] [Translated] [1493] |
| `8857E5A1` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [English] [RC-767] [Translated] [1497] |
| `C249AB34` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [English] [RC-767] [Translated] [6474] |
| `5C4F98D9` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [English][a] [RC-767] [Translated] [1492] |
| `C3EE5CA1` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [FRS patch] [RC-767] [1503] |
| `D5061D17` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [FRS patch] [RC-767] [2646] |
| `7921F049` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [FRS patch] [RC-767] [Translated] [2645] |
| `A46F6A2C` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [No SCC [English] [RC-767] [Translated] [6996] |
| `2023178A` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [RC-767] [1490] |
| `51F5C5DF` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [RC-767] [1500] |
| `F7C4D1D8` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [RC-767] [1501] |
| `A33E6835` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [RC-767] [1502] |
| `9304267E` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [RC-767] [4131] |
| `B4961E15` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Retranslation by BifiMSX] [RC-767] [Translated] [1504] |
| `5101C2AD` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Russian] [RC-767] [Translated] [5312] |
| `18439758` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Spanish] [RC-767] [3371] **✅ verificado en HW** |
| `86DC03AC` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Wii Virtual Console Version (EN)] [RC-767][b] |
| `A02A1669` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [Wii Virtual Console Version (JP)] [RC-767] [2718] |

## Metal Gear 1 — NO compatibles (38)

Motivo dominante: **código de guardado en otra posición** (0/20 sitios) — cada uno sería un re-porte desde cero. Incluye los originales japoneses, franceses, "Modern/Literal English", Remix, varios JoySNES, y las versiones de disco/SCC/Turbo Fix (tamaño distinto de 128K).

| CRC32 | Tam | Versión | Motivo |
|-------|-----|---------|--------|
| `1F5803D5` | 128K | Metal Gear (1987) Konami [1.995 Remix + Nekura Hoka - RC-750] [Hack] [9703] | código de guardado desplazado |
| `8477C6F3` | 128K | Metal Gear (1987) Konami [English by Mr.Dude, TyrannoRanger v1.0 - RC-750] [Translated] [9702] | código de guardado desplazado |
| `BE84C94F` | 128K | Metal Gear - Konami (1987) [Does not work on Non Japanese systems] [RC-750] [1473] | código de guardado desplazado |
| `FAFE1303` | 128K | Metal Gear - Konami (1987) [Does not work on Non Japanese systems] [RC-750] [GoodMSX] [1472] | código de guardado desplazado |
| `AEBF76B3` | 128K | Metal Gear - Konami (1987) [French translation by Django] [RC-750] [Translated] [1477] | código de guardado desplazado |
| `BF83C0B6` | 128K | Metal Gear - Konami (1987) [French] [RC-750] [Translated] [6393] | código de guardado desplazado |
| `EAC5ACFF` | 128K | Metal Gear - Konami (1987) [French] [RC-750] [Translated] [6874] | código de guardado desplazado |
| `40F6641D` | 128K | Metal Gear - Konami (1987) [JoySNES Remix] [RC-750] [5308] | código de guardado desplazado |
| `5FBED802` | 128K | Metal Gear - Konami (1987) [JoySNES-a Remix] [RC-750] [5307] | código de guardado desplazado |
| `6EA53544` | 128K | Metal Gear - Konami (1987) [JoySNES-a] [RC-750] [5304] | código de guardado desplazado |
| `8201B1AB` | 128K | Metal Gear - Konami (1987) [JoySNES] [RC-750] [5305] | código de guardado desplazado |
| `C39E3AFA` | 128K | Metal Gear - Konami (1987) [Literal English] [RC-750] [Translated] [6876] | código de guardado desplazado |
| `C1D8DE94` | 128K | Metal Gear - Konami (1987) [Modern English] [RC-750] [Translated] [6875] | código de guardado desplazado |
| `85A204D8` | 128K | Metal Gear - Konami (1987) [Official English Version][JP-EU patch] [RC-750] [Translated] [1478] | código de guardado desplazado |
| `60E0FA79` | 128K | Metal Gear - Konami (1987) [RC-750] [1470] | código de guardado desplazado |
| `2E3676C6` | 128K | Metal Gear - Konami (1987) [RC-750] [1480] | código de guardado desplazado |
| `87E4E0B6` | 128K | Metal Gear - Konami (1987) [RC-750] [1481] | código de guardado desplazado |
| `1917B63D` | 128K | Metal Gear - Konami (1987) [RC-750] [1483] | código de guardado desplazado |
| `5D6D6C71` | 128K | Metal Gear - Konami (1987) [RC-750] [1484] | código de guardado desplazado |
| `9E08DA48` | 128K | Metal Gear - Konami (1987) [Remix 1.995] [RC-750] [6799] | código de guardado desplazado |
| `DC8DEE0D` | 128K | Metal Gear - Konami (1987) [Russian Translation by Andrew Shtein] [RC-750] [6765] | código de guardado desplazado |
| `F479935F` | 128K | Metal Gear - Konami (1987) [Wii VC Version] [RC-750] [6428] | código de guardado desplazado |
| `7023D840` | 136K | Metal Gear - Konami (1987) [English and Disk Save] [RC-750] [Translated] [4910] | tamaño ≠ 128K |
| `BC943C68` | 136K | Metal Gear - Konami (1987) [Remix 1.995 SCC Version] [RC-750] [6800] | tamaño ≠ 128K |
| `94DA82B3` | 136K | Metal Gear - Konami (1987) [TFH SCC version] [RC-750] [3643] | tamaño ≠ 128K |
| `0694B93D` | 160K | Metal Gear (1987) Konami [1.995 Remix + Nekura Hoka+Improvements v1.0 - RC-750] [9142] | tamaño ≠ 128K |
| `CA7F257D` | 160K | Metal Gear (1987) Konami [English by Mr. Dude, TyrannoRanger v1.0a - RC-750] [Translated] [9701] | tamaño ≠ 128K |
| `EE1050C5` | 160K | Metal Gear (1987) Konami [FRS Patched - RC-750] [8318] | tamaño ≠ 128K |
| `48DC524F` | 160K | Metal Gear (1987) Konami [FRS Patched - RC-750] [8319] | tamaño ≠ 128K |
| `1A0B2077` | 160K | Metal Gear (1987) Konami [FRS Patched+save on disk - English - RC-750] [Translated] [8317] | tamaño ≠ 128K |
| `B35ED410` | 160K | Metal Gear - Konami (1987) [Disk Save Option] [RC-750] [1479] | tamaño ≠ 128K |
| `87EC113E` | 160K | Metal Gear - Konami (1987) [English Version - Nekura_Hoka v.1.995c] [RC-750] [Translated] [7660] | tamaño ≠ 128K |
| `34D500A2` | 160K | Metal Gear - Konami (1987) [Turbo Fix V1] [RC-750] [2615] | tamaño ≠ 128K |
| `BCC722FD` | 160K | Metal Gear - Konami (1987) [Turbo Fix V2] [RC-750] [2614] | tamaño ≠ 128K |
| `7EBA6A51` | 160K | Metal Gear - Konami (1987) [Turbo Fix V2] [RC-750] [Translated] [2644] | tamaño ≠ 128K |
| `C44F4EFC` | 256K | Metal Gear (1987) Konami [Chinese - RC-750] [Translated] [9700] | tamaño ≠ 128K |
| `ED46831F` | 256K | Metal Gear - Konami (1987) [Wii VC Version [o] [RC-750] [2657] | tamaño ≠ 128K |
| `6BD4F6C0` | 8192K | Metal Gear - Konami (1987) [Repro cart] [RC-750] [4117] | tamaño ≠ 128K |

## Metal Gear 2 — NO compatibles (8)

| CRC32 | Tam | Versión | Motivo |
|-------|-----|---------|--------|
| `DCEE5080` | 128K | Metal Gear 2 - Solid Snake (Demo) - Konami (1990) [(JP)] [RC-767] [GoodMSX] [1505] | tamaño ≠ 512K (128K) |
| `4307CBD2` | 128K | Metal Gear 2 - Solid Snake (Demo) - Konami (1990) [Retranslation by BifiMSX] [RC-767] [Translated] [1507] | tamaño ≠ 512K (128K) |
| `2DFF3510` | 128K | Metal Gear 2 - Solid Snake (Demo) - Konami (1990) [tr En] [RC-767] [Translated] [1506] | tamaño ≠ 512K (128K) |
| `9EC6E5B2` | 524256B | Metal Gear 2 - Solid Snake (1990) Konami [Darky version - SCC - RC-767] [8513] | tamaño ≠ 512K (524256B) |
| `7D5117CC` | 512K | Metal Gear 2 - Solid Snake - Konami (1990) [RC-767] [1499] | helper `0x186D4` no coincide (build distinto) |
| `C3B9AF8A` | 1024K | Metal Gear 2 - Solid Snake (1990) Konami [Chinese - RC-767] [Translated] [9691] | tamaño ≠ 512K (1024K) |
| `5A1EB01A` | 1024K | Metal Gear 2 - Solid Snake (1990) Konami [FRS Turbo Fix v1.0 - Chinese - RC-767] [Translated] [9690] | tamaño ≠ 512K (1024K) |
| `81919A0D` | 8192K | Metal Gear 2 - Solid Snake - Konami (1990) [Repro cart] [RC-767] [4118] | tamaño ≠ 512K (8192K) |

---

### Cómo empaquetar una versión compatible

La GUI auto-parchea el volcado crudo al arrastrarlo. Por CLI:

```
python packager/mg2_to_yamanooto.py "MG2 Spanish.rom" mg2_patched.rom
# luego yamanooto_pack.py build con  mapper = "mg2"  (o "mg1")
```

_Resumen: MG1 6 compatibles / 38 no · MG2 35 compatibles / 8 no · 87 volcados únicos analizados._
