# frozen_string_literal: true

require "test_helper"

class CardLinksTest < Minitest::Test
  CL = AgentsKanban::CardLinks
  REPO = "https://github.com/acme/shop"
  CARDS = { 4 => "acme/shop", 6 => "acme/shop", 10 => "acme/shop", 197 => "acme/shop", 77 => "o/other" }.freeze

  # The host's git port (CardLinks runs no git): branches, the default ref and which ref has a file, from a table.
  # files: {file => [refs that have it]}; asked records every files_at call.
  class FakeGit
    attr_reader :asked

    def initialize(branches: [], default: "master", files: {})
      @branches = branches.to_set
      @default = default
      @files = files
      @asked = []
    end

    def branches(_project) = @branches
    def default_ref(_project) = @default

    def files_at(project, refs, files)
      @asked << [project[:slug], refs, files]
      files.each_with_object({}) { |f, h| (r = refs.find { |x| @files.fetch(f, []).include?(x) }) && h[f] = r }
    end
  end

  NOGIT = FakeGit.new

  def refs(repo: REPO, pr_url: nil, activity: [148, 197, 200], cards: CARDS)
    CL::Refs.new(repo: repo, pr_url: pr_url, activity_ids: activity.to_set, slug: "acme/shop",
                 card_slugs: ->(ids) { cards.slice(*ids) },
                 card_path: ->(slug, id) { "/projects/#{slug}?tab=board&card=#{id}" })
  end

  def chips(html)
    html.scan(%r{<a class="gh-ref gh-(\w+)" href="([^"]+)"[^>]*>.*?<span>([^<]*)</span></a>})
        .map { |k, u, s| [k, CGI.unescapeHTML(u), s] }
  end

  def link(html, r = refs) = chips(CL.linkify(html, [], refs: r))

  def test_repo_existing_branches_sites_urls_and_commits
    project = { slug: "acme/site", path: "/checkouts/site", remote: "git@github.com:acme/shop.git" }
    card = { title: "main belongs to shop.example.com and production to kamal; make main + shop branch", notes: "see https://ci.example.com/job/1. and operator@example.com" }
    commits = ->(shas) { shas.include?("abcdef12") ? { "abcdef12" => { sha: "abcdef1234", subject: "fix radar" } } : {} }
    git = FakeGit.new(branches: %w[master production])
    by = CL.build(card, ["merged in abcdef12"], project, commits: commits, git: git).group_by { |l| l[:kind] }
    assert_equal "https://github.com/acme/shop", by["repo"].first[:url]
    assert_equal ["production"], by["branch"].map { |l| l[:label] }
    assert_equal ["https://shop.example.com"], by["site"].map { |l| l[:url] }
    assert_equal ["https://ci.example.com/job/1"], by["url"].map { |l| l[:url] }
    assert_equal "https://github.com/acme/shop/commit/abcdef1234", by["commit"].first[:url]
    assert_equal [["site", "https://example.com"]], CL.build({ title: "deploy example.com", notes: "" }, [], { slug: "x", path: "/nope", remote: nil }, commits: ->(_) { {} }, git: NOGIT).map { |l| [l[:kind], l[:url]] }
    assert_nil CL::Github.repo_url("https://gitlab.com/o/r.git")
    assert_equal "https://github.com/o/r/commit/abc", CL::Github.commit_url("ssh://git@github.com/o/r", "abc")
  end

  def test_files_on_named_branch_pr_lists_and_handoff_links
    project = { slug: "p", path: "/checkouts/p", remote: "https://github.com/o/r.git" }
    card = { title: "t", notes: "", pr_url: "https://github.com/o/r/pull/100", ci_url: "https://jenkins.example.com/job/shop/job/main/42/" }
    text = "on chore/cleanup: Runbook docs/runbook.md, pin config/x.rb:16. Open PRs: #93,84, and #7"
    git = FakeGit.new(branches: %w[master chore/cleanup], files: { "docs/runbook.md" => ["chore/cleanup"] })
    links = CL.build(card, [text], project, commits: ->(_) { {} }, git: git)
    by = links.group_by { |l| l[:kind] }
    # one port call for every path the text names, the branches it names first, HEAD last
    assert_equal [["p", %w[chore/cleanup HEAD], %w[docs/runbook.md config/x.rb]]], git.asked
    assert_equal [["repo", "p"], ["pr", "#100"], ["ci", "jenkins · shop / main #42"]],
                 links.first(3).map { |l| [l[:kind], l[:label]] }
    assert_equal ["https://github.com/o/r/blob/chore/cleanup/docs/runbook.md"], by["file"].map { |l| l[:url] }
    assert_equal %w[#100 #93 #84 #7], by["pr"].map { |l| l[:label] }
  end

  # a file on HEAD links to the checked-out branch's name; ".." paths are never asked of the port
  def test_file_on_head_uses_the_default_ref_and_dot_dot_is_never_asked
    project = { slug: "p", path: "/checkouts/p", remote: "https://github.com/o/r.git" }
    git = FakeGit.new(default: "trunk", files: { "lib/a.rb" => ["HEAD"] })
    links = CL.build({ title: "see lib/a.rb and ../etc/passwd.txt", notes: "" }, [], project, commits: ->(_) { {} }, git: git)
    assert_equal ["https://github.com/o/r/blob/trunk/lib/a.rb"], links.select { |l| l[:kind] == "file" }.map { |l| l[:url] }
    assert(git.asked.all? { |_, _, files| files.none? { |f| f.include?("..") } })
  end

  # the port is required: no host git means no build, never a silent reader of its own
  def test_build_without_a_git_port_is_refused
    assert_raises(ArgumentError) { CL.build({ title: "x", notes: "" }, [], nil, commits: ->(_) { {} }) }
    refute_respond_to CL, :branches
    refute_respond_to CL, :file_at?
    refute CL.const_defined?(:GIT_ENV)
  end

  # a port that cannot read the checkout raises; build passes the error on (the host shows it), never a guess
  def test_a_failing_port_raises_through_build
    bad = Object.new
    def bad.branches(_) = raise(IOError, "checkout unreadable")
    project = { slug: "p", path: "/checkouts/p", remote: "https://github.com/o/r.git" }
    e = assert_raises(IOError) { CL.build({ title: "main", notes: "" }, [], project, commits: ->(_) { {} }, git: bad) }
    assert_equal "checkout unreadable", e.message
  end

  def test_ci_label_unescapes_a_multibranch_job_name
    assert_equal "jenkins · busyyaks / card/166-approve-from-workflow #1",
                 CL.ci_label("https://jenkins.example.com/job/busyyaks/job/card%252F166-approve-from-workflow/1/")
    assert_equal "jenkins · shop / main #42", CL.ci_label("https://jenkins.example.com/job/shop/job/main/42/")
    assert_equal "jenkins.example.com", CL.ci_label("https://jenkins.example.com/view/x")
    assert_equal "jenkins · żó/ó #1", CL.ci_label("https://j/job/żó%252F%C3%B3/1/")   # raw UTF-8 beside escapes
    assert_equal "jenkins · a%41b #1", CL.ci_label("https://j/job/a%252541b/1/")       # never decoded a third time
  end

  def test_linkify_code_spans_paths_domains_prs_but_not_plain_branch_words_or_code_blocks
    links = [
      { kind: "branch", label: "production", url: "https://g/tree/production" },
      { kind: "branch", label: "chore/x", url: "https://g/tree/chore/x" },
      { kind: "file", label: "docs/run.md", url: "https://g/blob/chore/x/docs/run.md" },
      { kind: "site", label: "site.example", url: "https://site.example" },
      { kind: "pr", label: "#93", url: "https://g/pull/93" },
      { kind: "commit", label: "abc1234 fix", url: "https://g/commit/abc1234" },
    ]
    html = "<p>on <code>chore/x</code> see docs/run.md and site.example, PR #93, fix abc1234; production stays. " \
           "<code>production</code></p><pre><code>docs/run.md</code></pre>"
    out = CL.linkify(html, links, refs: refs(repo: "https://g"))
    anchor = '<a class="gh-ref gh-branch" href="https://g/tree/chore/x" target="_blank" rel="noopener">'
    assert_match %r{#{anchor}<svg[^>]*>.*?</svg><code>chore/x</code></a>}, out
    assert_includes out, %(href="https://site.example")
    assert_includes out, %(href="https://g/pull/93")
    assert_includes out, %(<code class="gh-sha">abc1234</code><span class="gh-subj">fix</span>)
    assert_includes out, "; production stays.", "a plain-text branch word stays a word"
    assert_includes out, "<pre><code>docs/run.md</code></pre>", "code blocks untouched"
  end

  def test_hash_references_resolve_against_this_card_and_board
    assert_equal [["comment", "#a-148", "#148"], ["comment", "#a-197", "#197"]], link("<p>table in #148. Waiting on #197.</p>")
    assert_equal [["pr", "#{REPO}/pull/12", "#12"], ["pr", "#{REPO}/pull/13", "13"], ["pr", "#{REPO}/pull/42", "42"]],
                 link("<p>PR #12, PR 13, pull/42</p>")
    assert_equal [], link("<p>PR #148 and PR-1 secrets</p>", refs(repo: nil)), "no repo → no PR URL to build"
    assert_equal [["card", "/projects/acme/shop?tab=board&card=6", "#6"]], link("<p>PR-1…PR-6; listed in (#6)</p>")
    r = refs(pr_url: "https://github.com/acme/shop/pull/100", activity: [98, 100])
    assert_equal [["pr", "https://github.com/acme/shop/pull/100", "#100"], ["comment", "#a-98", "#98"]],
                 link("<p>pre-#100 main; comment #98</p>", r)
    assert_equal [["card", "/projects/o/other?tab=board&card=77", "#77"]], link("<p>Card #77</p>")
    assert_equal [], link("<p>#77 is on another board, #555 is nothing</p>")
    html = %(<p><a href="https://x">PR #12</a> <code>#148</code> it&#39;s</p><pre><code>#148 PR #12</code></pre>)
    assert_equal html, CL.linkify(html, [], refs: refs)
  end

  # the work's PRs live on the handoff pr_url's repo (a private *_local repo, not origin)
  def test_pr_references_follow_the_handoff_repo_and_full_urls_are_never_rewritten
    local = "https://github.com/o/widgets_local"
    r = refs(repo: "https://github.com/o/widgets", pr_url: "#{local}/pull/1", activity: [])
    assert_equal [["pr", "#{local}/pull/1", "#1"], ["pr", "#{local}/pull/2", "2"], ["pr", "#{local}/pull/3", "3"]],
                 link("<p>PR #1, PR 2, pull/3</p>", r)
    # a full PR URL — autolinked or bare text — stays as written
    html = %(<p><a href="#{local}/pull/1">#{local}/pull/1</a> and github.com/o/other/pull/7</p>)
    assert_equal html, CL.linkify(html, [], refs: r)
    # build: the PR chips of the text go to that repo too
    card = { title: "see PR #2", notes: "", pr_url: "#{local}/pull/1" }
    project = { slug: "o/widgets", path: "/checkouts/widgets", remote: "git@github.com:o/widgets.git" }
    links = CL.build(card, [], project, commits: ->(_) { {} }, git: NOGIT)
    assert_equal ["#{local}/pull/1", "#{local}/pull/2"], links.select { |l| l[:kind] == "pr" }.map { |l| l[:url] }
    assert_nil CL.pr_repo("https://jenkins.example/job/x/1/")
  end
end

class MarkdownTest < Minitest::Test
  def md = KanbanTest.markdown(KanbanTest.config)

  def test_mentions_inline_raw_html_dropped
    html = md.card("hi @tl_g_r and @bob.\n\n`@nope` mail me@x.com [@link](https://x.y)\n\n<script>alert(1)</script>")
    assert_includes html, %(<span class="mention">@tl_g_r</span>)
    assert_includes html, %(<span class="mention">@bob</span>.)
    refute_includes html, %(<span class="mention">@nope</span>)
    refute_includes html, %(<span class="mention">@x.com)
    refute_includes html, "<script>"
    assert_equal "a <strong>b</strong>", md.inline("a **b**")
    assert_includes md.inline("- a\n- b"), "<ul>"
    assert_includes md.card("- [ ] task"), "checkbox"
  end

  # a Jenkins multibranch URL keeps its double-encoded %252F through rendering and linking
  def test_jenkins_url_with_double_encoded_slash_survives
    url = "https://ci.example.com/job/widgets_local/job/card%252F63-dev-workflow/1/"
    html = md.card("CI: #{url}")
    assert_includes html, %(href="#{url}")
    links = AgentsKanban::CardLinks.build({ title: "", notes: "", ci_url: url }, ["CI: #{url}"], nil, commits: ->(_) { {} },
                                                                                                 git: CardLinksTest::NOGIT)
    out = AgentsKanban::CardLinks.linkify(html, links)
    assert_includes out, %(href="#{url}")
    refute_includes out, "%2F63"
  end

  def test_slack_fences_and_dense_tables
    html = md.card("```Added to the board, waiting in\n#197\n.``` not such issue")
    assert_includes html, "Added to the board, waiting in"
    assert_includes html, "<p>not such issue</p>"
    refute_includes html, 'lang="Added"'
    assert_includes md.card("```ruby\nputs 1\n```"), '<pre lang="ruby"><code>puts 1'
    assert_includes md.card("```one line quote``` ok"), "<code>one line quote</code> ok"
    table = ->(cell) { "| a | b |\n|---|---|\n| x | #{cell} |\n" }
    assert_includes md.card(table.("short")), "<table>"
    assert_includes md.card(table.("word " * 200)), '<table class="md-dense">'
    assert_includes md.card(table.("word " * 500)), '<table class="md-denser">'
  end
end
