suno() {
  local api="https://sunodownload.io"
  local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
  local format="wav" outdir="$HOME/Music/AlgoRytmy/DOWNLOADS" name="" url=""
  local maxtries=3

  # kolory (tylko jak stdout to terminal)
  local R='' C='' O='' G='' GR='' RED='' GRN=''
  if [[ -t 1 ]]; then
    R=$'\e[0m' C=$'\e[36m' O=$'\e[38;5;208m' G=$'\e[32m'
    GR=$'\e[90m' RED=$'\e[1;31m' GRN=$'\e[1;32m'
  fi
  # header: symbole # = [ ] szare, słowo w środku kolorowe
  _suno_bar() { printf '%s# ========= [ %s%s%s ] =========%s\n' "$GR" "$2" "$1" "$GR" "$R"; }

  while (( $# )); do
    case "$1" in
      -f|--format) format="$2"; shift 2 ;;
      -o|--output) outdir="$2"; shift 2 ;;
      -n|--name)   name="$2";   shift 2 ;;
      -h|--help)
        echo "usage: suno [suno-url] [-f mp3|wav|mp4|m4a] [-o dir] [-n name]"
        echo "  brak url -> bierze z wl-paste; domyślnie -> $HOME/Music/AlgoRytmy/DOWNLOADS"
        return 0 ;;
      -*) echo "suno: unknown flag $1" >&2; return 1 ;;
      *)  url="$1"; shift ;;
    esac
  done

  # 0. brak url -> clipboard
  if [[ -z "$url" ]]; then
    command -v wl-paste >/dev/null || { echo "suno: brak url i brak wl-paste" >&2; return 1; }
    url="$(wl-paste -n)"
    [[ -z "$url" ]] && { echo "suno: clipboard pusty" >&2; return 1; }
  fi
  [[ "$url" == *suno.com* ]] || { echo "suno: to nie wygląda na URL suno: $url" >&2; return 1; }
  case "$format" in mp3|wav|mp4|m4a) ;; *)
    echo "suno: zły format '$format' (mp3|wav|mp4|m4a)" >&2; return 1 ;; esac
  command -v jq >/dev/null || { echo "suno: potrzebny jq" >&2; return 1; }

  mkdir -p "$outdir" || return 1

  # === natychmiastowy blok: co już wiadomo ===
  _suno_bar "DOWNLOADING" "$RED"
  printf '> [DIR]: [%s%s%s]\n> [URL]: [%s%s%s]\n' "$C" "$outdir" "$R" "$C" "$url" "$R"

  # request + download w jednej pętli retry (downloadUrl single-use -> po zwisie
  # trzeba wygenerować świeży link, retry samego linku = retry trupa)
  local resp dl fname afmt title tmp="" attempt=0 ok=0
  while (( attempt < maxtries )); do
    attempt=$(( attempt + 1 ))

    resp=$(curl -s --connect-timeout 15 --max-time 45 "$api/api/suno/download/" \
      -H 'content-type: application/json' \
      -H "origin: $api" -H "referer: $api/en/" -H "user-agent: $ua" \
      --data-raw "$(jq -nc --arg u "$url" --arg f "$format" '{url:$u,format:$f}')") || resp=""

    if [[ -z "$resp" ]]; then
      echo "suno: request timeout/fail ($attempt/$maxtries)" >&2; sleep 2; continue
    fi
    if [[ "$(jq -r '.success // false' <<<"$resp")" != "true" ]]; then
      echo "suno: API error: $resp" >&2; return 1
    fi

    dl=$(jq -r '.downloadUrl'  <<<"$resp")
    fname=$(jq -r '.filename'  <<<"$resp")
    afmt=$(jq -r '.actualFormat // "'"$format"'"' <<<"$resp")
    title=$(jq -r '.title // ""' <<<"$resp")

    tmp=$(mktemp "$outdir/.suno.XXXXXX") || return 1
    # progress bar na stderr; --speed-limit/--speed-time ubija tylko zwisy (<2KB/s przez 30s),
    # NIE aktywne pobieranie -> brak max-time żeby nie zabić dużych plików
    if curl -fL --progress-bar --connect-timeout 30 --speed-limit 2048 --speed-time 30 \
         "$api$dl" -H "referer: $api/en/" -H "user-agent: $ua" -o "$tmp"; then
      ok=1; break
    fi
    echo "suno: download stalled/fail ($attempt/$maxtries)" >&2
    rm -f "$tmp"; tmp=""; sleep 2
  done
  (( ok )) || { echo "suno: $maxtries próby w plecy, olewam" >&2; return 1; }

  # nazwa docelowa
  local out
  if [[ -n "$name" ]]; then
    case "$name" in *.mp3|*.wav|*.mp4|*.m4a) out="$name" ;; *) out="$name.$afmt" ;; esac
  else
    out="$fname"
  fi
  [[ -z "$title" ]] && title="${out%.*}"

  # metadata: długość + rozmiar (znane dopiero z gotowego pliku)
  local mmss='--:--'
  if command -v ffprobe >/dev/null; then
    local dur; dur=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$tmp" 2>/dev/null)
    [[ -n "$dur" ]] && mmss=$(awk -v d="$dur" 'BEGIN{s=int(d+0.5);printf "%02d:%02d",int(s/60),s%60}')
  fi
  local bytes hsize
  bytes=$(stat -c %s "$tmp" 2>/dev/null || stat -f %z "$tmp" 2>/dev/null)
  hsize=$(awk -v b="$bytes" 'BEGIN{
    if(b>=1073741824)printf "%.1f GB",b/1073741824;
    else if(b>=1048576)printf "%.1f MB",b/1048576;
    else if(b>=1024)printf "%.1f KB",b/1024;
    else printf "%d B",b}')

  printf '> [FILE]: %s%s%s / [%s%s%s] / [%s%s%s] / [%s%s%s]\n' \
    "$O" "$out" "$R" "$G" "$mmss" "$R" "$G" "$hsize" "$R" "$G" "$afmt" "$R"

  # reconcile — nigdy nie nadpisuj w ciemno
  local stem="${out%.*}" ext="${out##*.}"
  local cand="$outdir/$out" dup="" k=0 final=""
  while [[ -e "$cand" ]]; do
    if cmp -s "$tmp" "$cand"; then dup="$cand"; break; fi
    k=$(( k + 1 )); cand="$outdir/$stem-($k).$ext"
  done

  if [[ -n "$dup" ]]; then
    printf 'This exact file already exists. Download again? [y/N] '
    local ans; read -r ans
    case "$ans" in
      [yY]|[yY][eE][sS])
        local n=1 save="$outdir/$stem-($n).$ext"
        while [[ -e "$save" ]]; do n=$(( n + 1 )); save="$outdir/$stem-($n).$ext"; done
        mv "$tmp" "$save"; final="$save" ;;
      *) rm -f "$tmp"; final="$dup" ;;
    esac
  else
    mv "$tmp" "$cand"; final="$cand"
  fi
  [[ "${final:t}" != "$out" ]] && printf '> [SAVED]: %s%s%s\n' "$O" "${final:t}" "$R"

  _suno_bar "COMPLETE" "$GRN"
}
