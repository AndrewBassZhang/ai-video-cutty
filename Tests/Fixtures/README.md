# Synthetic audio fixture

`synthetic-waveform-12s.m4a` is a project-generated test signal. It contains no
recording, performance, voice, or third-party media.

The file is 12 seconds of stereo AAC at 48 kHz, divided into four three-second
sections: a low-amplitude 440 Hz tone, a high-amplitude 440 Hz tone, a
medium-amplitude 440 Hz tone, and silence. It is used to verify waveform
ordering and native audio metadata fallback.

Generation command:

```zsh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' \
  -f lavfi -i 'anullsrc=channel_layout=stereo:sample_rate=48000:duration=3' \
  -filter_complex '[0:a]volume=0.10,pan=stereo|c0=c0|c1=c0[low];[1:a]volume=0.80,pan=stereo|c0=c0|c1=c0[high];[2:a]volume=0.40,pan=stereo|c0=c0|c1=c0[medium];[3:a]anull[silent];[low][high][medium][silent]concat=n=4:v=0:a=1[out]' \
  -map '[out]' -c:a aac -b:a 128k -ar 48000 -ac 2 \
  -map_metadata -1 -fflags +bitexact -flags:a +bitexact \
  -movflags +faststart -y Tests/Fixtures/synthetic-waveform-12s.m4a
```

SHA-256:

```text
7f081378130347724b24e77ab4a232bf655df6ad5cba600ff76ac9f9f385bdba
```

The fixture is dedicated to the public domain under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).
