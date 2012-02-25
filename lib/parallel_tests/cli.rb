require 'optparse'
require 'parallel_tests/test/runner'

module ParallelTest
  module CLI
    def self.run(argv)
      options = {}
      OptionParser.new do |opts|
        opts.banner = <<BANNER
Run all tests in parallel, giving each process ENV['TEST_ENV_NUMBER'] ('', '2', '3', ...)

[optional] Only run selected files & folders:
    parallel_test test/bar test/baz/xxx_text.rb

Options are:
BANNER
        opts.on("-n [PROCESSES]", Integer, "How many processes to use, default: available CPUs") { |n| options[:count] = n }
        opts.on("-p", '--pattern [PATTERN]', "run tests matching this pattern") { |pattern| options[:pattern] = pattern }
        opts.on("--no-sort", "do not sort files before running them") { |no_sort| options[:no_sort] = no_sort }
        opts.on("-m [FLOAT]", "--multiply-processes [FLOAT]", Float, "use given number as a multiplier of processes to run") { |multiply| options[:multiply] = multiply }
        opts.on("-r", '--root [PATH]', "execute test commands from this path") { |path| options[:root] = path }
        opts.on("-s [PATTERN]", "--single [PATTERN]", "Run all matching files in only one process") do |pattern|
          options[:single_process] ||= []
          options[:single_process] << /#{pattern}/
        end
        opts.on("-e", '--exec [COMMAND]', "execute this code parallel and with ENV['TEST_ENV_NUM']") { |path| options[:execute] = path }
        opts.on("-o", "--test-options '[OPTIONS]'", "execute test commands with those options") { |arg| options[:test_options] = arg }
        opts.on("-t", "--type [TYPE]", "which type of tests to run? test, spec or features") { |type| options[:type] = type }
        opts.on("--non-parallel", "execute same commands but do not in parallel, needs --exec") { options[:non_parallel] = true }
        opts.on("--chunk-timeout [TIMEOUT]", "timeout before re-printing the output of a child-process") { |timeout| options[:chunk_timeout] = timeout.to_f }
        opts.on('-v', '--version', 'Show Version') { puts ParallelTests::VERSION; exit }
        opts.on("-h", "--help", "Show this.") { puts opts; exit }
      end.parse!(argv)

      raise "--no-sort and --single-process are not supported" if options[:no_sort] and options[:single_process]

      # get files to run from arguments
      options[:files] = argv if argv.size > 0

      num_processes = ParallelTests.determine_number_of_processes(options[:count])
      num_processes = num_processes * (options[:multiply] || 1)

      if options[:execute]
        runs = (0...num_processes).to_a
        results = if options[:non_parallel]
          runs.map do |i|
            ParallelTests::Test::Runner.execute_command(options[:execute], i, options)
          end
        else
          Parallel.map(runs, :in_processes => num_processes) do |i|
            ParallelTests::Test::Runner.execute_command(options[:execute], i, options)
          end
        end.flatten
        abort if results.any? { |r| r[:exit_status] != 0 }
      else
        lib, name, task = {
          'test' => ["test", "test", "test"],
          'spec' => ["spec", "spec", "spec"],
          'features' => ["cucumber", "feature", "features"]
        }[options[:type]||'test']

        require "parallel_tests/#{lib}/runner"
        klass = eval("ParallelTests::#{lib.capitalize}::Runner")

        start = Time.now

        tests_folder = task
        tests_folder = File.join(options[:root], tests_folder) unless options[:root].to_s.empty?

        groups = klass.tests_in_groups(options[:files] || tests_folder, num_processes, options)
        num_processes = groups.size

        #adjust processes to groups
        abort "no #{name}s found!" if groups.size == 0

        num_tests = groups.inject(0) { |sum, item| sum + item.size }
        puts "#{num_processes} processes for #{num_tests} #{name}s, ~ #{num_tests / groups.size} #{name}s per process"

        test_results = Parallel.map(groups, :in_processes => num_processes) do |group|
          if group.empty?
            {:stdout => '', :exit_status => 0}
          else
            klass.run_tests(group, groups.index(group), options)
          end
        end

        #parse and print results
        results = klass.find_results(test_results.map { |result| result[:stdout] }*"")
        puts ""
        puts klass.summarize_results(results)

        #report total time taken
        puts ""
        puts "Took #{Time.now - start} seconds"

        #exit with correct status code so rake parallel:test && echo 123 works
        failed = test_results.any? { |result| result[:exit_status] != 0 }
        abort "#{name.capitalize}s Failed" if failed
      end
    end
  end
end
