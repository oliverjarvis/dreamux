# Clayspace ZDOTDIR shim — runs *after* the user's normal $HOME/.zshrc
# so we can re-prepend Clayspace's bin to PATH and win the lookup for
# `claude` (and any future shim) regardless of how the user's rc files
# reordered PATH (Homebrew, nvm, asdf, …).
[ -f "$HOME/.zshrc" ] && . "$HOME/.zshrc"

# Restore Clayspace's bin to the front. Re-applied via precmd so that
# even mid-session PATH mutations (e.g. `nvm use`) don't strand us.
if [ -n "${CLAYSPACE_BIN:-}" ]; then
    _clayspace_ensure_path() {
        case ":$PATH:" in
            ":$CLAYSPACE_BIN:"*) ;;
            *) export PATH="$CLAYSPACE_BIN:$PATH" ;;
        esac
    }
    _clayspace_ensure_path
    autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _clayspace_ensure_path
fi
