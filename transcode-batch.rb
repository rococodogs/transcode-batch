#! /usr/bin/env ruby
#
# Parse a config file and create a plex-compatible folder of files
# for .mkv files ripped from DVD/BD discs using Lisa Melton's video_transcoding
# tool. idk I got tired of spending years thinking I know the commands
# only to find out I'm wrong and writing out the bash files is exhausting.
#
require 'fileutils'
require 'find'
require 'open3'
require 'yaml'

# Main class for executing commands
#
# The annoying thing about the new transcode-video api is that we can't
# make a new name for the file, so instead we'll create the plex scaffolding
# and then cd into each + run the commands that way?
class TranscodeBatchRunner
  class << self
    def run(dry: false, show_out: true, show_err: true, pwd: Dir.pwd, keep_logs: false)
      if config_path.nil?
        warn 'No config file found in pwd titled batch.yml or batch.yaml'
        exit 1
      end

      VideoConfig.for(File.join(pwd, config_path)).each do |config|
        output_path = config.output_path(pwd)
        FileUtils.mkdir_p(output_path) unless Dir.exist?(output_path)


        Dir.chdir(output_path) do
          vt_target = VideoTranscoding::Target.new(config)
          CmdExecute.run(vt_target.command, show_out: show_out, show_err: show_err, dry: dry)
          move_file(config.src_filename, config.output_filename, dry: dry) unless config.src_filename == config.output_filename
          MkvPropEdit.set_title(config.output_full_path(pwd), title: config.title_with_parent, dry: dry) if File.exist?(config.output_full_path(pwd))
        end
      end

      Cleaner.new(pwd).cleanup!(pwd: pwd)
    end

    def config_path(pwd: Dir.pwd)
      @@config_path ||= ['batch.yml', 'batch.yaml'].find { |p| File.exist?(File.join(pwd, p)) }
    end

    def config_exists?(pwd: Dir.pwd)
      !config_path.nil? && File.exist?(config_path)
    end

    def move_file(src, dest, dry: false)
      if dry
        puts "[FileUtils.mv] mv #{src} #{dest}"
      else
        FileUtils.mv(src, dest)
      end
    end

    def cleanup!(pwd: Dir.pwd)
      Find.find(pwd) do |path|
        if File.extname(path) == '.log'
          FileUtils.rm_rf(path)
        end
      end
    end
  end
end

class Cleaner
  def initialize(pwd = Dir.pwd)
    @pwd = pwd
  end

  def cleanup!
    save_subtitles!
    save_logs!
  end

  def save_logs!(clean: true)
    outdir = File.join(@pwd, VideoConfig::OUTPUT_DIRNAME, 'logs')
    FileUtils.mkdir_p(outdir) unless Dir.exist?(outdir)

    Find.find(@pwd) do |path|
      next unless File.extname(path) == '.log'

      FileUtils.cp(path, outdir)
      FileUtils.rm_f(path) if clean
    end
  end

  def save_subtitles!(clean: false)
    outdir = File.join(@pwd, VideoConfig::OUTPUT_DIRNAME, 'subtitles')
    FileUtils.mkdir_p(outdir) unless Dir.exist?(outdir)

    sub_extensions = ['.srt', 'sup', '.sub', '.idx', '.ass']

    Find.find(@pwd) do |path|
      if sub_extensions.any? { |ext| ext == File.extname(path) }
        FileUtils.cp(path, outdir)

        FiltUtils.rm_f(path) if clean
      end
    end
  end
end

# Convenience class for executing commands in a separate process
class CmdExecute
  class << self
    def run(cmd, show_out: true, show_err: true, dry: false)
      if dry
        puts "[CmdExecute.run] #{cmd}"
      else
        Open3.popen3(cmd) do |_stdin, stdout, stderr|
          IO.copy_stream(stdout, stream(show: show_out, type: :out)) if show_out
          IO.copy_stream(stderr, stream(show: show_err, type: :err)) if show_err
        end
      end
    end

    private

    def stream(show:, type: nil)
      return nil if show == false
      return show if show.is_a?(IO)

      case type
      when :out
        $stdout
      when :err
        $stderr
      end
    end
  end
end

# Lets you edit the title of an mkv file
class MkvPropEdit
  def self.set_title(src, title: nil, show_out: true, show_err: true, dry: false)
    title = File.basename(src, '.*') if title.nil?
    prop_commands = [
      'mkvpropedit',
      %("#{src.gsub('"', '\"')}"),
      '--set',
      %(title="#{title.gsub('"', '\"')}")
    ].join(' ')

    if dry
      puts "[MkvPropEdit.set_title]: #{prop_commands}"
    else
      CmdExecute.run(prop_commands, show_out: show_out, show_err: show_err)
    end
  end
end

# Config file parser
#
# @note extras have src video title appended to their mkv titles
class VideoConfig
  OUTPUT_DIRNAME = 'output'.freeze

  def self.for(path)
    abs_path = File.absolute_path(path)
    abs_dir = File.dirname(abs_path)

    configs = YAML.safe_load(File.read(abs_path), symbolize_names: true)

    configs.flat_map do |src, config|
      src_file = File.join(abs_dir, src.to_s)
      puts src_file
      next unless File.exist?(src_file)

      cnf = new(src_file, config)
      xtras = cnf.extras

      [cnf, *xtras]
    end.compact
  end

  def initialize(src, config, parent: true)
    @src = File.absolute_path(src.to_s)
    @config = config
    @parent = parent
  end

  attr_reader :src, :config, :parent

  def audio
    config[:audio] || []
  end

  def edition
    config[:edition]
  end

  def extra?
    has_parent?
  end

  def extras
    @extras ||= setup_extras(config[:extras])
  end

  def has_parent?
    parent && !parent? # lol wut
  end

  def mp4?
    config[:mp4] == true
  end

  def output_filename
    "#{title_with_edition}#{mp4? ? '.mp4' : '.mkv'}"
  end

  def output_full_path(pwd)
    File.join(output_path(pwd), output_filename)
  end

  # need to account for:
  #   no extras:
  #     output/
  #     |-- 28 Days Later (2003).mkv
  #
  #   extras:
  #     output/
  #     |-- 28 Days Later (2003)/
  #         |-- 28 Days Later (2003) {edition-Widescreen DVD}.mkv
  #
  # @note if this ever breaks, you'll know bc there'll be a plex-named
  #       directory sitting in your output folder
  def output_path(pwd)
    dir = File.join(pwd, OUTPUT_DIRNAME)

    if parent?
      # no extras: output/
      return dir if extras.empty?

      # extras: output/28 Days Later (2003)
      return File.join(dir, title)
    end

    # otherwise give it a plex-based subdirectory
    folder = case type.to_sym
             when :bts
               'Behind The Scenes'
             when :deleted
               'Deleted Scenes'
             when :featurette
               'Featurettes'
             when :interview
               'Interviews'
             when :trailer
               'Trailers'
             else
               'Other'
             end

    File.join(parent.output_path(pwd), folder)
  end

  def parent?
    parent.nil? || parent == true
  end

  def src_filename
    File.basename(src)
  end

  def subtitles
    config[:subtitles] || {}
  end

  def title
    @title ||= config[:title] || File.basename(src, '.*')
  end

  def title_with_edition
    return title unless edition
    %(#{title} {edition-"#{edition.gsub('"', '\"')}"})
  end

  def title_with_parent
    has_parent? ? "#{parent.title} - #{title}" : title
  end

  def type
    config[:type]&.to_sym || :feature
  end

  def video
    config[:video] || []
  end

  private

  def setup_extras(config)
    return [] if config.nil? || config.empty?

    config.map do |src, config|
      config[:type] ||= :other
      self.class.new(src, config, parent: self)
    end
  end
end

# Wrapper for generating a transcode-video command from a VideoConfig object
class VideoTranscoding
  class Target
    def initialize(config)
      @config = config
    end

    attr_reader :config

    def command
      [
        'transcode-video',
        *video_flags,
        *audio_flags,
        *subtitle_flags,
        %("#{config.src}"),
      ].join(' ')
    end

    def audio_flags
      return [] if config.audio.empty?

      audio_cmds = config.audio.map.with_index { |cnf, idx| "--add-audio #{cnf[:track] || idx + 1}" }
      audio_names = config.audio.map.with_index { |cnf, idx| %("#{cnf[:title]&.gsub('"', '\"')}") || %("Track #{idx + 1}") }
      audio_cmds << %(-x aname=#{audio_names.join(',')})
    end

    # give yrself a path in to play with video settings if need be
    # (tho you'll have to figure out how to parse to flags)
    def video_flags
      flags = []
      flags << '--mp4' if config.mp4?
      flags
    end

    # Subtitle options are passed to HandBrake
    def subtitle_flags
      return [] if config.subtitles.empty?

      src_dir = File.dirname(config.src)

      # src paths need to be relative
      files = config.subtitles.keys.map { |k| %("#{File.join(src_dir, k.to_s)}") }.join(',')
      langs = config.subtitles.values.collect { |v| v[:language] || v[:lang] || 'eng' }.join(',')
      encodings = config.subtitles.values.collect { |v| v[:encoding] || 'utf8' }.join(',')

      [
        "-x srt-file=#{files}",
        "-x srt-lang=#{langs}",
        "-x srt-codeset=#{encodings}"
      ]
    end
  end
end

####
####
####
####

if ['-h', '--help'].any? { |k| ARGV.include?(k) }
  puts <<-EOUSAGE
usage: ./transcode-batch [--dry]

a `batch.yml` file is required in the working directory, which #{TranscodeBatchRunner.config_exists? ? 'exists!' : 'doesn\'t exist here'}
EOUSAGE
  exit 0
elsif ARGV.include?('--dry')
  TranscodeBatchRunner.run(dry: true)
else
  TranscodeBatchRunner.run
end
