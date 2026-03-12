# Test Fixtures

Fixtures used by Pester tests in `Tests/Backup-ITGMania.Tests.ps1`.

## Structure

| Path | Purpose |
|------|---------|
| `config.json` | Valid config for Get-Config tests (gitignored; copy from `config.example.json` at project root) |
| `sample-stats-diff.txt` | Git diff format for Stats.xml; used by Get-NewScoreEntriesFromStatsDiff |
| `sample-pack-diff.txt` | Pack list diff for Get-PackListDiffSummary |
| `sample-digest.md` | Example digest content |
| `Songs/TestPack/TestSong/test.ssc` | .ssc chart (Challenge, meter 12) for Get-MeterFromSongChart |
| `Songs/TestPack/SmSong/test.sm` | .sm chart (Medium, meter 8, standard format with description line) |
| `StatsStaging/ITGMania/SavePortable/LocalProfiles/00000001/Stats.xml` | Full Stats.xml for Get-MeterTallyFromStatsXml |

## Meter Lookup Tests

- **Direct path:** `Songs\TestPack\TestSong` – InstallPath is Fixtures dir
- **Pack-song fallback:** `WrongPath/TestPack/TestSong` – direct path fails, fallback finds TestPack/TestSong
- **.sm format:** SmSong uses standard format (type, description, difficulty, meter)

## Stats.xml Fixture

The Stats.xml in `StatsStaging` has:
- Profile name: TestPlayer
- Two songs: TestPack/TestSong (Challenge), TestPack/SmSong (Medium)
- Multiple HighScores per chart (TestSong has 2)
- Dates in 2024-01-* for cutoff testing
