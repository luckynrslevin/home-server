# /etc/profile.d/zz-aliases.sh — managed by Ansible role os-base.
# `zz-` prefix so this loads after distro-provided profile.d entries
# (some define their own ll/la). Edits will be overwritten.

# Listing
alias ll='ls -lh --color=auto --group-directories-first'
alias la='ls -lAh --color=auto --group-directories-first'
alias l='ls -lh --color=auto --group-directories-first'

# Quick directory navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Color by default
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
alias diff='diff --color=auto'
alias ip='ip --color=auto'

# Safety nets — prompt before clobbering
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Useful systemd shortcuts
alias jc='journalctl'
alias sc='systemctl'
alias scu='systemctl --user'
