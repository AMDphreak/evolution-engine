# [2026-03-27] - Clarify Winget Publishing Job

Detailed context for renaming the "Publish Packages" GitHub Actions job to "Publish Winget Package".

## Context
The Evolution Engine repository uses several CI jobs to handle publishing across different platforms.

Previously, the job for Windows package publishing was named "Publish Packages", which was overly broad and implied it might be a parent or aggregator for other publishing jobs like "Publish Homebrew".

## Changes
- Renamed job `publish-pkg` display name from `Publish Packages` to `Publish Winget Package` in `.github/workflows/release.yml`.
- This change explicitly states that the job only handles Winget, aligning it visually with the sibling "Publish Homebrew" job.

## Impact
- Clearer visualization in the GitHub Actions dashboard.
- Explicitly documents that Winget and Homebrew publishing flows are independent of each other (both depend directly on the `release` job).
