# Generated MP3 fixture

`music-660-stereo.mp3` is an original, two-second 660 Hz sine wave at amplitude 0.15,
44.1 kHz, stereo, encoded as 128 kbps MPEG-1 Layer III with the installed LAME CLI.
It contains no recorded audio or third-party music. The recording regression
harness reads this file directly; running the tests needs no MP3 encoder.

The source PCM uses signed 16-bit little-endian samples, with the same signal in
both channels: `Int16(0.15 * 32767 * sin(2 * pi * 660 * frame / 44100))` for 88,200
frames. Encoding command: `lame -b 128 source.wav music-660-stereo.mp3`.
