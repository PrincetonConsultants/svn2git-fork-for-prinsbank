require 'optparse'
require 'pp'
require 'set'
require 'thread'
require 'timeout'
require 'fileutils'
require 'open3'

require_relative 'refname_sanitize'

module Svn2Git
  DEFAULT_AUTHORS_FILE = "~/.svn2git/authors"

  class Migration

    attr_reader :dir

    def initialize(args)
      @options = parse(args)
      if @options[:rebase]
         show_help_message('Too many arguments') if args.size > 0
         verify_working_tree_is_clean
      elsif @options[:rebasebranch]
         show_help_message('Too many arguments') if args.size > 0
         verify_working_tree_is_clean
      else
         show_help_message('Missing SVN_URL parameter') if args.empty?
         show_help_message('Too many arguments') if args.size > 1
         @url = args.first.gsub(' ', "\\ ")
      end
    end

    def run!
      if @options[:rebase] || @options[:rebasebranch]
        @options[:target_dir] = nil
      end
      
      if @options[:rebase]
        get_branches
      elsif @options[:rebasebranch]
        get_rebasebranch
      else
        clone!
      end
      fix_branches
      fix_tags
      fix_trunk
      optimize_repos
    end

    def parse(args)
      # Set up reasonable defaults for options.
      options = {}
      options[:verbose] = false
      options[:metadata] = false
      options[:nominimizeurl] = false
      options[:rootistrunk] = false
      options[:trunk] = 'trunk'
      options[:branches] = []
      options[:tags] = []
      options[:exclude] = []
      options[:revision] = nil
      options[:username] = nil
      options[:password] = nil
      options[:rebasebranch] = false
      options[:target_dir] = nil

      if File.exist?(File.expand_path(DEFAULT_AUTHORS_FILE))
        options[:authors] = DEFAULT_AUTHORS_FILE
      end


      # Parse the command-line arguments.
      @opts = OptionParser.new do |opts|
        opts.banner = 'Usage: svn2git SVN_URL [options]'

        opts.separator ''
        opts.separator 'Specific options:'

        opts.on('--rebase', 'Instead of cloning a new project, rebase an existing one against SVN') do
          options[:rebase] = true
        end

        opts.on('--username NAME', 'Username for transports that needs it (http(s), svn)') do |username|
          options[:username] = username
        end

        opts.on('--password PASSWORD', 'Password for transports that need it (http(s), svn)') do |password|
          options[:password] = password
        end

        opts.on('--trunk TRUNK_PATH', 'Subpath to trunk from repository URL (default: trunk)') do |trunk|
          options[:trunk] = trunk
        end

        opts.on('--branches BRANCHES_PATH', 'Subpath to branches from repository URL (default: branches); can be used multiple times') do |branches|
          options[:branches] << branches
        end

        opts.on('--tags TAGS_PATH', 'Subpath to tags from repository URL (default: tags); can be used multiple times') do |tags|
          options[:tags] << tags
        end

        opts.on('--rootistrunk', 'Use this if the root level of the repo is equivalent to the trunk and there are no tags or branches') do
          options[:rootistrunk] = true
          options[:trunk] = nil
          options[:branches] = nil
          options[:tags] = nil
        end

        opts.on('--notrunk', 'Do not import anything from trunk') do
          options[:trunk] = nil
        end

        opts.on('--nobranches', 'Do not try to import any branches') do
          options[:branches] = nil
        end

        opts.on('--notags', 'Do not try to import any tags') do
          options[:tags] = nil
        end

        opts.on('--no-minimize-url', 'Accept URLs as-is without attempting to connect to a higher level directory') do
          options[:nominimizeurl] = true
        end

        opts.on('--revision START_REV[:END_REV]', 'Start importing from SVN revision START_REV; optionally end at END_REV') do |revision|
          options[:revision] = revision
        end

        opts.on('-m', '--metadata', 'Include metadata in git logs (git-svn-id)') do
          options[:metadata] = true
        end

        opts.on('--authors AUTHORS_FILE', "Path to file containing svn-to-git authors mapping (default: #{DEFAULT_AUTHORS_FILE})") do |authors|
          options[:authors] = authors
        end

        opts.on('--exclude REGEX', 'Specify a Perl regular expression to filter paths when fetching; can be used multiple times') do |regex|
          options[:exclude] << regex
        end

        opts.on('-v', '--verbose', 'Be verbose in logging -- useful for debugging issues') do
          options[:verbose] = true
        end

        opts.on('--rebasebranch REBASEBRANCH', 'Rebase specified branch.') do |rebasebranch|
          options[:rebasebranch] = rebasebranch
        end

        opts.on('--target-dir DIR', 'Directory to create and use as the Git repo root') do |dir|
          options[:target_dir] = dir
        end        

        opts.separator ""

        # No argument, shows at tail.  This will print an options summary.
        # Try it and see!
        opts.on_tail('-h', '--help', 'Show this message') do
          puts opts
          exit
        end
      end

      @opts.parse! args
      options
    end

    def self.escape_quotes(str)
      # Escape only " and \, because the caller puts the result inside double quotes
      str.gsub(/["\\]/) { |c| "\\#{c}" }
    end
    def escape_quotes(str)
      Svn2Git::Migration.escape_quotes(str)
    end

    def self.checkout_svn_branch(branch)
      "git checkout -b \"#{branch}\" \"remotes/svn/#{branch}\""
    end

  private

  def clone!
    # Determine target directory
    repo_name = File.basename(@url).sub(/\.svn$/i, '')
    target_dir = @options[:target_dir] && !@options[:target_dir].empty? ? @options[:target_dir] : repo_name
    target_dir = File.expand_path(target_dir)
  
    # Guard against running inside an existing Git repo
    if File.exist?(File.join(target_dir, '.git'))
      raise "Target directory #{target_dir} already contains a Git repository"
    end
  
    # Create and enter the target directory
    FileUtils.mkdir_p(target_dir)
    Dir.chdir(target_dir) do
      trunk = @options[:trunk]
      branches = @options[:branches]
      tags = @options[:tags]
      metadata = @options[:metadata]
      nominimizeurl = @options[:nominimizeurl]
      rootistrunk = @options[:rootistrunk]
      authors = @options[:authors]
      exclude = @options[:exclude]
      revision = @options[:revision]
      username = @options[:username]
      password = @options[:password]
  
      if rootistrunk
        cmd = "git svn init --prefix=svn/ "
        cmd += "--username='#{username}' " unless username.nil?
        cmd += "--password='#{password}' " unless password.nil?
        cmd += "--no-metadata " unless metadata
        cmd += "--no-minimize-url " if nominimizeurl
        cmd += "--trunk='#{@url}'"
        run_command(cmd, true, true)
      else
        cmd = "git svn init --prefix=svn/ "
        cmd += "--username='#{username}' " unless username.nil?
        cmd += "--password='#{password}' " unless password.nil?
        cmd += "--no-metadata " unless metadata
        cmd += "--no-minimize-url " if nominimizeurl
        cmd += "--trunk='#{trunk}' " unless trunk.nil?
  
        unless tags.nil?
          tags = ['tags'] if tags.empty?
          tags.each { |tag| cmd += "--tags='#{tag}' " }
        end
  
        unless branches.nil?
          branches = ['branches'] if branches.empty?
          branches.each { |branch| cmd += "--branches='#{branch}' " }
        end
  
        cmd += @url
        run_command(cmd, true, true)
      end
  
      run_command("#{git_config_command} svn.authorsfile #{authors}") unless authors.nil?
  
      cmd = "git svn fetch "
      unless revision.nil?
        range = revision.split(":")
        range[1] = "HEAD" unless range[1]
        cmd += "-r #{range[0]}:#{range[1]} "
      end
      unless exclude.empty?
        regex = []
        unless rootistrunk
          regex << "#{trunk}[/]" unless trunk.nil?
          tags.each{|tag| regex << "#{tag}[/][^/]+[/]"} unless tags.nil? or tags.empty?
          branches.each{|branch| regex << "#{branch}[/][^/]+[/]"} unless branches.nil? or branches.empty?
        end
        regex = '^(?:' + regex.join('|') + ')(?:' + exclude.join('|') + ')'
        cmd += "--ignore-paths='#{regex}' "
      end
      run_command(cmd, true, true)
  
      get_branches
    end
  end
  
    def get_branches
      # Get the list of local and remote branches, taking care to ignore console color codes and ignoring the
      # '*' character used to indicate the currently selected branch.
      @local = run_command("git branch -l --no-color").split(/\n/).collect{ |b| b.gsub(/\*/,'').strip }
      @remote = run_command("git branch -r --no-color").split(/\n/).collect{ |b| b.gsub(/\*/,'').strip }

      # Tags are remote branches that start with "tags/".
      @tags = @remote.find_all { |b| b.strip =~ %r{^svn\/tags\/} }

    end

    def get_rebasebranch
	  get_branches 
	  @local = @local.find_all{|l| l == @options[:rebasebranch]}
	  @remote = @remote.find_all{|r| r.include? @options[:rebasebranch]}

      if @local.count > 1 
        pp "To many matching branches found (#{@local})."
        exit 1
      elsif @local.count == 0
	    pp "No local branch named \"#{@options[:rebasebranch]}\" found."
        exit 1
      end

      if @remote.count > 2 # 1 if remote is not pushed, 2 if its pushed to remote
        pp "To many matching remotes found (#{@remotes})"
        exit 1
      elsif @remote.count == 0
	    pp "No remote branch named \"#{@options[:rebasebranch]}\" found."
        exit 1
      end
	  pp "Local branches \"#{@local}\" found"
	  pp "Remote branches \"#{@remote}\" found"

      @tags = [] # We only rebase the specified branch

    end

    def fix_tags
      current = {}
      current['user.name']  = run_command("#{git_config_command} --get user.name", false)
      current['user.email'] = run_command("#{git_config_command} --get user.email", false)
    
      # Optional mapping log
      mapping = []
    
      @tags.each do |tag|
        tag = tag.strip
        raw_id = tag.gsub(%r{^svn\/tags\/}, '').strip
    
        # Translate SVN tag name to a valid Git tag name
        safe_id = Svn2Git::RefnameSanitize.tag(raw_id)
    
        mapping << "#{raw_id} -> #{safe_id}" if raw_id != safe_id
    
        subject = run_command("git log -1 --pretty=format:'%s' \"#{escape_quotes(tag)}\"").chomp("'").reverse.chomp("'").reverse
        date    = run_command("git log -1 --pretty=format:'%ci' \"#{escape_quotes(tag)}\"").chomp("'").reverse.chomp("'").reverse
        author  = run_command("git log -1 --pretty=format:'%an' \"#{escape_quotes(tag)}\"").chomp("'").reverse.chomp("'").reverse
        email   = run_command("git log -1 --pretty=format:'%ae' \"#{escape_quotes(tag)}\"").chomp("'").reverse.chomp("'").reverse
        run_command("#{git_config_command} user.name \"#{escape_quotes(author)}\"")
        run_command("#{git_config_command} user.email \"#{escape_quotes(email)}\"")
    
        original_git_committer_date = ENV['GIT_COMMITTER_DATE']
        ENV['GIT_COMMITTER_DATE'] = escape_quotes(date)
        run_command("git tag -a -m \"#{escape_quotes(subject)}\" \"#{escape_quotes(safe_id)}\" \"#{escape_quotes(tag)}\"")
        ENV['GIT_COMMITTER_DATE'] = original_git_committer_date
    
        run_command("git branch -d -r \"#{escape_quotes(tag)}\"")
      end
    
    ensure
      # restore git config if tags existed
      unless @tags.empty?
        current.each_pair do |name, value|
          if value.strip != ''
            run_command("#{git_config_command} #{name} \"#{value.strip}\"")
          else
            run_command("#{git_config_command} --unset #{name}")
          end
        end
      end
    
      # write mapping file after tags have been processed
      if defined?(mapping) && !mapping.empty?
        File.write('tag-rename-map.txt', mapping.join("\n"))
      end
    end
    
    def fix_branches
      svn_branches = @remote - @tags
      svn_branches.delete_if { |b| b.strip !~ %r{^svn\/} }
    
      # Skip svn snapshot refs like "branch@1234"
      svn_branches.delete_if { |b| b =~ /@\d+\s*\z/ }
    
      if @options[:rebase]
        run_command("git svn fetch", true, true)
      end
    
      svn_branches.each do |branch_ref|
        branch = branch_ref.gsub(/^svn\//,'').strip
        next if branch == 'trunk'
        next if @local.include?(branch)
    
        remote_ref = "refs/remotes/svn/#{branch}"
    
        # Ensure the remote ref exists
        exists = run_command("git rev-parse -q --verify \"refs/tags/#{escape_quotes(safe_id || id)}\"", false)
        if exists.strip != ''
          run_command("git branch -d -r \"#{escape_quotes(tag)}\"")
          next
        end

    
        # Create local branch from the remote ref, without tracking
        created = run_command("git branch \"#{escape_quotes(branch)}\" \"#{escape_quotes(remote_ref)}\"", false)
    
        # If the local branch already exists, just reset it to remote tip
        if created =~ /fatal: A branch named .+ already exists/i
          run_command("git branch -f \"#{escape_quotes(branch)}\" \"#{escape_quotes(remote_ref)}\"")
        end
    
        # Check it out
        run_command("git checkout \"#{escape_quotes(branch)}\"")
      end
    end
    
    def fix_trunk
      trunk = @remote.find { |b| b.strip == 'trunk' }
      if trunk && ! @options[:rebase]
        run_command("git checkout svn/trunk")
        run_command("git branch -D master")
        run_command("git checkout -f -b master")
      else
        run_command("git checkout -f master")
      end
    end

    def optimize_repos
      run_command("git gc")
    end

    def run_command(cmd, exit_on_error=true, printout_output=false)
      log "Running command: #{cmd}\n"
    
      ret = ''
      @stdin_queue ||= Queue.new
    
      # Collect user input lines asynchronously
      @stdin_thread ||= Thread.new do
        while (line = $stdin.gets)
          @stdin_queue << line
        end
        @stdin_queue << nil
      end
    
      Open3.popen2e(cmd) do |child_stdin, child_out, wait_thr|
        reader = Thread.new do
          begin
            until child_out.eof?
              chunk = child_out.readpartial(4096)
              ret << chunk
              if printout_output
                $stdout.print chunk
              else
                log chunk
              end
            end
          rescue EOFError
          end
        end
    
        writer = Thread.new do
          while (line = @stdin_queue.pop)
            child_stdin.write(line)
            child_stdin.flush
          end
        ensure
          child_stdin.close rescue nil
        end
    
        reader.join
        status = wait_thr.value
        if exit_on_error && !status.success?
          $stderr.puts "command failed:\n#{cmd}"
          exit -1
        end
      end
    
      ret
    end
    
    def log(msg)
      print msg if @options[:verbose]
    end

    def show_help_message(msg)
      puts "Error starting script: #{msg}\n\n"
      puts @opts.help
      exit
    end

    def verify_working_tree_is_clean
      status = run_command('git status --porcelain --untracked-files=no')
      unless status.strip == ''
        puts 'You have local pending changes.  The working tree must be clean in order to continue.'
        exit -1
      end
    end

    def git_config_command
      if @git_config_command.nil?
        status = run_command('git config --local --get user.name', false)

        @git_config_command = if status =~ /unknown option/m
                                'git config'
                              else
                                'git config --local'
                              end
      end

      @git_config_command
    end

  end
end

