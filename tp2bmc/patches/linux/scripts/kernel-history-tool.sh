#!/usr/bin/env bash
# TP2 BMC — harvest upstream Linux history for files touched by our patches.
#
# Pristine-only: this tool inspects unpatched upstream history between
# BASE_TAG (default v6.8.12) and HEAD_TAG (default v6.18.33). It does NOT
# apply or consider local patches; the patch set is used solely to derive
# the list of files to track.
#
# Typical workflow:
#   $0 setup                              # one-time partial clone
#   $0 inventory                          # show files we'll track
#   $0 commits drivers/regulator/fixed.c  # commit list (ascending date)
#   $0 show <sha> drivers/regulator/fixed.c
#   $0 harvest                            # dump everything to OUT_DIR
#
# All heavy outputs go to OUT_DIR (default tmp/upstream-analysis/), which
# is gitignored. The script never writes inside the kernel tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

KERNEL_GIT="${KERNEL_GIT:-${WORKSPACE_ROOT}/tmp/linux.git}"
BASE_TAG="${BASE_TAG:-v6.8.12}"
HEAD_TAG="${HEAD_TAG:-v6.18.33}"
OUT_DIR="${OUT_DIR:-${WORKSPACE_ROOT}/tmp/upstream-analysis}"
REMOTE_URL="${REMOTE_URL:-https://github.com/gregkh/linux.git}"

usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  setup                   One-time: partial-clone linux-stable into KERNEL_GIT
                          and fetch BASE_TAG/HEAD_TAG (filter=blob:none).
  fetch-tag <tag>         Fetch one extra tag into the existing clone.
  inventory               List files derived from patches (tracked set).
  commits <path>          Commits touching <path> in BASE_TAG..HEAD_TAG,
                          ascending by author-date, with rename follow.
  stat <path>             Same as commits but adds --stat (one entry/commit).
  renames <path>          Rename history of <path> across the window.
  show <sha> <path>       Full file-scoped diff for one commit.
  harvest [paths...]      Per-file dumps into OUT_DIR. If no paths given,
                          uses inventory.
  summary <path>          Subject+date+stat one-liner per commit.
  paths-at <tag> <regex>  Resolve a path glob/regex inside a tag's tree.

Environment:
  KERNEL_GIT   Bare/partial clone path  (default: ${KERNEL_GIT})
  BASE_TAG                              (default: ${BASE_TAG})
  HEAD_TAG                              (default: ${HEAD_TAG})
  OUT_DIR                               (default: ${OUT_DIR})
  REMOTE_URL                            (default: ${REMOTE_URL})

Files come from \`kernel-patch-tool.sh\` inventory output and are passed
verbatim (no normalization). The recursive expansion when code moves to
new files is intentionally left to a human/agent reviewer.
EOF
}

die() {
	echo "error: $*" >&2
	exit 1
}

# ---------- Inventory derived from patches (independent of kernel tree) ----------

ordered_patches() {
	local d p
	for d in generic/i2c generic/pwm net-dsa tp2/gpio tp2/power tp2/tpi-smi-mux; do
		shopt -s nullglob
		for p in "${PATCH_ROOT}/${d}"/*.patch; do echo "$p"; done
		shopt -u nullglob
	done
}

patch_touched_files() {
	local patch="$1" line
	while IFS= read -r line; do
		if [[ "$line" =~ ^diff\ --git\ a/([^[:space:]]+)\ b/([^[:space:]]+) ]]; then
			echo "${BASH_REMATCH[2]}"
		fi
	done <"$patch"
}

inventory_paths() {
	local p
	while IFS= read -r p; do
		patch_touched_files "$p"
	done < <(ordered_patches) | sort -u
}

# ---------- Git wrappers ----------

git_in() {
	git -c protocol.version=2 --git-dir="$KERNEL_GIT" "$@"
}

ensure_clone() {
	[[ -d "$KERNEL_GIT" ]] || die "no kernel clone at $KERNEL_GIT — run: $0 setup"
	git_in rev-parse --git-dir >/dev/null 2>&1 ||
		die "$KERNEL_GIT is not a git directory"
}

ensure_tag() {
	local tag="$1"
	git_in rev-parse --quiet --verify "refs/tags/${tag}^{commit}" >/dev/null ||
		die "tag $tag not present in $KERNEL_GIT — run: $0 fetch-tag $tag"
}

# ---------- Commands ----------

cmd_setup() {
	if [[ -d "$KERNEL_GIT" ]]; then
		echo "info: clone already exists at $KERNEL_GIT (skipping init)"
	else
		mkdir -p "$(dirname "$KERNEL_GIT")"
		echo "==> git init --bare $KERNEL_GIT"
		git init --bare "$KERNEL_GIT"
		git_in remote add origin "$REMOTE_URL"
		git_in config remote.origin.promisor true
		git_in config remote.origin.partialclonefilter blob:none
	fi
	echo "==> fetching $BASE_TAG (filter=blob:none, no other refs)"
	git_in fetch --filter=blob:none --no-tags origin \
		"refs/tags/${BASE_TAG}:refs/tags/${BASE_TAG}"
	echo "==> fetching $HEAD_TAG (filter=blob:none, incremental)"
	git_in fetch --filter=blob:none --no-tags origin \
		"refs/tags/${HEAD_TAG}:refs/tags/${HEAD_TAG}"
	echo "==> done. Sizes:"
	du -sh "$KERNEL_GIT"
	git_in rev-parse "${BASE_TAG}^{commit}" "${HEAD_TAG}^{commit}"
}

cmd_fetch_tag() {
	local tag="${1:?tag required}"
	ensure_clone
	git_in fetch --filter=blob:none --no-tags origin \
		"refs/tags/${tag}:refs/tags/${tag}"
}

cmd_inventory() {
	inventory_paths
}

cmd_commits() {
	local path="${1:?path required}"
	ensure_clone
	ensure_tag "$BASE_TAG"
	ensure_tag "$HEAD_TAG"
	git_in log --follow --reverse \
		--pretty=tformat:'%H%x09%ad%x09%an <%ae>%x09%s' \
		--date=short \
		"${BASE_TAG}..${HEAD_TAG}" -- "$path"
}

cmd_stat() {
	local path="${1:?path required}"
	ensure_clone
	ensure_tag "$BASE_TAG"
	ensure_tag "$HEAD_TAG"
	git_in log --follow --reverse \
		--pretty=tformat:'commit %H%n  date    %ad%n  author  %an <%ae>%n  subject %s' \
		--date=short --stat \
		"${BASE_TAG}..${HEAD_TAG}" -- "$path"
}

cmd_renames() {
	local path="${1:?path required}"
	ensure_clone
	ensure_tag "$BASE_TAG"
	ensure_tag "$HEAD_TAG"
	git_in log --follow --reverse --name-status \
		--pretty=tformat:'%H %ad %s' --date=short \
		"${BASE_TAG}..${HEAD_TAG}" -- "$path" |
		awk '
			/^[0-9a-f]{40} / { commit=$0; next }
			/^R[0-9]*\t/   { print commit; print "  " $0 }
		'
}

cmd_show() {
	local sha="${1:?sha required}" path="${2:?path required}"
	ensure_clone
	git_in show --pretty=fuller "$sha" -- "$path"
}

cmd_summary() {
	local path="${1:?path required}"
	ensure_clone
	ensure_tag "$BASE_TAG"
	ensure_tag "$HEAD_TAG"
	git_in log --follow --reverse --shortstat \
		--pretty=tformat:'%h %ad %s' --date=short \
		"${BASE_TAG}..${HEAD_TAG}" -- "$path" |
		awk '
			/^[0-9a-f]{7,} / { line=$0; getline blank; getline stat; print line "  | " stat; next }
		'
}

cmd_paths_at() {
	local tag="${1:?tag required}" pattern="${2:?regex required}"
	ensure_clone
	ensure_tag "$tag"
	git_in ls-tree -r --name-only "$tag" | grep -E "$pattern" || true
}

slug() {
	# Replace separators that confuse filesystem usage; keep readable.
	echo "$1" | sed -e 's|/|__|g'
}

cmd_harvest() {
	ensure_clone
	ensure_tag "$BASE_TAG"
	ensure_tag "$HEAD_TAG"
	mkdir -p "$OUT_DIR"
	local -a paths=()
	if (($# > 0)); then
		paths=("$@")
	else
		while IFS= read -r p; do paths+=("$p"); done < <(inventory_paths)
	fi
	local p slug_p out_dir commits commit sha date author subject
	for p in "${paths[@]}"; do
		slug_p="$(slug "$p")"
		out_dir="${OUT_DIR}/${slug_p}"
		mkdir -p "$out_dir"
		echo "==> $p"
		echo "$p" >"${out_dir}/PATH"
		echo "${BASE_TAG}..${HEAD_TAG}" >"${out_dir}/RANGE"

		commits="$(cmd_commits "$p")"
		printf '%s\n' "$commits" >"${out_dir}/commits.tsv"

		cmd_renames "$p" >"${out_dir}/renames.txt" || true
		cmd_summary "$p" >"${out_dir}/summary.txt" || true

		# Per-commit diffs (file-scoped, full).
		: >"${out_dir}/all-diffs.patch"
		while IFS=$'\t' read -r sha date author subject; do
			[[ -z "$sha" ]] && continue
			{
				echo "----- BEGIN COMMIT ${sha} -----"
				echo "Date:    $date"
				echo "Author:  $author"
				echo "Subject: $subject"
				echo
				git_in show --pretty='format:%H %an <%ae> %ad %s%n%n%b%n' \
					--date=iso-strict "$sha" -- "$p" || true
				echo
				echo "----- END COMMIT ${sha} -----"
				echo
			} >>"${out_dir}/all-diffs.patch"
		done <<<"$commits"

		# Snapshots of file at base/head for direct diffing & reference.
		git_in show "${BASE_TAG}:$p" >"${out_dir}/at-${BASE_TAG}" 2>/dev/null ||
			echo "(absent at ${BASE_TAG})" >"${out_dir}/at-${BASE_TAG}"
		git_in show "${HEAD_TAG}:$p" >"${out_dir}/at-${HEAD_TAG}" 2>/dev/null ||
			echo "(absent at ${HEAD_TAG})" >"${out_dir}/at-${HEAD_TAG}"

		# Net diff (base->head) for the whole file.
		git_in diff "${BASE_TAG}..${HEAD_TAG}" -- "$p" \
			>"${out_dir}/net-diff.patch" 2>/dev/null || true
	done
	echo "==> output under $OUT_DIR"
}

main() {
	case "${1:-}" in
	setup)         shift; cmd_setup ;;
	fetch-tag)     shift; cmd_fetch_tag "$@" ;;
	inventory)     shift; cmd_inventory ;;
	commits)       shift; cmd_commits "$@" ;;
	stat)          shift; cmd_stat "$@" ;;
	renames)       shift; cmd_renames "$@" ;;
	show)          shift; cmd_show "$@" ;;
	harvest)       shift; cmd_harvest "$@" ;;
	summary)       shift; cmd_summary "$@" ;;
	paths-at)      shift; cmd_paths_at "$@" ;;
	-h|help|"")
		usage
		[[ "${1:-}" == "" ]] && exit 1 || exit 0
		;;
	*)
		echo "unknown command: $1" >&2
		usage
		exit 1
		;;
	esac
}

main "$@"
