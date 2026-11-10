// Engine CI: every pushed branch runs `scripts/ci/test.sh all` — RuboCop + ShellCheck, the Ruby suite on SQLite and on
// Postgres, the React port's tsc + vitest, the dependency audit (bundle-audit + npm audit) and gitleaks over the full
// history, at once — and reports ONE GitHub commit status, context `jenkins/ci`,
// whose link is this build. A PR shows its head branch's status.
//
// Jenkins side: a multibranch job reading this file from SCM (this repository's own branches and pull requests; a
// fork's pull request is GitHub Actions', never here), an agent with a Docker CLI on a daemon it may start containers
// on — chosen by the controller's
// global env AGENTS_KANBAN_CI_AGENT_LABEL (unset → the build fails; docs/CI-JENKINS.md § Isolation: which agents, why never
// the controller) — and the Secret Text credential `github-pat` (a token allowed to post statuses on this repo).
// The repo the status goes to is read from the checkout's origin remote — nothing about the deployment is written here.
//
// README badges (coverage · branches · tests): after the gates pass on the repository's DEFAULT branch (asked from
// GitHub, never a card/PR branch), scripts/ci/badges reads the Ruby + vitest summaries from this build's log and
// PATCHes shields.io endpoint JSON into the public gist BADGE_GIST_ID (the one the README's badge URLs read) with the
// Secret Text credential BADGE_CREDENTIAL (a token that may write gists and nothing else: a fine-grained PAT with the
// account permission Gists = read/write, stored in THIS job's folder credential store — the other jobs on the
// controller cannot name it). A fork points these two at its own gist and credential. An update that fails fails the
// build, and the status then says the gates passed.
//
// Tokens never appear on a command line: this file runs no curl; scripts/ci/github and scripts/ci/badges call GitHub
// through scripts/ci/lib/github-api.sh, which feeds the Authorization header through a pipe (argv shows /dev/fd/N) —
// /proc/*/cmdline (ps) is readable by every uid. The token still sits in the step's env
// (/proc/*/environ: same uid only), which the other executor's build shares: the job, not the branch, is the boundary.
// Credential variables are only ever referenced from single-quoted shell, never Groovy-interpolated (that would write
// them into the build's flow-node XML).

pipeline {
  // `env` here is the controller's global env (Jenkinsfile code cannot set it before this point). A label that is unset,
  // or that the controller's job restrictions do not let this job run on, never builds: it fails or waits in the queue.
  agent { label requiredAgentLabel() }

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 30, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  triggers {
    githubPush()
  }

  environment {
    BADGE_GIST_ID = 'c8ad2b945aa9cbc99eddd0b28e98e400'
    BADGE_CREDENTIAL = 'badge-gist-token'
  }

  stages {
    stage('Checkout') {
      steps {
        script {
          // A fork's pull request is GitHub Actions' (disposable runners), never this Jenkins: its code would run on
          // this host. Jenkins builds the default branch and pull requests from this repository's own branches. Were
          // fork PR discovery ever switched on, an untrusted fork PR runs the default branch's copy of this file, so
          // this refusal holds there.
          if (env.CHANGE_FORK) {
            error("pull request ${env.CHANGE_ID} from fork ${env.CHANGE_FORK} refused: forks are built by GitHub Actions only")
          }
        }
        checkout scm
        script {
          env.GIT_SHA = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
          env.GH_REPO = sh(returnStdout: true, script: '''
            url=$(git config --get remote.origin.url)
            repo=$(printf '%s' "$url" | sed -nE 's#^(https://|git@|ssh://git@)github\\.com[:/]([^/]+/[^/]+)$#\\2#p' | sed 's#\\.git$##')
            [ -n "$repo" ] || { echo "origin $url is not a GitHub repo — nowhere to post the status" >&2; exit 1; }
            printf '%s' "$repo"
          ''').trim()
          env.DEFAULT_BRANCH = defaultBranch()
          echo "Building ${env.GH_REPO}@${env.GIT_SHA} (${env.BRANCH_NAME}; default branch ${env.DEFAULT_BRANCH})"
          sh 'rm -rf "$WORKSPACE_TMP/ci-logs" "$WORKSPACE_TMP/badges"'
        }
        notifyGitHub('pending', 'lint + Ruby (SQLite + Postgres) + React + audit + secrets running')
      }
    }

    stage('Gates') {
      steps { gate('all') }
      post { success { script { env.GATES_PASSED = 'true' } } }
    }

    stage('Badges') {
      when { expression { env.BRANCH_NAME == env.DEFAULT_BRANCH && !env.CHANGE_ID } }
      steps {
        withCredentials([string(credentialsId: env.BADGE_CREDENTIAL, variable: 'GIST_TOKEN')]) {
          sh '''#!/usr/bin/env bash
            set -euo pipefail
            scripts/ci/badges render "$WORKSPACE_TMP/badges" "$WORKSPACE_TMP/ci-logs/all.log"
            scripts/ci/badges publish "$BADGE_GIST_ID" "$WORKSPACE_TMP/badges"
          '''
        }
      }
    }
  }

  post {
    success  { notifyGitHub('success', 'lint + Ruby (SQLite + Postgres) + React + audit + secrets passed') }
    failure  { notifyGitHub('failure', env.GATES_PASSED ? 'Gates passed; README badge update failed — see the build log' : 'CI failed — see the build log') }
    unstable { notifyGitHub('failure', 'CI unstable') }
    aborted  { notifyGitHub('error', 'Build aborted') }
    cleanup  { cleanWs() }
  }
}

// The agent label the controller sets for this job (global env AGENTS_KANBAN_CI_AGENT_LABEL). No default: an unset label
// would let `agent any` land the build on the controller itself.
String requiredAgentLabel() {
  String label = env.AGENTS_KANBAN_CI_AGENT_LABEL
  if (!label?.trim()) {
    error('AGENTS_KANBAN_CI_AGENT_LABEL is not set on this Jenkins (Manage Jenkins → System → Global properties) — see docs/CI-JENKINS.md § Isolation')
  }
  return label.trim()
}

// One gate, its output also kept in $WORKSPACE_TMP/ci-logs/<suite>.log (outside the checkout) for the badges.
void gate(String suite) {
  sh """#!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "\$WORKSPACE_TMP/ci-logs"
    scripts/ci/test.sh ${suite} 2>&1 | tee "\$WORKSPACE_TMP/ci-logs/${suite}.log"
  """
}

// GitHub's default branch for this repo (scripts/ci/github default-branch). Unreadable fails the build.
String defaultBranch() {
  withCredentials([string(credentialsId: 'github-pat', variable: 'GH_TOKEN')]) {
    return sh(returnStdout: true, script: 'scripts/ci/github default-branch').trim()
  }
}

// The jenkins/ci commit status (scripts/ci/github status). A status that cannot be posted FAILS the build: a green
// build GitHub never heard about would look exactly like a PR with no CI. State and text reach the script as env, so
// nothing Groovy-interpolates into the shell.
void notifyGitHub(String state, String description) {
  if (!env.GIT_SHA || !env.GH_REPO) { error("no commit/repo known yet — cannot post GitHub status ${state}") }
  withCredentials([string(credentialsId: 'github-pat', variable: 'GH_TOKEN')]) {
    withEnv(["GH_STATE=${state}", "GH_DESCRIPTION=${description}"]) {
      sh 'scripts/ci/github status "$GH_STATE" "$GH_DESCRIPTION"'
    }
  }
}
