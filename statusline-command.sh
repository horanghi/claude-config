#!/bin/sh
input=$(cat)

# ─── ANSI codes ───────────────────────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
GRAY="\033[90m"

# ─── Parse JSON input ────────────────────────────────────────────────────────
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
version=$(echo "$input" | jq -r '.version // empty')
permission_mode=$(echo "$input" | jq -r '.permission_mode // empty')

# ─── Git branch ──────────────────────────────────────────────────────────────
git_branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  git_branch=$(git -C "$cwd" -c core.fsmonitor=false symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" -c core.fsmonitor=false rev-parse --short HEAD 2>/dev/null)
fi

# ─── Shorten cwd (~/... style) ───────────────────────────────────────────────
short_cwd=""
if [ -n "$cwd" ]; then
  short_cwd=$(echo "$cwd" | sed "s|^$HOME|~|")
fi

# ─── Color helper ────────────────────────────────────────────────────────────
color_for_pct() {
  pct="$1"
  if [ -z "$pct" ]; then printf "%s" "$WHITE"; return; fi
  if [ "$pct" -ge 80 ] 2>/dev/null; then
    printf "%s" "$RED"
  elif [ "$pct" -ge 50 ] 2>/dev/null; then
    printf "%s" "$YELLOW"
  else
    printf "%s" "$GREEN"
  fi
}

# ─── Progress bar helper ─────────────────────────────────────────────────────
# usage: progress_bar <remaining_pct> <width>
progress_bar() {
  remaining="$1"
  width="${2:-10}"
  filled=$(awk "BEGIN {printf \"%.0f\", ($remaining / 100) * $width}")
  empty=$((width - filled))
  bar=""
  i=0; while [ "$i" -lt "$filled" ]; do bar="${bar}="; i=$((i+1)); done
  i=0; while [ "$i" -lt "$empty" ];  do bar="${bar}-"; i=$((i+1)); done
  printf "%s" "[$bar]"
}

# ─── Rate limit timestamps ───────────────────────────────────────────────────
current_hour_start=$(awk 'BEGIN {now=systime(); print int(now/3600)*3600}')
monday_start=$(awk 'BEGIN {
  cmd = "date +\"%u %H %M %S\""
  cmd | getline line; close(cmd)
  split(line, a, " ")
  now = systime()
  elapsed = (a[1] - 1) * 86400 + a[2] * 3600 + a[3] * 60 + a[4]
  print now - elapsed
}')

# ─── Token usage from transcript (single jq pass) ────────────────────────────
ho=0; hs=0; wo=0; ws=0
total_cost_cents=0

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  usage_data=$(jq -r --argjson h_cutoff "$current_hour_start" --argjson w_cutoff "$monday_start" '
    select(.type == "assistant" and .timestamp != null)
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $ts
    | select($ts >= $w_cutoff)
    | (.message.usage // empty)
    | select(. != null)
    | {
        in_tok:  (.input_tokens // 0),
        out_tok: (.output_tokens // 0),
        is_hourly: (if $ts >= $h_cutoff then 1 else 0 end),
        is_sonnet: (if (.model // "" | test("sonnet"; "i")) then 1 else 0 end)
      }
    | "\(.in_tok) \(.out_tok) \(.is_hourly) \(.is_sonnet)"
  ' "$transcript_path" 2>/dev/null)

  if [ -n "$usage_data" ]; then
    eval $(echo "$usage_data" | awk '
    {
      inp=$1; out=$2; is_h=$3; is_s=$4
      tok = inp + out
      if (is_h && is_s)  hs += tok
      if (is_h && !is_s) ho += tok
      if (is_s)          ws += tok
      if (!is_s)         wo += tok
      # Cost estimate (Opus: $15/$75 per 1M in/out, Sonnet: $3/$15 per 1M in/out)
      if (is_s) {
        cost += inp * 3 / 1000000 + out * 15 / 1000000
      } else {
        cost += inp * 15 / 1000000 + out * 75 / 1000000
      }
    }
    END {
      printf "ho=%d hs=%d wo=%d ws=%d total_cost_cents=%d", ho+0, hs+0, wo+0, ws+0, cost+0
    }')
  fi
fi

# Compute percentages (adjust limits to your plan)
HOURLY_LIMIT=100000;       HOURLY_SONNET_LIMIT=300000
WEEKLY_LIMIT=5000000;      WEEKLY_SONNET_LIMIT=15000000

calc_pct() {
  val="$1"; limit="$2"
  if [ "$val" -gt 0 ] 2>/dev/null; then
    awk "BEGIN {v=int($val/$limit*100); print (v>100?100:v)}"
  fi
}

hourly_pct=$(calc_pct "$ho" "$HOURLY_LIMIT")
hourly_sonnet_pct=$(calc_pct "$hs" "$HOURLY_SONNET_LIMIT")
weekly_pct=$(calc_pct "$wo" "$WEEKLY_LIMIT")
weekly_sonnet_pct=$(calc_pct "$ws" "$WEEKLY_SONNET_LIMIT")

# ─── Session duration ────────────────────────────────────────────────────────
session_dur=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  first_ts=$(jq -r 'select(.timestamp != null) | .timestamp' "$transcript_path" 2>/dev/null | head -1)
  if [ -n "$first_ts" ]; then
    first_epoch=$(echo "$first_ts" | awk '{
      gsub(/\.[0-9]+Z$/, "Z", $1)
      cmd = "date -jf \"%Y-%m-%dT%H:%M:%SZ\" \"" $1 "\" +%s 2>/dev/null"
      cmd | getline epoch; close(cmd)
      if (epoch == "") {
        cmd2 = "date -d \"" $1 "\" +%s 2>/dev/null"
        cmd2 | getline epoch; close(cmd2)
      }
      print epoch
    }')
    if [ -n "$first_epoch" ] && [ "$first_epoch" -gt 0 ] 2>/dev/null; then
      now_epoch=$(date +%s)
      elapsed_s=$((now_epoch - first_epoch))
      elapsed_m=$((elapsed_s / 60))
      if [ "$elapsed_m" -ge 60 ]; then
        session_dur="$((elapsed_m / 60))h$((elapsed_m % 60))m"
      else
        session_dur="${elapsed_m}m"
      fi
    fi
  fi
fi

# ─── Cost formatting ─────────────────────────────────────────────────────────
cost_str=""
cost_rate=""
if [ "$total_cost_cents" -gt 0 ] 2>/dev/null; then
  cost_str=$(awk "BEGIN {printf \"\$%.2f\", $total_cost_cents / 100}")
  if [ -n "$session_dur" ]; then
    # Compute hourly rate
    now_epoch=$(date +%s)
    if [ -n "$first_epoch" ] && [ "$first_epoch" -gt 0 ] 2>/dev/null; then
      elapsed_h=$(awk "BEGIN {v=($now_epoch - $first_epoch)/3600; print (v<0.01?0.01:v)}")
      cost_rate=$(awk "BEGIN {printf \"\$%.2f/h\", ($total_cost_cents / 100) / $elapsed_h}")
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BUILD OUTPUT — multi-line like the reference screenshot
# Line 1: 📁 cwd  🌿 branch  🤖 model  💻 version  🐚 permission
# Line 2: 🧠 Context Remaining: XX% [==========─]
# Line 3: ⏱  1h: Opus XX% | Sonnet XX%   📅 7d: Opus XX% | Sonnet XX%
# Line 4: 💰 $X.XX ($X.XX/h)  ⏳ session duration
# ═══════════════════════════════════════════════════════════════════════════════

line1=""

# 📁 cwd
if [ -n "$short_cwd" ]; then
  line1="$(printf "\360\237\223\201 %b%s%b" "$CYAN" "$short_cwd" "$RESET")"
fi

# 🌿 branch
if [ -n "$git_branch" ]; then
  line1="${line1}  $(printf "\360\237\214\277 %b%s%b" "$GREEN" "$git_branch" "$RESET")"
fi

# 🤖 model
if [ -n "$model" ]; then
  line1="${line1}  $(printf "\360\237\244\226 %b%b%s%b" "$BOLD" "$WHITE" "$model" "$RESET")"
fi

# 💻 version
if [ -n "$version" ]; then
  line1="${line1}  $(printf "\360\237\222\273 %b%s%b" "$GRAY" "v${version}" "$RESET")"
fi

# 🐚 permission mode
if [ -n "$permission_mode" ]; then
  line1="${line1}  $(printf "\360\237\220\232 %b%s%b" "$GRAY" "$permission_mode" "$RESET")"
fi

# ─── Line 2: Context ─────────────────────────────────────────────────────────
line2=""
if [ -n "$used_pct" ]; then
  remaining_int=$(awk "BEGIN {v=100-$used_pct; printf \"%.0f\", (v<0?0:v)}")
  ctx_color=$(color_for_pct "$(awk "BEGIN {printf \"%.0f\", $used_pct}")")
  bar=$(progress_bar "$remaining_int" 12)
  line2="$(printf "\360\237\247\240 Context Remaining: %b%s%%%b %b%s%b" "$ctx_color" "$remaining_int" "$RESET" "$ctx_color" "$bar" "$RESET")"
fi

# ─── Line 3: Rate limits (hourly + weekly, Opus + Sonnet) ────────────────────
line3=""
# Hourly
h_part=""
if [ -n "$hourly_pct" ] || [ -n "$hourly_sonnet_pct" ]; then
  h_part="$(printf "\342\217\261  %b%b1h:%b" "$BOLD" "$CYAN" "$RESET")"
  if [ -n "$hourly_pct" ]; then
    hc=$(color_for_pct "$hourly_pct")
    h_part="${h_part} $(printf "Opus %b%s%%%b" "$hc" "$hourly_pct" "$RESET")"
  fi
  if [ -n "$hourly_sonnet_pct" ]; then
    hsc=$(color_for_pct "$hourly_sonnet_pct")
    if [ -n "$hourly_pct" ]; then h_part="${h_part} $(printf "%b|%b" "$GRAY" "$RESET")"; fi
    h_part="${h_part} $(printf "Sonnet %b%s%%%b" "$hsc" "$hourly_sonnet_pct" "$RESET")"
  fi
fi

# Weekly
w_part=""
if [ -n "$weekly_pct" ] || [ -n "$weekly_sonnet_pct" ]; then
  w_part="$(printf "\360\237\223\205 %b%b7d:%b" "$BOLD" "$MAGENTA" "$RESET")"
  if [ -n "$weekly_pct" ]; then
    wc=$(color_for_pct "$weekly_pct")
    w_part="${w_part} $(printf "Opus %b%s%%%b" "$wc" "$weekly_pct" "$RESET")"
  fi
  if [ -n "$weekly_sonnet_pct" ]; then
    wsc=$(color_for_pct "$weekly_sonnet_pct")
    if [ -n "$weekly_pct" ]; then w_part="${w_part} $(printf "%b|%b" "$GRAY" "$RESET")"; fi
    w_part="${w_part} $(printf "Sonnet %b%s%%%b" "$wsc" "$weekly_sonnet_pct" "$RESET")"
  fi
fi

if [ -n "$h_part" ] || [ -n "$w_part" ]; then
  line3="${h_part}"
  if [ -n "$h_part" ] && [ -n "$w_part" ]; then
    line3="${line3}   ${w_part}"
  elif [ -n "$w_part" ]; then
    line3="${w_part}"
  fi
fi

# ─── Line 4: Cost + session duration ─────────────────────────────────────────
line4=""
if [ -n "$cost_str" ]; then
  line4="$(printf "\360\237\222\260 %b%b%s%b" "$BOLD" "$YELLOW" "$cost_str" "$RESET")"
  if [ -n "$cost_rate" ]; then
    line4="${line4} $(printf "%b(%s)%b" "$GRAY" "$cost_rate" "$RESET")"
  fi
fi
if [ -n "$session_dur" ]; then
  if [ -n "$line4" ]; then
    line4="${line4}  $(printf "\342\217\263 %b%s%b" "$GRAY" "$session_dur" "$RESET")"
  else
    line4="$(printf "\342\217\263 %b%s%b" "$GRAY" "$session_dur" "$RESET")"
  fi
fi

# ─── Output all lines ────────────────────────────────────────────────────────
output=""
if [ -n "$line1" ]; then output="${line1}"; fi
if [ -n "$line2" ]; then
  if [ -n "$output" ]; then output="${output}\n"; fi
  output="${output}${line2}"
fi
if [ -n "$line3" ]; then
  if [ -n "$output" ]; then output="${output}\n"; fi
  output="${output}${line3}"
fi
if [ -n "$line4" ]; then
  if [ -n "$output" ]; then output="${output}\n"; fi
  output="${output}${line4}"
fi

printf "%b" "$output"
