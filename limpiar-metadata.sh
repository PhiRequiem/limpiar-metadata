#!/bin/bash
# limpiar-metadata.sh v0.2.0
# Elimina metadata de archivos usando mat2 + exiftool + qpdf
# https://github.com/TU_USUARIO/limpiar-metadata

set -o pipefail

VERSION="0.2.0"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

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
                local dims=$(exiftool -s -s -s -ImageSize "$file" 2>/dev/null)
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
                local magic=$(head -c 2 "$file" | xxd -p 2>/dev/null)
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
    echo "file_${hash}.${ext}"
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
            if mat2 --inplace "$output" 2>/dev/null && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                qpdf --linearize --replace-input "$output" 2>/dev/null || true
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1
                tool_used="qpdf+exiftool"
            fi
            ;;
        jpg|jpeg|png|tiff|tif|gif|webp|heic|heif)
            if mat2 --inplace "$output" 2>/dev/null && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1
                tool_used="exiftool"
            fi
            ;;
        mp4|mov|avi|mkv|m4v|webm)
            if mat2 --inplace "$output" 2>/dev/null && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1
                tool_used="exiftool"
            fi
            ;;
        docx|xlsx|pptx|odt|ods|odp)
            if mat2 --inplace "$output" 2>/dev/null && [ -s "$output" ]; then
                tool_used="mat2"
            else
                tool_used="mat2-failed"
            fi
            ;;
        mp3|flac|ogg|wav|m4a|opus)
            if mat2 --inplace "$output" 2>/dev/null && [ -s "$output" ]; then
                tool_used="mat2"
            else
                cp "$input" "$output"
                exiftool -all= -overwrite_original "$output" >/dev/null 2>&1
                tool_used="exiftool"
            fi
            ;;
        *)
            if mat2 --inplace "$output" 2>/dev/null && [ -s "$output" ]; then
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
        echo -e "${RED}✗ No existe:${NC} $input"
        return 1
    fi
    
    local base=$(basename "$input")
    local name="${base%.*}"
    local ext="${base##*.}"
    local ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    local safe_name=$(echo "$base" | tr ' /' '__')
    
    # Copiar a workdir
    local work_input="$WORKDIR/originals/$safe_name"
    cp "$input" "$work_input"
    
    # Metadata ANTES
    local before_json="$WORKDIR/reports/before_${safe_name}.json"
    extract_metadata "$work_input" "$before_json"
    
    # Header
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📄 $base${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local before_count=$(count_sensitive "$before_json")
    
    echo -e "${YELLOW}METADATA ENCONTRADA${NC} (antes):"
    show_metadata_section "$before_json"
    local has_meta=$?
    
    # Modo solo-ver
    if [ "$VIEW_ONLY" = "1" ]; then
        return 0
    fi
    
    # Determinar ruta de salida
    local output_dir=$(dirname "$input")
    local output_file
    
    if [ "$RENAME" = "1" ]; then
        local random_name
        random_name=$(generate_random_name "$input" "$ext")
        output_file="$output_dir/$random_name"
    elif [ "$INPLACE" = "1" ]; then
        output_file="$input"
    else
        output_file="$output_dir/${name}_limpio.${ext}"
    fi
    
    # Si no hay metadata sensible
    if [ "$has_meta" -ne 0 ]; then
        echo ""
        echo -e "${YELLOW}RESULTADO:${NC}"
        echo -e "  ${GREEN}✓ El archivo ya estaba limpio${NC}"
        if [ "$INPLACE" = "1" ]; then
            echo -e "  ${DIM}No se modificó (ya estaba limpio)${NC}"
        elif [ "$RENAME" = "1" ]; then
            cp "$input" "$output_file"
            echo -e "  ${DIM}Copia renombrada: $output_file${NC}"
        else
            cp "$input" "$output_file"
            echo -e "  ${DIM}Copia en: $output_file${NC}"
        fi
        return 0
    fi
    
    # Confirmación para --inplace (solo si hay metadata que limpiar)
    if [ "$INPLACE" = "1" ] && [ "$ASSUME_YES" != "1" ]; then
        echo ""
        if ! confirm "⚠  Sobreescribir el original?"; then
            echo -e "  ${YELLOW}Cancelado${NC}"
            return 0
        fi
    fi
    
    # Limpiar
    local work_clean="$WORKDIR/clean/$safe_name"
    local tool_used
    tool_used=$(clean_by_type "$work_input" "$work_clean" "$ext_lower")
    
    if [ "$tool_used" = "mat2-failed" ]; then
        echo ""
        echo -e "${RED}✗ mat2 falló con este formato y no hay fallback disponible${NC}"
        return 1
    fi
    
    # Validar archivo limpio
    local validation
    validation=$(validate_file "$work_clean" "$ext_lower")
    local valid_exit=$?
    
    if [ "$valid_exit" -ne 0 ]; then
        echo ""
        echo -e "${RED}✗ Validación falló: $validation${NC}"
        echo -e "${YELLOW}  El archivo limpio parece corrupto. No se escribirá.${NC}"
        echo -e "${DIM}  Original intacto: $input${NC}"
        return 1
    fi
    
    # Metadata DESPUÉS
    local after_json="$WORKDIR/reports/after_${safe_name}.json"
    extract_metadata "$work_clean" "$after_json"
    local after_count=$(count_sensitive "$after_json")
    local removed=$((before_count - after_count))
    
    # Escribir archivo final
    if [ "$INPLACE" = "1" ]; then
        # Sobreescribir solo tras validar
        cp "$work_clean" "$output_file"
    else
        cp "$work_clean" "$output_file"
    fi
    
    # Reporte
    echo ""
    echo -e "${YELLOW}RESULTADO:${NC}"
    if [ "$removed" -gt 0 ]; then
        echo -e "  ${GREEN}✓ $removed campos eliminados${NC}"
    fi
    echo -e "  ${GREEN}✓ Herramienta:${NC} $tool_used"
    echo -e "  ${GREEN}✓ Validación:${NC} $validation"
    
    if [ "$INPLACE" = "1" ]; then
        echo -e "  ${GREEN}✓ Archivo sobreescrito:${NC} $output_file"
    else
        echo -e "  ${GREEN}✓ Archivo limpio:${NC} $output_file"
    fi
    
    if [ "$RENAME" = "1" ] && [ "$INPLACE" != "1" ]; then
        echo -e "  ${DIM}Nombre original oculto${NC}"
    fi
    
    if [ "$after_count" -gt 0 ]; then
        echo -e "  ${YELLOW}⚠ Quedaron $after_count campos (revisa con --ver)${NC}"
    fi
}

show_help() {
    cat <<EOF
limpiar-metadata v$VERSION
Uso: $(basename "$0") [opciones] archivo1 [archivo2 ...]

Opciones:
  -i, --inplace    Sobreescribir el archivo original (pide confirmación)
  -y, --yes        Asumir sí en todas las confirmaciones (usar con --inplace)
  -r, --rename     Renombrar el archivo limpio con un hash aleatorio
  -v, --ver        Solo mostrar metadata, no limpiar
  -h, --help       Mostrar esta ayuda
      --version    Mostrar versión

Comportamiento por defecto:
  Crea <nombre>_limpio.<ext> junto al original sin modificar el original.

Formatos soportados:
  PDF, JPG, PNG, TIFF, GIF, WebP, HEIC, MP4, MOV, MKV, AVI,
  DOCX, XLSX, PPTX, ODT, ODS, ODP, MP3, FLAC, OGG, WAV

Ejemplos:
  limpiar-metadata foto.jpg
  limpiar-metadata --inplace *.pdf
  limpiar-metadata -iy *.jpg              # inplace sin confirmación
  limpiar-metadata --rename confidencial.pdf
  limpiar-metadata --ver documento.docx

EOF
}

# Parseo de argumentos
main() {
    VIEW_ONLY=0
    INPLACE=0
    ASSUME_YES=0
    RENAME=0
    local files=()
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --ver|-v)
                VIEW_ONLY=1
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
        echo -e "${YELLOW}⚠  --ver ignora --inplace y --rename${NC}"
    fi
    
    check_tools
    setup_workdir
    
    local total=${#files[@]}
    local failed=0
    
    for file in "${files[@]}"; do
        if ! process_file "$file"; then
            failed=$((failed + 1))
        fi
    done
    
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
