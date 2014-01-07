require 'grit'

module Migreazy
  @@db_connected = false
  
  def self.ensure_db_connection
    unless @@db_connected
      db_config = YAML::load(IO.read("./config/database.yml"))
      ActiveRecord::Base.establish_connection db_config['development']
      @@db_connected = true
    end
  end

  class Action
    def initialize(args)
      @args = args
      if args.empty?
        @source1 = Source::Database.new
        @source2 = Source::WorkingCopy.new
      elsif args.size == 1
        @source1 = Source::Database.new
        @source2 = Source.new_from_command_line_arg(args.first)
      elsif args.size == 2
        @source1 = Source.new_from_command_line_arg(args.first)
        @source2 = Source.new_from_command_line_arg(args.last)
      end
    end
  
    class Diff < Action
      def run
        left_only = (@source1.migrations - @source2.migrations).sort.reverse
        right_only = (@source2.migrations - @source1.migrations).sort.reverse
        unless left_only.empty? && right_only.empty?
          puts(
            sprintf("%-39s  %-39s", @source1.description, @source2.description)
          )
          puts(
            sprintf(
              "%-39s  %-39s", ("=" * @source1.description.length),
              ("=" * @source2.description.length)
            )
          )
          until (left_only.empty? && right_only.empty?)
            side = if right_only.empty?
              :left
            elsif left_only.empty?
              :right
            elsif left_only.first > right_only.first
              :left
            else
              :right
            end
            if side == :left
              puts sprintf("%-39s", left_only.first.to_s)
              left_only.shift
            else
              puts((" " * 39) + sprintf("  %-39s", right_only.first.to_s))
              right_only.shift
            end
          end
        end
      end
    end
    
    class Down < Action
      def run
        missing_in_branch = @source1.migrations - @source2.migrations
        if missing_in_branch.empty?
          puts "No down migrations to run"
        else
          missing_in_branch.sort.reverse.each do |version|
            cmd = "rake db:migrate:down VERSION=#{version}"
            exec cmd
          end
        end
      end
    end
    
    class Find < Action
      def initialize(args)
        @args = args
        @migration_number = args.first
      end
      
      def run
        repo = Grit::Repo.new '.'
        branches = repo.heads.select { |head|
          (head.commit.tree / "db/migrate").contents.any? { |blob|
            blob.name =~ /^0*#{@migration_number}/
          }
        }
        puts "Migration #{@migration_number} found in " +
             branches.map(&:name).join(', ')
      end
    end
  end
  
  class Source
    def self.new_from_command_line_arg(arg)
      if File.exist?(File.expand_path(arg))
        TextFile.new arg
      else
        GitBranch.new arg
      end
    end
    
    attr_reader :migrations
  
    class Database < Source
      def initialize
        Migreazy.ensure_db_connection
        @migrations = ActiveRecord::Base.connection.select_all(
          "select version from schema_migrations"
        ).map { |hash| hash['version'] }
      end
      
      def description
        "Development DB"
      end
    end
    
    class GitBranch < Source
      def initialize(git_branch_name)
        @git_branch_name = git_branch_name
        repo = Grit::Repo.new '.'
        head = repo.heads.detect { |h| h.name == @git_branch_name }
        all_migrations = (head.commit.tree / "db/migrate").contents
        @migrations = all_migrations.map { |blob|
          blob.name.gsub(/^0*(\d+)_.*/, '\1')
        }
      end
      
      def description
        "Branch #{@git_branch_name}"
      end
    end
    
    class TextFile < Source
      def initialize(file)
        @file = File.expand_path(file)
        @migrations = []
        File.read(@file).each_line do |line|
          line.chomp!
          if line.to_i.to_s == line
            @migrations << line
          end
        end
      end
      
      def description
        "File #{@file}"
      end
    end
    
    class WorkingCopy < Source
      def initialize
        @migrations = Dir.entries("./db/migrate").select { |entry|
          entry =~ /^\d+.*\.rb$/
        }.map { |entry|
          entry.gsub(/^0*(\d+)_.*/, '\1')
        }
      end
      
      def description
        "Working copy"
      end
    end
  end
end
