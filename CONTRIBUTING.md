# Contributing to Purr

Thanks for your interest in Purr! This guide covers setting up the project, making a change and opening a pull request.

## Code of Conduct

By taking part in this project, you agree to:

- Be respectful and inclusive
- Accept constructive criticism gracefully
- Focus on what is best for the community

## Getting Started

1. **Fork the Repository**
   - Open the [Purr repository](https://github.com/iamarunbrahma/purr) and click **Fork**
   - Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/purr.git
   cd purr
   ```

2. **Set Up Your Mac**
   - An Apple Silicon Mac on macOS 14 or later
   - Full Xcode, not just the Command Line Tools. Purr uses Foundation Models macros that need Xcode's compiler plugins.

   Build and open the app:
   ```bash
   make run
   ```

   `make app` signs the build ad hoc, so you don't need a certificate. macOS treats each ad-hoc build as a new app, so expect to grant Microphone and Accessibility again after you rebuild. The menu bar shows **Permissions Needed** when one is missing.

## Development Workflow

1. **Create a New Branch**
   ```bash
   # If you are fixing a bug
   git checkout -b bugfix/your-bug-name

   # If you are adding a new feature
   git checkout -b feature/your-feature-name
   ```

2. **Make Your Changes**
   - Keep each pull request to one fix or feature
   - Match the style of the code around your change, and format the files you touch with `swift format --in-place <file>` (settings are in `.swift-format`)
   - Update the README if you change how something works

3. **Check Your Changes**
   There is no automated test suite yet, so build the app and try your change in it:
   ```bash
   make run
   ```
   Then try the three hotkeys (dictation, meeting and Voice Edit) to make sure nothing else broke.

## Pull Request Process

1. **Prepare Your Changes**
   ```bash
   git add .
   git commit -S -m "Short description of your change"
   git push origin feature/your-feature-name
   ```
   `main` only accepts signed commits, and GitHub checks every commit in a pull request. See GitHub's guide to [signing commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits).

2. **Create a Pull Request**
   - Go to your fork on GitHub and click **New Pull Request**
   - Select your branch and target `main`
   - Describe what changed and why, and link the related issue

3. **Review**
   - The CI build runs once a maintainer approves it for your pull request
   - Claude posts an automated review. A maintainer reviews it too before merging.

## Reporting Security Issues

Please don't open a public issue for a security problem. Report it privately through [GitHub](https://github.com/iamarunbrahma/purr/security/advisories/new) instead.
