#!/bin/bash
# limpiar-metadata.sh v0.3.0
# Elimina metadata de archivos usando mat2 + exiftool + qpdf
# https://github.com/PhiRequiem/limpiar-metadata

set -o pipefail

VERSION="0.3.0"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

# Extensiones soportadas (usado al recorrer directorios)
SUPPORTED_EXTS="pdf jpg jpeg png tiff tif gif webp heic heif mp4 mov avi mkv m4v webm docx xlsx pptx odt ods odp mp3 flac ogg wav m4a opus"

# Imprime salida humana, salvo en modo --json (donde stdout es solo JSON)
say() {
    [ "${JSON_OUTPUT:-0}" = "1" ] && return 0
    echo -e "$@"
}

# Escapa una cadena para incrustarla en JSON (barra invertida, comillas y control)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Emite un objeto JSON con el resultado de un archivo (solo en modo --json)
# Args: file status message removed remaining tool output
json_result() {
    [ "${JSON_OUTPUT:-0}" = "1" ] || return 0
    printf '{"file":"%s","status":"%s","message":"%s","removed":%s,"remaining":%s,"tool":"%s","output":"%s"}\n' \
        "$(json_escape "$1")" "$2" "$(json_escape "$3")" "${4:-0}" "${5:-0}" \
        "$(json_escape "${6:-}")" "$(json_escape "${7:-}")"
}

# ¿La extensión del archivo está soportada? (para filtrar al recorrer directorios)
is_supported() {
    local e="${1##*.}"
    e=$(echo "$e" | tr '[:upper:]' '[:lower:]')
    local s
    for s in $SUPPORTED_EXTS; do
        [ "$e" = "$s" ] && return 0
    done
    return 1
}

# Expande directorios en sus archivos soportados (recursivo).
# Los archivos pasados explícitamente se conservan tal cual.
# Resultado en el array global EXPANDED_FILES.
expand_inputs() {
    EXPANDED_FILES=()
    local item f
    for item in "$@"; do
        if [ -d "$item" ]; then
            while IFS= read -r -d '' f; do
                is_supported "$f" && EXPANDED_FILES+=("$f")
            done < <(find "$item" -type f -print0)
        else
            EXPANDED_FILES+=("$item")
        fi
    done
}

# Verificar herramientas
check_tools() {
    local missing=()
    command -v mat2 >/dev/null 2>&1 || missing+=("mat2")
    command -v exiftool >/dev/null 2>&1 || missing+=("exiftool")
    command -v qpdf >/dev/null 2>&1 || missing+=("qpdf")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Faltan herramientas:${NC} ${missing[*]}"
        echo -e "${YELLOW}Instala con:${NC} brew install ${missing[*]}  (macOS)"
        echo -e "${YELLOW}           o:${NC} sudo apt install mat2 libimage-exiftool-perl qpdf python3  (Debian/Ubuntu)"
        exit 1
    fi
}

# Crear directorio de trabajo
setup_workdir() {
    WORKDIR="${TMPDIR:-/tmp}/meta_work_$$"
    mkdir -p "$WORKDIR/originals" "$WORKDIR/clean" "$WORKDIR/reports"
}

cleanup() {
    [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Extraer metadata a JSON
extract_metadata() {
    local file="$1"
    local out="$2"
    exiftool -j "$file" 2>/dev/null > "$out" || echo "[]" > "$out"
}

# Parsear metadata sensible
parse_sensitive() {
    local json_file="$1"
    python3 <<PYEOF
import json, sys

try:
    with open("$json_file") as f:
        data = json.load(f)
    if not data:
        sys.exit(0)
    meta = data[0]
except Exception:
    sys.exit(0)

sensitive = [
    "Author","Creator","LastModifiedBy","Manager","Company",
    "GPS","Location","City","Country","Province","State",
    "Software","Application","Producer","HostComputer",
    "SerialNumber","DeviceName","Make","Model","LensModel",
    "Comment","Description","Subject","Keywords","Title",
    "CreateDate","ModifyDate","MetadataDate","CreationDate",
    "IPTCDigest","DocumentID","InstanceID","OriginalDocumentID",
    "OwnerName","UserComment","XPAuthor","XPComment"
]

technical = {"SourceFile","ExifToolVersion","FileName","Directory","FileSize",
             "FileModifyDate","FileAccessDate","FileInodeChangeDate","FilePermissions",
             "FileType","FileTypeExtension","MIMEType","ExifByteOrder",
             "CurrentIPTCDigest","ImageWidth","ImageHeight","EncodingProcess",
             "BitsPerSample","ColorComponents","YCbCrSubSampling","ImageSize",
             "Megapixels","PDFVersion","Linearized","PageCount"}

found = []
for key, value in meta.items():
    if key in technical:
        continue
    if any(key == s or key.startswith(s) for s in sensitive):
        val_str = str(value)
        if len(val_str) > 60:
            val_str = val_str[:57] + "..."
        found.append((key, val_str))

for k, v in found:
    print(f"{k}|{v}")
PYEOF
}

show_metadata_section() {
    local json_file="$1"
    local output
    output=$(parse_sensitive "$json_file")
    
    if [ -z "$output" ]; then
        echo -e "  ${DIM}ℹ Sin metadata sensible detectada${NC}"
        return 1
    fi
    
    echo "$output" | while IFS='|' read -r key val; do
        printf "  ${YELLOW}%-18s${NC} → %s\n" "$key" "$val"
    done
    return 0
}

count_sensitive() {
    local json_file="$1"
    parse_sensitive "$json_file" | grep -c . || true
}

# Validar que el archivo limpio no está corrupto
validate_file() {
    local file="$1"
    local ext_lower="$2"
    
    # Verificar que existe y no está vacío
    if [ ! -s "$file" ]; then
        echo "vacío"
        return 1
    fi
    
    case "$ext_lower" in
        pdf)
            # qpdf --check valida estructura del PDF
            if qpdf --check "$file" >/dev/null 2>&1; then
                echo "ok"
                return 0
            else
                echo "PDF corrupto"
                return 1
            fi
            ;;
        jpg|jpeg|png|tiff|tif|gif|webp|heic|heif)
            # exiftool puede leer = archivo válido
            if exiftool "$file" >/dev/null 2>&1; then
                # Verificar también que tiene dimensiones
                local dims
                dims=$(exiftool -s -s -s -ImageSize "$file" 2>/dev/null)
                if [ -n "$dims" ]; then
                    echo "ok"
                    return 0
                fi
            fi
            echo "imagen corrupta"
            return 1
            ;;
        docx|xlsx|pptx|odt|ods|odp)
            # Son ZIPs, verificar integridad
            if command -v unzip >/dev/null 2>&1; then
                if unzip -t "$file" >/dev/null 2>&1; then
                    echo "ok"
                    return 0
                else
                    echo "ZIP corrupto"
                    return 1
                fi
            else
                # Sin unzip, fallback: solo verificar magic bytes
                local magic
                magic=$(head -c 2 "$file" | xxd -p 2>/dev/null)
                if [ "$magic" = "504b" ]; then
                    echo "ok"
                    return 0
                fi
                echo "no es ZIP válido"
                return 1
            fi
            ;;
        mp4|mov|avi|mkv|m4v|webm|mp3|flac|ogg|wav|m4a|opus)
            # Media: exiftool debería leerlo
            if exiftool "$file" >/dev/null 2>&1; then
                echo "ok"
                return 0
            fi
            echo "media corrupto"
            return 1
            ;;
        *)
            echo "ok"
            return 0
            ;;
    esac
}

# Generar nombre aleatorio basado en hash
generate_random_name() {
    local input="$1"
    local ext="$2"
    # Hash corto del archivo + timestamp para unicidad
    local hash
    if command -v shasum >/dev/null 2>&1; then
        hash=$(shasum -a 256 "$input" | cut -c1-12)
    elif command -v sha256sum >/dev/null 2>&1; then
        hash=$(sha256sum "$input" | cut -c1-12)
    else
        hash=$(date +%s%N | cut -c1-12)
    fi
    if [ -n "$ext" ]; then
        echo "file_${hash}.${ext}"
    else
        echo "file_${hash}"
    fi
}

# Limpiar según tipo
clean_by_type() {
    local input="$1"
    local output="$2"
    local ext_lower="$3"
    local tool_used=""
    
    cp "$input" "$output"
    
    case "$ext_lower" in
        pdf)
            if mat2 --inplace "$output" >/dev/null 2>&1 && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                qpdf --linearize --replace-input "$output" 2>/dev/null || true
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1
                tool_used="qpdf+exiftool"
            fi
            ;;
        jpg|jpeg|png|tiff|tif|gif|webp|heic|heif)
            if mat2 --inplace "$output" >/dev/null 2>&1 && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1
                tool_used="exiftool"
            fi
            ;;
        mp4|mov|avi|mkv|m4v|webm)
            if mat2 --inplace "$output" >/dev/null 2>&1 && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1
                tool_used="exiftool"
            fi
            ;;
        docx|xlsx|pptx|odt|ods|odp)
            if mat2 --inplace "$output" >/dev/null 2>&1 && [ -s "$output" ]; then
                tool_used="mat2"
            else
                tool_used="mat2-failed"
            fi
            ;;
        mp3|flac|ogg|wav|m4a|opus)
            if mat2 --inplace "$output" >/dev/null 2>&1 && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1
                tool_used="exiftool"
            fi
            ;;
        *)
            if mat2 --inplace "$output" >/dev/null 2>&1 && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1 || true
                tool_used="exiftool"
            fi
            ;;
    esac
    
    echo "$tool_used"
}

# Confirmar con el usuario (retorna 0 si sí, 1 si no)
confirm() {
    local prompt="$1"
    if [ "$ASSUME_YES" = "1" ]; then
        return 0
    fi
    read -r -p "$prompt [s/N]: " response
    case "$response" in
        [sSyY]|[sS][iIíÍ]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Procesar un archivo
process_file() {
    local input="$1"
    
    if [ ! -f "$input" ]; then
        say "${RED}✗ No existe:${NC} $input"
        json_result "$input" "error" "no existe" 0 0 "" ""
        return 1
    fi

    local base
    local name
    local ext
    local ext_lower
    local safe_name
    base=$(basename "$input")
    # Solo separar extensión si hay un punto que no sea el primer carácter
    # (evita nombres tipo "README" → "README_limpio.README" o ".bashrc" mal tratado)
    if [[ "$base" == ?*.* ]]; then
        name="${base%.*}"
        ext="${base##*.}"
    else
        name="$base"
        ext=""
    fi
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    safe_name=$(echo "$base" | tr ' /' '__')
    
    # Copiar a workdir
    local work_input="$WORKDIR/originals/$safe_name"
    cp "$input" "$work_input"
    
    # Metadata ANTES
    local before_json="$WORKDIR/reports/before_${safe_name}.json"
    extract_metadata "$work_input" "$before_json"
    
    # Header
    say ""
    say "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    say "${BLUE}📄 $base${NC}"
    say "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local before_count
    before_count=$(count_sensitive "$before_json")

    # has_meta=0 si hay metadata sensible (before_count > 0), 1 si no
    local has_meta=1
    [ "$before_count" -gt 0 ] && has_meta=0

    if [ "$JSON_OUTPUT" != "1" ]; then
        echo -e "${YELLOW}METADATA ENCONTRADA${NC} (antes):"
        show_metadata_section "$before_json"
    fi

    # Modo solo-ver
    if [ "$VIEW_ONLY" = "1" ]; then
        json_result "$input" "viewed" "solo inspección" 0 "$before_count" "" ""
        return 0
    fi
    
    # Determinar ruta de salida
    local output_dir
    local output_file
    output_dir=$(dirname "$input")
    
    if [ "$RENAME" = "1" ]; then
        local random_name
        random_name=$(generate_random_name "$input" "$ext")
        output_file="$output_dir/$random_name"
    elif [ "$INPLACE" = "1" ]; then
        output_file="$input"
    elif [ -n "$ext" ]; then
        output_file="$output_dir/${name}_limpio.${ext}"
    else
        output_file="$output_dir/${name}_limpio"
    fi
    
    # Si no hay metadata sensible
    if [ "$has_meta" -ne 0 ]; then
        say ""
        say "${YELLOW}RESULTADO:${NC}"
        say "  ${GREEN}✓ El archivo ya estaba limpio${NC}"
        local clean_out=""
        if [ "$INPLACE" = "1" ]; then
            say "  ${DIM}No se modificó (ya estaba limpio)${NC}"
        elif [ "$RENAME" = "1" ]; then
            cp "$input" "$output_file"
            clean_out="$output_file"
            say "  ${DIM}Copia renombrada: $output_file${NC}"
        else
            cp "$input" "$output_file"
            clean_out="$output_file"
            say "  ${DIM}Copia en: $output_file${NC}"
        fi
        json_result "$input" "clean" "ya estaba limpio" 0 0 "" "$clean_out"
        return 0
    fi

    # Confirmación para --inplace (solo si hay metadata que limpiar)
    if [ "$INPLACE" = "1" ] && [ "$ASSUME_YES" != "1" ]; then
        say ""
        if ! confirm "⚠  Sobreescribir el original?"; then
            say "  ${YELLOW}Cancelado${NC}"
            json_result "$input" "cancelled" "cancelado por el usuario" 0 "$before_count" "" ""
            return 0
        fi
    fi
    
    # Limpiar
    local work_clean="$WORKDIR/clean/$safe_name"
    local tool_used
    tool_used=$(clean_by_type "$work_input" "$work_clean" "$ext_lower")
    
    if [ "$tool_used" = "mat2-failed" ]; then
        say ""
        say "${RED}✗ mat2 falló con este formato y no hay fallback disponible${NC}"
        json_result "$input" "error" "mat2 falló sin fallback disponible" 0 "$before_count" "$tool_used" ""
        return 1
    fi

    # Validar archivo limpio
    local validation
    validation=$(validate_file "$work_clean" "$ext_lower")
    local valid_exit=$?

    if [ "$valid_exit" -ne 0 ]; then
        say ""
        say "${RED}✗ Validación falló: $validation${NC}"
        say "${YELLOW}  El archivo limpio parece corrupto. No se escribirá.${NC}"
        say "${DIM}  Original intacto: $input${NC}"
        json_result "$input" "error" "validación falló: $validation" 0 "$before_count" "$tool_used" ""
        return 1
    fi
    
    # Metadata DESPUÉS
    local after_json="$WORKDIR/reports/after_${safe_name}.json"
    extract_metadata "$work_clean" "$after_json"
    local after_count
    after_count=$(count_sensitive "$after_json")
    local removed=$((before_count - after_count))
    
    # Escribir archivo final
    if [ "$INPLACE" = "1" ]; then
        # Sobreescribir solo tras validar
        cp "$work_clean" "$output_file"
    else
        cp "$work_clean" "$output_file"
    fi
    
    # Reporte
    say ""
    say "${YELLOW}RESULTADO:${NC}"
    if [ "$removed" -gt 0 ]; then
        say "  ${GREEN}✓ $removed campos eliminados${NC}"
    fi
    say "  ${GREEN}✓ Herramienta:${NC} $tool_used"
    say "  ${GREEN}✓ Validación:${NC} $validation"

    if [ "$INPLACE" = "1" ]; then
        say "  ${GREEN}✓ Archivo sobreescrito:${NC} $output_file"
    else
        say "  ${GREEN}✓ Archivo limpio:${NC} $output_file"
    fi

    if [ "$RENAME" = "1" ] && [ "$INPLACE" != "1" ]; then
        say "  ${DIM}Nombre original oculto${NC}"
    fi

    if [ "$after_count" -gt 0 ]; then
        say "  ${YELLOW}⚠ Quedaron $after_count campos (revisa con --view)${NC}"
    fi

    json_result "$input" "ok" "limpiado" "$removed" "$after_count" "$tool_used" "$output_file"
    return 0
}

show_help() {
    cat <<EOF
limpiar-metadata v$VERSION
Uso: $(basename "$0") [opciones] archivo1 [archivo2 ...]

Opciones:
  -i, --inplace    Sobreescribir el archivo original (pide confirmación)
  -y, --yes        Asumir sí en todas las confirmaciones (usar con --inplace)
  -r, --rename     Renombrar el archivo limpio con un hash aleatorio
  -v, --view       Solo mostrar metadata, no limpiar
  -j, --json       Salida JSON en stdout (modo no interactivo; usar con -y)
  -h, --help       Mostrar esta ayuda
      --version    Mostrar versión

Comportamiento por defecto:
  Crea <nombre>_limpio.<ext> junto al original sin modificar el original.
  Si se pasa un directorio, se recorren recursivamente los archivos soportados.

Formatos soportados:
  PDF, JPG, PNG, TIFF, GIF, WebP, HEIC, MP4, MOV, MKV, AVI,
  DOCX, XLSX, PPTX, ODT, ODS, ODP, MP3, FLAC, OGG, WAV

Ejemplos:
  limpiar-metadata foto.jpg
  limpiar-metadata --inplace *.pdf
  limpiar-metadata -iy *.jpg              # inplace sin confirmación
  limpiar-metadata --rename confidencial.pdf
  limpiar-metadata --view documento.docx
  limpiar-metadata ./fotos/               # recorre el directorio
  limpiar-metadata --json -y *.pdf        # resultado en JSON

EOF
}

# Parseo de argumentos
main() {
    VIEW_ONLY=0
    INPLACE=0
    ASSUME_YES=0
    RENAME=0
    JSON_OUTPUT=0
    local files=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --view|--ver|-v)   # --ver se mantiene como alias por compatibilidad
                VIEW_ONLY=1
                shift
                ;;
            --json|-j)
                JSON_OUTPUT=1
                shift
                ;;
            --inplace|-i)
                INPLACE=1
                shift
                ;;
            --yes|-y)
                ASSUME_YES=1
                shift
                ;;
            --rename|-r)
                RENAME=1
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version)
                echo "limpiar-metadata v$VERSION"
                exit 0
                ;;
            # Flags combinados tipo -iy, -iyr
            -[a-z][a-z]*)
                local combined="${1#-}"
                local i
                for ((i=0; i<${#combined}; i++)); do
                    case "${combined:$i:1}" in
                        i) INPLACE=1 ;;
                        y) ASSUME_YES=1 ;;
                        r) RENAME=1 ;;
                        v) VIEW_ONLY=1 ;;
                        j) JSON_OUTPUT=1 ;;
                        h) show_help; exit 0 ;;
                        *) echo "Flag desconocido: -${combined:$i:1}"; exit 1 ;;
                    esac
                done
                shift
                ;;
            --)
                shift
                while [ $# -gt 0 ]; do files+=("$1"); shift; done
                ;;
            -*)
                echo "Opción desconocida: $1"
                echo "Usa --help para ver opciones disponibles"
                exit 1
                ;;
            *)
                files+=("$1")
                shift
                ;;
        esac
    done
    
    if [ ${#files[@]} -eq 0 ]; then
        show_help
        exit 1
    fi
    
    # Validar combinaciones
    if [ "$INPLACE" = "1" ] && [ "$RENAME" = "1" ]; then
        echo -e "${RED}✗ --inplace y --rename son incompatibles${NC}"
        echo "  --inplace sobreescribe el original (mismo nombre)"
        echo "  --rename genera un nombre nuevo"
        exit 1
    fi
    
    if [ "$VIEW_ONLY" = "1" ] && { [ "$INPLACE" = "1" ] || [ "$RENAME" = "1" ]; }; then
        say "${YELLOW}⚠  --view ignora --inplace y --rename${NC}"
    fi

    check_tools
    setup_workdir

    # Expandir directorios en sus archivos soportados
    expand_inputs "${files[@]}"
    files=("${EXPANDED_FILES[@]}")

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠ No se encontraron archivos soportados en la entrada${NC}" >&2
        exit 1
    fi

    local total=${#files[@]}
    local failed=0
    local json_results=()

    for file in "${files[@]}"; do
        if [ "$JSON_OUTPUT" = "1" ]; then
            local line rc
            line=$(process_file "$file")
            rc=$?
            [ -n "$line" ] && json_results+=("$line")
            [ "$rc" -ne 0 ] && failed=$((failed + 1))
        else
            if ! process_file "$file"; then
                failed=$((failed + 1))
            fi
        fi
    done

    if [ "$JSON_OUTPUT" = "1" ]; then
        local i
        printf '['
        for i in "${!json_results[@]}"; do
            [ "$i" -gt 0 ] && printf ','
            printf '%s' "${json_results[$i]}"
        done
        printf ']\n'
        [ "$failed" -eq 0 ] && exit 0
        [ "$failed" -eq "$total" ] && exit 1
        exit 2
    fi

    echo ""
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}✓ Terminado — $total archivo(s) procesado(s)${NC}"
        exit 0
    elif [ "$failed" -eq "$total" ]; then
        echo -e "${RED}✗ Todos los archivos fallaron ($failed/$total)${NC}"
        exit 1
    else
        echo -e "${YELLOW}⚠ Terminado con errores — $failed de $total fallaron${NC}"
        exit 2
    fi
}

main "$@"
