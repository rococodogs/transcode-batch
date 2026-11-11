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

#
#
# @example
#   28 Days Later.mkv:
#     # defaults to the file's basename for output file
#     title: 28 Days Later (2003)
#
#     # appends "{edition-<value>}" to filename (used in plex)
#     edition: Widescreen DVD
#
#    # Toggle output to be .mp4 file instead of default .mkv
#     mp4: false
#
#     # transcode_video defaults to adding the first track, so this can be empty
#     # if you only want the main audio track. if 'track' isn't provided, it is assumed
#     # that the track being added matches index + 1.
#     audio:
#       - title: English
#       - track: 4
#         title: Commentary with director Danny Boyle and writer Alex Garland
#
#     # add external srt files with the relative path to each file as the key.
#     # there is built in support with transcode-video for copying subtitles
#     # but i like the flexability of embedding a text file over an image.
#     #
#     # configs can be provided as an array of file strings (for english utf-8 files)
#     # or hashes specifying the 3-letter language code (defaults to eng) and
#     # file encoding (defaults to utf8). no support for forced bc i always have subtitles on
#    subtitles:
#      - 28 Days Later.eng.srt
#      - 28 Days Later.fre.srt:
#          language: fre
#          encoding: utf8
#
#     # extras videos are extracted to the project root and need to be moved to a
#     # different output location depending on the type. default is 'other'.
#     #
#     # supported types:
#     #   bts
#     #   deleted
#     #   featurette
#     #   interview
#     #   other
#     #   trailer
#     #
#     # extras are run through the same config parser as main videos, so any features applicable
#     # there (such as 'audio' or 'subtitles') can be used here.
#     extras:
#       Making Of Featurette.mkv:
#         type: featurette
#       Alternate Ending.mkv:
#         type: deleted
#       Theatrical Trailer.mkv:
#         type: trailer
#       Continuity Polaroids.mkv:
#         type: bts
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
      src_file = File.join(abs_dir, src.to_s).to_s
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

  def input_filename
    File.basename(src)
  end

  def mp4?
    config[:mp4] == true
  end

  def original_output_filename
    "#{File.basename(src, '.*')}.#{mp4? ? 'mp4' : 'mkv'}"
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
    @subtitles ||= setup_subtitles
  end

  def title
    @title ||= config[:title] || File.basename(src, '.*')
  end

  def title_with_edition
    return title unless edition
    prepared_edition = edition.include?(',') ? edition.gsub(',', '\,') : edition
    %(#{title} {edition-#{prepared_edition}})
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

  # supports hash and array style yaml config
  #
  # @example subtitles as hash
  #   28 Days Later.mkv:
  #     subtitles:
  #       28 Days Later.eng.srt:
  #         language: eng
  #         encoding utf8
  #       28 Days Later.fre.srt:
  #         language: fre
  #
  # @example subtitles as array for eng/utf8-encoded sub files,
  #   28 Days Later.mkv:
  #     subtitles:
  #       - 28 Days Later.eng.srt
  #       - 28 Days Later.eng-sdh.srt
  #       - 28 Days Later.fre.srt:
  #           language: fre
  #
  # @example use subtitles embedded in source mkv file
  #   28 Days Later.mkv:
  #     subtitles:
  #       - copy: true
  #       - copy: :fre
  #       - copy: 4
  SubtitleConfig = Struct.new(:file, :language, :encoding, :copy, :track, keyword_init: true) do
    def initialize(*)
      super

      self.copy = false if copy.nil?
      self.language = 'eng' if language.nil? && track.nil?
      self.encoding ||= 'utf8'
    end
  end

  def setup_subtitles
    config.fetch(:subtitles, []).to_a.map.with_index do |sub_cnf, idx|
      case sub_cnf
      when String
        SubtitleConfig.new(file: sub_cnf)
      when Array, Hash
        next subtitle_copy_config(sub_cnf[:copy], idx) unless sub_cnf[:copy].nil? || sub_cnf[:copy] == false


        file, cnf = sub_cnf.to_a

        clean_subtitle_file(file)
        SubtitleConfig.new(file: file.to_s, language: cnf[:language], encoding: cnf[:encoding])
      end
    end.compact
  end

  def subtitle_copy_config(value, index)
    case value
    when String  then SubtitleConfig.new(copy: true, language: value)
    when Numeric then SubtitleConfig.new(copy: true, track: value)
    else SubtitleConfig.new(copy: true, track: index + 1)
    end
  end

  # Scrub fancy quotes and em/en-dashes from incoming subtitle files
  #
  # @see https://stackoverflow.com/a/4399299
  def clean_subtitle_file(path)
    allowed_extensions = ['.srt', '.ass']
    extension = File.extname(path)
    return unless allowed_extensions.include?(extension)

    tmp = Tempfile.new("#{File.basename(path, '.*')}-cleaned#{extension}")
    begin
      File.open(path, 'r') do |subfile|
        subfile.each_line do |line|
          tmp.puts(line.gsub(/[–—]/, '-').gsub(/[‘’]/, "'").gsub(/[“”]/, '"'))
        end
      end
      tmp.close

      FileUtils.mv(path, "#{path}.original")
      FileUtils.mv(tmp.path, path)
    ensure
      tmp.close
      tmp.unlink
    end
  end
end



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

      VideoConfig.for(config_path).each do |config|
        output_path = config.output_path(pwd)
        FileUtils.mkdir_p(output_path) unless Dir.exist?(output_path)
        prop_editor_class = config.mp4? ? Mp4PropEdit : MkvPropEdit

        Dir.chdir(output_path) do
          vt_target = VideoTranscoding::Target.new(config)
          CmdExecute.run(vt_target.command, show_out: show_out, show_err: show_err, dry: dry)
          rename_file(config.original_output_filename, config.output_filename, dry: dry) unless config.output_filename == config.original_output_filename
          prop_editor_class.set_title(config.output_full_path(pwd), title: config.title_with_parent, dry: dry) if File.exist?(config.output_full_path(pwd))
        end

        Cleaner.new(config: config, pwd: pwd, dry: dry).cleanup!
      end
    end

    def config_path(pwd: Dir.pwd)
      @@config_path ||= Find.find(pwd) { |path| break path if path.to_s.match?(/(.*\.)?batch\.ya?ml$/) }
    end

    def config_exists?(pwd: Dir.pwd)
      !config_path.nil? && File.exist?(config_path)
    end

    def rename_file(src, dest, dry: false)
      puts "[FileUtils.mv] mv #{src} #{dest}"

      FileUtils.mv(src, dest) unless dry
    end
  end
end

# Used to clear out transcode-video .log files + move subtitle files to
# `output/subtitles` for archiving.
class Cleaner
  def initialize(config:, pwd: Dir.pwd, dry: false)
    @config = config
    @pwd = pwd
    @dry = dry
  end

  def cleanup!
    save_subtitles! unless @dry
    save_logs! unless @dry
  rescue => e
    puts "[WARN] encountered an error during cleanup: #{e.message}"
    puts e.backtrack.split('\n').map { |line| "  #{line}" }.join('\n')
    puts "[WARN] moving on"
  end

  def save_logs!
    outdir = File.join(@pwd, VideoConfig::OUTPUT_DIRNAME, 'logs')
    FileUtils.mkdir_p(outdir) unless Dir.exist?(outdir)

    Find.find(@pwd) do |path|
      next unless File.extname(path) == '.log'

      FileUtils.cp(path, outdir) unless File.exist?(File.join(outdir, path.basename))
    end
  end

  def save_subtitles!
    title = @config.has_parent? ? @config.parent.title : @config.title
    outdir = File.join(@pwd, VideoConfig::OUTPUT_DIRNAME, 'subtitles', title)
    FileUtils.mkdir_p(outdir) unless Dir.exist?(outdir)

    sub_extensions = ['.srt', '.sup', '.sub', '.idx', '.ass']

    Find.find(@pwd) do |path|
      if sub_extensions.any? { |ext| ext == File.extname(path) }
        FileUtils.cp(path, outdir) unless File.exist?(File.join(outdir, File.basename(path)))
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
        puts "[CmdExecute.run] running #{cmd}"
        Open3.popen3(cmd) do |_stdin, stdout, stderr|
          IO.copy_stream(stdout, stream(show: show_out, type: :out)) if show_out
          IO.copy_stream(stderr, stream(show: show_err, type: :err)) if show_err
        end
      end
    end

    private

    def stream(show:, type: nil)
      return if show == false
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
    prop_commands = %(mkvpropedit "#{src.gsub('"', '\"')}" --set title="#{title.gsub('"', '\"')}")

    if dry
      puts "[MkvPropEdit.set_title]: #{prop_commands}"
    else
      CmdExecute.run(prop_commands, show_out: show_out, show_err: show_err)
    end
  end
end

class Mp4PropEdit
  def self.set_title(src, title: nil, show_out: true, show_err: true, dry: false)
    title = File.basename(src, '.*') if title.nil?
    prop_commands = %(mp4tags -s "#{title.gsub('"', '\"')}" "#{src.gsub('"', '\"')}")

    if dry
      puts "[Mp4PropEdit.set_title] #{prop_commands}"
    else
      CmdExecute.run(prop_commands, show_out: show_out, show_err: show_err)
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
      audio_names = config.audio.map.with_index { |cnf, idx| %("#{cnf.fetch(:title, '').gsub('"', '\"').gsub(',', '\,')}") || %("Track #{idx + 1}") }
      audio_cmds << %(-x aname=#{audio_names.join(',')})
    end

    # give yrself a path in to play with video settings if need be
    # (tho you'll have to figure out how to parse to flags)
    def video_flags
      flags = []
      flags << '-x crop-mode=none'
      flags << '-x format=av_mp4' if config.mp4?
      flags
    end

    # Pass --add-subtitle flags for SubtitleConfigs with :copy, otherwise configure flags
    #
    # @return [Array<String>]
    def subtitle_flags
      return [] if config.subtitles.empty?
      src_dir = File.dirname(config.src)

      files, langs, encodings, copies = [], [], [], []
      just_copies = true

      config.subtitles.each do |subtitle|
        if subtitle.copy
          copies << "--add-subtitle #{subtitle.language || subtitle.track}"
        else
          files << %("#{File.join(src_dir, subtitle.file)}")
          langs << subtitle.language
          encodings << subtitle.encoding
          just_copies = false
        end
      end

      return [*copies, '--burn-subtitle none'] if just_copies

      files_flag = "-x srt-file=#{files.join(',')}" unless files.empty?
      langs_flag = "-x srt-lang=#{langs.join(',')}" unless langs.empty?
      encoding_flag = "-x srt-codeset=#{encodings.join(',')}" unless encodings.empty?

      [*copies, files_flag, langs_flag, encoding_flag, '--burn-subtitle none'].compact
    end
  end
end

# @todo wip testing out other_transcoding as an option
class OtherTranscoding
  class Target
    def initialize(config)
      @config = config
    end

    attr_reader :config

    def command
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
