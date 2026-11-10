# frozen_string_literal: true

require "yaml"
require "date"
require_relative "errors"
require_relative "column_types"

module AgentsKanban
  # Read-only view of a repo's Backlog.md tasks (backlog/tasks/*.md and backlog/drafts/*.md front matter), placed on
  # the board's columns by a status map the HOST gives (its own Backlog.md vocabulary → column TYPES, like every other
  # rule: a task lands on the board's column of that type; drafts always land on the first column). Tasks are changed
  # with the `backlog` CLI in the repo, never here. A file that does not parse, a status with no mapping, or a status
  # whose type this board has no column of (the operator removed it) is reported in :errors — never guessed, never a
  # crash.
  module BacklogMd
    FIELDS = %w[id title status labels assignee priority dependencies created_date updated_date].freeze
    JSON_FIELDS = %w[id title status column labels assignee priority file draft].freeze

    module_function

    def present?(repo_path) = File.directory?(File.join(repo_path.to_s, "backlog", "tasks"))

    # nil when the repo has no backlog/tasks dir; else
    # {columns: {column_key => [task]}, unmapped: [task], errors: [String], total: Integer}.
    # board: the project's Board; status_map: {"to do" => "queued", …} (keys lower-case), each value a column TYPE.
    def read(repo_path, board:, status_map:)
      return nil unless present?(repo_path)

      bad = status_map.values.reject { |v| ColumnTypes.known?(v) }
      if bad.any?
        raise ConfigError, "backlog status map names column types that do not exist: " \
                           "#{bad.uniq.join(', ')} (#{ColumnTypes.keys.join(', ')})"
      end

      dir = File.join(repo_path, "backlog")
      errors = []
      tasks = Dir.glob(File.join(dir, "tasks", "*.md")).sort.filter_map { |f| task(f, errors) }
      drafts = Dir.glob(File.join(dir, "drafts", "*.md")).sort.filter_map { |f| task(f, errors)&.merge("draft" => true) }
      cols = board.keys.to_h { |k| [k, []] }
      unmapped = []
      (tasks + drafts).each do |t|
        type = status_map[t["status"].to_s.strip.downcase]
        col = t["draft"] ? board.keys.first : type && board.one_of_type(type)
        col ? cols[col] << t : unmapped << t
      end
      unmapped.group_by { |t| t["status"].to_s }.each do |s, ts|
        type = status_map[s.strip.downcase]
        n = "#{ts.size} task#{'s' unless ts.size == 1}"
        errors << if type
                    "status #{s.inspect} (#{n}) maps to type #{type} but this board has no #{type} column"
                  else
                    "status #{s.inspect} (#{n}) has no column — see the board's backlog status map"
                  end
      end
      cols.each_value { |ts| ts.sort_by! { |t| [-stamp(t), t["id"].to_s] } }
      { columns: cols, unmapped: unmapped, errors: errors, total: tasks.size + drafts.size }
    end

    def stamp(t) = (t["updated_date"] || t["created_date"]).to_s.delete("^0-9").ljust(12, "0")[0, 12].to_i

    def task(file, errors)
      src = File.read(file, encoding: "UTF-8")
      m = src.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
      return errors.push("#{File.basename(file)}: no front matter") && nil unless m

      fm = YAML.safe_load(m[1], permitted_classes: [Date, Time])
      return errors.push("#{File.basename(file)}: front matter is not a mapping") && nil unless fm.is_a?(Hash)

      t = fm.slice(*FIELDS).transform_values { |v| v.is_a?(Date) || v.is_a?(Time) ? v.to_s : v }
      t["labels"] = Array(t["labels"]).map(&:to_s)
      t["assignee"] = Array(t["assignee"]).map(&:to_s)
      t["file"] = File.basename(file)
      t
    rescue Psych::Exception => e
      errors << "#{File.basename(file)}: #{e.message}"
      nil
    end

    # The board JSON's `backlog_md` block for one read result (nil in, nil out). column: only that column's tasks.
    def json(bm, column: nil)
      return nil unless bm

      placed = bm[:columns].flat_map { |k, ts| ts.map { |t| t.merge("column" => k) } }
      tasks = placed + bm[:unmapped].map { |t| t.merge("column" => nil) }
      tasks = tasks.select { |t| t["column"] == column } if column
      { read_only: "edit with the backlog CLI in the repo", errors: bm[:errors],
        tasks: tasks.map { |t| t.slice(*JSON_FIELDS) }, }
    end
  end
end
