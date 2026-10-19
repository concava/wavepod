# Pipeline profiling

Open the built app in Instruments with the **os_signpost** instrument, filter subsystem `app.wavepod`, category
`Pipeline`, and enable the **Memory Usage** instrument. Transcription jobs emit intervals and stage transitions
are written to the local unified log. Use a 3 h episode on the 16 GB design-floor Mac. Include the embedded
`WavepodEngine` XPC process when measuring the 4 GB combined pipeline cap. ASR and diarization run sequentially;
the foreground app holds an exclusive queue lease so the feed helper cannot start a second inference process.
