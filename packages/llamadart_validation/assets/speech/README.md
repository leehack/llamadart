# Speech fixtures

`jfk.wav` is the familiar excerpt from John F. Kennedy's January 20, 1961
inaugural address, distributed as the `samples/jfk.wav` fixture in whisper.cpp.
The US federal government speech is public domain. Its exact bytes and reference
words are locked in `stt.json`; the reference ignores punctuation/case only.
No personal microphone recordings are included.

The Qwen3-ASR and Qwen3-TTS model/projector locks match the maintained chat-app
catalog. Model files are downloaded separately, never included in the app or
repository. Model licenses remain with the linked upstream repositories.

The fixture reference is a transcription oracle, not proof of exact-model
qualification. A failed transcription remains a failure; do not revise the
reference or threshold to match the output of a failing run.
