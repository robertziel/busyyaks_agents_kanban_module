# frozen_string_literal: true

require "cgi"
require "erb"
require "set"

module AgentsKanban
  # The links a card points at, so it can be checked in one click: the repo, every branch it names that the repo
  # really has (→ GitHub tree), every URL and bare domain it mentions (→ https), every SHA that is a known commit.
  # Read from the card's title, description and comments. A branch it names that does not exist is not linked.
  # `project` is {slug:, path:, remote:} from the host (path = a git checkout; nil = no git lookups).
  # The engine runs no git itself: what the checkout holds comes from the host's `git:` port (required, no default) —
  #   git.branches(project)                → Set of branch names (local + remote-tracking with the remote dropped)
  #   git.default_ref(project)             → the checked-out branch's name, "HEAD" when detached / unborn
  #   git.files_at(project, refs, files)   → {file => the first of refs that has it}; a file no ref has is left out
  # A port that cannot read the checkout raises; the card view shows the error, never a guess.
  module CardLinks
    TLD = %w[pl com co io ai dev net org app eu de uk us me sh cloud site tech xyz info biz].freeze
    DOMAIN = /(?<![@\w.\/-])((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:#{TLD.join('|')}))(?![\w-]|\.\w)/i
    URL = %r{https?://[^\s<>()\[\]"'`]+}i
    SHA = /\b[0-9a-f]{7,40}\b/
    WORD = %r{[A-Za-z0-9][A-Za-z0-9._/-]{1,100}}
    PATH = %r{(?<![\w/.-])(?:[\w.-]+/)+[\w.-]+\.[A-Za-z0-9]{1,8}(?::\d+)?(?![\w/])}
    # #N references. Only what the text says is linked, never a guess:
    #   "PR #12", "PR 12", "PRs #93, 84", "pull/12"  → GitHub PR (kw: pr)
    #   "comment #148", "event #117 and #118"        → that activity entry on this card (kw: comment)
    #   "card #10"                                    → that kanban card (kw: card)
    #   a bare "#N"                                   → Refs#resolve: the handoff PR's number, else an activity id on
    #                                                   this card, else a card on this board, else plain text
    # Plan steps are not PR numbers: "PR-1" (no space), "**Proposed PRs:** 1 secrets" (no # after a colon / emphasis).
    # Without a # the number must follow the keyword after plain spaces ("PR 12").
    REF_SEP = /[ \t*_]*:?[ \t*_]*#|[ \t]+/
    REF_REST = %r{(?:(?:[ \t]*(?:,(?:[ \t]*and\b)?|&|/|\band\b|–|—)[ \t]*#?|-#)\d{1,6})*}
    REF_KW = /PRs?|pull[ \t]+requests?|comments?|events?|cards?/.source
    REF_LIST = /(?:#{REF_SEP})(?<list>\d{1,6}#{REF_REST})/.source
    REF = %r{(?:\b(?<kw>#{REF_KW})#{REF_LIST}|(?<![\w/])pull/(?<pull>\d{1,6})|(?<![\w&#])#(?<bare>\d{1,6}))(?!\w)}i
    REF_KIND = { "pr" => "pr", "pull" => "pr", "comment" => "comment", "event" => "comment", "card" => "card" }.freeze

    # Web URLs for repos whose origin is on github.com. Any other host gets no link (nil), not a guess.
    module Github
      module_function

      def repo_url(remote)
        m = remote.to_s.match(%r{\A(?:git@github\.com:|https://github\.com/|ssh://git@github\.com/)([\w.-]+)/([\w.-]+?)(?:\.git)?/?\z})
        m && "https://github.com/#{m[1]}/#{m[2]}"
      end

      def commit_url(remote, sha)
        base = repo_url(remote)
        base && "#{base}/commit/#{sha}"
      end
    end

    # What a #N can point at on one card: the repo (PR URLs), the handoff pr_url, the card's activity ids, its board
    # (slug), card_slugs: ->(ids) { {id => project_slug} } for the cards that exist (any board), and card_path:
    # ->(slug, id) { the host's URL that opens that card } (busyyaks: /projects/<slug>?tab=board&card=N).
    Refs = Struct.new(:repo, :pr_url, :activity_ids, :slug, :card_slugs, :card_path, keyword_init: true) do
      def pr_n = pr_url.to_s[%r{/pull/(\d+)}, 1]&.to_i

      # kind (pr|comment|card, nil = bare), n, slugs {id => slug} → [kind, url], or nil (stays plain text)
      def resolve(kind, n, slugs)
        case kind
        when "pr" then pr_link(n)
        when "comment" then activity_ids.include?(n) ? ["comment", "#a-#{n}"] : nil
        when "card" then slugs[n] ? ["card", card_path.call(slugs[n], n)] : nil
        else
          return pr_link(n) if pr_n == n
          return ["comment", "#a-#{n}"] if activity_ids.include?(n) # an activity on this card wins over a card id

          slugs[n] == slug ? ["card", card_path.call(slug, n)] : nil
        end
      end

      # The repo the work's PRs go to: the handoff pr_url's repo, else `repo` (the host's — the branch's push remote,
      # not necessarily origin: e.g. a private `*_local` repo beside a public origin).
      def pr_repo = CardLinks.pr_repo(pr_url) || repo

      def pr_link(n)
        return ["pr", pr_url] if pr_n == n

        r = pr_repo
        r ? ["pr", "#{r}/pull/#{n}"] : nil
      end
    end

    module_function

    # https://github.com/<owner>/<repo> of a GitHub PR URL, else nil.
    def pr_repo(pr_url) = pr_url.to_s[%r{\Ahttps://github\.com/[\w.-]+/[\w.-]+(?=/pull/\d)}]

    # card: {title, notes, pr_url?, ci_url?}, texts: comment bodies, project: {path, remote, slug} or nil (remote = the
    # repo the work is pushed to — the host picks it; busyyaks: the branch's push remote), commits: ->(shas) { {sha => row} }
    def build(card, texts, project, commits:, git:, branch_cache: nil)
      text = [card[:title], card[:notes], *texts].compact.join("\n")
      repo = project && Github.repo_url(project[:remote])
      links = []
      links << { kind: "repo", label: project[:slug], url: repo } if repo
      # the handoff's PR and CI build come first: they are what a human checks
      if card[:pr_url]
        n = card[:pr_url][%r{/pull/(\d+)}, 1]
        links << { kind: "pr", label: n ? "##{n}" : "PR", url: card[:pr_url] }
      end
      links << { kind: "ci", label: ci_label(card[:ci_url]), url: card[:ci_url] } if card[:ci_url]

      urls = text.scan(URL).map { |u| u.sub(/[.,;:!?]+\z/, "") }.uniq
      urls.each { |u| links << { kind: "url", label: u.sub(%r{\Ahttps?://}, "").delete_suffix("/"), url: u } }
      hosts = urls.map { |u| u[%r{\Ahttps?://([^/:?#]+)}, 1].to_s.downcase }.to_set
      text.scan(DOMAIN).flatten.map(&:downcase).uniq.reject { |d| hosts.include?(d) || d.end_with?(".git") }.each do |d|
        links << { kind: "site", label: d, url: "https://#{d}" }
      end

      if repo && project[:path]
        known = branch_cache ? (branch_cache[project[:path]] ||= git.branches(project)) : git.branches(project)
        words = text.scan(WORD).map { |w| w.sub(/[.,;:!?)]+\z/, "") }.to_set
        (words & known).sort.each do |b|
          links << { kind: "branch", label: b, url: "#{repo}/tree/#{b.split('/').map { |s| ERB::Util.url_encode(s) }.join('/')}" }
        end
      end

      if repo && project[:path]
        # repo files it names (docs/x.md, config/deploy/master.rb) → blob on the first named branch that has them
        refs = links.select { |l| l[:kind] == "branch" }.map { |l| l[:label] } + ["HEAD"]
        paths = text.scan(PATH).map { |w| w.sub(/[.,;:!?)]+\z/, "").sub(/:\d+\z/, "") }.uniq.first(40)
        found = paths.empty? ? {} : git.files_at(project, refs, paths.reject { |f| f.include?("..") })
        head = found.value?("HEAD") ? git.default_ref(project) : nil
        paths.each do |f|
          ref = found[f] or next
          links << { kind: "file", label: f, url: "#{repo}/blob/#{ref == 'HEAD' ? head : ref}/#{f}" }
        end
        # PRs the text names as PRs ("PR #12", "PRs: #93, 84", "pull/12"); a bare #N is never assumed to be one
        pr_base = pr_repo(card[:pr_url]) || repo
        ref_tokens(text).filter_map { |kind, n, _, _| n if kind == "pr" }.uniq.first(30).each do |n|
          links << { kind: "pr", label: "##{n}", url: "#{pr_base}/pull/#{n}" }
        end
      end

      shas = text.scan(SHA).uniq
      commits.call(shas).each do |sha, c|
        url = Github.commit_url(project && project[:remote], c[:sha])
        links << { kind: "commit", label: "#{sha[0, 9]} #{c[:subject].to_s[0, 60]}", url: url || "/commit/#{c[:sha]}" }
      end
      links.uniq { |l| l[:url] }
    end

    # Every #N reference in text: [[kind (pr|comment|card, nil = bare), n, offset, length]] — offset/length of the token
    # as written ("#12" or "12").
    def ref_tokens(text)
      text = text.to_s
      out = []
      text.scan(REF) do
        m = Regexp.last_match
        if m[:kw]
          kind = REF_KIND.fetch(m[:kw].downcase[/\A(pr|pull|comment|event|card)/, 1])
          start = m.begin(:list)
          start -= 1 if text[start - 1] == "#"
          text[start...m.end(:list)].scan(/#?\d+/) do |tok|
            out << [kind, tok.delete("#").to_i, start + Regexp.last_match.begin(0), tok.length]
          end
        elsif m[:pull]
          out << ["pr", m[:pull].to_i, m.begin(:pull), m[:pull].length]
        else
          out << [nil, m[:bare].to_i, m.begin(:bare) - 1, m[:bare].length + 1]
        end
      end
      out
    end

    # GitHub-style reference chips: an octicon-like glyph + the reference, a commit with its subject.
    ICONS = {
      "commit" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<circle cx="8" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="1.6"/>' \
        '<path d="M1 8h4M11 8h4" stroke="currentColor" stroke-width="1.6"/></svg>',
      "branch" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<circle cx="4.5" cy="3.5" r="1.8" fill="none" stroke="currentColor" stroke-width="1.5"/>' \
        '<circle cx="4.5" cy="12.5" r="1.8" fill="none" stroke="currentColor" stroke-width="1.5"/>' \
        '<circle cx="11.5" cy="5" r="1.8" fill="none" stroke="currentColor" stroke-width="1.5"/>' \
        '<path d="M4.5 5.3v5.4M11.5 6.8c0 3-7 2-7 4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>',
      "pr" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<circle cx="4" cy="3.5" r="1.8" fill="none" stroke="currentColor" stroke-width="1.5"/>' \
        '<circle cx="4" cy="12.5" r="1.8" fill="none" stroke="currentColor" stroke-width="1.5"/>' \
        '<circle cx="12" cy="12.5" r="1.8" fill="none" stroke="currentColor" stroke-width="1.5"/>' \
        '<path d="M4 5.3v5.4M12 10.7V6a2 2 0 0 0-2-2H7.5M9 2.5 7.5 4 9 5.5" fill="none" stroke="currentColor" ' \
        'stroke-width="1.5"/></svg>',
      "file" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<path d="M4 1.5h5l3.5 3.5v9.5H4z M9 1.5V5h3.5" fill="none" stroke="currentColor" stroke-width="1.4" ' \
        'stroke-linejoin="round"/></svg>',
      "issue" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.5"/>' \
        '<circle cx="8" cy="8" r="1.4" fill="currentColor"/></svg>',
      "site" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.4"/>' \
        '<path d="M1.8 8h12.4M8 1.8c2 2 2 10.4 0 12.4M8 1.8c-2 2-2 10.4 0 12.4" fill="none" stroke="currentColor" ' \
        'stroke-width="1.2"/></svg>',
      "ci" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<circle cx="8" cy="8" r="6.3" fill="none" stroke="currentColor" stroke-width="1.5"/>' \
        '<path d="M5 8.2l2 2 4-4.2" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" ' \
        'stroke-linejoin="round"/></svg>',
      "comment" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<path d="M2.5 3h11v7.5H7l-3 2.5v-2.5H2.5z" fill="none" stroke="currentColor" stroke-width="1.4" ' \
        'stroke-linejoin="round"/></svg>',
      "card" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<rect x="2" y="3" width="12" height="10" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/>' \
        '<path d="M4.5 6h5M4.5 8.5h7" stroke="currentColor" stroke-width="1.3"/></svg>',
      "repo" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true">' \
        '<path d="M3.5 2.5h8.5v10H5a1.5 1.5 0 0 0-1.5 1.5zM3.5 12.5V14" fill="none" stroke="currentColor" ' \
        'stroke-width="1.4" stroke-linejoin="round"/></svg>',
      "github" =>
        '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 .2a8 8 0 0 0-2.5 15.6c.4 0 ' \
        '.5-.2.5-.4v-1.5c-2.2.5-2.7-1-2.7-1-.4-.9-.9-1.2-.9-1.2-.7-.5.1-.5.1-.5.8.1 1.2.8 1.2.8.7 1.3 1.9.9 ' \
        '2.3.7.1-.5.3-.9.5-1.1-1.8-.2-3.6-.9-3.6-4 0-.9.3-1.6.8-2.1-.1-.2-.4-1 .1-2.1 0 0 .7-.2 2.2.8a7.5 7.5 0 0 1 4 ' \
        '0c1.5-1 2.2-.8 2.2-.8.4 1.1.2 1.9.1 2.1.5.6.8 1.3.8 2.1 0 3.1-1.9 3.8-3.6 4 .3.3.6.8.6 1.5v2.2c0 .2.1.5.6.4A8 8 0 ' \
        '0 0 8 .2z"/></svg>',
    }.freeze

    def chip(kind, url, inner, title: nil)
      ext = url.start_with?("/", "#") ? "" : ' target="_blank" rel="noopener"'
      t = title ? %( title="#{CGI.escapeHTML(title)}") : ""
      %(<a class="gh-ref gh-#{kind}" href="#{CGI.escapeHTML(url)}"#{ext}#{t}>#{ICONS.fetch(kind, ICONS["site"])}#{inner}</a>)
    end

    # A commit as GitHub shows it in a timeline: glyph, short sha, subject. compact: glyph + sha only, the subject in
    # the tooltip (where the line around it is the main thing: risk rows, timelines).
    def commit_chip(sha, url, subject, compact: false)
      subj = subject.to_s.strip
      short = subj.length > 64 ? "#{subj[0, 62]}…" : subj
      shown = compact || short.empty? ? "" : %(<span class="gh-subj">#{CGI.escapeHTML(short)}</span>)
      title = subj.empty? ? sha : "#{sha[0, 9]} · #{subj}"
      chip("commit", url, %(<code class="gh-sha">#{CGI.escapeHTML(sha[0, 7])}</code>#{shown}), title: title)
    end

    # Rendered HTML with the references it contains turned into GitHub-style chips (the same targets as the
    # Links list): `code` spans that name a branch / file / commit / domain; in plain text, file paths, domains,
    # known SHAs (and branch names only when they contain a "/", so the word "production" in a sentence stays a
    # word), the #N references refs resolves (PR / activity on this card / card; unresolved → text), and a GitHub PR /
    # issue / commit URL written out as its own link text (github_url_chip). Never inside
    # an existing <a>, a <pre> block or inline code.
    def linkify(html, links, refs: nil)
      return html if html.to_s.empty?

      by = {}
      links.each do |l|
        case l[:kind]
        when "branch", "file", "site" then by[l[:label]] ||= l
        when "url" then by[l[:url]] ||= l
        when "commit" then by[l[:label].split(" ").first] ||= l
        end
      end

      render = lambda do |key, shown_html|
        l = by[key] or return nil
        case l[:kind]
        when "commit" then commit_chip(key, l[:url], l[:label].split(" ", 2)[1])
        when "url" then chip("site", l[:url], %(<span>#{shown_html}</span>))
        else chip(l[:kind], l[:url], %(<code>#{shown_html}</code>))
        end
      end

      text_keys = links.filter_map do |l|
        next unless %w[file site commit].include?(l[:kind]) || (l[:kind] == "branch" && l[:label].include?("/"))

        l[:kind] == "commit" ? l[:label].split(" ").first : l[:label]
      end.uniq
      alternatives = text_keys.sort_by { |k| -k.length }.map { |k| Regexp.escape(k) }.join("|")
      text_re = text_keys.empty? ? nil : /(?<![\w\/.#-])(#{alternatives})(?![\w\/-])/
      plain = lambda do |s|
        next s unless text_re

        s.gsub(text_re) { render.call(CGI.unescapeHTML(Regexp.last_match(1)), Regexp.last_match(1)) || Regexp.last_match(1) }
      end
      slugs = refs ? refs.card_slugs.call(html.scan(/(?<![\w&])#?(\d{1,6})(?!\d)/).flatten.map(&:to_i).uniq.first(500)) : {}
      out = +""
      in_a = 0
      in_pre = 0
      tail = +"" # the text just before this node (across inline <strong>/<em>), so "card **#10**" keeps its keyword
      tokens = html.split(/(<[^>]+>)/)
      i = 0
      while i < tokens.size
        t = tokens[i]
        if t.start_with?("<")
          gh = in_a.zero? && in_pre.zero? ? github_url_chip(t, tokens[i + 1], tokens[i + 2]) : nil
          if gh
            out << gh
            i += 3
            next
          end
          in_a += 1 if t.match?(/\A<a[\s>]/i)
          in_a -= 1 if t.match?(%r{\A</a>}i)
          in_pre += 1 if t.match?(/\A<pre[\s>]/i)
          in_pre -= 1 if t.match?(%r{\A</pre>}i)
          tail = +"" unless t.match?(%r{\A</?(?:strong|em|b|i|del|s|mark)>\z}i)
          if t == "<code>" && in_a.zero? && in_pre.zero? && tokens[i + 2] == "</code>"
            key = CGI.unescapeHTML(tokens[i + 1].to_s)
            html_chip = render.call(key, tokens[i + 1]) || render.call(key.sub(/:\d+\z/, ""), tokens[i + 1])
            if html_chip
              out << html_chip
              i += 3
              next
            end
          end
          out << t
        elsif in_a.zero? && in_pre.zero? && !tokens[i - 1].to_s.start_with?("<code")
          out << (refs ? refs_html(t, tail, refs, slugs, plain) : plain.call(t))
          tail = (tail + t)[-48..] || (tail + t)
        else
          out << t
        end
        i += 1
      end
      out
    end

    GH_URL = %r{\Ahttps://github\.com/([\w.-]+)/([\w.-]+)/(pull|issues|commit)/(\h{7,40}|\d{1,7})/?\z}
    GH_URL_KIND = { "pull" => "pr", "issues" => "issue", "commit" => "commit" }.freeze

    # A bare GitHub URL written out in the text (autolinked: the link text is its href) — a PR, an issue or a commit
    # on any repo — as the chip GitHub itself shows: "repo#61" / "repo@abc1234", the full URL in the tooltip.
    # A link with its own text stays as written.
    def github_url_chip(open_tag, text, close_tag)
      return nil unless close_tag == "</a>" && open_tag.match?(/\A<a\s/i)

      href = CGI.unescapeHTML(open_tag[/\shref="([^"]*)"/, 1].to_s)
      return nil unless href == CGI.unescapeHTML(text.to_s)

      m = href.match(GH_URL) or return nil
      kind = GH_URL_KIND.fetch(m[3])
      return nil unless kind == "commit" ? m[4].length >= 7 : m[4].match?(/\A\d+\z/)

      label = kind == "commit" ? "#{m[2]}@#{m[4][0, 7]}" : "#{m[2]}##{m[4]}"
      chip(kind, href, %(<span>#{CGI.escapeHTML(label)}</span>), title: "#{m[1]}/#{m[2]} · #{href}")
    end

    REF_TITLE = { "pr" => "pull request", "comment" => "activity on this card", "card" => "card" }.freeze

    # One text node with its #N references resolved into chips and the rest through plain (the other reference kinds).
    # tail: the text before it, read for a keyword ("card " + "#10") but never re-emitted.
    def refs_html(t, tail, refs, slugs, plain)
      s = tail + t
      off = tail.length
      out = +""
      at = 0
      ref_tokens(s).each do |kind, n, pos, len|
        next if pos < off + at

        kind_url = refs.resolve(kind, n, slugs) or next
        out << plain.call(t[at...(pos - off)])
        out << chip(kind_url[0], kind_url[1], %(<span>#{s[pos, len]}</span>), title: "#{REF_TITLE[kind_url[0]]} ##{n}")
        at = pos - off + len
      end
      out << plain.call(t[at..].to_s)
    end

    # "jenkins · job #123" from a Jenkins build URL (…/job/<name>/<n>/), else the host. A multibranch job name is the
    # branch with its "/" escaped by Jenkins (%2F) and that "%" escaped again in the URL (%252F): unescaped exactly
    # twice, so "card%252F166-x" reads "card/166-x".
    def ci_label(url)
      jobs = url.to_s.scan(%r{/job/([^/]+)}).flatten.map { |j| unescape_job(j) }
      num = url.to_s[%r{/job/[^/]+/(\d+)/?}, 1]
      return "jenkins · #{jobs.join(' / ')}#{num ? " ##{num}" : ''}" if jobs.any?

      url.to_s[%r{\Ahttps?://([^/]+)}, 1] || "CI build"
    end

    def unescape_job(name)
      bytes = name.b
      2.times { bytes = bytes.gsub(/%(\h\h)/n) { [Regexp.last_match(1).hex].pack("C") } }
      bytes.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
