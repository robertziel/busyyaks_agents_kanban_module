# frozen_string_literal: true

require "digest"

module AgentsKanban
  # A dialog on an agent session's screen (Claude Code: permission prompt, AskUserQuestion; Hermes: its dangerous-command
  # panel, `hermes` below), parsed from `tmux capture-pane`
  # text. Pure Ruby, no dependencies and no other file of this library: loaded by the host's container (Store,
  # Notifier) AND by its host-side launcher, so both sides compute the same `hash` — the launcher presses a key only
  # while the screen still shows that exact dialog. Require this file alone from a host script.
  #
  # → nil (no dialog) or {question, command, options: [{key, label, free}], escape, free_text, hash, text}
  #   key: the digit to press; free: a free-text choice ("Type something", "Other", "Chat about this") — shown, never
  #   clickable; escape: "Esc to cancel" is on the screen; free_text: the dialog also takes typed text (Tab to amend).
  module SessionDialog
    BOX = /[│╭╮╰╯─┃━┌┐└┘┬┴├┤]/
    OPTION = /\A\s*(?:[❯>›▶]\s*)?(\d{1,2})[.)]\s+(\S.*?)\s*\z/
    FOOT = /Esc to cancel|Enter to confirm|Enter to select/i
    FREE = /\A(type something|other\b|chat about this|something else)/i
    MAX_COMMAND = 12
    # Claude Code's unattended-session countdown, re-drawn every second: shown, never hashed.
    COUNTDOWN = /(block this request in) \d+(?::\d{2})+/i
    # Hermes's approval hint under its panel ("(299s)" = its countdown, never hashed) and the prompt row it draws
    # while the panel is open (`⚠ ❯`): the row a transcript quoting the panel does not have.
    HERMES_FOOT = %r{\A\s*↑/↓ to select, Enter to confirm(?:\s+\(\d+s\))?\s*\z}
    HERMES_PROMPT = /\A⚠\s*❯/
    HERMES_TITLE = /Dangerous Command/
    HERMES_OPTION = /\A\s*(?:❯\s*)?(\d{1,2})\.\s+(\S.*?)\s*\z/
    # the panel's "view" choice re-draws it with the whole command: it answers nothing
    HERMES_VIEW = /\AShow full command\z/i
    HERMES_LAST = /\A(?:Deny|Show full command)\z/i
    HERMES_BELOW = 6 # rows from the hint to its prompt row (the status bar and a rule sit between them)
    HERMES_ABOVE = 4 # rows from the panel's bottom border to the hint (the running tool's line sits between them)

    module_function

    def parse(screen)
      raw = screen.to_s.lines.map(&:rstrip)
      lines = raw.map { |l| l.gsub(BOX, " ").rstrip }
      foot = lines.rindex { |l| l.match?(FOOT) } or return nil
      return hermes(raw, foot) if raw[foot].match?(HERMES_FOOT)

      # the run of numbered options nearest the footer (description lines between options are allowed)
      opt_idx = []
      i = foot - 1
      gap = 0
      while i >= 0 && i >= foot - 40
        if lines[i].match?(OPTION)
          opt_idx.unshift(i)
          gap = 0
        elsif !opt_idx.empty?
          gap += 1
          break if gap > 3 || lines[i].strip.empty? && lines[i - 1].to_s.strip.empty?
        end
        i -= 1
      end
      return nil if opt_idx.empty?

      options = opt_idx.map do |k|
        m = lines[k].match(OPTION)
        { key: m[1], label: m[2].gsub(/\s+/, " "), free: m[2].strip.match?(FREE) }
      end
      return nil unless options.map { |o| o[:key] }.uniq.size == options.size

      # the question: the non-empty block right above the first option (no blank line inside it)
      q_end = opt_idx.first - 1
      q_end -= 1 while q_end >= 0 && lines[q_end].strip.empty?
      q_start = q_end
      q_start -= 1 while q_start.positive? && !lines[q_start - 1].strip.empty? && q_end - q_start < 6
      question = lines[q_start..q_end].map(&:strip).join("\n") if q_end >= 0

      # the command shown above the question: the next block up (until a blank line, a box top, or MAX_COMMAND lines)
      c_end = q_start - 1
      c_end -= 1 while c_end >= 0 && lines[c_end].strip.empty?
      c_start = c_end
      while c_start.positive? && !lines[c_start - 1].strip.empty? && !raw[c_start - 1].match?(/[╭┌]/) &&
            c_end - c_start < MAX_COMMAND - 1
        c_start -= 1
      end
      command = c_end >= 0 && c_start >= 0 && !raw[c_end].match?(/\A\s*[╭┌]/) ? dedent(lines[c_start..c_end]) : nil
      command = nil if command&.strip&.empty?

      foot_text = lines[foot].strip
      escape = foot_text.match?(/Esc to cancel/i)
      free_text = foot_text.match?(/Tab to amend/i) || options.any? { |o| o[:free] }
      norm = [question, command, *options.map { |o| "#{o[:key]}. #{o[:label]}" }, foot_text]
             .compact
             .map { |s| s.gsub(/\s+/, " ").gsub(COUNTDOWN, '\\1 …').strip }
      text = lines[(command ? c_start : [q_start, 0].max)..foot].join("\n").strip
      { question: question.to_s, command: command, options: options, escape: escape, free_text: free_text,
        hash: Digest::SHA256.hexdigest(norm.join("\n")), text: text, }
    end

    # Hermes's panel: ╭ title · command · numbered choices · description ╰, the hint below it, `⚠ ❯` below that. Anything
    # else with that hint is no dialog. Choices are read upward from the last one (Deny / Show full command) while their
    # numbers run down to 1, so a numbered line inside the command is never taken for one.
    def hermes(raw, foot)
      return nil unless raw[(foot + 1)..(foot + HERMES_BELOW)].to_a.any? { |l| l.match?(HERMES_PROMPT) }

      bottom = (foot - 1).downto([foot - HERMES_ABOVE, 0].max).find { |i| raw[i].match?(/\A\s*╰─+╯\s*\z/) } or return nil
      top = (bottom - 1).downto(0).find { |i| raw[i].match?(/\A\s*╭─+╮\s*\z/) } or return nil
      rows = raw[(top + 1)...bottom].map { |l| l.sub(/\A\s*│ ?/, "").sub(/\s*│\s*\z/, "") }
      return nil unless rows.first.to_s.match?(HERMES_TITLE)

      last = rows.rindex { |r| (m = r.match(HERMES_OPTION)) && m[2].match?(HERMES_LAST) } or return nil
      first, options = hermes_options(rows, last)
      return nil unless first

      command = dedent(rows[1...first].reject { |r| r.strip.empty? })
      why = rows[(last + 1)..].map(&:strip).reject(&:empty?).join(" ")
      question = ["Dangerous Command", (why unless why.empty?)].compact.join(": ")
      norm = [question, command, *options.map { |o| "#{o[:key]}. #{o[:label]}" }].map { |x| x.gsub(/\s+/, " ").strip }
      { question: question, command: command.empty? ? nil : command, options: options, escape: false, free_text: false,
        hash: Digest::SHA256.hexdigest(norm.join("\n")), text: raw[top..bottom].join("\n"), }
    end

    # → [row of choice 1, options] walking up from row `last`; a wrapped label's continuation rows join their choice
    def hermes_options(rows, last)
      want = rows[last].match(HERMES_OPTION)[1].to_i
      options = []
      tail = []
      last.downto(1) do |i|
        m = rows[i].match(HERMES_OPTION)
        if m && m[1].to_i == want
          label = [m[2], *tail].join(" ").gsub(/\s+/, " ")
          options.unshift({ key: m[1], label: label, free: label.match?(HERMES_VIEW) })
          tail = []
          want -= 1
          return [i, options] if want.zero?
        elsif rows[i].match?(/\A {4}\S/)
          tail.unshift(rows[i].strip)
        else
          return nil
        end
      end
      nil
    end

    def dedent(ls)
      pad = ls.reject { |l| l.strip.empty? }.map { |l| l[/\A */].size }.min || 0
      ls.map { |l| l[pad..].to_s }.join("\n").strip
    end

    # Why pressing `key` on this screen is refused (nil = press it): the launcher's `answer` op's rule, here so it is tested.
    def refuse_answer(screen, hash:, key:)
      d = parse(screen)
      return "no dialog on its screen any more" unless d
      return "the dialog on its screen changed" unless d[:hash] == hash.to_s
      return "#{key} is not an option of this dialog (#{keys(d).join(', ')})" unless keys(d).include?(key.to_s)

      nil
    end

    # The keys an operator may press for this dialog: non-free numbered options, and "esc" when Esc cancels.
    def keys(d)
      opts = d[:options] || d["options"]
      ks = opts.reject { |o| o[:free] || o["free"] }.map { |o| (o[:key] || o["key"]).to_s }
      (d[:escape] || d["escape"]) ? ks + ["esc"] : ks
    end
  end
end
