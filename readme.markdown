# transcode-batch

i got tired of writing out bash scripts to use lisa melton's [video_transcoding] tools
to create plex-compatible directories for dvd/bd rips of movies + extras.

## how to

### requirements

- [video_transcoding] and [its dependencies](https://github.com/lisamelton/video_transcoding?tab=readme-ov-file#installation) in your path
- a directory of mkv files extracted from [makemkv](https://www.makemkv.com/)

```
$ tree .
.
├── 28 Days Later.mkv
├── 28 Days Later.srt
├── Alternate Ending.mkv
├── batch.yml
├── Continuity Polaroids.mkv
├── Making Of Featurette.mkv
├── output/
├── Theatrical Trailer.mkv

1 directory, 7 files
```


### create a `batch.yml` file

```yaml
28 Days Later.mkv:
  # defaults to the file's basename for output file
  title: 28 Days Later (2003)

  # appends "{edition-<value>}" to filename (used in plex)
  edition: Widescreen DVD

  # transcode_video defaults to adding the first track, so this can be empty
  # if you only want the main audio track. if 'track' isn't provided, it is assumed
  # that the track being added matches index + 1.
  audio:
    - title: English
    - track: 4
      title: Commentary with director Danny Boyle and writer Alex Garland

  # add external srt files with the relative path to each file as the key.
  # language and encoding default to 'eng' and 'utf8', natch. no support for
  # forced bc i always have subtitles on
  subtitles:
    28 Days Later.srt:
      language: eng
      encoding: utf8

  # extras videos are extracted to the project root and need to be moved to a
  # different output location depending on the type. default is 'other'.
  #
  # supported types:
  #   bts
  #   deleted
  #   featurette
  #   interview
  #   other
  #   trailer
  #
  # extras are run through the same config parser as main videos, so any features applicable
  # there (such as 'audio' or 'subtitles') can be used here.
  extras:
    Making Of Featurette.mkv:
      type: featurette
    Alternate Ending.mkv:
      type: deleted
    Theatrical Trailer.mkv:
      type: trailer
    Continuity Polaroids.mkv:
      type: bts
```

### run transcode-batch

```bash
cd /path/to/makemkv/payload
/path/to/transcode-batch.rb
```

### enjoy your new rip

```
$> tree output
output
└── 28 Days Later (2003)
    ├── 28 Days Later (2003) {edition-"Widescreen DVD"}.mkv
    ├── Behind The Scenes
    │   └── Continuity Polaroids.mkv
    ├── Deleted Scenes
    │   └── Alternate Ending.mkv
    ├── Featurettes
    │   └── Making Of Featurette.mkv
    └── Trailers
        └── Theatrical Trailer.mkv

6 directories, 5 files
```


[video_transcoding]: https://github.com/lisamelton/video_transcoding