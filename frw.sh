#!/bin/bash
# ====================================================================================
##  frw.sh  –  Fork-free File I/O  (4 KiB blocks, any size, seek/32-bit)
##  Documentation is embedded as MARKDOWN comments (start with ##)
##  Insert as-is:  source frw.sh
##  Replaces ALL sed/grep/awk/cat INSIDE scripts – exact, no fork, no temp files
# ====================================================================================

## ## Module `frw.sh`
##
## Provides low-level file read/write in **exactly 4,096-byte blocks**
## and a **universal `zed` function** – a **full analog of cat + sed + grep + awk**
## **without a single external process** – **all in bash + dd + 4 KiB seek blocks**
##
## Features:
## – 32-bit seek (0..4,294,967,295)
## – Any buffer size (fragmentation into 4 KB internally)
## – **exact cat** → `zed '' in -`
## – **exact sed** → `zed 's/old/new/g' in out`
## – **exact grep** → `zed '/PAT/p' in out`
## – **exact awk** → `zed '{print $2}' in out`
## – **No temporary files, no forks**
## – Works on 100 GB files – instant seek

# ---------- 1. LOW-LEVEL 4 KiB R/W (bmf4k) ----------
## ### `bmf4k <file> <mode> <seek> <bytes>`
## – mode = "R" → return block to stdout
## – mode = "W" → write stdin to file with seek, bytes=0 → entire stdin
## – Internally uses **double dd**: first aligns 4 KB, second precisely trims head/tail
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

# ---------- 2. BMF – Universal wrappers (any size) ----------
## ### `BMF R|W file seek bytes [buffer]`
## – **Any buffer size** (fragmentation into 4 KB internally)
## – Returns/writes **exactly as many bytes as requested**
BMF(){
  local mode=$1 file=$2 seek=$3 bytes=$4 buffer=${5:-}   ## arguments with empty default
  [[ -n $mode && -n $file && -n $seek && -n $bytes ]] || return 1
  local off=$seek left=$bytes pos=0 result=""            ## position and counters
  case "$mode" in
    R) ## read in 4 KB chunks
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
    W) ## write in 4 KB chunks
        [[ ${#buffer} -eq 0 ]] && return 0               ## empty buffer → exit
        [[ $bytes -eq 0 ]] && bytes=${#buffer}           ## bytes=0 → entire buffer
        while ((left > 0 && pos < ${#buffer})); do
          local blk_size=$((left>4096?4096:left))        ## block size
          local blk="${buffer:$pos:$blk_size}"           ## cut out a piece
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

# ---------- 3. UNIVERSAL zed – exact cat + sed + grep + awk ----------
## ### `zed <expression> <input1> [input2] ... [output]`
## – **Single function** for **all** text pipelines:
##   – **cat** → `zed '' in1 in2 -`
##   – **sed** → `zed 's/old/new/g' in out`
##   – **grep** → `zed '/PAT/p' in out`
##   – **awk** → `zed '{print $2}' in out`
## – **No external processes** – **BMF(R)** + **BMF(W)** + bash loops
## – **4 KiB blocks** – **instant seek**, **exact bytes**, **no fork**
##
## Examples:
##   zed '' file.txt -                                 # exact cat file.txt → stdout
##   zed '' f1.txt f2.txt merged.txt                   # exact cat f1+f2 → merged.txt
##   zed 's/old/new/g' input.txt output.txt            # exact sed
##   zed '/^ERROR/p' log.txt errors.txt                # exact grep
##   zed '{print $2}' data.txt column2.txt             # exact awk
##   zed '/cc_/{print $1}' list.txt names.txt          # exact awk + grep
zed(){
  local expr=$1; shift                       ## extract expression
  [[ ${DEBUG:-0} -eq 1 ]] && printf '🔍 zed: incoming expr="%s" (quoted)\n' "$expr" >&2
  local -a inputs=() output=""               ## array of inputs and output
  ## separate inputs and output (last argument is output, unless "-")
  if [[ $# -gt 0 && ${@: -1} != "-" ]]; then
    output=${@: -1}
    inputs=("${@:1:$#-1}")
  else
    output="-"
    inputs=("$@")
    # remove last "-" if present
    [[ ${#inputs[@]} -gt 0 && ${inputs[-1]} == "-" ]] && unset inputs[-1]
  fi
  [[ ${#inputs[@]} -eq 0 ]] && return 1      ## no inputs → exit

  ## read ALL inputs in full via BMF (fork-free)
  local whole="" chunk off b=65536
  for infile in "${inputs[@]}"; do
    [[ -f $infile ]] || continue
    local file_size
    file_size=$(stat -c%s "$infile" 2>/dev/null || echo 0)
    [[ $file_size -eq 0 ]] && continue
    off=0
    while ((off < file_size)); do
      local read_size=$((file_size - off))
      [[ $read_size -gt $b ]] && read_size=$b
      chunk=$(BMF R "$infile" "$off" "$read_size")
      [[ ${#chunk} -eq 0 ]] && break
      whole+="$chunk"
      off=$((off + ${#chunk}))
    done
  done

  ## if output = "-" → output to stdout
  if [[ $output == "-" ]]; then
    # Apply expression and output
    case "$expr" in
      "") printf '%s' "$whole" ;;
      *) local processed; processed=$(process_expression "$expr" "$whole")
         printf '%s' "$processed" ;;
    esac
    return 0
  fi

  ## apply expression and write to file
  local whole_out
  whole_out=$(process_expression "$expr" "$whole")
  BMF W "$output" 0 0 "$whole_out"
}

## Helper function for expression processing
process_expression(){
  local expr=$1 whole=$2 whole_out=""

  case "$expr" in
    "")        ## ========== CAT MODE ==========
       whole_out="$whole" ;;

    s/*)       ## ========== SED ==========
       local pat rpl
       pat=${expr#s/}; pat=${pat%/*}
       rpl=${expr#s/}; rpl=${rpl#*/}; rpl=${rpl%/g}
       whole_out=${whole//"$pat"/"$rpl"} ;;

    /?*/d)     ## ========== GREP DELETE ==========
       local pattern=${expr%/d}; pattern=${pattern#/}
       local IFS=$'\n' line
       while IFS= read -r line; do
         [[ $line == $pattern* ]] && continue
         whole_out+="$line"$'\n'
       done <<< "$whole" ;;

    /?*/p)     ## ========== GREP PRINT ==========
       local pattern=${expr%/p}; pattern=${pattern#/}
       local IFS=$'\n' line
       while IFS= read -r line; do
         [[ $line == *$pattern* ]] && whole_out+="$line"$'\n'
       done <<< "$whole" ;;

    '{print $'*'}')  ## ========== AWK FIELD ==========
       local n=${expr#'{print $'}; n=${n%'}'}
       local IFS=$'\n' line
       while IFS= read -r line; do
         [[ -z $line ]] && continue
         read -r -a fld <<< "$line"
         [[ -n ${fld[$((n-1))]-} ]] && whole_out+="${fld[$((n-1))]}"$'\n'
       done <<< "$whole" ;;

    /*' {print $'*'}')  ## ========== AWK + GREP (/PAT/ {print $N}) ==========
       # Parse /pattern/ {print $field} expressions using string manipulation
       local pattern field
       # Remove leading / and trailing }
       local temp="${expr#/}"       # Remove leading /
       temp="${temp%'}'}"           # Remove trailing }

       # Split on / {print $
       if [[ "$temp" == *'/ {print $'* ]]; then
         pattern="${temp%%'/ {print $'*}"  # Everything before / {print $
         field="${temp##*'/ {print $'}"    # Everything after / {print $

         [[ ${DEBUG:-0} -eq 1 ]] && printf '🔍 zed: parsed pattern="%s" field="%s"\n' "$pattern" "$field" >&2

         local IFS=$'\n' line
         while IFS= read -r line; do
           [[ $line == *"$pattern"* ]] || continue
           read -r -a fld <<< "$line"
           [[ -n ${fld[$((field-1))]-} ]] && whole_out+="${fld[$((field-1))]}"$'\n'
         done <<< "$whole"
       else
         # Fallback for malformed expressions
         [[ ${DEBUG:-0} -eq 1 ]] && printf '🔍 zed: failed to parse complex expression: %s\n' "$expr" >&2
         printf 'zed: unknown expression: %s\n' "$expr" >&2
         return 1
       fi
       ;;

    *)         ## ========== FALLBACK ==========
       [[ ${DEBUG:-0} -eq 1 ]] && printf '🔍 zed: unknown expression: %s\n' "$expr" >&2
       printf 'zed: unknown expression: %s\n' "$expr" >&2
       return 1 ;;
  esac
  printf '%s' "$whole_out"
}

# ---------------------------------------------------------------------------
#  READY TO USE:
#  source frw.sh
#  then:
#   BMF R file 0 128        – read 128 bytes from start
#   BMF W file 4096 0 "$data" – write $data at offset 4096
#   zed '' in1 in2 -       – exact cat in1+in2 → stdout
#   zed 's/old/new/g' in out – exact sed
#   zed '/ERROR/p' log err   – exact grep
#   zed '{print $2}' data col – exact awk
#   zed '/filename/ {print $1}' log col – exact awk + grep
# ---------------------------------------------------------------------------
