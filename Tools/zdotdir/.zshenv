# Dreamux ZDOTDIR shim — load the user's normal $HOME/.zshenv, since
# zsh stops looking there once ZDOTDIR is set. Other rc files
# (.zshrc, .zprofile, .zlogin) follow the same pattern in their
# matching files in this directory.
[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"
