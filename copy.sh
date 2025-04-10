#!/bin/bash

log_file=~/copy-debug.log
input="$1"

{
  echo "[$(date)] input: '$input'"

  osc52=$(echo -n "$input" | base64 | tr -d '\n' | awk '{printf "\033]52;c;%s\a", $0}')
  echo "[$(date)] osc52: '$osc52'"

  session=$(tmux display-message -p '#S')
  window=$(tmux display-message -p '#I')
  echo "[$(date)] session: $session, window: $window"

  # Silent split — 1-line tall pane at the bottom
  pane_id=$(tmux split-window -v -l 1 -t "$session:$window" -P -F '#{pane_id}' -d "printf '$osc52' >/dev/tty; sleep 0.2" 2>/dev/null)
  echo "[$(date)] pane_id: '$pane_id'"

  # If successful, clean it up
  if [ -n "$pane_id" ]; then
    sleep 0.3
    tmux kill-pane -t "$pane_id" 2>/dev/null
    echo "[$(date)] killed pane $pane_id"
  else
    echo "[$(date)] failed to create pane"
  fi
} >> "$log_file" 2>&1

# Always exit cleanly so LazyGit doesn't complain
exit 0

