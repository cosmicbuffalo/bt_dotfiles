
alias tmuxkillall="tmux ls | cut -d : -f 1 | xargs -I \{\} tmux kill-session -t \{\}" # tmux kill all sessions
export NVIM_APPNAME=personal_nvim

source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

