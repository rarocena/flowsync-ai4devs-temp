#!/usr/bin/env bash
# PostToolUse (Write|Edit): AVISA, sin bloquear nunca, cuando una escritura en
# `frontend/src/` introduce un color escrito a pelo en vez de un token:
#   - hexadecimales (#fff, #1d4ed8, también dentro de `bg-[#1d4ed8]`)
#   - funciones de color: rgb(), rgba(), hsl(), hsla(), oklch(), oklab(),
#     lab(), lch(), hwb()
#   - clases de paleta cruda de Tailwind (bg-blue-600, text-white,
#     border-zinc-200/50…)
# `frontend/src/index.css` queda fuera: es la capa donde el valor literal sí se
# escribe, la que da nombre a cada color.
#
# Solo cuenta lo que trae ESTA operación, no lo que ya estaba en el archivo:
#   - Edit: los colores de `new_string` que no estaban ya en `old_string`.
#   - Write: los del contenido escrito que no estaban en `originalFile`, que
#     Claude Code manda en la respuesta (vale `null` si el archivo es nuevo).
# Se compara por valor, no por posición: tocar una línea que ya tenía un color
# no avisa, y añadir una segunda vez un color que ya salía en el trozo
# reemplazado tampoco.
#
# ESTO ES UN AVISO, NO UN CANDADO. Lo que NO ve:
#   - Lo que no pasa por Write o Edit: `npx shadcn add`, `sed`, un heredoc o
#     cualquier otra cosa por Bash, o una edición a mano fuera de Claude.
#   - Colores con nombre (`red`, `transparent`, `currentColor`), los que se
#     arman en tiempo de ejecución (`` `#${hex}` ``, `rgb(${r}…`) y los que
#     llegan por una variable o por una prop `style` calculada.
#   - Si la pieza tenía que haber salido del catálogo: eso es la regla de
#     `CLAUDE.md`, no algo que un script pueda comprobar.
# Y puede avisar de más: un ancla `#add` o una referencia `#123` en un
# comentario tienen forma de hexadecimal.
set -uo pipefail

entrada=$(cat)

archivo=$(printf '%s' "$entrada" | jq -r '.tool_response.filePath // .tool_input.file_path // empty' 2>/dev/null)
[ -n "$archivo" ] || exit 0

raiz="${CLAUDE_PROJECT_DIR:-$(pwd)}"
case "$archivo" in
  /*) ;;
  *) archivo="$raiz/$archivo" ;;
esac
case "$archivo" in
  "$raiz"/frontend/src/index.css) exit 0 ;;
  "$raiz"/frontend/src/*) ;;
  *) exit 0 ;;
esac

# Lo que entra y lo que había. `edits[]` es por si llega una edición múltiple.
nuevo=$(printf '%s' "$entrada" | jq -r '
  if .tool_input.edits then [.tool_input.edits[].new_string] | join("\n")
  elif .tool_input.new_string != null then .tool_input.new_string
  else .tool_input.content // "" end' 2>/dev/null)
previo=$(printf '%s' "$entrada" | jq -r '
  if .tool_input.edits then [.tool_input.edits[].old_string] | join("\n")
  elif .tool_input.old_string != null then .tool_input.old_string
  else .tool_response.originalFile // "" end' 2>/dev/null)

paleta='red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|slate|gray|zinc|neutral|stone'
utilidad='bg|text|border(-[xytrblse])?|ring(-offset)?|outline|fill|stroke|from|via|to|shadow|inset-shadow|inset-ring|drop-shadow|text-shadow|divide|decoration|placeholder|caret|accent'

# Los colores literales de un texto, uno por línea, en minúsculas y con los
# espacios normalizados, para poder comparar dos textos por valor. Primero se trocea por
# palabras y después se exige la forma exacta a cada trozo: así `foo#abc` o
# `&#123;` no cuentan como hexadecimal, y dos colores pegados (`#fff,#000`)
# salen los dos.
colores() {
  local texto
  texto=$(cat)
  {
    printf '%s\n' "$texto" | grep -oE '[[:alnum:]_&-]*#[[:alnum:]_-]*' \
      | grep -E '^#([[:xdigit:]]{3,4}|[[:xdigit:]]{6}|[[:xdigit:]]{8})$'
    printf '%s\n' "$texto" | grep -oE '[[:alnum:]_.$-]*\([^)]*\)?' \
      | grep -E '^(rgba?|hsla?|oklch|oklab|lab|lch|hwb)\('
    printf '%s\n' "$texto" | grep -oE '[[:alnum:]_-]+' \
      | grep -E "^(${utilidad})-(white|black|(${paleta})-(50|[1-9]00|950))$"
  } | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[[:space:]]+/ /g; s/ ?([(),/]) ?/\1/g' | sort -u
}

introducidos=$(comm -23 <(printf '%s' "$nuevo" | colores) <(printf '%s' "$previo" | colores))
[ -n "$introducidos" ] || exit 0

relativo="${archivo#"$raiz"/}"
lista=$(printf '%s\n' "$introducidos" | awk 'NR > 1 { printf ", " } { printf "`%s`", $0 }')
mensaje="Aviso de aviso-colores-a-pelo.sh (no bloquea): ${relativo} introduce colores escritos a pelo: ${lista}. En frontend/src/ los colores salen de los tokens de frontend/src/index.css, por sus utilidades (bg-primary, text-muted-foreground, border-border, bg-destructive…). Si ningún token encaja, dilo en vez de escribir el valor: un color nuevo es un token nuevo, y esa decisión no se toma de pasada."

jq -n --arg m "$mensaje" '{
  systemMessage: $m,
  hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $m }
}' 2>/dev/null || printf '%s\n' "$mensaje"

exit 0
