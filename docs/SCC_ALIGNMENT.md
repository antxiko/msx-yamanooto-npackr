# Por qué los juegos SCC en Yamanooto van alineados a 512KB

> _Why SCC games on the Yamanooto must be placed at 512KB-aligned positions._
>
> This document is the "open the hood" explainer for the most surprising
> packing constraint in the toolkit. Read it before reporting "SCC music
> doesn't play".

## 1. El truco de Konami con el SCC

Konami inventó un atajo elegante para sus juegos con chip SCC. Para activar
el SCC y a la vez saltar al banco de música, el código del juego escribe un
solo byte (`0x3F`) en el registro de banco del cartucho. **Una sola
instrucción hace dos cosas simultáneamente:**

- Activa el chip de sonido SCC
- Cambia el banco de la ROM al último (donde vive el driver de música)

¿Cómo? El hardware del cartucho Konami real **enmascara el valor del banco al
tamaño de la ROM**. Para un cart de 128KB (16 bancos), la máscara es `0x0F`:

```
0x3F & 0x0F = 0x0F = banco 15 (último banco = música)
```

Y como los 6 bits bajos del valor son todos 1 (`111111` = `0x3F`), el hardware
**también activa el chip SCC**. Dos pájaros de un tiro.

## 2. El Yamanooto no enmascara

El Yamanooto tiene **8 MB de flash** (o 2 MB en modelos antiguos) y puede
albergar muchos juegos. Por eso su registro de banco es más grande: en vez de
enmascarar al tamaño de un juego concreto, **acepta el valor literal y lo
suma a un offset** (registro `OFFR`, que indica dónde está cada juego dentro
del flash):

```
bankRegs[i] = (valor_que_escribe_el_juego + OFFR × 4) & 0x3FF
```

Las dos diferencias importantes:

- **No hay máscara automática** del tamaño del juego. El valor `0x3F` ya no
  se traduce mágicamente al "último banco".
- **OFFR está sumado**, así que dos juegos en posiciones distintas del flash
  interpretan los mismos bytes de manera diferente.

## 3. El bug de openMSX 21.0

En la versión actual de openMSX (la 21.0, abril 2026), la función que decide
si el chip SCC está activo mira el banco **después** de aplicar OFFR:

```cpp
// openMSX 21.0 — Yamanooto::isSCCAccess()
return ((bankRegs[2] & 0x3F) == 0x3F) && ...
//       ^^^^^^^^^^^
//       usa el banco con OFFR sumado
```

Esto está mal. El hardware real del Yamanooto mira el **valor crudo** que
escribió el juego (sin OFFR). La rama `master` de openMSX ya lo arregló:

```cpp
// openMSX master — fix posterior
return ((rawBanks[2] & 0x3F) == 0x3F) && ...
//       ^^^^^^^^^^
//       valor literal que escribió el juego
```

…pero **todavía no hay release** con la corrección. Mientras no salga
openMSX 22, tenemos que sortear el bug. Y la pregunta es: ¿cómo evitamos que
sumar OFFR rompa la detección de SCC?

## 4. Las matemáticas del alineamiento

Para que el chip SCC se siga activando cuando el juego escribe `0x3F`,
necesitamos que **el resultado tras sumar OFFR siga teniendo los 6 bits bajos
a `111111`**:

```
(0x3F + OFFR × 4) & 0x3F == 0x3F
```

Lo que reescribiendo da:

```
(OFFR × 4) mod 64 == 0
OFFR × 4 debe ser múltiplo de 64
OFFR debe ser múltiplo de 16
```

Como OFFR está en unidades de 32KB, **16 × 32KB = 512KB**.

## 5. Conclusión práctica

Los juegos SCC del Yamanooto **deben colocarse en posiciones de flash
múltiplo de 512KB** (OFFR = 0, 16, 32, 48, ..., 240). En el flash de 8MB
caben 16 de esos "slots"; como uno se queda para el launcher, hay **15 huecos
para juegos SCC**. En 2MB son 4 slots, 3 para juegos SCC.

Esto **solo es necesario por el bug de openMSX 21**. En hardware Yamanooto
real:

- El bug NO existe — el SCC se activa siempre que escribas `0x3F`, da igual
  el OFFR
- Pero alinear a 512KB **tampoco hace daño**, así que mantenemos el
  alineamiento por compatibilidad con el emulador hasta que salga openMSX 22

## 6. Cómo lo aprovecha el packager

El truco está en que dentro de cada slot de 512KB, **solo necesitamos un
banco extra de 8KB** (no los 512KB enteros):

- El juego (128KB típico) va al principio del slot
- Al final del slot, en la posición exacta donde `0x3F + OFFR × 4` aterriza,
  ponemos **una copia del último banco del juego** (8KB con el driver de
  música)
- Los ~376KB del medio **se reutilizan para meter otros juegos** (K4, plain)
  que no necesitan alineamiento

Por eso una colección de 14 SCC + 35 plain + 9 K4 = **59 juegos Konami en
5.3MB** del flash de 8MB.

## Referencias

- openMSX `src/memory/Yamanooto.cc`
  ([RELEASE_21_0](https://github.com/openMSX/openMSX/blob/RELEASE_21_0/src/memory/Yamanooto.cc) vs
  [master](https://github.com/openMSX/openMSX/blob/master/src/memory/Yamanooto.cc))
- [Yamanooto hardware reference (Genami)](https://genami.shop/blogs/news/programming-the-yamanooto)
- Konami SCC mapper: register `0x9000` controls segment 2; lower 6 bits =
  `0x3F` enables the SCC chip at `0x9800-0x9FFF`.
