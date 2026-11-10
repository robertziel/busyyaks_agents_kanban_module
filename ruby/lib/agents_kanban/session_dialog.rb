# frozen_string_literal: true

require "digest"

module AgentsKanban
  # A dialog on a Claude Code session's screen (permission prompt, AskUserQuestion), parsed from `tmux capture-pane`
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

    module_function

    def parse(screen)
      raw = screen.to_s.lines.map(&:rstrip)
      lines = raw.map { |l| l.gsub(BOX, " ").rstrip }
      foot = lines.rindex { |l| l.match?(FOOT) } or return nil

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
