# Development handoff — estado tras la maratón 2026-07-04 → 2026-07-06

> Continuation notes. Snapshot: 2026-07-06, `main` en `1397c61` (9 commits de la
> maratón: d53722a, c71431b, 446ca09, 493374a, f226cb0, 2cd3eb2, 7c86f23,
> 976616f, a63a580, 1397c61). Gate forense VERDE en cada uno.
> Esta tarde: sesión de pruebas del usuario (lista al final).

## Qué hay hecho y verificado (por el usuario en openMSX salvo nota)

1. **SUBOFF / granularidad 8KB (d53722a + fix en 446ca09)** — juegos K4/plain
   ≤16KB comparten unidad de 32KB (2×16KB o 4×8KB) en AMBOS builders.
   Verificado con 24 Konami reales de 16KB (24 unidades → 12).
   ⚠ Lección grabada: openMSX (y seguramente el hardware) **latchea
   OFFR*4+SUBOFF al escribir cada registro de banco** — el trampolín escribe
   CFGR=SUBOFF|ECHO ANTES de los bank writes (STEP 1). Si se toca ese orden,
   los juegos sub-colocados arrancan el vecino del slot 0.
2. **Jingle de arranque opcional (c71431b)** — YMNTCFG!+12, TOML/CLI/GUI.
3. **Toggles runtime (446ca09; teclas remapeadas en v1.7.2)** — TAB = 50/60Hz
   (MSX2+, VDP R#9 bit1 + espejo RG9SAV), F1 = R800 DRAM (solo turbo R, CHGCPU
   0x82 antes del di; F1 se lee por SNSMAT con FNKSTR anulada).
   Detección por BIOS 0x002D en el arranque; estado en la fila 22.
   50/60 verificado (R9=2/0 según toggle); R800 verificado en emulador
   (FS-A1GT) — **pendiente hardware real** para veredicto final.
4. **Echo Mode preservado (446ca09)** — el trampolín ya no borra CFGR bit 1
   (PSG mirroring al minijack, tecla HOME). Solo se preserva, nunca se
   setea. *Sin verificar en emulador aún.*
5. **Tile de fondo animado (2cd3eb2 + 7c86f23)** — 8×8 horneado build-time
   (YMNTCFG!+13..20), 8 direcciones de scroll (+21), color (+22, 0=auto
   caja). Flush variable por fila (mdr_nt): el tile llena todo lo negro a la
   derecha de cada título. GUI: editor de píxeles con rejilla, dropdowns de
   dirección/color, preview animado en tiempo real. Verificado por el usuario.
6. **Metal Gear 1 salva a flash (976616f)** — cinta virtual sobre UN sector
   de 64KB (banco relativo 0x18), contrato por CARRY, 20 calls TAP*
   parcheados con validación byte a byte. **Verificado por el usuario**:
   grabar en ascensor con items → VERIFY OK → quit limpio → recargar → todo.
   ⚠ Semántica original del juego: la cinta guarda el ÚLTIMO CHECKPOINT
   (ascensores), no el instante del save — no es un bug (docs/MG1_SAVES.md).
   El dump local es una fan-translation (CRC 5F3BB2F1) con layout idéntico.
7. **GUI parchea los Metal Gear al vuelo (1397c61)** — arrastras el MG1
   (128KB) o MG2 (512KB) CRUDOS y la GUI los parchea (ports Rust con paridad
   byte a byte demostrada contra los scripts Python vía
   `cargo run --example mg_parity`). También acepta dumps ya parcheados
   (detección por firma). *Pipeline GUI→imagen→save aún sin verificar en
   emulador (pendiente de esta tarde).*
8. **SCC sin desperdicio + modo secuencial (1397c61)** — veredicto de la
   investigación: **el alineamiento 512KB NO es del hardware, es solo del
   bug de openMSX 21.0** (fix rawBanks solo en master; última release
   21.0 = sep 2025). Implementado:
   - Las unidades-mirror donan sus 24KB libres a juegos ≤16KB (~336KB
     recuperados con la colección completa). Automático en ambos modos.
   - `--no-scc-align` / `[launcher].scc_align` / checkbox GUI (default ON):
     OFF = empaquetado 100% secuencial — correcto en hardware real y openMSX
     master; **la música SCC calla en openMSX 21.0** (documentado). Invertir
     el default cuando salga la próxima release de openMSX.
   - Detalles y fuentes en docs/SCC_ALIGNMENT.md (fecha 21.0 corregida).
9. **Botón Build ROM** arriba a la derecha, doble tamaño (petición usuario).

## Build & recipe (referencia)

pasmo 0.5.4.beta2 · python 3.13 · cargo · openMSX 21.0. Tamaños de referencia:
launcher.bin **6077** (¡crece con cada feature — el gate usa rango!),
mg1_engine 144, mg1_driver 8192, mg1_shim 56, mg2_engine 181, mg2_driver 8192,
gm2_part1 26, gm2_part2 274, sram_engine_gm2 530.
SIEMPRE: size-check tras pasmo (ds negativo → bin vacío exit 0) y resync
gui-rs/data/launcher.bin (el gate lo fuerza). Gate: `.forja/gate.json` +
`.forja/asm_check.py` (gitignorados; recrear de esta lista si se pierden:
pasmo×9 con tamaños, launcher-bin-sync, py-compile×9, pack-selftest,
cargo build+test con is_test).

### openMSX en esta máquina (aprendido a golpes)
- **El usuario prueba; el asistente SOLO lanza** (sin -script, sin teclas,
  sin capturas, sin matar instancias ajenas). Regla dura.
- openmsx muere mudo exit 1 → `SDL_AUDIODRIVER=dummy` (audio del sistema
  caído). No experimentar con otros drivers.
- `Panasonic_FS-A1ST` no arranca en esta instalación → usar **FS-A1GT**.
- Los dummies de test_image hacen DI/HALT a propósito: congelarse = éxito.

## Pruebas de ESTA TARDE (pendientes del usuario)

1. **Pipeline GUI completo con Metal Gears**: arrastrar MG1+MG2 crudos +
   colección, Build ROM, y en openMSX: grabar partida MG1 (ascensor) y MG2
   → quit limpio → recargar → cargar. (El asistente lanza; el usuario prueba.)
2. **Música SCC con la imagen default (alineada)**: Salamander/Gradius 2
   suenan + juegos de 16KB viviendo en unidades-mirror funcionan.
3. (Opcional) Imagen `--no-scc-align` en openMSX master o hardware real.
4. (Cuando haya cartucho a mano) R800 en turbo R real + el caso SCC/0x3F
   sin alinear en hardware — las dos incógnitas abiertas.

## Siguientes (sin fecha)

- Migrar GM2 al modelo per-game 64KB RMW; ASCII8-SRAM (Xanadu) /
  ASCII16-SRAM2 (Hydlide).
- Verificar ECHO preserve en emulador; test MG2 3 slots sin contaminación.
- Invertir default de scc_align cuando salga openMSX > 21.0.
- Release (tag `v*` — es lo ÚNICO que dispara el workflow de release).
- Actualizar README (features nuevas: toggles, tile, MG1, scc_align, MG en GUI).

## Gotchas vigentes (los que muerden)

- SUBOFF debe estar en CFGR ANTES de los bank writes (trampolín STEP 1).
- El mirror SCC vive en el banco 3 de la unidad OFFR+15 — el packer lo
  siembra en `subunits`; no tocar sin actualizar los selftests gemelos.
- Dos copias de launcher.bin (launcher/ y gui-rs/data/) + tres .bin de MG1
  y uno de MG2 embebidos por include_bytes! en la GUI → recompilar gui-rs
  tras tocar cualquier .asm.
- La colocación física NO sigue el orden del menú (alfabético) ni el de
  entrada (por tamaño y pasadas). No inferir posiciones sin el selftest.
- mg1/mg2 en la GUI validan la firma del dump antes de parchear — un dump
  distinto se rechaza en rojo, nunca se parchea a ciegas.
