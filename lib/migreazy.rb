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
        @migration_source1 = MigrationSource::Database.new
        @migration_source2 = MigrationSource::WorkingCopy.new
      elsif args.size == 1
        @migration_source1 = MigrationSource::Database.new
        @migration_source2 = MigrationSource.new_from_command_line_arg(
          args.first
        )
      elsif args.size == 2
        @migration_source1 = MigrationSource.new_from_command_line_arg(
          args.first
        )
        @migration_source2 = MigrationSource.new_from_command_line_arg(
          args.last
        )
      end
    end
  
    class Diff < Action
      def run
        missing_in_db =
            @migration_source2.migrations - @migration_source1.migrations
        puts "Missing in #{@migration_source1.description}:"
        if missing_in_db.empty?
          puts "  (none)"
        else
          puts "  #{missing_in_db.join(', ')}"
        end
        puts
        missing_in_branch =
            @migration_source1.migrations - @migration_source2.migrations
        puts "Missing in #{@migration_source2.description}:"
        if missing_in_branch.empty?
          puts "  (none)"
        else
          puts "  #{missing_in_branch.join(', ')}"
        end
      end
    end
    
    class Down < Action
      def run
        successful_downs = []
        missing_in_branch =
            @migration_source1.migrations - @migration_source2.migrations
        if missing_in_branch.empty?
          puts "No down migrations to run"
        else
          missing_in_branch.sort.reverse.each do |migration|
            file = Dir.entries("./db/migrate/").detect { |entry|
              entry =~ /^#{migration}.*\.rb$/
            }
            require "./db/migrate/#{file}"
            file =~ /^#{migration}_([_a-z0-9]*).rb/
            $1.camelize.constantize.down
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
  
  class MigrationSource
    def self.new_from_command_line_arg(arg)
      if File.exist?(File.expand_path(arg))
        TextFile.new arg
      else
        GitBranch.new arg
      end
    end
    
    attr_reader :migrations
  
    class Database < MigrationSource
      def initialize
        Migreazy.ensure_db_connection
        @migrations = ActiveRecord::Base.connection.select_all(
          "select version from schema_migrations"
        ).map { |hash| hash['version'] }
      end
      
      def description
        "development DB"
      end
    end
    
    class GitBranch < MigrationSource
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
        "branch #{@git_branch_name}"
      end
    end
    
    class TextFile < MigrationSource
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
        "file #{@file}"
      end
    end
    
    class WorkingCopy < MigrationSource
      def initialize
        @migrations = Dir.entries("./db/migrate").select { |entry|
          entry =~ /^\d+.*\.rb$/
        }.map { |entry|
          entry.gsub(/^0*(\d+)_.*/, '\1')
        }
      end
      
      def description
        "working copy"
      end
    end
  end
end
