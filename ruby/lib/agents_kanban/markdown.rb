# frozen_string_literal: true

require "cgi"
require "erb"

module AgentsKanban
  # The MARKDOWN port's shipped implementation: card descriptions, comments and checklist items rendered server-side
  # with commonmarker (raw HTML dropped — `unsafe: false`), @name mentions marked, this host's own attachment pictures
  # kept and every other image turned into a plain link. A host may inject any object answering card(md) / inline(md)
  # instead; the engine never renders markdown in a browser.
  #
  # commonmarker is required lazily, so a host that injects its own renderer needs no gem.
  class Markdown
    DENSE_AT = 900
    DENSER_AT = 2200
    # Slack-style ```text``` typed or pasted inline: CommonMark reads "```Some words" as a fence whose info string
    # (the code language) is "Some", so the words vanish. When the text after ``` has a space and the span closes
    # with ``` somewhere later, rewrite it as a real fenced block with the closing text kept after it.
    # Only when it spans lines AND closes mid-line (a real fence closes on its own line, so "```js title=x" is untouched;
    # one-line ```x y``` is already inline code).
    SLACK_FENCE = /^(`{3,})([^`\n]*\s[^`\n]*)(\n.*?[^\n`])\1[ \t]*([^\n]*)$/m
    IMG = %r{<img\s[^>]*>}
    MENTION = %r{(?<![\w@/.&#-])@([A-Za-z0-9](?:[\w.-]*[A-Za-z0-9_])?)}
    SKIP_TAG = %r{\A<(/?)(code|pre|a)\b}i

    attr_reader :attachment_url_prefix

    def initialize(attachment_url_prefix:)
      require "commonmarker"
      @attachment_url_prefix = attachment_url_prefix
      @att_src = %r{\A#{Regexp.escape(attachment_url_prefix)}/(\d+)\z}
      @file_link = %r{<a href="#{Regexp.escape(attachment_url_prefix)}/(\d+)/download"(?:\s+title="[^"]*")?>}
    end

    # Kanban descriptions and comments: render + @name mentions wrapped in <span class="mention"> (not inside code/pre/a),
    # attachment pictures and file chips, wide tables zoomed out.
    def card(md) = dense_tables(mentions(attachments(render(slack_fences(md)))))

    # A checklist item: one paragraph unwrapped to inline HTML (a multi-block body stays as blocks).
    def inline(md)
      html = card(md)
      m = html.match(%r{\A<p>(.*)</p>\n?\z}m)
      m && !m[1].include?("<p>") ? m[1] : html
    end

    def render(md)
      extension = { table: true, strikethrough: true, autolink: true, tasklist: true, header_ids: "" }
      Commonmarker.to_html(md.to_s, options: { render: { unsafe: false }, extension: extension },
                                    plugins: { syntax_highlighter: nil })
    end

    # A table with a lot of text is zoomed out: md-dense (one step) or md-denser (two), by its visible characters.
    def dense_tables(html)
      html.gsub(%r{<table>(.*?)</table>}m) do
        inner = Regexp.last_match(1)
        n = CGI.unescapeHTML(inner.gsub(/<[^>]+>/, "")).gsub(/\s+/, " ").length
        cls = if n >= DENSER_AT then "md-denser" elsif n >= DENSE_AT then "md-dense" end
        cls ? %(<table class="#{cls}">#{inner}</table>) : "<table>#{inner}</table>"
      end
    end

    def slack_fences(md)
      md.to_s.gsub(SLACK_FENCE) do
        fence = $1
        first = $2
        rest = $3.to_s
        after = $4
        body = (first + rest).strip
        "#{fence}\n#{body}\n#{fence}" + (after.strip.empty? ? "" : "\n\n#{after.strip}")
      end
    end

    # Only this host's own attachments are pictures: <img src="<prefix>/ID"> stays (wrapped in a link the card dialog
    # opens as a lightbox); any other image (a remote URL) becomes a plain link — no remote image is ever loaded.
    # [name](<prefix>/ID/download) becomes a file chip that downloads.
    def attachments(html)
      p = @attachment_url_prefix
      html.gsub(IMG) do |tag|
        src = CGI.unescapeHTML(tag[/\ssrc="([^"]*)"/, 1].to_s)
        alt = tag[/\salt="([^"]*)"/, 1].to_s
        m = src.match(@att_src)
        if m
          url = "#{p}/#{m[1]}"
          img = %(<img src="#{url}" alt="#{alt}" loading="lazy" />)
          %(<a class="kb-att-img" href="#{url}" data-attachment="#{m[1]}">#{img}</a>)
        elsif src.match?(%r{\Ahttps?://}i)
          text = alt.empty? ? ERB::Util.h(src) : alt
          %(<a class="ext-img" href="#{ERB::Util.h(src)}" target="_blank" rel="noopener nofollow">#{text}</a>)
        else
          alt
        end
      end.gsub(@file_link) do
        id = Regexp.last_match(1)
        %(<a class="kb-file-chip" href="#{p}/#{id}/download" data-attachment="#{id}" download>)
      end
    end

    def mentions(html)
      skip = 0
      html.split(/(<[^>]+>)/).map do |part|
        if part.start_with?("<")
          t = part.match(SKIP_TAG)
          skip += t[1].empty? ? 1 : -1 if t
          part
        elsif skip.zero?
          part.gsub(MENTION) { %(<span class="mention">@#{Regexp.last_match(1)}</span>) }
        else
          part
        end
      end.join
    end
  end
end
