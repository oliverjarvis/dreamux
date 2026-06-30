# Dreamux ZDOTDIR shim — runs *after* the user's normal $HOME/.zshrc
# so we can re-prepend Dreamux's bin to PATH and win the lookup for
# `claude` (and any future shim) regardless of how the user's rc files
# reordered PATH (Homebrew, nvm, asdf, …).
[ -f "$HOME/.zshrc" ] && . "$HOME/.zshrc"

# Restore Dreamux's bin to the front. Re-applied via precmd so that
# even mid-session PATH mutations (e.g. `nvm use`) don't strand us.
if [ -n "${DREAMUX_BIN:-}" ]; then
    _dreamux_ensure_path() {
        case ":$PATH:" in
            ":$DREAMUX_BIN:"*) ;;
            *) export PATH="$DREAMUX_BIN:$PATH" ;;
        esac
    }
    _dreamux_ensure_path
    autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _dreamux_ensure_path
fi
