![ShellCheck](https://github.com/PhiRequiem/limpiar-metadata/actions/workflows/shellcheck.yml/badge.svg)

# limpiar-metadata

Script en Bash para eliminar metadata sensible de archivos desde la terminal en macOS y Linux. Pensado para periodistas, personas defensoras, activistas y cualquiera que necesite anonimizar archivos antes de compartirlos.

Orquesta tres herramientas conocidas (`mat2`, `exiftool`, `qpdf`) con fallbacks automáticos según el tipo de archivo, valida que el archivo limpio no quede corrupto, y muestra un reporte claro de qué se encontró y qué se eliminó.

## ¿Por qué?

La metadata de un archivo puede filtrar más información de la que parece: nombre del autor, organización, ubicación GPS de una foto, modelo de cámara o celular, software usado, fechas de creación y modificación, historial de ediciones. Para quien trabaja en contextos de riesgo, eso puede significar identificar una fuente, ubicar un lugar seguro o confirmar la autoría de un documento.

Existen herramientas excelentes para limpiar metadata (`mat2` es la referencia), pero cada una tiene huecos en ciertos formatos. Este script las combina, valida el resultado y te entrega un reporte legible.

## Características

- Limpia PDF, imágenes (JPG, PNG, TIFF, WebP, GIF, HEIC), videos (MP4, MOV, MKV, AVI), documentos Office (DOCX, XLSX, PPTX), ODF (ODT, ODS, ODP) y audio (MP3, FLAC, OGG, WAV)
- Reporte antes/después destacando solo campos sensibles (oculta los técnicos como tamaño, tipo MIME, etc.)
- Fallback automático: si `mat2` falla, cae a `qpdf`+`exiftool` o solo `exiftool`
- **Validación post-limpieza:** verifica que el archivo no quedó corrupto antes de escribirlo
- **Modo `--inplace`:** sobreescribe el original (con confirmación)
- **Modo `--rename`:** renombra el archivo limpio con un hash aleatorio para ocultar el nombre
- Modo `--ver` para solo inspeccionar metadata sin limpiar
- Trabaja sobre copias en directorio temporal y limpia al salir
- Procesa múltiples archivos en una sola llamada
- Códigos de salida útiles para scripts: 0 = éxito, 1 = falla total, 2 = parcial

## Requisitos

- macOS o Linux
- `bash`
- `python3` (viene por defecto en macOS moderno y la mayoría de distros Linux)
- `mat2`, `exiftool`, `qpdf`
- `unzip` (opcional, para validación de DOCX/XLSX/PPTX)

## Instalación

### macOS (Homebrew)

```bash
brew install mat2 exiftool qpdf
```

### Debian / Ubuntu

```bash
sudo apt install mat2 libimage-exiftool-perl qpdf python3
```

### Fedora

```bash
sudo dnf install mat2 perl-Image-ExifTool qpdf python3
```

### Descargar el script

```bash
mkdir -p ~/bin
curl -o ~/bin/limpiar-metadata.sh https://raw.githubusercontent.com/PhiRequiem/limpiar-metadata/main/limpiar-metadata.sh
chmod +x ~/bin/limpiar-metadata.sh
```

### Agregar al PATH

Si `~/bin` no está en tu PATH, agrégalo a tu shell. Para zsh (macOS por defecto):

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Para bash:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Alias opcional

```bash
echo 'alias limpiar="limpiar-metadata.sh"' >> ~/.zshrc
source ~/.zshrc
```

## Uso

```bash
# Uso básico — crea archivo_limpio.ext junto al original
limpiar-metadata.sh foto.jpg

# Varios archivos
limpiar-metadata.sh doc.pdf foto.jpg video.mp4

# Con glob
limpiar-metadata.sh *.pdf

# Sobreescribir el original (pide confirmación)
limpiar-metadata.sh --inplace foto.jpg

# Sobreescribir sin preguntar (para scripts)
limpiar-metadata.sh -iy *.jpg

# Renombrar con hash aleatorio (oculta el nombre original)
limpiar-metadata.sh --rename confidencial.pdf

# Solo ver metadata sin limpiar
limpiar-metadata.sh --ver reporte.pdf

# Ayuda
limpiar-metadata.sh --help
```

## Opciones

| Flag              | Descripción                                               |
|-------------------|-----------------------------------------------------------|
| `-i, --inplace`   | Sobreescribe el archivo original (pide confirmación)      |
| `-y, --yes`       | Asume sí en confirmaciones (usar con `--inplace`)         |
| `-r, --rename`    | Renombra el limpio con un hash aleatorio                  |
| `-v, --ver`       | Solo mostrar metadata, no limpiar                         |
| `-h, --help`      | Ayuda                                                     |
| `--version`       | Versión actual                                            |

Los flags cortos son combinables: `-iy`, `-iyr`, etc.

## Ejemplo de salida

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📄 informe.pdf
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
METADATA ENCONTRADA (antes):
  Author             → Juan García
  Creator            → Microsoft Word 2019
  Company            → Organización XYZ
  CreateDate         → 2024:03:15 10:22:31
  ModifyDate         → 2024:11:02 18:45:10
  Producer           → Adobe PDF Library

RESULTADO:
  ✓ 6 campos eliminados
  ✓ Herramienta: mat2
  ✓ Validación: ok
  ✓ Archivo limpio: /Users/tu/Desktop/informe_limpio.pdf
```

## Estrategia por tipo de archivo

| Tipo                     | Primario | Fallback                         | Validación            |
|--------------------------|----------|----------------------------------|-----------------------|
| PDF                      | `mat2`   | `qpdf --linearize` + `exiftool`  | `qpdf --check`        |
| Imágenes                 | `mat2`   | `exiftool -all=`                 | `exiftool` + dims     |
| Videos                   | `mat2`   | `exiftool -all=`                 | `exiftool` lee        |
| Office (DOCX/XLSX/PPTX)  | `mat2`   | ninguno (aviso)                  | `unzip -t`            |
| ODF (ODT/ODS/ODP)        | `mat2`   | ninguno (aviso)                  | `unzip -t`            |
| Audio                    | `mat2`   | `exiftool -all=`                 | `exiftool` lee        |

Si la validación falla, el archivo limpio **no** se escribe y el original queda intacto.

## Advertencias

- **PDFs firmados digitalmente:** limpiar metadata rompe la firma. Es el comportamiento esperado.
- **Documentos con macros:** `mat2` los elimina (suele ser lo que quieres).
- **Nombre del archivo:** con `--rename` el script oculta el nombre original usando un hash. Sin ese flag, el nombre se mantiene.
- **Formularios PDF interactivos:** `mat2` puede romperlos. La validación lo detectará y no escribirá el archivo.
- **Videos grandes:** pueden tardar, especialmente con `mat2`.
- **Modo `--inplace`:** aunque pide confirmación, una vez sobreescrito no hay vuelta atrás. El script valida antes de sobreescribir, pero haz copias de seguridad si los archivos son importantes.
- **Esto no te hace anónimo por sí solo.** Limpiar metadata es una capa. Considera también el canal por el que compartes, si capturaste la imagen/video en un lugar identificable, si el contenido mismo revela información, etc.

## Códigos de salida

- `0` — Todos los archivos procesados sin error
- `1` — Todos los archivos fallaron (o error de configuración)
- `2` — Algunos archivos fallaron, otros tuvieron éxito

Útiles para encadenar en scripts:

```bash
limpiar-metadata.sh *.pdf && echo "Todo OK, ahora a subirlos"
```

## Desinstalar

```bash
rm ~/bin/limpiar-metadata.sh
# Edita ~/.zshrc y quita la línea del PATH y del alias si los agregaste
```

## Roadmap — mejoras planeadas

Las siguientes están en la lista para próximas versiones. Si alguna te urge, abre un issue o un PR:

- **Procesamiento recursivo de carpetas** (`-R`/`--recursive`). Hoy hay que usar globs y no maneja subcarpetas.
- **Modo silencioso** (`-q`/`--quiet`). Para usar en pipelines de CI o workflows de publicación sin llenar la terminal.
- **Salida JSON estructurada** (`--json`). Para integrar con otras herramientas o generar logs auditables.
- **Dry-run** (`--dry-run`). Mostrar qué haría el script sin tocar archivos, útil antes de correr sobre un lote grande.
- **Soporte para stdin** (`--stdin`). Leer lista de archivos desde stdin para combinar con `find`, `fd`, `fzf`:

  ```bash
  find . -name '*.jpg' | limpiar-metadata --stdin
  ```

- **Log opcional** (`--log archivo.txt`). Guardar el reporte completo en un archivo para trabajo de auditoría donde necesitas evidencia.
- **Reporte más granular de fallas parciales.** Distinguir mejor entre limpieza total, parcial y fallida en el reporte por archivo.

## Changelog

### v0.2.1 — 2026-04-21

- Fix: corregidos 8 warnings SC2155 detectados por shellcheck (declaración y asignación de variables locales en líneas separadas). Sin cambios funcionales.

### v0.2.0 — 2026-04-21

**Nuevas opciones:**
- `--inplace` / `-i`: sobreescribe el archivo original tras pedir confirmación
- `--yes` / `-y`: asume sí en todas las confirmaciones, para uso no-interactivo
- `--rename` / `-r`: renombra el archivo limpio con un hash aleatorio para ocultar el nombre
- Flags cortos combinables (ej. `-iy`, `-iyr`)

**Seguridad del proceso:**
- Validación post-limpieza antes de escribir el archivo final. Si el archivo limpio está corrupto (PDF mal formado, ZIP dañado, imagen sin dimensiones, etc.), no se escribe y el original queda intacto.
- Validación específica por tipo: `qpdf --check` para PDF, `unzip -t` para Office/ODF, `exiftool` + verificación de dimensiones para imágenes.

**Mejoras:**
- Códigos de salida útiles para scripts (0/1/2)
- Mensaje de ayuda más claro con ejemplos
- Detección temprana de combinaciones inválidas (`--inplace` + `--rename`)
- Mejor reporte de totales al final (éxitos / fallos / total)

### v0.1.0 — 2023-05-30

- Versión inicial
- Soporte para PDF, imágenes, videos, Office, ODF y audio
- Reporte antes/después con filtro de campos sensibles
- Modo `--ver` para solo inspeccionar
- Fallbacks automáticos por tipo de archivo
- Directorio de trabajo temporal con limpieza automática

## Licencia

MIT

## Créditos

Construido sobre el trabajo de:
- [mat2](https://0xacab.org/jvoisin/mat2) — Metadata Anonymisation Toolkit
- [ExifTool](https://exiftool.org/) — Phil Harvey
- [qpdf](https://qpdf.sourceforge.io/) — Jay Berkenbilt

Desarrollado como herramienta de apoyo para el trabajo de [seguridades.org](https://seguridades.org) con personas defensoras, periodistas y sociedad civil en América Latina.
