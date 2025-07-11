#!/bin/bash

# Default ignore patterns (can be overridden with --no-ignore)
DEFAULT_IGNORE_PATTERNS=(".rvm" ".local" "vim_dotfiles")

# Parse command line arguments
IGNORE_PATTERNS=("${DEFAULT_IGNORE_PATTERNS[@]}")
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-ignore)
            IGNORE_PATTERNS=()
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --no-ignore    Don't ignore any directories (by default ignores .rvm, .local, and vim_dotfiles)"
            echo "  --verbose, -v  Show detailed checking progress"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Temporary files to store different categories
temp_dir=$(mktemp -d)
uncommitted_repos="$temp_dir/uncommitted"
unpushed_repos="$temp_dir/unpushed"
untracked_repos="$temp_dir/untracked"
no_upstream_repos="$temp_dir/no_upstream"
unpushed_branches="$temp_dir/unpushed_branches"
stashed_repos="$temp_dir/stashed_repos"
failed_resolution="$temp_dir/failed_resolution"

# Cleanup function
cleanup() {
    rm -rf "$temp_dir"
}
trap cleanup EXIT


# Function to check if a path should be ignored
should_ignore() {
    local path="$1"
    for pattern in "${IGNORE_PATTERNS[@]}"; do
        if [[ "$path" == *"/$pattern/"* ]] || [[ "$path" == "./$pattern"* ]]; then
            return 0  # Should ignore
        fi
    done
    return 1  # Should not ignore
}

# Disable version managers to prevent them from modifying files during checks
export RVM_DISABLE_AUTO_SWITCH=1
export DISABLE_AUTO_CD=1
unset rvm_current_rvmrc
unset rvm_trust_rvmrcs_flag

# Find all git repositories recursively and check for local changes
find . -name ".git" -type d 2>/dev/null | while read -r git_dir; do
    repo_dir=$(dirname "$git_dir")
    
    # Check if this directory should be ignored
    if should_ignore "$repo_dir"; then
        continue
    fi
    
    # Try to get absolute path first (before any cd operations)
    repo_path=$(realpath "$repo_dir" 2>/dev/null)
    
    # Skip if directory doesn't exist or isn't accessible
    if [ ! -d "$repo_dir" ] || ! cd "$repo_dir" 2>/dev/null; then
        # Store absolute path for failed resolution
        if [ -n "$repo_path" ]; then
            echo "$repo_path" >> "$failed_resolution"
        else
            # Convert ./ to absolute manually as fallback
            echo "$(pwd)/${repo_dir#./}" >> "$failed_resolution"
        fi
        continue
    fi
    
    # Check if we got a valid path
    if [ -n "$repo_path" ]; then
        # Only print "Checking" if verbose mode is enabled
        if [ "$VERBOSE" = true ]; then
            echo "Checking repository: $repo_path"
        fi
        has_issues=false
        
        # Run git checks in a subshell with clean environment to avoid RVM interference
        (
            # Completely disable RVM and other version managers in this subshell
            unset RVM_PATH RVM_CURRENT_RUBY_VERSION RVM_RUBY_VERSION 
            unset rvm_current_rvmrc rvm_trust_rvmrcs_flag
            export RVM_DISABLE_AUTO_SWITCH=1
            
            # Check for uncommitted changes (staged and unstaged)
            if ! git diff-index --quiet HEAD 2>/dev/null || ! git diff-index --quiet --cached HEAD 2>/dev/null; then
                echo "uncommitted" > "$temp_dir/status_$$"
            fi
            
            # Check for untracked files
            if [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
                echo "untracked" >> "$temp_dir/status_$$"
            fi
            
            # Check for unpushed commits on current branch
            current_branch=$(git branch --show-current 2>/dev/null)
            if [ -n "$current_branch" ]; then
                upstream=$(git rev-parse --abbrev-ref "$current_branch@{upstream}" 2>/dev/null)
                if [ -n "$upstream" ]; then
                    unpushed=$(git rev-list "$upstream..HEAD" --count 2>/dev/null)
                    if [ "$unpushed" -gt 0 ]; then
                        echo "unpushed:$unpushed" >> "$temp_dir/status_$$"
                    fi
                else
                    echo "no_upstream" >> "$temp_dir/status_$$"
                fi
            fi
            
            # Check for unpushed commits on other local branches
            has_unpushed_branches=false
            git for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads/ 2>/dev/null | while read -r local_branch upstream_branch; do
                if [ -n "$upstream_branch" ]; then
                    # Check if this branch has commits ahead of its upstream
                    ahead=$(git rev-list --count "$upstream_branch..$local_branch" 2>/dev/null || echo "0")
                    if [ "$ahead" -gt 0 ]; then
                        echo "branch_unpushed:$local_branch:$ahead" >> "$temp_dir/status_$$"
                    fi
                elif [ "$local_branch" != "$current_branch" ]; then
                    # Local branch with no upstream (excluding current branch which is handled above)
                    echo "branch_no_upstream:$local_branch" >> "$temp_dir/status_$$"
                fi
            done
            
            # Check for stashes
            stash_count=$(git stash list 2>/dev/null | wc -l)
            if [ "$stash_count" -gt 0 ]; then
                echo "stashes:$stash_count" >> "$temp_dir/status_$$"
            fi
        )
        
        # Process the results from the subshell
        if [ -f "$temp_dir/status_$$" ]; then
            while read -r status; do
                case "$status" in
                    uncommitted)
                        if [ "$VERBOSE" = true ]; then
                            echo "  ✗ Has uncommitted changes"
                        fi
                        echo "$repo_path" >> "$uncommitted_repos"
                        has_issues=true
                        ;;
                    untracked)
                        if [ "$VERBOSE" = true ]; then
                            echo "  ✗ Has untracked files"
                        fi
                        echo "$repo_path" >> "$untracked_repos"
                        has_issues=true
                        ;;
                    unpushed:*)
                        unpushed_count="${status#unpushed:}"
                        if [ "$VERBOSE" = true ]; then
                            echo "  ✗ Has $unpushed_count unpushed commit(s)"
                        fi
                        echo "$repo_path" >> "$unpushed_repos"
                        has_issues=true
                        ;;
                    no_upstream)
                        if [ "$VERBOSE" = true ]; then
                            echo "  ✗ No upstream branch set"
                        fi
                        echo "$repo_path" >> "$no_upstream_repos"
                        has_issues=true
                        ;;
                    branch_unpushed:*)
                        branch_info="${status#branch_unpushed:}"
                        branch_name="${branch_info%:*}"
                        commit_count="${branch_info#*:}"
                        if [ "$VERBOSE" = true ]; then
                            echo "  ✗ Branch '$branch_name' has $commit_count unpushed commit(s)"
                        fi
                        echo "$repo_path" >> "$unpushed_branches"
                        has_issues=true
                        ;;
                    branch_no_upstream:*)
                        branch_name="${status#branch_no_upstream:}"
                        if [ "$VERBOSE" = true ]; then
                            echo "  ✗ Branch '$branch_name' has no upstream"
                        fi
                        echo "$repo_path" >> "$unpushed_branches"
                        has_issues=true
                        ;;
                    stashes:*)
                        stash_count="${status#stashes:}"
                        if [ "$VERBOSE" = true ]; then
                            echo "  ✗ Has $stash_count stash(es)"
                        fi
                        echo "$repo_path" >> "$stashed_repos"
                        has_issues=true
                        ;;
                esac
            done < "$temp_dir/status_$$"
            rm -f "$temp_dir/status_$$"
        fi
        
        if [ "$has_issues" = false ] && [ "$VERBOSE" = true ]; then
            echo "  ✓ Clean"
        fi
    else
        # Path resolution failed - record absolute path
        if [ -n "$repo_path" ]; then
            echo "$repo_path" >> "$failed_resolution"
        else
            # Convert ./ to absolute manually as fallback
            echo "$(pwd)/${repo_dir#./}" >> "$failed_resolution"
        fi
    fi
    
    cd - > /dev/null 2>&1
done

# Print summary
echo ""
echo "========================================"
echo "SUMMARY:"
echo "========================================"

# Sort and deduplicate each category
if [ -f "$uncommitted_repos" ] && [ -s "$uncommitted_repos" ]; then
    echo "Repos with uncommitted changes:"
    sort "$uncommitted_repos" | uniq | while read -r repo; do
        echo "	- $repo"
    done
    echo ""
fi

if [ -f "$unpushed_repos" ] && [ -s "$unpushed_repos" ]; then
    echo "Repos with unpushed changes:"
    sort "$unpushed_repos" | uniq | while read -r repo; do
        echo "	- $repo"
    done
    echo ""
fi

if [ -f "$untracked_repos" ] && [ -s "$untracked_repos" ]; then
    echo "Repos with untracked files:"
    sort "$untracked_repos" | uniq | while read -r repo; do
        echo "	- $repo"
    done
    echo ""
fi

if [ -f "$no_upstream_repos" ] && [ -s "$no_upstream_repos" ]; then
    echo "Repos with no upstream branch:"
    sort "$no_upstream_repos" | uniq | while read -r repo; do
        echo "	- $repo"
    done
    echo ""
fi

if [ -f "$unpushed_branches" ] && [ -s "$unpushed_branches" ]; then
    echo "Repos with unpushed branches:"
    sort "$unpushed_branches" | uniq | while read -r repo; do
        echo "	- $repo"
    done
    echo ""
fi

if [ -f "$stashed_repos" ] && [ -s "$stashed_repos" ]; then
    echo "Repos with stashes:"
    sort "$stashed_repos" | uniq | while read -r repo; do
        echo "	- $repo"
    done
    echo ""
fi

if [ -f "$failed_resolution" ] && [ -s "$failed_resolution" ]; then
    # Save the full list to a permanent file
    failed_list_file="/tmp/git_failed_repos.txt"
    sort "$failed_resolution" | uniq > "$failed_list_file"
    failed_count=$(wc -l < "$failed_list_file")
    echo "Found $failed_count repos with path resolution issues (full list saved to: $failed_list_file)"
    echo ""
fi

# Check if all main files are empty
if [ ! -s "$uncommitted_repos" ] && [ ! -s "$unpushed_repos" ] && [ ! -s "$untracked_repos" ] && [ ! -s "$no_upstream_repos" ] && [ ! -s "$unpushed_branches" ] && [ ! -s "$stashed_repos" ]; then
    echo "All accessible repositories are clean!"
fi