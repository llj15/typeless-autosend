import Foundation

// Scripts delegate candidates to the executable, so upgrades cannot leave stale
// command/flag lists in shell profiles. Shell words are always passed as argv.
func completionScript(shell: String) -> String? {
    switch shell {
    case "zsh":
        return #"""
# typeless-autosend zsh completion
_typeless_autosend() {
  local -a candidates
  candidates=("${(@f)$(command "${words[1]}" completion candidates -- "${(@)words[2,CURRENT]}" 2>/dev/null)}")
  (( ${#candidates} )) && compadd -- "${candidates[@]}"
}
if ! (( $+functions[compdef] )); then
  autoload -Uz compinit
  compinit
fi
compdef _typeless_autosend typeless-autosend

"""#
    case "bash":
        return #"""
# typeless-autosend bash completion (compatible with macOS Bash 3.2)
_typeless_autosend() {
  local candidate output
  COMPREPLY=()
  output=$(command "${COMP_WORDS[0]}" completion candidates -- "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && COMPREPLY+=("$candidate")
  done <<TYPELESS_CANDIDATES
$output
TYPELESS_CANDIDATES
}
complete -F _typeless_autosend typeless-autosend

"""#
    case "fish":
        return #"""
# typeless-autosend fish completion
function __typeless_autosend_candidates
  set -l tokens (commandline -opc)
  set -l executable $tokens[1]
  set -e tokens[1]
  set -l prefix (commandline -ct)
  command "$executable" completion candidates -- $tokens "$prefix" 2>/dev/null
end
complete -c typeless-autosend -e
complete -c typeless-autosend -f -a '(__typeless_autosend_candidates)'

"""#
    default: return nil
    }
}
