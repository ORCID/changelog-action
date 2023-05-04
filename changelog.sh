#!/usr/bin/env bash
# Generate a Markdown change log of pull requests from commits between two tags
# Author: Russell Heimlich
# URL: https://gist.github.com/kingkool68/09a201a35c83e43af08fcbacee5c315a
# Modified to include conventional commits and tag filtering


set -o errexit -o errtrace -o nounset -o functrace -o pipefail
shopt -s inherit_errexit 2>/dev/null || true

trap 'echo "exit_code $? line $LINENO linecallfunc $BASH_COMMAND"' ERR

#
# defaults
#

NAME=changelog.sh
USER=$(whoami)
CCOMMIT_TYPES='fix feature refactor'
CHANGELOG_PLAIN=/tmp/CHANGELOG.md.plain.$USER
CHANGELOG_GITHUB=/tmp/CHANGELOG.md.github.$USER
CHANGELOG_LOCAL=./CHANGELOG.md
slack_channel=keyevent-dev

#
# functions
#

usage(){
I_USAGE="

  Usage:  ${NAME} [OPTIONS]

  Description:
      This script will scan the git commit logs between the <latest_tag> <previous_tag>
      and create a markdown format changelog https://keepachangelog.com/en/1.0.0/

      Github pr merges will be isolated and translated into clickable urls
      Conventional commits will be extracted and categorized by their types
      Other commits will be ignored

      If no tag is provided a tag 'unreleased' will be used and only the expected output will be shown

      The output will be:-

        $CHANGELOG_GITHUB
        $CHANGELOG_PLAIN which is concatinated onto ./CHANGELOG.md

  Options:
      -p | --prefix       ) set the version prefix ($prefix)
      -t | --tag       ) tag to create
      -r | --release   ) perform github release
      -dr | --delete_release   ) delete a release if it exists first

"
  echo "$I_USAGE"
  exit
}

sk-ccommit-cleanup(){
  for commit_type in $CCOMMIT_TYPES;do
    if [[ -f /tmp/${commit_type}.$USER ]];then
      rm /tmp/${commit_type}.$USER
    fi
  done
}

sk-ccommit-builder(){
  local target_file=${1:-/tmp/blar}
  for commit_type in $CCOMMIT_TYPES;do
    if [[ -f /tmp/${commit_type}.$USER ]];then
      echo "" >> $target_file
      upcase_commit_type=$(tr '[:lower:]' '[:upper:]' <<< ${commit_type:0:1})${commit_type:1}
      echo "### $upcase_commit_type" >> $target_file
      echo "" >> $target_file
      cat /tmp/$commit_type.$USER >> $target_file
    fi
  done
}

sk-ccommit-unifier(){
  local commit_type=${1:-fix}
  case $commit_type in
    bug) echo "fix" ;;
    bugfix) echo "fix" ;;
    feat) echo "feature" ;;
    feature) echo "feature" ;;
    fix) echo "fix" ;;
    refactor) echo "refactor";;
    *) echo "excluded" ;;
  esac
}



#
# args
#
release=0 delete_release=0 tag=unreleased prefix_search_arg='v' prefix='v'

while :
do
  case ${1-default} in
      --*help|-h          ) usage ; exit 0 ;;
      --man               ) usage ; exit 0 ;;
      -v | --verbose      ) VERBOSE=$(($VERBOSE+1)) ; shift ;;
      --debug             ) DEBUG=1; [ "$VERBOSE" == "0" ] && VERBOSE=1 ; shift;;
      --dry-run           ) dry_run=1 ; shift ;;
      -p | --prefix       ) prefix=$2 ; prefix_search_arg="$2" ;shift 2 ;;
      -t | --tag       ) tag=$2 ;shift 2 ;;
      -r | --release   ) release=1 ;shift ;;
      -dr | --delete_release   ) delete_release=1 ;shift ;;
      -s | --slack_channel   ) slack_channel=$2 ;shift 2 ;;
      --) shift ; break ;;
      -*) echo "WARN: Unknown option (ignored): $1" >&2 ; shift ;;
      *)  break ;;
    esac
done

sk-ccommit-cleanup

if printenv GITHUB_REF_NAME;then
  git config --global user.email "actions@github.com"
  git config --global user.name "github actions"
  repository_url="https://github.com/$GITHUB_REPOSITORY"
else
  repository_url="https://$(git config --get remote.origin.url | perl -ne '/(github.com.*).git/ && print $1' | perl -pe 's/:/\//g' )"
fi

# Get a list of all tags in reverse order
git_tags=`git -c 'versionsort.suffix=-' ls-remote --exit-code --refs --sort='-version:refname' --tags origin '*.*.*' | grep "$prefix_search_arg" | cut -d '/' -f 3`

# fetch all the tags when they don't exist on github actions checkout
# and we need to search for all commits in the git log from the previous tag .. latest commit
git fetch --all > /dev/null 2>&1

# if tag is found we use it as the latest
if echo "$git_tags" | grep -q $tag;then
  previous_tag=$(echo "$git_tags" | grep -A1 $tag | tail -n1)
  latest_tag=$tag

  # Get a log of commits that occured between two tags
  # We only get the commit hash so we don't have to deal with a bunch of ugly parsing
  # See Pretty format placeholders at https://git-scm.com/docs/pretty-formats
  commits=$(git log $previous_tag..$latest_tag --pretty=format:"%H")
else
  echo "tag $tag doesn't exist"
  latest_tag=$tag
  # Make the tags an array
  tags=($git_tags)
  previous_tag=${tags[0]}
  commits=$(git log $previous_tag..HEAD --pretty=format:"%H")
fi

echo "latest_tag: $latest_tag"
echo "previous_tag $previous_tag"

# Store our changelog in a variable to be saved to a file at the end
markdown="[Full Changelog]($repository_url/compare/$previous_tag...$latest_tag)"
markdown+='\n'

# Loop over each commit and look for merged pull requests
for commit in $commits; do
	# Get the subject of the current commit
	subject=$(git log -1 ${commit} --pretty=format:"%s")

	# If the subject contains "Merge pull request #xxxxx" then it is deemed a pull request
	if pull_request=$( grep -Eo "Merge pull request #[[:digit:]]+" <<< "$subject" );then
		# Perform a substring operation so we're left with just the digits of the pull request
		pull_num=${pull_request#"Merge pull request #"}
		# AUTHOR_NAME=$(git log -1 ${commit} --pretty=format:"%an")
		# AUTHOR_EMAIL=$(git log -1 ${commit} --pretty=format:"%ae")

		# Get the body of the commit
		body=$(git log -1 ${commit} --pretty=format:"%b")
		markdown+='\n'
		markdown+=" - [#$pull_num]($repository_url/pull/$pull_num): $body"
	fi

	if grep -qEo "[[:alpha:]]+:" <<< "$subject"; then
    commit_type=$(echo "$subject" | perl -ne '/(\w+):/ && print $1')
    commit_subject_no_type=$(echo "$subject" | perl -ne '/(\w+):(.*)/ && print $2')
    commit_type_unified=$(sk-ccommit-unifier $commit_type)
    if [[ "$commit_type_unified" = 'excluded' ]];then
      continue
    fi
    echo "- $commit_subject_no_type" >> /tmp/${commit_type_unified}.$USER
	fi

done


# Save our markdown to a file
echo -e $markdown > $CHANGELOG_GITHUB
echo "## $latest_tag - $(date +%F)" > $CHANGELOG_PLAIN
echo -e $markdown >> $CHANGELOG_PLAIN

sk-ccommit-builder $CHANGELOG_PLAIN
sk-ccommit-builder $CHANGELOG_GITHUB
echo "" >> $CHANGELOG_PLAIN

echo ""
echo "--------------- NEW CHANGELOG ENTRY ------------------"

cat $CHANGELOG_PLAIN

echo "------------------------------------------------------"
echo ""

if [[ "$tag" = 'unreleased' ]];then
  echo "tag is unreleased so exiting, not updating ./CHANGELOG.md, tagging or releasing to github."
  exit
fi

if [[ ! -f CHANGELOG.md ]];then
  touch CHANGELOG.md
fi

if grep -q $latest_tag CHANGELOG.md;then
  echo "tag already exists in CHANGELOG.md"
else
  # add our new changelog entry to the top of our changelog
  cp CHANGELOG.md $CHANGELOG_PLAIN.old
  cp $CHANGELOG_PLAIN CHANGELOG.md
  cat $CHANGELOG_PLAIN.old >> CHANGELOG.md

  git add CHANGELOG.md
  git commit -m "$latest_tag changelog update"
  git push origin
fi

echo "tagging repo with $tag"
if git tag | grep -q $tag;then
  echo "tag $tag exists skipping tagging"
else
  git tag $tag
  git push origin $tag
fi

if [[ "$delete_release" -eq 1 ]];then
  echo gh release delete $latest_tag --yes
  if gh release delete $latest_tag --yes >/dev/null;then
    echo "no release found"
  fi
fi

if [[ "$release" -eq 1 ]];then
  echo gh release create $latest_tag -F $CHANGELOG_GITHUB
  gh release create $latest_tag -F $CHANGELOG_GITHUB
fi

if printenv SLACKTEE_TOKEN > /dev/null ;then

  if [[ ! -f /tmp/slacktee.sh ]];then
    wget -q https://raw.githubusercontent.com/coursehero/slacktee/222129128de4bdcd83bc23138b4fafaf60385b9a/slacktee.sh -O /tmp/slacktee.sh
    chmod +x /tmp/slacktee.sh
  fi

  echo "$repository_url/releases/tag/$latest_tag" | /tmp/slacktee.sh -p -c $slack_channel --icon "https://avatars.githubusercontent.com/u/65916846?s=48&v=4"
  cat $CHANGELOG_PLAIN | /tmp/slacktee.sh -q -c $slack_channel --icon "https://avatars.githubusercontent.com/u/65916846?s=48&v=4"

fi
