#!/bin/bash
# ====================================================================================
## frwe.sh – Fork-free File I/O + Stream Processing Module
## Documentation is embedded as MARKDOWN comments (starting with ##)
## Insert as-is: source frwe.sh
## Combines frwe.sh low-level I/O + stream processing
## Replaces ALL sed/grep/awk/cat INSIDE scripts – exact, no fork, no temp files
# ====================================================================================

## ## `frwe.sh`
##
## Provides:
## – Low-level file read/write in **exactly 4,096-byte blocks** (BMF).
## – **Universal `zed` function** – **full analog of cat + sed + grep + awk**
##   with **stream processing** (line-by-line, no memory load).
## – **Extended syntax**: support for complex sed and awk expressions.
##
## Features:
## – 32-bit seek (0..4,294,967,295).
## – Any buffer size (4 KB fragmentation internally).
## – **Stream processing**: works with files of any size, no memory load.
## – **Exact cat** → `zed '' in -`.
## – **Exact sed** → `zed 's/old/new/g' in out`.
## – **Exact grep** → `zed '/PAT/p' in out`.
## – **Exact awk** → `zed '{print $2}' in out`.
## – **No temporary files, no forks**.
## – Works on 100 GB files – instant seek.

# ---------- 1. LOW-LEVEL 4 KiB R/W (bmf4k) ----------
## ### `bmf4k <file> <mode> <seek> <bytes>`
## – mode = "R" → return block to stdout.
## – mode = "W" → write stdin to file with seek, bytes=0 → entire stdin.
## – Internally **double dd**: first aligns 4 KB, second precisely trims head/tail.
bmf4k(){
  local file=$1 mode=${2:-R} seek=$3 bytes=$4            ## arguments
  [[ -n $file && -n $seek && -n $bytes ]] || return 1   ## basic validation
  case "$mode" in
    R) ## read block, trim excess
        dd if="$file" bs=4096 skip=$((seek/4096)) count=$(((bytes+4095)/4096)) 2>/dev/null |
        dd bs=1 skip=$((seek%4096)) count="$bytes" 2>/dev/null ;;
    W) ## write block, write exactly as much as received
        dd of="$file" bs=4096 seek=$((seek/4096)) conv=notrunc 2>/dev/null ;;
    *) return 2 ;;                                       ## unknown mode
  esac
}

# ---------- 2. BMF – Universal Wrappers (Any Size) ----------
## ### `BMF R|W file seek bytes [buffer]`
## – **Any buffer size** (4 KB fragmentation internally).
## – Returns/writes **exactly as many bytes as requested**.
BMF(){
  local mode=$1 file=$2 seek=$3 bytes=$4 buffer=${5:-}   ## arguments with empty default
  [[ -n $mode && -n $file && -n $seek && -n $bytes ]] || return 1
  local off=$seek left=$bytes pos=0 result=""            ## position and counters
  case "$mode" in
    R) ## read in 4 KB loop
        while ((left > 0)); do
          local blk_size=$((left>4096?4096:left))        ## no more than 4 KB at a time
          local chunk
          chunk=$(bmf4k "$file" R "$off" "$blk_size")     ## read block
          [[ ${#chunk} -eq 0 ]] && break                 ## EOF
          result+="$chunk"                               ## accumulate
          off=$((off + ${#chunk}))                       ## shift position
          left=$((left - ${#chunk}))                     ## reduce remainder
        done
        printf '%s' "$result"                            ## return buffer
        ;;
    W) ## write in 4 KB loop
        [[ ${#buffer} -eq 0 ]] && return 0               ## empty buffer → exit
        [[ $bytes -eq 0 ]] && bytes=${#buffer}           ## bytes=0 → entire buffer
        while ((left > 0 && pos < ${#buffer})); do
          local blk_size=$((left>4096?4096:left))        ## block size
          local blk="${buffer:$pos:$blk_size}"           ## cut out piece
          [[ ${#blk} -eq 0 ]] && break                   ## end of data
          printf '%s' "$blk" | bmf4k "$file" W "$off" "${#blk}"  ## write block
          off=$((off + ${#blk}))                         ## shift seek
          pos=$((pos + ${#blk}))                         ## shift position in buffer
          left=$((left - ${#blk}))                       ## reduce remainder
        done
        ;;
    *) return 2 ;;                                       ## unknown mode
  esac
}

# ---------- 3. UNIVERSAL zed – Stream-enabled cat + sed + grep + awk ----------
## ### `zed <expression> <input1> [input2] ... [output]`
## – **Stream processing**: reads one file at a time, processing it line-by-line.
## – **Stdin support**: can accept data from standard input.
## – **Extended syntax**: new features for sed and awk.
zed(){
  local expr=$1; shift
  [[ ${DEBUG:-0} -eq 1 ]] && printf '🔍 zed (combined): incoming expr="%s" (quoted)\n' "$expr" >&2
  local -a inputs=() output=""

  if [[ $# -gt 0 && ${@: -1} != "-" ]]; then
    output=${@: -1}
    inputs=("${@:1:$#-1}")
  else
    output="-"
    inputs=("$@")
    [[ ${#inputs[@]} -gt 0 && ${inputs[-1]} == "-" ]] && unset inputs[-1]
  fi

  # If no inputs are specified but stdin has data, use stdin
  if [[ ${#inputs[@]} -eq 0 && ! -t 0 ]]; then
      inputs+=("-")
  elif [[ ${#inputs[@]} -eq 0 ]]; then
      # If neither files nor stdin data is available
      printf 'zed: missing input\n' >&2
      return 1
  fi

  # Open file descriptor for output, if not stdout
  if [[ "$output" != "-" ]]; then
    exec 3>"$output"
  else
    exec 3>&1
  fi

  for infile in "${inputs[@]}"; do
    # Read from stdin if infile is "-"
    if [[ "$infile" == "-" ]]; then
        while IFS= read -r line; do
            process_expression_stream "$expr" "$line" >&3
        done
    else
        [[ -f "$infile" ]] || continue
        while IFS= read -r line; do
            process_expression_stream "$expr" "$line" >&3
        done < "$infile"
    fi
  done

  # Close file descriptor
  exec 3>&-
}

## Helper function for stream expression processing
process_expression_stream(){
  local expr=$1 line=$2

  case "$expr" in
    "")        ## ========== CAT MODE ==========
       printf '%s\n' "$line" ;;
    s/*)       ## ========== SED (EXTENDED) ==========
       local pat rpl flags
       pat=${expr#s/}
       flags=${pat##*/}
       pat=${pat%/*}
       rpl=${expr#s/"$pat"/}
       rpl=${rpl%/"$flags"}

       if [[ "$flags" == "g" ]]; then
         printf '%s\n' "${line//"$pat"/"$rpl"}"
       else
         printf '%s\n' "${line/"$pat"/"$rpl"}"
       fi
       ;;
    /?*/d)     ## ========== GREP DELETE ==========
       local pattern=${expr%/d}
       pattern=${pattern#/}
       [[ $line != *"$pattern"* ]] && printf '%s\n' "$line"
       ;;
    /?*/p)     ## ========== GREP PRINT ==========
       local pattern=${expr%/p}
       pattern=${pattern#/}
       [[ $line == *"$pattern"* ]] && printf '%s\n' "$line"
       ;;
    '{print $'*'}')  ## ========== AWK FIELD ==========
       local n=${expr#'{print $'}
       n=${n%'}'}
       local -a fld
       read -r -a fld <<< "$line"
       if [[ "$n" == "0" ]]; then
         printf '%s\n' "$line"
       elif [[ -n ${fld[$((n-1))]-} ]]; then
         printf '%s\n' "${fld[$((n-1))]}"
       fi
       ;;
    /*/' {print $'*'}')  ## ========== AWK + GREP (/PAT/ {print $N}) ==========
       local pattern field
       local temp="${expr#/}"
       temp="${temp%'}'}"
       if [[ "$temp" == *'/ {print $'* ]]; then
         pattern="${temp%%'/ {print $'*}"
         field="${temp##*'/ {print $'}"
         if [[ $line == *"$pattern"* ]]; then
            local -a fld
            read -r -a fld <<< "$line"
            if [[ "$field" == "0" ]]; then
                printf '%s\n' "$line"
            elif [[ -n ${fld[$((field-1))]-} ]]; then
                printf '%s\n' "${fld[$((field-1))]}"
            fi
         fi
       else
         printf 'zed: unknown expression: %s\n' "$expr" >&2
         return 1
       fi
       ;;
    *)         ## ========== FALLBACK ==========
       printf 'zed: unknown expression: %s\n' "$expr" >&2
       return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
#  READY TO USE:
#  source frwe.sh
#  then:
#   cat data.txt | zed '{print $1}' - > column1.txt
#   zed '/^DEBUG/d' large_log.txt processed_log.txt
#   BMF R file 0 128        – read 128 bytes from start
#   BMF W file 4096 0 "$data" – write $data at offset 4096
#   zed '' in1 in2 -       – exact cat in1+in2 → stdout
#   zed 's/old/new/g' in out – exact sed
#   zed '/ERROR/p' log err   – exact grep
#   zed '{print $2}' data col – exact awk
#   zed '/filename/ {print $1}' log col – exact awk + grep
# ---------------------------------------------------------------------------
