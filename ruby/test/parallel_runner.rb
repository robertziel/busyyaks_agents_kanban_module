# frozen_string_literal: true

require "etc"
require "open3"
require "rbconfig"

# Runs minitest files in one worker PROCESS per CPU. Each worker is a fresh `ruby` loading its share of the
# files, with the environment `env_for.(i)` gives it (its own database, sockets, dirs), so nothing a test touches is
# shared. Files are split longest-first onto the least-loaded worker, weighted by size. Every worker's result is
# collected; a failed or crashed worker fails the run and its whole output is printed. The same files run as under
# `rake test`, only spread out — the totals line proves the count.
module ParallelRunner
  SUMMARY = /^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/
  LOAD = "ARGV.shift(ARGV.size).each { |f| require File.expand_path(f) }"
  Result = Struct.new(:index, :files, :status, :output, :counts, :seconds)

  module_function

  # The CPUs this process may run on (sched_getaffinity on Linux — a container's cpuset, not the host's count).
  def workers = Etc.nprocessors

  # How many workers for `files` test files, from TEST_WORKERS: unset → one per CPU (capped at the file count);
  # `files` → one per test file, whatever the CPU count (an I/O-bound run); a positive integer →
  # that many (capped at the file count). Anything else is refused.
  def count(setting, files)
    case setting
    when nil then [workers, files].min
    when "files" then files
    when /\A[1-9]\d*\z/ then [setting.to_i, files].min
    else raise ArgumentError, "TEST_WORKERS=#{setting.inspect}: neither `files` nor a positive integer"
    end
  end

  def balance(files, n)
    buckets = Array.new(n) { [] }
    loads = Array.new(n, 0)
    files.sort_by { |f| [-File.size(f), f] }.each do |f|
      i = loads.index(loads.min)
      buckets[i] << f
      loads[i] += File.size(f)
    end
    buckets.reject(&:empty?)
  end

  # files: the test files · libs: -I dirs · env_for: worker index → its ENV additions · prepare: called with the index
  # before that worker starts (e.g. copy its database) · boot: worker index → Ruby code the worker runs before it loads
  # its files (e.g. start coverage). Returns true when every worker passed.
  def run(files:, libs:, env_for:, workers: self.workers, prepare: nil, boot: nil, out: $stdout)
    raise ArgumentError, "no test files" if files.empty?

    n = [workers, files.size].min
    buckets = balance(files, n)
    out.puts "parallel: #{files.size} files in #{buckets.size} workers (#{Etc.nprocessors} CPUs)"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = buckets.each_with_index.map do |fs, i|
      Thread.new { run_worker(i, fs, libs, env_for, prepare, boot) }
    end.map(&:value)
    report(results, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, out)
  end

  def run_worker(index, files, libs, env_for, prepare, boot)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    prepare&.call(index)
    # the files leave ARGV before minitest parses it (as its own options) at exit
    cmd = [RbConfig.ruby, *libs.flat_map { ["-I", _1] }, *(boot ? ["-e", boot.call(index)] : []), "-e", LOAD, *files]
    output, status = Open3.capture2e(env_for.call(index), *cmd)
    counts = output.scan(SUMMARY).last&.map(&:to_i)
    Result.new(index, files, status, output, counts, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
  rescue StandardError => e
    Result.new(index, files, nil, "worker #{index} did not run: #{e.class}: #{e.message}", nil, 0)
  end

  def report(results, wall, out)
    failed = results.reject { |r| r.status&.success? && r.counts && r.counts[2].zero? && r.counts[3].zero? }
    failed.each do |r|
      out.puts "", "── worker #{r.index} FAILED (#{r.status&.exitstatus.inspect}) · #{r.files.join(' ')} ──", r.output
    end
    results.each do |r|
      c = r.counts ? format("%d runs, %d assertions, %d failures, %d errors, %d skips", *r.counts) : "no summary"
      out.puts format("worker %2d  %5.1fs  %3d files  %s", r.index, r.seconds, r.files.size, c)
    end
    totals = results.filter_map(&:counts).transpose.map(&:sum)
    totals = [0, 0, 0, 0, 0] if totals.empty?
    out.puts format("TOTAL %d runs, %d assertions, %d failures, %d errors, %d skips · %d workers · %.1fs%s",
                    *totals, results.size, wall, failed.empty? ? "" : " · #{failed.size} worker(s) FAILED")
    failed.empty?
  end
end
