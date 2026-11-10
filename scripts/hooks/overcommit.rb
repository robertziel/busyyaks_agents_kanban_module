# frozen_string_literal: true

# overcommit's own hook entry point (template-dir/hooks/overcommit-hook), minus what does not apply in a container
# here: no self-update of an installed .git/hooks copy (nothing is installed — .githooks/<hook> starts the
# container) and no OVERCOMMIT_DISABLE escape (the environment is not passed in). Any error refuses the commit.
require "overcommit"

hook_type = ARGV.shift
begin
  logger = Overcommit::Logger.new($stdout)
  Overcommit::Utils.log = logger
  config = Overcommit::ConfigurationLoader.new(logger).load_repo_config
  context = Overcommit::HookContext.create(hook_type, config, ARGV, $stdin)
  config.apply_environment!(context, ENV)
  printer = Overcommit::Printer.new(config, logger, context)
  exit(Overcommit::HookRunner.new(config, logger, context, printer).run ? 0 : 65)
rescue Overcommit::Exceptions::ConfigurationSignatureChanged => e
  puts e
  puts "Review .overcommit.yml, then: scripts/hooks/run sign"
  exit 1
rescue Overcommit::Exceptions::InvalidHookSignature
  puts "Review the hook, then: scripts/hooks/run sign"
  exit 1
rescue StandardError => e
  puts "overcommit: #{e.class}: #{e.message}"
  exit 1
end
