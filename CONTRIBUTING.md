# Contributing to Wavepod

Thank you for helping. Bug reports, fixes, translations and ideas are all welcome.

## Report a bug or ask for a feature

Open an [issue](https://github.com/concava/wavepod/issues). For a bug, tell us:

- your Mac (for example M2, 16 GB) and the macOS version,
- the Wavepod version (**Wavepod › About Wavepod**),
- the link or the kind of file you used, if you can share it,
- what you expected, and what happened.

Do not paste private transcripts, account emails or tokens into an issue. To report a security problem, follow
[SECURITY.md](SECURITY.md) instead.

## Make a change

1. Build the app with the steps in [Build from source](README.md#build-from-source).
2. Read [docs/development.md](docs/development.md) for the code conventions and the tests, and
   [docs/architecture.md](docs/architecture.md) for how the parts fit together.
3. Make a branch from `main`. Keep one topic per pull request.
4. Run the tests before you push:

   ```sh
   (cd WavepodKit && swift test)
   ```

   If you change the UI on purpose, record the snapshots again and look at the new images before you commit
   them:

   ```sh
   (cd WavepodKit && SNAPSHOT_RECORD=1 swift test --filter SnapshotTests)
   ```

5. Open a pull request. Say what changed, why, and how you checked it. Add a screenshot for a UI change.

## Ground rules

- **Privacy first.** Audio never leaves the Mac. A change that sends data off the Mac must be optional and
  visible in Settings › Data and Privacy. All network requests go through `Networking.HTTPClient`.
- **No secrets in the repository.** Never commit keys, tokens, certificates, `.env` files or personal data. Use
  placeholder values such as `test@example.invalid` in tests.
- **Small and tested.** Add or update a test for each behavior change.

## License

Wavepod is licensed under the [Apache License 2.0](LICENSE). By contributing, you agree that your contribution is
licensed under the same terms.
